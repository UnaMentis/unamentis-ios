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
        let descriptor = try QuizMatchFormatDescriptor.load(named: name)
        return QuizMatchEngine(
            descriptor: descriptor,
            options: QuizMatchSessionOptions(
                questionCount: questions.count,
                participantCount: participantCount,
                autoListen: autoListen
            ),
            host: context,
            provider: { index in index < questions.count ? questions[index] : nil }
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

    // MARK: - Helpers

    /// The engine's attempt emission is fire-and-forget; poll briefly.
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
