// UnaMentis - Utterance Endpointer Tests
//
// Deterministic tests of the config-driven endpointing state machine that
// backs VoiceSession.listen (MODULE_SDK_SPEC.md section 5.1). Same pattern as
// BargeInDetectorTests: no audio, no sleeps; feed VADResults with controlled
// timestamps and read the decisions.
//
// These encode the migrated Knowledge Bowl behavior: an utterance finalizes
// after the configured silence threshold (KB: 1.5 s) following speech, never
// before speech, bounded by max utterance duration and the answer timeout.

import XCTest
@testable import UnaMentis

final class UtteranceEndpointerTests: XCTestCase {

    private func vad(speech: Bool, at timestamp: TimeInterval, confidence: Float = 0.9) -> VADResult {
        VADResult(isSpeech: speech, confidence: confidence, timestamp: timestamp, segmentDuration: 0.1)
    }

    private func makeEndpointer(
        silence: TimeInterval = 1.5,
        maxUtterance: TimeInterval = 60,
        answerTimeout: TimeInterval? = nil
    ) -> UtteranceEndpointer {
        UtteranceEndpointer(
            policy: EndpointingPolicy(
                silenceThreshold: silence,
                maxUtteranceDuration: maxUtterance
            ),
            answerTimeout: answerTimeout
        )
    }

    // MARK: - Silence Endpointing (the KB 1.5 s rule, as config)

    func testFinalizesAfterSilenceThresholdFollowingSpeech() {
        var endpointer = makeEndpointer(silence: 1.5)
        endpointer.begin(at: 0)

        XCTAssertNil(endpointer.process(vad(speech: true, at: 0.5)))
        XCTAssertNil(endpointer.process(vad(speech: true, at: 1.0)))
        // Silence begins at 1.2; threshold not yet met at 2.0.
        XCTAssertNil(endpointer.process(vad(speech: false, at: 1.2)))
        XCTAssertNil(endpointer.process(vad(speech: false, at: 2.0)))
        // 1.5 s after silence began: finalize.
        XCTAssertEqual(endpointer.process(vad(speech: false, at: 2.7)), .silence)
    }

    func testSilenceBeforeAnySpeechNeverFinalizes() {
        var endpointer = makeEndpointer(silence: 1.5)
        endpointer.begin(at: 0)

        XCTAssertNil(endpointer.process(vad(speech: false, at: 1.0)))
        XCTAssertNil(endpointer.process(vad(speech: false, at: 5.0)))
        XCTAssertNil(endpointer.process(vad(speech: false, at: 30.0)))
        XCTAssertFalse(endpointer.hasDetectedSpeech)
    }

    func testResumedSpeechResetsSilenceTimer() {
        var endpointer = makeEndpointer(silence: 1.5)
        endpointer.begin(at: 0)

        XCTAssertNil(endpointer.process(vad(speech: true, at: 0.5)))
        XCTAssertNil(endpointer.process(vad(speech: false, at: 1.0)))
        // Speech resumes inside the silence window: the timer resets.
        XCTAssertNil(endpointer.process(vad(speech: true, at: 2.0)))
        XCTAssertNil(endpointer.process(vad(speech: false, at: 2.2)))
        XCTAssertNil(endpointer.process(vad(speech: false, at: 3.5)))
        XCTAssertEqual(endpointer.process(vad(speech: false, at: 3.8)), .silence)
    }

    func testConfiguredThresholdIsRespected() {
        // The threshold is configuration: a 2.5 s policy (KB oral answers)
        // does not finalize at 1.5 s.
        var endpointer = makeEndpointer(silence: 2.5)
        endpointer.begin(at: 0)

        XCTAssertNil(endpointer.process(vad(speech: true, at: 0.5)))
        XCTAssertNil(endpointer.process(vad(speech: false, at: 1.0)))
        XCTAssertNil(endpointer.process(vad(speech: false, at: 2.6)))
        XCTAssertEqual(endpointer.process(vad(speech: false, at: 3.5)), .silence)
    }

    // MARK: - Answer Timeout

    func testAnswerTimeoutFinalizesWhenNoSpeechArrives() {
        var endpointer = makeEndpointer(answerTimeout: 5)
        endpointer.begin(at: 100)

        XCTAssertNil(endpointer.process(vad(speech: false, at: 103)))
        XCTAssertEqual(endpointer.process(vad(speech: false, at: 105)), .timeout)
    }

    func testSpeechBeforeTimeoutDisablesTimeout() {
        var endpointer = makeEndpointer(silence: 1.5, answerTimeout: 5)
        endpointer.begin(at: 0)

        XCTAssertNil(endpointer.process(vad(speech: true, at: 4.0)))
        // Past the answer timeout, but speech already started: no timeout.
        XCTAssertNil(endpointer.process(vad(speech: true, at: 6.0)))
        XCTAssertNil(endpointer.process(vad(speech: false, at: 6.5)))
        XCTAssertEqual(endpointer.process(vad(speech: false, at: 8.0)), .silence)
    }

    // MARK: - Max Utterance Duration

    func testMaxUtteranceDurationBoundsContinuousSpeech() {
        var endpointer = makeEndpointer(silence: 1.5, maxUtterance: 10)
        endpointer.begin(at: 0)

        XCTAssertNil(endpointer.process(vad(speech: true, at: 1)))
        XCTAssertNil(endpointer.process(vad(speech: true, at: 9)))
        XCTAssertEqual(endpointer.process(vad(speech: true, at: 11)), .maxUtteranceDuration)
    }

    // MARK: - Reuse

    func testBeginResetsStateBetweenUtterances() {
        var endpointer = makeEndpointer(silence: 1.5)
        endpointer.begin(at: 0)
        XCTAssertNil(endpointer.process(vad(speech: true, at: 0.5)))
        // Silence timer starts on the first silence frame, finalizes on a
        // later frame past the threshold (matching the original KB logic).
        XCTAssertNil(endpointer.process(vad(speech: false, at: 1.0)))
        XCTAssertEqual(endpointer.process(vad(speech: false, at: 3.0)), .silence)

        // New listening window: earlier speech does not leak in.
        endpointer.begin(at: 10)
        XCTAssertFalse(endpointer.hasDetectedSpeech)
        XCTAssertNil(endpointer.process(vad(speech: false, at: 15)))
    }

    // MARK: - Policy Defaults

    func testDefaultPolicyMatchesKnowledgeBowlEndpointing() {
        // KB's previous hand-rolled endpointing used a 1.5 s silence rule;
        // the default policy preserves that timing as configuration.
        XCTAssertEqual(EndpointingPolicy.default.silenceThreshold, 1.5)
    }
}
