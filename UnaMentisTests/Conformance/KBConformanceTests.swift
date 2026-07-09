// UnaMentis - Knowledge Bowl Conformance Tests
// Runs the UM-Core and UM-Voice conformance levels against the real Knowledge
// Bowl module (MODULE_SDK_SPEC.md section 9). KB is the reference first-party
// module: it must pass both levels before shipping.
//
// These tests exercise KnowledgeBowlModule end to end through the shared
// ScriptedModuleHost harness and the ModuleConformance suite. The UM-Voice run
// drives KB's oral practice headlessly via ConformanceDrivable (no SwiftUI, zero
// touch events), proving the audio-only commitment.

import XCTest
@testable import UnaMentis

@MainActor
final class KBConformanceTests: XCTestCase {
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

    func testKnowledgeBowl_passesUMCore() async {
        await ModuleConformance.run(
            module: KnowledgeBowlModule(), level: .umCore, using: harness
        )
    }

    func testKnowledgeBowl_passesUMVoice() async {
        await ModuleConformance.run(
            module: KnowledgeBowlModule(), level: .umVoice, using: harness
        )
    }

    /// Directly assert the headless oral run reaches completion with attempts,
    /// independently of the suite, so a regression in KB's ConformanceDrivable
    /// adoption is pinpointed.
    func testKnowledgeBowl_headlessOralRunCompletesWithAttempts() async throws {
        let module = KnowledgeBowlModule()
        try await module.initialize(host: harness.host)
        let result = try await module.runPrimaryVoiceActivity(
            host: harness.host,
            session: harness.voiceSession,
            script: ConformanceVoiceScript(roundCount: 3)
        )
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.attemptsEvaluated, 3)

        // The engine emitted the required host writes: attempts and telemetry.
        let export = await harness.progressStore.exportAll(for: module.manifest.id)
        XCTAssertEqual(export.attempts.count, 3)
        let attemptTelemetry = await harness.telemetryRecorder.attemptCount(module: module.manifest.id)
        XCTAssertEqual(attemptTelemetry, 3)
    }
}
