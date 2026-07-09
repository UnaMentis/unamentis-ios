// UnaMentis - Template Module Conformance Tests
// The Phase 6 exit criterion (MODULE_SDK_SPEC.md section 13): the template module
// passes UM-Core and UM-Voice from a clean checkout. If a contributor copies
// ExampleEchoModule and it stops passing, this test tells them exactly which
// contract touchpoint regressed.
//
// The template is a DEBUG-only module, and tests build in DEBUG, so it is
// available here.

import XCTest
@testable import UnaMentis

@MainActor
final class TemplateModuleConformanceTests: XCTestCase {
    private var harness: ScriptedModuleHost!

    override func setUp() {
        super.setUp()
        harness = ScriptedModuleHost.make()
    }

    override func tearDown() {
        harness?.tearDown()
        harness = nil
        super.tearDown()
    }

    func testTemplate_passesUMCore() async {
        await ModuleConformance.run(
            module: ExampleEchoModule(), level: .umCore, using: harness
        )
    }

    func testTemplate_passesUMVoice() async {
        await ModuleConformance.run(
            module: ExampleEchoModule(), level: .umVoice, using: harness
        )
    }

    /// The echo drill: with the harness in echo mode the learner "echoes" the
    /// spoken word, so all three rounds are evaluated correct and recorded.
    func testTemplate_echoDrillRecordsThreeCorrectAttempts() async throws {
        let module = ExampleEchoModule()
        try await module.initialize(host: harness.host)
        let result = try await module.runPrimaryVoiceActivity(
            host: harness.host,
            session: harness.voiceSession,
            script: ConformanceVoiceScript(roundCount: 3)
        )
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.attemptsEvaluated, 3)

        let export = await harness.progressStore.exportAll(for: module.manifest.id)
        XCTAssertEqual(export.attempts.count, 3)
        XCTAssertTrue(export.attempts.allSatisfy(\.correct), "Echoing the spoken word should evaluate correct.")

        let attemptTelemetry = await harness.telemetryRecorder.attemptCount(module: module.manifest.id)
        XCTAssertEqual(attemptTelemetry, 3)
    }
}
