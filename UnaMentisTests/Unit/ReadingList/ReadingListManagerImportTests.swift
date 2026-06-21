// UnaMentis - ReadingListManager Import Pipeline Tests
// Real end-to-end import with real text files and real Core Data.
//
// These tests exercise importDocument from a real file on disk through
// text extraction, chunking, and Core Data entity creation. No mocks are
// used. The only external-ish dependency is the background audio
// pre-generation task that import kicks off; tests await its completion
// so the in-memory store stays alive for any background writes. On-device
// TTS is an internal component (not a paid API), and synthesis failing in
// the test environment is tolerated by the pre-generator's error handling.

import XCTest
import CoreData
@testable import UnaMentis

final class ReadingListManagerImportTests: XCTestCase {

    var persistence: PersistenceController!
    var manager: ReadingListManager!
    private var tempFiles: [URL] = []
    private var importedItemIds: [UUID] = []

    @MainActor
    override func setUp() async throws {
        persistence = PersistenceController(inMemory: true)
        manager = ReadingListManager(persistenceController: persistence)
        tempFiles = []
        importedItemIds = []
    }

    @MainActor
    override func tearDown() async throws {
        // Let any background pre-generation finish so it doesn't write to a
        // torn-down store. waitForPreGeneration returns immediately if nothing
        // is in flight.
        for id in importedItemIds {
            _ = await ReadingAudioPreGenerator.shared.waitForPreGeneration(itemId: id)
        }
        for url in tempFiles {
            try? FileManager.default.removeItem(at: url)
        }
        manager = nil
        persistence = nil
    }

    // MARK: - Helpers

    /// Write content to a uniquely named temp file and track it for cleanup.
    private func writeTempFile(content: String, ext: String) throws -> URL {
        let name = "readingtest-\(UUID().uuidString).\(ext)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        tempFiles.append(url)
        return url
    }

    /// Generate enough sentences to produce multiple chunks.
    private func longBody(sentences: Int) -> String {
        (0..<sentences)
            .map { "This is sentence number \($0) in the imported document body." }
            .joined(separator: " ")
    }

    @MainActor
    private func track(_ item: ReadingListItem) {
        if let id = item.id { importedItemIds.append(id) }
    }

    // MARK: - Plain Text Import

    @MainActor
    func testImportPlainTextCreatesItemWithChunks() async throws {
        let url = try writeTempFile(content: longBody(sentences: 30), ext: "txt")

        let item = try await manager.importDocument(from: url, title: "My Notes", author: "Author X")
        track(item)

        XCTAssertEqual(item.title, "My Notes")
        XCTAssertEqual(item.author, "Author X")
        XCTAssertEqual(item.sourceType, .plainText)
        XCTAssertFalse(item.chunksArray.isEmpty, "Import should create chunks")
        XCTAssertEqual(item.status, .unread)
        XCTAssertNotNil(item.fileHash)
        XCTAssertGreaterThan(item.fileSizeBytes, 0)

        // The item must be persisted and fetchable.
        let id = try XCTUnwrap(item.id)
        XCTAssertNotNil(try manager.fetchItem(id: id))
    }

    @MainActor
    func testImportDefaultsTitleToFilename() async throws {
        let url = try writeTempFile(content: longBody(sentences: 20), ext: "txt")

        let item = try await manager.importDocument(from: url)
        track(item)

        // Title defaults to the filename without extension.
        let expected = url.deletingPathExtension().lastPathComponent
        XCTAssertEqual(item.title, expected)
    }

    @MainActor
    func testImportChunkIndicesAreSequentialAndPersisted() async throws {
        let url = try writeTempFile(content: longBody(sentences: 40), ext: "txt")

        let item = try await manager.importDocument(from: url, title: "Sequential")
        track(item)

        let chunks = item.chunksArray
        XCTAssertGreaterThan(chunks.count, 1, "A long document should yield multiple chunks")
        for (offset, chunk) in chunks.enumerated() {
            XCTAssertEqual(chunk.index, Int32(offset), "Chunk order index must be sequential")
            XCTAssertFalse(chunk.text?.isEmpty ?? true)
        }
    }

    // MARK: - Markdown Import

    @MainActor
    func testImportMarkdownStripsSyntax() async throws {
        let md = """
        # Heading One

        This is **bold** body text with [a link](https://example.com) and enough
        content to form at least one chunk for the reading list import pipeline.

        ## Heading Two

        More paragraph content here to ensure the document has substance for chunking.
        """
        let url = try writeTempFile(content: md, ext: "md")

        let item = try await manager.importDocument(from: url, title: "MD Doc")
        track(item)

        XCTAssertEqual(item.sourceType, .markdown)
        let combined = item.chunksArray.compactMap(\.text).joined(separator: " ")
        XCTAssertTrue(combined.contains("Heading One"))
        XCTAssertTrue(combined.contains("bold"))
        XCTAssertFalse(combined.contains("#"), "Markdown header syntax should be stripped")
        XCTAssertFalse(combined.contains("**"), "Markdown emphasis syntax should be stripped")
        XCTAssertFalse(combined.contains("https://"), "Link URLs should be stripped")
    }

    // MARK: - Source Type Detection / Errors

    @MainActor
    func testImportUnsupportedFileTypeThrows() async throws {
        let url = try writeTempFile(content: "binary-ish content", ext: "xyz")

        do {
            _ = try await manager.importDocument(from: url)
            XCTFail("Expected unsupportedFileType error")
        } catch let error as ReadingListError {
            guard case .unsupportedFileType(let ext) = error else {
                return XCTFail("Expected unsupportedFileType, got \(error)")
            }
            XCTAssertEqual(ext, "xyz")
        }
    }

    @MainActor
    func testImportEmptyTextThrowsNoTextContent() async throws {
        // Whitespace-only file produces no chunks after cleaning.
        let url = try writeTempFile(content: "   \n\n   \n", ext: "txt")

        do {
            _ = try await manager.importDocument(from: url)
            XCTFail("Expected noTextContent error for empty document")
        } catch let error as ReadingListError {
            guard case .noTextContent = error else {
                return XCTFail("Expected noTextContent, got \(error)")
            }
        }
    }

    // MARK: - Deduplication

    @MainActor
    func testImportDuplicateContentThrows() async throws {
        let body = longBody(sentences: 25)
        let firstURL = try writeTempFile(content: body, ext: "txt")
        let secondURL = try writeTempFile(content: body, ext: "txt")

        let first = try await manager.importDocument(from: firstURL, title: "Original")
        track(first)

        // Second import of identical content hashes to the same value -> duplicate.
        do {
            _ = try await manager.importDocument(from: secondURL, title: "Copy")
            XCTFail("Expected duplicateDocument error for identical content")
        } catch let error as ReadingListError {
            switch error {
            case .duplicateDocument(let title):
                XCTAssertEqual(title, "Original", "Duplicate error should name the existing item")
            default:
                XCTFail("Expected duplicateDocument, got \(error)")
            }
        }

        // Only one item should exist in the store.
        let all = try persistence.viewContext.fetch(ReadingListItem.fetchRequest())
        XCTAssertEqual(all.count, 1, "Duplicate import must not create a second item")
    }

    @MainActor
    func testImportDistinctContentBothSucceed() async throws {
        let firstURL = try writeTempFile(content: longBody(sentences: 20), ext: "txt")
        let secondURL = try writeTempFile(
            content: longBody(sentences: 20) + " Distinct trailing content here.",
            ext: "txt"
        )

        let first = try await manager.importDocument(from: firstURL, title: "First")
        track(first)
        let second = try await manager.importDocument(from: secondURL, title: "Second")
        track(second)

        XCTAssertNotEqual(first.fileHash, second.fileHash)
        let all = try persistence.viewContext.fetch(ReadingListItem.fetchRequest())
        XCTAssertEqual(all.count, 2)
    }

    // MARK: - Integration with read APIs

    @MainActor
    func testImportedItemAppearsInActiveList() async throws {
        let url = try writeTempFile(content: longBody(sentences: 22), ext: "txt")

        let item = try await manager.importDocument(from: url, title: "Active Import")
        track(item)

        let active = try manager.fetchActiveItems()
        XCTAssertTrue(
            active.contains { $0.id == item.id },
            "A freshly imported (unread) item should appear in the active list"
        )
    }

    @MainActor
    func testImportedItemContributesToStatistics() async throws {
        let url = try writeTempFile(content: longBody(sentences: 22), ext: "txt")

        let item = try await manager.importDocument(from: url, title: "Stat Import")
        track(item)

        let stats = try manager.getStatistics()
        XCTAssertEqual(stats.unreadCount, 1)
        XCTAssertEqual(stats.totalActiveCount, 1)
    }
}
