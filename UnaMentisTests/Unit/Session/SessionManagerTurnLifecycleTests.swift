// UnaMentis - SessionManager Turn Lifecycle Tests
// Validates the turn-processing pipeline that runs when a user utterance is
// handed to the manager: transcript surfacing, telemetry event recording, and
// the error-recovery path taken when the LLM service is unavailable. These
// tests drive the DEBUG injection entry point and the state choke point
// directly, so no real AVAudioSession or audio hardware is required. The only
// external dependency touched is the real TelemetryEngine; the paid LLM/STT/TTS
// services are never started, which is exactly the condition that exercises the
// graceful "LLM service not configured" recovery branch in generateAIResponse.

import XCTest
@testable import UnaMentis

@MainActor
final class SessionManagerTurnLifecycleTests: XCTestCase {

    private func makeManager(
        config: SessionConfig = .default,
        telemetry: TelemetryEngine
    ) -> SessionManager {
        SessionManager(config: config, telemetry: telemetry)
    }

    #if DEBUG

    // MARK: - Injection: Transcript Surfacing

    func testInjectUserUtterance_whenActive_surfacesTranscript() async {
        // When the session is active, the injected text must immediately become
        // the visible userTranscript. The idle-rejection case is covered in the
        // state-machine tests; this asserts the positive contract.
        let telemetry = TelemetryEngine()
        let manager = makeManager(telemetry: telemetry)
        await manager._testForceState(.userSpeaking)

        await manager.injectUserUtterance("What is photosynthesis?")

        XCTAssertEqual(manager.userTranscript, "What is photosynthesis?",
                       "an active session must surface the injected utterance as the transcript")
    }

    // MARK: - Injection: Turn Pipeline Telemetry

    func testInjectUserUtterance_whenActive_recordsUserFinishedSpeakingEvent() async {
        // Processing an utterance must record a userFinishedSpeaking telemetry
        // event carrying the exact transcript. This validates the turn pipeline
        // actually reached processUserUtterance and emitted through the real
        // telemetry engine, not merely that it set a published string.
        let telemetry = TelemetryEngine()
        await telemetry.startSession()  // clears the buffer; events accumulate after this
        let manager = makeManager(telemetry: telemetry)
        await manager._testForceState(.userSpeaking)

        await manager.injectUserUtterance("Define an isotope")

        let events = await telemetry.recentEvents
        let recordedTranscript: String? = events.compactMap { recorded in
            if case let .userFinishedSpeaking(transcript) = recorded.event {
                return transcript
            }
            return nil
        }.first

        XCTAssertEqual(recordedTranscript, "Define an isotope",
                       "the turn pipeline must record the finished utterance with its transcript")
    }

    func testInjectUserUtterance_whenIdle_recordsNoFinishedSpeakingEvent() async {
        // The idle guard short-circuits before processUserUtterance, so no
        // userFinishedSpeaking event may be recorded. This pairs with the
        // active-state event test to prove the guard actually gates the pipeline
        // rather than just the published transcript.
        let telemetry = TelemetryEngine()
        await telemetry.startSession()
        let manager = makeManager(telemetry: telemetry)
        XCTAssertEqual(manager.state, .idle)

        await manager.injectUserUtterance("Should be ignored")

        let events = await telemetry.recentEvents
        let hasFinishedSpeaking = events.contains { recorded in
            if case .userFinishedSpeaking = recorded.event { return true }
            return false
        }
        XCTAssertFalse(hasFinishedSpeaking,
                       "injection from idle must not run the turn pipeline or record its events")
    }

    // MARK: - Error Recovery (LLM unavailable)

    func testInjectUserUtterance_withoutLLMService_recoversToUserSpeaking() async {
        // No session was started, so llmService is nil. Processing an utterance
        // must run generateAIResponse, hit the "LLM service not configured"
        // guard, and recover to .userSpeaking rather than wedging in an error or
        // thinking state. The error state is transient (handleProcessingError
        // sleeps 1.5s then recovers), and the whole recovery is awaited inline,
        // so by the time injection returns the manager must be listening again.
        let telemetry = TelemetryEngine()
        let manager = makeManager(telemetry: telemetry)
        await manager._testForceState(.userSpeaking)

        await manager.injectUserUtterance("Tell me about gravity")

        XCTAssertEqual(manager.state, .userSpeaking,
                       "a turn that fails because the LLM is unavailable must recover to userSpeaking")
    }

    func testInjectUserUtterance_withoutLLMService_clearsAIResponseAfterRecovery() async {
        // handleProcessingError clears any partial AI response on the recovery
        // path. With no LLM there is never a real response, but the contract is
        // that aiResponse is empty after the failed turn settles.
        let telemetry = TelemetryEngine()
        let manager = makeManager(telemetry: telemetry)
        await manager._testForceState(.userSpeaking)

        await manager.injectUserUtterance("Anything")

        XCTAssertTrue(manager.aiResponse.isEmpty,
                      "a failed turn must leave the AI response cleared after recovery")
    }

    func testInjectUserUtterance_secondTurnAfterRecovery_alsoRecovers() async {
        // The recovery path must be re-entrant: after one failed turn returns to
        // userSpeaking, a second injected utterance must run the same pipeline
        // and recover again rather than wedging the state machine.
        let telemetry = TelemetryEngine()
        let manager = makeManager(telemetry: telemetry)
        await manager._testForceState(.userSpeaking)

        await manager.injectUserUtterance("First question")
        XCTAssertEqual(manager.state, .userSpeaking)

        await manager.injectUserUtterance("Second question")
        XCTAssertEqual(manager.state, .userSpeaking,
                       "the failure-recovery pipeline must be re-entrant across turns")
    }

    #endif
}
