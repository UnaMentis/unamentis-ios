// UnaMentis - Quiz Bowl Conformance Tests
// Runs UM-Core and UM-Voice against the real Quiz Bowl module (MODULE_SDK_SPEC.md
// section 9). Quiz Bowl is a voice-first first-party module (voiceCoverage 0.95),
// so it must pass both levels before shipping.
//
// The UM-Voice run drives Quiz Bowl's NAQT tossup practice headlessly via
// ConformanceDrivable (no SwiftUI, zero touch), proving the primary voice
// activity completes hands-free with evaluated attempts and the required
// module.attempt telemetry, and honors the claimed quit/skip commands.

import XCTest
@testable import UnaMentis

@MainActor
final class QuizBowlConformanceTests: XCTestCase {
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

    func testQuizBowl_passesUMCore() async {
        await ModuleConformance.run(
            module: QuizBowlModule(), level: .umCore, using: harness
        )
    }

    func testQuizBowl_passesUMVoice() async {
        await ModuleConformance.run(
            module: QuizBowlModule(), level: .umVoice, using: harness
        )
    }

    /// Directly assert the headless NAQT tossup run reaches completion with
    /// attempts and emits the required host writes, so a regression in Quiz
    /// Bowl's ConformanceDrivable adoption is pinpointed independently of the
    /// suite.
    func testQuizBowl_headlessTossupRunCompletesWithAttempts() async throws {
        let module = QuizBowlModule()
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
        let attemptTelemetry = await harness.telemetryRecorder.attemptCount(module: module.manifest.id)
        XCTAssertEqual(attemptTelemetry, 3)
    }

    /// The module id is "quiz-bowl" and attempts land under that namespace.
    func testQuizBowl_manifestIdentity() {
        let manifest = QuizBowlModule().manifest
        XCTAssertEqual(manifest.id, "quiz-bowl")
        XCTAssertEqual(manifest.engine, .quizMatch)
        XCTAssertEqual(manifest.voiceCoverage.declared, 0.95, accuracy: 0.0001)
        XCTAssertTrue(manifest.surfaces.contains(.phone))
        // en-GB was dropped deliberately: VoicePipelineConfig.locale is not yet
        // plumbed into STT (RFC 0002 item 6), so declaring it would be dishonest.
        // OralExamModule refuses to declare fr-FR for the same reason.
        XCTAssertEqual(Set(manifest.locales), ["en-US"])
        XCTAssertTrue(HostCapabilities.supports(manifest),
                      "Quiz Bowl's required host capabilities must all be provided by this build")
    }
}
