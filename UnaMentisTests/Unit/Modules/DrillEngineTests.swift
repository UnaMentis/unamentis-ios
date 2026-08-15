// UnaMentis - Drill Engine Tests
// Scripted drill runs against the shared harness (ScriptedModuleHost /
// ScriptedVoiceSession) and the real FileProgressStoreService: sequencing,
// review-policy ordering, numeric and fuzzy evaluation, streak logic, and
// per-attempt progress/telemetry emission (MODULE_SDK_SPEC.md sections 6.3, 5.4,
// 5.6).

import XCTest
@testable import UnaMentis

@MainActor
final class DrillEngineTests: XCTestCase {
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

    // MARK: - Helpers

    private func descriptor(policy: DrillFormatDescriptor.SchedulingPolicy = .free) -> DrillFormatDescriptor {
        DrillFormatDescriptor(
            formatId: "test-drill",
            itemTypes: ["drill-items/1"],
            sessionShapes: [.count(10)],
            schedulingPolicy: policy
        )
    }

    /// The drill host context view of the harness, built from its public
    /// services (the harness exposes a quizMatchContext but not a drillContext;
    /// the DrillHostContext has the same shape, so we assemble it here to avoid
    /// editing the shared harness file).
    private func drillContext(moduleId: String) -> DrillHostContext {
        DrillHostContext(
            moduleId: moduleId,
            evaluation: harness.evaluationService,
            progress: harness.progressStore,
            telemetry: harness.telemetryRecorder
        )
    }

    private func makeEngine(items: [DrillItem], moduleId: String = "test-module") -> DrillEngine {
        DrillEngine(
            descriptor: descriptor(),
            options: DrillSessionOptions(activityKind: ModuleActivityKind("drill"), autoListen: false),
            host: drillContext(moduleId: moduleId),
            provider: { items }
        )
    }

    /// A drill host context whose evaluation parks on `gate`, so a test can
    /// hold the engine inside `submitAnswer`'s evaluation await.
    private func gatedDrillContext(moduleId: String, gate: EngineTestGate) -> DrillHostContext {
        DrillHostContext(
            moduleId: moduleId,
            evaluation: GatedResponseEvaluationService(gate: gate),
            progress: harness.progressStore,
            telemetry: harness.telemetryRecorder
        )
    }

    private func makeEngine(
        host: DrillHostContext,
        autoListen: Bool = false,
        provider: @escaping DrillItemProvider
    ) -> DrillEngine {
        DrillEngine(
            descriptor: descriptor(),
            options: DrillSessionOptions(
                activityKind: ModuleActivityKind("drill"), autoListen: autoListen
            ),
            host: host,
            provider: provider
        )
    }

    private func textItem(id: String, answer: String, acceptable: [String] = [], skill: String = "vocab") -> DrillItem {
        DrillItem(
            id: id,
            prompt: "Define \(id).",
            evaluation: EvaluationSpec(
                primaryAnswer: answer,
                acceptableAnswers: acceptable,
                category: .text,
                strictness: StrictnessProfile(id: "std", level: .standard),
                evaluatorTiers: [.textExact, .textFuzzy]
            ),
            skillTag: skill,
            domain: skill
        )
    }

    private func numericItem(id: String, answer: String, skill: String = "algebra") -> DrillItem {
        DrillItem(
            id: id,
            prompt: "Compute \(id).",
            evaluation: EvaluationSpec(
                primaryAnswer: answer,
                category: .numeric,
                strictness: StrictnessProfile(id: "num", level: .strict, exactOnly: true),
                evaluatorTiers: [.numeric],
                numericTolerance: 0.5
            ),
            skillTag: skill,
            domain: skill
        )
    }

    /// Step the engine to completion, submitting one answer per item, and return
    /// the ordered (index, itemId, correct) tuples plus the final summary.
    private func run(
        engine: DrillEngine,
        answers: [String]
    ) async -> (evaluated: [(index: Int, itemId: String, correct: Bool, streak: Int)], summary: DrillSummary?) {
        var remaining = answers
        var evaluated: [(index: Int, itemId: String, correct: Bool, streak: Int)] = []
        var presentedItemIds: [Int: String] = [:]
        var summary: DrillSummary?

        await engine.start(voice: harness.voiceSession)

        var iterator = engine.events.makeAsyncIterator()
        loop: while let event = await iterator.next() {
            switch event {
            case .itemPresented(let index, let item):
                presentedItemIds[index] = item.id
            case .answerWindowOpened:
                if !remaining.isEmpty {
                    await engine.submitAnswer(remaining.removeFirst())
                } else {
                    await engine.markSkipped()
                }
            case .evaluated(let index, let judgment):
                evaluated.append((index, presentedItemIds[index] ?? "", judgment.isCorrect, judgment.streak))
                await engine.next()
            case .itemSkipped:
                await engine.next()
            case .roundEnded(let s):
                summary = s
                break loop
            default:
                break
            }
        }
        return (evaluated, summary)
    }

    // MARK: - Sequencing

    func testEngine_presentsItemsInProviderOrder() async {
        let items = (0..<4).map { textItem(id: "item-\($0)", answer: "a\($0)") }
        let engine = makeEngine(items: items)
        let (evaluated, summary) = await run(engine: engine, answers: ["a0", "a1", "a2", "a3"])

        XCTAssertEqual(evaluated.map(\.itemId), ["item-0", "item-1", "item-2", "item-3"])
        XCTAssertEqual(evaluated.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(summary?.answeredItems, 4)
        XCTAssertEqual(summary?.correctAnswers, 4)
    }

    func testEngine_emptyProviderEndsImmediately() async {
        let engine = makeEngine(items: [])
        let (evaluated, summary) = await run(engine: engine, answers: [])
        XCTAssertTrue(evaluated.isEmpty)
        XCTAssertEqual(summary?.answeredItems, 0)
    }

    // MARK: - Evaluation Paths

    func testEngine_fuzzyTextEvaluation_matchesSynonymAndNearMiss() async {
        let items = [
            textItem(id: "v1", answer: "clear", acceptable: ["plain"]),
            textItem(id: "v2", answer: "cautious")
        ]
        let engine = makeEngine(items: items)
        // "plain" is an acceptable alternative; "cautius" is a Levenshtein near-miss.
        let (evaluated, _) = await run(engine: engine, answers: ["plain", "cautius"])
        XCTAssertEqual(evaluated.map(\.correct), [true, true])
    }

    func testEngine_numericEvaluation_exactMatchesAndRejectsWrongNumber() async {
        let items = [numericItem(id: "m1", answer: "5"), numericItem(id: "m2", answer: "28")]
        let engine = makeEngine(items: items)
        // "5" is exact; "27" is wrong and must not fuzzy-match "28".
        let (evaluated, _) = await run(engine: engine, answers: ["5", "27"])
        XCTAssertEqual(evaluated.map(\.correct), [true, false])
    }

    // MARK: - Streak

    func testEngine_streakGrowsOnCorrectAndResetsOnMiss() async {
        let items = (0..<4).map { numericItem(id: "m\($0)", answer: "\($0)") }
        let engine = makeEngine(items: items)
        // correct, correct, wrong, correct -> streaks 1, 2, 0, 1
        let (evaluated, summary) = await run(engine: engine, answers: ["0", "1", "99", "3"])
        XCTAssertEqual(evaluated.map(\.streak), [1, 2, 0, 1])
        XCTAssertEqual(summary?.bestStreak, 2)
        XCTAssertEqual(summary?.correctAnswers, 3)
    }

    func testEngine_skipResetsStreakAndRecordsNoAttempt() async {
        let moduleId = "skip-module"
        let items = (0..<3).map { numericItem(id: "m\($0)", answer: "\($0)") }
        let engine = makeEngine(items: items, moduleId: moduleId)

        // Drive: correct on item 0 (streak 1), SKIP item 1, correct on item 2.
        var streaks: [Int] = []
        var answered = 0
        var skipped = 0
        await engine.start(voice: harness.voiceSession)
        var iterator = engine.events.makeAsyncIterator()
        loop: while let event = await iterator.next() {
            switch event {
            case .answerWindowOpened(let index):
                if index == 1 {
                    await engine.markSkipped()
                } else {
                    await engine.submitAnswer("\(index)")
                }
            case .evaluated(let index, let judgment):
                streaks.append(judgment.streak)
                answered += 1
                _ = index
                await engine.next()
            case .itemSkipped:
                skipped += 1
                await engine.next()
            case .streakChanged:
                break
            case .roundEnded:
                break loop
            default:
                break
            }
        }

        // A skip resets the streak: item 2's streak is 1, not 2.
        XCTAssertEqual(streaks, [1, 1])
        XCTAssertEqual(answered, 2)
        XCTAssertEqual(skipped, 1)

        try? await Task.sleep(nanoseconds: 200_000_000)
        // Only the two answered items recorded attempts; the skip recorded none.
        let export = await harness.progressStore.exportAll(for: moduleId)
        XCTAssertEqual(export.attempts.count, 2)
        XCTAssertEqual(Set(export.attempts.map(\.itemId)), ["m0", "m2"])
    }

    // MARK: - Attempt Emission (real FileProgressStore)

    func testEngine_recordsAttemptsToRealProgressStore() async {
        let moduleId = "drill-progress-module"
        let items = [
            textItem(id: "v1", answer: "clear", skill: "words-in-context"),
            numericItem(id: "m1", answer: "5", skill: "algebra")
        ]
        let engine = makeEngine(items: items, moduleId: moduleId)
        _ = await run(engine: engine, answers: ["clear", "5"])

        // Give the fire-and-forget attempt tasks a moment to flush.
        try? await Task.sleep(nanoseconds: 200_000_000)

        let export = await harness.progressStore.exportAll(for: moduleId)
        XCTAssertEqual(export.attempts.count, 2)
        XCTAssertEqual(Set(export.attempts.map(\.itemId)), ["v1", "m1"])
        XCTAssertTrue(export.attempts.allSatisfy(\.correct))

        // Mastery was reported per skill domain.
        let wordsMastery = await harness.progressStore.proficiency(for: StandardDomain("words-in-context"))
        XCTAssertGreaterThan(wordsMastery.observationCount, 0)
        XCTAssertEqual(wordsMastery.mastery, 100, accuracy: 0.001)

        // module.attempt telemetry emitted once per evaluated attempt.
        let attemptTelemetry = await harness.telemetryRecorder.attemptCount(module: moduleId)
        XCTAssertEqual(attemptTelemetry, 2)
    }

    // MARK: - Regression: Concurrency Correctness
    //
    // The DrillEngine carries the same suspension-point defects QuizMatchEngine
    // did (spec 6.1 and 6.3 engines share the shape). Each test pins one, and
    // asserts the restructured invariant (state transitions happen before the
    // first await; capture ownership is observable through `isCapturing`)
    // rather than trying to win a timing lottery.

    /// A stop that lands while an answer is being evaluated must not resurrect
    /// the round: no state assignment, no counters, and no attempt record after
    /// the final summary.
    func testStop_duringEvaluation_doesNotResurrectTheEngine() async {
        let moduleId = "drill-stop-during-eval"
        let gate = EngineTestGate()
        let items = [numericItem(id: "m0", answer: "0")]
        let engine = makeEngine(host: gatedDrillContext(moduleId: moduleId, gate: gate)) { items }
        let (log, drain) = drainEvents(engine.events)
        defer { drain.cancel() }

        await engine.start(voice: harness.voiceSession)
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .answerWindowOpened(0) = $0 { return true }; return false }
        })

        let submission = Task { await engine.submitAnswer("0") }
        assertTrueAsync(
            await waitUntil { await gate.waiterCount >= 1 },
            "submitAnswer must be parked inside evaluation before the stop lands"
        )

        await engine.stop()
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .roundEnded = $0 { return true }; return false }
        })

        await gate.open()
        await submission.value

        var state = await engine.state
        XCTAssertEqual(state, .ended, "An evaluation finishing after stop must not reassign state")
        await engine.next()
        state = await engine.state
        XCTAssertEqual(state, .ended, "next() after stop must not present an item on a released session")

        let summaries = await log.snapshot().compactMap { event -> DrillSummary? in
            if case .roundEnded(let summary) = event { return summary }
            return nil
        }
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.answeredItems, 0, "Nothing may score after the final summary")

        try? await Task.sleep(nanoseconds: 200_000_000)
        let export = await harness.progressStore.exportAll(for: moduleId)
        XCTAssertTrue(export.attempts.isEmpty, "No attempt may be written after the final summary")
    }

    /// Two `start()` calls inside the provider window must run ONE round.
    func testStart_calledTwiceInsideTheProviderWindow_runsOneRound() async {
        let gate = EngineTestGate()
        let provider = RecordingDrillItemProvider(
            items: [numericItem(id: "m0", answer: "0")], gate: gate
        )
        let engine = makeEngine(host: drillContext(moduleId: "drill-double-start")) {
            await provider.items()
        }
        let (log, drain) = drainEvents(engine.events)
        defer { drain.cancel() }

        await engine.start(voice: harness.voiceSession)
        let stateAfterStart = await engine.state
        XCTAssertNotEqual(
            stateAfterStart, .idle,
            "start() must leave .idle synchronously, before the provider await"
        )
        assertTrueAsync(await waitUntil { await provider.callCount >= 1 })
        await engine.start(voice: harness.voiceSession)

        await gate.open()
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .answerWindowOpened(0) = $0 { return true }; return false }
        })
        try? await Task.sleep(nanoseconds: 100_000_000)

        let callCount = await provider.callCount
        XCTAssertEqual(callCount, 1, "A second start() must not run a second round")
        let started = await log.snapshot().filter { if case .roundStarted = $0 { return true }; return false }
        XCTAssertEqual(started.count, 1)

        await engine.stop()
    }

    /// Two submissions inside the evaluation window (a typed answer plus a
    /// finalizing utterance) must score once.
    func testSubmitAnswer_calledTwiceInsideTheEvaluationWindow_scoresOnce() async throws {
        let moduleId = "drill-double-submit"
        let gate = EngineTestGate()
        let items = [numericItem(id: "m0", answer: "0")]
        let engine = makeEngine(host: gatedDrillContext(moduleId: moduleId, gate: gate)) { items }
        let (log, drain) = drainEvents(engine.events)
        defer { drain.cancel() }

        await engine.start(voice: harness.voiceSession)
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .answerWindowOpened(0) = $0 { return true }; return false }
        })

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await engine.submitAnswer("0") }
            group.addTask { await engine.submitAnswer("0") }
            group.addTask {
                _ = await waitUntil { await gate.waiterCount >= 1 }
                await gate.open()
            }
        }

        let events = await log.snapshot()
        let judgments = events.compactMap { event -> DrillJudgment? in
            if case .evaluated(_, let judgment) = event { return judgment }
            return nil
        }
        XCTAssertEqual(judgments.count, 1, "One item, one evaluation")
        XCTAssertEqual(judgments.first?.streak, 1, "A doubled streak is the defect this pins")

        try? await Task.sleep(nanoseconds: 250_000_000)
        let export = await harness.progressStore.exportAll(for: moduleId)
        XCTAssertEqual(export.attempts.count, 1, "One item, one attempt record")
        let telemetry = await harness.telemetryRecorder.attemptCount(module: moduleId)
        XCTAssertEqual(telemetry, 1)
    }

    /// `next()` must leave `.feedback` synchronously, so a voice "next" plus a
    /// button tap cannot advance two items.
    func testNext_calledTwice_advancesExactlyOneItem() async {
        let items = (0..<3).map { numericItem(id: "m\($0)", answer: "\($0)") }
        let engine = makeEngine(host: drillContext(moduleId: "drill-double-next")) { items }
        let (log, drain) = drainEvents(engine.events)
        defer { drain.cancel() }

        await engine.start(voice: harness.voiceSession)
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .answerWindowOpened(0) = $0 { return true }; return false }
        })
        await engine.submitAnswer("0")
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .evaluated(0, _) = $0 { return true }; return false }
        })

        await engine.next()
        let stateAfterFirstNext = await engine.state
        XCTAssertEqual(
            stateAfterFirstNext, .presenting(index: 1),
            "next() must leave .feedback synchronously, before the cycle task runs"
        )
        await engine.next()

        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .answerWindowOpened(1) = $0 { return true }; return false }
        })
        try? await Task.sleep(nanoseconds: 100_000_000)
        let presented = await log.snapshot().compactMap { event -> Int? in
            if case .itemPresented(let index, _) = event { return index }
            return nil
        }
        XCTAssertEqual(presented, [0, 1], "No item may be skipped or presented twice")

        await engine.stop()
    }

    /// `stopListening` is authoritative and a stale listen cannot clobber the
    /// live one (cancellation is asynchronous).
    func testCapture_stopListeningIsAuthoritative_andAStaleListenCannotClobber() async {
        let voice = ScriptedVoiceSession()
        let items = [textItem(id: "v0", answer: "clear")]
        let engine = makeEngine(host: drillContext(moduleId: "drill-capture")) { items }
        let (log, drain) = drainEvents(engine.events)
        defer { drain.cancel() }

        await engine.start(voice: voice)
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .answerWindowOpened(0) = $0 { return true }; return false }
        })

        await engine.startListening()
        var capturing = await engine.isCapturing
        XCTAssertTrue(capturing)

        await engine.stopListening()
        capturing = await engine.isCapturing
        XCTAssertFalse(capturing, "stopListening must clear the capture flag synchronously")

        await engine.startListening()
        capturing = await engine.isCapturing
        XCTAssertTrue(capturing, "The restart must not be rejected by a stale isListening")

        try? await Task.sleep(nanoseconds: 150_000_000)
        capturing = await engine.isCapturing
        XCTAssertTrue(capturing, "A stale listen must not orphan the live microphone")

        await voice.enqueueTranscript("clear")
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .answerCaptured = $0 { return true }; return false }
        })
        try? await Task.sleep(nanoseconds: 100_000_000)
        let captured = await log.snapshot().filter {
            if case .answerCaptured = $0 { return true }; return false
        }
        XCTAssertEqual(captured.count, 1, "The orphaned listen must not deliver a transcript")

        await engine.stop()
    }

    /// A pause closes the mic; a resume must open it again.
    func testResume_reopensCaptureInTheAnswerWindow() async {
        let voice = ScriptedVoiceSession()
        let items = [textItem(id: "v0", answer: "clear")]
        let engine = makeEngine(
            host: drillContext(moduleId: "drill-resume"), autoListen: true
        ) { items }
        let (log, drain) = drainEvents(engine.events)
        defer { drain.cancel() }

        await engine.start(voice: voice)
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .listening(0) = $0 { return true }; return false }
        })
        var capturing = await engine.isCapturing
        XCTAssertTrue(capturing)

        await engine.pause()
        capturing = await engine.isCapturing
        XCTAssertFalse(capturing, "pause must close the mic")

        await engine.resume()
        capturing = await engine.isCapturing
        XCTAssertTrue(capturing, "resume must reopen capture in the answer window")

        await engine.stop()
    }

    /// The host scopes its command vocabulary by the ACTIVE module voice state.
    /// No engine ever set one, so that vocabulary was inert in production.
    func testEngine_publishesModuleVoiceStatesToTheSession() async {
        let voice = ScriptedVoiceSession()
        let items = [textItem(id: "v0", answer: "clear")]
        let engine = makeEngine(host: drillContext(moduleId: "drill-voice-states")) { items }
        let (log, drain) = drainEvents(engine.events)
        defer { drain.cancel() }

        await engine.start(voice: voice)
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .answerWindowOpened(0) = $0 { return true }; return false }
        })
        await engine.startListening()
        await engine.submitAnswer("clear")
        await engine.next()
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .roundEnded = $0 { return true }; return false }
        })

        let expected: Set<String> = ["presenting", "answering", "listening", "feedback", "ended"]
        assertTrueAsync(
            await waitUntil {
                let states = await voice.activeStates
                return Set(states.map(\.rawValue)).isSuperset(of: expected)
            },
            "The engine must drive the host's module voice state through every phase"
        )
    }

    /// The attempt trail must be COMPLETE when the terminal event lands: the
    /// writes used to be fire-and-forget, so consumers reading attempts on
    /// `roundEnded` raced them.
    func testRoundEnded_arrivesWithTheAttemptTrailComplete() async {
        let moduleId = "drill-attempt-flush"
        let items = [
            textItem(id: "v1", answer: "clear", skill: "words-in-context"),
            numericItem(id: "m1", answer: "5", skill: "algebra")
        ]
        let engine = makeEngine(items: items, moduleId: moduleId)
        _ = await run(engine: engine, answers: ["clear", "5"])

        // Read IMMEDIATELY, with no polling: that is the guarantee.
        let export = await harness.progressStore.exportAll(for: moduleId)
        XCTAssertEqual(
            export.attempts.count, 2,
            "Every attempt must be written before the terminal event is emitted"
        )
        let telemetry = await harness.telemetryRecorder.attemptCount(module: moduleId)
        XCTAssertEqual(telemetry, 2)
    }

    // MARK: - Scheduling

    func testReviewPolicy_ordersByAscendingMastery() {
        let items = [
            DrillItem(id: "strong", prompt: "", evaluation: spec(), skillTag: "high"),
            DrillItem(id: "weak", prompt: "", evaluation: spec(), skillTag: "low"),
            DrillItem(id: "mid", prompt: "", evaluation: spec(), skillTag: "mid")
        ]
        let mastery = ["high": 90.0, "mid": 50.0, "low": 10.0]
        let ordered = DrillScheduling.order(
            items, policy: .review, masteryForTag: { mastery[$0] ?? 0 }
        )
        XCTAssertEqual(ordered.map(\.id), ["weak", "mid", "strong"])
    }

    func testReviewPolicy_stableForEqualMastery() {
        let items = (0..<3).map {
            DrillItem(id: "i\($0)", prompt: "", evaluation: spec(), skillTag: "same")
        }
        let ordered = DrillScheduling.order(
            items, policy: .review, masteryForTag: { _ in 42 }
        )
        XCTAssertEqual(ordered.map(\.id), ["i0", "i1", "i2"])
    }

    func testFreePolicy_preservesPackOrder() {
        let items = (0..<3).map {
            DrillItem(id: "i\($0)", prompt: "", evaluation: spec(), skillTag: "t\($0)")
        }
        let ordered = DrillScheduling.order(
            items, policy: .free, masteryForTag: { _ in 0 }
        )
        XCTAssertEqual(ordered.map(\.id), ["i0", "i1", "i2"])
    }

    private func spec() -> EvaluationSpec {
        EvaluationSpec(primaryAnswer: "x", strictness: StrictnessProfile(id: "s", level: .standard))
    }
}

// MARK: - Drill Test Seams

/// A drill item provider that counts invocations and parks on a gate, so the
/// double-start race (whose window is exactly that provider await) is a fixed
/// sequence rather than a scheduling accident.
/// ALLOWED: in-memory test seam, not a mock of a paid external API.
actor RecordingDrillItemProvider {
    private(set) var callCount = 0
    private let allItems: [DrillItem]
    private let gate: EngineTestGate?

    init(items: [DrillItem], gate: EngineTestGate? = nil) {
        self.allItems = items
        self.gate = gate
    }

    func items() async -> [DrillItem] {
        callCount += 1
        if let gate {
            await gate.wait()
        }
        return allItems
    }
}
