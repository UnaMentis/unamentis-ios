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

    func testConfirmedBargeInEventReturnsToUserSpeaking() async {
        let manager = SessionManager(telemetry: TelemetryEngine())

        await manager._testForceState(.aiSpeaking)
        XCTAssertEqual(manager.state, .aiSpeaking)

        await manager._testDispatchBargeInEvent(.confirmed)
        XCTAssertEqual(manager.state, .userSpeaking, "a confirmed barge-in hands the floor to the user")
    }
}
