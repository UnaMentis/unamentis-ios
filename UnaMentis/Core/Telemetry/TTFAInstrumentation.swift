// UnaMentis - TTFA Instrumentation
// =================================
//
// Lightweight Time To First Audio measurement using os_log.
// Emits structured events that the external TTFA harness captures
// via `xcrun simctl spawn <udid> log stream`.
//
// This actor has minimal overhead: just os_log writes and mach_absolute_time reads.
// It is compiled in all builds (DEBUG and RELEASE).
//
// Log format: [TTFA] EVENT|feature_id|elapsed_ms|metadata
//
// The external harness filters on subsystem "com.unamentis.ttfa" and parses
// these structured lines to compute TTFA per feature.

import Foundation
import os.log

// MARK: - Feature Identifiers

/// Standardized feature IDs for TTFA measurement.
/// Each audio-producing feature in the app has a unique ID.
public enum TTFAFeature: String, Sendable {
    // Voice sessions
    case sessionChat = "session.chat"
    case sessionCurriculum = "session.curriculum"

    // Knowledge Bowl
    case kbOral = "kb.oral"
    case kbWritten = "kb.written"
    case kbDrill = "kb.drill"
    case kbRebound = "kb.rebound"
    case kbConference = "kb.conference"

    // Reading List
    case readingPlay = "reading.play"
    case readingResume = "reading.resume"

    // Barge-in response (measures time from barge-in confirmation to first canned audio)
    case sessionBargeIn = "session.bargein"
}

// MARK: - Event Types

/// TTFA lifecycle events emitted via os_log.
public enum TTFAEventType: String, Sendable {
    /// User action triggered (button tap, deep link, play pressed)
    case activate = "ACTIVATE"
    /// First TTS chunk received from synthesis
    case ttsFirst = "TTS_FIRST"
    /// First audio buffer scheduled to AVAudioPlayerNode
    case audioScheduled = "AUDIO_SCHEDULED"
    /// playerNode.play() called (closest to actual sound output)
    case audioPlaying = "AUDIO_PLAYING"
    /// Audio served from cache (instant path)
    case cachedHit = "CACHED_HIT"
    /// Feature failed to produce audio
    case error = "ERROR"

    // Barge-in detection timeline (measured from speech onset, T0).
    /// VAD first detected user speech onset while the AI was speaking.
    case bargeInOnset = "BARGEIN_ONSET"
    /// AI playback paused on a tentative (not yet confirmed) barge-in.
    case bargeInTentative = "BARGEIN_TENTATIVE"
    /// Barge-in confirmed (continued speech); the user has the floor.
    case bargeInConfirmed = "BARGEIN_CONFIRMED"
    /// First partial STT transcript produced for the interrupting utterance.
    case bargeInSttPartial = "BARGEIN_STT_PARTIAL"
}

// MARK: - Mach Time Utilities

/// Cached mach timebase info (invariant during process lifetime)
private let ttfaTimebase: mach_timebase_info_data_t = {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return timebase
}()

/// Convert mach absolute time delta to milliseconds
private func ttfaMachToMs(_ machDelta: UInt64) -> Double {
    let nanoseconds = Double(machDelta) * Double(ttfaTimebase.numer) / Double(ttfaTimebase.denom)
    return nanoseconds / 1_000_000.0
}

// MARK: - TTFA Instrumentation Actor

/// Emits structured TTFA measurement events via os_log.
///
/// Usage from feature code:
/// ```swift
/// await TTFAInstrumentation.shared.markActivation(.readingPlay)
/// // ... audio pipeline runs ...
/// // AudioEngine automatically emits AUDIO_SCHEDULED and AUDIO_PLAYING
/// ```
///
/// The external TTFA harness captures these events to compute:
/// - Activation to first TTS chunk (TTS pipeline latency)
/// - Activation to audio scheduled (full pipeline including buffer creation)
/// - Activation to audio playing (true TTFA, closest to audible output)
public actor TTFAInstrumentation {
    public static let shared = TTFAInstrumentation()

    private static let log = OSLog(subsystem: "com.unamentis.ttfa", category: "measurement")

    /// Currently active feature being measured (only one at a time)
    private var activeFeature: TTFAFeature?

    /// Mach absolute time when the current feature was activated
    private var activationTime: UInt64 = 0

    /// Whether a measurement is currently in progress
    public var isActive: Bool { activeFeature != nil }

    /// Independent timing slot for barge-in detection. This is separate from
    /// `activationTime` so the detection timeline (onset to confirmed) never
    /// collides with a feature-TTFA measurement (e.g. the filler clip's TTFA,
    /// which uses markActivation/markAudioPlaying on the same feature id).
    private var bargeInOnsetTime: UInt64 = 0
    private var bargeInActive: Bool = false

    // MARK: - Activation

    /// Mark the start of a TTFA measurement for a feature.
    /// Call this at the exact moment the user triggers audio (tap play, start session, etc.)
    public func markActivation(_ feature: TTFAFeature, metadata: String = "") {
        // If a previous measurement is still active, auto-close it
        if let current = activeFeature {
            emit(.error, feature: current, elapsedMs: 0, metadata: "superseded by \(feature.rawValue)")
        }

        activeFeature = feature
        activationTime = mach_absolute_time()
        emit(.activate, feature: feature, elapsedMs: 0, metadata: metadata)
    }

    // MARK: - Milestone Events

    /// Mark when the first TTS audio chunk is received from synthesis.
    public func markTTSFirstChunk() {
        guard let feature = activeFeature else { return }
        let elapsed = ttfaMachToMs(mach_absolute_time() - activationTime)
        emit(.ttsFirst, feature: feature, elapsedMs: elapsed)
    }

    /// Mark when the first audio buffer is scheduled to AVAudioPlayerNode.
    public func markAudioScheduled() {
        guard let feature = activeFeature else { return }
        let elapsed = ttfaMachToMs(mach_absolute_time() - activationTime)
        emit(.audioScheduled, feature: feature, elapsedMs: elapsed)
    }

    /// Mark when playerNode.play() is called (closest to audible output).
    /// This completes the TTFA measurement.
    public func markAudioPlaying() {
        guard let feature = activeFeature else { return }
        let elapsed = ttfaMachToMs(mach_absolute_time() - activationTime)
        emit(.audioPlaying, feature: feature, elapsedMs: elapsed)
        // Measurement complete, clear active feature
        activeFeature = nil
    }

    /// Mark when audio is served from cache (instant path).
    public func markCachedHit() {
        guard let feature = activeFeature else { return }
        let elapsed = ttfaMachToMs(mach_absolute_time() - activationTime)
        emit(.cachedHit, feature: feature, elapsedMs: elapsed)
    }

    /// Mark an error during audio production.
    public func markError(_ description: String) {
        guard let feature = activeFeature else { return }
        let elapsed = ttfaMachToMs(mach_absolute_time() - activationTime)
        emit(.error, feature: feature, elapsedMs: elapsed, metadata: description)
        activeFeature = nil
    }

    // MARK: - Barge-In Detection Timeline

    /// Mark user speech onset during AI playback (T0 for barge-in latency).
    /// Reaction and time-to-first-partial are all measured from this instant.
    public func markBargeInOnset(metadata: String = "") {
        bargeInOnsetTime = mach_absolute_time()
        bargeInActive = true
        emit(.bargeInOnset, feature: .sessionBargeIn, elapsedMs: 0, metadata: metadata)
    }

    /// Mark when AI playback paused on a tentative barge-in.
    public func markBargeInTentative() {
        guard bargeInActive else { return }
        let elapsed = ttfaMachToMs(mach_absolute_time() - bargeInOnsetTime)
        emit(.bargeInTentative, feature: .sessionBargeIn, elapsedMs: elapsed)
    }

    /// Mark when the barge-in is confirmed (this is the reaction-latency milestone).
    public func markBargeInConfirmed() {
        guard bargeInActive else { return }
        let elapsed = ttfaMachToMs(mach_absolute_time() - bargeInOnsetTime)
        emit(.bargeInConfirmed, feature: .sessionBargeIn, elapsedMs: elapsed)
    }

    /// Mark the first partial STT transcript for the interrupting utterance.
    public func markBargeInSttFirstPartial() {
        guard bargeInActive else { return }
        let elapsed = ttfaMachToMs(mach_absolute_time() - bargeInOnsetTime)
        emit(.bargeInSttPartial, feature: .sessionBargeIn, elapsedMs: elapsed)
    }

    /// Close the current barge-in measurement (confirmed-and-handled, or a
    /// false positive that resumed). A subsequent onset starts a fresh one.
    public func markBargeInResolved() {
        bargeInActive = false
    }

    // MARK: - os_log Emission

    /// Emit a structured TTFA event via os_log.
    /// Format: [TTFA] EVENT|feature_id|elapsed_ms|metadata
    private func emit(
        _ event: TTFAEventType,
        feature: TTFAFeature,
        elapsedMs: Double,
        metadata: String = ""
    ) {
        // Use os_log for zero-copy, low-overhead logging.
        // The external harness filters on subsystem "com.unamentis.ttfa".
        os_log(
            .info,
            log: Self.log,
            "[TTFA] %{public}@|%{public}@|%.2f|%{public}@",
            event.rawValue,
            feature.rawValue,
            elapsedMs,
            metadata
        )
    }
}
