// UnaMentis - Quiz Bowl Engine Tests
// Proves the Quiz Bowl module's format descriptors and content map correctly
// onto the generic QuizMatchEngine and score by the format's rules:
// - the full qb-naqt.json descriptor loads with the exact NAQT values
// - a scripted NAQT match verifies 15 (power), 10 (regular correct), and -5 (neg)
// - a 3-part bonus totals correctly
// - the ACF, IHBB Europe, and UK Schools' Challenge descriptors load and express
//   their scoring tables (no powers and a neg for ACF; short form for UK)
//
// Real over mock: evaluation runs the real DefaultResponseEvaluationService,
// progress the real FileProgressStoreService on a temp root, driven through the
// shared ScriptedModuleHost harness, exactly as QuizMatchEngineTests does.

import XCTest
@testable import UnaMentis

final class QuizBowlEngineTests: XCTestCase {
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

    // MARK: Helpers

    private func context() -> QuizMatchHostContext {
        harness.quizMatchContext(moduleId: "quiz-bowl")
    }

    private func makeEngine(
        descriptorNamed name: String,
        questions: [QuizMatchQuestion],
        autoListen: Bool = false
    ) throws -> QuizMatchEngine {
        let descriptor = try QuizMatchFormatDescriptor.load(named: name)
        return QuizMatchEngine(
            descriptor: descriptor,
            options: QuizMatchSessionOptions(
                questionCount: questions.count, participantCount: 1, autoListen: autoListen
            ),
            host: context(),
            provider: { index in index < questions.count ? questions[index] : nil }
        )
    }

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

    // MARK: Descriptor Loading

    func testQBNAQTDescriptor_loadsWithNAQTRules() throws {
        let d = try QuizMatchFormatDescriptor.load(named: "qb-naqt")
        XCTAssertEqual(d.formatId, "qb-naqt")
        XCTAssertEqual(d.phases, [.oral])
        XCTAssertEqual(d.buzz.mode, .individual)
        XCTAssertTrue(d.buzz.lockout)
        XCTAssertEqual(d.scoring.correct, 10)
        XCTAssertEqual(d.scoring.power, 15)
        XCTAssertEqual(d.scoring.incorrect, -5)
        XCTAssertEqual(d.scoring.bonus?.partCount, 3)
        XCTAssertEqual(d.scoring.bonus?.pointsPerPart, 10)
        XCTAssertEqual(d.questionForm, .pyramidal)
        XCTAssertEqual(d.oral?.questions, 24)
        XCTAssertEqual(d.oral?.answerTimeoutSec, 5)
        XCTAssertNil(d.conference)
    }

    func testQBACFDescriptor_hasNegsButNoPowers() throws {
        let d = try QuizMatchFormatDescriptor.load(named: "qb-acf")
        XCTAssertEqual(d.scoring.correct, 10)
        XCTAssertNil(d.scoring.power, "ACF packets have no power marks")
        XCTAssertEqual(d.scoring.incorrect, -5, "ACF negs a wrong interrupt 5 points")
        XCTAssertEqual(d.oral?.questions, 20)
        XCTAssertEqual(d.questionForm, .pyramidal)
    }

    func testIHBBEuropeDescriptor_isNAQTLikeWithoutPowers() throws {
        let d = try QuizMatchFormatDescriptor.load(named: "ihbb-europe")
        XCTAssertEqual(d.buzz.mode, .individual)
        XCTAssertEqual(d.scoring.correct, 10)
        XCTAssertEqual(d.scoring.incorrect, -5)
        XCTAssertNil(d.scoring.power, "IHBB standard bowl has no powers")
        XCTAssertEqual(d.scoring.bonus?.partCount, 3)
        XCTAssertEqual(d.questionForm, .pyramidal)
    }

    func testUKSchoolsChallengeDescriptor_isShortFormStarters() throws {
        let d = try QuizMatchFormatDescriptor.load(named: "uk-schools-challenge")
        XCTAssertEqual(d.questionForm, .short, "Starters are short questions, not pyramidal")
        XCTAssertEqual(d.buzz.mode, .individual)
        XCTAssertFalse(d.buzz.lockout)
        XCTAssertEqual(d.scoring.correct, 10)
        XCTAssertEqual(d.scoring.incorrect, -5, "A wrong starter interrupt costs 5")
        XCTAssertNil(d.scoring.power)
        XCTAssertEqual(d.scoring.bonus?.partCount, 3)
        XCTAssertEqual(d.scoring.bonus?.pointsPerPart, 5)
    }

    // MARK: Scripted NAQT Match: 15 / 10 / -5

    func testNAQTMatch_powerThenRegularThenNeg_scoresCorrectly() async throws {
        let voice = ScriptedVoiceSession()
        let questions = [
            QBQuestionMapper.engineQuestion(from: QBItem(
                id: "n1", text: String(repeating: "clue ", count: 30),
                answer: QBAnswer(primary: "chlorophyll"), domain: "science", powerMarkIndex: 40
            )),
            QBQuestionMapper.engineQuestion(from: QBItem(
                id: "n2", text: String(repeating: "clue ", count: 30),
                answer: QBAnswer(primary: "mitochondria"), domain: "science", powerMarkIndex: 40
            )),
            QBQuestionMapper.engineQuestion(from: QBItem(
                id: "n3", text: String(repeating: "clue ", count: 30),
                answer: QBAnswer(primary: "ribosome"), domain: "science", powerMarkIndex: 40
            ))
        ]
        let engine = try makeEngine(descriptorNamed: "qb-naqt", questions: questions)
        var events = engine.events.makeAsyncIterator()

        // Q1: power buzz (index 10, before power mark 40), correct -> 15.
        await voice.holdSpeaks(1)
        await engine.start(voice: voice)
        _ = try await waitFor(&events) { if case .questionPresented(0, _) = $0 { return true }; return false }
        await engine.buzz(atCharacterIndex: 10)
        _ = try await waitFor(&events) { if case .answerWindowOpened(0) = $0 { return true }; return false }
        await engine.submitAnswer("chlorophyll")
        guard case .evaluated(_, let power) = try await waitFor(&events, where: {
            if case .evaluated = $0 { return true }; return false
        }) else { return XCTFail("Expected evaluated") }
        XCTAssertTrue(power.wasPower)
        XCTAssertEqual(power.pointsAwarded, 15)

        // Q2: regular buzz (index 100, after power mark), correct -> 10.
        await voice.holdSpeaks(1)
        await engine.next()
        _ = try await waitFor(&events) { if case .questionPresented(1, _) = $0 { return true }; return false }
        await engine.buzz(atCharacterIndex: 100)
        _ = try await waitFor(&events) { if case .answerWindowOpened(1) = $0 { return true }; return false }
        await engine.submitAnswer("mitochondria")
        guard case .evaluated(_, let regular) = try await waitFor(&events, where: {
            if case .evaluated(1, _) = $0 { return true }; return false
        }) else { return XCTFail("Expected evaluated") }
        XCTAssertFalse(regular.wasPower)
        XCTAssertEqual(regular.pointsAwarded, 10)

        // Q3: wrong interrupt buzz -> -5.
        await voice.holdSpeaks(1)
        await engine.next()
        _ = try await waitFor(&events) { if case .questionPresented(2, _) = $0 { return true }; return false }
        await engine.buzz(atCharacterIndex: 5)
        _ = try await waitFor(&events) { if case .answerWindowOpened(2) = $0 { return true }; return false }
        await engine.submitAnswer("wrong answer")
        guard case .evaluated(_, let neg) = try await waitFor(&events, where: {
            if case .evaluated(2, _) = $0 { return true }; return false
        }) else { return XCTFail("Expected evaluated") }
        XCTAssertFalse(neg.isCorrect)
        XCTAssertTrue(neg.wasInterrupt)
        XCTAssertEqual(neg.pointsAwarded, -5)

        // Final score: 15 + 10 - 5 = 20.
        await engine.next()
        guard case .matchEnded(let summary) = try await waitFor(&events, where: {
            if case .matchEnded = $0 { return true }; return false
        }) else { return XCTFail("Expected matchEnded") }
        XCTAssertEqual(summary.scores, [20], "15 power + 10 regular - 5 neg")
        XCTAssertEqual(summary.correctAnswers, 2)
    }

    // MARK: Bonus Totaling

    func testNAQTMatch_threePartBonusTotals() async throws {
        let voice = ScriptedVoiceSession()
        let item = QBItem(
            id: "b1", text: "Tossup with a bonus.",
            answer: QBAnswer(primary: "neptune"), domain: "science", powerMarkIndex: 3,
            bonus: QBBonusItem(
                leadIn: "Answer these about planets.",
                parts: [
                    .init(text: "Red planet?", answer: QBAnswer(primary: "mars")),
                    .init(text: "Largest planet?", answer: QBAnswer(primary: "jupiter")),
                    .init(text: "Ringed planet?", answer: QBAnswer(primary: "saturn"))
                ]
            )
        )
        let engine = try makeEngine(
            descriptorNamed: "qb-naqt",
            questions: [QBQuestionMapper.engineQuestion(from: item)]
        )
        var events = engine.events.makeAsyncIterator()

        // Two correct bonus parts, one wrong.
        await voice.enqueueTranscript("mars")
        await voice.enqueueTranscript("neptune")
        await voice.enqueueTranscript("saturn")

        await engine.start(voice: voice)
        _ = try await waitFor(&events) { if case .answerWindowOpened(0) = $0 { return true }; return false }
        await engine.submitAnswer("neptune")

        guard case .bonusCompleted(let total) = try await waitFor(&events, where: {
            if case .bonusCompleted = $0 { return true }; return false
        }) else { return XCTFail("Expected bonusCompleted") }
        XCTAssertEqual(total, 20, "Two correct parts at 10 each")

        // Tossup 10 (no power, buzzed after) plus 20 bonus = 30.
        guard case .scoreChanged(let scores) = try await waitFor(&events, where: {
            if case .scoreChanged(let s) = $0 { return s == [30] }; return false
        }) else { return XCTFail("Expected 10 + 20 = 30") }
        XCTAssertEqual(scores, [30])
    }

    // MARK: ACF: negs, no powers

    func testACFMatch_wrongInterruptNegs() async throws {
        let voice = ScriptedVoiceSession()
        let item = QBQuestionMapper.engineQuestion(from: QBItem(
            id: "acf1", text: "Tossup text here.",
            answer: QBAnswer(primary: "paris"), domain: "geography", powerMarkIndex: 5
        ))
        let engine = try makeEngine(descriptorNamed: "qb-acf", questions: [item])
        var events = engine.events.makeAsyncIterator()

        await voice.holdSpeaks(1)
        await engine.start(voice: voice)
        _ = try await waitFor(&events) { if case .questionPresented(0, _) = $0 { return true }; return false }
        await engine.buzz(atCharacterIndex: 2)
        _ = try await waitFor(&events) { if case .answerWindowOpened(0) = $0 { return true }; return false }
        await engine.submitAnswer("london")
        guard case .evaluated(_, let judgment) = try await waitFor(&events, where: {
            if case .evaluated = $0 { return true }; return false
        }) else { return XCTFail("Expected evaluated") }
        XCTAssertFalse(judgment.isCorrect)
        XCTAssertTrue(judgment.wasInterrupt)
        XCTAssertEqual(judgment.pointsAwarded, -5, "ACF negs a wrong interrupt 5 points")
    }
}
