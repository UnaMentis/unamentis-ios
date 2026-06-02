// UnaMentis - Barge-In Detector
// =============================
//
// The single detection pipeline for barge-in across every narrating surface
// (session, reader, curriculum, Knowledge Bowl). Before this existed, the
// VAD-to-tentative-to-confirm state machine lived inline inside SessionManager
// and nothing else could reuse it, which is how parallel audio paths crept in.
//
// This actor owns ONLY the detection decision and its timer:
//   listening --(speech above threshold)--> tentative
//   tentative --(continued speech)--------> confirmed   (consumer fully interrupts)
//   tentative --(confirmation window with no continued speech)--> resumed (false positive)
//
// It is deliberately PURE: it performs no audio side effects (pause/stop), no
// telemetry, and no UI. It emits timestamped ``BargeInEvent`` values and lets
// the consumer decide what to do. That separation is what makes it reusable: a
// session confirms by stopping the LLM/TTS, a reader confirms by pausing
// narration, but both share this exact detection logic and these exact
// thresholds. It is also what makes detection measurable in isolation (see
// BargeInMeasurementHarness): feed it VAD results, read the events, time them.
//
// The state machine and thresholds are extracted faithfully from the prior
// SessionManager implementation:
//   - tentative on the first frame where isSpeech && confidence > threshold while armed
//   - confirm on the next such frame (the confirmation window is a timeout, not a delay)
//   - resume if the window elapses with no continued speech
//   - tentative entry is gated by `enabled`; confirmation is not (matches prior code)

import Foundation

// MARK: - Events & Config

/// A timestamped barge-in detection event. `machTime` is `mach_absolute_time()`
/// at emission, so consumers can measure latency against a known onset.
public struct BargeInEvent: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// Speech detected while armed. Consumer should pause playback.
        case tentative
        /// Continued speech. Consumer should fully interrupt (stop, hand floor to user).
        case confirmed
        /// Confirmation window elapsed with no continued speech (false positive).
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

/// Tunables for barge-in detection. Defaults mirror the prior SessionManager
/// values (`bargeInThreshold` 0.7, `bargeInConfirmationMs` 600).
public struct BargeInDetectorConfig: Sendable, Equatable {
    /// Master enable for tentative entry (was `enableInterruptions`).
    public var enabled: Bool
    /// VAD confidence a frame must strictly exceed to count as speech for
    /// barge-in (was `config.audio.bargeInThreshold`, compared with `>`).
    public var confidenceThreshold: Float
    /// Milliseconds of no continued speech after a tentative before resuming
    /// (the false-positive timeout, was `bargeInConfirmationMs`).
    public var confirmationMs: Int

    public init(enabled: Bool = true, confidenceThreshold: Float = 0.7, confirmationMs: Int = 600) {
        self.enabled = enabled
        self.confidenceThreshold = confidenceThreshold
        self.confirmationMs = confirmationMs
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
        /// A tentative barge-in is pending confirmation.
        case tentative
    }

    public private(set) var phase: Phase = .idle
    private var config: BargeInDetectorConfig
    private var confirmationTask: Task<Void, Never>?

    private let stream: AsyncStream<BargeInEvent>
    private let continuation: AsyncStream<BargeInEvent>.Continuation

    /// The detection event stream. Single consumer per detector instance.
    public nonisolated var events: AsyncStream<BargeInEvent> { stream }

    public init(config: BargeInDetectorConfig = BargeInDetectorConfig()) {
        self.config = config
        (self.stream, self.continuation) = AsyncStream<BargeInEvent>.makeStream()
    }

    /// Update thresholds (e.g. when the user changes settings mid-session).
    public func updateConfig(_ newConfig: BargeInDetectorConfig) {
        config = newConfig
    }

    // MARK: Arming

    /// Arm detection. Call when the surface starts speaking. No-op if already
    /// in a non-idle phase (a pending tentative is preserved).
    public func arm() {
        if phase == .idle { phase = .listening }
    }

    /// Disarm detection. Call when the surface stops speaking (normally or on
    /// teardown). Cancels any pending confirmation timer.
    public func disarm() {
        confirmationTask?.cancel()
        confirmationTask = nil
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
            phase = .tentative
            emit(.tentative, confidence: result.confidence)
            // The false-positive timeout starts at detection. The prior code
            // started it after the consumer's async pause completed, so this
            // window is ~pause-duration shorter. That is immaterial: a real
            // barge-in is confirmed by the next speech frame (~one frame later,
            // far inside the window), so the timeout only governs how soon an
            // isolated single-frame false positive resumes - slightly sooner,
            // which is the safe direction.
            startConfirmationTimer()

        case .tentative:
            guard result.isSpeech, result.confidence > config.confidenceThreshold else {
                return
            }
            confirmationTask?.cancel()
            confirmationTask = nil
            phase = .idle
            emit(.confirmed, confidence: result.confidence)
        }
    }

    /// Abort a pending tentative (e.g. the consumer could not pause playback),
    /// returning to listening so a later frame can retry. Mirrors the prior
    /// behavior where a failed pause left the surface armed and re-triggering.
    public func abortTentative() {
        guard phase == .tentative else { return }
        confirmationTask?.cancel()
        confirmationTask = nil
        phase = .listening
    }

    /// End the event stream. Call on session teardown.
    public func finish() {
        confirmationTask?.cancel()
        confirmationTask = nil
        phase = .idle
        continuation.finish()
    }

    // MARK: Internals

    private func startConfirmationTimer() {
        confirmationTask?.cancel()
        let ms = config.confirmationMs
        confirmationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.confirmationWindowElapsed()
        }
    }

    private func confirmationWindowElapsed() {
        // Still tentative and no continued speech confirmed it: resume.
        guard phase == .tentative else { return }
        confirmationTask = nil
        phase = .listening
        emit(.resumed, confidence: 0)
    }

    private func emit(_ kind: BargeInEvent.Kind, confidence: Float) {
        continuation.yield(BargeInEvent(kind: kind, machTime: mach_absolute_time(), confidence: confidence))
    }
}
