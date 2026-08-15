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

    /// Completion must be TRACKED, never assumed. A drill torn down while it is
    /// listening never reaches its summary, so it must report
    /// `completed == false`; a driver that hardcodes `true` would make the
    /// UM-Voice completion check pass vacuously for every module.
    func testTemplate_drillCancelledMidListenReportsIncomplete() async throws {
        // A session of its own: no scripted transcripts and no echo mode, so
        // `listen` parks until the run is cancelled. That is exactly the
        // mid-activity teardown the conformance gate must be able to see.
        let session = ScriptedVoiceSession()
        let host = harness.host
        let moduleId = ExampleEchoModule().manifest.id

        let runTask = Task {
            try await EchoDrill.run(
                moduleId: moduleId,
                host: host,
                session: session,
                rounds: 3,
                claimedCommands: []
            )
        }

        // Let the drill speak its first prompt and park in `listen`, bounded so
        // a drill that never speaks fails the test instead of hanging it.
        var waited = 0
        while await session.spokenTexts.isEmpty, waited < 400 {
            waited += 1
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let spokenBeforeCancel = await session.spokenTexts
        XCTAssertFalse(
            spokenBeforeCancel.isEmpty,
            "The drill must speak its first prompt before the run is cancelled."
        )

        runTask.cancel()
        let result = try await runTask.value

        XCTAssertFalse(
            result.completed,
            "A drill torn down mid-listen must report completed == false; hardcoding it true makes the "
                + "UM-Voice completion check vacuous for every module."
        )
        XCTAssertEqual(
            result.attemptsEvaluated, 0,
            "No response was captured, so no attempt was evaluated."
        )
    }
}
