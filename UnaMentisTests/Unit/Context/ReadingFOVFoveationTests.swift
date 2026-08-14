// UnaMentis - Reading FOV Foveation Tests
// Unit tests for foveated context assembly and granularity-aware trimming.
//
// The assembly and trimming logic is deterministic and takes precomputed
// summaries as input, so these tests need no LLM.

import XCTest
@testable import UnaMentis

final class ReadingFOVFoveationTests: XCTestCase {

    // MARK: - Helpers

    private func makeChunks(count: Int, text: (Int) -> String) -> [ReadingChunkData] {
        (0..<count).map { index in
            ReadingChunkData(
                index: Int32(index),
                text: text(index),
                characterOffset: 0,
                estimatedDurationSeconds: 1.0
            )
        }
    }

    /// A record covering `count` chunks in sections of `size` chunks each
    private func makeRecord(
        chunkCount: Int,
        sectionSize: Int,
        withOutline: Bool = true
    ) -> ReadingDocumentSummaryRecord {
        var sections: [ReadingSectionSummary] = []
        var start = 0
        var index = 0
        while start < chunkCount {
            let end = min(start + sectionSize - 1, chunkCount - 1)
            sections.append(ReadingSectionSummary(
                index: index,
                startChunkIndex: Int32(start),
                endChunkIndex: Int32(end),
                title: "Title\(index)",
                summary: "Summary of section \(index)."
            ))
            start = end + 1
            index += 1
        }

        let outline = withOutline
            ? ReadingDocumentOutline(
                overview: "A book about testing.",
                entries: sections.map {
                    ReadingOutlineEntry(
                        sectionIndex: $0.index,
                        title: $0.title,
                        line: "line for section \($0.index)"
                    )
                }
            )
            : nil

        return ReadingDocumentSummaryRecord(
            itemId: UUID(),
            status: .completed,
            totalChunks: chunkCount,
            sections: sections,
            outline: outline,
            generatedAt: Date()
        )
    }

    // MARK: - Assembly

    func testBuildContext_withoutSummaryLeavesFoveatedBandsEmpty() async {
        let manager = ReadingFOVContextManager()
        let chunks = makeChunks(count: 5) { "chunk\($0)" }

        let window = await manager.buildContext(chunks: chunks, currentIndex: 2, title: "Doc")

        XCTAssertEqual(window.outlineText, "")
        XCTAssertEqual(window.earlierSummaryText, "")
        XCTAssertEqual(window.upcomingSummaryText, "")
        XCTAssertEqual(window.currentText, "chunk2")
    }

    func testBuildContext_includesOutlineAndBothSummaryBands() async {
        let manager = ReadingFOVContextManager(precedingChunkCount: 3, followingChunkCount: 2)
        let chunks = makeChunks(count: 100) { "chunk\($0)" }
        let record = makeRecord(chunkCount: 100, sectionSize: 10)

        let window = await manager.buildContext(
            chunks: chunks,
            currentIndex: 50,
            title: "Doc",
            summary: record
        )

        XCTAssertTrue(window.outlineText.contains("Overview: A book about testing."))
        XCTAssertTrue(window.outlineText.contains("line for section 0"))
        XCTAssertFalse(window.earlierSummaryText.isEmpty, "Sections before the near window form the Earlier band")
        XCTAssertFalse(window.upcomingSummaryText.isEmpty, "Sections after the near window form the Upcoming band")
        XCTAssertEqual(window.currentText, "chunk50")
        XCTAssertEqual(window.precedingText, "chunk47\n\nchunk48\n\nchunk49")
        XCTAssertEqual(window.followingText, "chunk51\n\nchunk52")
    }

    func testBuildContext_bandsExcludeSectionsCoveredByTheNearWindow() async {
        let manager = ReadingFOVContextManager(precedingChunkCount: 3, followingChunkCount: 2)
        let chunks = makeChunks(count: 100) { "chunk\($0)" }
        let record = makeRecord(chunkCount: 100, sectionSize: 10)

        let window = await manager.buildContext(
            chunks: chunks,
            currentIndex: 50,
            title: "Doc",
            summary: record
        )

        // The near window spans chunks 47...52, which is section 5 (chunks 50-59)
        // and section 4 (chunks 40-49). Neither may appear in a summary band.
        XCTAssertFalse(window.earlierSummaryText.contains("Summary of section 4."))
        XCTAssertFalse(window.upcomingSummaryText.contains("Summary of section 5."))
        XCTAssertTrue(window.earlierSummaryText.contains("Summary of section 3."))
        XCTAssertTrue(window.upcomingSummaryText.contains("Summary of section 6."))
    }

    func testFullContext_ordersSectionsCoarseToFineAndBackOut() async {
        let manager = ReadingFOVContextManager()
        let chunks = makeChunks(count: 100) { "chunk\($0)" }
        let record = makeRecord(chunkCount: 100, sectionSize: 10)

        let window = await manager.buildContext(
            chunks: chunks,
            currentIndex: 50,
            title: "Doc",
            summary: record
        )
        let full = window.fullContext

        let markers = [
            "## Document Outline",
            "## Earlier in the Document",
            "## Previously Read",
            "## Currently Reading",
            "## Coming Up Next",
            "## Later in the Document"
        ]

        var searchStart = full.startIndex
        for marker in markers {
            guard let range = full.range(of: marker, range: searchStart..<full.endIndex) else {
                return XCTFail("Missing section \(marker), or it appeared out of order")
            }
            searchStart = range.upperBound
        }
    }

    // MARK: - Trimming order

    func testTrimming_dropsDistantSummariesBeforeTheNearWindow() async {
        let chunks = makeChunks(count: 200) { "chunk\($0)" }
        let record = makeRecord(chunkCount: 200, sectionSize: 10)

        // Measure the untrimmed context, then set a budget that can be met by
        // giving up part of one summary band and nothing else.
        let unlimited = ReadingFOVContextManager(maxTotalCharacters: 1_000_000)
        let full = await unlimited.buildContext(
            chunks: chunks,
            currentIndex: 100,
            title: "Doc",
            summary: record
        )
        let budget = full.fullContext.count - (full.earlierSummaryText.count / 2)

        let manager = ReadingFOVContextManager(maxTotalCharacters: budget)
        let window = await manager.buildContext(
            chunks: chunks,
            currentIndex: 100,
            title: "Doc",
            summary: record
        )

        XCTAssertLessThanOrEqual(window.fullContext.count, budget)
        // The near window is the last raw thing to go, so it survives untouched.
        XCTAssertEqual(window.currentText, "chunk100")
        XCTAssertEqual(window.precedingText, full.precedingText)
        XCTAssertEqual(window.followingText, full.followingText)
        // Section 0 is the farthest behind, so it is dropped before nearer ones.
        XCTAssertFalse(window.earlierSummaryText.contains("Summary of section 0."))
        XCTAssertTrue(window.outlineText.contains("Overview:"), "The outline is compressed last")
    }

    func testTrimming_neverDropsTheOutlineEntirely() async {
        // A budget so tight that everything droppable has to go.
        let manager = ReadingFOVContextManager(
            precedingChunkCount: 3,
            followingChunkCount: 2,
            maxSectionCharacters: 4000,
            maxTotalCharacters: 1
        )
        let chunks = makeChunks(count: 200) { "chunk\($0)" }
        let record = makeRecord(chunkCount: 200, sectionSize: 10)

        let window = await manager.buildContext(
            chunks: chunks,
            currentIndex: 100,
            title: "Doc",
            summary: record
        )

        XCTAssertTrue(
            window.outlineText.contains("Overview: A book about testing."),
            "The outline is compressed to its overview but never removed"
        )
        XCTAssertEqual(window.earlierSummaryText, "", "Summary bands go first")
        XCTAssertEqual(window.upcomingSummaryText, "")
        XCTAssertEqual(window.precedingText, "", "The near window shrinks to the current chunk")
        XCTAssertEqual(window.followingText, "")
        XCTAssertEqual(window.currentText, "chunk100", "The current chunk is never dropped")
    }

    func testTrimming_shrinksNearWindowFromItsOuterEdges() async {
        let manager = ReadingFOVContextManager(
            precedingChunkCount: 3,
            followingChunkCount: 2,
            maxSectionCharacters: 4000,
            maxTotalCharacters: 1
        )
        // No summaries, so the near window is the only droppable content.
        let chunks = makeChunks(count: 20) { "chunk\($0)" }

        let window = await manager.buildContext(chunks: chunks, currentIndex: 10, title: "Doc")

        XCTAssertEqual(window.precedingText, "")
        XCTAssertEqual(window.followingText, "")
        XCTAssertEqual(window.currentText, "chunk10")
    }

    // MARK: - Band fitting (no blind suffix truncation)

    func testBandFitting_dropsWholeChunksRatherThanClippingCharacters() async {
        let manager = ReadingFOVContextManager(
            precedingChunkCount: 3,
            followingChunkCount: 1,
            maxSectionCharacters: 50
        )
        let head = String(repeating: "H", count: 100)
        let tail = String(repeating: "T", count: 40)
        let chunks = [
            ReadingChunkData(index: 0, text: head, characterOffset: 0, estimatedDurationSeconds: 1),
            ReadingChunkData(index: 1, text: tail, characterOffset: 0, estimatedDurationSeconds: 1),
            ReadingChunkData(index: 2, text: "current", characterOffset: 0, estimatedDurationSeconds: 1)
        ]

        let window = await manager.buildContext(chunks: chunks, currentIndex: 2, title: "Doc")

        XCTAssertEqual(
            window.precedingText,
            tail,
            "The far chunk is dropped whole; the near chunk survives intact"
        )
        XCTAssertFalse(window.precedingText.contains("H"))
    }

    func testSentenceTrim_keepsWholeSentencesFromTheEndWhenKeepingTail() {
        let text = "First sentence here. Second sentence here. Third sentence here."
        let trimmed = ReadingFOVContextManager.trimToSentenceBoundary(text, limit: 45, keepingTail: true)

        XCTAssertLessThanOrEqual(trimmed.count, 45)
        XCTAssertTrue(trimmed.hasSuffix("Third sentence here."))
        XCTAssertFalse(trimmed.contains("First sentence"))
    }

    func testSentenceTrim_keepsWholeSentencesFromTheStartWhenKeepingHead() {
        let text = "First sentence here. Second sentence here. Third sentence here."
        let trimmed = ReadingFOVContextManager.trimToSentenceBoundary(text, limit: 45, keepingTail: false)

        XCTAssertLessThanOrEqual(trimmed.count, 45)
        XCTAssertTrue(trimmed.hasPrefix("First sentence here."))
        XCTAssertFalse(trimmed.contains("Third sentence"))
    }

    func testSentenceTrim_returnsTextUnchangedWhenItAlreadyFits() {
        let text = "Short enough."
        XCTAssertEqual(
            ReadingFOVContextManager.trimToSentenceBoundary(text, limit: 100, keepingTail: true),
            text
        )
    }

    func testSentenceTrim_fallsBackToWordBoundaryForOneLongSentence() {
        let text = String(repeating: "word ", count: 100).trimmingCharacters(in: .whitespaces)
        let trimmed = ReadingFOVContextManager.trimToSentenceBoundary(text, limit: 20, keepingTail: true)

        XCTAssertLessThanOrEqual(trimmed.count, 20)
        XCTAssertFalse(trimmed.isEmpty)
        XCTAssertFalse(trimmed.hasPrefix(" "), "Word-boundary trimming leaves no dangling separator")
    }

    // MARK: - Barge-in messages

    func testBuildBargeInMessages_systemMessageCarriesTheFoveatedContext() async {
        let manager = ReadingFOVContextManager()
        let chunks = makeChunks(count: 100) { "chunk\($0)" }
        let record = makeRecord(chunkCount: 100, sectionSize: 10)

        let messages = await manager.buildBargeInMessages(
            question: "What was that about?",
            chunks: chunks,
            currentIndex: 50,
            title: "Doc",
            summary: record
        )

        XCTAssertEqual(messages.first?.role, .system)
        XCTAssertTrue(messages.first?.content.contains("## Document Outline") ?? false)
        XCTAssertEqual(messages.last?.content, "What was that about?")
    }

    // MARK: - Record helpers

    func testSectionSummary_distanceIsZeroInsideTheSection() {
        let section = ReadingSectionSummary(
            index: 0,
            startChunkIndex: 10,
            endChunkIndex: 20,
            title: nil,
            summary: "s"
        )

        XCTAssertEqual(section.distance(from: 15), 0)
        XCTAssertEqual(section.distance(from: 5), 5)
        XCTAssertEqual(section.distance(from: 25), 5)
    }

    func testRecord_needsGenerationWhenChunkCountChanged() {
        let record = ReadingDocumentSummaryRecord(
            itemId: UUID(),
            status: .completed,
            totalChunks: 50,
            sections: [
                ReadingSectionSummary(
                    index: 0,
                    startChunkIndex: 0,
                    endChunkIndex: 49,
                    title: nil,
                    summary: "s"
                )
            ]
        )

        XCTAssertFalse(record.needsGeneration(forChunkCount: 50))
        XCTAssertTrue(record.needsGeneration(forChunkCount: 60), "Re-chunked documents are stale")
    }

    func testRecord_needsGenerationForEveryUnfinishedStatus() {
        func record(_ status: ReadingSummaryStatus) -> ReadingDocumentSummaryRecord {
            ReadingDocumentSummaryRecord(itemId: UUID(), status: status, totalChunks: 10)
        }

        XCTAssertTrue(record(.pending).needsGeneration(forChunkCount: 10))
        XCTAssertTrue(record(.failed).needsGeneration(forChunkCount: 10))
        // A persisted in-progress record means a run was interrupted, so retry.
        XCTAssertTrue(record(.inProgress).needsGeneration(forChunkCount: 10))
        // Completed but empty means something went wrong; regenerate.
        XCTAssertTrue(record(.completed).needsGeneration(forChunkCount: 10))
    }
}
