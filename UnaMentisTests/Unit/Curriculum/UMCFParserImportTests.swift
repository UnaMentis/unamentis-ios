// UnaMentis - UMCF Parser Import Branch Tests
// Real Core Data tests for UMCFParser import branches not covered by
// UMCFParserTests.swift: nested objective inheritance, depth-level parsing,
// content-node type filtering, selective import semantics, transcript content
// formatting, and visual-asset timing defaults.

import XCTest
import CoreData
@testable import UnaMentis

final class UMCFParserImportTests: XCTestCase {

    // MARK: - Properties

    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    var parser: UMCFParser!

    // MARK: - Setup / Teardown

    @MainActor
    override func setUp() async throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        parser = UMCFParser(persistenceController: persistenceController)
    }

    @MainActor
    override func tearDown() async throws {
        parser = nil
        context = nil
        persistenceController = nil
    }

    // MARK: - Helpers

    private func data(_ json: String) -> Data {
        json.data(using: .utf8)!
    }

    @MainActor
    private func sortedTopics(_ curriculum: Curriculum) -> [Topic] {
        let topics = curriculum.topics?.array as? [Topic] ?? []
        return topics.sorted { $0.orderIndex < $1.orderIndex }
    }

    // MARK: - Nested Objective Inheritance

    @MainActor
    func testImport_childTopicInheritsParentObjectives() async throws {
        // A "unit" node carries objectives that its child topic should inherit.
        // The unit node itself is type "unit", which is not a topic-bearing type,
        // so it does not become a Topic, but its objectives flow to children.
        let json = """
        {
            "umcf": "1.0",
            "id": {"value": "inherit-objectives"},
            "title": "Inheritance",
            "version": {"number": "1.0.0"},
            "content": [
                {
                    "id": {"value": "unit-1"},
                    "title": "Unit One",
                    "type": "unit",
                    "learningObjectives": [
                        {"id": {"value": "p-obj"}, "statement": "Parent goal"}
                    ],
                    "children": [
                        {
                            "id": {"value": "child-topic"},
                            "title": "Child Topic",
                            "type": "topic",
                            "learningObjectives": [
                                {"id": {"value": "c-obj"}, "statement": "Child goal"}
                            ]
                        }
                    ]
                }
            ]
        }
        """
        let document = try await parser.parse(data: data(json))

        let curriculum = try await parser.importToCoreData(document: document)

        // The unit is not topic-bearing, so only the child becomes a topic.
        let topics = sortedTopics(curriculum)
        XCTAssertEqual(topics.count, 1)
        let child = topics[0]
        let objectives = child.objectives ?? []
        // Child's own objective comes first, then the inherited parent objective.
        XCTAssertTrue(objectives.contains("Child goal"))
        XCTAssertTrue(objectives.contains("Parent goal"))
    }

    @MainActor
    func testImport_ignoresNonTopicContentNodeTypes() async throws {
        // A node whose type is not topic/subtopic/lesson must not create a Topic,
        // but its children of valid types still import.
        let json = """
        {
            "umcf": "1.0",
            "id": {"value": "type-filtering"},
            "title": "Type Filtering",
            "version": {"number": "1.0.0"},
            "content": [
                {
                    "id": {"value": "module-1"},
                    "title": "A Module",
                    "type": "module",
                    "children": [
                        {"id": {"value": "lesson-1"}, "title": "Lesson One", "type": "lesson"},
                        {"id": {"value": "subtopic-1"}, "title": "Sub One", "type": "subtopic"}
                    ]
                }
            ]
        }
        """
        let document = try await parser.parse(data: data(json))

        let curriculum = try await parser.importToCoreData(document: document)

        let topics = sortedTopics(curriculum)
        // Module excluded, lesson and subtopic included.
        XCTAssertEqual(topics.count, 2)
        let titles = topics.map { $0.title }
        XCTAssertTrue(titles.contains("Lesson One"))
        XCTAssertTrue(titles.contains("Sub One"))
        XCTAssertFalse(titles.contains("A Module"))
    }

    // MARK: - Depth Level Parsing

    @MainActor
    func testImport_parsesContentDepthFromTutoringConfig() async throws {
        let json = """
        {
            "umcf": "1.0",
            "id": {"value": "depth-test"},
            "title": "Depth",
            "version": {"number": "1.0.0"},
            "content": [
                {
                    "id": {"value": "t-advanced"},
                    "title": "Advanced One",
                    "type": "topic",
                    "tutoringConfig": {"contentDepth": "advanced"}
                }
            ]
        }
        """
        let document = try await parser.parse(data: data(json))

        let curriculum = try await parser.importToCoreData(document: document)

        let topic = sortedTopics(curriculum).first
        XCTAssertEqual(topic?.depthLevel, .advanced)
    }

    @MainActor
    func testImport_defaultsToIntermediateDepthWhenUnspecified() async throws {
        let json = """
        {
            "umcf": "1.0",
            "id": {"value": "depth-default"},
            "title": "Depth Default",
            "version": {"number": "1.0.0"},
            "content": [
                {"id": {"value": "t-plain"}, "title": "Plain Topic", "type": "topic"}
            ]
        }
        """
        let document = try await parser.parse(data: data(json))

        let curriculum = try await parser.importToCoreData(document: document)

        let topic = sortedTopics(curriculum).first
        XCTAssertEqual(topic?.depthLevel, .intermediate)
    }

    @MainActor
    func testImport_defaultsToIntermediateForUnknownDepthString() async throws {
        let json = """
        {
            "umcf": "1.0",
            "id": {"value": "depth-bogus"},
            "title": "Depth Bogus",
            "version": {"number": "1.0.0"},
            "content": [
                {
                    "id": {"value": "t-bogus"},
                    "title": "Bogus Depth",
                    "type": "topic",
                    "tutoringConfig": {"contentDepth": "not-a-real-depth"}
                }
            ]
        }
        """
        let document = try await parser.parse(data: data(json))

        let curriculum = try await parser.importToCoreData(document: document)

        let topic = sortedTopics(curriculum).first
        XCTAssertEqual(topic?.depthLevel, .intermediate)
    }

    // MARK: - Selective Import Semantics

    @MainActor
    func testStaticImport_emptySelectionImportsAllTopics() async throws {
        // An empty selectedTopicIds set is documented to import all topics.
        let json = """
        {
            "umcf": "1.0",
            "id": {"value": "empty-selection"},
            "title": "Empty Selection",
            "version": {"number": "1.0.0"},
            "content": [
                {"id": {"value": "a"}, "title": "A", "type": "topic"},
                {"id": {"value": "b"}, "title": "B", "type": "topic"}
            ]
        }
        """
        let document = try JSONDecoder().decode(UMCFDocument.self, from: data(json))

        let curriculum = try UMCFParser.importDocument(
            document,
            selectedTopicIds: Set<String>(),
            persistenceController: persistenceController
        )

        XCTAssertEqual(sortedTopics(curriculum).count, 2)
    }

    @MainActor
    func testStaticImport_selectiveImportReindexesOrderContiguously() async throws {
        // When topic-a is skipped, the imported topics get contiguous order
        // indices starting at 0 (b -> 0, c -> 1), not their original positions.
        let json = """
        {
            "umcf": "1.0",
            "id": {"value": "reindex-selection"},
            "title": "Reindex",
            "version": {"number": "1.0.0"},
            "content": [
                {"id": {"value": "a"}, "title": "A", "type": "topic"},
                {"id": {"value": "b"}, "title": "B", "type": "topic"},
                {"id": {"value": "c"}, "title": "C", "type": "topic"}
            ]
        }
        """
        let document = try JSONDecoder().decode(UMCFDocument.self, from: data(json))

        let curriculum = try UMCFParser.importDocument(
            document,
            selectedTopicIds: Set(["b", "c"]),
            persistenceController: persistenceController
        )

        let topics = sortedTopics(curriculum)
        XCTAssertEqual(topics.count, 2)
        XCTAssertEqual(topics[0].title, "B")
        XCTAssertEqual(topics[0].orderIndex, 0)
        XCTAssertEqual(topics[1].title, "C")
        XCTAssertEqual(topics[1].orderIndex, 1)
    }

    // MARK: - Transcript Content Formatting

    @MainActor
    func testImport_transcriptContentIncludesSegmentTypeAndSpeakingNotes() async throws {
        let json = """
        {
            "umcf": "1.0",
            "id": {"value": "transcript-format"},
            "title": "Transcript Format",
            "version": {"number": "1.0.0"},
            "content": [
                {
                    "id": {"value": "t-trans"},
                    "title": "Transcript Topic",
                    "type": "topic",
                    "transcript": {
                        "segments": [
                            {
                                "id": "s1",
                                "type": "introduction",
                                "content": "Welcome.",
                                "speakingNotes": {"pace": "slow", "emotionalTone": "warm"}
                            },
                            {
                                "id": "s2",
                                "type": "explanation",
                                "content": "Here is the idea."
                            }
                        ],
                        "totalDuration": "PT5M"
                    }
                }
            ]
        }
        """
        let document = try await parser.parse(data: data(json))

        let curriculum = try await parser.importToCoreData(document: document)

        let topic = try XCTUnwrap(sortedTopics(curriculum).first)
        let doc = try XCTUnwrap((topic.documents?.allObjects as? [Document])?.first)
        let content = try XCTUnwrap(doc.content)

        // Segment type is uppercased and prefixed in brackets.
        XCTAssertTrue(content.contains("[INTRODUCTION] Welcome."))
        XCTAssertTrue(content.contains("[EXPLANATION] Here is the idea."))
        // Speaking notes annotated inline.
        XCTAssertTrue(content.contains("[PACE: slow]"))
        XCTAssertTrue(content.contains("[TONE: warm]"))
        // Segments are joined with a separator.
        XCTAssertTrue(content.contains("---"))

        // Decoded transcript carries structured speaking notes through.
        let decoded = try XCTUnwrap(doc.decodedTranscript())
        XCTAssertEqual(decoded.segments.count, 2)
        XCTAssertEqual(decoded.totalDuration, "PT5M")
        XCTAssertEqual(decoded.segments.first?.speakingNotes?.pace, "slow")
        XCTAssertEqual(decoded.segments.first?.speakingNotes?.emotionalTone, "warm")
    }

    // MARK: - Visual Asset Timing Defaults

    @MainActor
    func testImport_embeddedAssetWithSegmentTimingSetsRange() async throws {
        let json = """
        {
            "umcf": "1.0",
            "id": {"value": "asset-timing"},
            "title": "Asset Timing",
            "version": {"number": "1.0.0"},
            "content": [
                {
                    "id": {"value": "t-asset"},
                    "title": "Asset Topic",
                    "type": "topic",
                    "media": {
                        "embedded": [
                            {
                                "id": "timed-img",
                                "type": "image",
                                "url": "https://example.com/a.png",
                                "segmentTiming": {"startSegment": 2, "endSegment": 5, "displayMode": "highlight"}
                            }
                        ]
                    }
                }
            ]
        }
        """
        let document = try await parser.parse(data: data(json))

        let curriculum = try await parser.importToCoreData(document: document)

        let topic = try XCTUnwrap(sortedTopics(curriculum).first)
        let asset = try XCTUnwrap((topic.visualAssets?.allObjects as? [VisualAsset])?.first)

        XCTAssertEqual(asset.startSegment, 2)
        XCTAssertEqual(asset.endSegment, 5)
        XCTAssertEqual(asset.displayMode, "highlight")
        XCTAssertFalse(asset.isReference)
        XCTAssertEqual(asset.remoteURL?.absoluteString, "https://example.com/a.png")
    }

    @MainActor
    func testImport_assetWithoutTimingDefaultsToPersistentAlwaysVisible() async throws {
        let json = """
        {
            "umcf": "1.0",
            "id": {"value": "asset-default-timing"},
            "title": "Asset Default Timing",
            "version": {"number": "1.0.0"},
            "content": [
                {
                    "id": {"value": "t-asset2"},
                    "title": "Asset Topic 2",
                    "type": "topic",
                    "media": {
                        "embedded": [
                            {"id": "untimed-img", "type": "image"}
                        ]
                    }
                }
            ]
        }
        """
        let document = try await parser.parse(data: data(json))

        let curriculum = try await parser.importToCoreData(document: document)

        let topic = try XCTUnwrap(sortedTopics(curriculum).first)
        let asset = try XCTUnwrap((topic.visualAssets?.allObjects as? [VisualAsset])?.first)

        // No timing means always visible: sentinel -1 range and persistent mode.
        XCTAssertEqual(asset.startSegment, -1)
        XCTAssertEqual(asset.endSegment, -1)
        XCTAssertEqual(asset.displayMode, "persistent")
    }

    // MARK: - Curriculum Metadata From Lifecycle

    @MainActor
    func testImport_parsesLifecycleDatesIntoTimestamps() async throws {
        let json = """
        {
            "umcf": "1.0",
            "id": {"value": "lifecycle-dates"},
            "title": "Lifecycle",
            "version": {"number": "1.0.0"},
            "lifecycle": {
                "created": "2024-01-15T10:30:00Z",
                "modified": "2024-06-20T08:00:00Z"
            },
            "content": []
        }
        """
        let document = try await parser.parse(data: data(json))

        let curriculum = try await parser.importToCoreData(document: document)

        // ISO8601 without fractional seconds should still parse via the fallback path.
        let created = try XCTUnwrap(curriculum.createdAt)
        let updated = try XCTUnwrap(curriculum.updatedAt)
        XCTAssertLessThan(created, updated)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(created, formatter.date(from: "2024-01-15T10:30:00Z"))
    }
}
