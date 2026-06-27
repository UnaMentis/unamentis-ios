// UnaMentis - SessionManager State Machine Tests
// Validates the SessionManager state machine and turn/config logic without the
// audio hardware path. These tests drive the state choke point and the barge-in
// event dispatcher directly through the existing DEBUG test hooks, so no real
// AVAudioSession or audio engine is required. The only external dependencies
// touched are the real TelemetryEngine and the real BargeInDetector.

import XCTest
@testable import UnaMentis

@MainActor
final class SessionManagerStateMachineTests: XCTestCase {

    private func makeManager(config: SessionConfig = .default) -> SessionManager {
        SessionManager(config: config, telemetry: TelemetryEngine())
    }

    // MARK: - Initial State

    func testInitialState_isIdle() {
        let manager = makeManager()
        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(manager.state.isActive, "idle is not an active state")
        XCTAssertFalse(manager.state.isPaused)
    }

    func testInitialPublishedFields_areEmpty() {
        let manager = makeManager()
        XCTAssertTrue(manager.userTranscript.isEmpty)
        XCTAssertTrue(manager.aiResponse.isEmpty)
        XCTAssertEqual(manager.audioLevel, -60.0, "audio level seeds at the floor (-60 dB)")
    }

    // MARK: - Forced State Transitions (choke point)

    func testForceState_movesThroughEveryState() async {
        let manager = makeManager()

        let states: [SessionState] = [
            .userSpeaking, .processingUserUtterance, .aiThinking,
            .aiSpeaking, .interrupted, .paused, .error, .idle
        ]
        for state in states {
            await manager._testForceState(state)
            XCTAssertEqual(manager.state, state, "state should reflect the forced transition to \(state.rawValue)")
        }
    }

    // MARK: - Pause / Resume Lifecycle

    func testPause_fromActiveState_succeedsAndFreezesState() async {
        let manager = makeManager()
        await manager._testForceState(.aiSpeaking)

        let didPause = await manager.pauseSession()

        XCTAssertTrue(didPause, "pausing an active session should succeed")
        XCTAssertEqual(manager.state, .paused)
        XCTAssertTrue(manager.state.isPaused)
    }

    func testPause_fromIdle_isRejected() async {
        let manager = makeManager()
        XCTAssertEqual(manager.state, .idle)

        let didPause = await manager.pauseSession()

        XCTAssertFalse(didPause, "idle is not active, so pause must be rejected")
        XCTAssertEqual(manager.state, .idle, "a rejected pause must not change state")
    }

    func testPause_whenAlreadyPaused_isRejected() async {
        let manager = makeManager()
        await manager._testForceState(.aiSpeaking)
        _ = await manager.pauseSession()
        XCTAssertEqual(manager.state, .paused)

        let secondPause = await manager.pauseSession()

        XCTAssertFalse(secondPause, "pausing an already paused session must be rejected")
        XCTAssertEqual(manager.state, .paused)
    }

    func testResume_restoresThePrePauseState() async {
        let manager = makeManager()
        await manager._testForceState(.aiSpeaking)
        _ = await manager.pauseSession()
        XCTAssertEqual(manager.state, .paused)

        let didResume = await manager.resumeSession()

        XCTAssertTrue(didResume, "resuming a paused session should succeed")
        XCTAssertEqual(manager.state, .aiSpeaking, "resume must restore the exact state captured at pause time")
    }

    func testResume_restoresUserSpeakingWhenPausedFromUserSpeaking() async {
        let manager = makeManager()
        await manager._testForceState(.userSpeaking)
        _ = await manager.pauseSession()

        let didResume = await manager.resumeSession()

        XCTAssertTrue(didResume)
        XCTAssertEqual(manager.state, .userSpeaking, "the pre-pause state, not a hardcoded default, is restored")
    }

    func testResume_whenNotPaused_isRejected() async {
        let manager = makeManager()
        await manager._testForceState(.aiSpeaking)

        let didResume = await manager.resumeSession()

        XCTAssertFalse(didResume, "resume must be rejected when the session is not paused")
        XCTAssertEqual(manager.state, .aiSpeaking, "a rejected resume must not change state")
    }

    func testPauseResume_roundTripIsIdempotentOnState() async {
        let manager = makeManager()
        await manager._testForceState(.aiThinking)

        let didPause = await manager.pauseSession()
        XCTAssertTrue(didPause)
        let didResume = await manager.resumeSession()
        XCTAssertTrue(didResume)
        XCTAssertEqual(manager.state, .aiThinking, "a full pause/resume cycle returns to the original state")

        // A second resume with no intervening pause must be a no-op.
        let secondResume = await manager.resumeSession()
        XCTAssertFalse(secondResume)
        XCTAssertEqual(manager.state, .aiThinking)
    }

    func testPause_fromInterrupted_succeeds() async {
        // .interrupted is an active state, so it must be pauseable.
        let manager = makeManager()
        await manager._testForceState(.interrupted)
        XCTAssertTrue(manager.state.isActive)

        let didPause = await manager.pauseSession()

        XCTAssertTrue(didPause)
        XCTAssertEqual(manager.state, .paused)

        let didResume = await manager.resumeSession()
        XCTAssertTrue(didResume)
        XCTAssertEqual(manager.state, .interrupted, "resume restores the interrupted state")
    }

    func testPause_fromError_isRejected() async {
        // .error is not an active state, so pause must be rejected.
        let manager = makeManager()
        await manager._testForceState(.error)
        XCTAssertFalse(manager.state.isActive)

        let didPause = await manager.pauseSession()

        XCTAssertFalse(didPause)
        XCTAssertEqual(manager.state, .error)
    }

    // MARK: - Barge-In Detector Arming via the Choke Point

    func testEnteringAISpeaking_armsDetector() async {
        let manager = makeManager()
        manager._testInstallBargeInDetector()

        await manager._testForceState(.aiSpeaking)

        let phase = await manager._testBargeInDetectorPhase()
        XCTAssertEqual(phase, .listening, "entering aiSpeaking must arm the detector")
    }

    func testLeavingAISpeakingToNonInterrupted_disarmsDetector() async {
        let manager = makeManager()
        manager._testInstallBargeInDetector()
        await manager._testForceState(.aiSpeaking)

        // Every non-interrupted exit must disarm the detector.
        let disarmingStates: [SessionState] = [
            .userSpeaking, .idle, .error, .aiThinking, .processingUserUtterance, .paused
        ]
        for state in disarmingStates {
            await manager._testForceState(.aiSpeaking)
            let armedPhase = await manager._testBargeInDetectorPhase()
            XCTAssertEqual(armedPhase, .listening)

            await manager._testForceState(state)
            let disarmedPhase = await manager._testBargeInDetectorPhase()
            XCTAssertEqual(
                disarmedPhase, .idle,
                "transition to \(state.rawValue) should disarm the detector"
            )
        }
    }

    func testTransitionToInterrupted_doesNotDisarmDetector() async {
        let manager = makeManager()
        manager._testInstallBargeInDetector()
        await manager._testForceState(.aiSpeaking)

        await manager._testForceState(.interrupted)

        // The detector owns the tentative sub-state, so .interrupted must leave it armed.
        let phase = await manager._testBargeInDetectorPhase()
        XCTAssertEqual(phase, .listening,
                       ".interrupted must not disarm the detector")
    }

    func testReArmingAISpeakingFromIdleDetector_isSafe() async {
        let manager = makeManager()
        manager._testInstallBargeInDetector()

        // arm -> disarm -> arm again should land back at listening.
        await manager._testForceState(.aiSpeaking)
        await manager._testForceState(.userSpeaking)
        let disarmedPhase = await manager._testBargeInDetectorPhase()
        XCTAssertEqual(disarmedPhase, .idle)

        await manager._testForceState(.aiSpeaking)
        let rearmedPhase = await manager._testBargeInDetectorPhase()
        XCTAssertEqual(rearmedPhase, .listening,
                       "re-entering aiSpeaking after a disarm re-arms cleanly")
    }

    // MARK: - Barge-In Event Dispatch (side effects)

    func testConfirmedBargeIn_pausesPendingEngagementNotImmediateUserSpeaking() async {
        // INVARIANT: a confirmed (sustained) barge-in PAUSES narration pending real
        // engagement; it must NOT immediately hand the floor to the user. Only an
        // actual utterance commits the interruption. With no pausable audio engine
        // in this bare manager, confirm cannot pause, so it leaves narration alone
        // rather than dropping to .userSpeaking. The full pause -> commit/resume
        // flow is covered by the session integration tests (with a real AudioEngine).
        let manager = makeManager()
        await manager._testForceState(.aiSpeaking)

        await manager._testDispatchBargeInEvent(.confirmed)

        XCTAssertNotEqual(manager.state, .userSpeaking,
                          "confirmed must not immediately hand the floor; it pauses pending engagement")
    }

    func testConfirmedBargeIn_onlyActsWhileAISpeaking() async {
        // confirmBargeIn guards on .aiSpeaking. A confirmed event arriving in any
        // other state (here .interrupted) is ignored, with no spurious transition.
        let manager = makeManager()
        await manager._testForceState(.interrupted)

        await manager._testDispatchBargeInEvent(.confirmed)

        XCTAssertEqual(manager.state, .interrupted,
                       "a confirmed event off aiSpeaking is ignored")
    }

    func testResumedEvent_doesNotDisruptNarration() async {
        // Tentative no longer pauses narration, so a resumed (false-positive)
        // event has nothing to undo: it must not alter session state. Recovery
        // from a genuine confirmed pause is handled by the no-engagement timer.
        let manager = makeManager()
        manager._testInstallBargeInDetector()
        await manager._testForceState(.aiSpeaking)

        await manager._testDispatchBargeInEvent(.resumed)

        XCTAssertEqual(manager.state, .aiSpeaking,
                       "a resumed event must not disrupt ongoing narration")
    }

    func testTentativeEvent_whenNotSpeaking_isDroppedAndStateUnchanged() async {
        // onBargeInTentative guards on state == .aiSpeaking. When the AI is no
        // longer speaking the stale event must be dropped, leaving state intact.
        let manager = makeManager()
        manager._testInstallBargeInDetector()
        await manager._testForceState(.userSpeaking)

        await manager._testDispatchBargeInEvent(.tentative)

        XCTAssertEqual(manager.state, .userSpeaking,
                       "a tentative event while not speaking must not change state")
    }

    func testTentativeEvent_doesNotDisruptNarration() async {
        // INVARIANT: a tentative is only the START of evaluation. It must never
        // pause or otherwise disrupt narration; the session stays in .aiSpeaking
        // while the detector decides whether the speech sustains into a genuine
        // barge-in. Only a confirmed event acts.
        let manager = makeManager()
        manager._testInstallBargeInDetector()
        await manager._testForceState(.aiSpeaking)

        await manager._testDispatchBargeInEvent(.tentative)

        XCTAssertEqual(manager.state, .aiSpeaking,
                       "a tentative must not disrupt narration; only a confirmed barge-in acts")
    }

    // MARK: - DEBUG Utterance Injection Guard

    #if DEBUG
    func testInjectUserUtterance_whenIdle_isRejected() async {
        // injectUserUtterance guards on state.isActive. From idle it must be a
        // no-op and must not surface a transcript.
        let manager = makeManager()
        XCTAssertEqual(manager.state, .idle)

        await manager.injectUserUtterance("Hello there")

        XCTAssertEqual(manager.state, .idle, "injection from idle must not change state")
        XCTAssertTrue(manager.userTranscript.isEmpty, "injection from idle must not set a transcript")
    }
    #endif
}
