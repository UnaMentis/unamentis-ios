// UnaMentis - Reading FOV Context Manager Tests
// Unit tests for context windowing during document reading barge-in Q&A.
//
// The manager is a real actor with deterministic windowing logic and no
// external dependencies, so it is exercised directly with real inputs.

import XCTest
@testable import UnaMentis

final class ReadingFOVContextManagerTests: XCTestCase {

    var manager: ReadingFOVContextManager!

    override func setUp() async throws {
        // Small, explicit window sizes keep assertions deterministic.
        manager = ReadingFOVContextManager(
            precedingChunkCount: 2,
            followingChunkCount: 2,
            maxSectionCharacters: 4000
        )
    }

    override func tearDown() async throws {
        manager = nil
    }

    // MARK: - Helpers

    private func makeChunks(_ texts: [String]) -> [ReadingChunkData] {
        texts.enumerated().map { index, text in
            ReadingChunkData(
                index: Int32(index),
                text: text,
                characterOffset: 0,
                estimatedDurationSeconds: 1.0
            )
        }
    }

    // MARK: - buildContext windowing

    func testBuildContext_selectsCurrentChunkText() async {
        let chunks = makeChunks(["zero", "one", "two", "three", "four"])

        let window = await manager.buildContext(
            chunks: chunks,
            currentIndex: 2,
            title: "Doc"
        )

        XCTAssertEqual(window.currentText, "two")
        XCTAssertEqual(window.currentChunkIndex, 2)
        XCTAssertEqual(window.totalChunks, 5)
    }

    func testBuildContext_includesPrecedingChunksUpToLimit() async {
        let chunks = makeChunks(["zero", "one", "two", "three", "four"])

        // current = 3, precedingChunkCount = 2 -> chunks 1 and 2.
        let window = await manager.buildContext(
            chunks: chunks,
            currentIndex: 3,
            title: "Doc"
        )

        XCTAssertEqual(window.precedingText, "one\n\ntwo")
        XCTAssertFalse(window.precedingText.contains("zero"),
                       "Preceding window must respect the preceding chunk limit")
    }

    func testBuildContext_includesFollowingChunksUpToLimit() async {
        let chunks = makeChunks(["zero", "one", "two", "three", "four"])

        // current = 1, followingChunkCount = 2 -> chunks 2 and 3.
        let window = await manager.buildContext(
            chunks: chunks,
            currentIndex: 1,
            title: "Doc"
        )

        XCTAssertEqual(window.followingText, "two\n\nthree")
        XCTAssertFalse(window.followingText.contains("four"),
                       "Following window must respect the following chunk limit")
    }

    func testBuildContext_atStartHasNoPrecedingText() async {
        let chunks = makeChunks(["zero", "one", "two"])

        let window = await manager.buildContext(
            chunks: chunks,
            currentIndex: 0,
            title: "Doc"
        )

        XCTAssertEqual(window.precedingText, "", "First chunk has nothing before it")
        XCTAssertEqual(window.currentText, "zero")
        XCTAssertEqual(window.followingText, "one\n\ntwo")
    }

    func testBuildContext_atEndHasNoFollowingText() async {
        let chunks = makeChunks(["zero", "one", "two"])

        let window = await manager.buildContext(
            chunks: chunks,
            currentIndex: 2,
            title: "Doc"
        )

        XCTAssertEqual(window.followingText, "", "Last chunk has nothing after it")
        XCTAssertEqual(window.currentText, "two")
        XCTAssertEqual(window.precedingText, "zero\n\none")
    }

    func testBuildContext_precedingClampsToStart() async {
        let chunks = makeChunks(["zero", "one", "two", "three"])

        // current = 1, precedingChunkCount = 2 but only chunk 0 exists before it.
        let window = await manager.buildContext(
            chunks: chunks,
            currentIndex: 1,
            title: "Doc"
        )

        XCTAssertEqual(window.precedingText, "zero")
    }

    func testBuildContext_indexBeyondChunksGivesEmptyCurrentText() async {
        let chunks = makeChunks(["zero", "one"])

        // current index 5 is out of range.
        let window = await manager.buildContext(
            chunks: chunks,
            currentIndex: 5,
            title: "Doc"
        )

        XCTAssertEqual(window.currentText, "", "Out-of-range index yields empty current text")
        XCTAssertEqual(window.followingText, "", "No following chunks beyond the end")
        XCTAssertEqual(window.totalChunks, 2)
    }

    func testBuildContext_singleChunkHasOnlyCurrentText() async {
        let chunks = makeChunks(["only"])

        let window = await manager.buildContext(
            chunks: chunks,
            currentIndex: 0,
            title: "Doc"
        )

        XCTAssertEqual(window.currentText, "only")
        XCTAssertEqual(window.precedingText, "")
        XCTAssertEqual(window.followingText, "")
    }

    // MARK: - Section truncation

    func testBuildContext_truncatesLongPrecedingTextToSuffix() async {
        // maxSectionCharacters = 50 so preceding text gets clipped to its tail.
        let smallWindowManager = ReadingFOVContextManager(
            precedingChunkCount: 3,
            followingChunkCount: 1,
            maxSectionCharacters: 50
        )
        let head = String(repeating: "H", count: 100)
        let tail = String(repeating: "T", count: 40)
        let chunks = makeChunks([head, tail, "current"])

        let window = await smallWindowManager.buildContext(
            chunks: chunks,
            currentIndex: 2,
            title: "Doc"
        )

        XCTAssertEqual(window.precedingText.count, 50, "Preceding text should be clipped to the limit")
        XCTAssertTrue(window.precedingText.hasSuffix(tail),
                      "Truncation keeps the most recent (suffix) text")
        // The full 100-character head cannot survive a 50-character suffix clip, so
        // the oldest leading text is dropped. (A few of the head's trailing
        // characters may remain to fill out the 50-char budget, which is correct;
        // suffix truncation keeps the text closest to the current position.)
        XCTAssertFalse(window.precedingText.contains(head),
                       "Oldest leading text should be dropped during truncation")
    }

    // MARK: - fullContext rendering

    func testFullContext_includesSystemPromptTitleAndProgress() async {
        let chunks = makeChunks(["intro", "body", "end"])

        let window = await manager.buildContext(
            chunks: chunks,
            currentIndex: 1,
            title: "The Great Document",
            author: "Jane Author"
        )
        let full = window.fullContext

        XCTAssertTrue(full.contains(window.systemPrompt))
        XCTAssertTrue(full.contains("## Document: The Great Document"))
        XCTAssertTrue(full.contains("Author: Jane Author"))
        // currentChunkIndex 1 -> "Segment 2 of 3"
        XCTAssertTrue(full.contains("Progress: Segment 2 of 3"))
        XCTAssertTrue(full.contains("## Currently Reading"))
        XCTAssertTrue(full.contains("body"))
    }

    func testFullContext_omitsAuthorWhenNil() async {
        let chunks = makeChunks(["intro", "body"])

        let window = await manager.buildContext(
            chunks: chunks,
            currentIndex: 0,
            title: "Untitled",
            author: nil
        )

        XCTAssertFalse(window.fullContext.contains("Author:"))
    }

    func testFullContext_omitsAuthorWhenEmpty() async {
        let chunks = makeChunks(["intro", "body"])

        let window = await manager.buildContext(
            chunks: chunks,
            currentIndex: 0,
            title: "Untitled",
            author: ""
        )

        XCTAssertFalse(window.fullContext.contains("Author:"))
    }

    func testFullContext_omitsSectionsWhenNoSurroundingText() async {
        let chunks = makeChunks(["only"])

        let window = await manager.buildContext(
            chunks: chunks,
            currentIndex: 0,
            title: "Solo"
        )
        let full = window.fullContext

        XCTAssertFalse(full.contains("## Previously Read"))
        XCTAssertFalse(full.contains("## Coming Up Next"))
        XCTAssertTrue(full.contains("## Currently Reading"))
    }

    func testFullContext_includesSurroundingSectionsWhenPresent() async {
        let chunks = makeChunks(["before", "current", "after"])

        let window = await manager.buildContext(
            chunks: chunks,
            currentIndex: 1,
            title: "Doc"
        )
        let full = window.fullContext

        XCTAssertTrue(full.contains("## Previously Read"))
        XCTAssertTrue(full.contains("before"))
        XCTAssertTrue(full.contains("## Coming Up Next"))
        XCTAssertTrue(full.contains("after"))
    }

    func testEstimatedTokenCount_matchesFullContextLengthHeuristic() async {
        let chunks = makeChunks(["alpha", "beta", "gamma"])

        let window = await manager.buildContext(
            chunks: chunks,
            currentIndex: 1,
            title: "Doc"
        )

        XCTAssertEqual(window.estimatedTokenCount, window.fullContext.count / 4)
    }

    // MARK: - buildBargeInMessages

    func testBuildBargeInMessages_startsWithSystemContextAndEndsWithQuestion() async {
        let chunks = makeChunks(["one", "two", "three"])

        let messages = await manager.buildBargeInMessages(
            question: "What does this mean?",
            chunks: chunks,
            currentIndex: 1,
            title: "Doc"
        )

        XCTAssertEqual(messages.first?.role, .system)
        XCTAssertTrue(messages.first?.content.contains("## Currently Reading") ?? false)
        XCTAssertEqual(messages.last?.role, .user)
        XCTAssertEqual(messages.last?.content, "What does this mean?")
    }

    func testBuildBargeInMessages_withNoHistoryHasSystemAndOneUserMessage() async {
        let chunks = makeChunks(["one", "two"])

        let messages = await manager.buildBargeInMessages(
            question: "Q?",
            chunks: chunks,
            currentIndex: 0,
            title: "Doc"
        )

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[1].role, .user)
    }

    func testBuildBargeInMessages_interleavesConversationHistory() async {
        let chunks = makeChunks(["one", "two", "three"])
        let history = [
            (question: "First question?", answer: "First answer."),
            (question: "Second question?", answer: "Second answer.")
        ]

        let messages = await manager.buildBargeInMessages(
            question: "Latest question?",
            chunks: chunks,
            currentIndex: 1,
            title: "Doc",
            author: "Author",
            conversationHistory: history
        )

        // 1 system + (2 history exchanges * 2) + 1 current question = 6.
        XCTAssertEqual(messages.count, 6)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[1].role, .user)
        XCTAssertEqual(messages[1].content, "First question?")
        XCTAssertEqual(messages[2].role, .assistant)
        XCTAssertEqual(messages[2].content, "First answer.")
        XCTAssertEqual(messages[3].role, .user)
        XCTAssertEqual(messages[3].content, "Second question?")
        XCTAssertEqual(messages[4].role, .assistant)
        XCTAssertEqual(messages[4].content, "Second answer.")
        XCTAssertEqual(messages[5].role, .user)
        XCTAssertEqual(messages[5].content, "Latest question?")
    }
}
