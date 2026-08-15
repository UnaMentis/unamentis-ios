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

import AVFoundation
import XCTest
@testable import UnaMentis

// MARK: - Test Doubles
//
// ALLOWED: these stand in for INTERNAL provider seams (a system synthesizer and
// an STT provider), not for paid external APIs, so they carry no Mock prefix.
// They exist because the defects under test are timing and lifecycle behavior
// that cannot be driven deterministically through live audio hardware.

/// A TTS provider that owns its own playback, exactly like AppleTTSService: it
/// emits no PCM while speaking and only its own `stop()` can cut it short.
private actor ScriptedSystemTTS: SystemSynthesizerTTS {
    enum Behavior: Sendable {
        /// Yields one chunk and finishes after the given delay.
        case finishes(after: Duration)
        /// Never finishes on its own; only `stop()` ends it.
        case runsForever
        /// Finishes immediately without ever producing audio.
        case producesNothing
    }

    let metrics = TTSMetrics(medianTTFB: 0, p99TTFB: 0)
    var costPerCharacter: Decimal { 0 }
    private(set) var voiceConfig = TTSVoiceConfig(voiceId: "test", rate: 1.0)

    private let behavior: Behavior
    private var continuation: AsyncStream<TTSAudioChunk>.Continuation?
    private var speechTask: Task<Void, Never>?
    private(set) var stopCount = 0
    private(set) var isSpeaking = false

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func configure(_ config: TTSVoiceConfig) async {
        voiceConfig = config
    }

    func synthesize(text: String) async throws -> AsyncStream<TTSAudioChunk> {
        let (stream, continuation) = AsyncStream<TTSAudioChunk>.makeStream()
        self.continuation = continuation
        isSpeaking = true
        switch behavior {
        case .producesNothing:
            isSpeaking = false
            continuation.finish()
        case .finishes(let delay):
            speechTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                await self?.finishSpeaking(emittingChunk: true)
            }
        case .runsForever:
            break
        }
        return stream
    }

    func flush() async throws {
        await stop()
    }

    /// The provider-level stop. On the real service this is
    /// `AVSpeechSynthesizer.stopSpeaking(at: .immediate)`.
    func stop() async {
        stopCount += 1
        speechTask?.cancel()
        speechTask = nil
        finishSpeaking(emittingChunk: false)
    }

    private func finishSpeaking(emittingChunk: Bool) {
        guard isSpeaking else { return }
        isSpeaking = false
        if emittingChunk {
            continuation?.yield(TTSAudioChunk(
                audioData: Data([0, 0, 0, 0]),
                format: .pcmFloat32(sampleRate: 24000, channels: 1),
                sequenceNumber: 0,
                isFirst: true,
                isLast: true
            ))
        }
        continuation?.finish()
        continuation = nil
    }
}

/// An STT provider with the same teardown SHAPE as AppleSpeechSTTService: a
/// teardown that lands some time after it is asked for, and tears down whatever
/// recognition stream exists at that later moment.
private actor ScriptedSTT: STTService {
    let metrics = STTMetrics(medianLatency: 0, p99Latency: 0, wordEmissionRate: 0)
    var costPerHour: Decimal { 0 }
    private(set) var isStreaming = false

    private let teardownDelay: Duration
    private var continuation: AsyncStream<STTResult>.Continuation?
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private(set) var stopCount = 0

    init(teardownDelay: Duration = .milliseconds(200)) {
        self.teardownDelay = teardownDelay
    }

    func startStreaming(audioFormat: sending AVAudioFormat) async throws -> AsyncStream<STTResult> {
        startCount += 1
        let (stream, continuation) = AsyncStream<STTResult>.makeStream()
        self.continuation = continuation
        isStreaming = true
        return stream
    }

    func sendAudio(_ buffer: sending AVAudioPCMBuffer) async throws {}

    func stopStreaming() async throws {
        stopCount += 1
        try? await Task.sleep(for: teardownDelay)
        cleanup()
    }

    func cancelStreaming() async {
        cancelCount += 1
        // Matches AppleSpeechSTTService: the streaming flag drops right away,
        // but the actual teardown lands later and hits whatever stream exists
        // at THAT moment.
        isStreaming = false
        try? await Task.sleep(for: teardownDelay)
        cleanup()
    }

    /// Push a recognition result into whichever stream is currently live.
    func emit(_ transcript: String, confidence: Float = 0.8) {
        continuation?.yield(STTResult(
            transcript: transcript, isFinal: false, isEndOfUtterance: false, confidence: confidence
        ))
    }

    private func cleanup() {
        continuation?.finish()
        continuation = nil
        isStreaming = false
    }
}

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

    /// A service on scripted providers plus a real (never started) AudioEngine,
    /// so listen() runs its full path without touching audio hardware.
    private func makeScriptedService(
        ownership: VoicePipelineOwnership,
        tts: ScriptedSystemTTS = ScriptedSystemTTS(behavior: .finishes(after: .milliseconds(50))),
        stt: ScriptedSTT = ScriptedSTT(),
        engine: AudioEngine? = nil
    ) -> UnifiedVoiceSessionService {
        UnifiedVoiceSessionService(
            ownership: ownership,
            engineProvider: { engine },
            ttsResolver: { tts },
            sttFactory: { stt }
        )
    }

    /// A real AudioEngine that is never configured or started: it publishes no
    /// frames, which is exactly the stalled-audio condition the wall-clock
    /// deadlines exist for.
    private func makeIdleEngine() -> AudioEngine {
        AudioEngine(config: .default, vadService: SileroVADService(), telemetry: TelemetryEngine())
    }

    private func vad(speech: Bool, at timestamp: TimeInterval, confidence: Float = 0.9) -> VADResult {
        VADResult(isSpeech: speech, confidence: confidence, timestamp: timestamp, segmentDuration: 0.1)
    }

    /// Wait until `condition` holds or the deadline passes.
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
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

    // MARK: - Stopping the System Synthesizer Path

    func testStopSpeakingStopsTheSystemSynthesizerPath() async throws {
        // The system-synthesizer branch installs no orchestrator, so stopping
        // only the orchestrator made stopSpeaking() a no-op there: barge-in
        // could not stop narration and a buzz could not cut off a tossup.
        let ownership = VoicePipelineOwnership()
        let tts = ScriptedSystemTTS(behavior: .runsForever)
        let service = makeScriptedService(ownership: ownership, tts: tts)
        let session = try await service.acquire(config: VoicePipelineConfig(bargeIn: .full))

        let speaking = Task { try await session.speak(.text("A long tossup being read aloud.")) }
        let started = await waitUntil { await tts.isSpeaking }
        XCTAssertTrue(started, "The scripted synthesizer should be speaking")

        await session.stopSpeaking()

        let stopped = await waitUntil { await tts.stopCount > 0 }
        XCTAssertTrue(stopped, "stopSpeaking must reach the provider on this path")
        try await speaking.value  // Returns promptly, and does NOT report failure.
        let speakingStill = await tts.isSpeaking
        XCTAssertFalse(speakingStill)
        await session.release()
    }

    func testReleaseStopsTheSystemSynthesizerBeforeHandingBackThePipeline() async throws {
        // release() used to hand the pipeline back while AVSpeechSynthesizer was
        // still speaking, so a core session could start over a live voice.
        let ownership = VoicePipelineOwnership()
        let tts = ScriptedSystemTTS(behavior: .runsForever)
        let service = makeScriptedService(ownership: ownership, tts: tts)
        let session = try await service.acquire(config: VoicePipelineConfig())

        let speaking = Task { try? await session.speak(.text("Still reading.")) }
        _ = await waitUntil { await tts.isSpeaking }

        await session.release()
        _ = await speaking.value

        let stillSpeaking = await tts.isSpeaking
        XCTAssertFalse(stillSpeaking, "The pipeline must not be handed back while speech continues")
        let holder = await ownership.holder
        XCTAssertNil(holder)
    }

    func testSystemSynthesizerPathIsBoundedInWallClockTime() {
        // Bounded synthesis is a locked guarantee (commit 7483a6d); this path
        // had no timeout at all, so a stalled synthesizer hung the module.
        // The bound is twice the estimated spoken duration plus the
        // orchestrator's buffer timeout as slack, clamped to 5...300 seconds.
        // The slack dominates for a short utterance, so the 5 second floor is
        // a lower guarantee rather than the value a short string produces.
        let shortBound = UnifiedVoiceSession.systemSynthesisBound(for: "hi")
        XCTAssertGreaterThanOrEqual(shortBound, 5, "The bound never drops below the floor")
        XCTAssertLessThanOrEqual(shortBound, 300, "The bound never exceeds the cap")
        XCTAssertGreaterThan(
            UnifiedVoiceSession.systemSynthesisBound(for: String(repeating: "a", count: 2000)),
            UnifiedVoiceSession.systemSynthesisBound(for: "short"),
            "A longer utterance gets a longer bound"
        )
        XCTAssertLessThanOrEqual(
            UnifiedVoiceSession.systemSynthesisBound(for: String(repeating: "a", count: 1_000_000)),
            300,
            "The bound is capped"
        )
    }

    func testSystemSynthesizerEmptyStreamSurfacesAsAnError() async throws {
        // A provider that produces nothing must surface, never pass as a
        // successful (silent) utterance.
        let ownership = VoicePipelineOwnership()
        let tts = ScriptedSystemTTS(behavior: .producesNothing)
        let service = makeScriptedService(ownership: ownership, tts: tts)
        let session = try await service.acquire(config: VoicePipelineConfig())

        do {
            try await session.speak(.text("Nothing comes back."))
            XCTFail("An empty synthesis stream must throw")
        } catch let error as VoiceSessionError {
            guard case .synthesisFailed = error else {
                return XCTFail("Expected synthesisFailed, got \(error)")
            }
        }
        await session.release()
    }

    // MARK: - Overlapping Calls

    func testConcurrentSpeakCallsReportAlreadySpeaking() async throws {
        // The guard and the isSpeaking assignment used to be separated by
        // awaits, so both callers passed the guard.
        let ownership = VoicePipelineOwnership()
        let tts = ScriptedSystemTTS(behavior: .runsForever)
        let service = makeScriptedService(ownership: ownership, tts: tts)
        let session = try await service.acquire(config: VoicePipelineConfig())

        let first = Task { try await session.speak(.text("First utterance.")) }
        let speaking = await waitUntil { await tts.isSpeaking }
        XCTAssertTrue(speaking)

        do {
            try await session.speak(.text("Second utterance."))
            XCTFail("A second speak while one is in flight must throw")
        } catch let error as VoiceSessionError {
            XCTAssertEqual(error, .alreadySpeaking)
        }

        await session.stopSpeaking()
        try await first.value
        let synthesisStarts = await tts.stopCount
        XCTAssertEqual(synthesisStarts, 1, "Only the accepted utterance was ever synthesized")
        await session.release()
    }

    func testConcurrentListenCallsReportAlreadyListeningAndNeitherHangs() async throws {
        // Two overlapping listens both passed the guard; the second overwrote
        // the first's continuation, and the first caller hung forever
        // (SWIFT TASK CONTINUATION MISUSE).
        let ownership = VoicePipelineOwnership()
        let stt = ScriptedSTT()
        let service = makeScriptedService(ownership: ownership, stt: stt, engine: makeIdleEngine())
        let session = try await service.acquire(config: VoicePipelineConfig(
            endpointing: EndpointingPolicy(silenceThreshold: 0.2, maxUtteranceDuration: 1.0),
            answerTimeout: .milliseconds(400)
        ))

        async let first = try? await session.listen(expecting: .answer)
        async let second = try? await session.listen(expecting: .answer)
        let (firstResult, secondResult) = await (first, second)

        // Exactly one listen ran (and ended by its wall-clock timeout); the
        // other was rejected. Neither hung.
        let completed = [firstResult, secondResult].compactMap { $0 }
        XCTAssertEqual(completed.count, 1, "Exactly one of two overlapping listens may run")
        XCTAssertEqual(completed.first?.endedBy, .timeout)
        let starts = await stt.startCount
        XCTAssertEqual(starts, 1, "The rejected listen must not start a second STT stream")
        await session.release()
    }

    // MARK: - Wall-Clock Deadlines

    func testAnswerTimeoutFiresInWallClockTimeWhenNoFramesArrive() async throws {
        // The endpointer only advances on VAD frames, so a stalled audio path
        // (interruption, route change, dead recognition task) left listen()
        // awaiting forever with isListening stuck true.
        let ownership = VoicePipelineOwnership()
        let service = makeScriptedService(ownership: ownership, engine: makeIdleEngine())
        let session = try await service.acquire(config: VoicePipelineConfig(
            endpointing: EndpointingPolicy(silenceThreshold: 1.5, maxUtteranceDuration: 60),
            answerTimeout: .milliseconds(300)
        ))

        let started = Date()
        let result = try await session.listen(expecting: .answer)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result.endedBy, .timeout)
        XCTAssertLessThan(elapsed, 3.0, "The answer timeout must fire in real time")
        XCTAssertGreaterThan(elapsed, 0.2, "It must not fire before the configured timeout")

        // The session is usable again afterwards.
        let second = try await session.listen(expecting: .answer)
        XCTAssertEqual(second.endedBy, .timeout)
        await session.release()
    }

    func testFractionalAnswerTimeoutIsNotTruncated() {
        // components.seconds alone truncates 2.5 s to 2 and 800 ms to 0, which
        // made the endpointer fire .timeout on the very first silent frame.
        XCTAssertEqual(Duration.milliseconds(2500).timeIntervalSeconds, 2.5, accuracy: 0.0001)
        XCTAssertEqual(Duration.milliseconds(800).timeIntervalSeconds, 0.8, accuracy: 0.0001)
        XCTAssertEqual(Duration.seconds(5).timeIntervalSeconds, 5.0, accuracy: 0.0001)
    }

    func testMaxUtteranceDurationFiresInWallClockTimeAfterSpeech() async throws {
        let ownership = VoicePipelineOwnership()
        let service = makeScriptedService(ownership: ownership, engine: makeIdleEngine())
        guard let session = try await service.acquire(config: VoicePipelineConfig(
            endpointing: EndpointingPolicy(silenceThreshold: 30, maxUtteranceDuration: 0.4),
            answerTimeout: .milliseconds(200)
        )) as? UnifiedVoiceSession else {
            return XCTFail("Expected UnifiedVoiceSession")
        }

        let listening = Task { try await session.listen(expecting: .answer) }
        _ = await waitUntil { await session.isCapturing }
        // One speech frame, then the audio path goes silent (no more frames).
        await session.ingest(vad(speech: true, at: 100.0))

        let result = try await listening.value
        XCTAssertEqual(result.endedBy, .maxUtteranceDuration,
                       "Speech was detected, so the answer timeout must not claim it")
        await session.release()
    }

    // MARK: - Back-to-Back Listens

    func testBackToBackListenIsNotKilledByThePreviousTeardown() async throws {
        // The previous listen's teardown tore down whatever recognition request
        // existed when it landed, which was the NEW listen's request. Results
        // then never arrived and the answer was graded incorrect with no error.
        let ownership = VoicePipelineOwnership()
        let stt = ScriptedSTT(teardownDelay: .milliseconds(250))
        let service = makeScriptedService(ownership: ownership, stt: stt, engine: makeIdleEngine())
        guard let session = try await service.acquire(config: VoicePipelineConfig(
            endpointing: EndpointingPolicy(silenceThreshold: 0.2, maxUtteranceDuration: 30),
            answerTimeout: .seconds(3)
        )) as? UnifiedVoiceSession else {
            return XCTFail("Expected UnifiedVoiceSession")
        }

        // First listen: one answer, then silence past the threshold.
        let first = Task { try await session.listen(expecting: .answer) }
        _ = await waitUntil { await session.isCapturing }
        await stt.emit("first answer")
        // Let the result reach the session before the endpointer finalizes.
        try? await Task.sleep(for: .milliseconds(50))
        await session.ingest(vad(speech: true, at: 10.0))
        await session.ingest(vad(speech: false, at: 10.1))
        await session.ingest(vad(speech: false, at: 10.5))
        let firstResult = try await first.value
        XCTAssertEqual(firstResult.transcript, "first answer")

        // Second listen starts immediately, inside the previous teardown window.
        let second = Task { try await session.listen(expecting: .answer) }
        _ = await waitUntil { await session.isCapturing }
        await stt.emit("second answer")
        try? await Task.sleep(for: .milliseconds(50))
        await session.ingest(vad(speech: true, at: 20.0))
        await session.ingest(vad(speech: false, at: 20.1))
        await session.ingest(vad(speech: false, at: 20.5))
        let secondResult = try await second.value

        XCTAssertEqual(
            secondResult.transcript, "second answer",
            "A stale teardown must not silence the next listen"
        )
        XCTAssertNotEqual(secondResult.endedBy, .timeout)
        await session.release()
    }

    // MARK: - Pipeline Ownership Safety Net

    func testDroppedSessionReleasesThePipeline() async throws {
        // A session dropped without release() (task cancelled, throw before the
        // defer, a view model torn down on an unexpected path) used to brick the
        // pipeline for the whole process.
        let ownership = VoicePipelineOwnership()
        let service = makeScriptedService(ownership: ownership)

        // The acquired session is discarded immediately, without release().
        func acquireAndDrop() async throws {
            _ = try await service.acquire(config: VoicePipelineConfig())
        }
        try await acquireAndDrop()

        let reclaimed = await waitUntil(timeout: 3.0) { await ownership.holder == nil }
        XCTAssertTrue(reclaimed, "A dropped session must give the pipeline back")

        // And the pipeline is genuinely usable again.
        let next = try await service.acquire(config: VoicePipelineConfig())
        await next.release()
    }

    // MARK: - Event Stream Bounds

    func testEventStreamBuffersAreBounded() async throws {
        // A module is free never to iterate events (QuizMatchEngine deliberately
        // does not); unbounded buffering accumulated every partial transcript
        // for the whole session against the memory budget.
        XCTAssertLessThanOrEqual(UnifiedVoiceSession.eventBufferCapacity, 256)
        XCTAssertGreaterThan(UnifiedVoiceSession.eventBufferCapacity, 0)

        let ownership = VoicePipelineOwnership()
        let service = makeScriptedService(ownership: ownership)
        guard let session = try await service.acquire(config: VoicePipelineConfig()) as? UnifiedVoiceSession else {
            return XCTFail("Expected UnifiedVoiceSession")
        }

        // Nobody is iterating: push far more events than the buffer holds.
        for index in 0..<1000 {
            await session.ingest(vad(speech: index.isMultiple(of: 2), at: Double(index) * 0.1))
        }

        // Release finishes the stream; whatever was buffered still drains, and
        // that is what the memory budget pays for.
        await session.release()
        var delivered = 0
        for await _ in session.events {
            delivered += 1
        }
        XCTAssertGreaterThan(delivered, 0, "The newest events are still delivered")
        XCTAssertLessThanOrEqual(
            delivered, UnifiedVoiceSession.eventBufferCapacity,
            "An unread event stream must not grow without bound"
        )
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
