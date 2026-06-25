// UnaMentis - ReadingPlaybackViewModelTests
// Unit tests for ReadingPlaybackViewModel
//
// Validates the real outcomes of the view model's derived state that drives
// the reading playback UI: progress, play/active flags, skip availability,
// and the FlaggableActivity bridge the reinforcement system reads. A real
// in-memory Core Data ReadingListItem backs the view model. Playback control
// methods that require live audio services are intentionally not exercised
// here; the derived properties below are the contract the SwiftUI controls
// bind to and are pure given the published state.

import XCTest
import CoreData
@testable import UnaMentis

@MainActor
final class ReadingPlaybackViewModelTests: XCTestCase {

    private var persistence: PersistenceController!

    override func setUp() async throws {
        persistence = PersistenceController(inMemory: true)
    }

    override func tearDown() async throws {
        persistence = nil
    }

    /// Create a real ReadingListItem with chunks in in-memory Core Data.
    @discardableResult
    private func makeItem(
        title: String = "Test Reading",
        chunkCount: Int = 5,
        currentChunkIndex: Int32 = 0
    ) throws -> ReadingListItem {
        let context = persistence.viewContext
        let item = ReadingListItem(context: context)
        item.configure(title: title, sourceType: .plainText)
        for index in 0..<chunkCount {
            let chunk = ReadingChunk(context: context)
            chunk.configure(
                index: Int32(index),
                text: "Chunk \(index) content.",
                characterOffset: Int64(index * 20),
                estimatedDuration: 5.0
            )
            item.addToChunks(chunk)
        }
        item.currentChunkIndex = currentChunkIndex
        try persistence.save()
        return item
    }

    // MARK: - Initialization

    func testInit_seedsChunkCountAndIndexFromItem() throws {
        let item = try makeItem(chunkCount: 5, currentChunkIndex: 2)

        let vm = ReadingPlaybackViewModel(item: item)

        // The view model must mirror the item's persisted position so the UI
        // resumes where the reader left off.
        XCTAssertEqual(vm.totalChunks, 5)
        XCTAssertEqual(vm.currentChunkIndex, 2)
        XCTAssertEqual(vm.state, .idle)
    }

    // MARK: - Progress

    func testProgress_zeroWhenNoChunks() throws {
        let item = try makeItem(chunkCount: 0)
        let vm = ReadingPlaybackViewModel(item: item)

        // No chunks means no division by zero and a defined zero progress.
        XCTAssertEqual(vm.totalChunks, 0)
        XCTAssertEqual(vm.progress, 0.0, accuracy: 0.0001)
    }

    func testProgress_reflectsCurrentPosition() throws {
        let item = try makeItem(chunkCount: 4, currentChunkIndex: 1)
        let vm = ReadingPlaybackViewModel(item: item)

        // 1 of 4 chunks completed.
        XCTAssertEqual(vm.progress, 0.25, accuracy: 0.0001)

        vm.currentChunkIndex = 3
        XCTAssertEqual(vm.progress, 0.75, accuracy: 0.0001)
    }

    // MARK: - Playback State Flags

    func testIsPlaying_trueOnlyWhenPlaying() throws {
        let item = try makeItem()
        let vm = ReadingPlaybackViewModel(item: item)

        vm.state = .playing
        XCTAssertTrue(vm.isPlaying)

        vm.state = .paused
        XCTAssertFalse(vm.isPlaying)

        vm.state = .buffering
        XCTAssertFalse(vm.isPlaying)
    }

    func testHasActivePlayback_trueForPlayingPausedBuffering() throws {
        let item = try makeItem()
        let vm = ReadingPlaybackViewModel(item: item)

        for activeState in [ReadingPlaybackState.playing, .paused, .buffering] {
            vm.state = activeState
            XCTAssertTrue(vm.hasActivePlayback, "Expected active for \(activeState)")
        }

        for inactiveState in [ReadingPlaybackState.idle, .loading, .completed, .error("x")] {
            vm.state = inactiveState
            XCTAssertFalse(vm.hasActivePlayback, "Expected inactive for \(inactiveState)")
        }
    }

    // MARK: - Skip Availability

    func testCanSkipBackward_falseAtFirstChunk() throws {
        let item = try makeItem(chunkCount: 5, currentChunkIndex: 0)
        let vm = ReadingPlaybackViewModel(item: item)
        vm.state = .playing

        XCTAssertFalse(vm.canSkipBackward)

        vm.currentChunkIndex = 1
        XCTAssertTrue(vm.canSkipBackward)
    }

    func testCanSkipBackward_falseWhileLoading() throws {
        let item = try makeItem(chunkCount: 5, currentChunkIndex: 2)
        let vm = ReadingPlaybackViewModel(item: item)
        vm.state = .loading

        // Loading blocks skipping even when not on the first chunk.
        XCTAssertFalse(vm.canSkipBackward)
    }

    func testCanSkipForward_falseAtLastChunk() throws {
        let item = try makeItem(chunkCount: 5, currentChunkIndex: 4)
        let vm = ReadingPlaybackViewModel(item: item)
        vm.state = .playing

        // Index 4 is the final chunk of 5 (0-based).
        XCTAssertFalse(vm.canSkipForward)

        vm.currentChunkIndex = 3
        XCTAssertTrue(vm.canSkipForward)
    }

    func testCanSkipForward_falseWhileLoading() throws {
        let item = try makeItem(chunkCount: 5, currentChunkIndex: 1)
        let vm = ReadingPlaybackViewModel(item: item)
        vm.state = .loading

        XCTAssertFalse(vm.canSkipForward)
    }

    // MARK: - FlaggableActivity Bridge

    func testFlaggableActivity_exposesSegmentAndSourceMetadata() throws {
        let item = try makeItem(title: "Deep Work", chunkCount: 6, currentChunkIndex: 3)
        let vm = ReadingPlaybackViewModel(item: item)
        vm.currentChunkText = "the current passage"

        // The reinforcement/flagging system reads these to build a flag
        // record, so they must reflect the live reading position and source.
        XCTAssertEqual(vm.currentSegmentIndex, 3)
        XCTAssertEqual(vm.totalSegments, 6)
        XCTAssertEqual(vm.currentSegmentText, "the current passage")
        XCTAssertEqual(vm.sourceTitle, "Deep Work")
        XCTAssertEqual(vm.sourceType, .readingList)
        XCTAssertEqual(vm.sourceId, item.id)
    }

    func testSourceTitle_fallsBackWhenItemHasNoTitle() {
        let context = persistence.viewContext
        let item = ReadingListItem(context: context)
        item.configure(title: "Temp", sourceType: .plainText)
        item.title = nil
        // Do not save: the model requires a non-nil title, and the fallback is a
        // live computed property that does not depend on persistence. This still
        // validates the real outcome: a nil title yields the fallback label.

        let vm = ReadingPlaybackViewModel(item: item)

        // A nil title must not produce an empty source label.
        XCTAssertEqual(vm.sourceTitle, "Reading List Item")
    }
}
