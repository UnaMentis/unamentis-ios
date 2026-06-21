// UnaMentis - Curriculum Models Tests
// Real tests for the pure helpers and Core Data extensions in CurriculumModels.swift:
// cosineSimilarity, DocumentType detection, Document.decodedChunks, and the
// Topic.status derivation. These are foundational to the curriculum engine's
// semantic search and progress logic, so they are exercised directly here.

import XCTest
import CoreData
@testable import UnaMentis

final class CurriculumModelsTests: XCTestCase {

    // MARK: - Properties

    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!

    // MARK: - Setup / Teardown

    @MainActor
    override func setUp() async throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
    }

    @MainActor
    override func tearDown() async throws {
        context = nil
        persistenceController = nil
    }

    // MARK: - cosineSimilarity

    func testCosineSimilarity_identicalVectors_isOne() {
        let v: [Float] = [1, 2, 3]
        XCTAssertEqual(cosineSimilarity(v, v), 1.0, accuracy: 0.0001)
    }

    func testCosineSimilarity_orthogonalVectors_isZero() {
        let a: [Float] = [1, 0]
        let b: [Float] = [0, 1]
        XCTAssertEqual(cosineSimilarity(a, b), 0.0, accuracy: 0.0001)
    }

    func testCosineSimilarity_oppositeVectors_isNegativeOne() {
        let a: [Float] = [1, 1]
        let b: [Float] = [-1, -1]
        XCTAssertEqual(cosineSimilarity(a, b), -1.0, accuracy: 0.0001)
    }

    func testCosineSimilarity_mismatchedLengths_isZero() {
        XCTAssertEqual(cosineSimilarity([1, 2, 3], [1, 2]), 0.0)
    }

    func testCosineSimilarity_emptyVectors_isZero() {
        XCTAssertEqual(cosineSimilarity([], []), 0.0)
    }

    func testCosineSimilarity_zeroVector_isZero() {
        // A zero-magnitude vector must not divide by zero.
        XCTAssertEqual(cosineSimilarity([0, 0, 0], [1, 2, 3]), 0.0)
    }

    // MARK: - DocumentType.from(fileExtension:)

    func testDocumentTypeFrom_detectsKnownExtensionsCaseInsensitively() {
        XCTAssertEqual(DocumentType.from(fileExtension: "pdf"), .pdf)
        XCTAssertEqual(DocumentType.from(fileExtension: "PDF"), .pdf)
        XCTAssertEqual(DocumentType.from(fileExtension: "txt"), .text)
        XCTAssertEqual(DocumentType.from(fileExtension: "md"), .markdown)
        XCTAssertEqual(DocumentType.from(fileExtension: "markdown"), .markdown)
        XCTAssertEqual(DocumentType.from(fileExtension: "json"), .transcript)
    }

    func testDocumentTypeFrom_unknownExtensionReturnsNil() {
        XCTAssertNil(DocumentType.from(fileExtension: "docx"))
        XCTAssertNil(DocumentType.from(fileExtension: ""))
    }

    // MARK: - Document.documentType

    @MainActor
    func testDocument_documentType_defaultsToTextForNilOrUnknown() throws {
        let doc = TestDataFactory.createDocument(in: context, type: "text")
        XCTAssertEqual(doc.documentType, .text)

        let unknown = TestDataFactory.createDocument(in: context, type: "weird")
        XCTAssertEqual(unknown.documentType, .text)
    }

    @MainActor
    func testDocument_documentType_mapsTranscript() throws {
        let doc = TestDataFactory.createDocument(in: context, type: DocumentType.transcript.rawValue)
        XCTAssertEqual(doc.documentType, .transcript)
    }

    // MARK: - Document.decodedChunks

    @MainActor
    func testDecodedChunks_returnsNilWhenNoEmbeddingData() throws {
        let doc = TestDataFactory.createDocument(in: context)
        // No embedding set.
        XCTAssertNil(doc.decodedChunks())
    }

    @MainActor
    func testDecodedChunks_returnsNilForInvalidData() throws {
        let doc = TestDataFactory.createDocument(in: context)
        doc.embedding = Data("not valid chunk json".utf8)
        XCTAssertNil(doc.decodedChunks())
    }

    @MainActor
    func testDecodedChunks_roundTripsEncodedChunks() throws {
        let doc = TestDataFactory.createDocument(in: context)
        let docId = doc.id!
        let chunks = [
            DocumentChunk(documentId: docId, text: "First chunk", embedding: [0.1, 0.2], chunkIndex: 0),
            DocumentChunk(documentId: docId, text: "Second chunk", embedding: [0.3, 0.4], pageNumber: 2, chunkIndex: 1)
        ]
        doc.embedding = try JSONEncoder().encode(chunks)

        let decoded = try XCTUnwrap(doc.decodedChunks())
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].text, "First chunk")
        XCTAssertEqual(decoded[0].chunkIndex, 0)
        XCTAssertNil(decoded[0].pageNumber)
        XCTAssertEqual(decoded[1].text, "Second chunk")
        XCTAssertEqual(decoded[1].pageNumber, 2)
        XCTAssertEqual(decoded[1].embedding, [0.3, 0.4])
    }

    // MARK: - Topic.status derivation

    @MainActor
    func testTopicStatus_notStartedWhenNoProgress() throws {
        let topic = TestDataFactory.createTopic(in: context, mastery: 0.9)
        // No progress object: status is notStarted regardless of mastery.
        XCTAssertEqual(topic.status, .notStarted)
    }

    @MainActor
    func testTopicStatus_notStartedWhenProgressButZeroTime() throws {
        let topic = TestDataFactory.createTopic(in: context, mastery: 0.0)
        _ = TestDataFactory.createProgress(in: context, for: topic, timeSpent: 0)
        XCTAssertEqual(topic.status, .notStarted)
    }

    @MainActor
    func testTopicStatus_inProgressWhenTimeSpentButLowMastery() throws {
        let topic = TestDataFactory.createTopic(in: context, mastery: 0.5)
        _ = TestDataFactory.createProgress(in: context, for: topic, timeSpent: 120)
        XCTAssertEqual(topic.status, .inProgress)
    }

    @MainActor
    func testTopicStatus_completedRequiresBothMasteryAndTime() throws {
        // High mastery alone (no time) is not completed.
        let masteryOnly = TestDataFactory.createTopic(in: context, mastery: 0.95)
        _ = TestDataFactory.createProgress(in: context, for: masteryOnly, timeSpent: 0)
        XCTAssertEqual(masteryOnly.status, .notStarted)

        // Mastery >= 0.8 plus time spent is completed.
        let done = TestDataFactory.createTopic(in: context, mastery: 0.8)
        _ = TestDataFactory.createProgress(in: context, for: done, timeSpent: 1)
        XCTAssertEqual(done.status, .completed)
    }

    // MARK: - TopicStatus / ContentDepth enum metadata

    func testTopicStatus_displayAndAccessibilityNames() {
        XCTAssertEqual(TopicStatus.inProgress.displayName, "In Progress")
        XCTAssertEqual(TopicStatus.completed.accessibilityDescription, "completed")
        XCTAssertEqual(TopicStatus.reviewing.displayName, "Reviewing")
    }

    func testContentDepth_mathDerivationsGatedByLevel() {
        XCTAssertFalse(ContentDepth.overview.includeMathDerivations)
        XCTAssertFalse(ContentDepth.introductory.includeMathDerivations)
        XCTAssertFalse(ContentDepth.intermediate.includeMathDerivations)
        XCTAssertTrue(ContentDepth.advanced.includeMathDerivations)
        XCTAssertTrue(ContentDepth.graduate.includeMathDerivations)
        XCTAssertTrue(ContentDepth.research.includeMathDerivations)
    }

    func testContentDepth_expectedDurationRangesAreOrdered() {
        // Each deeper level should expect at least as long a session.
        XCTAssertEqual(ContentDepth.overview.expectedDurationRange, 2...5)
        XCTAssertEqual(ContentDepth.advanced.expectedDurationRange, 30...60)
        XCTAssertLessThan(
            ContentDepth.overview.expectedDurationRange.lowerBound,
            ContentDepth.graduate.expectedDurationRange.lowerBound
        )
    }
}
