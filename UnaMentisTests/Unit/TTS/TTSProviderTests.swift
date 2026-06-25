// UnaMentis - TTSProviderTests
// Unit tests for TTSProvider metadata and service-resolution logic.
//
// These tests validate real outcomes of the provider-selection layer:
// which providers need network, which need an API key, their default ports
// and sample rates, on-device vs self-hosted classification, and the
// UserDefaults-driven resolution of a local service. None of this touches
// the network or any model.

import XCTest
@testable import UnaMentis

final class TTSProviderTests: XCTestCase {

    // MARK: - Identifier mapping

    func testIdentifiersAreStableAndUnique() {
        // The short identifier is used for config keys and persistence,
        // so each provider must map to a distinct, known value.
        let expected: [TTSProvider: String] = [
            .deepgramAura2: "deepgram",
            .elevenLabsFlash: "elevenlabs-flash",
            .elevenLabsTurbo: "elevenlabs-turbo",
            .playHT: "playht",
            .appleTTS: "apple",
            .selfHosted: "piper",
            .vibeVoice: "vibevoice",
            .chatterbox: "chatterbox",
            .pocketTTS: "pocket-tts"
        ]

        for (provider, identifier) in expected {
            XCTAssertEqual(provider.identifier, identifier, "identifier for \(provider)")
        }

        // Every case must have a unique identifier.
        let allIdentifiers = TTSProvider.allCases.map(\.identifier)
        XCTAssertEqual(Set(allIdentifiers).count, allIdentifiers.count, "identifiers must be unique")
    }

    // MARK: - Network requirement

    func testOnlyOnDeviceProvidersSkipNetwork() {
        // Apple and Pocket run fully on-device, everything else needs a network.
        XCTAssertFalse(TTSProvider.appleTTS.requiresNetwork)
        XCTAssertFalse(TTSProvider.pocketTTS.requiresNetwork)

        for provider in TTSProvider.allCases where provider != .appleTTS && provider != .pocketTTS {
            XCTAssertTrue(provider.requiresNetwork, "\(provider) should require network")
        }
    }

    // MARK: - API key requirement

    func testApiKeyRequiredOnlyForCloudProviders() {
        // Self-hosted, on-device, and Chatterbox never require an API key.
        let keyFree: Set<TTSProvider> = [.appleTTS, .selfHosted, .vibeVoice, .chatterbox, .pocketTTS]
        for provider in keyFree {
            XCTAssertFalse(provider.requiresAPIKey, "\(provider) should not require an API key")
        }

        // The remaining hosted-cloud providers require a key.
        let keyRequired: Set<TTSProvider> = [.deepgramAura2, .elevenLabsFlash, .elevenLabsTurbo, .playHT]
        for provider in keyRequired {
            XCTAssertTrue(provider.requiresAPIKey, "\(provider) should require an API key")
        }
    }

    // MARK: - Default ports

    func testDefaultPortsForSelfHostedProviders() {
        // The default port drives the auto-config URL for self-hosted servers.
        XCTAssertEqual(TTSProvider.selfHosted.defaultPort, 11402) // Piper
        XCTAssertEqual(TTSProvider.vibeVoice.defaultPort, 8880)
        XCTAssertEqual(TTSProvider.chatterbox.defaultPort, 8004)

        // Cloud and on-device providers do not expose a self-hosted port.
        XCTAssertEqual(TTSProvider.deepgramAura2.defaultPort, 0)
        XCTAssertEqual(TTSProvider.appleTTS.defaultPort, 0)
        XCTAssertEqual(TTSProvider.pocketTTS.defaultPort, 0)
    }

    // MARK: - Sample rates

    func testSampleRatesMatchProviderOutput() {
        // These rates must match the actual audio the servers emit, otherwise
        // playback pitch/speed is wrong.
        XCTAssertEqual(TTSProvider.selfHosted.sampleRate, 22050) // Piper
        XCTAssertEqual(TTSProvider.vibeVoice.sampleRate, 24000)
        XCTAssertEqual(TTSProvider.chatterbox.sampleRate, 24000)
        XCTAssertEqual(TTSProvider.pocketTTS.sampleRate, 24000)
        // Default for cloud providers.
        XCTAssertEqual(TTSProvider.deepgramAura2.sampleRate, 24000)
    }

    // MARK: - Classification

    func testOnDeviceAndSelfHostedAreMutuallyExclusive() {
        // A provider cannot be both on-device and self-hosted, and the two
        // flags must agree with requiresNetwork for the relevant cases.
        for provider in TTSProvider.allCases {
            XCTAssertFalse(
                provider.isOnDevice && provider.isSelfHosted,
                "\(provider) cannot be both on-device and self-hosted"
            )
        }

        XCTAssertTrue(TTSProvider.appleTTS.isOnDevice)
        XCTAssertTrue(TTSProvider.pocketTTS.isOnDevice)
        XCTAssertFalse(TTSProvider.deepgramAura2.isOnDevice)

        XCTAssertTrue(TTSProvider.selfHosted.isSelfHosted)
        XCTAssertTrue(TTSProvider.vibeVoice.isSelfHosted)
        XCTAssertTrue(TTSProvider.chatterbox.isSelfHosted)
        XCTAssertFalse(TTSProvider.appleTTS.isSelfHosted)
        XCTAssertFalse(TTSProvider.deepgramAura2.isSelfHosted)
    }

    func testDisplayNameMatchesRawValue() {
        // displayName drives the picker UI and must echo the human-readable raw value.
        XCTAssertEqual(TTSProvider.deepgramAura2.displayName, "Deepgram Aura-2")
        XCTAssertEqual(TTSProvider.pocketTTS.displayName, "Pocket TTS (On-Device)")
        for provider in TTSProvider.allCases {
            XCTAssertEqual(provider.displayName, provider.rawValue)
        }
    }

    func testRawValueDecodesBackToProvider() {
        // Persistence relies on round-tripping rawValue (e.g. UserDefaults).
        for provider in TTSProvider.allCases {
            XCTAssertEqual(TTSProvider(rawValue: provider.rawValue), provider)
        }
        XCTAssertNil(TTSProvider(rawValue: "not-a-provider"))
    }

    // MARK: - resolveConfiguredService

    func testResolveDefaultsToPocketTTSWhenUnset() async {
        UserDefaults.standard.removeObject(forKey: "ttsProvider")
        defer { UserDefaults.standard.removeObject(forKey: "ttsProvider") }

        // With nothing configured, the resolver returns the on-device default.
        let service = TTSProvider.resolveConfiguredService()
        let costPerChar = await service.costPerCharacter
        // Pocket TTS is free on-device.
        XCTAssertEqual(costPerChar, 0)
        XCTAssertTrue(service is KyutaiPocketTTSService)
    }

    func testResolveDefaultsToPocketTTSForUnknownValue() async {
        UserDefaults.standard.set("garbage-provider", forKey: "ttsProvider")
        defer { UserDefaults.standard.removeObject(forKey: "ttsProvider") }

        // An unrecognized stored value must fall back to Pocket TTS, not crash.
        let service = TTSProvider.resolveConfiguredService()
        XCTAssertTrue(service is KyutaiPocketTTSService)
    }

    func testResolveUsesAppleWhenConfigured() async {
        UserDefaults.standard.set(TTSProvider.appleTTS.rawValue, forKey: "ttsProvider")
        defer { UserDefaults.standard.removeObject(forKey: "ttsProvider") }

        // Apple TTS is a real on-device service and should be created directly.
        let service = TTSProvider.resolveConfiguredService()
        XCTAssertTrue(service is AppleTTSService)
    }

    func testCloudProviderResolvesToLocalPocketFallback() {
        // Cloud/server providers cannot run for local announcements, so the
        // factory deliberately substitutes the on-device Pocket service.
        let service = TTSProvider.deepgramAura2.createLocalService()
        XCTAssertTrue(service is KyutaiPocketTTSService)

        let vibe = TTSProvider.vibeVoice.createLocalService()
        XCTAssertTrue(vibe is KyutaiPocketTTSService)
    }
}
