// UnaMentis - SAT Prep Drill Session Tests
// The module's scheduling and session lifecycle, driven through the shared
// ScriptedModuleHost (a real FileProgressStoreService on a temp dir, the real
// evaluator, a scripted voice session).
//
// The load-bearing property here is that review ordering is REAL: the drill
// claims to adapt to the skills the learner finds hardest, so mastery written by
// the engine has to be the mastery the scheduler reads back. These tests pin the
// key space (the item's domain, which is what DrillEngine.recordAttempt writes),
// the refusal behavior on duplicate item ids, and the stop/teardown path that
// owns the voice session.

import XCTest
@testable import UnaMentis

@MainActor
final class SATPrepDrillSessionTests: XCTestCase {

    private var harness: ScriptedModuleHost!

    // The async forms keep the harness handling on the main actor: this class is
    // MainActor-isolated (it drives a MainActor view model), while XCTest's
    // setUp/tearDown are not.
    override func setUp() async throws {
        try await super.setUp()
        harness = ScriptedModuleHost.make()
    }

    override func tearDown() async throws {
        harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private func reportMastery(_ domain: String, signal: Double = 100) async {
        await harness.progressStore.reportMastery(
            MasteryObservation(module: "sat-prep", domain: StandardDomain(domain), signal: signal)
        )
    }

    // MARK: - Review ordering (the module's headline claim)

    /// A mastered domain sorts last, through the real progress store. The math
    /// pack ships eleven consecutive algebra items at the front, so pack order
    /// and review order are unmistakably different.
    func testReviewOrder_sortsMasteredDomainLast() async throws {
        let items = try SATPrepPackLoader.items(for: .math)
        XCTAssertTrue(items.prefix(10).allSatisfy { $0.domain == "algebra" },
                      "Pack order leads with algebra; this test needs that to be meaningful.")

        // Write mastery exactly as DrillEngine.recordAttempt does: an observation
        // keyed on the item's effective domain.
        await reportMastery("algebra")

        let ordered = await SATDrillScheduling.ordered(
            items, policy: .review, progress: harness.progressStore
        )

        guard let firstAlgebra = ordered.firstIndex(where: { $0.domain == "algebra" }),
              let lastOther = ordered.lastIndex(where: { $0.domain != "algebra" }) else {
            return XCTFail("Expected both algebra and non-algebra items in the pack.")
        }
        XCTAssertGreaterThan(firstAlgebra, lastOther,
                             "Every mastered-domain item must sort after every weaker one.")
        XCTAssertEqual(ordered.count, items.count)

        // What the learner actually gets: the descriptor's ten-item session now
        // contains none of the mastered domain.
        let session = ordered.prefix(10)
        XCTAssertFalse(session.contains { $0.domain == "algebra" },
                       "A ten-item session must lead with the weakest domains.")
    }

    /// The regression pin. Mastery stored under a SKILL TAG is not what the
    /// engine writes, so it must not move anything; mastery stored under the
    /// DOMAIN must. Reading the wrong key space is what made review ordering a
    /// silent no-op.
    func testReviewOrder_readsTheDomainKeySpaceTheEngineWrites() async throws {
        let items = try SATPrepPackLoader.items(for: .math)
        let packOrder = items.map(\.id)

        // Skill tags of every algebra item in the pack.
        for tag in ["linear-equations", "linear-functions", "systems"] {
            await reportMastery(tag)
        }
        let tagOrdered = await SATDrillScheduling.ordered(
            items, policy: .review, progress: harness.progressStore
        )
        XCTAssertEqual(tagOrdered.map(\.id), packOrder,
                       "Skill-tag keys are never written by the engine and must not order anything.")

        await reportMastery("algebra")
        let domainOrdered = await SATDrillScheduling.ordered(
            items, policy: .review, progress: harness.progressStore
        )
        XCTAssertNotEqual(domainOrdered.map(\.id), packOrder,
                          "Domain mastery is the engine's key space and must reorder the session.")
        XCTAssertNotEqual(domainOrdered.first?.domain, "algebra")
    }

    func testFreePolicy_keepsPackOrder() async throws {
        let items = try SATPrepPackLoader.items(for: .math)
        await reportMastery("algebra")
        let ordered = await SATDrillScheduling.ordered(
            items, policy: .free, progress: harness.progressStore
        )
        XCTAssertEqual(ordered.map(\.id), items.map(\.id))
    }

    /// The live surface uses the fixed scheduler: after mastering algebra, the
    /// first item a math drill presents is from a weaker domain.
    func testMathDrill_presentsAWeakerDomainFirst() async throws {
        await reportMastery("algebra")
        let algebraPrompts = Set(
            try SATPrepPackLoader.items(for: .math)
                .filter { $0.domain == "algebra" }
                .map(\.prompt)
        )

        let model = DrillSessionModel(kind: .math, host: harness.host, moduleId: "sat-prep")
        await model.start()
        let presented = await waitForCondition { !model.promptText.isEmpty }
        XCTAssertTrue(presented, "The drill should present its first item.")
        XCTAssertFalse(algebraPrompts.contains(model.promptText),
                       "The drill must open on a weaker domain, not the mastered one.")

        await model.teardown()
    }

    // MARK: - Malformed content

    /// Duplicate item ids used to hit `Dictionary(uniqueKeysWithValues:)`, whose
    /// uniqueness PRECONDITION traps rather than throwing. The scheduler now
    /// resolves them deterministically (first occurrence wins) and returns every
    /// slot it was given.
    func testScheduling_withDuplicateItemIds_doesNotTrap() async {
        let items = [
            SATDrillItem(id: "dup", skillTag: "words-in-context", domain: "craft-and-structure",
                         prompt: "First prompt.", answer: "alpha"),
            SATDrillItem(id: "dup", skillTag: "transitions", domain: "expression-of-ideas",
                         prompt: "Second prompt with the same id.", answer: "beta"),
            SATDrillItem(id: "solo", skillTag: "central-ideas", domain: "information-and-ideas",
                         prompt: "Third prompt.", answer: "gamma")
        ]
        await reportMastery("craft-and-structure")

        let ordered = await SATDrillScheduling.ordered(
            items, policy: .review, progress: harness.progressStore
        )
        XCTAssertEqual(ordered.count, items.count, "No item slot may be dropped.")
        XCTAssertEqual(Set(ordered.map(\.id)), ["dup", "solo"])
        // Deterministic resolution: the first item carrying the id.
        XCTAssertTrue(ordered.filter { $0.id == "dup" }.allSatisfy { $0.prompt == "First prompt." })
    }

    // MARK: - Stop and teardown

    /// `SATPrepModule.stop()` must actually stop the drill in flight. Before the
    /// active session was registered, stop() tore down nothing: the engine kept
    /// running and the acquired VoiceSession was never released.
    func testModuleStop_endsTheDrillInFlightAndReleasesTheVoiceSession() async throws {
        let module = SATPrepModule()
        try await module.initialize(host: harness.host)

        let model = DrillSessionModel(kind: .math, host: harness.host, moduleId: module.manifest.id)
        await model.start()
        let answering = await waitForCondition { model.phase == .awaitingAnswer }
        XCTAssertTrue(answering, "The drill should reach its first answer window.")
        var released = await harness.voiceSession.released
        XCTAssertFalse(released, "The drill still owns the voice session while it runs.")

        await module.stop()

        released = await harness.voiceSession.released
        XCTAssertTrue(released, "stop() must release the voice session the drill acquired.")
        XCTAssertEqual(model.phase, .completed, "A stopped drill is finished, not still answering.")
        let endCount = await activityEndCount(module: module.manifest.id)
        XCTAssertEqual(endCount, 1, "Stopping closes the activityStart/activityEnd pair exactly once.")

        // The engine is gone: driving the surface cannot narrate another item on
        // the session that was just handed back.
        let spokenAfterStop = await harness.voiceSession.spokenTexts.count
        await model.next()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let spokenLater = await harness.voiceSession.spokenTexts.count
        XCTAssertEqual(spokenLater, spokenAfterStop,
                       "A stopped engine must not speak on a released session.")
    }

    /// Teardown stops the engine, releases the session, and is safe to repeat:
    /// the round end, the End button, a spoken quit, and `onDisappear` can all
    /// reach it, and several of them routinely do.
    func testTeardown_stopsTheEngineAndIsIdempotent() async throws {
        let model = DrillSessionModel(kind: .math, host: harness.host, moduleId: "sat-prep")
        await model.start()
        let answering = await waitForCondition { model.phase == .awaitingAnswer }
        XCTAssertTrue(answering, "The drill should reach its first answer window.")

        await model.teardown()
        let released = await harness.voiceSession.released
        XCTAssertTrue(released)
        XCTAssertEqual(model.phase, .completed)
        XCTAssertFalse(model.isListening)

        let spokenAfterTeardown = await harness.voiceSession.spokenTexts.count
        model.typedAnswer = "5"
        await model.next()
        await model.skip()
        await model.submitTypedAnswer()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let spokenLater = await harness.voiceSession.spokenTexts.count
        XCTAssertEqual(spokenLater, spokenAfterTeardown,
                       "Nothing may drive the engine after teardown.")
        XCTAssertEqual(model.answeredCount, 0, "A torn-down drill cannot score another answer.")

        // Repeat teardown: no crash, no second release, no second activityEnd.
        await model.teardown()
        await model.end()
        XCTAssertEqual(model.phase, .completed)
        let endCount = await activityEndCount(module: "sat-prep")
        XCTAssertEqual(endCount, 1,
                       "Teardown is idempotent: exactly one activityEnd for one activityStart.")
    }

    /// Teardown before a round ever started opens no telemetry activity it
    /// cannot close, and leaves the surface idle rather than claiming a
    /// completed drill.
    func testTeardown_beforeStart_recordsNothing() async {
        let model = DrillSessionModel(kind: .vocab, host: harness.host, moduleId: "sat-prep")
        await model.teardown()
        XCTAssertEqual(model.phase, .idle)
        let endCount = await activityEndCount(module: "sat-prep")
        XCTAssertEqual(endCount, 0)
    }

    // MARK: - Helpers

    /// Poll a main-actor condition until it holds or the timeout expires. The
    /// drill's engine runs off the main actor and reports back through it, so
    /// the suspension here is what lets the round make progress.
    private func waitForCondition(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    private func activityEndCount(module: String) async -> Int {
        let events = await harness.telemetryRecorder.events(module: module)
        return events.filter { event in
            if case .activityEnd = event { return true }
            return false
        }.count
    }
}
