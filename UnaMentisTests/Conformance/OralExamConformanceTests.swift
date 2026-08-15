// UnaMentis - Oral Exam Studio Conformance Tests
//
// Runs the reusable conformance suite (MODULE_SDK_SPEC.md section 9) against
// OralExamModule. First-party modules must pass UM-Core and UM-Voice before
// shipping; this module declares voiceCoverage 1.0 and adopts
// ConformanceDrivable (its question-volley activity), so both levels apply.
//
// The UM-Voice run drives the module's primary voice activity headlessly
// through the scripted VoiceSession with zero touch events, using the
// deterministic rule-based examiner (offline Tier 0), so it is hermetic.

import XCTest
@testable import UnaMentis

@MainActor
final class OralExamConformanceTests: XCTestCase {
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

    func testOralExam_passesUMCore() async {
        await ModuleConformance.run(module: OralExamModule(), level: .umCore, using: harness)
    }

    func testOralExam_passesUMVoice() async {
        await ModuleConformance.run(module: OralExamModule(), level: .umVoice, using: harness)
    }
}
