// UnaMentis - Module Telemetry Service Tests
// MODULE_SDK_SPEC.md section 5.6, capability "telemetry/1".
//
// Verifies the required taxonomy is recorded and, critically, that every event
// carries the module dimension so cross-module analysis stays possible. Uses a
// real TelemetryEngine (real over mock) and reads events back.

import XCTest
@testable import UnaMentis

final class ModuleTelemetryServiceTests: XCTestCase {

    func testTelemetry_eventsCarryModuleDimension() async {
        let engine = TelemetryEngine()
        let service = TelemetryEngineModuleTelemetryService(engine: engine)

        await service.record(.sessionStart, module: "knowledge-bowl")
        await service.record(
            .activityStart(kind: ModuleActivityKind("oral"), voiceInitiated: true),
            module: "knowledge-bowl"
        )
        await service.record(.attempt(outcome: .correct, latencyMs: 1234), module: "knowledge-bowl")
        await service.record(.activityEnd(kind: ModuleActivityKind("oral")), module: "knowledge-bowl")
        await service.record(.sessionEnd(duration: 42), module: "knowledge-bowl")

        let events = await engine.recentModuleEvents
        XCTAssertEqual(events.count, 5)
        // Every event is stamped with the emitting module.
        XCTAssertTrue(events.allSatisfy { $0.module == "knowledge-bowl" })

        let names = events.map { $0.name }
        XCTAssertEqual(names, [
            "module.session.start",
            "module.activity.start",
            "module.attempt",
            "module.activity.end",
            "module.session.end"
        ])
    }

    func testTelemetry_attemptEventCarriesOutcomeAndLatency() async {
        let engine = TelemetryEngine()
        let service = TelemetryEngineModuleTelemetryService(engine: engine)

        await service.record(.attempt(outcome: .incorrect, latencyMs: 500), module: "m")

        let record = await engine.recentModuleEvents.first
        XCTAssertEqual(record?.name, "module.attempt")
        XCTAssertTrue(record?.detail.contains("outcome=incorrect") ?? false)
        XCTAssertTrue(record?.detail.contains("latencyMs=500") ?? false)
    }

    func testTelemetry_activityStartCarriesVoiceInitiatedFlag() async {
        let engine = TelemetryEngine()
        let service = TelemetryEngineModuleTelemetryService(engine: engine)

        await service.record(
            .activityStart(kind: ModuleActivityKind("written"), voiceInitiated: false),
            module: "m"
        )

        let record = await engine.recentModuleEvents.first
        XCTAssertTrue(record?.detail.contains("kind=written") ?? false)
        XCTAssertTrue(record?.detail.contains("voiceInitiated=false") ?? false)
    }

    func testTelemetry_twoModulesRemainDistinguishable() async {
        let engine = TelemetryEngine()
        let service = TelemetryEngineModuleTelemetryService(engine: engine)

        await service.record(.sessionStart, module: "module-a")
        await service.record(.sessionStart, module: "module-b")

        let modules = await Set(engine.recentModuleEvents.map { $0.module })
        XCTAssertEqual(modules, ["module-a", "module-b"])
    }
}
