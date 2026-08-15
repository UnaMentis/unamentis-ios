// UnaMentis - SAT Prep Conformance Tests
// The SAT module must pass UM-Core and UM-Voice before shipping
// (MODULE_SDK_SPEC.md section 9). UM-Voice runs the vocabulary drill, the
// module's primary voice activity, driven headlessly through the scripted voice
// session with zero touch events.

import XCTest
@testable import UnaMentis

@MainActor
final class SATPrepConformanceTests: XCTestCase {
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

    func testSATPrep_passesUMCore() async {
        await ModuleConformance.run(module: SATPrepModule(), level: .umCore, using: harness)
    }

    func testSATPrep_passesUMVoice() async {
        await ModuleConformance.run(module: SATPrepModule(), level: .umVoice, using: harness)
    }

    /// The vocab drill headless path: the shared driver submits each item's
    /// canonical answer, so all three rounds evaluate correct and record attempts
    /// through the real host progress store.
    func testSATPrep_vocabDrillRecordsCorrectAttempts() async throws {
        let module = SATPrepModule()
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
        XCTAssertTrue(export.attempts.allSatisfy(\.correct),
                      "Speaking each item's canonical answer should evaluate correct.")

        let attemptTelemetry = await harness.telemetryRecorder.attemptCount(module: module.manifest.id)
        XCTAssertEqual(attemptTelemetry, 3)
    }

    /// The manifest declares voice-assisted coverage (< 0.6) honestly.
    func testSATPrep_manifestDeclaresVoiceAssistedCoverage() {
        let manifest = SATPrepModule().manifest
        XCTAssertEqual(manifest.id, "sat-prep")
        XCTAssertEqual(manifest.engine, .custom)
        XCTAssertEqual(manifest.surfaces, [.phone])
        XCTAssertEqual(manifest.serverTiers, [0])
        XCTAssertLessThan(manifest.voiceCoverage.declared, 0.6,
                          "SAT prep is voice-assisted, not voice-first.")
        XCTAssertGreaterThan(manifest.voiceCoverage.declared, 0.0)
        // The catalog must provide every host capability the module requires.
        XCTAssertTrue(HostCapabilities.supports(manifest))
    }
}
