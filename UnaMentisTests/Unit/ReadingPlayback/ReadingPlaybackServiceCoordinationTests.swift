// UnaMentis - ReadingPlaybackService Coordination Tests
// Additional unit tests for reading playback behaviors not covered by
// ReadingPlaybackServiceTests: re-entrant session swapping, updateChunks
// before playback starts, the skip-while-playing branch, and the
// orchestrator-error to service-error bridge.
//
// TESTING PHILOSOPHY (Real Over Mock):
// - Real ReadingListManager, real PersistenceController(inMemory: true),
//   real AudioEngine, real TelemetryEngine, real AudioPlaybackOrchestrator.
// - The only mock is MockTTSService (paid/hardware external TTS API), wired in
//   the same way ReadingPlaybackServiceTests and AudioPlaybackOrchestratorTests
//   wire it.

import XCTest
import CoreData
@testable import UnaMentis

// Core Data managed objects are read and written on the main actor, so the whole
// suite runs on the main actor to keep non-Sendable test state from crossing
// actor boundaries.
@MainActor
final class ReadingPlaybackServiceCoordinationTests: XCTestCase {

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

    /// Persist a ReadingListItem with `chunkCount` chunks so the manager can find
    /// it by id. Returns the item's UUID.
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

    @MainActor
    private func persistedPosition(for itemId: UUID) -> Int32? {
        let request = ReadingListItem.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", itemId as CVarArg)
        request.fetchLimit = 1
        return try? persistence.viewContext.fetch(request).first?.currentChunkIndex
    }

    /// Spin until the service reaches one of the target states or attempts run out.
    /// ReadingPlaybackState is Equatable but not Hashable (the .error case carries a
    /// String), so targets are matched with a linear contains.
    private func waitForState(
        _ service: ReadingPlaybackService,
        in targets: [ReadingPlaybackState],
        attempts: Int = 60
    ) async -> ReadingPlaybackState {
        var state = await service.state
        for _ in 0..<attempts {
            if targets.contains(state) { return state }
            try? await Task.sleep(for: .milliseconds(50))
            state = await service.state
        }
        return state
    }

    /// Spin until the service state is any .error case (which carries a message we
    /// cannot match by literal value), or attempts run out.
    private func waitForErrorState(
        _ service: ReadingPlaybackService,
        attempts: Int = 60
    ) async -> ReadingPlaybackState {
        var state = await service.state
        for _ in 0..<attempts {
            if case .error = state { return state }
            try? await Task.sleep(for: .milliseconds(50))
            state = await service.state
        }
        return state
    }

    // MARK: - Re-entrant startPlayback (session swapping)

    func testStartPlayback_calledAgain_swapsToNewItemChunks() async throws {
        let service = await makeConfiguredService()
        let itemA = await persistItem(chunkCount: 3)
        let itemB = await persistItem(chunkCount: 7)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemA, chunks: makeChunks(3))
        let totalAfterA = await service.totalChunks
        XCTAssertEqual(totalAfterA, 3)

        // Starting a new item must replace the prior session's chunk set entirely.
        try await service.startPlayback(itemId: itemB, chunks: makeChunks(7), startIndex: 2)
        let totalAfterB = await service.totalChunks
        let indexAfterB = await service.currentChunkIndex
        XCTAssertEqual(totalAfterB, 7, "Restarting playback loads the new item's chunks")
        XCTAssertEqual(indexAfterB, 2, "Restarting honors the new start index")

        await service.stopPlayback()
    }

    func testStartPlayback_calledAgain_persistsPriorItemPosition() async throws {
        let service = await makeConfiguredService()
        let itemA = await persistItem(chunkCount: 6)
        let itemB = await persistItem(chunkCount: 4)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        // Advance item A to chunk 3, then start item B. The internal stop that
        // precedes the new session must flush item A's position to Core Data.
        try await service.startPlayback(itemId: itemA, chunks: makeChunks(6))
        try await service.skipToChunk(3)

        try await service.startPlayback(itemId: itemB, chunks: makeChunks(4))

        let savedA = await persistedPosition(for: itemA)
        XCTAssertEqual(savedA, 3, "Switching items persists the previous item's last position")

        await service.stopPlayback()
    }

    func testStartPlayback_calledAgain_doesNotCorruptNewItemPosition() async throws {
        // Regression guard: the cleanup of the prior session must not leak its
        // index into the freshly started session.
        let service = await makeConfiguredService()
        let itemA = await persistItem(chunkCount: 8)
        let itemB = await persistItem(chunkCount: 5)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemA, chunks: makeChunks(8), startIndex: 6)
        try await service.startPlayback(itemId: itemB, chunks: makeChunks(5))

        let indexB = await service.currentChunkIndex
        XCTAssertEqual(indexB, 0, "A fresh session with default start index begins at chunk 0")

        await service.stopPlayback()
    }

    // MARK: - updateChunks before playback starts

    func testUpdateChunks_beforePlayback_updatesTotalChunks() async {
        // updateChunks is reachable on a configured service that has never started
        // playback (e.g. when pre-gen audio finishes before the user hits play).
        let service = await makeConfiguredService()

        let initial = await service.totalChunks
        XCTAssertEqual(initial, 0)

        await service.updateChunks(makeChunks(4))
        let updated = await service.totalChunks
        XCTAssertEqual(updated, 4, "updateChunks loads chunks even before playback begins")
    }

    func testUpdateChunks_doesNotChangeStateOrIndex() async {
        // Loading fresh chunks is a data refresh, not a transport command: it must
        // not move the service out of idle or alter the current index.
        let service = await makeConfiguredService()

        await service.updateChunks(makeChunks(3))

        let state = await service.state
        let index = await service.currentChunkIndex
        XCTAssertEqual(state, .idle, "updateChunks must not start playback")
        XCTAssertEqual(index, 0, "updateChunks must not move the playback position")
    }

    // MARK: - Skip while already playing

    func testSkipToChunk_whilePlaying_staysPlaying() async throws {
        // The paused -> playing transition is covered elsewhere. This guards the
        // other branch: skipping while already playing must remain .playing.
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 6)
        await mockTTS.configureStreaming(chunks: 5, bytesPerChunk: 9600)
        await mockTTS.enableLatencySimulation(ttftMs: 0, tokenDelayMs: 200)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(6))
        let playingBefore = await service.state
        XCTAssertEqual(playingBefore, .playing)

        try await service.skipToChunk(4)

        let stateAfter = await service.state
        let indexAfter = await service.currentChunkIndex
        XCTAssertEqual(stateAfter, .playing, "Skipping while playing keeps playback running")
        XCTAssertEqual(indexAfter, 4)

        await service.stopPlayback()
    }

    // MARK: - Orchestrator error bridges to service error

    func testTTSSynthesisFailure_transitionsServiceToError() async throws {
        // When every audio source for a segment fails, the orchestrator reports an
        // error which the reading delegate bridges into the service .error state.
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 2)
        await mockTTS.configureToFail(with: .connectionFailed("synthesis down"))

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(2))

        let state = await waitForErrorState(service)
        guard case .error = state else {
            return XCTFail("Expected service to enter .error after TTS failure, got \(state)")
        }
    }

    func testTTSSynthesisFailure_firesOnErrorAsPlaybackFailed() async throws {
        let recorder = ErrorRecorder()
        let callbacks = ReadingPlaybackCallbacks(
            onError: { error in Task { await recorder.record(error) } }
        )
        let service = await makeConfiguredService(callbacks: callbacks)
        let itemId = await persistItem(chunkCount: 2)
        await mockTTS.configureToFail(with: .connectionFailed("synthesis down"))

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(2))

        let mapped = await recorder.waitForPlaybackFailed(attempts: 60)
        XCTAssertTrue(
            mapped,
            "onError should fire with a ReadingPlaybackError.playbackFailed wrapping the failure"
        )
    }

    func testTTSSuccess_neverEntersErrorState() async throws {
        // Counterpart to the failure tests: a healthy single-chunk synthesis runs
        // to completion without ever surfacing an error to the service.
        let service = await makeConfiguredService()
        let itemId = await persistItem(chunkCount: 2)
        await mockTTS.configureStreaming(chunks: 1, bytesPerChunk: 9600)

        try await service.startPlayback(itemId: itemId, chunks: makeChunks(2))

        let state = await waitForState(service, in: [.completed], attempts: 80)
        XCTAssertEqual(state, .completed, "A successful run completes without entering .error")
    }
}

// MARK: - Test Support Actor (real coordination primitive, not a service mock)

/// Records onError callback payloads so the test can assert on the mapped error
/// type. This is a real synchronization primitive, not a mock of any service.
private actor ErrorRecorder {
    private var errors: [Error] = []

    func record(_ error: Error) { errors.append(error) }

    /// Wait until at least one recorded error is a ReadingPlaybackError.playbackFailed.
    func waitForPlaybackFailed(attempts: Int) async -> Bool {
        for _ in 0..<attempts {
            if containsPlaybackFailed { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return containsPlaybackFailed
    }

    private var containsPlaybackFailed: Bool {
        errors.contains { error in
            if let readingError = error as? ReadingPlaybackError,
               case .playbackFailed = readingError {
                return true
            }
            return false
        }
    }
}
