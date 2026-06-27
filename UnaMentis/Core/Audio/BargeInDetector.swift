// UnaMentis - Barge-In Detector
// =============================
//
// The single detection pipeline for barge-in across every narrating surface
// (session, reader, curriculum, Knowledge Bowl). This actor owns ONLY the
// detection decision; it performs no audio side effects, no telemetry, no UI.
// It emits timestamped `BargeInEvent` values and lets the consumer decide.
//
// CORE INVARIANT (the product principle): ongoing narration must be very hard to
// interrupt. Constantly listening for a barge-in must NOT disrupt the flow.
// Background noise, music, or the AI's own voice echoing into the mic must never
// stop narration. Only a GENUINE barge-in interrupts, and "genuine" means
// SUSTAINED speech, not a frame or two above threshold. A brief blip that does
// not sustain is a false positive: the detector resumes and narration continues
// seamlessly.
//
// State machine:
//   listening --(speech above threshold)--------------> tentative   (EVALUATING; consumer keeps narrating)
//   tentative --(speech sustains >= sustainedSpeechMs)-> confirmed   (genuine barge; consumer interrupts)
//   tentative --(silence gap > maxGapMs before sustain)-> resumed    (false positive; keep narrating)
//   tentative --(safety window elapses with no resolve)-> resumed    (backstop; never stuck in tentative)
//
// Timing is driven by `VADResult.timestamp` (wall-clock at frame capture, which
// tracks audio time under the real-time mic delivery the app always uses). This
// makes the "sustained speech" decision deterministic and unit-testable without
// real-time sleeps: feed frames with controlled timestamps, read the events.

import Foundation

// MARK: - Events & Config

/// A timestamped barge-in detection event. `machTime` is `mach_absolute_time()`
/// at emission, so consumers can measure latency against a known onset.
public struct BargeInEvent: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// Speech detected while armed. The detector is now EVALUATING whether
        /// this is a genuine barge-in. Per the invariant, the consumer should NOT
        /// stop narration on this event; it is informational.
        case tentative
        /// Speech SUSTAINED past the threshold: a genuine barge-in. The consumer
        /// should fully interrupt (stop, hand the floor to the user).
        case confirmed
        /// The tentative did not sustain (false positive / noise / changed mind).
        /// The consumer should ensure narration is still flowing.
        case resumed
    }
    public let kind: Kind
    public let machTime: UInt64
    /// VAD confidence that drove the event (0 for `resumed`).
    public let confidence: Float

    public init(kind: Kind, machTime: UInt64, confidence: Float) {
        self.kind = kind
        self.machTime = machTime
        self.confidence = confidence
    }
}

/// Tunables for barge-in detection. These are the on-device "nerd knobs":
/// `confidenceThreshold`, `sustainedSpeechMs`, and `enabled` are surfaced in the
/// Barge-In Tuning settings so they can be dialed in live, in real environments,
/// without rebuilding.
public struct BargeInDetectorConfig: Sendable, Equatable {
    /// Master enable for barge-in detection.
    public var enabled: Bool
    /// VAD confidence a frame must strictly exceed to count as speech.
    public var confidenceThreshold: Float
    /// How long speech must SUSTAIN (continuous, allowing short gaps) before it
    /// counts as a genuine barge-in and confirms. This is the key anti-noise /
    /// anti-echo knob: raise it to make narration harder to interrupt.
    public var sustainedSpeechMs: Int
    /// Silence tolerated WITHIN sustained speech before the tentative is treated
    /// as ended (inter-word gaps). A gap longer than this resumes narration.
    public var maxGapMs: Int
    /// Backstop: if a tentative neither confirms nor resumes within this window
    /// (e.g. VAD frames stop arriving), force a resume so we never stick.
    public var safetyWindowMs: Int

    public init(
        enabled: Bool = true,
        confidenceThreshold: Float = 0.7,
        sustainedSpeechMs: Int = 700,
        maxGapMs: Int = 350,
        safetyWindowMs: Int = 3000
    ) {
        self.enabled = enabled
        self.confidenceThreshold = confidenceThreshold
        self.sustainedSpeechMs = sustainedSpeechMs
        self.maxGapMs = maxGapMs
        self.safetyWindowMs = safetyWindowMs
    }
}

// MARK: - Detector

public actor BargeInDetector {

    /// Detection sub-state, independent of any consumer's published state.
    public enum Phase: String, Sendable {
        /// Not armed (the surface is not currently speaking).
        case idle
        /// Armed and listening for a barge-in.
        case listening
        /// Speech seen; evaluating whether it sustains into a genuine barge-in.
        case tentative
    }

    public private(set) var phase: Phase = .idle
    private var config: BargeInDetectorConfig
    private var safetyTask: Task<Void, Never>?

    /// Audio-time (VADResult.timestamp) when the current tentative's speech began.
    private var speechStartTimestamp: TimeInterval = 0
    /// Audio-time of the most recent speech frame in the current tentative.
    private var lastSpeechTimestamp: TimeInterval = 0

    private let stream: AsyncStream<BargeInEvent>
    private let continuation: AsyncStream<BargeInEvent>.Continuation

    /// The detection event stream. Single consumer per detector instance.
    public nonisolated var events: AsyncStream<BargeInEvent> { stream }

    public init(config: BargeInDetectorConfig = BargeInDetectorConfig()) {
        self.config = config
        (self.stream, self.continuation) = AsyncStream<BargeInEvent>.makeStream()
    }

    /// Update thresholds live (e.g. when the user adjusts the tuning knobs).
    public func updateConfig(_ newConfig: BargeInDetectorConfig) {
        config = newConfig
    }

    // MARK: Arming

    /// Arm detection. Call when the surface starts speaking. No-op if already in
    /// a non-idle phase (a pending tentative is preserved).
    public func arm() {
        if phase == .idle { phase = .listening }
    }

    /// Disarm detection. Call when the surface stops speaking (normally or on
    /// teardown). Cancels any pending safety timer.
    public func disarm() {
        safetyTask?.cancel()
        safetyTask = nil
        phase = .idle
    }

    // MARK: Feeding VAD

    /// Feed one VAD result into the detector.
    public func process(_ result: VADResult) {
        switch phase {
        case .idle:
            return

        case .listening:
            guard config.enabled, result.isSpeech, result.confidence > config.confidenceThreshold else {
                return
            }
            // Speech seen. Begin EVALUATING, but do not declare a barge-in yet:
            // narration keeps flowing until the speech sustains.
            phase = .tentative
            speechStartTimestamp = result.timestamp
            lastSpeechTimestamp = result.timestamp
            emit(.tentative, confidence: result.confidence)

            // If the speech already qualifies in one frame (e.g. a long chunk and
            // a low sustainedSpeechMs), confirm immediately.
            if elapsedMs(from: speechStartTimestamp, to: result.timestamp) >= config.sustainedSpeechMs {
                confirm(result.confidence)
            } else {
                startSafetyTimer()
            }

        case .tentative:
            if result.isSpeech, result.confidence > config.confidenceThreshold {
                lastSpeechTimestamp = result.timestamp
                if elapsedMs(from: speechStartTimestamp, to: result.timestamp) >= config.sustainedSpeechMs {
                    confirm(result.confidence)
                }
            } else {
                // A silence frame. Tolerate brief inter-word gaps; resume only if
                // the gap exceeds maxGapMs (the speech did not sustain).
                if elapsedMs(from: lastSpeechTimestamp, to: result.timestamp) > config.maxGapMs {
                    resume()
                }
            }
        }
    }

    /// Abort a pending tentative (e.g. the consumer could not act), returning to
    /// listening so a later frame can retry.
    public func abortTentative() {
        guard phase == .tentative else { return }
        safetyTask?.cancel()
        safetyTask = nil
        phase = .listening
    }

    /// End the event stream. Call on session teardown.
    public func finish() {
        safetyTask?.cancel()
        safetyTask = nil
        phase = .idle
        continuation.finish()
    }

    // MARK: Internals

    private func elapsedMs(from start: TimeInterval, to end: TimeInterval) -> Int {
        Int(max(0, (end - start)) * 1000)
    }

    private func confirm(_ confidence: Float) {
        safetyTask?.cancel()
        safetyTask = nil
        phase = .idle
        emit(.confirmed, confidence: confidence)
    }

    private func resume() {
        safetyTask?.cancel()
        safetyTask = nil
        phase = .listening
        emit(.resumed, confidence: 0)
    }

    /// Wall-clock backstop: if VAD frames stop arriving while tentative (so the
    /// frame-driven gap logic never runs), force a resume so we never stick.
    private func startSafetyTimer() {
        safetyTask?.cancel()
        let ms = config.safetyWindowMs
        safetyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.safetyWindowElapsed()
        }
    }

    private func safetyWindowElapsed() {
        guard phase == .tentative else { return }
        resume()
    }

    private func emit(_ kind: BargeInEvent.Kind, confidence: Float) {
        continuation.yield(BargeInEvent(kind: kind, machTime: mach_absolute_time(), confidence: confidence))
    }
}
