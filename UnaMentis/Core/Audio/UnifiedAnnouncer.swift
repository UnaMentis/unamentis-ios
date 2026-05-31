// UnaMentis - Unified Announcer
//
// A single shared entry point for one-shot spoken announcements (Knowledge Bowl
// drill/rebound questions, voice activity feedback, lecture transitions, barge-in
// responses). It routes playback through the one voice pipeline:
// AudioPlaybackOrchestrator + AudioEngine (via AudioEngineCache), instead of a
// per-call AVAudioPlayer.
//
// Why this exists: several features independently did
//   resolve TTS -> accumulate chunks -> AVAudioPlayer(data:)
// which silently drops audio for raw-PCM providers (Pocket TTS, the default),
// because AVAudioPlayer cannot infer a format from headerless PCM. Funneling
// every announcement through the orchestrator fixes that and keeps audio on the
// single, well-tested pipeline.
//
// Part of Core/Audio

import Foundation
import Logging

/// Shared one-shot announcement player. Use for short spoken phrases that are not
/// part of a multi-segment playback session.
public actor UnifiedAnnouncer {

    /// Shared singleton.
    public static let shared = UnifiedAnnouncer()

    private let logger = Logger(label: "com.unamentis.audio.announcer")

    /// The orchestrator for the in-flight announcement, retained so it can be stopped.
    private var orchestrator: AudioPlaybackOrchestrator?

    private init() {}

    // MARK: - Public API

    /// Speak a one-shot announcement using the user's configured TTS provider.
    /// - Parameters:
    ///   - text: The text to speak.
    ///   - activation: Optional TTFA feature to mark when playback begins.
    public func speak(_ text: String, activation: TTFAFeature? = nil) async {
        await speak(text, service: TTSProvider.resolveConfiguredService(), activation: activation)
    }

    /// Speak a one-shot announcement using a specific TTS service.
    public func speak(_ text: String, service: any TTSService, activation: TTFAFeature? = nil) async {
        guard !text.isEmpty else { return }

        if let activation {
            await TTFAInstrumentation.shared.markActivation(activation)
        }

        // Apple TTS plays through AVSpeechSynthesizer internally (system-managed audio),
        // so it is driven by draining its stream rather than the engine.
        if service is AppleTTSService {
            await playViaAppleTTS(service, text: text)
            return
        }

        // PCM providers (Pocket TTS, etc.) play through the unified
        // AudioPlaybackOrchestrator + AudioEngine.
        guard let engine = await AudioEngineCache.shared.getEngine() else {
            logger.error("Audio engine unavailable for announcement; falling back to Apple TTS")
            await playViaAppleTTS(AppleTTSService(), text: text)
            return
        }

        let orch = AudioPlaybackOrchestrator(
            config: .knowledgeBowl,
            ttsService: service,
            audioEngine: engine
        )
        orchestrator = orch
        await orch.loadSegments([AnnouncementSegment(text: text)])
        await orch.startPlayback(from: 0)

        // Wait for the single fire-and-forget segment to finish.
        while true {
            let state = await orch.state
            switch state {
            case .playing, .buffering:
                try? await Task.sleep(for: .milliseconds(50))
            case .error(let message):
                logger.warning("Announcement playback error, falling back to Apple TTS: \(message)")
                orchestrator = nil
                await AudioEngineCache.shared.scheduleRelease()
                await playViaAppleTTS(AppleTTSService(), text: text)
                return
            default:
                orchestrator = nil
                await AudioEngineCache.shared.scheduleRelease()
                return
            }
        }
    }

    /// Stop the in-flight announcement, if any.
    public func stop() async {
        if let orch = orchestrator {
            await orch.stopPlayback()
        }
        orchestrator = nil
        await AudioEngineCache.shared.scheduleRelease()
    }

    // MARK: - Private

    /// Drain an Apple TTS stream (which plays internally via AVSpeechSynthesizer).
    private func playViaAppleTTS(_ service: any TTSService, text: String) async {
        do {
            let stream = try await service.synthesize(text: text)
            for try await chunk in stream {
                if chunk.isFirst {
                    await TTFAInstrumentation.shared.markTTSFirstChunk()
                }
            }
        } catch {
            logger.error("Apple TTS announcement failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Announcement Segment

/// A single text segment for one-shot announcement playback via AudioPlaybackOrchestrator.
private struct AnnouncementSegment: PlayableSegment {
    let segmentIndex: Int
    let segmentText: String
    let cachedAudio: CachedSegmentAudio?

    init(text: String) {
        self.segmentIndex = 0
        self.segmentText = text
        self.cachedAudio = nil
    }
}
