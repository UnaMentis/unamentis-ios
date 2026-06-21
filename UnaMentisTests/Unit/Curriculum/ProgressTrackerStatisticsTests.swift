// UnaMentis - Progress Tracker Statistics Tests
// Real Core Data tests for ProgressTracker query, concepts, and statistics APIs.
//
// Complements ProgressTrackerTests.swift, which covers creation, time tracking,
// mastery clamping, quiz scores, and status transitions. This file targets
// getProgressStatistics, isCompleted, the concepts API, the mastery floor in
// markCompleted, and the ProgressStatistics computed properties.

import XCTest
import CoreData
@testable import UnaMentis

final class ProgressTrackerStatisticsTests: XCTestCase {

    // MARK: - Properties

    var progressTracker: ProgressTracker!
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!

    // MARK: - Setup / Teardown

    @MainActor
    override func setUp() async throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        progressTracker = ProgressTracker(persistenceController: persistenceController)
    }

    @MainActor
    override func tearDown() async throws {
        progressTracker = nil
        context = nil
        persistenceController = nil
    }

    // MARK: - getProgressStatistics

    @MainActor
    func testGetProgressStatistics_returnsNilWhenNoProgress() async throws {
        let topic = TestDataFactory.createTopic(in: context)
        try context.save()

        let stats = progressTracker.getProgressStatistics(for: topic)

        XCTAssertNil(stats)
    }

    @MainActor
    func testGetProgressStatistics_populatesFieldsFromProgress() async throws {
        // Given a topic in progress with two quiz scores.
        let topic = TestDataFactory.createTopic(in: context, mastery: 0.6)
        let progress = TestDataFactory.createProgress(
            in: context,
            for: topic,
            timeSpent: 1800,
            quizScores: [0.6, 0.8]
        )
        let accessDate = Date(timeIntervalSince1970: 1_700_000_000)
        progress.lastAccessed = accessDate
        try context.save()

        // When
        let computed = progressTracker.getProgressStatistics(for: topic)
        let stats = try XCTUnwrap(computed)

        // Then
        XCTAssertEqual(stats.timeSpent, 1800)
        XCTAssertEqual(stats.masteryLevel, 0.6, accuracy: 0.0001)
        XCTAssertEqual(stats.averageQuizScore, 0.7, accuracy: 0.0001) // (0.6 + 0.8) / 2
        XCTAssertEqual(stats.quizCount, 2)
        XCTAssertEqual(stats.lastAccessed, accessDate)
        // mastery 0.6 with time spent => in progress.
        XCTAssertEqual(stats.status, .inProgress)
    }

    @MainActor
    func testGetProgressStatistics_zeroAverageWhenNoQuizScores() async throws {
        let topic = TestDataFactory.createTopic(in: context, mastery: 0.0)
        _ = TestDataFactory.createProgress(in: context, for: topic, timeSpent: 0)
        try context.save()

        let computed = progressTracker.getProgressStatistics(for: topic)
        let stats = try XCTUnwrap(computed)

        XCTAssertEqual(stats.averageQuizScore, 0)
        XCTAssertEqual(stats.quizCount, 0)
        // No time and no mastery => not started.
        XCTAssertEqual(stats.status, .notStarted)
    }

    // MARK: - isCompleted

    @MainActor
    func testIsCompleted_trueWhenHighMasteryAndTimeSpent() async throws {
        let topic = TestDataFactory.createTopic(in: context, mastery: 0.85)
        _ = TestDataFactory.createProgress(in: context, for: topic, timeSpent: 600)
        try context.save()

        let completed = progressTracker.isCompleted(topic: topic)

        XCTAssertTrue(completed)
    }

    @MainActor
    func testIsCompleted_falseWhenHighMasteryButNoTimeSpent() async throws {
        // Status requires BOTH mastery >= 0.8 AND timeSpent > 0.
        let topic = TestDataFactory.createTopic(in: context, mastery: 0.95)
        _ = TestDataFactory.createProgress(in: context, for: topic, timeSpent: 0)
        try context.save()

        let completed = progressTracker.isCompleted(topic: topic)

        XCTAssertFalse(completed)
    }

    @MainActor
    func testIsCompleted_falseWhenNoProgress() async throws {
        let topic = TestDataFactory.createTopic(in: context, mastery: 0.9)
        try context.save()

        let completed = progressTracker.isCompleted(topic: topic)

        XCTAssertFalse(completed)
    }

    // MARK: - Concepts API

    @MainActor
    func testAddAndGetConceptsCovered_currentSchemaReturnsEmpty() async throws {
        // The current schema does not persist concept lists, so the getter is
        // documented to return empty. This test pins that contract so a future
        // schema change that starts persisting concepts is caught here.
        let topic = TestDataFactory.createTopic(in: context)
        let progress = TestDataFactory.createProgress(in: context, for: topic)
        try context.save()

        try progressTracker.addConceptsCovered(progress: progress, concepts: ["Recursion", "Stacks"])
        let concepts = progressTracker.getConceptsCovered(for: progress)

        XCTAssertTrue(concepts.isEmpty)
    }

    @MainActor
    func testAddConceptsCovered_updatesLastAccessed() async throws {
        let topic = TestDataFactory.createTopic(in: context)
        let progress = TestDataFactory.createProgress(in: context, for: topic)
        let before = progress.lastAccessed
        try context.save()

        try await Task.sleep(nanoseconds: 10_000_000) // 10ms

        try progressTracker.addConceptsCovered(progress: progress, concepts: ["X"])

        XCTAssertNotNil(progress.lastAccessed)
        if let before = before {
            XCTAssertGreaterThan(progress.lastAccessed!, before)
        }
    }

    // MARK: - markCompleted mastery floor

    @MainActor
    func testMarkCompleted_flooredToPointEightWhenLowerRequested() async throws {
        let topic = TestDataFactory.createTopic(in: context, mastery: 0.2)
        _ = TestDataFactory.createProgress(in: context, for: topic, timeSpent: 100)
        try context.save()

        // Requesting below 0.8 should still floor to 0.8.
        try progressTracker.markCompleted(topic: topic, masteryLevel: 0.5)

        XCTAssertEqual(topic.mastery, 0.8, accuracy: 0.0001)
        XCTAssertEqual(topic.status, .completed)
    }

    @MainActor
    func testMarkCompleted_keepsHigherRequestedMastery() async throws {
        let topic = TestDataFactory.createTopic(in: context, mastery: 0.5)
        _ = TestDataFactory.createProgress(in: context, for: topic, timeSpent: 100)
        try context.save()

        try progressTracker.markCompleted(topic: topic, masteryLevel: 0.95)

        XCTAssertEqual(topic.mastery, 0.95, accuracy: 0.0001)
    }

    // MARK: - ProgressStatistics computed properties

    func testProgressStatistics_formattedTimeSpent_hoursAndMinutes() {
        let stats = ProgressStatistics(
            timeSpent: 2 * 3600 + 5 * 60, // 2h 5m
            masteryLevel: 0.5,
            averageQuizScore: 0,
            quizCount: 0,
            lastAccessed: nil,
            status: .inProgress
        )
        XCTAssertEqual(stats.formattedTimeSpent, "2h 5m")
    }

    func testProgressStatistics_formattedTimeSpent_minutesOnly() {
        let stats = ProgressStatistics(
            timeSpent: 42 * 60, // 42m
            masteryLevel: 0.5,
            averageQuizScore: 0,
            quizCount: 0,
            lastAccessed: nil,
            status: .inProgress
        )
        XCTAssertEqual(stats.formattedTimeSpent, "42m")
    }

    func testProgressStatistics_masteryPercentage_roundsDown() {
        let stats = ProgressStatistics(
            timeSpent: 0,
            masteryLevel: 0.756, // Int(75.6) == 75
            averageQuizScore: 0,
            quizCount: 0,
            lastAccessed: nil,
            status: .inProgress
        )
        XCTAssertEqual(stats.masteryPercentage, "75%")
    }
}
