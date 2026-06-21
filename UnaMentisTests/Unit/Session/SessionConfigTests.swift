// UnaMentis - Session Configuration Tests
// Exercises the value types that govern a SessionManager turn: SessionConfig,
// TTSPlaybackConfig, the TTSPlaybackPreset mapping, the SessionState machine
// properties, and the SessionError descriptions. These are pure value types
// with no external dependencies, so the tests are fully deterministic.

import XCTest
@testable import UnaMentis

final class SessionConfigTests: XCTestCase {

    // MARK: - SessionConfig Defaults

    func testDefaultConfig_coreFlags() {
        let config = SessionConfig.default

        XCTAssertTrue(config.enableCostTracking)
        XCTAssertTrue(config.enableInterruptions)
        XCTAssertEqual(config.maxDuration, 0, "0 means unlimited; longevity is governed by environmental monitoring")
        XCTAssertFalse(config.systemPrompt.isEmpty, "the default config ships a non-empty system prompt")
    }

    func testDefaultConfig_turnTuning() {
        let config = SessionConfig.default

        XCTAssertEqual(config.silenceThreshold, 1.5, accuracy: 0.0001,
                       "default silence threshold is 1.5s")
        XCTAssertEqual(config.bargeInConfirmationMs, 600,
                       "default barge-in confirmation window is 600ms")
    }

    func testInit_defaultsMatchDocumentedValues() {
        // The memberwise init should produce the same turn-tuning defaults as
        // the .default preset when no overrides are given.
        let config = SessionConfig()

        XCTAssertEqual(config.silenceThreshold, 1.5, accuracy: 0.0001)
        XCTAssertEqual(config.bargeInConfirmationMs, 600)
        XCTAssertTrue(config.enableCostTracking)
        XCTAssertTrue(config.enableInterruptions)
        XCTAssertEqual(config.maxDuration, 0)
    }

    // MARK: - SessionConfig Codable Round-Trip

    func testConfigCodable_preservesAllFields() throws {
        let original = SessionConfig(
            audio: .lowLatency,
            llm: .costOptimized,
            voice: .default,
            systemPrompt: "Custom learning prompt",
            enableCostTracking: false,
            maxDuration: 1800,
            enableInterruptions: false,
            ttsPlayback: .conservative,
            silenceThreshold: 2.0,
            bargeInConfirmationMs: 450
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionConfig.self, from: data)

        XCTAssertEqual(decoded.systemPrompt, "Custom learning prompt")
        XCTAssertFalse(decoded.enableCostTracking)
        XCTAssertEqual(decoded.maxDuration, 1800)
        XCTAssertFalse(decoded.enableInterruptions)
        XCTAssertEqual(decoded.silenceThreshold, 2.0, accuracy: 0.0001)
        XCTAssertEqual(decoded.bargeInConfirmationMs, 450)
    }

    func testConfigCodable_preservesNestedAudioAndLLM() throws {
        let original = SessionConfig(
            audio: .lowLatency,
            llm: .highQuality
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionConfig.self, from: data)

        // Nested audio config survives the round-trip.
        XCTAssertEqual(decoded.audio.sampleRate, AudioEngineConfig.lowLatency.sampleRate)
        XCTAssertEqual(decoded.audio.bargeInThreshold, AudioEngineConfig.lowLatency.bargeInThreshold)
        // Nested LLM config survives the round-trip.
        XCTAssertEqual(decoded.llm.model, LLMConfig.highQuality.model)
        XCTAssertEqual(decoded.llm.maxTokens, LLMConfig.highQuality.maxTokens)
    }

    func testConfigCodable_preservesNestedTTSPlayback() throws {
        let original = SessionConfig(ttsPlayback: .lowLatency)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionConfig.self, from: data)

        XCTAssertEqual(decoded.ttsPlayback.prefetchQueueDepth, TTSPlaybackConfig.lowLatency.prefetchQueueDepth)
        XCTAssertEqual(decoded.ttsPlayback.scheduledBufferCount, TTSPlaybackConfig.lowLatency.scheduledBufferCount)
        XCTAssertEqual(decoded.ttsPlayback.prefetchLookaheadSeconds,
                       TTSPlaybackConfig.lowLatency.prefetchLookaheadSeconds, accuracy: 0.0001)
    }

    // MARK: - TTSPlaybackConfig Presets

    func testTTSPlaybackDefault_enablesPrefetchAndMultiBuffer() {
        let config = TTSPlaybackConfig.default

        XCTAssertTrue(config.enablePrefetch)
        XCTAssertTrue(config.enableMultiBufferScheduling)
        XCTAssertEqual(config.prefetchLookaheadSeconds, 1.5, accuracy: 0.0001)
        XCTAssertEqual(config.prefetchQueueDepth, 1)
        XCTAssertEqual(config.interSentenceSilenceMs, 0, "default flow has no inter-sentence gap")
        XCTAssertEqual(config.scheduledBufferCount, 2)
    }

    func testTTSPlaybackLowLatency_isMoreAggressiveThanDefault() {
        let low = TTSPlaybackConfig.lowLatency
        let standard = TTSPlaybackConfig.default

        XCTAssertGreaterThan(low.prefetchLookaheadSeconds, standard.prefetchLookaheadSeconds,
                             "low latency looks further ahead")
        XCTAssertGreaterThan(low.prefetchQueueDepth, standard.prefetchQueueDepth,
                             "low latency prefetches a deeper queue")
        XCTAssertGreaterThan(low.scheduledBufferCount, standard.scheduledBufferCount,
                             "low latency keeps more buffers scheduled")
        XCTAssertTrue(low.enablePrefetch)
        XCTAssertTrue(low.enableMultiBufferScheduling)
    }

    func testTTSPlaybackConservative_addsGapAndDisablesMultiBuffer() {
        let config = TTSPlaybackConfig.conservative

        XCTAssertTrue(config.enablePrefetch, "conservative still prefetches, just less aggressively")
        XCTAssertFalse(config.enableMultiBufferScheduling, "conservative disables multi-buffer scheduling")
        XCTAssertEqual(config.interSentenceSilenceMs, 100, "conservative inserts a small inter-sentence gap")
        XCTAssertEqual(config.scheduledBufferCount, 1)
    }

    func testTTSPlaybackDisabled_turnsEverythingOff() {
        let config = TTSPlaybackConfig.disabled

        XCTAssertFalse(config.enablePrefetch)
        XCTAssertFalse(config.enableMultiBufferScheduling)
        XCTAssertEqual(config.prefetchQueueDepth, 0)
        XCTAssertEqual(config.prefetchLookaheadSeconds, 0, accuracy: 0.0001)
        XCTAssertEqual(config.scheduledBufferCount, 1, "even disabled keeps a single buffer")
    }

    func testTTSPlaybackConfig_codableRoundTrip() throws {
        let original = TTSPlaybackConfig(
            enablePrefetch: false,
            prefetchLookaheadSeconds: 3.3,
            prefetchQueueDepth: 2,
            interSentenceSilenceMs: 75,
            enableMultiBufferScheduling: true,
            scheduledBufferCount: 4
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TTSPlaybackConfig.self, from: data)

        XCTAssertEqual(decoded.enablePrefetch, false)
        XCTAssertEqual(decoded.prefetchLookaheadSeconds, 3.3, accuracy: 0.0001)
        XCTAssertEqual(decoded.prefetchQueueDepth, 2)
        XCTAssertEqual(decoded.interSentenceSilenceMs, 75)
        XCTAssertEqual(decoded.enableMultiBufferScheduling, true)
        XCTAssertEqual(decoded.scheduledBufferCount, 4)
    }

    // MARK: - TTSPlaybackPreset Mapping

    func testPreset_namedPresetsMapToTheirConfigs() {
        XCTAssertEqual(TTSPlaybackPreset.default.config?.prefetchQueueDepth,
                       TTSPlaybackConfig.default.prefetchQueueDepth)
        XCTAssertEqual(TTSPlaybackPreset.lowLatency.config?.scheduledBufferCount,
                       TTSPlaybackConfig.lowLatency.scheduledBufferCount)
        XCTAssertEqual(TTSPlaybackPreset.conservative.config?.interSentenceSilenceMs,
                       TTSPlaybackConfig.conservative.interSentenceSilenceMs)
        XCTAssertEqual(TTSPlaybackPreset.disabled.config?.enablePrefetch,
                       TTSPlaybackConfig.disabled.enablePrefetch)
    }

    func testPreset_customMapsToNilConfig() {
        XCTAssertNil(TTSPlaybackPreset.custom.config,
                     "custom means use the individual settings, so it has no canned config")
    }

    func testPreset_allCasesAreCovered() {
        // Every non-custom preset must resolve to a concrete config; custom is
        // the only nil. This guards against adding a preset without wiring it.
        for preset in TTSPlaybackPreset.allCases {
            if preset == .custom {
                XCTAssertNil(preset.config)
            } else {
                XCTAssertNotNil(preset.config, "preset \(preset.rawValue) must resolve to a config")
            }
        }
    }

    func testPreset_rawValuesAreStableForPersistence() {
        // Raw values are persisted in settings, so they must not drift.
        XCTAssertEqual(TTSPlaybackPreset.default.rawValue, "Default")
        XCTAssertEqual(TTSPlaybackPreset.lowLatency.rawValue, "Low Latency")
        XCTAssertEqual(TTSPlaybackPreset.conservative.rawValue, "Conservative")
        XCTAssertEqual(TTSPlaybackPreset.disabled.rawValue, "Disabled")
        XCTAssertEqual(TTSPlaybackPreset.custom.rawValue, "Custom")
    }

    // MARK: - SessionState Machine Properties

    func testSessionState_activeStates() {
        XCTAssertTrue(SessionState.userSpeaking.isActive)
        XCTAssertTrue(SessionState.aiThinking.isActive)
        XCTAssertTrue(SessionState.aiSpeaking.isActive)
        XCTAssertTrue(SessionState.interrupted.isActive)
        XCTAssertTrue(SessionState.processingUserUtterance.isActive)
        XCTAssertTrue(SessionState.paused.isActive, "paused is a frozen-but-active state")
    }

    func testSessionState_inactiveStates() {
        XCTAssertFalse(SessionState.idle.isActive)
        XCTAssertFalse(SessionState.error.isActive)
    }

    func testSessionState_isPausedOnlyForPaused() {
        XCTAssertTrue(SessionState.paused.isPaused)
        for state in [SessionState.idle, .userSpeaking, .aiThinking, .aiSpeaking,
                      .interrupted, .processingUserUtterance, .error] {
            XCTAssertFalse(state.isPaused, "\(state.rawValue) must not report isPaused")
        }
    }

    func testSessionState_rawValues() {
        XCTAssertEqual(SessionState.idle.rawValue, "Idle")
        XCTAssertEqual(SessionState.userSpeaking.rawValue, "User Speaking")
        XCTAssertEqual(SessionState.aiThinking.rawValue, "AI Thinking")
        XCTAssertEqual(SessionState.aiSpeaking.rawValue, "AI Speaking")
        XCTAssertEqual(SessionState.interrupted.rawValue, "Interrupted")
        XCTAssertEqual(SessionState.paused.rawValue, "Paused")
        XCTAssertEqual(SessionState.processingUserUtterance.rawValue, "Processing Utterance")
        XCTAssertEqual(SessionState.error.rawValue, "Error")
    }

    func testSessionState_roundTripsThroughRawValue() {
        for state in [SessionState.idle, .userSpeaking, .aiThinking, .aiSpeaking,
                      .interrupted, .paused, .processingUserUtterance, .error] {
            XCTAssertEqual(SessionState(rawValue: state.rawValue), state,
                           "\(state.rawValue) must reconstruct from its raw value")
        }
    }

    // MARK: - SessionError Descriptions

    func testSessionError_descriptions() {
        XCTAssertEqual(SessionError.servicesNotConfigured.errorDescription,
                       "Required services not configured")
        XCTAssertEqual(SessionError.sessionAlreadyActive.errorDescription,
                       "Session is already active")
        XCTAssertEqual(SessionError.sessionNotActive.errorDescription,
                       "No active session")
        XCTAssertEqual(SessionError.maintenanceMode.errorDescription,
                       "System is in maintenance mode. Please try again later.")
    }
}
