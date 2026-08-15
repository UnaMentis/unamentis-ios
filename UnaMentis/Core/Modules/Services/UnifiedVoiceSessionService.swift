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

        // Construct the session (and with it the claim guard that releases the
        // pipeline if the session is ever dropped without release()) BEFORE any
        // other suspension point, so no await can strand the claim.
        let session = UnifiedVoiceSession(
            config: config,
            holder: holder,
            ownership: ownership,
            engineProvider: engineProvider,
            ttsResolver: ttsResolver,
            sttFactory: sttFactory
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

// MARK: - System Synthesizer TTS

/// A TTS provider that owns its own playback (AVSpeechSynthesizer), emitting no
/// PCM for the orchestrator to route.
///
/// Two things follow, and both used to be missed: playback on this path is not
/// bounded by the orchestrator, and stopping it means telling the PROVIDER to
/// stop, because there is no orchestrator to stop. Expressing that as a
/// capability rather than a concrete-type check also makes both behaviors
/// testable without driving the system synthesizer.
protocol SystemSynthesizerTTS: TTSService {
    /// Stop any in-progress speech immediately.
    func stop() async
}

extension AppleTTSService: SystemSynthesizerTTS {}

// MARK: - Claim Safety Net

/// Releases the voice-pipeline claim if its owning session is deallocated
/// without `release()` (a task cancelled between acquire and the module's
/// defer, a throw before the defer is installed, a view model torn down on a
/// path that misses release). Without this net a dropped session bricks the
/// pipeline for the whole process: every later claim throws `pipelineBusy`.
///
/// Owner-gated release semantics are preserved: it releases exactly the holder
/// its session claimed, so it can never free someone else's claim.
///
/// `@unchecked Sendable`: `armed` is mutated only from the owning session
/// actor, and `deinit` runs when the last (that actor's) reference is gone.
private final class PipelineClaimGuard: @unchecked Sendable {
    private let ownership: VoicePipelineOwnership
    private let holder: VoicePipelineHolder
    private var armed = true

    init(ownership: VoicePipelineOwnership, holder: VoicePipelineHolder) {
        self.ownership = ownership
        self.holder = holder
    }

    /// Called by the session when `release()` ran normally.
    func disarm() {
        armed = false
    }

    deinit {
        guard armed else { return }
        let ownership = self.ownership
        let holder = self.holder
        Task.detached {
            await ownership.release(holder)
            await AudioEngineCache.shared.scheduleRelease()
        }
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

    /// Feedback cues, resolved on first use (MainActor-bound).
    private var cues: VoiceActivityFeedback?

    /// Frees the pipeline claim if this session is dropped without release().
    private let claimGuard: PipelineClaimGuard

    /// The canonical barge-in detector (the ONE detector in the app).
    private let detector: BargeInDetector
    private var detectorEventTask: Task<Void, Never>?

    private var ttsService: (any TTSService)?
    private var sttService: (any STTService)?

    private var released = false
    private var isSpeaking = false
    private var isListening = false

    /// Set while a stop was explicitly requested for the in-progress speak, so
    /// a stopped utterance is not reported as a synthesis failure.
    private var stopRequested = false

    /// Set when the system-synthesizer bound expired, so the failure surfaces
    /// as a typed error once the drained stream ends.
    private var systemSynthesisTimedOut = false

    /// Playback orchestrator for the in-progress speak() call.
    private var orchestrator: AudioPlaybackOrchestrator?

    /// Listening state for the in-progress listen() call.
    private var listenContinuation: CheckedContinuation<UtteranceResult, Error>?
    private var endpointer: UtteranceEndpointer?
    private var currentTranscript = ""
    private var lastConfidence: Float = 0
    private var sttStreamTask: Task<Void, Never>?

    /// True only while a listen is actually capturing (STT stream live and the
    /// endpointer armed). `isListening` is claimed earlier, synchronously, to
    /// close the overlapping-call race; this flag drives audio routing.
    private var captureActive = false

    /// Monotonic listen id, so a watchdog or a teardown from an earlier listen
    /// can never act on a later one.
    private var listenGeneration = 0

    /// Wall-clock backstop for the in-progress listen.
    private var listenWatchdogTask: Task<Void, Never>?

    /// The previous listen's provider teardown. A new listen awaits it, so a
    /// late STT cleanup can never tear down the new recognition request.
    private var sttTeardownTask: Task<Void, Never>?

    /// An end decision that arrived before the continuation was installed.
    private var pendingFinishReason: UtteranceResult.EndReason?

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
        sttFactory: @escaping UnifiedVoiceSessionService.STTFactory
    ) {
        self.config = config
        self.holder = holder
        self.ownership = ownership
        self.engineProvider = engineProvider
        self.ttsResolver = ttsResolver
        self.sttFactory = sttFactory
        self.claimGuard = PipelineClaimGuard(ownership: ownership, holder: holder)

        var detectorConfig = BargeInTuning.detectorConfig()
        detectorConfig.enabled = detectorConfig.enabled && (config.bargeIn != .off)
        self.detector = BargeInDetector(config: detectorConfig)

        // Bounded buffering: a module is free never to iterate `events`
        // (QuizMatchEngine deliberately does not), so an unbounded stream would
        // accumulate every partial transcript for the whole session against the
        // memory budget. Newest-N keeps the recent history a consumer needs.
        (self.eventStream, self.eventContinuation) = AsyncStream<VoiceEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.eventBufferCapacity)
        )
    }

    /// How many undelivered events the session buffers before dropping the
    /// oldest. Large enough for a bursty consumer, bounded for a silent one.
    static let eventBufferCapacity = 64

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
        // Claim the speaking slot SYNCHRONOUSLY, before the first suspension
        // point: the guard above and the claim must not be separated by an
        // await, or two overlapping calls both pass it.
        isSpeaking = true
        stopRequested = false
        systemSynthesisTimedOut = false
        defer {
            isSpeaking = false
            stopRequested = false
        }

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

        await armBargeIn()

        do {
            if let systemTTS = tts as? any SystemSynthesizerTTS, cached == nil {
                try await playThroughSystemSynthesizer(text: utterance.text, tts: systemTTS)
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

    /// Play one utterance through a provider that owns its own playback.
    ///
    /// There is no orchestrator on this path, so the guarantees the
    /// orchestrator provides are reproduced here rather than dropped: the
    /// utterance is bounded in wall-clock time, an empty stream is an error,
    /// and a stop request ends playback immediately. A stalled or silent
    /// synthesizer therefore surfaces as a typed error instead of a silent
    /// hang, which is what commit 7483a6d locked in for the other path.
    private func playThroughSystemSynthesizer(text: String, tts: any SystemSynthesizerTTS) async throws {
        let stream = try await tts.synthesize(text: text)
        let bound = Self.systemSynthesisBound(for: text)

        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(bound))
            guard !Task.isCancelled else { return }
            await self?.expireSystemSynthesis(after: bound)
        }
        defer { watchdog.cancel() }

        var chunkCount = 0
        await withTaskCancellationHandler {
            for await _ in stream {
                chunkCount += 1
            }
        } onCancel: {
            Task { [weak self] in await self?.stopSystemSynthesizer() }
        }

        if systemSynthesisTimedOut {
            systemSynthesisTimedOut = false
            throw VoiceSessionError.synthesisFailed(
                "The system synthesizer did not finish within \(Int(bound)) seconds"
            )
        }
        if Task.isCancelled { throw CancellationError() }
        guard chunkCount > 0 || stopRequested else {
            throw VoiceSessionError.synthesisFailed("The system synthesizer produced no audio")
        }
    }

    /// Wall-clock bound for one system-synthesizer utterance: roughly twice the
    /// estimated spoken duration (about 12 characters per second at the default
    /// rate) plus the orchestrator's buffer timeout as slack.
    static func systemSynthesisBound(for text: String) -> TimeInterval {
        let estimated = Double(text.count) / 12.0
        let slack = PlaybackOrchestratorConfig.knowledgeBowl.bufferTimeoutSeconds
        return min(300, max(5, estimated * 2 + slack))
    }

    /// The bound expired: stop the synthesizer so the drained stream ends, and
    /// mark the utterance failed so speak() throws instead of returning
    /// silently.
    private func expireSystemSynthesis(after bound: TimeInterval) async {
        guard isSpeaking else { return }
        systemSynthesisTimedOut = true
        Self.logger.error("System synthesis exceeded its \(Int(bound))s bound; stopping")
        await stopSystemSynthesizer()
    }

    /// Stop a provider that owns its own playback. This is the ONLY way to stop
    /// that path: it has no orchestrator to stop.
    private func stopSystemSynthesizer() async {
        guard let systemTTS = ttsService as? any SystemSynthesizerTTS else { return }
        stopRequested = true
        await systemTTS.stop()
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
        stopRequested = true
        if let orch = orchestrator {
            await orch.stopPlayback()
        }
        // The system-synthesizer branch (Apple TTS, including the automatic
        // fallback when Pocket TTS models fail to load) never installs an
        // orchestrator, so stopping the orchestrator alone left narration
        // running: barge-in could not stop it, a buzz could not cut off a
        // tossup, and release() handed the pipeline back while the synthesizer
        // was still speaking. Stop the provider itself so stopSpeaking()
        // genuinely stops speech on EVERY path.
        await stopSystemSynthesizer()
        await disarmBargeIn()
    }

    // MARK: Prefetch

    func prefetch(_ utterances: [Utterance]) async {
        guard !released, let tts = await resolvedTTS() else { return }
        // A system synthesizer owns its own playback and emits no PCM, so
        // there is nothing to cache.
        guard !(tts is any SystemSynthesizerTTS) else { return }

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
        // Claim the listening slot SYNCHRONOUSLY, before the first suspension
        // point. Setting it after the awaits below let two overlapping calls
        // both pass the guard; the second overwrote listenContinuation and the
        // first caller hung forever on an orphaned continuation.
        isListening = true
        listenGeneration &+= 1
        let generation = listenGeneration

        do {
            // The previous listen's teardown stops the STT provider
            // asynchronously (Apple Speech sleeps before tearing down), so wait
            // for it here: otherwise that late cleanup lands on THIS listen's
            // recognition request and no results ever arrive.
            if let teardown = sttTeardownTask {
                sttTeardownTask = nil
                await teardown.value
            }

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
            if await stt.isStreaming {
                try? await stt.stopStreaming()
            }
            let sttStream = try await stt.startStreaming(audioFormat: formatCopy)

            currentTranscript = ""
            lastConfidence = 0
            lastCommandTranscript = ""
            pendingFinishReason = nil
            var endpointer = UtteranceEndpointer(
                policy: config.endpointing,
                // Fractional seconds matter: components.seconds alone truncates
                // 2.5 s to 2 and anything under a second to 0, which made the
                // endpointer fire .timeout on the first silent frame.
                answerTimeout: config.answerTimeout?.timeIntervalSeconds
            )
            endpointer.begin(at: Date().timeIntervalSince1970)
            self.endpointer = endpointer
            captureActive = true

            sttStreamTask = Task { [weak self] in
                for await result in sttStream {
                    guard let self else { break }
                    await self.handleSTTResult(result)
                }
            }
            startListenWatchdog(generation: generation)
        } catch {
            // Every throw path releases the claim, so a failed listen leaves
            // the session usable instead of permanently "already listening".
            isListening = false
            captureActive = false
            endpointer = nil
            listenWatchdogTask?.cancel()
            listenWatchdogTask = nil
            throw error
        }

        Self.logger.info("Listening started (expecting: \(expectation.rawValue))")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // The endpointer, the STT stream, a cancellation, or a release
                // can all land before the continuation is installed; honor
                // whichever happened instead of waiting on a dead listen.
                if self.released {
                    continuation.resume(throwing: VoiceSessionError.sessionReleased)
                } else if !self.isListening {
                    continuation.resume(throwing: CancellationError())
                } else if let reason = self.pendingFinishReason {
                    self.pendingFinishReason = nil
                    let result = UtteranceResult(
                        transcript: self.currentTranscript,
                        confidence: self.lastConfidence,
                        endedBy: reason
                    )
                    self.teardownListening()
                    continuation.resume(returning: result)
                } else {
                    self.listenContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelListening() }
        }
    }

    /// Wall-clock backstop for a listen.
    ///
    /// The endpointer is advanced only by VAD frames from the audio engine, so
    /// a stalled audio path (an interruption, a route change, an engine
    /// restart, a dead STT recognition task) would otherwise leave listen()
    /// awaiting forever with `isListening` stuck true. These deadlines honor
    /// `answerTimeout` and `maxUtteranceDuration` in real time, no matter what
    /// the frame delivery does.
    private func startListenWatchdog(generation: Int) {
        let answerTimeout = config.answerTimeout?.timeIntervalSeconds
        let maxDuration = config.endpointing.maxUtteranceDuration
        listenWatchdogTask = Task { [weak self] in
            if let answerTimeout, answerTimeout > 0, answerTimeout.isFinite {
                try? await Task.sleep(for: .seconds(answerTimeout))
                if Task.isCancelled { return }
                let ended = await self?.expireListen(
                    generation: generation, reason: .timeout, onlyIfSilent: true
                )
                if ended == true { return }
            }
            guard maxDuration > 0, maxDuration.isFinite else { return }
            try? await Task.sleep(for: .seconds(maxDuration))
            if Task.isCancelled { return }
            _ = await self?.expireListen(
                generation: generation, reason: .maxUtteranceDuration, onlyIfSilent: false
            )
        }
    }

    /// Finish an in-flight listen from the wall-clock watchdog. Returns true
    /// when this call ended the listen.
    @discardableResult
    private func expireListen(
        generation: Int,
        reason: UtteranceResult.EndReason,
        onlyIfSilent: Bool
    ) -> Bool {
        guard isListening, generation == listenGeneration else { return false }
        if onlyIfSilent, endpointer?.hasDetectedSpeech == true { return false }
        Self.logger.warning(
            "Listen watchdog fired (\(reason.rawValue)): no endpointing decision arrived in time"
        )
        finishListening(reason)
        return true
    }

    private func handleSTTResult(_ result: STTResult) async {
        guard captureActive else { return }
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
    /// finish wins (the endpointer, the STT final, and the watchdog can race).
    private func finishListening(_ reason: UtteranceResult.EndReason) {
        guard isListening else { return }
        guard let continuation = listenContinuation else {
            // The continuation is not installed yet; record the decision so it
            // is honored the moment listen() installs it.
            pendingFinishReason = reason
            return
        }
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
        guard let continuation = listenContinuation else {
            // Cancelled before the continuation landed: drop the claim anyway
            // so the session is not stuck "already listening".
            if isListening { teardownListening() }
            return
        }
        listenContinuation = nil
        teardownListening()
        continuation.resume(throwing: CancellationError())
    }

    private func teardownListening() {
        isListening = false
        captureActive = false
        endpointer = nil
        pendingFinishReason = nil
        listenWatchdogTask?.cancel()
        listenWatchdogTask = nil
        sttStreamTask?.cancel()
        sttStreamTask = nil
        let stt = sttService
        // Cancel rather than stop: stopStreaming waits half a second for final
        // results and then tears down whatever recognition request exists at
        // THAT moment, which is a new listen's request if one started in the
        // meantime. The transcript is already captured, so there is nothing to
        // drain. The handle is kept so the next listen awaits this teardown.
        sttTeardownTask = Task {
            await stt?.cancelStreaming()
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
        let feedback = await resolvedCues()
        await MainActor.run {
            feedback.playTone(tone)
        }
    }

    /// The MainActor-bound feedback object, created on first use so acquire()
    /// has no suspension point between claiming the pipeline and building the
    /// session that owns the claim.
    private func resolvedCues() async -> VoiceActivityFeedback {
        if let cues { return cues }
        let feedback = await MainActor.run { VoiceActivityFeedback() }
        cues = feedback
        return feedback
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
        } else if isListening {
            // Released while a listen was starting up: drop the claim so the
            // starting listen sees the release when it installs.
            teardownListening()
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
        cues = nil
        prefetched.removeAll()
        prefetchOrder.removeAll()

        // The claim is being released the normal way; the safety net must not
        // release it a second time later.
        claimGuard.disarm()
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
        if captureActive {
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
        if captureActive, var activeEndpointer = endpointer {
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

    /// Whether a listen is actively capturing (STT stream live, endpointer
    /// armed). Internal, not private, so tests can wait for capture readiness
    /// before injecting frames, the same seam `ingest` provides.
    var isCapturing: Bool { captureActive }

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

// MARK: - Duration

extension Duration {
    /// The duration in seconds, fractional part included. `components.seconds`
    /// alone truncates (2.5 s becomes 2 s, 800 ms becomes 0), which silently
    /// broke sub-second and fractional answer timeouts.
    var timeIntervalSeconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) * 1e-18
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
