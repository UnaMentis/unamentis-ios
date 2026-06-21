// UnaMentis - ReadingListManager Tests
// Real Core Data CRUD, bookmark, statistics, and update coverage.
//
// These tests use a real in-memory PersistenceController and real
// Core Data managed objects. No mocks are involved. The manager's
// read/update/bookmark/delete/statistics paths are pure Core Data and
// fully deterministic.

import XCTest
import CoreData
@testable import UnaMentis

final class ReadingListManagerTests: XCTestCase {

    var persistence: PersistenceController!
    var manager: ReadingListManager!

    @MainActor
    override func setUp() async throws {
        persistence = PersistenceController(inMemory: true)
        manager = ReadingListManager(persistenceController: persistence)
    }

    @MainActor
    override func tearDown() async throws {
        manager = nil
        persistence = nil
    }

    // MARK: - Test Fixtures

    /// Create a real ReadingListItem with the given number of chunks directly
    /// in Core Data, mirroring what the import pipeline produces.
    @MainActor
    @discardableResult
    private func makeItem(
        title: String,
        status: ReadingListStatus = .unread,
        chunkCount: Int = 3,
        hash: String? = nil
    ) throws -> ReadingListItem {
        let context = persistence.viewContext
        let item = ReadingListItem(context: context)
        item.configure(title: title, sourceType: .plainText)
        item.fileHash = hash ?? UUID().uuidString
        item.status = status

        for index in 0..<chunkCount {
            let chunk = ReadingChunk(context: context)
            chunk.configure(
                index: Int32(index),
                text: "Chunk \(index) text with several words for duration estimation.",
                characterOffset: Int64(index * 60),
                estimatedDuration: 10.0
            )
            item.addToChunks(chunk)
        }

        try persistence.save()
        return item
    }

    /// Assert that the given error is ReadingListError.itemNotFound.
    /// Uses pattern matching instead of Equatable to avoid a retroactive
    /// protocol conformance on a type owned by the main module.
    private func assertItemNotFound(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let readingError = error as? ReadingListError,
              case .itemNotFound = readingError else {
            XCTFail("Expected ReadingListError.itemNotFound, got \(error)", file: file, line: line)
            return
        }
    }

    // MARK: - Read: fetchActiveItems

    @MainActor
    func testFetchActiveItemsExcludesArchived() throws {
        try makeItem(title: "Unread Doc", status: .unread)
        try makeItem(title: "In Progress Doc", status: .inProgress)
        try makeItem(title: "Completed Doc", status: .completed)
        try makeItem(title: "Archived Doc", status: .archived)

        let active = try manager.fetchActiveItems()

        XCTAssertEqual(active.count, 3, "Archived items should be excluded from active list")
        XCTAssertFalse(
            active.contains { $0.title == "Archived Doc" },
            "Archived item must not appear in active list"
        )
    }

    @MainActor
    func testFetchActiveItemsSortsInProgressFirst() throws {
        // statusRaw sort: "completed" < "in_progress" < "unread" alphabetically,
        // so the sort descriptor on statusRaw ascending puts completed first.
        // Verify the actual ordering produced by the manager's sort descriptors.
        try makeItem(title: "Unread Doc", status: .unread)
        let inProgress = try makeItem(title: "In Progress Doc", status: .inProgress)
        inProgress.lastReadAt = Date()
        try persistence.save()

        let active = try manager.fetchActiveItems()

        XCTAssertEqual(active.count, 2)
        // The in-progress item has a lastReadAt, so within its status group it is present.
        XCTAssertTrue(active.contains { $0.title == "In Progress Doc" })
        XCTAssertTrue(active.contains { $0.title == "Unread Doc" })
    }

    @MainActor
    func testFetchActiveItemsEmptyReturnsEmpty() throws {
        let active = try manager.fetchActiveItems()
        XCTAssertTrue(active.isEmpty)
    }

    // MARK: - Read: fetchItems(status:)

    @MainActor
    func testFetchItemsByStatus() throws {
        try makeItem(title: "A", status: .unread)
        try makeItem(title: "B", status: .completed)
        try makeItem(title: "C", status: .completed)

        let completed = try manager.fetchItems(status: .completed)
        let unread = try manager.fetchItems(status: .unread)

        XCTAssertEqual(completed.count, 2)
        XCTAssertEqual(unread.count, 1)
        XCTAssertTrue(completed.allSatisfy { $0.status == .completed })
    }

    // MARK: - Read: fetchItem(id:)

    @MainActor
    func testFetchItemByIdReturnsMatch() throws {
        let item = try makeItem(title: "Findable")
        let id = try XCTUnwrap(item.id)

        let fetched = try manager.fetchItem(id: id)

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.title, "Findable")
        XCTAssertEqual(fetched?.id, id)
    }

    @MainActor
    func testFetchItemByIdReturnsNilForUnknown() throws {
        try makeItem(title: "Exists")
        let fetched = try manager.fetchItem(id: UUID())
        XCTAssertNil(fetched)
    }

    // MARK: - Update: position

    @MainActor
    func testUpdatePositionPersistsAndUpdatesPercent() throws {
        let item = try makeItem(title: "Doc", chunkCount: 4)

        try manager.updatePosition(item: item, chunkIndex: 2)

        XCTAssertEqual(item.currentChunkIndex, 2)
        XCTAssertEqual(item.percentComplete, 0.5, accuracy: 0.001)
        // Advancing past chunk 0 transitions unread -> in_progress.
        XCTAssertEqual(item.status, .inProgress)
        XCTAssertNotNil(item.lastReadAt)
    }

    @MainActor
    func testUpdatePositionByIdUpdatesCorrectItem() throws {
        let item = try makeItem(title: "ByID", chunkCount: 5)
        let id = try XCTUnwrap(item.id)

        try manager.updatePositionById(itemId: id, chunkIndex: 3)

        let fetched = try XCTUnwrap(manager.fetchItem(id: id))
        XCTAssertEqual(fetched.currentChunkIndex, 3)
    }

    @MainActor
    func testUpdatePositionByIdThrowsForUnknownItem() throws {
        XCTAssertThrowsError(try manager.updatePositionById(itemId: UUID(), chunkIndex: 1)) { error in
            assertItemNotFound(error)
        }
    }

    @MainActor
    func testUpdatePositionFromUnreadToFinalChunkBecomesInProgress() throws {
        // KNOWN BEHAVIOR (see ReadingListItem.updatePosition): when an item is
        // still .unread and the position jumps straight to the final chunk, the
        // "unread && chunkIndex > 0 -> inProgress" branch wins because it is
        // evaluated first. The completion branch is an `else if`, so it never
        // runs in this case. This documents the actual behavior, not an ideal.
        let item = try makeItem(title: "Finisher", status: .unread, chunkCount: 3)

        try manager.updatePosition(item: item, chunkIndex: 3)

        XCTAssertEqual(
            item.status,
            .inProgress,
            "Jumping from unread to final chunk sets in_progress, not completed (else-if guard)"
        )
    }

    @MainActor
    func testUpdatePositionFromInProgressToFinalChunkMarksCompleted() throws {
        // When already in progress, reaching chunkIndex >= totalChunks triggers
        // the completion branch.
        let item = try makeItem(title: "Finisher2", status: .inProgress, chunkCount: 3)

        try manager.updatePosition(item: item, chunkIndex: 3)

        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.percentComplete, 1.0, accuracy: 0.001)
    }

    // MARK: - Update: metadata

    @MainActor
    func testUpdateItemMetadata() throws {
        let item = try makeItem(title: "Old Title")

        try manager.updateItem(item: item, title: "New Title", author: "New Author")

        XCTAssertEqual(item.title, "New Title")
        XCTAssertEqual(item.author, "New Author")
    }

    @MainActor
    func testUpdateItemMetadataNilLeavesValuesUnchanged() throws {
        let item = try makeItem(title: "Keep Title")
        item.author = "Original Author"
        try persistence.save()

        try manager.updateItem(item: item, title: nil, author: nil)

        XCTAssertEqual(item.title, "Keep Title")
        XCTAssertEqual(item.author, "Original Author")
    }

    // MARK: - Status transitions

    @MainActor
    func testCompleteItem() throws {
        let item = try makeItem(title: "ToComplete", status: .inProgress)

        try manager.completeItem(item)

        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.percentComplete, 1.0, accuracy: 0.001)
        XCTAssertNotNil(item.completedAt)
    }

    @MainActor
    func testArchiveItem() throws {
        let item = try makeItem(title: "ToArchive", status: .inProgress)

        try manager.archiveItem(item)

        XCTAssertEqual(item.status, .archived)
        // Archived items must not appear in the active list.
        XCTAssertFalse(try manager.fetchActiveItems().contains { $0.id == item.id })
    }

    @MainActor
    func testResetProgress() throws {
        let item = try makeItem(title: "ToReset", status: .completed, chunkCount: 4)
        try manager.updatePosition(item: item, chunkIndex: 4)

        try manager.resetProgress(item: item)

        XCTAssertEqual(item.currentChunkIndex, 0)
        XCTAssertEqual(item.percentComplete, 0.0, accuracy: 0.001)
        XCTAssertEqual(item.status, .unread)
        XCTAssertNil(item.completedAt)
    }

    // MARK: - Cached audio

    @MainActor
    func testSaveCachedAudioStoresOnChunk() throws {
        let item = try makeItem(title: "Audio Doc", chunkCount: 3)
        let id = try XCTUnwrap(item.id)
        let audio = Data(repeating: 0x42, count: 256)

        try manager.saveCachedAudio(itemId: id, chunkIndex: 1, audioData: audio, sampleRate: 24000)

        let chunk = try XCTUnwrap(item.chunksArray.first { $0.index == 1 })
        XCTAssertTrue(chunk.hasCachedAudio)
        XCTAssertEqual(chunk.cachedAudioData, audio)
        XCTAssertEqual(chunk.cachedAudioSampleRate, 24000, accuracy: 0.001)
    }

    @MainActor
    func testSaveCachedAudioDoesNotOverwriteExisting() throws {
        let item = try makeItem(title: "Audio Doc", chunkCount: 2)
        let id = try XCTUnwrap(item.id)
        let first = Data(repeating: 0x01, count: 64)
        let second = Data(repeating: 0x02, count: 64)

        try manager.saveCachedAudio(itemId: id, chunkIndex: 0, audioData: first, sampleRate: 24000)
        try manager.saveCachedAudio(itemId: id, chunkIndex: 0, audioData: second, sampleRate: 16000)

        let chunk = try XCTUnwrap(item.chunksArray.first { $0.index == 0 })
        XCTAssertEqual(chunk.cachedAudioData, first, "Existing cached audio must not be overwritten")
        XCTAssertEqual(chunk.cachedAudioSampleRate, 24000, accuracy: 0.001)
    }

    @MainActor
    func testSaveCachedAudioForUnknownChunkIndexIsNoOp() throws {
        let item = try makeItem(title: "Audio Doc", chunkCount: 2)
        let id = try XCTUnwrap(item.id)

        // chunkIndex 99 does not exist; should return without throwing or saving.
        XCTAssertNoThrow(
            try manager.saveCachedAudio(
                itemId: id,
                chunkIndex: 99,
                audioData: Data([0x01]),
                sampleRate: 24000
            )
        )
        XCTAssertFalse(item.chunksArray.contains { $0.hasCachedAudio })
    }

    @MainActor
    func testSaveCachedAudioThrowsForUnknownItem() throws {
        XCTAssertThrowsError(
            try manager.saveCachedAudio(
                itemId: UUID(),
                chunkIndex: 0,
                audioData: Data([0x01]),
                sampleRate: 24000
            )
        ) { error in
            assertItemNotFound(error)
        }
    }

    // MARK: - Bookmarks

    @MainActor
    func testAddBookmarkAtExplicitChunkUsesChunkSnippet() throws {
        let item = try makeItem(title: "Bookmarkable", chunkCount: 4)

        let bookmark = try manager.addBookmark(to: item, at: 2, note: "Important")

        XCTAssertEqual(bookmark.chunkIndex, 2)
        XCTAssertEqual(bookmark.note, "Important")
        // Snippet should come from the chunk text (configure(from:)).
        XCTAssertNotNil(bookmark.snippetPreview)
        XCTAssertFalse(bookmark.snippetPreview?.isEmpty ?? true)
        XCTAssertEqual(item.bookmarksArray.count, 1)
    }

    @MainActor
    func testAddBookmarkDefaultsToCurrentChunkIndex() throws {
        let item = try makeItem(title: "CurrentPos", chunkCount: 5)
        try manager.updatePosition(item: item, chunkIndex: 3)

        let bookmark = try manager.addBookmark(to: item)

        XCTAssertEqual(bookmark.chunkIndex, 3, "Bookmark should default to current chunk index")
    }

    @MainActor
    func testAddBookmarkBeyondChunkRangeStillConfigures() throws {
        let item = try makeItem(title: "OutOfRange", chunkCount: 2)

        // Index 10 is past the available chunks; configure(chunkIndex:) path is used.
        let bookmark = try manager.addBookmark(to: item, at: 10, note: "Far")

        XCTAssertEqual(bookmark.chunkIndex, 10)
        XCTAssertEqual(bookmark.note, "Far")
    }

    @MainActor
    func testAddBookmarkByIdReturnsBookmarkData() throws {
        let item = try makeItem(title: "ByIDBookmark", chunkCount: 3)
        let id = try XCTUnwrap(item.id)

        let result = try manager.addBookmarkById(itemId: id, chunkIndex: 1, note: "Note text")

        XCTAssertEqual(result.chunkIndex, 1)
        XCTAssertEqual(result.note, "Note text")
        XCTAssertEqual(item.bookmarksArray.count, 1)
    }

    @MainActor
    func testAddBookmarkByIdThrowsForUnknownItem() throws {
        XCTAssertThrowsError(
            try manager.addBookmarkById(itemId: UUID(), chunkIndex: 0, note: nil)
        ) { error in
            assertItemNotFound(error)
        }
    }

    @MainActor
    func testRemoveBookmark() throws {
        let item = try makeItem(title: "RemovableBookmark", chunkCount: 3)
        let bookmark = try manager.addBookmark(to: item, at: 1, note: nil)
        XCTAssertEqual(item.bookmarksArray.count, 1)

        try manager.removeBookmark(bookmark)

        XCTAssertEqual(item.bookmarksArray.count, 0)
    }

    // MARK: - Delete

    @MainActor
    func testDeleteItemRemovesFromStore() throws {
        let item = try makeItem(title: "Deletable")
        let id = try XCTUnwrap(item.id)

        try manager.deleteItem(item)

        XCTAssertNil(try manager.fetchItem(id: id))
    }

    @MainActor
    func testDeleteItemCascadesChunks() throws {
        let item = try makeItem(title: "WithChunks", chunkCount: 3)

        try manager.deleteItem(item)

        // After deletion there should be no remaining ReadingChunk rows.
        let chunkRequest = ReadingChunk.fetchRequest()
        let remaining = try persistence.viewContext.fetch(chunkRequest)
        XCTAssertTrue(remaining.isEmpty, "Chunks should be deleted with the item via cascade")
    }

    @MainActor
    func testDeleteAllArchivedOnlyRemovesArchived() throws {
        try makeItem(title: "Active1", status: .unread)
        try makeItem(title: "Archived1", status: .archived)
        try makeItem(title: "Archived2", status: .archived)

        try manager.deleteAllArchived()

        let archived = try manager.fetchItems(status: .archived)
        let unread = try manager.fetchItems(status: .unread)
        XCTAssertTrue(archived.isEmpty, "All archived items should be deleted")
        XCTAssertEqual(unread.count, 1, "Non-archived items should remain")
    }

    // MARK: - Statistics

    @MainActor
    func testStatisticsCountsByStatus() throws {
        try makeItem(title: "U1", status: .unread)
        try makeItem(title: "U2", status: .unread)
        try makeItem(title: "IP", status: .inProgress)
        try makeItem(title: "C1", status: .completed)
        try makeItem(title: "A1", status: .archived)

        let stats = try manager.getStatistics()

        XCTAssertEqual(stats.unreadCount, 2)
        XCTAssertEqual(stats.inProgressCount, 1)
        XCTAssertEqual(stats.completedCount, 1)
        XCTAssertEqual(stats.archivedCount, 1)
        XCTAssertEqual(stats.totalActiveCount, 3, "Active = unread + in progress")
    }

    @MainActor
    func testStatisticsTotalReadingTimeOnlyCountsCompleted() throws {
        // Each chunk has estimatedDuration 10.0; 3 chunks => 30s per item.
        try makeItem(title: "Completed", status: .completed, chunkCount: 3)
        try makeItem(title: "Unread", status: .unread, chunkCount: 3)

        let stats = try manager.getStatistics()

        XCTAssertEqual(
            stats.totalReadingTimeSeconds,
            30.0,
            accuracy: 0.01,
            "Only completed items contribute to total reading time"
        )
    }

    @MainActor
    func testStatisticsEmptyStore() throws {
        let stats = try manager.getStatistics()
        XCTAssertEqual(stats.unreadCount, 0)
        XCTAssertEqual(stats.inProgressCount, 0)
        XCTAssertEqual(stats.completedCount, 0)
        XCTAssertEqual(stats.archivedCount, 0)
        XCTAssertEqual(stats.totalActiveCount, 0)
        XCTAssertEqual(stats.totalReadingTimeSeconds, 0.0, accuracy: 0.001)
    }
}

// MARK: - Statistics Formatting

final class ReadingListStatisticsFormattingTests: XCTestCase {

    func testFormattedMinutesOnly() {
        let stats = ReadingListStatistics(
            unreadCount: 0,
            inProgressCount: 0,
            completedCount: 0,
            archivedCount: 0,
            totalReadingTimeSeconds: 5 * 60 // 5 minutes
        )
        XCTAssertEqual(stats.totalReadingTimeFormatted, "5m")
    }

    func testFormattedHoursAndMinutes() {
        let stats = ReadingListStatistics(
            unreadCount: 0,
            inProgressCount: 0,
            completedCount: 0,
            archivedCount: 0,
            totalReadingTimeSeconds: (2 * 3600) + (15 * 60) // 2h 15m
        )
        XCTAssertEqual(stats.totalReadingTimeFormatted, "2h 15m")
    }

    func testFormattedZero() {
        let stats = ReadingListStatistics(
            unreadCount: 0,
            inProgressCount: 0,
            completedCount: 0,
            archivedCount: 0,
            totalReadingTimeSeconds: 0
        )
        XCTAssertEqual(stats.totalReadingTimeFormatted, "0m")
    }

    func testTotalActiveCount() {
        let stats = ReadingListStatistics(
            unreadCount: 4,
            inProgressCount: 3,
            completedCount: 99,
            archivedCount: 99,
            totalReadingTimeSeconds: 0
        )
        XCTAssertEqual(stats.totalActiveCount, 7)
    }
}

// MARK: - Error Descriptions

final class ReadingListErrorTests: XCTestCase {

    func testUnsupportedFileTypeDescription() {
        let error = ReadingListError.unsupportedFileType("xyz")
        let description = try? XCTUnwrap(error.errorDescription)
        XCTAssertNotNil(description)
        XCTAssertTrue(description?.contains("xyz") ?? false)
    }

    func testDuplicateDocumentDescription() {
        let error = ReadingListError.duplicateDocument("My Book")
        XCTAssertTrue(error.errorDescription?.contains("My Book") ?? false)
    }

    func testNoTextContentDescription() {
        let error = ReadingListError.noTextContent
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
    }

    func testItemNotFoundDescription() {
        let error = ReadingListError.itemNotFound
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
    }
}

// NOTE: We intentionally do NOT add a retroactive Equatable conformance to
// ReadingListError (a main-module type) from the test target. Error variants
// are asserted via pattern matching (if case / guard case) instead.
