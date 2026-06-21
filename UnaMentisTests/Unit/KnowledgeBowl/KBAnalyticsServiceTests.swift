//
//  KBAnalyticsServiceTests.swift
//  UnaMentisTests
//
//  Real tests for KBAnalyticsService and its value types.
//  Uses a real KBSessionStore with real KBSession data (no mocks).
//  KBAnalyticsService has no external paid dependencies, so everything here
//  exercises production code end to end.
//

import XCTest
@testable import UnaMentis

@available(iOS 18.0, *)
final class KBAnalyticsServiceTests: XCTestCase {

    // Real on-device session store. The analytics service reads from it.
    private var store: KBSessionStore!
    private var service: KBAnalyticsService!

    override func setUp() async throws {
        try await super.setUp()
        store = KBSessionStore()
        // The store persists to the shared Documents directory and loadAll()
        // reads every file there. Clear it so each test starts from a known,
        // empty state and prior runs cannot leak in.
        try await store.deleteAll()
        service = KBAnalyticsService(sessionStore: store)
    }

    override func tearDown() async throws {
        // Leave the store clean for the next test and for the app.
        try? await store.deleteAll()
        service = nil
        store = nil
        try await super.tearDown()
    }

    // MARK: - Test Helpers

    private func makeConfig(
        region: KBRegion = .colorado,
        roundType: KBRoundType = .written,
        questionCount: Int = 10
    ) -> KBSessionConfig {
        KBSessionConfig(
            region: region,
            roundType: roundType,
            questionCount: questionCount,
            timeLimit: nil,
            domains: nil,
            domainWeights: nil,
            difficulty: nil,
            gradeLevel: nil
        )
    }

    private func makeAttempt(
        domain: KBDomain,
        wasCorrect: Bool,
        responseTime: TimeInterval = 5.0,
        roundType: KBRoundType = .written
    ) -> KBQuestionAttempt {
        KBQuestionAttempt(
            questionId: UUID(),
            domain: domain,
            responseTime: responseTime,
            wasCorrect: wasCorrect,
            pointsEarned: wasCorrect ? 1 : 0,
            roundType: roundType
        )
    }

    /// Build and persist a completed session with the given attempts.
    @discardableResult
    private func saveSession(
        roundType: KBRoundType = .written,
        region: KBRegion = .colorado,
        endTime: Date = Date(),
        attempts: [KBQuestionAttempt]
    ) async throws -> KBSession {
        var session = KBSession(config: makeConfig(region: region, roundType: roundType))
        session.attempts = attempts
        session.endTime = endTime
        session.isComplete = true
        try await store.save(session)
        return session
    }

    /// Convenience: create N attempts in a single domain with a given number correct.
    private func attempts(
        domain: KBDomain,
        total: Int,
        correct: Int,
        responseTime: TimeInterval = 5.0,
        roundType: KBRoundType = .written
    ) -> [KBQuestionAttempt] {
        precondition(correct <= total)
        var result: [KBQuestionAttempt] = []
        for index in 0..<total {
            result.append(makeAttempt(
                domain: domain,
                wasCorrect: index < correct,
                responseTime: responseTime,
                roundType: roundType
            ))
        }
        return result
    }

    // MARK: - Domain Performance

    func testGetDomainPerformance_withNoSessions_returnsEmpty() async throws {
        let performance = try await service.getDomainPerformance()
        XCTAssertTrue(performance.isEmpty)
    }

    func testGetDomainPerformance_aggregatesAcrossSessions() async throws {
        // Two sessions, both touching Science. 6 correct of 10 total combined.
        try await saveSession(attempts: attempts(domain: .science, total: 6, correct: 4))
        try await saveSession(attempts: attempts(domain: .science, total: 4, correct: 2))

        let performance = try await service.getDomainPerformance()

        let science = try XCTUnwrap(performance[.science])
        XCTAssertEqual(science.totalQuestions, 10)
        XCTAssertEqual(science.correctAnswers, 6)
        XCTAssertEqual(science.accuracy, 0.6, accuracy: 0.0001)
    }

    func testGetDomainPerformance_computesAverageResponseTime() async throws {
        // 4 questions at 2.0s and 4 at 6.0s should average to 4.0s.
        try await saveSession(attempts: attempts(domain: .mathematics, total: 4, correct: 2, responseTime: 2.0))
        try await saveSession(attempts: attempts(domain: .mathematics, total: 4, correct: 2, responseTime: 6.0))

        let performance = try await service.getDomainPerformance()

        let math = try XCTUnwrap(performance[.mathematics])
        XCTAssertEqual(math.totalQuestions, 8)
        XCTAssertEqual(math.averageResponseTime, 4.0, accuracy: 0.0001)
    }

    func testGetDomainPerformance_ignoresIncompleteSessions() async throws {
        // An incomplete session must not contribute to analytics.
        var incomplete = KBSession(config: makeConfig())
        incomplete.attempts = attempts(domain: .history, total: 5, correct: 5)
        incomplete.isComplete = false
        try await store.save(incomplete)

        let performance = try await service.getDomainPerformance()
        XCTAssertNil(performance[.history])
    }

    func testGetDomainPerformance_separatesDomains() async throws {
        try await saveSession(attempts:
            attempts(domain: .science, total: 4, correct: 3) +
            attempts(domain: .literature, total: 2, correct: 0)
        )

        let performance = try await service.getDomainPerformance()

        XCTAssertEqual(performance[.science]?.totalQuestions, 4)
        XCTAssertEqual(performance[.science]?.correctAnswers, 3)
        XCTAssertEqual(performance[.literature]?.totalQuestions, 2)
        XCTAssertEqual(performance[.literature]?.correctAnswers, 0)
    }

    // MARK: - Weak / Strong Domains

    func testGetWeakDomains_flagsLowAccuracyWithEnoughQuestions() async throws {
        // Science: 3/10 = 30% accuracy with 10 questions -> weak.
        try await saveSession(attempts: attempts(domain: .science, total: 10, correct: 3))

        let weak = try await service.getWeakDomains()
        XCTAssertEqual(weak, [.science])
    }

    func testGetWeakDomains_ignoresDomainsBelowQuestionThreshold() async throws {
        // 0/9 = 0% accuracy but only 9 questions -> below the 10-question floor.
        try await saveSession(attempts: attempts(domain: .science, total: 9, correct: 0))

        let weak = try await service.getWeakDomains()
        XCTAssertTrue(weak.isEmpty)
    }

    func testGetWeakDomains_ignoresAccuracyAtOrAboveFiftyPercent() async throws {
        // Exactly 50% should not be flagged as weak (filter uses < 0.5).
        try await saveSession(attempts: attempts(domain: .science, total: 10, correct: 5))

        let weak = try await service.getWeakDomains()
        XCTAssertTrue(weak.isEmpty)
    }

    func testGetWeakDomains_sortedByDisplayName() async throws {
        // Mathematics (display "Mathematics") and Science (display "Science").
        // Both weak; result must be sorted alphabetically by display name.
        try await saveSession(attempts:
            attempts(domain: .science, total: 10, correct: 2) +
            attempts(domain: .mathematics, total: 10, correct: 1)
        )

        let weak = try await service.getWeakDomains()
        XCTAssertEqual(weak, [.mathematics, .science])
    }

    func testGetStrongDomains_flagsHighAccuracyWithEnoughQuestions() async throws {
        // History: 9/10 = 90% with 10 questions -> strong.
        try await saveSession(attempts: attempts(domain: .history, total: 10, correct: 9))

        let strong = try await service.getStrongDomains()
        XCTAssertEqual(strong, [.history])
    }

    func testGetStrongDomains_ignoresAccuracyBelowEightyPercent() async throws {
        // 79% accuracy: 79/100 is below the 0.8 threshold.
        try await saveSession(attempts: attempts(domain: .history, total: 100, correct: 79))

        let strong = try await service.getStrongDomains()
        XCTAssertTrue(strong.isEmpty)
    }

    func testGetStrongDomains_includesExactlyEightyPercent() async throws {
        // Exactly 80% should be flagged (filter uses >= 0.8).
        try await saveSession(attempts: attempts(domain: .history, total: 10, correct: 8))

        let strong = try await service.getStrongDomains()
        XCTAssertEqual(strong, [.history])
    }

    // MARK: - Round Type Comparison

    func testGetRoundTypeComparison_withNoSessions_returnsZeros() async throws {
        let comparison = try await service.getRoundTypeComparison()

        XCTAssertEqual(comparison.writtenAccuracy, 0)
        XCTAssertEqual(comparison.oralAccuracy, 0)
        XCTAssertEqual(comparison.writtenQuestions, 0)
        XCTAssertEqual(comparison.oralQuestions, 0)
    }

    func testGetRoundTypeComparison_separatesWrittenAndOral() async throws {
        // Written: 8/10 correct. Oral: 3/6 correct.
        try await saveSession(
            roundType: .written,
            attempts: attempts(domain: .science, total: 10, correct: 8, roundType: .written)
        )
        try await saveSession(
            roundType: .oral,
            attempts: attempts(domain: .science, total: 6, correct: 3, roundType: .oral)
        )

        let comparison = try await service.getRoundTypeComparison()

        XCTAssertEqual(comparison.writtenQuestions, 10)
        XCTAssertEqual(comparison.writtenAccuracy, 0.8, accuracy: 0.0001)
        XCTAssertEqual(comparison.oralQuestions, 6)
        XCTAssertEqual(comparison.oralAccuracy, 0.5, accuracy: 0.0001)
    }

    // MARK: - Accuracy Trend

    func testGetAccuracyTrend_groupsByDayAndSorts() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: today)!

        // Older day: 2/4 = 50%.
        try await saveSession(
            endTime: twoDaysAgo,
            attempts: attempts(domain: .science, total: 4, correct: 2)
        )
        // Today: 3/3 = 100%.
        try await saveSession(
            endTime: today,
            attempts: attempts(domain: .science, total: 3, correct: 3)
        )

        let trend = try await service.getAccuracyTrend(days: 30)

        XCTAssertEqual(trend.count, 2)
        // Sorted ascending by date, so the older day comes first.
        XCTAssertLessThan(trend[0].date, trend[1].date)
        XCTAssertEqual(trend[0].accuracy, 0.5, accuracy: 0.0001)
        XCTAssertEqual(trend[0].questionsAnswered, 4)
        XCTAssertEqual(trend[1].accuracy, 1.0, accuracy: 0.0001)
        XCTAssertEqual(trend[1].questionsAnswered, 3)
    }

    func testGetAccuracyTrend_excludesSessionsBeyondCutoff() async throws {
        let calendar = Calendar.current
        let old = calendar.date(byAdding: .day, value: -40, to: Date())!
        let recent = calendar.date(byAdding: .day, value: -1, to: Date())!

        try await saveSession(endTime: old, attempts: attempts(domain: .science, total: 5, correct: 5))
        try await saveSession(endTime: recent, attempts: attempts(domain: .science, total: 5, correct: 1))

        // A 30-day window must drop the 40-day-old session.
        let trend = try await service.getAccuracyTrend(days: 30)

        XCTAssertEqual(trend.count, 1)
        XCTAssertEqual(trend[0].accuracy, 0.2, accuracy: 0.0001)
    }

    func testGetAccuracyTrend_combinesSessionsOnSameDay() async throws {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date()).addingTimeInterval(9 * 3600)
        let laterSameDay = day.addingTimeInterval(3 * 3600)

        // Two sessions on the same calendar day should be combined:
        // (4 + 6) correct of (10 + 10) total = 50%.
        try await saveSession(endTime: day, attempts: attempts(domain: .science, total: 10, correct: 4))
        try await saveSession(endTime: laterSameDay, attempts: attempts(domain: .science, total: 10, correct: 6))

        let trend = try await service.getAccuracyTrend(days: 30)

        XCTAssertEqual(trend.count, 1)
        XCTAssertEqual(trend[0].questionsAnswered, 20)
        XCTAssertEqual(trend[0].accuracy, 0.5, accuracy: 0.0001)
    }

    // MARK: - Streak

    func testCalculateStreak_withNoSessions_returnsZero() async throws {
        let streak = try await service.calculateStreak()
        XCTAssertEqual(streak, 0)
    }

    func testCalculateStreak_countsConsecutiveDaysEndingToday() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date()).addingTimeInterval(10 * 3600)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let dayBefore = calendar.date(byAdding: .day, value: -2, to: today)!

        try await saveSession(endTime: dayBefore, attempts: attempts(domain: .science, total: 1, correct: 1))
        try await saveSession(endTime: yesterday, attempts: attempts(domain: .science, total: 1, correct: 1))
        try await saveSession(endTime: today, attempts: attempts(domain: .science, total: 1, correct: 1))

        let streak = try await service.calculateStreak()
        XCTAssertEqual(streak, 3)
    }

    func testCalculateStreak_brokenWhenLastSessionOlderThanYesterday() async throws {
        let calendar = Calendar.current
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: Date())!

        try await saveSession(endTime: threeDaysAgo, attempts: attempts(domain: .science, total: 1, correct: 1))

        let streak = try await service.calculateStreak()
        XCTAssertEqual(streak, 0)
    }

    // MARK: - Domain Mastery

    func testGetDomainMastery_mapsAccuracyToMasteryLevels() async throws {
        // Science: 9/10 = 90% with 10 questions -> mastered.
        // Literature: 6/10 = 60% with 10 questions -> intermediate.
        try await saveSession(attempts:
            attempts(domain: .science, total: 10, correct: 9) +
            attempts(domain: .literature, total: 10, correct: 6)
        )

        let mastery = try await service.getDomainMastery()

        XCTAssertEqual(mastery[.science], .mastered)
        XCTAssertEqual(mastery[.literature], .intermediate)
    }

    func testGetDomainMastery_fewQuestionsAreBeginner() async throws {
        // 4 questions all correct, but fewer than 5 questions -> beginner.
        try await saveSession(attempts: attempts(domain: .science, total: 4, correct: 4))

        let mastery = try await service.getDomainMastery()
        XCTAssertEqual(mastery[.science], .beginner)
    }

    // MARK: - Insights

    func testGenerateInsights_withNoSessions_onlyLowActivity() async throws {
        // With zero completed sessions, totalSessions (0) < 5 triggers the
        // low-activity insight. All other insights are gated off because their
        // conditions require non-zero comparison gaps, weak domains, or streaks.
        let insights = try await service.generateInsights()

        XCTAssertEqual(insights.count, 1)
        XCTAssertEqual(insights.first?.type, .lowActivity)
        // Streak-broken requires totalSessions > 0, so it must not appear here.
        XCTAssertFalse(insights.contains { $0.type == .streakBroken })
    }

    func testGenerateInsights_emitsLowActivityForFewSessions() async throws {
        // A single small completed session: should yield the low-activity insight.
        try await saveSession(attempts: attempts(domain: .science, total: 3, correct: 2))

        let insights = try await service.generateInsights()
        XCTAssertTrue(insights.contains { $0.type == .lowActivity })
    }

    func testGenerateInsights_emitsDomainWeaknessWithNavigation() async throws {
        // 2/10 = 20% in Science: weak domain, with a domainDrill navigation target.
        try await saveSession(attempts: attempts(domain: .science, total: 10, correct: 2))

        let insights = try await service.generateInsights()
        let weakness = try XCTUnwrap(insights.first { $0.type == .domainWeakness })

        // Navigation destination should be a drill into the weakest domain.
        if case let .domainDrill(domain) = weakness.navigationDestination {
            XCTAssertEqual(domain, .science)
        } else {
            XCTFail("Expected domainDrill navigation destination for domain weakness")
        }
    }

    func testGenerateInsights_emitsPerformanceGapWhenWrittenBeatsOral() async throws {
        // Written 100%, oral 40%: gap > 0.15 favoring written -> "Oral Practice Needed".
        try await saveSession(
            roundType: .written,
            attempts: attempts(domain: .science, total: 10, correct: 10, roundType: .written)
        )
        try await saveSession(
            roundType: .oral,
            attempts: attempts(domain: .science, total: 10, correct: 4, roundType: .oral)
        )

        let insights = try await service.generateInsights()
        let gap = try XCTUnwrap(insights.first { $0.type == .performanceGap })

        // InsightDestination is not Equatable, so match the case directly.
        if case .oralPractice = gap.navigationDestination {
            // Expected destination.
        } else {
            XCTFail("Expected oralPractice navigation for written-favored gap")
        }
    }

    func testGenerateInsights_sortedByPriorityDescending() async throws {
        // Create conditions producing both a high-priority (domain weakness) and a
        // medium/low priority insight, then verify ordering.
        try await saveSession(attempts: attempts(domain: .science, total: 10, correct: 2))

        let insights = try await service.generateInsights()
        XCTAssertFalse(insights.isEmpty)

        let priorities = insights.map { $0.priority.rawValue }
        XCTAssertEqual(priorities, priorities.sorted(by: >),
                       "Insights must be sorted by descending priority")
    }

    // MARK: - DomainAnalytics value type

    func testDomainAnalytics_accuracy_withQuestions() {
        var analytics = DomainAnalytics(domain: .science)
        analytics.totalQuestions = 10
        analytics.correctAnswers = 7
        XCTAssertEqual(analytics.accuracy, 0.7, accuracy: 0.0001)
    }

    func testDomainAnalytics_accuracy_withNoQuestions_returnsZero() {
        let analytics = DomainAnalytics(domain: .science)
        XCTAssertEqual(analytics.accuracy, 0)
    }

    // MARK: - RoundTypeComparison value type

    func testRoundTypeComparison_gapIsAbsoluteDifference() {
        let comparison = RoundTypeComparison(
            writtenAccuracy: 0.4,
            oralAccuracy: 0.9,
            writtenQuestions: 10,
            oralQuestions: 10
        )
        XCTAssertEqual(comparison.gap, 0.5, accuracy: 0.0001)
    }

    func testRoundTypeComparison_hasSignificantGap() {
        let big = RoundTypeComparison(writtenAccuracy: 0.9, oralAccuracy: 0.5, writtenQuestions: 1, oralQuestions: 1)
        let small = RoundTypeComparison(writtenAccuracy: 0.9, oralAccuracy: 0.85, writtenQuestions: 1, oralQuestions: 1)

        XCTAssertTrue(big.hasSignificantGap)
        XCTAssertFalse(small.hasSignificantGap)
    }

    // MARK: - MasteryLevel value type

    func testMasteryLevel_notStartedWhenNoQuestions() {
        XCTAssertEqual(MasteryLevel.from(accuracy: 0.9, questionsAttempted: 0), .notStarted)
    }

    func testMasteryLevel_beginnerForFewQuestions() {
        XCTAssertEqual(MasteryLevel.from(accuracy: 1.0, questionsAttempted: 4), .beginner)
    }

    func testMasteryLevel_beginnerForLowAccuracy() {
        XCTAssertEqual(MasteryLevel.from(accuracy: 0.49, questionsAttempted: 20), .beginner)
    }

    func testMasteryLevel_intermediateBand() {
        XCTAssertEqual(MasteryLevel.from(accuracy: 0.69, questionsAttempted: 20), .intermediate)
    }

    func testMasteryLevel_advancedBand() {
        XCTAssertEqual(MasteryLevel.from(accuracy: 0.84, questionsAttempted: 20), .advanced)
    }

    func testMasteryLevel_masteredBand() {
        XCTAssertEqual(MasteryLevel.from(accuracy: 0.85, questionsAttempted: 20), .mastered)
    }

    func testMasteryLevel_allCasesHaveColors() {
        for level in MasteryLevel.allCases {
            XCTAssertFalse(level.color.isEmpty)
        }
    }

    // MARK: - InsightPriority / InsightType value types

    func testInsightPriority_rawValuesOrderHighest() {
        XCTAssertGreaterThan(InsightPriority.high.rawValue, InsightPriority.medium.rawValue)
        XCTAssertGreaterThan(InsightPriority.medium.rawValue, InsightPriority.low.rawValue)
    }

    func testInsightType_everyCaseHasNonEmptyIcon() {
        let allTypes: [InsightType] = [
            .performanceGap, .domainWeakness, .lowActivity, .streakBroken,
            .achievement, .responseTime, .improvementTrend, .competitionReady,
            .reboundSkill, .conferenceSkill, .difficultyProgression,
            .timePatterns, .matchPerformance
        ]
        for type in allTypes {
            XCTAssertFalse(type.icon.isEmpty, "\(type) should have an icon")
        }
    }

    // MARK: - KBInsight value type

    func testKBInsight_iconMirrorsType() {
        let insight = KBInsight(
            type: .achievement,
            title: "Title",
            message: "Message",
            priority: .low,
            recommendedAction: "Action"
        )
        XCTAssertEqual(insight.icon, InsightType.achievement.icon)
        XCTAssertNil(insight.navigationDestination)
    }
}
