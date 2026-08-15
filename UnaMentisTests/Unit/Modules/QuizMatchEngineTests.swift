// UnaMentis - Quiz Match Engine Tests
//
// Phase 5 exit criterion (MODULE_SDK_SPEC.md section 13): a second format
// descriptor (the Quiz Bowl NAQT skeleton) parses and plays a basic match
// headlessly in the harness, proving the engine is format-generic:
// - pyramidal power scoring (15 on a buzz before the power mark, 10 after)
// - a -5 neg on a wrong interrupt buzz (and no neg without an interrupt)
// - 3-part bonus totaling
// - match end conditions and final summary
// - the rebound hook passing a dead question to the next participant
//
// Plus the KB-shaped flow (kb-colorado descriptor): conference timing events,
// 5/0 scoring, auto-listen, and the engine's AttemptRecord/mastery emission.
//
// Real over mock: evaluation runs the real DefaultResponseEvaluationService,
// progress the real FileProgressStoreService on a temp root, telemetry the
// recording service. All of that is now the shared ScriptedModuleHost harness
// (UnaMentisTests/Helpers/ModuleTestHarness/), and ScriptedVoiceSession is the
// harness's shared VoiceSession seam. This test drives QuizMatchEngine directly
// through the harness's QuizMatchHostContext; behavior is identical to the
// former inline seam.

import XCTest
@testable import UnaMentis

// MARK: - Engine Tests

final class QuizMatchEngineTests: XCTestCase {

    // MARK: - Harness

    private var harness: ScriptedModuleHost!

    @MainActor
    override func setUp() async throws {
        harness = ScriptedModuleHost.make()
    }

    override func tearDown() {
        harness?.tearDown()
        harness = nil
        super.tearDown()
    }

    private func makeContext(
        moduleId: String = "quiz-match-test"
    ) -> (QuizMatchHostContext, FileProgressStoreService) {
        (harness.quizMatchContext(moduleId: moduleId), harness.progressStore)
    }

    private func spec(_ answer: String) -> EvaluationSpec {
        EvaluationSpec(
            primaryAnswer: answer,
            strictness: StrictnessProfile(id: "kb-standard", level: .standard),
            evaluatorTiers: [.textExact, .textFuzzy]
        )
    }

    private func tossup(
        id: String,
        text: String,
        answer: String,
        powerMarkIndex: Int? = nil,
        bonus: QuizMatchBonus? = nil,
        domain: String? = "science"
    ) -> QuizMatchQuestion {
        QuizMatchQuestion(
            id: id,
            text: text,
            evaluation: spec(answer),
            domain: domain,
            powerMarkIndex: powerMarkIndex,
            bonus: bonus
        )
    }

    private func makeEngine(
        descriptorNamed name: String,
        questions: [QuizMatchQuestion],
        context: QuizMatchHostContext,
        participantCount: Int = 1,
        autoListen: Bool = false
    ) throws -> QuizMatchEngine {
        try makeEngine(
            descriptorNamed: name,
            questionCount: questions.count,
            context: context,
            participantCount: participantCount,
            autoListen: autoListen,
            provider: { index in index < questions.count ? questions[index] : nil }
        )
    }

    /// Engine over an arbitrary provider, so a test can gate or count the
    /// provider's suspension (the double-start and double-advance races both
    /// live inside that await).
    private func makeEngine(
        descriptorNamed name: String,
        questionCount: Int,
        context: QuizMatchHostContext,
        participantCount: Int = 1,
        autoListen: Bool = false,
        provider: @escaping QuizMatchQuestionProvider
    ) throws -> QuizMatchEngine {
        let descriptor = try QuizMatchFormatDescriptor.load(named: name)
        return QuizMatchEngine(
            descriptor: descriptor,
            options: QuizMatchSessionOptions(
                questionCount: questionCount,
                participantCount: participantCount,
                autoListen: autoListen
            ),
            host: context,
            provider: provider
        )
    }

    /// A host context whose evaluation parks on `gate`, so a test can hold the
    /// engine inside `submitAnswer`'s evaluation await.
    private func gatedContext(moduleId: String, gate: EngineTestGate) -> QuizMatchHostContext {
        QuizMatchHostContext(
            moduleId: moduleId,
            evaluation: GatedResponseEvaluationService(gate: gate),
            progress: harness.progressStore,
            telemetry: harness.telemetryRecorder
        )
    }

    /// Await the next event matching the predicate, skipping others (with a
    /// safety cap so a wedged engine fails the test instead of hanging it).
    private func waitFor(
        _ iterator: inout AsyncStream<QuizMatchEvent>.Iterator,
        cap: Int = 500,
        where predicate: (QuizMatchEvent) -> Bool
    ) async throws -> QuizMatchEvent {
        for _ in 0..<cap {
            guard let event = await iterator.next() else { break }
            if predicate(event) { return event }
        }
        struct EventNotSeen: Error {}
        throw EventNotSeen()
    }

    // MARK: - QB Skeleton: Power Scoring

    func testQBSkeleton_powerBuzzScores15_postPowerScores10() async throws {
        let (context, _) = makeContext()
        let voice = ScriptedVoiceSession()
        let questions = [
            tossup(id: "t1", text: String(repeating: "clue ", count: 20),
                   answer: "chlorophyll", powerMarkIndex: 40),
            tossup(id: "t2", text: String(repeating: "clue ", count: 20),
                   answer: "mitochondria", powerMarkIndex: 40)
        ]
        let engine = try makeEngine(
            descriptorNamed: "qb-naqt-skeleton", questions: questions, context: context
        )
        var events = engine.events.makeAsyncIterator()

        // Tossup 1: buzz at character 10, before the power mark at 40.
        await voice.holdSpeaks(1)
        await engine.start(voice: voice)
        _ = try await waitFor(&events) { if case .questionPresented(0, _) = $0 { return true }; return false }
        await engine.buzz(atCharacterIndex: 10)
        _ = try await waitFor(&events) {
            if case .questionReadingFinished(0, let interrupted) = $0 { return interrupted }
            return false
        }
        _ = try await waitFor(&events) { if case .answerWindowOpened(0) = $0 { return true }; return false }
        await engine.submitAnswer("chlorophyll")

        guard case .evaluated(_, let power) = try await waitFor(&events, where: {
            if case .evaluated = $0 { return true }; return false
        }) else { return XCTFail("Expected evaluated event") }
        XCTAssertTrue(power.isCorrect)
        XCTAssertTrue(power.wasInterrupt)
        XCTAssertTrue(power.wasPower, "A buzz before the power mark must be a power")
        XCTAssertEqual(power.pointsAwarded, 15)

        // Tossup 2: buzz at character 100, after the power mark.
        await voice.holdSpeaks(1)
        await engine.next()
        _ = try await waitFor(&events) { if case .questionPresented(1, _) = $0 { return true }; return false }
        await engine.buzz(atCharacterIndex: 100)
        _ = try await waitFor(&events) { if case .answerWindowOpened(1) = $0 { return true }; return false }
        await engine.submitAnswer("mitochondria")

        guard case .evaluated(_, let regular) = try await waitFor(&events, where: {
            if case .evaluated(1, _) = $0 { return true }; return false
        }) else { return XCTFail("Expected evaluated event") }
        XCTAssertTrue(regular.isCorrect)
        XCTAssertTrue(regular.wasInterrupt)
        XCTAssertFalse(regular.wasPower, "A buzz after the power mark must not be a power")
        XCTAssertEqual(regular.pointsAwarded, 10)

        guard case .scoreChanged(let scores) = try await waitFor(&events, where: {
            if case .scoreChanged(let s) = $0 { return s == [25] }; return false
        }) else { return XCTFail("Expected 15 + 10 = 25") }
        XCTAssertEqual(scores, [25])
    }

    // MARK: - QB Skeleton: Interrupt Neg

    func testQBSkeleton_wrongInterruptBuzzNegsMinus5_wrongAfterReadingScoresZero() async throws {
        let (context, _) = makeContext()
        let voice = ScriptedVoiceSession()
        let questions = [
            tossup(id: "t1", text: "Tossup one text", answer: "paris", powerMarkIndex: 8),
            tossup(id: "t2", text: "Tossup two text", answer: "london", powerMarkIndex: 8)
        ]
        let engine = try makeEngine(
            descriptorNamed: "qb-naqt-skeleton", questions: questions, context: context
        )
        var events = engine.events.makeAsyncIterator()

        // Wrong answer on an interrupt buzz: -5.
        await voice.holdSpeaks(1)
        await engine.start(voice: voice)
        _ = try await waitFor(&events) { if case .questionPresented(0, _) = $0 { return true }; return false }
        await engine.buzz(atCharacterIndex: 3)
        _ = try await waitFor(&events) { if case .answerWindowOpened(0) = $0 { return true }; return false }
        await engine.submitAnswer("rome")

        guard case .evaluated(_, let neg) = try await waitFor(&events, where: {
            if case .evaluated = $0 { return true }; return false
        }) else { return XCTFail("Expected evaluated event") }
        XCTAssertFalse(neg.isCorrect)
        XCTAssertTrue(neg.wasInterrupt)
        XCTAssertEqual(neg.pointsAwarded, -5, "A wrong interrupt buzz must neg")

        guard case .scoreChanged(let scores) = try await waitFor(&events, where: {
            if case .scoreChanged = $0 { return true }; return false
        }) else { return XCTFail("Expected scoreChanged event") }
        XCTAssertEqual(scores, [-5])

        // Wrong answer with no interrupt (question read to completion): 0.
        await engine.next()
        _ = try await waitFor(&events) {
            if case .questionReadingFinished(1, let interrupted) = $0 { return !interrupted }
            return false
        }
        _ = try await waitFor(&events) { if case .answerWindowOpened(1) = $0 { return true }; return false }
        await engine.submitAnswer("berlin")

        guard case .evaluated(_, let zero) = try await waitFor(&events, where: {
            if case .evaluated(1, _) = $0 { return true }; return false
        }) else { return XCTFail("Expected evaluated event") }
        XCTAssertFalse(zero.isCorrect)
        XCTAssertFalse(zero.wasInterrupt)
        XCTAssertEqual(zero.pointsAwarded, 0, "No neg without an interrupt")
    }

    // MARK: - QB Skeleton: Bonus Totaling

    func testQBSkeleton_threePartBonusTotals() async throws {
        let (context, _) = makeContext()
        let voice = ScriptedVoiceSession()
        let bonus = QuizMatchBonus(
            leadIn: "This bonus is about planets.",
            parts: [
                .init(text: "Name the red planet.", evaluation: spec("mars")),
                .init(text: "Name the largest planet.", evaluation: spec("jupiter")),
                .init(text: "Name the ringed planet.", evaluation: spec("saturn"))
            ]
        )
        let questions = [
            tossup(id: "t1", text: "Tossup text", answer: "neptune", powerMarkIndex: 5, bonus: bonus)
        ]
        let engine = try makeEngine(
            descriptorNamed: "qb-naqt-skeleton", questions: questions, context: context
        )
        var events = engine.events.makeAsyncIterator()

        // Bonus answers: two right, one wrong. Queued up front; the engine's
        // internal bonus listens consume them in order (auto-listen is off,
        // so the tossup answer window does not race for the queue).
        await voice.enqueueTranscript("mars")
        await voice.enqueueTranscript("neptune")
        await voice.enqueueTranscript("saturn")

        await engine.start(voice: voice)
        _ = try await waitFor(&events) { if case .answerWindowOpened(0) = $0 { return true }; return false }
        await engine.submitAnswer("neptune")

        guard case .bonusStarted(_, let partCount) = try await waitFor(&events, where: {
            if case .bonusStarted = $0 { return true }; return false
        }) else { return XCTFail("Expected bonusStarted") }
        XCTAssertEqual(partCount, 3)

        var partResults: [(correct: Bool, points: Int)] = []
        for _ in 0..<3 {
            guard case .bonusPartEvaluated(_, let correct, let points) = try await waitFor(&events, where: {
                if case .bonusPartEvaluated = $0 { return true }; return false
            }) else { return XCTFail("Expected bonusPartEvaluated") }
            partResults.append((correct, points))
        }
        XCTAssertEqual(partResults.map(\.correct), [true, false, true])
        XCTAssertEqual(partResults.map(\.points), [10, 0, 10])

        guard case .bonusCompleted(let total) = try await waitFor(&events, where: {
            if case .bonusCompleted = $0 { return true }; return false
        }) else { return XCTFail("Expected bonusCompleted") }
        XCTAssertEqual(total, 20, "Two correct parts at 10 each")

        guard case .scoreChanged(let scores) = try await waitFor(&events, where: {
            if case .scoreChanged(let s) = $0 { return s == [30] }; return false
        }) else { return XCTFail("Expected 10 tossup + 20 bonus") }
        XCTAssertEqual(scores, [30])
    }

    // MARK: - QB Skeleton: Match End

    func testQBSkeleton_matchEndsAfterAllTossups_withFinalSummary() async throws {
        let (context, _) = makeContext()
        let voice = ScriptedVoiceSession()
        let questions = [
            tossup(id: "t1", text: "Tossup one", answer: "paris", powerMarkIndex: 3),
            tossup(id: "t2", text: "Tossup two", answer: "london", powerMarkIndex: 3)
        ]
        let engine = try makeEngine(
            descriptorNamed: "qb-naqt-skeleton", questions: questions, context: context
        )
        var events = engine.events.makeAsyncIterator()

        await voice.holdSpeaks(1)
        await engine.start(voice: voice)
        guard case .matchStarted(let total) = try await waitFor(&events, where: {
            if case .matchStarted = $0 { return true }; return false
        }) else { return XCTFail("Expected matchStarted") }
        XCTAssertEqual(total, 2)

        // Q1: power buzz, correct: 15.
        _ = try await waitFor(&events) { if case .questionPresented(0, _) = $0 { return true }; return false }
        await engine.buzz(atCharacterIndex: 0)
        _ = try await waitFor(&events) { if case .answerWindowOpened(0) = $0 { return true }; return false }
        await engine.submitAnswer("paris")
        _ = try await waitFor(&events) { if case .evaluated(0, _) = $0 { return true }; return false }
        await voice.holdSpeaks(1)
        await engine.next()

        // Q2: wrong interrupt: -5.
        _ = try await waitFor(&events) { if case .questionPresented(1, _) = $0 { return true }; return false }
        await engine.buzz(atCharacterIndex: 0)
        _ = try await waitFor(&events) { if case .answerWindowOpened(1) = $0 { return true }; return false }
        await engine.submitAnswer("madrid")
        _ = try await waitFor(&events) { if case .evaluated(1, _) = $0 { return true }; return false }
        await engine.next()

        guard case .matchEnded(let summary) = try await waitFor(&events, where: {
            if case .matchEnded = $0 { return true }; return false
        }) else { return XCTFail("Expected matchEnded") }
        XCTAssertEqual(summary.scores, [10], "15 power - 5 neg")
        XCTAssertEqual(summary.answeredQuestions, 2)
        XCTAssertEqual(summary.correctAnswers, 1)

        let state = await engine.state
        XCTAssertEqual(state, .ended)
    }

    // MARK: - QB Skeleton: Rebound Hook

    func testQBSkeleton_deadTossupReboundsToNextParticipant() async throws {
        let (context, _) = makeContext()
        let voice = ScriptedVoiceSession()
        let questions = [
            tossup(id: "t1", text: "Tossup one", answer: "paris", powerMarkIndex: 3)
        ]
        let engine = try makeEngine(
            descriptorNamed: "qb-naqt-skeleton",
            questions: questions,
            context: context,
            participantCount: 2
        )
        var events = engine.events.makeAsyncIterator()

        await voice.holdSpeaks(1)
        await engine.start(voice: voice)
        _ = try await waitFor(&events) { if case .questionPresented(0, _) = $0 { return true }; return false }

        // Participant 0 negs on an interrupt.
        await engine.buzz(atCharacterIndex: 1, participant: 0)
        _ = try await waitFor(&events) { if case .answerWindowOpened(0) = $0 { return true }; return false }
        await engine.submitAnswer("rome", participant: 0)

        guard case .reboundOffered(let next) = try await waitFor(&events, where: {
            if case .reboundOffered = $0 { return true }; return false
        }) else { return XCTFail("Expected reboundOffered") }
        XCTAssertEqual(next, 1)

        // Participant 1 converts the rebound (no interrupt context: plain 10).
        await engine.submitAnswer("paris", participant: 1)
        guard case .evaluated(_, let judgment) = try await waitFor(&events, where: {
            if case .evaluated(0, let j) = $0 { return j.participant == 1 }; return false
        }) else { return XCTFail("Expected participant 1 evaluation") }
        XCTAssertTrue(judgment.isCorrect)
        XCTAssertFalse(judgment.wasInterrupt)
        XCTAssertEqual(judgment.pointsAwarded, 10)

        guard case .scoreChanged(let scores) = try await waitFor(&events, where: {
            if case .scoreChanged(let s) = $0 { return s.count == 2 && s[1] == 10 }; return false
        }) else { return XCTFail("Expected final scores") }
        XCTAssertEqual(scores, [-5, 10])
    }

    // MARK: - KB Flow on the Same Engine

    func testKBColoradoFlow_conferenceEventsAutoListenAndScoring() async throws {
        let (context, progress) = makeContext(moduleId: "knowledge-bowl-test")
        let voice = ScriptedVoiceSession()
        let questions = [
            tossup(id: "q1", text: "What is the chemical symbol for gold?", answer: "au", domain: "science")
        ]
        let engine = try makeEngine(
            descriptorNamed: "kb-colorado",
            questions: questions,
            context: context,
            autoListen: true
        )
        var events = engine.events.makeAsyncIterator()

        await engine.start(voice: voice)
        _ = try await waitFor(&events) {
            if case .questionReadingFinished(0, let interrupted) = $0 { return !interrupted }
            return false
        }

        // KB's descriptor has a 15 s nonverbal conference; skip it after the
        // first tick like a "Ready to Answer" tap.
        guard case .conferenceStarted(let seconds) = try await waitFor(&events, where: {
            if case .conferenceStarted = $0 { return true }; return false
        }) else { return XCTFail("Expected conferenceStarted") }
        XCTAssertEqual(seconds, 15)

        _ = try await waitFor(&events) { if case .conferenceTick = $0 { return true }; return false }
        await engine.skipConference()
        guard case .conferenceEnded(let skipped) = try await waitFor(&events, where: {
            if case .conferenceEnded = $0 { return true }; return false
        }) else { return XCTFail("Expected conferenceEnded") }
        XCTAssertTrue(skipped)

        // The answer window auto-opens and capture auto-starts (KB behavior).
        _ = try await waitFor(&events) { if case .answerWindowOpened(0) = $0 { return true }; return false }
        _ = try await waitFor(&events) { if case .listeningStarted(0) = $0 { return true }; return false }

        await engine.submitAnswer("au")
        guard case .evaluated(_, let judgment) = try await waitFor(&events, where: {
            if case .evaluated = $0 { return true }; return false
        }) else { return XCTFail("Expected evaluated") }
        XCTAssertTrue(judgment.isCorrect)
        XCTAssertEqual(judgment.pointsAwarded, 5, "Colorado oral scoring is 5 per correct")
        XCTAssertFalse(judgment.wasPower, "KB short form has no powers")

        await engine.next()
        guard case .matchEnded(let summary) = try await waitFor(&events, where: {
            if case .matchEnded = $0 { return true }; return false
        }) else { return XCTFail("Expected matchEnded") }
        XCTAssertEqual(summary.scores, [5])

        // The engine (not the module) emitted the host AttemptRecord.
        try await waitForAttemptCount(1, in: progress, module: "knowledge-bowl-test")
    }

    func testEngine_recordsAttemptAndMasteryThroughHostServices() async throws {
        let (context, progress) = makeContext(moduleId: "attempt-emission-test")
        let voice = ScriptedVoiceSession()
        let questions = [
            tossup(id: "item-42", text: "Tossup", answer: "paris", powerMarkIndex: 3, domain: "geography")
        ]
        let engine = try makeEngine(
            descriptorNamed: "qb-naqt-skeleton", questions: questions, context: context
        )
        var events = engine.events.makeAsyncIterator()

        await engine.start(voice: voice)
        _ = try await waitFor(&events) { if case .answerWindowOpened(0) = $0 { return true }; return false }
        await engine.submitAnswer("paris")
        _ = try await waitFor(&events) { if case .evaluated = $0 { return true }; return false }

        try await waitForAttemptCount(1, in: progress, module: "attempt-emission-test")
        let export = await progress.exportAll(for: "attempt-emission-test")
        let record = try XCTUnwrap(export.attempts.first)
        XCTAssertEqual(record.itemId, "item-42")
        XCTAssertEqual(record.domain, StandardDomain("geography"))
        XCTAssertEqual(record.response, "paris")
        XCTAssertTrue(record.correct)

        let proficiency = await progress.proficiency(for: StandardDomain("geography"))
        XCTAssertEqual(proficiency.observationCount, 1)
        XCTAssertEqual(proficiency.mastery, 100, accuracy: 0.001)
    }

    // MARK: - Regression: Concurrency and Scoring Correctness
    //
    // Each test below pins one verified defect. Where the defect was a race,
    // the engine was restructured so the invariant is assertable directly
    // (state transitions happen before the first await; capture ownership is
    // observable through `isCapturing`), and the test asserts the invariant
    // rather than trying to win a timing lottery.

    /// A stop that lands while an answer is being evaluated must not resurrect
    /// the engine: no state assignment, no scoring, and no attempt record after
    /// the final summary, and no later `next()` on the released session.
    func testStop_duringEvaluation_doesNotResurrectTheEngine() async throws {
        let moduleId = "stop-during-eval"
        let gate = EngineTestGate()
        let engine = try makeEngine(
            descriptorNamed: "qb-naqt-skeleton",
            questions: [tossup(id: "t1", text: "Tossup one", answer: "paris", powerMarkIndex: 3)],
            context: gatedContext(moduleId: moduleId, gate: gate)
        )
        let voice = ScriptedVoiceSession()
        let (log, drain) = drainEvents(engine.events)
        defer { drain.cancel() }

        await voice.holdSpeaks(1)
        await engine.start(voice: voice)
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .questionPresented(0, _) = $0 { return true }; return false }
        })
        await engine.buzz(atCharacterIndex: 1)
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .answerWindowOpened(0) = $0 { return true }; return false }
        })

        let submission = Task { await engine.submitAnswer("paris") }
        assertTrueAsync(
            await waitUntil { await gate.waiterCount >= 1 },
            "submitAnswer must be parked inside evaluation before the stop lands"
        )

        await engine.stop()
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .matchEnded = $0 { return true }; return false } })

        await gate.open()
        await submission.value

        var state = await engine.state
        XCTAssertEqual(state, .ended, "An evaluation finishing after stop must not reassign state")
        await engine.next()
        state = await engine.state
        XCTAssertEqual(state, .ended, "next() after stop must not start a question on a released session")

        let summaries = await log.snapshot().compactMap { event -> QuizMatchSummary? in
            if case .matchEnded(let summary) = event { return summary }
            return nil
        }
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.scores, [0], "Nothing may score after the final summary")
        XCTAssertEqual(summaries.first?.answeredQuestions, 0)

        try? await Task.sleep(nanoseconds: 200_000_000)
        let export = await harness.progressStore.exportAll(for: moduleId)
        XCTAssertTrue(export.attempts.isEmpty, "No attempt may be written after the final summary")
    }

    /// Two `next()` calls inside the provider window (a voice "next" plus a
    /// button tap) must advance exactly one question. The old engine passed
    /// both guards: one question was skipped and the next was presented twice.
    func testNext_calledTwiceInsideTheProviderWindow_advancesExactlyOneQuestion() async throws {
        let (context, _) = makeContext()
        let gate = EngineTestGate()
        let questions = (0..<3).map {
            tossup(id: "t\($0)", text: "Tossup \($0)", answer: "paris", powerMarkIndex: 3)
        }
        let provider = RecordingQuestionProvider(questions: questions, gate: gate, gateFromIndex: 1)
        let engine = try makeEngine(
            descriptorNamed: "qb-naqt-skeleton",
            questionCount: questions.count,
            context: context,
            provider: { index in await provider.question(at: index) }
        )
        let voice = ScriptedVoiceSession()
        let (log, drain) = drainEvents(engine.events)
        defer { drain.cancel() }

        await engine.start(voice: voice)
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .answerWindowOpened(0) = $0 { return true }; return false }
        })
        await engine.submitAnswer("paris")
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .evaluated(0, _) = $0 { return true }; return false }
        })

        await engine.next()
        let stateAfterFirstNext = await engine.state
        XCTAssertEqual(
            stateAfterFirstNext, .readingQuestion(index: 1),
            "next() must leave .feedback synchronously, before the provider await"
        )
        await engine.next()

        await gate.open()
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .questionPresented(1, _) = $0 { return true }; return false }
        })
        try? await Task.sleep(nanoseconds: 100_000_000)

        let requested = await provider.requested
        XCTAssertEqual(requested, [0, 1], "The second next() must not advance a second question")
        let presented = await log.snapshot().compactMap { event -> Int? in
            if case .questionPresented(let index, _) = event { return index }
            return nil
        }
        XCTAssertEqual(presented, [0, 1], "No question may be skipped or presented twice")
    }

    /// Two `start()` calls inside the provider window must run ONE round.
    func testStart_calledTwiceInsideTheProviderWindow_runsOneRound() async throws {
        let (context, _) = makeContext()
        let gate = EngineTestGate()
        let questions = [tossup(id: "t0", text: "Tossup zero", answer: "paris", powerMarkIndex: 3)]
        let provider = RecordingQuestionProvider(questions: questions, gate: gate, gateFromIndex: 0)
        let engine = try makeEngine(
            descriptorNamed: "qb-naqt-skeleton",
            questionCount: questions.count,
            context: context,
            provider: { index in await provider.question(at: index) }
        )
        let voice = ScriptedVoiceSession()
        let (log, drain) = drainEvents(engine.events)
        defer { drain.cancel() }

        await engine.start(voice: voice)
        let stateAfterStart = await engine.state
        XCTAssertNotEqual(
            stateAfterStart, .idle,
            "start() must leave .idle synchronously, before the provider await"
        )
        assertTrueAsync(await waitUntil { await provider.requested.count >= 1 })
        await engine.start(voice: voice)

        await gate.open()
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .answerWindowOpened(0) = $0 { return true }; return false }
        })
        try? await Task.sleep(nanoseconds: 100_000_000)

        let requested = await provider.requested
        XCTAssertEqual(requested, [0], "A second start() must not run a second round")
        let started = await log.snapshot().filter { if case .matchStarted = $0 { return true }; return false }
        XCTAssertEqual(started.count, 1)
    }

    /// Two submissions inside the evaluation window must score once. The old
    /// engine scored both: doubled counts, two attempt records, and a doubled
    /// score delta (-10 instead of -5 on a neg).
    func testSubmitAnswer_calledTwiceInsideTheEvaluationWindow_scoresOnce() async throws {
        let moduleId = "double-submit"
        let gate = EngineTestGate()
        let engine = try makeEngine(
            descriptorNamed: "qb-naqt-skeleton",
            questions: [tossup(id: "t1", text: "Tossup one", answer: "paris", powerMarkIndex: 3)],
            context: gatedContext(moduleId: moduleId, gate: gate)
        )
        let voice = ScriptedVoiceSession()
        let (log, drain) = drainEvents(engine.events)
        defer { drain.cancel() }

        await voice.holdSpeaks(1)
        await engine.start(voice: voice)
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .questionPresented(0, _) = $0 { return true }; return false }
        })
        await engine.buzz(atCharacterIndex: 1)
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .answerWindowOpened(0) = $0 { return true }; return false }
        })

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await engine.submitAnswer("rome") }
            group.addTask { await engine.submitAnswer("rome") }
            group.addTask {
                // Release evaluation once the first submission is parked on it,
                // so a second submission that slipped past the guard would
                // score, exactly as it used to.
                _ = await waitUntil { await gate.waiterCount >= 1 }
                await gate.open()
            }
        }

        let events = await log.snapshot()
        let judgments = events.compactMap { event -> QuizMatchJudgment? in
            if case .evaluated(_, let judgment) = event { return judgment }
            return nil
        }
        XCTAssertEqual(judgments.count, 1, "One question, one evaluation")
        XCTAssertEqual(judgments.first?.pointsAwarded, -5)

        let scores = events.compactMap { event -> [Int]? in
            if case .scoreChanged(let scores) = event { return scores }
            return nil
        }
        XCTAssertEqual(scores.last, [-5], "A doubled neg (-10) is the defect this pins")

        try await waitForAttemptCount(1, in: harness.progressStore, module: moduleId)
        try? await Task.sleep(nanoseconds: 150_000_000)
        let export = await harness.progressStore.exportAll(for: moduleId)
        XCTAssertEqual(export.attempts.count, 1, "One question, one attempt record")
    }

    /// A tossup with NO power mark can never award power, even in a powered
    /// format. The old `?? .max` sentinel paid 15 for every unpowered tossup.
    func testPowerScoring_tossupWithoutAPowerMarkNeverAwardsPower() async throws {
        let (context, _) = makeContext()
        let voice = ScriptedVoiceSession()
        let engine = try makeEngine(
            descriptorNamed: "qb-naqt-skeleton",
            questions: [
                tossup(
                    id: "t1", text: String(repeating: "clue ", count: 20),
                    answer: "chlorophyll", powerMarkIndex: nil
                )
            ],
            context: context
        )
        var events = engine.events.makeAsyncIterator()

        await voice.holdSpeaks(1)
        await engine.start(voice: voice)
        _ = try await waitFor(&events) { if case .questionPresented(0, _) = $0 { return true }; return false }
        await engine.buzz(atCharacterIndex: 3)
        _ = try await waitFor(&events) { if case .answerWindowOpened(0) = $0 { return true }; return false }
        await engine.submitAnswer("chlorophyll")

        guard case .evaluated(_, let judgment) = try await waitFor(&events, where: {
            if case .evaluated = $0 { return true }; return false
        }) else { return XCTFail("Expected evaluated event") }
        XCTAssertTrue(judgment.isCorrect)
        XCTAssertTrue(judgment.wasInterrupt)
        XCTAssertFalse(judgment.wasPower, "A nil power mark must never award power")
        XCTAssertEqual(judgment.pointsAwarded, 10, "Unpowered tossups pay the regular value")
    }

    /// `stopListening` is authoritative and a stale listen cannot clobber the
    /// live one. Cancellation is asynchronous, so both halves matter: the flag
    /// must be cleared by `stopListening` itself (or the rebind is rejected and
    /// the participant gets a dead mic), and the cancelled task must not clear
    /// the flags for the capture that replaced it (or the mic is orphaned).
    func testCapture_stopListeningIsAuthoritative_andAStaleListenCannotClobber() async throws {
        let (context, _) = makeContext()
        let voice = ScriptedVoiceSession()
        let engine = try makeEngine(
            descriptorNamed: "qb-naqt-skeleton",
            questions: [tossup(id: "t1", text: "Tossup one", answer: "paris", powerMarkIndex: 3)],
            context: context
        )
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
        XCTAssertTrue(capturing, "The rebind must not be rejected by a stale isListening")

        // Well past the point where the cancelled listen has noticed.
        try? await Task.sleep(nanoseconds: 150_000_000)
        capturing = await engine.isCapturing
        XCTAssertTrue(capturing, "A stale listen must not orphan the live microphone")

        await voice.enqueueTranscript("paris")
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .answerCaptured = $0 { return true }; return false }
        })
        try? await Task.sleep(nanoseconds: 100_000_000)
        let captured = await log.snapshot().filter {
            if case .answerCaptured = $0 { return true }; return false
        }
        XCTAssertEqual(captured.count, 1, "The orphaned listen must not deliver a transcript")
        capturing = await engine.isCapturing
        XCTAssertFalse(capturing, "A completed capture clears the flag")
    }

    /// Bonus capture must be cancellable. It used to call `voice.listen`
    /// directly, so `stop()` could not end it: the mic stayed live and the
    /// bonus kept scoring after the final summary.
    func testStop_duringBonusCapture_endsTheMatchAndStopsScoring() async throws {
        let (context, _) = makeContext(moduleId: "bonus-cancel")
        let voice = ScriptedVoiceSession()
        let bonus = QuizMatchBonus(
            leadIn: nil,
            parts: [
                .init(text: "Name the red planet.", evaluation: spec("mars")),
                .init(text: "Name the largest planet.", evaluation: spec("jupiter")),
                .init(text: "Name the ringed planet.", evaluation: spec("saturn"))
            ]
        )
        let engine = try makeEngine(
            descriptorNamed: "qb-naqt-skeleton",
            questions: [
                tossup(id: "t1", text: "Tossup text", answer: "neptune", powerMarkIndex: 5, bonus: bonus)
            ],
            context: context
        )
        let (log, drain) = drainEvents(engine.events)
        defer { drain.cancel() }

        await engine.start(voice: voice)
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .answerWindowOpened(0) = $0 { return true }; return false }
        })

        // No bonus transcripts are queued, so bonus capture parks with the mic
        // open, which is exactly the state a watch pause or a stop must break.
        let submission = Task { await engine.submitAnswer("neptune") }
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .bonusPartPresented(0, _) = $0 { return true }; return false }
        })

        await engine.stop()
        assertTrueAsync(
            await waitForEvents(in: log) { events in
                events.contains { if case .matchEnded = $0 { return true }; return false }
            },
            "stop() must cancel the bonus capture instead of waiting on a listen nothing can end"
        )
        await submission.value

        let events = await log.snapshot()
        XCTAssertFalse(
            events.contains { if case .bonusPartEvaluated = $0 { return true }; return false },
            "A stopped match must not keep scoring bonus parts"
        )
        let summaries = events.compactMap { event -> QuizMatchSummary? in
            if case .matchEnded(let summary) = event { return summary }
            return nil
        }
        XCTAssertEqual(summaries.first?.scores, [10], "Only the tossup scored")
        let state = await engine.state
        XCTAssertEqual(state, .ended)
    }

    /// A pause closes the mic; a resume must open it again. The old resume only
    /// emitted `.resumed`, leaving a hands-free learner with a dead microphone.
    func testResume_reopensCaptureInTheAnswerWindow() async throws {
        let (context, _) = makeContext()
        let voice = ScriptedVoiceSession()
        let engine = try makeEngine(
            descriptorNamed: "qb-naqt-skeleton",
            questions: [tossup(id: "t1", text: "Tossup one", answer: "paris", powerMarkIndex: 3)],
            context: context,
            autoListen: true
        )
        let (log, drain) = drainEvents(engine.events)
        defer { drain.cancel() }

        await engine.start(voice: voice)
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .listeningStarted(0) = $0 { return true }; return false }
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

    /// Bonus parts are answered attempts and must reach the ProgressStore and
    /// module.attempt telemetry, not bypass them.
    func testBonusParts_recordAttemptsThroughHostServices() async throws {
        let moduleId = "bonus-attempts"
        let (context, progress) = makeContext(moduleId: moduleId)
        let voice = ScriptedVoiceSession()
        let bonus = QuizMatchBonus(
            leadIn: nil,
            parts: [
                .init(text: "Name the red planet.", evaluation: spec("mars")),
                .init(text: "Name the largest planet.", evaluation: spec("jupiter")),
                .init(text: "Name the ringed planet.", evaluation: spec("saturn"))
            ]
        )
        let engine = try makeEngine(
            descriptorNamed: "qb-naqt-skeleton",
            questions: [
                tossup(id: "t1", text: "Tossup text", answer: "neptune", powerMarkIndex: 5, bonus: bonus)
            ],
            context: context
        )
        var events = engine.events.makeAsyncIterator()

        await voice.enqueueTranscripts(["mars", "neptune", "saturn"])
        await engine.start(voice: voice)
        _ = try await waitFor(&events) { if case .answerWindowOpened(0) = $0 { return true }; return false }
        await engine.submitAnswer("neptune")
        _ = try await waitFor(&events) { if case .bonusCompleted = $0 { return true }; return false }

        try await waitForAttemptCount(4, in: progress, module: moduleId)
        let export = await progress.exportAll(for: moduleId)
        XCTAssertEqual(
            Set(export.attempts.map(\.itemId)),
            ["t1", "t1#bonus0", "t1#bonus1", "t1#bonus2"],
            "The tossup plus every bonus part must be recorded"
        )
        let telemetry = await harness.telemetryRecorder.attemptCount(module: moduleId)
        XCTAssertEqual(telemetry, 4)
    }

    /// `summary.answeredQuestions` counts QUESTIONS, not submissions: a rebound
    /// question answered by two participants counts once.
    func testSummary_countsQuestionsNotSubmissions_acrossARebound() async throws {
        let (context, _) = makeContext()
        let voice = ScriptedVoiceSession()
        let engine = try makeEngine(
            descriptorNamed: "qb-naqt-skeleton",
            questions: [tossup(id: "t1", text: "Tossup one", answer: "paris", powerMarkIndex: 3)],
            context: context,
            participantCount: 2
        )
        var events = engine.events.makeAsyncIterator()

        await voice.holdSpeaks(1)
        await engine.start(voice: voice)
        _ = try await waitFor(&events) { if case .questionPresented(0, _) = $0 { return true }; return false }
        await engine.buzz(atCharacterIndex: 1, participant: 0)
        _ = try await waitFor(&events) { if case .answerWindowOpened(0) = $0 { return true }; return false }
        await engine.submitAnswer("rome", participant: 0)
        _ = try await waitFor(&events) { if case .reboundOffered = $0 { return true }; return false }
        await engine.submitAnswer("paris", participant: 1)
        _ = try await waitFor(&events) {
            if case .evaluated(0, let judgment) = $0 { return judgment.participant == 1 }
            return false
        }

        await engine.next()
        guard case .matchEnded(let summary) = try await waitFor(&events, where: {
            if case .matchEnded = $0 { return true }; return false
        }) else { return XCTFail("Expected matchEnded") }
        XCTAssertEqual(
            summary.answeredQuestions, 1,
            "Two submissions on one rebound question are still one answered question"
        )
        XCTAssertEqual(summary.correctAnswers, 1)
    }

    /// The host scopes its command vocabulary by the ACTIVE module voice state.
    /// No engine ever set one, so that vocabulary was inert in production: the
    /// session never learned which phase the activity was in.
    func testEngine_publishesModuleVoiceStatesToTheSession() async throws {
        let (context, _) = makeContext()
        let voice = ScriptedVoiceSession()
        let engine = try makeEngine(
            descriptorNamed: "qb-naqt-skeleton",
            questions: [tossup(id: "t1", text: "Tossup one", answer: "paris", powerMarkIndex: 3)],
            context: context
        )
        let (log, drain) = drainEvents(engine.events)
        defer { drain.cancel() }

        await engine.start(voice: voice)
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .answerWindowOpened(0) = $0 { return true }; return false }
        })
        await engine.startListening()
        await engine.submitAnswer("paris")
        await engine.next()
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .matchEnded = $0 { return true }; return false }
        })

        let expected: Set<String> = ["reading", "answering", "listening", "feedback", "ended"]
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
    /// `matchEnded` raced them.
    func testMatchEnded_arrivesWithTheAttemptTrailComplete() async throws {
        let moduleId = "attempt-flush"
        let (context, progress) = makeContext(moduleId: moduleId)
        let voice = ScriptedVoiceSession()
        let questions = [
            tossup(id: "t1", text: "Tossup one", answer: "paris", powerMarkIndex: 3),
            tossup(id: "t2", text: "Tossup two", answer: "london", powerMarkIndex: 3)
        ]
        let engine = try makeEngine(
            descriptorNamed: "qb-naqt-skeleton", questions: questions, context: context
        )
        var events = engine.events.makeAsyncIterator()

        await engine.start(voice: voice)
        _ = try await waitFor(&events) { if case .answerWindowOpened(0) = $0 { return true }; return false }
        await engine.submitAnswer("paris")
        _ = try await waitFor(&events) { if case .evaluated(0, _) = $0 { return true }; return false }
        await engine.next()
        _ = try await waitFor(&events) { if case .answerWindowOpened(1) = $0 { return true }; return false }
        await engine.submitAnswer("london")
        _ = try await waitFor(&events) { if case .evaluated(1, _) = $0 { return true }; return false }
        await engine.next()
        _ = try await waitFor(&events) { if case .matchEnded = $0 { return true }; return false }

        // Read IMMEDIATELY, with no polling: that is the guarantee.
        let export = await progress.exportAll(for: moduleId)
        XCTAssertEqual(
            export.attempts.count, 2,
            "Every attempt must be written before the terminal event is emitted"
        )
        let telemetry = await harness.telemetryRecorder.attemptCount(module: moduleId)
        XCTAssertEqual(telemetry, 2)
    }

    // MARK: - Helpers

    /// The engine's attempt emission is flushed before the terminal event, but
    /// mid-run readers still poll.
    private func waitForAttemptCount(
        _ expected: Int,
        in progress: FileProgressStoreService,
        module: String
    ) async throws {
        for _ in 0..<100 {
            let export = await progress.exportAll(for: module)
            if export.attempts.count >= expected { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Expected \(expected) attempt(s) for \(module) in the progress store")
    }
}

// MARK: - Shared Engine Test Seams
//
// Deterministic seams for the engine concurrency regressions. They are
// in-memory doubles of HOST services (the ScriptedVoiceSession pattern), not
// mocks of a paid external API. They live here rather than in a new file
// because DrillEngineTests and OralExamEngineTests drive the same seams and the
// shared harness directory is owned elsewhere.

/// A gate a test parks an engine on, turning a race (a stop landing during
/// evaluation, two submissions inside the evaluation window, a pause arriving
/// while the examiner is thinking) into a fixed sequence.
/// ALLOWED: in-memory test seam, not a mock of a paid external API.
actor EngineTestGate {
    private var isOpen = false

    /// How many callers have parked on this gate so far.
    private(set) var waiterCount = 0

    func open() {
        isOpen = true
    }

    /// Park until the gate opens. Cancellation releases the waiter too, so a
    /// test can prove that cancelling an in-flight host call (a stop during
    /// rubric assembly) actually unblocks the engine.
    func wait() async {
        waiterCount += 1
        while !isOpen && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

/// The real evaluation algorithm, parked on a gate, so a test can hold an
/// engine inside `submitAnswer`'s evaluation await for as long as it needs.
/// ALLOWED: in-memory host seam, not a mock of a paid external API.
struct GatedResponseEvaluationService: ResponseEvaluationService {
    let gate: EngineTestGate

    /// No rubric evaluator: these tests judge text answers only, and the
    /// evaluator must never reach an LLM.
    private let real = DefaultResponseEvaluationService(rubricEvaluator: nil)

    var availableEvaluators: Set<EvaluatorKind> { real.availableEvaluators }

    func evaluate(_ response: LearnerResponse, against spec: EvaluationSpec) async -> EvaluationResult {
        await gate.wait()
        return await real.evaluate(response, against: spec)
    }
}

/// A question provider that records every index the engine asked for and can
/// park on a gate from a chosen index onward. Both the double-start and the
/// double-advance races live inside that provider await, so the recorded index
/// list is the direct evidence.
/// ALLOWED: in-memory test seam, not a mock of a paid external API.
actor RecordingQuestionProvider {
    private(set) var requested: [Int] = []
    private let questions: [QuizMatchQuestion]
    private let gate: EngineTestGate?
    private let gateFromIndex: Int

    init(questions: [QuizMatchQuestion], gate: EngineTestGate? = nil, gateFromIndex: Int = .max) {
        self.questions = questions
        self.gate = gate
        self.gateFromIndex = gateFromIndex
    }

    func question(at index: Int) async -> QuizMatchQuestion? {
        requested.append(index)
        if let gate, index >= gateFromIndex {
            await gate.wait()
        }
        return index < questions.count ? questions[index] : nil
    }
}

/// Drains an engine event stream into an inspectable buffer, so tests poll with
/// a real timeout instead of blocking on `iterator.next()`: a wedged engine
/// must FAIL the test, not hang the suite.
/// ALLOWED: in-memory test seam, not a mock of a paid external API.
actor EngineEventLog<Event: Sendable> {
    private var events: [Event] = []

    func append(_ event: Event) {
        events.append(event)
    }

    func snapshot() -> [Event] {
        events
    }
}

/// Start draining `stream`. Cancel the returned task in the test's teardown.
func drainEvents<Event: Sendable>(
    _ stream: AsyncStream<Event>
) -> (EngineEventLog<Event>, Task<Void, Never>) {
    let log = EngineEventLog<Event>()
    let task = Task {
        for await event in stream {
            await log.append(event)
        }
    }
    return (log, task)
}

/// Poll `log` until `predicate` holds over the events seen so far.
@discardableResult
func waitForEvents<Event: Sendable>(
    in log: EngineEventLog<Event>,
    timeout: TimeInterval = 5,
    until predicate: @Sendable ([Event]) -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate(await log.snapshot()) { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return predicate(await log.snapshot())
}

/// Poll `condition` until it holds or the timeout expires.
@discardableResult
func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}
