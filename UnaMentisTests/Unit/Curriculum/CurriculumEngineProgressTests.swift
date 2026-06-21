// UnaMentis - Curriculum Engine Progress and Outline Tests
// Real Core Data tests for CurriculumEngine aggregation, navigation boundaries,
// foveated context, and curriculum outline generation.
//
// These complement CurriculumEngineTests.swift, which covers loading, basic
// navigation, context generation, and semantic search happy paths. This file
// targets the aggregation methods (getCurriculumProgress), the FOV helpers
// (generateCurriculumOutline, getTopicPosition, generateFoveatedContext), and
// the boundary/edge behavior of navigation and context generation.

import XCTest
import CoreData
@testable import UnaMentis

final class CurriculumEngineProgressTests: XCTestCase {

    // MARK: - Properties

    var curriculumEngine: CurriculumEngine!
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!

    // MARK: - Setup / Teardown

    @MainActor
    override func setUp() async throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        // No embedding service here: exercises the no-embeddings code paths.
        curriculumEngine = CurriculumEngine(persistenceController: persistenceController)
    }

    @MainActor
    override func tearDown() async throws {
        curriculumEngine = nil
        context = nil
        persistenceController = nil
    }

    // MARK: - Helpers

    /// Build a curriculum with `count` topics ordered 0..<count and load it into the engine.
    @MainActor
    @discardableResult
    private func makeLoadedCurriculum(
        name: String = "Engine Course",
        count: Int
    ) throws -> (curriculum: Curriculum, topics: [Topic]) {
        let curriculum = TestDataFactory.createCurriculum(in: context, name: name)
        var topics: [Topic] = []
        for i in 0..<count {
            let topic = TestDataFactory.createTopic(in: context, title: "Topic \(i)", orderIndex: Int32(i))
            topic.curriculum = curriculum
            topics.append(topic)
        }
        try context.save()
        try curriculumEngine.loadCurriculum(curriculum.id!)
        return (curriculum, topics)
    }

    // MARK: - getTopics Edge Cases

    @MainActor
    func testGetTopics_returnsEmptyWhenNoCurriculumLoaded() async throws {
        // No curriculum loaded.
        let topics = await curriculumEngine.getTopics()
        XCTAssertTrue(topics.isEmpty)
    }

    @MainActor
    func testGetTopics_sortsByOrderIndex() async throws {
        // Given topics created out of order.
        let curriculum = TestDataFactory.createCurriculum(in: context)
        let t2 = TestDataFactory.createTopic(in: context, title: "Second", orderIndex: 1); t2.curriculum = curriculum
        let t0 = TestDataFactory.createTopic(in: context, title: "Zero", orderIndex: 0); t0.curriculum = curriculum
        let t1 = TestDataFactory.createTopic(in: context, title: "First", orderIndex: 2); t1.curriculum = curriculum
        try context.save()
        try curriculumEngine.loadCurriculum(curriculum.id!)

        // When
        let topics = await curriculumEngine.getTopics()

        // Then sorted ascending by orderIndex.
        XCTAssertEqual(topics.map { $0.orderIndex }, [0, 1, 2])
        XCTAssertEqual(topics.first?.title, "Zero")
    }

    // MARK: - Navigation Boundaries

    @MainActor
    func testGetNextTopic_returnsNilWhenNoCurrentTopic() async throws {
        // No current topic set.
        let next = await curriculumEngine.getNextTopic()
        XCTAssertNil(next)
    }

    @MainActor
    func testGetPreviousTopic_returnsNilOnFirstTopic() async throws {
        // Given
        let (_, topics) = try makeLoadedCurriculum(count: 3)
        try curriculumEngine.startTopic(topics[0])

        // When/Then previous of first is nil.
        let prev = await curriculumEngine.getPreviousTopic()
        XCTAssertNil(prev)
    }

    @MainActor
    func testGetPreviousTopic_returnsNilWhenNoCurrentTopic() async throws {
        _ = try makeLoadedCurriculum(count: 2)
        let prev = await curriculumEngine.getPreviousTopic()
        XCTAssertNil(prev)
    }

    // MARK: - getCurriculumProgress

    @MainActor
    func testGetCurriculumProgress_emptyCurriculum() async throws {
        _ = try makeLoadedCurriculum(count: 0)

        let progress = await curriculumEngine.getCurriculumProgress()

        XCTAssertEqual(progress.totalTopics, 0)
        XCTAssertEqual(progress.completedTopics, 0)
        XCTAssertEqual(progress.totalTimeSpent, 0)
        XCTAssertEqual(progress.averageMastery, 0)
        XCTAssertNil(progress.suggestedNextTopicId)
        // Division-by-zero guard.
        XCTAssertEqual(progress.completionPercentage, 0)
    }

    @MainActor
    func testGetCurriculumProgress_aggregatesAcrossTopics() async throws {
        // Given 3 topics: topic 0 completed (mastery 0.9, time 600),
        // topic 1 in progress (mastery 0.4, time 300), topic 2 not started.
        let (_, topics) = try makeLoadedCurriculum(count: 3)

        topics[0].mastery = 0.9
        _ = TestDataFactory.createProgress(in: context, for: topics[0], timeSpent: 600)

        topics[1].mastery = 0.4
        _ = TestDataFactory.createProgress(in: context, for: topics[1], timeSpent: 300)

        topics[2].mastery = 0.0
        // No progress for topic 2.
        try context.save()

        // When
        let progress = await curriculumEngine.getCurriculumProgress()

        // Then
        XCTAssertEqual(progress.totalTopics, 3)
        XCTAssertEqual(progress.completedTopics, 1) // only topic 0 meets .completed
        XCTAssertEqual(progress.totalTimeSpent, 900) // 600 + 300
        // Average mastery: (0.9 + 0.4 + 0.0) / 3 = 0.4333...
        XCTAssertEqual(progress.averageMastery, (0.9 + 0.4 + 0.0) / 3, accuracy: 0.0001)
        // Completion percentage 1/3.
        XCTAssertEqual(progress.completionPercentage, 1.0 / 3.0, accuracy: 0.0001)
        // Suggested next is the first non-completed topic, which is topic 1.
        XCTAssertEqual(progress.suggestedNextTopicId, topics[1].id)
        XCTAssertEqual(progress.suggestedNextTopicOrderIndex, 1)
    }

    @MainActor
    func testGetCurriculumProgress_suggestsFirstTopicWhenNoneCompleted() async throws {
        let (_, topics) = try makeLoadedCurriculum(count: 2)
        // Neither topic has progress, so both are .notStarted.
        let progress = await curriculumEngine.getCurriculumProgress()
        XCTAssertEqual(progress.completedTopics, 0)
        XCTAssertEqual(progress.suggestedNextTopicId, topics[0].id)
    }

    // MARK: - CurriculumProgress formatting

    func testCurriculumProgress_formattedTimeSpent_hoursAndMinutes() {
        let p = CurriculumProgress(
            totalTopics: 1,
            completedTopics: 0,
            totalTimeSpent: 3600 + 25 * 60, // 1h 25m
            averageMastery: 0,
            suggestedNextTopicId: nil,
            suggestedNextTopicOrderIndex: nil
        )
        XCTAssertEqual(p.formattedTimeSpent, "1h 25m")
    }

    func testCurriculumProgress_formattedTimeSpent_minutesOnly() {
        let p = CurriculumProgress(
            totalTopics: 1,
            completedTopics: 0,
            totalTimeSpent: 7 * 60, // 7m
            averageMastery: 0,
            suggestedNextTopicId: nil,
            suggestedNextTopicOrderIndex: nil
        )
        XCTAssertEqual(p.formattedTimeSpent, "7m")
    }

    // MARK: - generateCurriculumOutline

    @MainActor
    func testGenerateCurriculumOutline_emptyWhenNoCurriculum() async throws {
        let outline = await curriculumEngine.generateCurriculumOutline()
        XCTAssertEqual(outline, "")
    }

    @MainActor
    func testGenerateCurriculumOutline_includesTitlesObjectivesAndStatus() async throws {
        // Given two topics, the first completed.
        let curriculum = TestDataFactory.createCurriculum(in: context, name: "Outline Course")
        let t0 = TestDataFactory.createTopic(in: context, title: "Intro", orderIndex: 0)
        t0.objectives = ["Understand the basics", "Build confidence"]
        t0.curriculum = curriculum
        t0.mastery = 0.9
        _ = TestDataFactory.createProgress(in: context, for: t0, timeSpent: 120)

        let t1 = TestDataFactory.createTopic(in: context, title: "Advanced", orderIndex: 1)
        t1.objectives = ["Dive deeper"]
        t1.curriculum = curriculum
        try context.save()
        try curriculumEngine.loadCurriculum(curriculum.id!)

        // When
        let outline = await curriculumEngine.generateCurriculumOutline()

        // Then header, numbered titles, status markers, and objectives appear.
        XCTAssertTrue(outline.contains("Curriculum: Outline Course"))
        // 1-indexed numbering: orderIndex + 1.
        XCTAssertTrue(outline.contains("1. Intro"))
        XCTAssertTrue(outline.contains("2. Advanced"))
        // Completed topic gets the check mark, incomplete gets the open circle.
        XCTAssertTrue(outline.contains("\u{2713}")) // ✓
        XCTAssertTrue(outline.contains("\u{25CB}")) // ○
        // Only the first two objectives are included, joined by "; ".
        XCTAssertTrue(outline.contains("Understand the basics; Build confidence"))
        XCTAssertTrue(outline.contains("Dive deeper"))
    }

    // MARK: - getTopicPosition

    @MainActor
    func testGetTopicPosition_reportsIndexAndTotal() async throws {
        let (_, topics) = try makeLoadedCurriculum(name: "Positioned", count: 4)

        let position = await curriculumEngine.getTopicPosition(for: topics[2])

        XCTAssertEqual(position.curriculumTitle, "Positioned")
        XCTAssertEqual(position.currentTopicIndex, 2)
        XCTAssertEqual(position.totalTopics, 4)
    }

    // MARK: - generateFoveatedContext

    @MainActor
    func testGenerateFoveatedContext_includesCurrentPrevAndNext() async throws {
        let curriculum = TestDataFactory.createCurriculum(in: context, name: "Foveal Course")
        let prev = TestDataFactory.createTopic(in: context, title: "Prev Topic", orderIndex: 0)
        prev.objectives = ["Prev objective"]
        prev.curriculum = curriculum
        let current = TestDataFactory.createTopic(in: context, title: "Current Topic", orderIndex: 1)
        current.objectives = ["Current objective"]
        current.curriculum = curriculum
        let next = TestDataFactory.createTopic(in: context, title: "Next Topic", orderIndex: 2)
        next.objectives = ["Next objective"]
        next.curriculum = curriculum
        try context.save()
        try curriculumEngine.loadCurriculum(curriculum.id!)

        // When
        let fov = await curriculumEngine.generateFoveatedContext(for: current, tokenBudget: 4000)

        // Then all three sections are present with the current topic at full detail.
        XCTAssertTrue(fov.contains("### CURRENT TOPIC (FULL DETAIL)"))
        XCTAssertTrue(fov.contains("Current Topic"))
        XCTAssertTrue(fov.contains("### PREVIOUS TOPIC (CONTEXT)"))
        XCTAssertTrue(fov.contains("Prev Topic"))
        XCTAssertTrue(fov.contains("### UPCOMING TOPIC (PREVIEW)"))
        XCTAssertTrue(fov.contains("Next Topic"))
    }

    @MainActor
    func testGenerateFoveatedContext_firstTopicHasNoPreviousSection() async throws {
        let (_, topics) = try makeLoadedCurriculum(count: 2)

        let fov = await curriculumEngine.generateFoveatedContext(for: topics[0])

        XCTAssertTrue(fov.contains("### CURRENT TOPIC (FULL DETAIL)"))
        XCTAssertFalse(fov.contains("### PREVIOUS TOPIC (CONTEXT)"))
        XCTAssertTrue(fov.contains("### UPCOMING TOPIC (PREVIEW)"))
    }

    @MainActor
    func testGenerateFoveatedContext_lastTopicHasNoUpcomingSection() async throws {
        let (_, topics) = try makeLoadedCurriculum(count: 2)

        let fov = await curriculumEngine.generateFoveatedContext(for: topics[1])

        XCTAssertTrue(fov.contains("### CURRENT TOPIC (FULL DETAIL)"))
        XCTAssertTrue(fov.contains("### PREVIOUS TOPIC (CONTEXT)"))
        XCTAssertFalse(fov.contains("### UPCOMING TOPIC (PREVIEW)"))
    }

    @MainActor
    func testGenerateFoveatedContext_fallsBackToPlainContextForUnknownTopic() async throws {
        // Topic not part of the loaded curriculum: index lookup fails, so the
        // engine falls back to generateContext(for:) (no FOV section headers).
        _ = try makeLoadedCurriculum(count: 2)
        let orphan = TestDataFactory.createTopic(in: context, title: "Orphan Topic", orderIndex: 99)
        try context.save()

        let fov = await curriculumEngine.generateFoveatedContext(for: orphan)

        XCTAssertFalse(fov.contains("### CURRENT TOPIC (FULL DETAIL)"))
        // Plain context still includes the topic title and teaching approach block.
        XCTAssertTrue(fov.contains("Orphan Topic"))
        XCTAssertTrue(fov.contains("TEACHING APPROACH"))
    }

    @MainActor
    func testGenerateFoveatedContext_respectsTokenBudgetTruncation() async throws {
        // A topic with a very long outline should be truncated under a tight budget.
        let curriculum = TestDataFactory.createCurriculum(in: context, name: "Budget Course")
        let topic = TestDataFactory.createTopic(in: context, title: "Long Topic", orderIndex: 0)
        topic.outline = String(repeating: "word ", count: 5000) // ~25k chars
        topic.curriculum = curriculum
        try context.save()
        try curriculumEngine.loadCurriculum(curriculum.id!)

        // Tiny budget forces truncation. Foveal share is 60% of 100 = 60 tokens => ~240 chars.
        let fov = await curriculumEngine.generateFoveatedContext(for: topic, tokenBudget: 100)

        // Truncated output ends with the ellipsis marker and is far shorter than the source.
        XCTAssertTrue(fov.contains("..."))
        XCTAssertLessThan(fov.count, 5000)
    }

    // MARK: - generateContextForQuery without embedding service

    @MainActor
    func testGenerateContextForQuery_returnsEmptyWithoutEmbeddingService() async throws {
        // This engine was created without an embedding service.
        let topic = TestDataFactory.createTopic(in: context, title: "No Embeddings")
        try context.save()

        let result = await curriculumEngine.generateContextForQuery(query: "anything", topic: topic)

        XCTAssertEqual(result, "")
    }

    // MARK: - semanticSearchChunks without embedding service

    @MainActor
    func testSemanticSearchChunks_returnsEmptyWithoutEmbeddingService() async throws {
        let chunk = DocumentChunk(documentId: UUID(), text: "Hello", embedding: [0.1, 0.2], chunkIndex: 0)
        let result = await curriculumEngine.semanticSearchChunks(query: "Hi", chunks: [chunk], maxTokens: 1000)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - updateProgress error path

    @MainActor
    func testUpdateProgress_throwsWhenNoProgressRecord() async throws {
        let topic = TestDataFactory.createTopic(in: context, title: "No Progress")
        try context.save()

        do {
            try curriculumEngine.updateProgress(topic: topic, timeSpent: 10, conceptsCovered: [])
            XCTFail("Expected progressNotFound error")
        } catch let error as CurriculumError {
            if case .progressNotFound = error {
                // Expected.
            } else {
                XCTFail("Wrong CurriculumError case: \(error)")
            }
        }
    }

    // MARK: - completeTopic mastery floor

    @MainActor
    func testCompleteTopic_enforcesMinimumMasteryFloor() async throws {
        let topic = TestDataFactory.createTopic(in: context, title: "Floor Topic", mastery: 0.1)
        try curriculumEngine.startTopic(topic) // creates progress
        // A topic only reaches .completed status once time has been logged against
        // it (Topic.status requires mastery >= 0.8 AND timeSpent > 0). Logging time
        // mirrors the real flow where a session records study time before the topic
        // is completed.
        try curriculumEngine.updateProgress(topic: topic, timeSpent: 120, conceptsCovered: [])
        try context.save()

        // Requesting a low mastery should still floor at 0.8.
        try curriculumEngine.completeTopic(topic, masteryLevel: 0.2)

        XCTAssertEqual(topic.mastery, 0.8, accuracy: 0.0001)
        XCTAssertEqual(topic.status, .completed)
    }

    // MARK: - FOV extension stubs (currently empty by design)

    @MainActor
    func testGlossaryAndMisconceptionStubs_returnEmpty() async throws {
        let topic = TestDataFactory.createTopic(in: context)
        try context.save()

        let glossary = await curriculumEngine.getRelevantGlossaryTerms(for: "content", in: topic)
        let misconceptions = await curriculumEngine.getMisconceptionTriggers(for: topic)
        let alternatives = await curriculumEngine.getAlternativeExplanations(for: topic)

        XCTAssertTrue(glossary.isEmpty)
        XCTAssertTrue(misconceptions.isEmpty)
        XCTAssertTrue(alternatives.isEmpty)
    }
}
