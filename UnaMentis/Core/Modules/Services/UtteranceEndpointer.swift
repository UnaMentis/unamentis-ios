// UnaMentis - Utterance Endpointer
// Config-driven utterance endpointing for the VoiceSession host service.
//
// This replaces per-module endpointing code (Knowledge Bowl's hand-rolled
// 1.5 s silence rule) with one policy-driven state machine. Like
// BargeInDetector, timing is driven by `VADResult.timestamp` so decisions are
// deterministic and unit-testable without real-time sleeps: feed frames with
// controlled timestamps, read the decisions.
//
// State machine (per listen call):
//   waiting  --(speech frame)-------------------------> speaking
//   waiting  --(answerTimeout elapses, no speech)------> finalize(.timeout)
//   speaking --(silence >= silenceThreshold)-----------> finalize(.silence)
//   speaking --(duration >= maxUtteranceDuration)------> finalize(.maxUtteranceDuration)

import Foundation

/// Decides when a learner utterance is complete, per `EndpointingPolicy`.
struct UtteranceEndpointer: Sendable {
    private let policy: EndpointingPolicy
    private let answerTimeout: TimeInterval?

    /// Audio-time when listening began (for answer timeout).
    private var listenStart: TimeInterval?
    /// Audio-time of the first speech frame in this utterance.
    private var speechStart: TimeInterval?
    /// Audio-time when the current trailing silence began.
    private var silenceStart: TimeInterval?
    /// Whether any speech has been detected in this utterance.
    private(set) var hasDetectedSpeech = false

    init(policy: EndpointingPolicy, answerTimeout: TimeInterval? = nil) {
        self.policy = policy
        self.answerTimeout = answerTimeout
    }

    /// Begin a listening window at the given audio-time.
    mutating func begin(at timestamp: TimeInterval) {
        listenStart = timestamp
        speechStart = nil
        silenceStart = nil
        hasDetectedSpeech = false
    }

    /// Feed one VAD frame. Returns a finalize reason when the utterance is
    /// complete, or nil to keep listening.
    mutating func process(_ result: VADResult) -> UtteranceResult.EndReason? {
        let now = result.timestamp

        guard hasDetectedSpeech else {
            if result.isSpeech {
                hasDetectedSpeech = true
                speechStart = now
                silenceStart = nil
                return nil
            }
            // No speech yet: enforce the answer timeout if configured.
            if let answerTimeout, let listenStart, now - listenStart >= answerTimeout {
                return .timeout
            }
            return nil
        }

        // Speech has occurred: enforce the max utterance duration.
        if let speechStart, now - speechStart >= policy.maxUtteranceDuration {
            return .maxUtteranceDuration
        }

        if result.isSpeech {
            silenceStart = nil
            return nil
        }

        // Trailing silence: finalize once it sustains past the threshold.
        if let silenceStart {
            if now - silenceStart >= policy.silenceThreshold {
                return .silence
            }
        } else {
            silenceStart = now
        }
        return nil
    }
}
