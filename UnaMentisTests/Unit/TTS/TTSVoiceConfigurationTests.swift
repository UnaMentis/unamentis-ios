// UnaMentis - TTSVoiceConfigurationTests
// Unit tests for voice configuration and voice/format selection across the
// network-backed TTS providers.
//
// These cover the configuration surface that maps user intent onto provider
// requests: which voice id a service reports, how reconfiguration overwrites
// state, default voice catalogs, and the self-hosted factory wiring (URLs,
// sample rates, fallbacks). None of these hit the network; we only inspect the
// state the request builder would draw from.

import XCTest
@testable import UnaMentis

final class TTSVoiceConfigurationTests: XCTestCase {

    // MARK: - TTSVoiceConfig defaults

    func testVoiceConfigDefaultValues() {
        let config = TTSVoiceConfig.default
        XCTAssertEqual(config.voiceId, "default")
        XCTAssertEqual(config.rate, 1.0)
        XCTAssertEqual(config.pitch, 0.0)
        XCTAssertEqual(config.volume, 1.0)
        XCTAssertNil(config.stability)
        XCTAssertNil(config.similarityBoost)
    }

    func testVoiceConfigCodableRoundTrip() throws {
        let original = TTSVoiceConfig(
            voiceId: "aura-orion-en",
            rate: 1.2,
            pitch: -0.2,
            volume: 0.8,
            stability: 0.5,
            similarityBoost: 0.75
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TTSVoiceConfig.self, from: data)

        XCTAssertEqual(decoded.voiceId, original.voiceId)
        XCTAssertEqual(decoded.rate, original.rate)
        XCTAssertEqual(decoded.pitch, original.pitch)
        XCTAssertEqual(decoded.volume, original.volume)
        XCTAssertEqual(decoded.stability, original.stability)
        XCTAssertEqual(decoded.similarityBoost, original.similarityBoost)
    }

    // MARK: - Deepgram voice catalog and selection

    func testDeepgramVoiceCatalogIsComplete() {
        // The Aura catalog drives the model query param; missing voices break selection.
        let voices = DeepgramTTSService.AuraVoice.allCases
        XCTAssertEqual(voices.count, 12)
        // Each voice id is the Deepgram model name and must carry the aura-* / -en shape.
        for voice in voices {
            XCTAssertTrue(voice.rawValue.hasPrefix("aura-"), "\(voice) should be an aura model")
            XCTAssertTrue(voice.rawValue.hasSuffix("-en"), "\(voice) should be English")
        }
        XCTAssertEqual(DeepgramTTSService.AuraVoice.asteria.rawValue, "aura-asteria-en")
        XCTAssertEqual(DeepgramTTSService.AuraVoice.zeus.rawValue, "aura-zeus-en")
    }

    func testDeepgramInitialVoiceBecomesVoiceId() async {
        // The chosen voice enum must populate voiceConfig, which is what the
        // request builder serializes into the "model" query item.
        let service = DeepgramTTSService(apiKey: "test_key", voice: .orion)
        let config = await service.voiceConfig
        XCTAssertEqual(config.voiceId, "aura-orion-en")
    }

    func testDeepgramConfigureOverwritesVoice() async {
        let service = DeepgramTTSService(apiKey: "test_key", voice: .asteria)
        await service.configure(TTSVoiceConfig(voiceId: "aura-zeus-en", rate: 1.3))
        let config = await service.voiceConfig
        XCTAssertEqual(config.voiceId, "aura-zeus-en")
        XCTAssertEqual(config.rate, 1.3)
    }

    // MARK: - ElevenLabs voice configuration

    func testElevenLabsDefaultVoiceId() async {
        // Default constructor uses the Jessica voice id.
        let service = ElevenLabsTTSService(apiKey: "test_key")
        let config = await service.voiceConfig
        XCTAssertEqual(config.voiceId, "cjVigY5qzO862AIGy5LS")
    }

    func testElevenLabsCustomVoiceId() async {
        let service = ElevenLabsTTSService(apiKey: "test_key", voiceId: "custom-voice-123")
        let config = await service.voiceConfig
        XCTAssertEqual(config.voiceId, "custom-voice-123")
    }

    func testElevenLabsConfigureReplacesVoice() async {
        let service = ElevenLabsTTSService(apiKey: "test_key")
        await service.configure(TTSVoiceConfig(voiceId: "swapped"))
        let config = await service.voiceConfig
        XCTAssertEqual(config.voiceId, "swapped")
    }

    // MARK: - Self-hosted voice catalog and configuration

    func testSelfHostedDefaultVoiceCatalog() async throws {
        // When the server cannot be queried, listVoices falls back to the
        // OpenAI-compatible default catalog. The base URL is unreachable in
        // the test host, so this exercises the fallback path deterministically.
        let service = SelfHostedTTSService(baseURL: URL(string: "http://127.0.0.1:9")!)
        let voices = try await service.listVoices()
        let ids = Set(voices.map(\.id))
        XCTAssertEqual(ids, ["nova", "alloy", "echo", "fable", "onyx", "shimmer"])
        // The catalog must carry display metadata used by the picker.
        let nova = try XCTUnwrap(voices.first { $0.id == "nova" })
        XCTAssertEqual(nova.name, "Nova")
        XCTAssertEqual(nova.gender, "female")
        XCTAssertEqual(nova.language, "en")
    }

    func testSelfHostedConfigureUpdatesVoice() async {
        let service = SelfHostedTTSService(baseURL: URL(string: "http://localhost:11402")!, voiceId: "nova")
        await service.configure(TTSVoiceConfig(voiceId: "onyx"))
        let config = await service.voiceConfig
        XCTAssertEqual(config.voiceId, "onyx")
    }

    func testSelfHostedServerConfigInitAdoptsConfiguredVoice() async throws {
        // The ServerConfig convenience init must derive a usable base URL from
        // the server's host/port and carry the requested voice into voiceConfig,
        // which is what every request is built against.
        let server = ServerConfig(name: "piper-box", host: "10.0.0.5", port: 11402)
        let service = try XCTUnwrap(SelfHostedTTSService(server: server, voiceId: "shimmer"))
        let config = await service.voiceConfig
        XCTAssertEqual(config.voiceId, "shimmer")
    }

    // MARK: - Self-hosted factory wiring

    func testPiperFactoryUsesPiperRateWithVibeVoiceFallback() async {
        // The Piper factory must select the 22050 Hz Piper output and arrange
        // a VibeVoice fallback, since playback depends on the right sample rate.
        let service = SelfHostedTTSService.piper(voice: "echo")
        let config = await service.voiceConfig
        XCTAssertEqual(config.voiceId, "echo")
        // Free, self-hosted.
        let cost = await service.costPerCharacter
        XCTAssertEqual(cost, 0)
    }

    func testForProviderReturnsNilForNonSelfHostedProvider() {
        // Cloud providers are not buildable by the self-hosted factory.
        XCTAssertNil(SelfHostedTTSService.forProvider(.deepgramAura2, host: "localhost"))
        XCTAssertNil(SelfHostedTTSService.forProvider(.appleTTS, host: "localhost"))
        // Self-hosted providers are buildable.
        XCTAssertNotNil(SelfHostedTTSService.forProvider(.selfHosted, host: "localhost"))
        XCTAssertNotNil(SelfHostedTTSService.forProvider(.vibeVoice, host: "localhost"))
    }
}
