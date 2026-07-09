// UnaMentis - Unified Voice Session Service
// The production VoiceSessionService on the app's single voice pipeline.
//
// Composes the EXISTING unified pipeline components, creating no parallel
// audio machinery:
// - AudioEngine via AudioEngineCache.shared (one capture/playback pipeline)
// - AudioPlaybackOrchestrator for TTS playback (bounded synthesis: stalls and
//   empty streams surface as errors, never silent hangs)
// - the canonical BargeInDetector (the ONE detector; tuned by BargeInTuning)
// - the shared on-device providers (AppleSpeechSTTService; Pocket TTS with
//   Apple TTS fallback, honoring the user's ttsProvider setting)
//
// Exclusive acquisition is arbitrated by VoicePipelineOwnership against the
// core session (SessionManager) and other module sessions.

@preconcurrency import AVFoundation
import Combine
import Foundation
import Logging

// MARK: - Service

/// Production `VoiceSessionService` composing the unified voice pipeline.
public actor UnifiedVoiceSessionService: VoiceSessionService {
    /// Provides the shared audio engine. Injectable for tests.
    typealias EngineProvider = @Sendable () async -> AudioEngine?
    /// Resolves the TTS provider. Injectable for tests.
    typealias TTSResolver = @Sendable () async -> any TTSService
    /// Creates the STT provider. Injectable for tests.
    typealias STTFactory = @Sendable () -> any STTService

    /// The app-wide instance used by DefaultModuleHost.
    public static let shared = UnifiedVoiceSessionService()

    private let ownership: VoicePipelineOwnership
    private let engineProvider: EngineProvider
    private let ttsResolver: TTSResolver
    private let sttFactory: STTFactory

    private static let logger = Logger(label: "com.unamentis.modules.voice")

    /// Production configuration: shared engine cache, user-configured
    /// on-device TTS (Pocket preferred, Apple fallback), Apple Speech STT.
    public init() {
        self.init(
            ownership: .shared,
            engineProvider: { await AudioEngineCache.shared.getEngine() },
            ttsResolver: { await Self.resolveConfiguredTTS() },
            sttFactory: { AppleSpeechSTTService() }
        )
    }

    /// Designated initializer with injection seams for tests.
    init(
        ownership: VoicePipelineOwnership,
        engineProvider: @escaping EngineProvider,
        ttsResolver: @escaping TTSResolver,
        sttFactory: @escaping STTFactory
    ) {
        self.ownership = ownership
        self.engineProvider = engineProvider
        self.ttsResolver = ttsResolver
        self.sttFactory = sttFactory
    }

    // MARK: VoiceSessionService

    public func acquire(config: VoicePipelineConfig) async throws -> any VoiceSession {
        let holder = VoicePipelineHolder.module(sessionID: UUID())
        try await ownership.claim(holder)
        Self.logger.info("Voice pipeline acquired by module session (bargeIn: \(config.bargeIn.rawValue))")

        let cues = await MainActor.run { VoiceActivityFeedback() }
        let session = UnifiedVoiceSession(
            config: config,
            holder: holder,
            ownership: ownership,
            engineProvider: engineProvider,
            ttsResolver: ttsResolver,
            sttFactory: sttFactory,
            cues: cues
        )
        // Best-effort prewarm (TTS model load, warm engine) so the first
        // speak() has no cold start. Failures surface later as typed errors.
        await session.prepare()
        return session
    }

    /// Resolve the user's configured on-device TTS provider. Knowledge Bowl
    /// and other modules are offline-capable activities, so cloud providers
    /// map to on-device Pocket TTS; Pocket falls back to Apple TTS when its
    /// models are unavailable.
    private static func resolveConfiguredTTS() async -> any TTSService {
        let raw = UserDefaults.standard.string(forKey: "ttsProvider")
        let provider = raw.flatMap { TTSProvider(rawValue: $0) } ?? .pocketTTS

        let service: any TTSService
        switch provider {
        case .appleTTS:
            service = AppleTTSService()
            logger.info("VoiceSession using Apple TTS (on-device)")
        default:
            let kyutai = KyutaiPocketTTSService(config: .lowLatency)
            do {
                try await kyutai.ensureLoaded()
                service = kyutai
                logger.info("VoiceSession using Pocket TTS (on-device)")
            } catch {
                logger.warning("Pocket TTS unavailable, falling back to Apple TTS: \(error)")
                service = AppleTTSService()
            }
        }
        await service.configure(TTSVoiceConfig(voiceId: "default", rate: 1.0))
        return service
    }
}

// MARK: - Session

/// An exclusively held module voice session on the unified pipeline.
actor UnifiedVoiceSession: VoiceSession {
    // MARK: State

    private let config: VoicePipelineConfig
    private let holder: VoicePipelineHolder
    private let ownership: VoicePipelineOwnership
    private let engineProvider: UnifiedVoiceSessionService.EngineProvider
    private let ttsResolver: UnifiedVoiceSessionService.TTSResolver
    private let sttFactory: UnifiedVoiceSessionService.STTFactory
    private let cues: VoiceActivityFeedback

    /// The canonical barge-in detector (the ONE detector in the app).
    private let detector: BargeInDetector
    private var detectorEventTask: Task<Void, Never>?

    private var ttsService: (any TTSService)?
    private var sttService: (any STTService)?

    private var released = false
    private var isSpeaking = false
    private var isListening = false

    /// Playback orchestrator for the in-progress speak() call.
    private var orchestrator: AudioPlaybackOrchestrator?

    /// Listening state for the in-progress listen() call.
    private var listenContinuation: CheckedContinuation<UtteranceResult, Error>?
    private var endpointer: UtteranceEndpointer?
    private var currentTranscript = ""
    private var lastConfidence: Float = 0
    private var sttStreamTask: Task<Void, Never>?

    /// Audio stream subscription (VAD frames + STT feed), keyed to the engine
    /// instance so a recreated engine is resubscribed.
    private var audioSubscription: AnyCancellable?
    private var subscribedEngineID: ObjectIdentifier?
    private var lastVadIsSpeech: Bool?

    /// Prefetched synthesis results keyed by utterance text (bounded).
    private var prefetched: [String: CachedSegmentAudio] = [:]
    private var prefetchOrder: [String] = []
    private let prefetchCapacity = 8

    /// Module command vocabularies by voice state.
    private var vocabularies: [ModuleVoiceState: CommandVocabulary] = [:]
    private var activeVoiceState: ModuleVoiceState?
    private let commandRecognizer = VoiceCommandRecognizer()
    private var lastCommandTranscript = ""

    private let eventStream: AsyncStream<VoiceEvent>
    private let eventContinuation: AsyncStream<VoiceEvent>.Continuation

    private static let logger = Logger(label: "com.unamentis.modules.voice.session")

    nonisolated var events: AsyncStream<VoiceEvent> { eventStream }

    // MARK: Init

    init(
        config: VoicePipelineConfig,
        holder: VoicePipelineHolder,
        ownership: VoicePipelineOwnership,
        engineProvider: @escaping UnifiedVoiceSessionService.EngineProvider,
        ttsResolver: @escaping UnifiedVoiceSessionService.TTSResolver,
        sttFactory: @escaping UnifiedVoiceSessionService.STTFactory,
        cues: VoiceActivityFeedback
    ) {
        self.config = config
        self.holder = holder
        self.ownership = ownership
        self.engineProvider = engineProvider
        self.ttsResolver = ttsResolver
        self.sttFactory = sttFactory
        self.cues = cues

        var detectorConfig = BargeInTuning.detectorConfig()
        detectorConfig.enabled = detectorConfig.enabled && (config.bargeIn != .off)
        self.detector = BargeInDetector(config: detectorConfig)

        (self.eventStream, self.eventContinuation) = AsyncStream<VoiceEvent>.makeStream()
    }

    // MARK: Preparation

    /// Best-effort prewarm: resolve TTS (loads Pocket models) and forward
    /// detector events. Does not throw; audio failures surface on first use.
    func prepare() async {
        guard !released else { return }
        if ttsService == nil {
            ttsService = await ttsResolver()
        }
        startDetectorEventForwarding()
    }

    private func startDetectorEventForwarding() {
        guard detectorEventTask == nil else { return }
        detectorEventTask = Task { [weak self, detector] in
            for await event in detector.events {
                guard let self else { break }
                await self.handleBargeInEvent(event)
            }
        }
    }

    private func handleBargeInEvent(_ event: BargeInEvent) async {
        eventContinuation.yield(.bargeIn(event))
        if event.kind == .confirmed && config.bargeIn == .full {
            // Full policy: a genuine barge-in stops narration and hands the
            // floor to the user. commandOnly leaves the reaction to the module.
            await stopSpeaking()
        }
    }

    // MARK: Speaking

    func speak(_ utterance: Utterance) async throws {
        guard !released else { throw VoiceSessionError.sessionReleased }
        guard !isSpeaking else { throw VoiceSessionError.alreadySpeaking }

        guard let tts = await resolvedTTS() else {
            throw VoiceSessionError.synthesisFailed("No TTS provider available")
        }

        // Resolve the audio source: explicit pre-rendered audio wins, then
        // the local prefetch cache, then live synthesis.
        var cached: CachedSegmentAudio?
        if let pre = utterance.preRendered {
            do {
                cached = try pre.toCachedSegmentAudio()
            } catch {
                Self.logger.warning("Pre-rendered audio unavailable, synthesizing: \(error)")
            }
        }
        if cached == nil {
            cached = prefetched[utterance.text]
        }

        isSpeaking = true
        await armBargeIn()
        defer {
            isSpeaking = false
        }

        do {
            if tts is AppleTTSService && cached == nil {
                // Apple TTS plays through AVSpeechSynthesizer internally
                // (system-managed audio); drain the stream until speech ends.
                let stream = try await tts.synthesize(text: utterance.text)
                for await _ in stream {
                    if Task.isCancelled { break }
                }
            } else {
                try await playThroughOrchestrator(
                    text: utterance.text,
                    cached: cached,
                    tts: tts
                )
            }
            await disarmBargeIn()
        } catch {
            await disarmBargeIn()
            throw error
        }
    }

    /// Play one segment via the shared AudioPlaybackOrchestrator. The
    /// orchestrator bounds synthesis (timeout, empty-stream detection), so a
    /// stalled or silent TTS engine surfaces here as a thrown error.
    private func playThroughOrchestrator(
        text: String,
        cached: CachedSegmentAudio?,
        tts: any TTSService
    ) async throws {
        guard let engine = await engineProvider() else {
            throw VoiceSessionError.audioEngineUnavailable
        }
        await subscribeToAudioStreamIfNeeded(engine)

        let orch = AudioPlaybackOrchestrator(
            config: .knowledgeBowl,
            ttsService: tts,
            audioEngine: engine
        )
        orchestrator = orch
        defer { orchestrator = nil }

        await orch.loadSegments([VoiceUtteranceSegment(text: text, cachedAudio: cached)])
        await orch.startPlayback(from: 0)

        while true {
            if Task.isCancelled {
                await orch.stopPlayback()
                throw CancellationError()
            }
            let state = await orch.state
            switch state {
            case .playing, .buffering:
                try? await Task.sleep(for: .milliseconds(50))
            case .error(let message):
                throw VoiceSessionError.synthesisFailed(message)
            case .idle, .paused, .completed:
                return
            }
        }
    }

    func stopSpeaking() async {
        if let orch = orchestrator {
            await orch.stopPlayback()
        }
        await disarmBargeIn()
    }

    // MARK: Prefetch

    func prefetch(_ utterances: [Utterance]) async {
        guard !released, let tts = await resolvedTTS() else { return }
        // Apple TTS plays via the system synthesizer and emits no PCM,
        // so there is nothing to cache.
        guard !(tts is AppleTTSService) else { return }

        for utterance in utterances {
            guard utterance.preRendered == nil,
                  prefetched[utterance.text] == nil else { continue }
            guard let audio = await synthesizeToCachedAudio(utterance.text, tts: tts) else { continue }
            storePrefetched(audio, for: utterance.text)
        }
    }

    /// Synthesize text into a single cached-audio blob, bounded in time so a
    /// stalled engine cannot hang prefetch. Returns nil on failure or when
    /// the stream format is not raw PCM.
    private func synthesizeToCachedAudio(_ text: String, tts: any TTSService) async -> CachedSegmentAudio? {
        do {
            let stream = try await tts.synthesize(text: text)
            let chunks = try await withThrowingTaskGroup(of: [TTSAudioChunk]?.self) { group -> [TTSAudioChunk] in
                group.addTask {
                    var collected: [TTSAudioChunk] = []
                    for await chunk in stream { collected.append(chunk) }
                    return collected
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(10))
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let chunks = first else {
                    throw VoiceSessionError.synthesisFailed("Prefetch synthesis timed out")
                }
                return chunks
            }

            var data = Data()
            var sampleRate: Double?
            var channels: UInt32 = 1
            for chunk in chunks {
                guard case .pcmFloat32(let rate, let chunkChannels) = chunk.format else { return nil }
                if let sampleRate, sampleRate != rate { return nil }
                sampleRate = rate
                channels = chunkChannels
                data.append(chunk.audioData)
            }
            guard let sampleRate, !data.isEmpty else { return nil }
            return CachedSegmentAudio(audioData: data, sampleRate: sampleRate, channels: channels)
        } catch {
            Self.logger.warning("Prefetch synthesis failed: \(error)")
            return nil
        }
    }

    private func storePrefetched(_ audio: CachedSegmentAudio, for text: String) {
        prefetched[text] = audio
        prefetchOrder.append(text)
        while prefetchOrder.count > prefetchCapacity {
            let evicted = prefetchOrder.removeFirst()
            prefetched.removeValue(forKey: evicted)
        }
    }

    // MARK: Listening

    func listen(expecting expectation: ListenExpectation) async throws -> UtteranceResult {
        guard !released else { throw VoiceSessionError.sessionReleased }
        guard !isListening else { throw VoiceSessionError.alreadyListening }

        guard let engine = await engineProvider() else {
            throw VoiceSessionError.audioEngineUnavailable
        }
        await subscribeToAudioStreamIfNeeded(engine)

        guard let format = await engine.format,
              let formatCopy = AVAudioFormat(
                commonFormat: format.commonFormat,
                sampleRate: format.sampleRate,
                channels: format.channelCount,
                interleaved: format.isInterleaved
              ) else {
            throw VoiceSessionError.audioEngineUnavailable
        }

        let stt = sttService ?? sttFactory()
        sttService = stt
        // Ensure any previous stream has fully stopped (teardown stops the
        // provider asynchronously; back-to-back listens must not race it).
        if await stt.isStreaming {
            try? await stt.stopStreaming()
        }
        let sttStream = try await stt.startStreaming(audioFormat: formatCopy)

        isListening = true
        currentTranscript = ""
        lastConfidence = 0
        lastCommandTranscript = ""
        var endpointer = UtteranceEndpointer(
            policy: config.endpointing,
            answerTimeout: config.answerTimeout.map { TimeInterval($0.components.seconds) }
        )
        endpointer.begin(at: Date().timeIntervalSince1970)
        self.endpointer = endpointer

        sttStreamTask = Task { [weak self] in
            for await result in sttStream {
                guard let self else { break }
                await self.handleSTTResult(result)
            }
        }

        Self.logger.info("Listening started (expecting: \(expectation.rawValue))")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.listenContinuation = continuation
            }
        } onCancel: {
            Task { await self.cancelListening() }
        }
    }

    private func handleSTTResult(_ result: STTResult) async {
        guard isListening else { return }
        currentTranscript = result.transcript
        if result.confidence > 0 {
            lastConfidence = result.confidence
        }
        eventContinuation.yield(.partialTranscript(result.transcript))
        await recognizeRegisteredCommands(in: result.transcript)

        if result.isFinal && result.isEndOfUtterance && !result.transcript.isEmpty {
            finishListening(.sttFinalized)
        }
    }

    private func recognizeRegisteredCommands(in transcript: String) async {
        guard let state = activeVoiceState,
              let vocabulary = vocabularies[state],
              !vocabulary.commands.isEmpty,
              !transcript.isEmpty,
              transcript != lastCommandTranscript else { return }

        let words = transcript.lowercased().split(separator: " ")
        let tail = words.suffix(3).joined(separator: " ")
        if let match = await commandRecognizer.recognize(
            transcript: tail,
            validCommands: vocabulary.commands
        ), match.shouldExecute {
            lastCommandTranscript = transcript
            eventContinuation.yield(.commandRecognized(match.command, confidence: match.confidence))
        }
    }

    /// End the in-progress listen with a result. Idempotent: only the first
    /// finish wins (the endpointer and the STT final can race).
    private func finishListening(_ reason: UtteranceResult.EndReason) {
        guard let continuation = listenContinuation else { return }
        listenContinuation = nil
        let result = UtteranceResult(
            transcript: currentTranscript,
            confidence: lastConfidence,
            endedBy: reason
        )
        Self.logger.info("Listening finished (\(reason.rawValue), \(result.transcript.count) chars)")
        teardownListening()
        continuation.resume(returning: result)
    }

    private func cancelListening() {
        guard let continuation = listenContinuation else { return }
        listenContinuation = nil
        teardownListening()
        continuation.resume(throwing: CancellationError())
    }

    private func teardownListening() {
        isListening = false
        endpointer = nil
        sttStreamTask?.cancel()
        sttStreamTask = nil
        let stt = sttService
        Task {
            try? await stt?.stopStreaming()
        }
    }

    // MARK: Commands

    func registerCommands(_ vocabulary: CommandVocabulary, for state: ModuleVoiceState) {
        vocabularies[state] = vocabulary
    }

    func setActiveVoiceState(_ state: ModuleVoiceState) {
        activeVoiceState = state
    }

    // MARK: Cues

    func playCue(_ cue: AudioCue) async {
        let tone: FeedbackTone
        switch cue {
        case .correct: tone = .correct
        case .incorrect: tone = .incorrect
        case .commandRecognized: tone = .commandRecognized
        case .commandInvalid: tone = .commandInvalid
        case .countdownTick: tone = .countdownTick
        case .attention: tone = .attention
        }
        await MainActor.run { [cues] in
            cues.playTone(tone)
        }
    }

    // MARK: Release

    func release() async {
        guard !released else { return }
        released = true

        // Fail any in-flight listen with a typed error.
        if let continuation = listenContinuation {
            listenContinuation = nil
            teardownListening()
            continuation.resume(throwing: VoiceSessionError.sessionReleased)
        }

        await stopSpeaking()

        audioSubscription?.cancel()
        audioSubscription = nil
        subscribedEngineID = nil

        detectorEventTask?.cancel()
        detectorEventTask = nil
        await detector.finish()

        eventContinuation.finish()

        ttsService = nil
        sttService = nil
        prefetched.removeAll()
        prefetchOrder.removeAll()

        await ownership.release(holder)
        await AudioEngineCache.shared.scheduleRelease()
        Self.logger.info("Voice session released")
    }

    // MARK: Audio Routing

    /// Subscribe once per engine instance: VAD frames feed the barge-in
    /// detector (while speaking) and the endpointer + STT (while listening).
    private func subscribeToAudioStreamIfNeeded(_ engine: AudioEngine) async {
        let engineID = ObjectIdentifier(engine)
        guard subscribedEngineID != engineID else { return }

        audioSubscription?.cancel()
        subscribedEngineID = engineID
        audioSubscription = engine.audioStream
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (buffer, vadResult) in
                guard let self else { return }
                Task {
                    await self.processAudioFrame(vadResult, buffer: buffer)
                }
            }
    }

    private func processAudioFrame(_ vadResult: VADResult, buffer: sending AVAudioPCMBuffer) async {
        if isListening {
            do {
                try await sttService?.sendAudio(buffer)
            } catch {
                Self.logger.error("Failed to send audio to STT: \(error)")
            }
        }
        await ingest(vadResult)
    }

    /// Route one VAD frame to the endpointer, detector, and event stream.
    /// Internal (not private) so tests can inject deterministic frames, the
    /// same seam the barge-in measurement harness uses.
    func ingest(_ vadResult: VADResult) async {
        // VAD state transitions.
        if lastVadIsSpeech != vadResult.isSpeech {
            lastVadIsSpeech = vadResult.isSpeech
            eventContinuation.yield(.vadState(isSpeech: vadResult.isSpeech))
        }

        // Endpointing while listening.
        if isListening, var activeEndpointer = endpointer {
            let reason = activeEndpointer.process(vadResult)
            endpointer = activeEndpointer
            if let reason {
                finishListening(reason)
            }
        }

        // Barge-in detection. The canonical detector owns the decision and
        // is a no-op unless armed (armed only while this session speaks).
        if config.bargeIn != .off {
            await detector.process(vadResult)
        }
    }

    /// Arm the canonical detector while narrating. Internal for tests.
    func armBargeIn() async {
        guard config.bargeIn != .off else { return }
        await detector.arm()
    }

    /// Disarm the detector when narration ends. Internal for tests.
    func disarmBargeIn() async {
        await detector.disarm()
    }

    // MARK: Helpers

    private func resolvedTTS() async -> (any TTSService)? {
        if let ttsService { return ttsService }
        let service = await ttsResolver()
        ttsService = service
        return service
    }
}

// MARK: - Segment

/// Single-utterance playback segment for the shared orchestrator.
private struct VoiceUtteranceSegment: PlayableSegment {
    let segmentIndex: Int = 0
    let segmentText: String
    let cachedAudio: CachedSegmentAudio?

    init(text: String, cachedAudio: CachedSegmentAudio? = nil) {
        self.segmentText = text
        self.cachedAudio = cachedAudio
    }
}
