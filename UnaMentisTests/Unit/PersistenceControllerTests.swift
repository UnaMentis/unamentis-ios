// UnaMentis - Persistence Controller Tests
// Tests for Core Data stack initialization and operations
//
// Part of Persistence Layer Testing

import XCTest
import CoreData
@testable import UnaMentis

final class PersistenceControllerTests: XCTestCase {

    // MARK: - Initialization Tests

    func testInit_inMemory_createsController() {
        // Given/When
        let controller = PersistenceController(inMemory: true)

        // Then
        XCTAssertNotNil(controller)
        XCTAssertNotNil(controller.container)
    }

    @MainActor
    func testInit_inMemory_viewContextIsAvailable() {
        // Given
        let controller = PersistenceController(inMemory: true)

        // When
        let context = controller.viewContext

        // Then
        XCTAssertNotNil(context)
        XCTAssertEqual(context.concurrencyType, .mainQueueConcurrencyType)
    }

    @MainActor
    func testInit_inMemory_contextMergePolicy() {
        // Given
        let controller = PersistenceController(inMemory: true)

        // When
        let context = controller.viewContext

        // Then
        XCTAssertTrue(context.automaticallyMergesChangesFromParent)
    }

    // MARK: - Background Context Tests

    func testNewBackgroundContext_createsContext() {
        // Given
        let controller = PersistenceController(inMemory: true)

        // When
        let bgContext = controller.newBackgroundContext()

        // Then
        XCTAssertNotNil(bgContext)
        XCTAssertEqual(bgContext.concurrencyType, .privateQueueConcurrencyType)
    }

    func testNewBackgroundContext_hasCorrectMergePolicy() {
        // Given
        let controller = PersistenceController(inMemory: true)

        // When
        let bgContext = controller.newBackgroundContext()

        // Then
        // Verify merge policy is set (NSMergePolicy.mergeByPropertyObjectTrump)
        XCTAssertNotNil(bgContext.mergePolicy)
    }

    // MARK: - Save Operations Tests

    @MainActor
    func testSave_noChanges_doesNotThrow() throws {
        // Given
        let controller = PersistenceController(inMemory: true)

        // When/Then - should not throw when no changes
        XCTAssertNoThrow(try controller.save())
    }

    @MainActor
    func testSave_withChanges_persistsData() throws {
        // Given
        let controller = PersistenceController(inMemory: true)
        let context = controller.viewContext

        let curriculum = Curriculum(context: context)
        curriculum.id = UUID()
        curriculum.name = "Test Curriculum"
        curriculum.createdAt = Date()
        curriculum.updatedAt = Date()

        // When
        try controller.save()

        // Then - fetch to verify persistence
        let fetchRequest = Curriculum.fetchRequest()
        let results = try context.fetch(fetchRequest)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.name, "Test Curriculum")
    }

    func testSave_context_persistsData() throws {
        // Given
        let controller = PersistenceController(inMemory: true)
        let bgContext = controller.newBackgroundContext()

        // When - create entity in background context
        let expectation = expectation(description: "Background save")
        bgContext.perform {
            let curriculum = Curriculum(context: bgContext)
            curriculum.id = UUID()
            curriculum.name = "Background Curriculum"
            curriculum.createdAt = Date()
            curriculum.updatedAt = Date()

            do {
                try controller.save(context: bgContext)
                expectation.fulfill()
            } catch {
                XCTFail("Save failed: \(error)")
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Fetch Operations Tests

    @MainActor
    func testFetchCurricula_empty_returnsEmptyArray() throws {
        // Given
        let controller = PersistenceController(inMemory: true)

        // When
        let curricula = try controller.fetchCurricula()

        // Then
        XCTAssertTrue(curricula.isEmpty)
    }

    @MainActor
    func testFetchCurricula_withData_returnsSortedByDate() throws {
        // Given
        let controller = PersistenceController(inMemory: true)
        let context = controller.viewContext

        // Create older curriculum
        let older = Curriculum(context: context)
        older.id = UUID()
        older.name = "Older"
        older.createdAt = Date().addingTimeInterval(-3600)
        older.updatedAt = Date().addingTimeInterval(-3600)

        // Create newer curriculum
        let newer = Curriculum(context: context)
        newer.id = UUID()
        newer.name = "Newer"
        newer.createdAt = Date()
        newer.updatedAt = Date()

        try context.save()

        // When
        let curricula = try controller.fetchCurricula()

        // Then - should be sorted by updatedAt descending
        XCTAssertEqual(curricula.count, 2)
        XCTAssertEqual(curricula.first?.name, "Newer")
    }

    @MainActor
    func testFetchTopics_forCurriculum_returnsSortedByOrder() throws {
        // Given
        let controller = PersistenceController(inMemory: true)
        let context = controller.viewContext

        let curriculum = Curriculum(context: context)
        curriculum.id = UUID()
        curriculum.name = "Test"
        curriculum.createdAt = Date()
        curriculum.updatedAt = Date()

        let topic1 = Topic(context: context)
        topic1.id = UUID()
        topic1.title = "Topic 1"
        topic1.orderIndex = 1
        topic1.curriculum = curriculum

        let topic0 = Topic(context: context)
        topic0.id = UUID()
        topic0.title = "Topic 0"
        topic0.orderIndex = 0
        topic0.curriculum = curriculum

        try context.save()

        // When
        let topics = try controller.fetchTopics(for: curriculum)

        // Then - sorted by orderIndex ascending
        XCTAssertEqual(topics.count, 2)
        XCTAssertEqual(topics.first?.title, "Topic 0")
    }

    @MainActor
    func testFetchRecentSessions_respectsLimit() throws {
        // Given
        let controller = PersistenceController(inMemory: true)
        let context = controller.viewContext

        // Create 15 sessions
        for i in 0..<15 {
            let session = Session(context: context)
            session.id = UUID()
            session.startTime = Date().addingTimeInterval(Double(-i * 60))
        }
        try context.save()

        // When
        let sessions = try controller.fetchRecentSessions(limit: 5)

        // Then
        XCTAssertEqual(sessions.count, 5)
    }

    @MainActor
    func testFetchRecentSessions_sortedByStartTime() throws {
        // Given
        let controller = PersistenceController(inMemory: true)
        let context = controller.viewContext

        let olderSession = Session(context: context)
        olderSession.id = UUID()
        olderSession.startTime = Date().addingTimeInterval(-3600)

        let newerSession = Session(context: context)
        newerSession.id = UUID()
        newerSession.startTime = Date()

        try context.save()

        // When
        let sessions = try controller.fetchRecentSessions()

        // Then - most recent first
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.first?.id, newerSession.id)
    }

    // MARK: - Preview Controller Tests

    @MainActor
    func testPreview_hasPreviewData() {
        // Given/When
        let preview = PersistenceController.preview

        // Then
        let curricula = try? preview.fetchCurricula()
        XCTAssertFalse(curricula?.isEmpty ?? true)
    }
}
