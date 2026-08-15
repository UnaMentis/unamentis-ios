// UnaMentis - Aural Skills Conformance Tests
// Runs the Aural Skills module through the executable certification levels
// (MODULE_SDK_SPEC.md section 9): UM-Core (manifest validity, lifecycle,
// capability gating, namespaced persistence) and UM-Voice (the interval drill
// completes headlessly with zero touch events, evaluates attempts, emits the
// required telemetry, and honors its claimed unified commands).
//
// Tone generation runs REAL in these runs (pure synthesis, headless); the
// scripted session records the resulting pre-rendered utterances.

import XCTest
@testable import UnaMentis

@MainActor
final class AuralSkillsConformanceTests: XCTestCase {
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

    func testAuralSkillsModule_passesUMCore() async {
        await ModuleConformance.run(
            module: AuralSkillsModule(), level: .umCore, using: harness
        )
    }

    func testAuralSkillsModule_passesUMVoice() async {
        await ModuleConformance.run(
            module: AuralSkillsModule(), level: .umVoice, using: harness
        )
    }
}
