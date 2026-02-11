// UnaMentis - ReadingTextChunker Tests
// Tests for text chunking, extraction routing, and OCR integration

import XCTest
@testable import UnaMentis

final class ReadingTextChunkerTests: XCTestCase {

    var chunker: ReadingTextChunker!
    let tempDir = FileManager.default.temporaryDirectory

    override func setUp() {
        super.setUp()
        chunker = ReadingTextChunker(config: .default)
    }

    override func tearDown() {
        chunker = nil
        super.tearDown()
    }

    // MARK: - Helper

    private func writeTempFile(content: String, name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Plain Text Extraction

    func testExtractPlainText() async throws {
        let url = try writeTempFile(content: "Hello world. This is a test.", name: "test.txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let text = try await chunker.extractText(from: url, sourceType: .plainText)
        XCTAssertEqual(text, "Hello world. This is a test.")
    }

    func testExtractPlainTextNormalizesWhitespace() async throws {
        let content = "Too    many   spaces.\n\n\n\nToo many lines."
        let url = try writeTempFile(content: content, name: "spaces.txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let text = try await chunker.extractText(from: url, sourceType: .plainText)
        XCTAssertFalse(text.contains("  "))
        XCTAssertFalse(text.contains("\n\n\n"))
    }

    // MARK: - Markdown Extraction

    func testExtractMarkdownStripsFormatting() async throws {
        let md = "# Title\n\nThis is **bold** and [a link](https://example.com)."
        let url = try writeTempFile(content: md, name: "test.md")
        defer { try? FileManager.default.removeItem(at: url) }

        let text = try await chunker.extractText(from: url, sourceType: .markdown)
        XCTAssertTrue(text.contains("Title"))
        XCTAssertTrue(text.contains("bold"))
        XCTAssertTrue(text.contains("a link"))
        XCTAssertFalse(text.contains("#"))
        XCTAssertFalse(text.contains("**"))
        XCTAssertFalse(text.contains("https://"))
    }

    // MARK: - Web Article Extraction

    func testExtractWebArticleAsPlainText() async throws {
        // Web articles are already extracted to plain text at fetch time
        let content = "This is pre-extracted article text."
        let url = try writeTempFile(content: content, name: "article.txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let text = try await chunker.extractText(from: url, sourceType: .webArticle)
        XCTAssertEqual(text, "This is pre-extracted article text.")
    }

    // MARK: - File Not Found

    func testExtractTextThrowsForMissingFile() async {
        let url = tempDir.appendingPathComponent("nonexistent.txt")

        do {
            _ = try await chunker.extractText(from: url, sourceType: .plainText)
            XCTFail("Should throw for missing file")
        } catch {
            XCTAssertTrue(error is ReadingChunkerError)
        }
    }

    // MARK: - Chunking

    func testChunkTextProducesChunks() async {
        let text = Array(repeating: "This is a sentence.", count: 20).joined(separator: " ")
        let chunks = await chunker.chunkText(text)

        XCTAssertFalse(chunks.isEmpty, "Should produce at least one chunk")
        XCTAssertTrue(chunks.count > 1, "20 sentences should produce multiple chunks")
    }

    func testChunkTextEmptyReturnsEmpty() async {
        let chunks = await chunker.chunkText("")
        XCTAssertTrue(chunks.isEmpty)
    }

    func testChunkTextShortTextProducesSingleChunk() async {
        let text = "Just a short text."
        let chunks = await chunker.chunkText(text)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.text, "Just a short text.")
    }

    func testChunkIndicesAreSequential() async {
        let text = Array(repeating: "This is sentence number one.", count: 30).joined(separator: " ")
        let chunks = await chunker.chunkText(text)

        for (index, chunk) in chunks.enumerated() {
            XCTAssertEqual(chunk.index, index, "Chunk index should be sequential")
        }
    }

    func testChunkHasEstimatedDuration() async {
        let text = "This is a test sentence with several words in it."
        let chunks = await chunker.chunkText(text)

        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(
            chunks[0].estimatedDurationSeconds > 0,
            "Should have positive estimated duration"
        )
    }

    func testChunkCharacterOffsetsAreIncreasing() async {
        let text = Array(repeating: "Testing the offset tracking for each chunk.", count: 20)
            .joined(separator: " ")
        let chunks = await chunker.chunkText(text)

        guard chunks.count > 1 else { return }

        for i in 1..<chunks.count {
            XCTAssertTrue(
                chunks[i].characterOffset > chunks[i - 1].characterOffset,
                "Character offsets should increase"
            )
        }
    }

    // MARK: - Chunking Config

    func testShortChunksConfig() async {
        let shortChunker = ReadingTextChunker(config: .shortChunks)
        let text = Array(repeating: "This is a sentence for testing chunk sizes.", count: 30)
            .joined(separator: " ")

        let defaultChunks = await chunker.chunkText(text)
        let shortChunks = await shortChunker.chunkText(text)

        XCTAssertTrue(
            shortChunks.count >= defaultChunks.count,
            "Short chunks should produce at least as many chunks as default"
        )
    }

    func testLongChunksConfig() async {
        let longChunker = ReadingTextChunker(config: .longChunks)
        let text = Array(repeating: "This is a sentence for testing chunk sizes.", count: 30)
            .joined(separator: " ")

        let defaultChunks = await chunker.chunkText(text)
        let longChunks = await longChunker.chunkText(text)

        XCTAssertTrue(
            longChunks.count <= defaultChunks.count,
            "Long chunks should produce at most as many chunks as default"
        )
    }

    // MARK: - Process Document Pipeline

    func testProcessDocumentPlainText() async throws {
        let content = Array(repeating: "Sentence for the full pipeline test.", count: 15)
            .joined(separator: " ")
        let url = try writeTempFile(content: content, name: "pipeline.txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let chunks = try await chunker.processDocument(from: url, sourceType: .plainText)
        XCTAssertFalse(chunks.isEmpty, "Pipeline should produce chunks")
    }

    func testProcessDocumentMarkdown() async throws {
        let content = """
        # Document Title

        ## Introduction

        This is the introduction paragraph with enough text to form at least one chunk.

        ## Body

        The body has multiple paragraphs explaining the topic in detail. Each paragraph
        contributes to the overall content and helps demonstrate the chunking behavior.

        Another paragraph in the body section provides additional content for testing.

        ## Conclusion

        The conclusion wraps up the document nicely with a final statement.
        """
        let url = try writeTempFile(content: content, name: "pipeline.md")
        defer { try? FileManager.default.removeItem(at: url) }

        let chunks = try await chunker.processDocument(from: url, sourceType: .markdown)
        XCTAssertFalse(chunks.isEmpty, "Should produce chunks from markdown")

        // Verify no markdown syntax in chunks
        for chunk in chunks {
            XCTAssertFalse(chunk.text.contains("##"), "Chunks should not contain markdown headers")
        }
    }

    func testProcessDocumentWithImagesNonPDF() async throws {
        let content = "Simple content for non-PDF test."
        let url = try writeTempFile(content: content, name: "nonpdf.txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await chunker.processDocumentWithImages(from: url, sourceType: .plainText)
        XCTAssertFalse(result.chunks.isEmpty, "Should have chunks")
        XCTAssertTrue(result.images.isEmpty, "Non-PDF should have no images")
    }

    // MARK: - Sentence Splitting

    func testSentenceSplitting() async {
        let text = "First sentence. Second sentence! Third sentence? Fourth."
        let chunks = await chunker.chunkText(text)

        // With 4 short sentences, should be 1 chunk
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].text.contains("First sentence"))
        XCTAssertTrue(chunks[0].text.contains("Fourth"))
    }
}
