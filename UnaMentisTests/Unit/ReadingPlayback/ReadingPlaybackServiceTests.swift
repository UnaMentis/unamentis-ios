// UnaMentis - ReadingPlaybackService Tests
// Unit tests for the reading playback coordinator.
//
// Tests cover: configuration guards, segment sequencing, pause/resume/stop
// state transitions, skip logic and index clamping, position persistence via
// the real ReadingListManager + in-memory Core Data, bookmark creation, and
// error mapping.
//
// TESTING PHILOSOPHY (Real Over Mock):
// - Real ReadingListManager, real PersistenceController(inMemory: true),
//   real AudioEngine, real TelemetryEngine, real AudioPlaybackOrchestrator.
// - The only mock is MockTTSService (paid/hardware external TTS API), wired in
//   exactly the same way AudioPlaybackOrchestratorTests does it.

import XCTest
import CoreData
@testable import UnaMentis

// The test helpers persist and read Core Data managed objects on the main actor,
// so the whole suite runs on the main actor. This keeps the non-Sendable test
// `self` and its managed objects from crossing actor boundaries.
@MainActor
final class ReadingPlaybackServiceTests: XCTestCase {

    // MARK: - Real Dependencies

    private var persistence: PersistenceController!
    private var readingListManager: ReadingListManager!
    private var mockTTS: MockTTSService!
    private var mockVAD: MockVADService!
    private var telemetry: TelemetryEngine!
    private var audioEngine: AudioEngine!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        persistence = PersistenceController(inMemory: true)
        readingListManager = ReadingListManager(persistenceController: persistence)
        mockTTS = MockTTSService()
        mockVAD = MockVADService()
        telemetry = TelemetryEngine()
        audioEngine = AudioEngine(config: .default, vadService: mockVAD, telemetry: telemetry)
        // Mirror AudioPlaybackOrchestratorTests: start the engine so playback can run.
        try await audioEngine.configure(config: .default)
        try await audioEngine.start()
    }

    override func tearDown() async throws {
        await audioEngine.stop()
        audioEngine = nil
        telemetry = nil
        mockVAD = nil
        mockTTS = nil
        readingListManager = nil
        persistence = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Build a configured ReadingPlaybackService wired to the real dependencies.
    private func makeConfiguredService(
        callbacks: ReadingPlaybackCallbacks = ReadingPlaybackCallbacks()
    ) async -> ReadingPlaybackService {
        let service = ReadingPlaybackService()
        await service.configure(
            ttsService: mockTTS,
            audioEngine: audioEngine,
            readingListManager: readingListManager,
            callbacks: callbacks
        )
        return service
    }

    /// Build N simple chunk DTOs.
    private func makeChunks(_ count: Int) -> [ReadingChunkData] {
        (0..<count).map {
            ReadingChunkData(
                index: Int32($0),
                text: "Chunk number \($0) with some words.",
                characterOffset: Int64($0 * 40),
                estimatedDurationSeconds: 4.0
            )
        }
    }

    /// Persist a ReadingListItem with `chunkCount` chunks into the shared in-memory
    /// store so the manager can find it by id. Returns the item's UUID.
    @MainActor
    private func persistItem(chunkCount: Int) -> UUID {
        let context = persistence.viewContext
        let item = ReadingListItem(context: context)
        item.configure(title: "Test Article", sourceType: .pdf)
        for i in 0..<chunkCount {
            let chunk = ReadingChunk(context: context)
            chunk.configure(
                index: Int32(i),
                text: "Persisted chunk \(i)",
                characterOffset: Int64(i * 20),
                estimatedDuration: 4.0
            )
            item.addToChunks(chunk)
        }
        try? persistence.save()
        return item.id ?? UUID()
    }

    /// Read the persisted currentChunkIndex for an item id.
    @MainActor
    private func persistedPosition(for itemId: UUID) -> Int32? {
        let request = ReadingListItem.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", itemId as CVarArg)
        request.fetchLimit = 1
        return try? persistence.viewContext.fetch(request).first?.currentChunkIndex
    }

    /// Sendable summary of a persisted bookmark, extracted on the main actor so
    /// the managed objects never cross an actor boundary.
    private struct BookmarkSummary: Sendable {
        let chunkIndex: Int32
        let note: String?
    }

    /// Read persisted bookmark summaries for an item id (main-actor isolated).
    @MainActor
    private func persistedBookmarkSummaries(for itemId: UUID) -> [BookmarkSummary] {
        let request = ReadingListItem.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", itemId as CVarArg)
        request.fetchLimit = 1
        let bookmarks = (try? persistence.viewContext.fetch(request).first?.bookmarksArray) ?? []
        return bookmarks.map { BookmarkSummary(chunkIndex: $0.chunkIndex, note: $0.note) }
    }

    /// Spin until the service reaches one of the target states or attempts run out.
    /// ReadingPlaybackState is Equatable (not Hashable, since `.error` carries a
    /// String), so targets are matched with a linear contains.
    private func waitForState(
        _ service: ReadingPlaybackService,
        in targets: [ReadingPlaybackState],
        attempts: Int = 40
    ) async -> ReadingPlaybackState {
        var state = await service.state
        for _ in 0..<attempts {
            if targets.contains(state) { return state }
            try? await Task.sleep(for: .milliseconds(50))
            state = await service.state
        }
        return state
    }

    // MARK: - Initial State

    func testInitialState_isIdle() async {
        let service = ReadingPlaybackService()
        let state = await service.state
        XCTAssertEqual(state, .idle)
    }

    func testInitialState_currentChunkIndexZero() async {
        let service = ReadingPlaybackService()
        let index = await service.currentChunkIndex
        XCTAssertEqual(index, 0)
    }

    func testInitialState_totalChunksZero() async {
        let service = ReadingPlaybackService()
        let total = await service.totalChunks
        XCTAssertEqual(total, 0)
    }

    // MARK: - Configuration Guards

    func testStartPlayback_whenNotConfigured_throwsNotConfigured() async {
        let service = ReadingPlaybackService()
        let chunks = makeChunks(2)

        do {
            try await service.startPlayback(itemId: UUID(), chunks: chunks)
            XCTFail("Expected notConfigured error")
        } catch let error as ReadingPlaybackError {
            guard case .notConfigured = error else {
                return XCTFail("Expected .notConfigured, got \(error)")
            }
        } catch {
            XCTFail("Expected ReadingPlaybackError, got \(error)")
        }
    }

    func testStartPlayback_withEmptyChunks_throwsNoChunks() async {
        let service = await makeConfiguredService()

        do {
            try await service.startPlayback(itemId: UUID(), chunks: [])
            XCTFail("Expected noChunks error")
        } catch let error as ReadingPlaybackError {
            guard case .noChunks = error else {
                return XCTFail("Expected .noChunks, got \(error)")
            }
        } catch {
            XCTFail("Expected ReadingPlaybackError, got \(error)")
        }
    }

    func testSkipToChunk_whenNotConfigured_andNoChunks_throwsInvalidIndex() async {
        // With no chunks loaded, index 0 fails the bounds guard before the
        // configuration guard is reached.
        let service = ReadingPlaybackService()
        do {
            try await service.skipToChunk(0)
            XCTFail("Expected invalidChunkIndex error")
        } catch let error as ReadingPlaybackError {
            guard case .invalidChunkIndex = error else {
                return XCTFail("Expected .invalidChunkIndex, got \(error)")
            }
        } catch {
            XCTFail("Expected ReadingPlaybackError, got \(error)")
        }
    }

    // MARK: - Start Playback Sequencing

    func testStartPlayback_setsTotalChunks() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 3)
        let chunks = makeChunks(3)

        try await service.startPlayback(itemId: itemId, chunks: chunks)

        let total = await service.totalChunks
        XCTAssertEqual(total, 3)

        await service.stopPlayback()
    }

    func testStartPlayback_transitionsToPlaying() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 3)
        // Slow TTS so playback stays active long enough to observe.
        await mockTTS.configureStreaming(chunks: 5, bytesPerChunk: 9600)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(3))

        // State is set to .playing synchronously inside startPlayback.
        let state = await service.state
        XCTAssertEqual(state, .playing)

        await service.stopPlayback()
    }

    func testStartPlayback_fromMiddle_setsCurrentChunkIndex() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 5)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(5), startIndex: 3)

        let index = await service.currentChunkIndex
        XCTAssertEqual(index, 3)

        await service.stopPlayback()
    }

    func testStartPlayback_startIndexBeyondEnd_clampsToLastChunk() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 4)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        // startIndex 99 should clamp to chunks.count - 1 == 3
        try await service.startPlayback(itemId: itemId, chunks: makeChunks(4), startIndex: 99)

        let index = await service.currentChunkIndex
        XCTAssertEqual(index, 3, "startIndex past the end clamps to the last chunk")

        await service.stopPlayback()
    }

    func testStartPlayback_firesOnStartCallback() async throws {
        let started = AsyncFlag()
        let callbacks = ReadingPlaybackCallbacks(onStart: { Task { await started.set() } })
        let service = await makeConfiguredService(callbacks: callbacks)
        let itemId = await persistItem(chunkCount: 2)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(2))

        let didStart = await started.waitUntilSet(attempts: 40)
        XCTAssertTrue(didStart, "onStart callback should fire on playback start")

        await service.stopPlayback()
    }

    func testStartPlayback_completesAllChunks_reachesCompleted() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 2)
        // Fast single-chunk TTS so the loop completes quickly.
        await mockTTS.configureStreaming(chunks: 1, bytesPerChunk: 9600)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(2))

        // The full pipeline (service -> orchestrator -> real AudioEngine) needs a
        // generous window to synthesize and play both chunks to completion, matching
        // the wait budget the orchestrator's own completion tests use.
        let state = await waitForState(service, in: [.completed], attempts: 80)
        XCTAssertEqual(state, .completed, "Playback should complete after all chunks play")
    }

    // MARK: - Pause / Resume

    func testPause_whenPlaying_transitionsToPaused() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 5)
        await mockTTS.configureStreaming(chunks: 5, bytesPerChunk: 9600)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(5))
        await service.pause()

        let state = await service.state
        XCTAssertEqual(state, .paused)

        await service.stopPlayback()
    }

    func testPause_whenIdle_isNoOp() async {
        let service = await makeConfiguredService()
        await service.pause()
        let state = await service.state
        XCTAssertEqual(state, .idle, "Pause should be a no-op when not playing")
    }

    func testResume_whenPaused_transitionsToPlaying() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 5)
        await mockTTS.configureStreaming(chunks: 5, bytesPerChunk: 9600)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(5))
        await service.pause()
        await service.resume()

        let state = await service.state
        XCTAssertEqual(state, .playing)

        await service.stopPlayback()
    }

    func testResume_whenNotPaused_isNoOp() async {
        let service = await makeConfiguredService()
        await service.resume()
        let state = await service.state
        XCTAssertEqual(state, .idle, "Resume should be a no-op when not paused")
    }

    func testPause_firesOnPauseCallback() async throws {
        let paused = AsyncFlag()
        let callbacks = ReadingPlaybackCallbacks(onPause: { Task { await paused.set() } })
        let service = await makeConfiguredService(callbacks: callbacks)
        let itemId = await persistItem(chunkCount: 5)
        await mockTTS.configureStreaming(chunks: 5, bytesPerChunk: 9600)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(5))
        await service.pause()

        let didPause = await paused.waitUntilSet(attempts: 40)
        XCTAssertTrue(didPause, "onPause callback should fire on pause")

        await service.stopPlayback()
    }

    func testResume_firesOnResumeCallback() async throws {
        let resumed = AsyncFlag()
        let callbacks = ReadingPlaybackCallbacks(onResume: { Task { await resumed.set() } })
        let service = await makeConfiguredService(callbacks: callbacks)
        let itemId = await persistItem(chunkCount: 5)
        await mockTTS.configureStreaming(chunks: 5, bytesPerChunk: 9600)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(5))
        await service.pause()
        await service.resume()

        let didResume = await resumed.waitUntilSet(attempts: 40)
        XCTAssertTrue(didResume, "onResume callback should fire on resume")

        await service.stopPlayback()
    }

    // MARK: - Suspend

    func testSuspend_whenPlaying_transitionsToPaused() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 5)
        await mockTTS.configureStreaming(chunks: 5, bytesPerChunk: 9600)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(5))
        await service.suspendPlayback()

        let state = await service.state
        XCTAssertEqual(state, .paused)

        await service.stopPlayback()
    }

    func testSuspend_whenIdle_isNoOp() async {
        let service = await makeConfiguredService()
        await service.suspendPlayback()
        let state = await service.state
        XCTAssertEqual(state, .idle)
    }

    // MARK: - Stop

    func testStop_whenPlaying_transitionsToIdle() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 5)
        await mockTTS.configureStreaming(chunks: 5, bytesPerChunk: 9600)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(5))
        await service.stopPlayback()

        let state = await service.state
        XCTAssertEqual(state, .idle)
    }

    func testStop_resetsTotalChunks() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 5)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(5))
        await service.stopPlayback()

        let total = await service.totalChunks
        XCTAssertEqual(total, 0, "Stopping clears the loaded chunks")
    }

    func testStop_whenIdle_isNoOp() async {
        let service = await makeConfiguredService()
        await service.stopPlayback()
        let state = await service.state
        XCTAssertEqual(state, .idle)
    }

    func testStop_firesOnStopCallback() async throws {
        let stopped = AsyncFlag()
        let callbacks = ReadingPlaybackCallbacks(onStop: { Task { await stopped.set() } })
        let service = await makeConfiguredService(callbacks: callbacks)
        let itemId = await persistItem(chunkCount: 3)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(3))
        await service.stopPlayback()

        let didStop = await stopped.waitUntilSet(attempts: 40)
        XCTAssertTrue(didStop, "onStop callback should fire on explicit stop")
    }

    // MARK: - Skip Logic

    func testSkipToChunk_validIndex_updatesCurrentChunkIndex() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 5)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(5))
        try await service.skipToChunk(2)

        let index = await service.currentChunkIndex
        XCTAssertEqual(index, 2)

        await service.stopPlayback()
    }

    func testSkipToChunk_negativeIndex_throwsInvalidIndex() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 3)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)
        try await service.startPlayback(itemId: itemId, chunks: makeChunks(3))

        do {
            try await service.skipToChunk(-1)
            XCTFail("Expected invalidChunkIndex")
        } catch let error as ReadingPlaybackError {
            guard case .invalidChunkIndex = error else {
                return XCTFail("Expected .invalidChunkIndex, got \(error)")
            }
        }

        await service.stopPlayback()
    }

    func testSkipToChunk_indexAtCount_throwsInvalidIndex() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 3)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)
        try await service.startPlayback(itemId: itemId, chunks: makeChunks(3))

        do {
            // count == 3, so index 3 is out of bounds (valid range 0...2)
            try await service.skipToChunk(3)
            XCTFail("Expected invalidChunkIndex")
        } catch let error as ReadingPlaybackError {
            guard case .invalidChunkIndex = error else {
                return XCTFail("Expected .invalidChunkIndex, got \(error)")
            }
        }

        await service.stopPlayback()
    }

    func testSkipForward_advancesByOne() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 5)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(5), startIndex: 1)
        try await service.skipForward()

        let index = await service.currentChunkIndex
        XCTAssertEqual(index, 2)

        await service.stopPlayback()
    }

    func testSkipForward_atLastChunk_staysAtLast() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 3)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(3), startIndex: 2)
        try await service.skipForward()

        let index = await service.currentChunkIndex
        XCTAssertEqual(index, 2, "Skipping forward past the end clamps to the last chunk")

        await service.stopPlayback()
    }

    func testSkipBackward_decrementsByOne() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 5)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(5), startIndex: 3)
        try await service.skipBackward()

        let index = await service.currentChunkIndex
        XCTAssertEqual(index, 2)

        await service.stopPlayback()
    }

    func testSkipBackward_atFirstChunk_staysAtZero() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 3)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(3), startIndex: 0)
        try await service.skipBackward()

        let index = await service.currentChunkIndex
        XCTAssertEqual(index, 0, "Skipping backward past the start clamps to zero")

        await service.stopPlayback()
    }

    func testSkipForward_multipleChunks_clampsToLast() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 5)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(5), startIndex: 0)
        try await service.skipForward(chunks: 100)

        let index = await service.currentChunkIndex
        XCTAssertEqual(index, 4)

        await service.stopPlayback()
    }

    func testSkipToChunk_whilePaused_returnsToPlaying() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 5)
        await mockTTS.configureStreaming(chunks: 5, bytesPerChunk: 9600)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(5))
        await service.pause()
        let pausedState = await service.state
        XCTAssertEqual(pausedState, .paused)

        try await service.skipToChunk(3)

        let state = await service.state
        XCTAssertEqual(state, .playing, "Skipping while paused resumes playback")

        await service.stopPlayback()
    }

    func testSkipToChunk_firesOnChunkChangeCallback() async throws {
        let observed = ChunkChangeRecorder()
        let callbacks = ReadingPlaybackCallbacks(
            onChunkChange: { idx, total in Task { await observed.record(idx, total) } }
        )
        let service = await makeConfiguredService(callbacks: callbacks)
        let itemId = await persistItem(chunkCount: 5)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(5))
        try await service.skipToChunk(2)

        let sawSkip = await observed.waitForChange(index: 2, total: 5, attempts: 40)
        XCTAssertTrue(sawSkip, "onChunkChange should report the skipped-to index and total")

        await service.stopPlayback()
    }

    // MARK: - Update Chunks

    func testUpdateChunks_replacesChunkSet() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 2)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(2))
        let initialTotal = await service.totalChunks
        XCTAssertEqual(initialTotal, 2)

        await service.updateChunks(makeChunks(6))
        let updatedTotal = await service.totalChunks
        XCTAssertEqual(updatedTotal, 6)

        await service.stopPlayback()
    }

    // MARK: - Position Persistence (real Core Data + real ReadingListManager)

    func testStartPlayback_fromMiddle_persistsStartPositionOnPause() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 6)
        await mockTTS.configureStreaming(chunks: 5, bytesPerChunk: 9600)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(6), startIndex: 2)
        await service.pause()

        let position = await persistedPosition(for: itemId)
        XCTAssertEqual(position, 2, "Pausing saves the current chunk index to Core Data")

        await service.stopPlayback()
    }

    func testSkipThenStop_persistsLatestPosition() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 6)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(6))
        try await service.skipToChunk(4)
        await service.stopPlayback()

        let position = await persistedPosition(for: itemId)
        XCTAssertEqual(position, 4, "Stopping persists the most recently played chunk index")
    }

    func testSuspend_persistsPosition() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 6)
        await mockTTS.configureStreaming(chunks: 5, bytesPerChunk: 9600)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(6), startIndex: 3)
        await service.suspendPlayback()

        let position = await persistedPosition(for: itemId)
        XCTAssertEqual(position, 3, "Suspending persists the current chunk index")

        await service.stopPlayback()
    }

    // MARK: - Bookmarks (real Core Data + real ReadingListManager)

    func testAddBookmark_whenNotConfigured_throwsNotConfigured() async {
        let service = ReadingPlaybackService()
        do {
            try await service.addBookmark()
            XCTFail("Expected notConfigured error")
        } catch let error as ReadingPlaybackError {
            guard case .notConfigured = error else {
                return XCTFail("Expected .notConfigured, got \(error)")
            }
        } catch {
            XCTFail("Expected ReadingPlaybackError, got \(error)")
        }
    }

    func testAddBookmark_atCurrentPosition_persistsBookmark() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 6)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(6), startIndex: 2)
        try await service.addBookmark(note: "Important passage")

        let bookmarks = await persistedBookmarkSummaries(for: itemId)
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks.first?.chunkIndex, 2)
        XCTAssertEqual(bookmarks.first?.note, "Important passage")

        await service.stopPlayback()
    }

    func testJumpToBookmark_movesToBookmarkChunk() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 6)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(6))
        let bookmark = ReadingBookmarkData(id: UUID(), chunkIndex: 4, note: nil)
        try await service.jumpToBookmark(bookmark)

        let index = await service.currentChunkIndex
        XCTAssertEqual(index, 4, "Jumping to a bookmark skips to its chunk index")

        await service.stopPlayback()
    }

    func testJumpToBookmark_invalidIndex_throwsInvalidIndex() async throws {
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 3)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)
        try await service.startPlayback(itemId: itemId, chunks: makeChunks(3))

        let bookmark = ReadingBookmarkData(id: UUID(), chunkIndex: 99, note: nil)
        do {
            try await service.jumpToBookmark(bookmark)
            XCTFail("Expected invalidChunkIndex")
        } catch let error as ReadingPlaybackError {
            guard case .invalidChunkIndex = error else {
                return XCTFail("Expected .invalidChunkIndex, got \(error)")
            }
        }

        await service.stopPlayback()
    }
}

// MARK: - Reading Playback DTO + Error Tests

final class ReadingPlaybackDTOTests: XCTestCase {

    // MARK: - ReadingChunkData

    func testReadingChunkData_storesAllFields() {
        let data = Data(repeating: 0x10, count: 48)
        let chunk = ReadingChunkData(
            index: 5,
            text: "Body text",
            characterOffset: 200,
            estimatedDurationSeconds: 7.5,
            cachedAudioData: data,
            cachedAudioSampleRate: 24000
        )

        XCTAssertEqual(chunk.index, 5)
        XCTAssertEqual(chunk.text, "Body text")
        XCTAssertEqual(chunk.characterOffset, 200)
        XCTAssertEqual(chunk.estimatedDurationSeconds, 7.5)
        XCTAssertEqual(chunk.cachedAudioData, data)
        XCTAssertEqual(chunk.cachedAudioSampleRate, 24000)
    }

    func testReadingChunkData_defaults_noCachedAudio() {
        let chunk = ReadingChunkData(
            index: 0,
            text: "No cache",
            characterOffset: 0,
            estimatedDurationSeconds: 1.0
        )
        XCTAssertNil(chunk.cachedAudioData)
        XCTAssertEqual(chunk.cachedAudioSampleRate, 0)
        XCTAssertFalse(chunk.hasCachedAudio)
    }

    // MARK: - ReadingBookmarkData

    func testReadingBookmarkData_storesFields() {
        let id = UUID()
        let bookmark = ReadingBookmarkData(id: id, chunkIndex: 12, note: "note text")
        XCTAssertEqual(bookmark.id, id)
        XCTAssertEqual(bookmark.chunkIndex, 12)
        XCTAssertEqual(bookmark.note, "note text")
    }

    // MARK: - ReadingPlaybackState equality

    func testReadingPlaybackState_errorEquality_matchesOnMessage() {
        XCTAssertEqual(ReadingPlaybackState.error("boom"), ReadingPlaybackState.error("boom"))
        XCTAssertNotEqual(ReadingPlaybackState.error("a"), ReadingPlaybackState.error("b"))
    }

    func testReadingPlaybackState_distinctCasesNotEqual() {
        XCTAssertNotEqual(ReadingPlaybackState.idle, ReadingPlaybackState.playing)
        XCTAssertNotEqual(ReadingPlaybackState.paused, ReadingPlaybackState.completed)
        XCTAssertNotEqual(ReadingPlaybackState.loading, ReadingPlaybackState.buffering)
    }

    // MARK: - ReadingPlaybackError descriptions

    func testReadingPlaybackError_descriptions() {
        XCTAssertEqual(
            ReadingPlaybackError.notConfigured.errorDescription,
            "Reading playback service not configured"
        )
        XCTAssertEqual(
            ReadingPlaybackError.noChunks.errorDescription,
            "No chunks available for playback"
        )
        XCTAssertEqual(
            ReadingPlaybackError.invalidChunkIndex.errorDescription,
            "Invalid chunk index"
        )
        XCTAssertEqual(
            ReadingPlaybackError.bufferTimeout.errorDescription,
            "Timed out waiting for audio buffer"
        )
        XCTAssertEqual(
            ReadingPlaybackError.playbackFailed("network down").errorDescription,
            "Playback failed: network down"
        )
    }

    // MARK: - ReadingPlaybackCallbacks defaults

    func testReadingPlaybackCallbacks_defaultsDoNotCrash() async {
        let callbacks = ReadingPlaybackCallbacks()
        await MainActor.run {
            callbacks.onStart()
            callbacks.onPause()
            callbacks.onResume()
            callbacks.onStop()
            callbacks.onComplete()
            callbacks.onBuffering()
            callbacks.onChunkChange(0, 0)
            callbacks.onError(ReadingPlaybackError.noChunks)
        }
    }
}

// MARK: - Test Support Actors (not mocks; real coordination primitives)

/// A simple awaitable boolean flag for observing fire-and-forget callbacks.
/// This is a real synchronization primitive, not a mock of any service.
private actor AsyncFlag {
    private var isSet = false

    func set() { isSet = true }

    func waitUntilSet(attempts: Int) async -> Bool {
        for _ in 0..<attempts {
            if isSet { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return isSet
    }
}

/// Records onChunkChange callback payloads for assertions.
private actor ChunkChangeRecorder {
    private var changes: [(index: Int32, total: Int)] = []

    func record(_ index: Int32, _ total: Int) {
        changes.append((index: index, total: total))
    }

    func waitForChange(index: Int32, total: Int, attempts: Int) async -> Bool {
        for _ in 0..<attempts {
            if changes.contains(where: { $0.index == index && $0.total == total }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return changes.contains(where: { $0.index == index && $0.total == total })
    }
}
