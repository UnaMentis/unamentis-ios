//
//  KBOnDeviceTTS.swift
//  UnaMentis
//
//  TTS adapter for Knowledge Bowl. Routes playback through the unified
//  AudioPlaybackOrchestrator + AudioEngine (the single voice pipeline),
//  respecting the user's configured on-device TTS provider.
//

import AVFoundation
import Logging

// MARK: - Knowledge Bowl TTS Adapter

/// Thin TTS adapter for Knowledge Bowl. PCM providers (Pocket TTS, the canonical
/// on-device KB voice) play through the shared AudioPlaybackOrchestrator and
/// AudioEngine. Apple TTS plays through its own AVSpeechSynthesizer path, which is
/// managed by the system. This type owns no audio engine, audio player, or audio
/// session of its own.
actor KBOnDeviceTTS {
    // MARK: - State

    private(set) var isSpeaking = false
    private(set) var isPaused = false
    private(set) var progress: Float = 0

    // MARK: - Private State

    private var ttsService: (any TTSService)?
    private var orchestrator: AudioPlaybackOrchestrator?
    private let logger = Logger(label: "com.unamentis.kb.tts")

    // MARK: - Configuration

    /// Voice configuration for questions. Retained for API compatibility; pacing is
    /// applied by the resolved TTS provider.
    struct VoiceConfig: Sendable {
        var language: String = "en-US"
        var rate: Float = AVSpeechUtteranceDefaultSpeechRate
        var pitchMultiplier: Float = 1.0
        var volume: Float = 1.0
        var preUtteranceDelay: TimeInterval = 0
        var postUtteranceDelay: TimeInterval = 0

        /// Standard reading pace for questions
        static let questionPace = VoiceConfig(
            rate: AVSpeechUtteranceDefaultSpeechRate * 0.9,
            pitchMultiplier: 1.0
        )

        /// Slower pace for complex questions
        static let slowPace = VoiceConfig(
            rate: AVSpeechUtteranceDefaultSpeechRate * 0.75,
            pitchMultiplier: 1.0
        )

        /// Faster pace for experienced users
        static let fastPace = VoiceConfig(
            rate: AVSpeechUtteranceDefaultSpeechRate * 1.1,
            pitchMultiplier: 1.0
        )
    }

    // MARK: - Initialization

    init() {
        logger.info("KBOnDeviceTTS initialized (unified pipeline adapter)")
    }

    // MARK: - Public API

    /// Pre-warm the TTS engine and the shared audio engine to avoid cold-start latency.
    /// Call during session preparation, before the first speak() call.
    func prewarm() async {
        await ensureServiceConfigured()

        // For Pocket TTS, ensure the on-device model is loaded.
        if let kyutaiService = ttsService as? KyutaiPocketTTSService {
            do {
                try await kyutaiService.ensureLoaded()
            } catch {
                logger.error("Failed to prewarm Pocket TTS engine: \(error.localizedDescription)")
            }
        }

        // Warm the shared audio engine so the first question reads without delay.
        _ = await AudioEngineCache.shared.getEngine()
    }

    /// Speak text with default configuration.
    func speak(_ text: String) async {
        await speak(text, config: .questionPace)
    }

    /// Speak text with custom configuration.
    func speak(_ text: String, config: VoiceConfig) async {
        await ensureServiceConfigured()

        guard let service = ttsService else {
            logger.error("Failed to configure TTS service")
            return
        }

        isSpeaking = true
        isPaused = false
        progress = 0.1

        do {
            if service is AppleTTSService {
                // Apple TTS plays through AVSpeechSynthesizer internally (system-managed
                // audio). Drain the stream and track progress; the engine is not used.
                let audioStream = try await service.synthesize(text: text)
                for try await chunk in audioStream {
                    if chunk.isFirst {
                        progress = 0.3
                        await TTFAInstrumentation.shared.markTTSFirstChunk()
                    }
                }
            } else {
                // PCM providers (Pocket TTS, etc.) play through the unified
                // AudioPlaybackOrchestrator + AudioEngine. The orchestrator emits the
                // TTFA markTTSFirstChunk instrumentation internally.
                guard let engine = await AudioEngineCache.shared.getEngine() else {
                    logger.error("Audio engine unavailable for TTS playback")
                    isSpeaking = false
                    progress = 0
                    return
                }

                let orch = AudioPlaybackOrchestrator(
                    config: .knowledgeBowl,
                    ttsService: service,
                    audioEngine: engine
                )
                orchestrator = orch
                progress = 0.5

                await orch.loadSegments([KBPlayableSegment(text: text)])
                await orch.startPlayback(from: 0)

                // Wait for the single fire-and-forget segment to finish.
                while true {
                    let state = await orch.state
                    if state == .playing || state == .buffering {
                        try? await Task.sleep(for: .milliseconds(50))
                    } else {
                        break
                    }
                }

                orchestrator = nil
                await AudioEngineCache.shared.scheduleRelease()
            }

            isSpeaking = false
            progress = 1.0
        } catch {
            logger.error("TTS synthesis failed: \(error.localizedDescription)")
            orchestrator = nil
            isSpeaking = false
            progress = 0
        }
    }

    /// Speak a Knowledge Bowl question.
    func speakQuestion(_ question: KBQuestion, config: VoiceConfig = .questionPace) async {
        await TTFAInstrumentation.shared.markActivation(.kbOral)
        logger.info("[KB-TTS] Speaking question: \(question.text.prefix(50))...")
        await speak(question.text, config: config)
    }

    /// Pause speech. Not all providers support pause; the flag is preserved for the UI.
    func pause() {
        guard isSpeaking, !isPaused else { return }
        isPaused = true
        logger.debug("Speech paused")
    }

    /// Resume speech.
    func resume() {
        guard isPaused else { return }
        isPaused = false
        logger.debug("Speech resumed")
    }

    /// Stop speech and release the shared engine after the inactivity window.
    func stop() async {
        if let orch = orchestrator {
            await orch.stopPlayback()
        }
        orchestrator = nil

        if let service = ttsService {
            try? await service.flush()
        }

        isSpeaking = false
        isPaused = false
        progress = 0
        await AudioEngineCache.shared.scheduleRelease()
        logger.debug("Speech stopped")
    }

    // MARK: - Private Helpers

    /// Resolve and configure the TTS service based on user settings.
    /// Knowledge Bowl is an offline-capable activity, so it uses on-device providers:
    /// Pocket TTS (preferred, real PCM through the unified engine) or Apple TTS.
    /// Cloud and self-hosted providers are mapped to Pocket TTS to avoid a network
    /// dependency during a timed competition.
    private func ensureServiceConfigured() async {
        if ttsService != nil { return }

        let raw = UserDefaults.standard.string(forKey: "ttsProvider")
        let provider = raw.flatMap { TTSProvider(rawValue: $0) } ?? .pocketTTS
        logger.info("Knowledge Bowl using TTS provider: \(provider.rawValue)")

        switch provider {
        case .appleTTS:
            ttsService = AppleTTSService()
        case .pocketTTS:
            ttsService = KyutaiPocketTTSService(config: .lowLatency)
        default:
            // Cloud and self-hosted providers are not used for offline KB practice.
            logger.warning("\(provider.rawValue) not used for Knowledge Bowl; using on-device Pocket TTS")
            ttsService = KyutaiPocketTTSService(config: .lowLatency)
        }

        if let service = ttsService {
            await service.configure(TTSVoiceConfig(voiceId: "default", rate: 1.0))
        }
    }

    // MARK: - Available Voices

    /// Get available voices for a language.
    static func availableVoices(for language: String = "en-US") -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language.prefix(2)) }
    }

    /// Get the best quality voice for a language.
    static func bestVoice(for language: String = "en-US") -> AVSpeechSynthesisVoice? {
        let voices = availableVoices(for: language)
        if let enhanced = voices.first(where: { $0.quality == .enhanced }) {
            return enhanced
        }
        return AVSpeechSynthesisVoice(language: language)
    }
}

// MARK: - KB Playable Segment

/// A single text segment for Knowledge Bowl TTS playback via AudioPlaybackOrchestrator.
/// Optionally carries pre-cached audio (skips synthesis).
private struct KBPlayableSegment: PlayableSegment {
    let segmentIndex: Int
    let segmentText: String
    let cachedAudio: CachedSegmentAudio?

    init(text: String, cachedAudio: CachedSegmentAudio? = nil) {
        self.segmentIndex = 0
        self.segmentText = text
        self.cachedAudio = cachedAudio
    }
}

// MARK: - Preview Support

#if DEBUG
extension KBOnDeviceTTS {
    /// Create a TTS instance for previews.
    static func preview() -> KBOnDeviceTTS {
        KBOnDeviceTTS()
    }
}
#endif
