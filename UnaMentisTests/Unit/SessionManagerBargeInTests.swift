// UnaMentis - SessionManager Barge-In Adoption Tests
// Validates that SessionManager drives the single BargeInDetector: the state
// choke point arms/disarms it, and detector events produce the interrupt side
// effects. Real-audio timing is validated on device; this covers the wiring.

import XCTest
@testable import UnaMentis

@MainActor
final class SessionManagerBargeInTests: XCTestCase {

    func testSetStateArmsAndDisarmsDetector() async {
        let manager = SessionManager(telemetry: TelemetryEngine())
        manager._testInstallBargeInDetector()

        await manager._testForceState(.aiSpeaking)
        let armed = await manager._testBargeInDetectorPhase()
        XCTAssertEqual(armed, .listening, "entering aiSpeaking arms the detector")

        await manager._testForceState(.userSpeaking)
        let disarmed = await manager._testBargeInDetectorPhase()
        XCTAssertEqual(disarmed, .idle, "leaving aiSpeaking disarms the detector")
    }

    func testInterruptedStateLeavesDetectorArmed() async {
        let manager = SessionManager(telemetry: TelemetryEngine())
        manager._testInstallBargeInDetector()

        await manager._testForceState(.aiSpeaking)
        // The detector owns the tentative sub-state, so transitioning the
        // session to .interrupted must not disarm it.
        await manager._testForceState(.interrupted)
        let phase = await manager._testBargeInDetectorPhase()
        XCTAssertEqual(phase, .listening, ".interrupted must not disarm the detector")
    }

    func testConfirmedBargeInPausesPendingEngagementNotImmediateStop() async {
        // INVARIANT: a confirmed (sustained) barge-in PAUSES narration pending real
        // engagement; it must NOT immediately drop the floor / stop. Only an actual
        // user utterance commits the interruption. With no pausable audio engine in
        // this bare manager, confirm cannot pause, so it leaves narration alone
        // (state stays .aiSpeaking) rather than dropping to .userSpeaking. The full
        // pause -> commit/resume flow is covered by the session integration tests
        // with a real AudioEngine.
        let manager = SessionManager(telemetry: TelemetryEngine())

        await manager._testForceState(.aiSpeaking)
        await manager._testDispatchBargeInEvent(.confirmed)

        XCTAssertNotEqual(manager.state, .userSpeaking,
                          "confirmed must not immediately hand the floor; it pauses pending engagement")
    }
}
