// UnaMentis - Reading Summary Pre-Generator Tests
// Unit tests for chunk grouping, status transitions, and outline parsing.
//
// The LLM is a paid external API, so MockLLMService stands in for it. The store
// is real, pointed at a temporary directory.

import XCTest
@testable import UnaMentis

final class ReadingSummaryPreGeneratorTests: XCTestCase {

    private var storeDirectory: URL!
    private var store: ReadingSummaryStore!

    override func setUp() async throws {
        storeDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ReadingSummaryTests-\(UUID().uuidString)", isDirectory: true)
        store = ReadingSummaryStore(directoryURL: storeDirectory)
    }

    override func tearDown() async throws {
        if let storeDirectory {
            try? FileManager.default.removeItem(at: storeDirectory)
        }
        store = nil
        storeDirectory = nil
    }

    // MARK: - Helpers

    private func makeChunks(_ count: Int) -> [PreGenChunkSpec] {
        (0..<count).map { PreGenChunkSpec(index: Int32($0), text: "Sentence number \($0).") }
    }

    private func makeGenerator(llm: MockLLMService?) -> ReadingSummaryPreGenerator {
        ReadingSummaryPreGenerator(store: store) { llm }
    }

    // MARK: - Grouping

    func testGrouping_withoutMarkersUsesFixedSizeSections() {
        let sections = ReadingSectionGrouper.makeSections(totalChunks: 36, target: 12)

        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(sections[0].startChunkIndex, 0)
        XCTAssertEqual(sections[0].endChunkIndex, 11)
        XCTAssertEqual(sections[2].endChunkIndex, 35)
        XCTAssertNil(sections[0].title)
    }

    func testGrouping_coversEveryChunkExactlyOnce() {
        for total in [1, 7, 8, 15, 16, 40, 137, 400] {
            let sections = ReadingSectionGrouper.makeSections(totalChunks: total)
            XCTAssertEqual(sections.first?.startChunkIndex, 0, "total=\(total)")
            XCTAssertEqual(sections.last?.endChunkIndex, Int32(total - 1), "total=\(total)")
            for pair in zip(sections, sections.dropFirst()) {
                XCTAssertEqual(
                    pair.1.startChunkIndex,
                    pair.0.endChunkIndex + 1,
                    "Sections must be contiguous (total=\(total))"
                )
            }
        }
    }

    func testGrouping_emptyDocumentProducesNoSections() {
        XCTAssertTrue(ReadingSectionGrouper.makeSections(totalChunks: 0).isEmpty)
    }

    func testGrouping_shortDocumentIsOneSection() {
        let sections = ReadingSectionGrouper.makeSections(totalChunks: 5)

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].startChunkIndex, 0)
        XCTAssertEqual(sections[0].endChunkIndex, 4)
    }

    func testGrouping_usesMarkerBoundariesAndKeepsTitles() {
        let markers = [
            DocumentSectionMarker(title: "Intro", level: 1, chunkIndex: 0),
            DocumentSectionMarker(title: "Middle", level: 1, chunkIndex: 12),
            DocumentSectionMarker(title: "End", level: 1, chunkIndex: 24)
        ]

        let sections = ReadingSectionGrouper.makeSections(totalChunks: 36, markers: markers)

        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(sections.map(\.title), ["Intro", "Middle", "End"])
        XCTAssertEqual(sections[1].startChunkIndex, 12)
        XCTAssertEqual(sections[1].endChunkIndex, 23)
    }

    func testGrouping_addsAnUntitledOpeningSectionWhenTheFirstHeadingIsLater() {
        let markers = [DocumentSectionMarker(title: "Chapter 1", level: 1, chunkIndex: 10)]

        let sections = ReadingSectionGrouper.makeSections(totalChunks: 30, markers: markers)

        XCTAssertEqual(sections.first?.startChunkIndex, 0)
        XCTAssertNil(sections.first?.title, "Front matter before the first heading has no title")
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[1].title, "Chapter 1")
    }

    func testGrouping_splitsOversizedMarkerSections() {
        let markers = [DocumentSectionMarker(title: "Long", level: 1, chunkIndex: 0)]

        let sections = ReadingSectionGrouper.makeSections(totalChunks: 60, markers: markers)

        XCTAssertGreaterThan(sections.count, 1, "A 60-chunk section must be split")
        for section in sections {
            XCTAssertLessThanOrEqual(section.chunkCount, ReadingSectionGrouper.maxChunksPerSection)
        }
        XCTAssertEqual(sections[0].title, "Long")
        XCTAssertNil(sections[1].title, "Continuation pieces carry no heading")
    }

    func testGrouping_mergesUndersizedMarkerSections() {
        // Headings two chunks apart would make sections far too small to summarize.
        let markers = (0..<10).map {
            DocumentSectionMarker(title: "H\($0)", level: 2, chunkIndex: Int32($0 * 2))
        }

        let sections = ReadingSectionGrouper.makeSections(totalChunks: 20, markers: markers)

        for section in sections where section.endChunkIndex < 19 {
            XCTAssertGreaterThanOrEqual(
                section.chunkCount,
                ReadingSectionGrouper.minChunksPerSection
            )
        }
    }

    func testGrouping_ignoresMarkersOutsideTheDocument() {
        let markers = [
            DocumentSectionMarker(title: "Bad", level: 1, chunkIndex: 500),
            DocumentSectionMarker(title: "Good", level: 1, chunkIndex: 12)
        ]

        let sections = ReadingSectionGrouper.makeSections(totalChunks: 30, markers: markers)

        XCTAssertFalse(sections.contains { $0.title == "Bad" })
        XCTAssertTrue(sections.contains { $0.title == "Good" })
    }

    // MARK: - Status transitions

    func testPreGenerate_withNoLLMLeavesStatusPending() async {
        let generator = makeGenerator(llm: nil)
        let itemId = UUID()

        await generator.preGenerate(itemId: itemId, title: "Doc", chunks: makeChunks(30))
        await generator.waitForGeneration(itemId: itemId)

        let record = await store.load(itemId: itemId)
        XCTAssertEqual(record?.status, .pending, "No LLM means defer, not fail")
        XCTAssertTrue(record?.sections.isEmpty ?? false)
    }

    func testPreGenerate_withWorkingLLMCompletesWithSectionsAndOutline() async {
        let mock = MockLLMService()
        await mock.configure(summaryResponse: "The section explains a thing.")
        let generator = makeGenerator(llm: mock)
        let itemId = UUID()

        await generator.preGenerate(itemId: itemId, title: "Doc", chunks: makeChunks(36))
        await generator.waitForGeneration(itemId: itemId)

        let record = await store.load(itemId: itemId)
        XCTAssertEqual(record?.status, .completed)
        XCTAssertEqual(record?.sections.count, 3)
        XCTAssertNotNil(record?.outline)
        XCTAssertNotNil(record?.generatedAt)
        XCTAssertEqual(record?.totalChunks, 36)
    }

    func testPreGenerate_withFailingLLMMarksFailed() async {
        let mock = MockLLMService()
        await mock.configureToFail(with: .rateLimited(retryAfter: 30))
        let generator = makeGenerator(llm: mock)
        let itemId = UUID()

        await generator.preGenerate(itemId: itemId, title: "Doc", chunks: makeChunks(30))
        await generator.waitForGeneration(itemId: itemId)

        let record = await store.load(itemId: itemId)
        XCTAssertEqual(record?.status, .failed)
        XCTAssertTrue(record?.sections.isEmpty ?? false)
        XCTAssertNotNil(record?.lastAttemptAt)
    }

    func testPreGenerate_skipsWorkWhenACompletedRecordAlreadyCoversTheDocument() async {
        let mock = MockLLMService()
        let generator = makeGenerator(llm: mock)
        let itemId = UUID()

        await generator.preGenerate(itemId: itemId, title: "Doc", chunks: makeChunks(36))
        await generator.waitForGeneration(itemId: itemId)
        let firstCallCount = await mock.streamCompletionCallCount

        await generator.preGenerate(itemId: itemId, title: "Doc", chunks: makeChunks(36))
        await generator.waitForGeneration(itemId: itemId)
        let secondCallCount = await mock.streamCompletionCallCount

        XCTAssertEqual(firstCallCount, secondCallCount, "A complete record is not regenerated")
    }

    func testPreGenerate_regeneratesWhenTheChunkCountChanged() async {
        let mock = MockLLMService()
        let generator = makeGenerator(llm: mock)
        let itemId = UUID()

        await generator.preGenerate(itemId: itemId, title: "Doc", chunks: makeChunks(36))
        await generator.waitForGeneration(itemId: itemId)
        let firstCallCount = await mock.streamCompletionCallCount

        await generator.preGenerate(itemId: itemId, title: "Doc", chunks: makeChunks(60))
        await generator.waitForGeneration(itemId: itemId)
        let secondCallCount = await mock.streamCompletionCallCount

        XCTAssertGreaterThan(secondCallCount, firstCallCount)
        let record = await store.load(itemId: itemId)
        XCTAssertEqual(record?.totalChunks, 60)
    }

    func testPreGenerate_retriesAfterAPendingResult() async {
        let itemId = UUID()

        let deferred = makeGenerator(llm: nil)
        await deferred.preGenerate(itemId: itemId, title: "Doc", chunks: makeChunks(30))
        await deferred.waitForGeneration(itemId: itemId)
        let pending = await store.load(itemId: itemId)
        XCTAssertEqual(pending?.status, .pending)

        // Next opportunity: an LLM is available now.
        let mock = MockLLMService()
        let generator = makeGenerator(llm: mock)
        await generator.preGenerate(itemId: itemId, title: "Doc", chunks: makeChunks(30))
        await generator.waitForGeneration(itemId: itemId)

        let record = await store.load(itemId: itemId)
        XCTAssertEqual(record?.status, .completed)
        XCTAssertFalse(record?.sections.isEmpty ?? true)
    }

    func testPreGenerate_ignoresEmptyDocuments() async {
        let mock = MockLLMService()
        let generator = makeGenerator(llm: mock)
        let itemId = UUID()

        await generator.preGenerate(itemId: itemId, title: "Doc", chunks: [])
        await generator.waitForGeneration(itemId: itemId)

        let callCount = await mock.streamCompletionCallCount
        XCTAssertEqual(callCount, 0)
        let record = await store.load(itemId: itemId)
        XCTAssertNil(record)
    }

    func testPreGenerate_sectionSummariesCoverEveryChunk() async {
        let mock = MockLLMService()
        let generator = makeGenerator(llm: mock)
        let itemId = UUID()

        await generator.preGenerate(itemId: itemId, title: "Doc", chunks: makeChunks(40))
        await generator.waitForGeneration(itemId: itemId)

        let sections = await store.load(itemId: itemId)?.sections ?? []
        XCTAssertEqual(sections.first?.startChunkIndex, 0)
        XCTAssertEqual(sections.last?.endChunkIndex, 39)
    }

    // MARK: - Persistence

    func testStoreRoundTrip_survivesANewStoreInstance() async {
        let mock = MockLLMService()
        let generator = makeGenerator(llm: mock)
        let itemId = UUID()

        await generator.preGenerate(itemId: itemId, title: "Doc", chunks: makeChunks(36))
        await generator.waitForGeneration(itemId: itemId)

        // A fresh store reads from disk rather than the in-memory cache.
        let reopened = ReadingSummaryStore(directoryURL: storeDirectory)
        let record = await reopened.load(itemId: itemId)

        XCTAssertEqual(record?.status, .completed)
        XCTAssertEqual(record?.sections.count, 3)
        XCTAssertNotNil(record?.outline)
    }

    func testStoreDelete_removesTheRecord() async {
        let record = ReadingDocumentSummaryRecord(itemId: UUID(), status: .completed, totalChunks: 5)
        await store.save(record)
        let saved = await store.load(itemId: record.itemId)
        XCTAssertNotNil(saved)

        await store.delete(itemId: record.itemId)
        let reopened = ReadingSummaryStore(directoryURL: storeDirectory)
        let afterDelete = await reopened.load(itemId: record.itemId)
        XCTAssertNil(afterDelete)
    }

    // MARK: - Outline parsing

    func testParseOutline_readsOverviewAndNumberedLines() {
        let summaries = (0..<3).map {
            ReadingSectionSummary(
                index: $0,
                startChunkIndex: Int32($0 * 10),
                endChunkIndex: Int32($0 * 10 + 9),
                title: nil,
                summary: "Section \($0) summary."
            )
        }
        let response = """
        Overview: A short guide to widgets.
        1. Introduces widgets
        2. Explains assembly
        3. Covers maintenance
        """

        let outline = ReadingSummaryPreGenerator.parseOutline(response, summaries: summaries)

        XCTAssertEqual(outline.overview, "A short guide to widgets.")
        XCTAssertEqual(outline.entries.count, 3)
        XCTAssertEqual(outline.entries[0].line, "Introduces widgets")
        XCTAssertEqual(outline.entries[2].line, "Covers maintenance")
    }

    func testParseOutline_fillsGapsFromTheSectionSummaries() {
        let summaries = (0..<3).map {
            ReadingSectionSummary(
                index: $0,
                startChunkIndex: Int32($0 * 10),
                endChunkIndex: Int32($0 * 10 + 9),
                title: nil,
                summary: "Section \($0) summary. Extra detail."
            )
        }
        // The model skipped section 2.
        let response = """
        Overview: A short guide.
        1. First
        2. Second
        """

        let outline = ReadingSummaryPreGenerator.parseOutline(response, summaries: summaries)

        XCTAssertEqual(outline.entries.count, 3)
        XCTAssertEqual(outline.entries[2].line, "Section 2 summary.")
    }

    func testFallbackOutline_usesTheFirstSentenceOfEachSummary() {
        let summaries = [
            ReadingSectionSummary(
                index: 0,
                startChunkIndex: 0,
                endChunkIndex: 9,
                title: "Intro",
                summary: "It opens the topic. It then adds detail."
            )
        ]

        let outline = ReadingSummaryPreGenerator.fallbackOutline(title: "Doc", summaries: summaries)

        XCTAssertEqual(outline.overview, "It opens the topic.")
        XCTAssertEqual(outline.entries.first?.line, "It opens the topic.")
        XCTAssertEqual(outline.entries.first?.title, "Intro")
    }

    func testSectionPrompt_mentionsTheSectionTitleWhenKnown() {
        let withTitle = ReadingSummaryPreGenerator.sectionPrompt(
            title: "Doc",
            sectionTitle: "Chapter 3",
            text: "body"
        )
        let withoutTitle = ReadingSummaryPreGenerator.sectionPrompt(
            title: "Doc",
            sectionTitle: nil,
            text: "body"
        )

        XCTAssertTrue(withTitle.contains("Chapter 3"))
        XCTAssertFalse(withoutTitle.contains("titled"))
    }
}
