// UnaMentis - Unified Voice Session Service Tests
//
// Covers the Phase 2 VoiceSession host service (MODULE_SDK_SPEC.md 5.1):
// - exclusive acquisition semantics against core sessions and other modules
//   (VoicePipelineOwnership, the exact mechanism SessionManager hooks)
// - typed errors after release
// - the pre-rendered audio path (server-pregenerated KB audio)
// - event stream delivery, with deterministic VAD frame injection through
//   the same seam the barge-in measurement harness uses
//
// Real over mock: sessions are built on the real on-device providers
// (AppleTTSService, AppleSpeechSTTService) with a nil engine provider so no
// live audio hardware is touched; audio-path behavior is exercised through
// injected VAD frames like BargeInDetectorTests.

import XCTest
@testable import UnaMentis

final class UnifiedVoiceSessionServiceTests: XCTestCase {

    // MARK: - Helpers

    private func makeService(ownership: VoicePipelineOwnership) -> UnifiedVoiceSessionService {
        UnifiedVoiceSessionService(
            ownership: ownership,
            engineProvider: { nil },
            ttsResolver: { AppleTTSService() },
            sttFactory: { AppleSpeechSTTService() }
        )
    }

    private func vad(speech: Bool, at timestamp: TimeInterval, confidence: Float = 0.9) -> VADResult {
        VADResult(isSpeech: speech, confidence: confidence, timestamp: timestamp, segmentDuration: 0.1)
    }

    // MARK: - Ownership Arbitration (the mechanism SessionManager hooks)

    func testClaimIsExclusiveAcrossHolders() async throws {
        let ownership = VoicePipelineOwnership()
        try await ownership.claim(.coreSession)

        do {
            try await ownership.claim(.module(sessionID: UUID()))
            XCTFail("Claiming a held pipeline must throw")
        } catch let error as VoiceSessionError {
            guard case .pipelineBusy = error else {
                return XCTFail("Expected pipelineBusy, got \(error)")
            }
        }
    }

    func testClaimIsIdempotentPerHolder() async throws {
        let ownership = VoicePipelineOwnership()
        try await ownership.claim(.coreSession)
        try await ownership.claim(.coreSession)
        let holder = await ownership.holder
        XCTAssertEqual(holder, .coreSession)
    }

    func testReleaseOnlyClearsForTheActualOwner() async throws {
        let ownership = VoicePipelineOwnership()
        let moduleHolder = VoicePipelineHolder.module(sessionID: UUID())
        try await ownership.claim(moduleHolder)

        // A stale release from someone else must not free the pipeline.
        await ownership.release(.coreSession)
        var holder = await ownership.holder
        XCTAssertEqual(holder, moduleHolder)

        await ownership.release(moduleHolder)
        holder = await ownership.holder
        XCTAssertNil(holder)
    }

    // MARK: - Exclusive Acquisition

    func testAcquireIsExclusiveBetweenModuleSessions() async throws {
        let ownership = VoicePipelineOwnership()
        let service = makeService(ownership: ownership)

        let first = try await service.acquire(config: VoicePipelineConfig())
        do {
            _ = try await service.acquire(config: VoicePipelineConfig())
            XCTFail("Second acquire while held must throw pipelineBusy")
        } catch let error as VoiceSessionError {
            guard case .pipelineBusy = error else {
                return XCTFail("Expected pipelineBusy, got \(error)")
            }
        }

        await first.release()
        let second = try await service.acquire(config: VoicePipelineConfig())
        await second.release()
    }

    func testAcquireWhileCoreSessionHoldsPipelineThrows() async throws {
        let ownership = VoicePipelineOwnership()
        let service = makeService(ownership: ownership)

        // SessionManager.startSession claims .coreSession via this same call.
        try await ownership.claim(.coreSession)

        do {
            _ = try await service.acquire(config: VoicePipelineConfig())
            XCTFail("Acquire during a core session must throw pipelineBusy")
        } catch let error as VoiceSessionError {
            guard case .pipelineBusy = error else {
                return XCTFail("Expected pipelineBusy, got \(error)")
            }
        }
    }

    func testReleaseHandsPipelineBackToCoreSession() async throws {
        let ownership = VoicePipelineOwnership()
        let service = makeService(ownership: ownership)

        let session = try await service.acquire(config: VoicePipelineConfig())
        await session.release()

        // The core session can now claim (SessionManager.startSession path).
        try await ownership.claim(.coreSession)
        let holder = await ownership.holder
        XCTAssertEqual(holder, .coreSession)
    }

    // MARK: - Released Session Errors

    func testSpeakAfterReleaseThrowsTypedError() async throws {
        let ownership = VoicePipelineOwnership()
        let service = makeService(ownership: ownership)
        let session = try await service.acquire(config: VoicePipelineConfig())
        await session.release()

        do {
            try await session.speak(.text("hello"))
            XCTFail("speak after release must throw")
        } catch let error as VoiceSessionError {
            XCTAssertEqual(error, .sessionReleased)
        }
    }

    func testListenAfterReleaseThrowsTypedError() async throws {
        let ownership = VoicePipelineOwnership()
        let service = makeService(ownership: ownership)
        let session = try await service.acquire(config: VoicePipelineConfig())
        await session.release()

        do {
            _ = try await session.listen(expecting: .answer)
            XCTFail("listen after release must throw")
        } catch let error as VoiceSessionError {
            XCTAssertEqual(error, .sessionReleased)
        }
    }

    func testReleaseIsIdempotent() async throws {
        let ownership = VoicePipelineOwnership()
        let service = makeService(ownership: ownership)
        let session = try await service.acquire(config: VoicePipelineConfig())
        await session.release()
        await session.release()
        let holder = await ownership.holder
        XCTAssertNil(holder)
    }

    // MARK: - Pre-Rendered Audio Path

    func testPreRenderedDataConvertsToCachedSegmentAudio() throws {
        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        let audio = PreRenderedAudio(source: .data(bytes), sampleRate: 24000, channels: 1)

        let cached = try audio.toCachedSegmentAudio()
        XCTAssertEqual(cached.audioData, bytes)
        XCTAssertEqual(cached.sampleRate, 24000)
        XCTAssertEqual(cached.channels, 1)

        // The pipeline chunk KB's server audio plays through.
        let chunk = cached.toTTSAudioChunk()
        XCTAssertEqual(chunk.audioData, bytes)
        XCTAssertTrue(chunk.isFirst)
        XCTAssertTrue(chunk.isLast)
    }

    func testPreRenderedFileConvertsToCachedSegmentAudio() throws {
        let bytes = Data([0xAA, 0xBB, 0xCC])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-session-prerendered-\(UUID().uuidString).pcm")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let audio = PreRenderedAudio(source: .file(url), sampleRate: 16000, channels: 1)
        let cached = try audio.toCachedSegmentAudio()
        XCTAssertEqual(cached.audioData, bytes)
        XCTAssertEqual(cached.sampleRate, 16000)
    }

    func testUtteranceConstructors() {
        let plain = Utterance.text("What is the SI unit of current?")
        XCTAssertEqual(plain.text, "What is the SI unit of current?")
        XCTAssertNil(plain.preRendered)

        let audio = PreRenderedAudio(source: .data(Data([1])), sampleRate: 24000)
        let rendered = Utterance.preRendered(audio, fallbackText: "Ampere")
        XCTAssertEqual(rendered.text, "Ampere")
        XCTAssertNotNil(rendered.preRendered)
    }

    // MARK: - Event Stream Delivery

    func testEventStreamDeliversVadStateTransitions() async throws {
        let ownership = VoicePipelineOwnership()
        let service = makeService(ownership: ownership)
        guard let session = try await service.acquire(config: VoicePipelineConfig()) as? UnifiedVoiceSession else {
            return XCTFail("Expected UnifiedVoiceSession")
        }

        let eventsTask = Task { [weak session] () -> [VoiceEvent] in
            guard let session else { return [] }
            var received: [VoiceEvent] = []
            for await event in session.events {
                received.append(event)
                if received.count >= 3 { break }
            }
            return received
        }

        // Deterministic frame injection (the harness seam). Transitions only:
        // speech, speech, silence, speech emits exactly three vadState events.
        await session.ingest(vad(speech: true, at: 0.0))
        await session.ingest(vad(speech: true, at: 0.1))
        await session.ingest(vad(speech: false, at: 0.2))
        await session.ingest(vad(speech: true, at: 0.3))

        let received = await eventsTask.value
        let states: [Bool] = received.compactMap {
            if case .vadState(let isSpeech) = $0 { return isSpeech }
            return nil
        }
        XCTAssertEqual(states, [true, false, true])
        await session.release()
    }

    func testBargeInEventsComeFromTheCanonicalDetector() async throws {
        let ownership = VoicePipelineOwnership()
        let service = makeService(ownership: ownership)
        let config = VoicePipelineConfig(bargeIn: .full)
        guard let session = try await service.acquire(config: config) as? UnifiedVoiceSession else {
            return XCTFail("Expected UnifiedVoiceSession")
        }

        let collected = Task { [weak session] () -> [BargeInEvent.Kind] in
            guard let session else { return [] }
            var kinds: [BargeInEvent.Kind] = []
            for await event in session.events {
                if case .bargeIn(let bargeEvent) = event {
                    kinds.append(bargeEvent.kind)
                    if bargeEvent.kind == .confirmed { break }
                }
            }
            return kinds
        }

        // Arm exactly as speak() does, then inject sustained speech past the
        // detector's sustained-speech threshold (default 700 ms).
        await session.armBargeIn()
        await session.ingest(vad(speech: true, at: 10.0, confidence: 0.95))
        await session.ingest(vad(speech: true, at: 10.4, confidence: 0.95))
        await session.ingest(vad(speech: true, at: 10.9, confidence: 0.95))

        let kinds = await collected.value
        XCTAssertEqual(kinds.first, .tentative, "Speech onset must be tentative (narration keeps flowing)")
        XCTAssertEqual(kinds.last, .confirmed, "Sustained speech must confirm a genuine barge-in")
        await session.release()
    }

    // MARK: - Host Wiring

    func testHostCapabilitiesAdvertiseVoiceSession() {
        XCTAssertTrue(HostCapabilities.provided.contains("voice.session/1"))
    }

    func testDefaultModuleHostCarriesUnifiedVoiceService() {
        let host = DefaultModuleHost()
        XCTAssertTrue(host.voice is UnifiedVoiceSessionService)
    }

    @MainActor
    func testModuleCatalogConstructsDefaultHost() {
        XCTAssertTrue(ModuleCatalog.shared.host is DefaultModuleHost)
    }
}
