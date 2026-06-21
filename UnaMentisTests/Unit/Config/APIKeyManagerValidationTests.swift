// UnaMentis - APIKeyManager.validateRequiredKeys branch tests
// Drives the provider-selection logic via UserDefaults and asserts which API
// keys are reported missing for each STT/LLM/TTS provider choice.
//
// TESTING PHILOSOPHY (Real Over Mock):
// validateRequiredKeys reads the real UserDefaults provider selections and the
// real Keychain. These tests set provider keys in UserDefaults, ensure the keys
// they assert on are absent from the Keychain, then restore everything.

import XCTest
@testable import UnaMentis

/// Tests for the settings-driven required-key validation.
final class APIKeyManagerValidationTests: XCTestCase {

    private let manager = APIKeyManager.shared

    private let sttKey = "sttProvider"
    private let llmKey = "llmProvider"
    private let ttsKey = "ttsProvider"

    private var savedSTT: String?
    private var savedLLM: String?
    private var savedTTS: String?

    /// Keys that the validation logic may reference. We snapshot and remove these
    /// so "missing" assertions are deterministic, then restore them afterwards.
    private let touchedKeys: [APIKeyManager.KeyType] = [
        .assemblyAI, .deepgram, .openAI, .anthropic, .groq, .elevenLabs
    ]
    private var savedKeyValues: [APIKeyManager.KeyType: String] = [:]

    override func setUp() async throws {
        try await super.setUp()
        let defaults = UserDefaults.standard
        savedSTT = defaults.string(forKey: sttKey)
        savedLLM = defaults.string(forKey: llmKey)
        savedTTS = defaults.string(forKey: ttsKey)

        // Snapshot and clear any configured keys we will assert on.
        for keyType in touchedKeys {
            if let value = await manager.getKey(keyType) {
                savedKeyValues[keyType] = value
            }
            try? await manager.removeKey(keyType)
        }
    }

    override func tearDown() async throws {
        let defaults = UserDefaults.standard
        restore(savedSTT, forKey: sttKey, in: defaults)
        restore(savedLLM, forKey: llmKey, in: defaults)
        restore(savedTTS, forKey: ttsKey, in: defaults)

        // Restore previously configured keys (or leave removed if none existed).
        for keyType in touchedKeys {
            if let value = savedKeyValues[keyType] {
                try? await manager.setKey(keyType, value: value)
            } else {
                try? await manager.removeKey(keyType)
            }
        }
        try await super.tearDown()
    }

    private func restore(_ value: String?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func selectProviders(stt: String, llm: String, tts: String) {
        let defaults = UserDefaults.standard
        defaults.set(stt, forKey: sttKey)
        defaults.set(llm, forKey: llmKey)
        defaults.set(tts, forKey: ttsKey)
    }

    // MARK: - On-device selections require nothing

    func testOnDeviceProvidersRequireNoKeys() async {
        selectProviders(
            stt: "Apple Speech (On-Device)",
            llm: "Local MLX",
            tts: "Apple TTS (On-Device)"
        )

        let missing = await manager.validateRequiredKeys()
        XCTAssertTrue(missing.isEmpty,
                      "on-device providers must not require any API keys, got \(missing)")
    }

    func testUnsetProvidersDefaultToOnDevice() async {
        UserDefaults.standard.removeObject(forKey: sttKey)
        UserDefaults.standard.removeObject(forKey: llmKey)
        UserDefaults.standard.removeObject(forKey: ttsKey)

        let missing = await manager.validateRequiredKeys()
        XCTAssertTrue(missing.isEmpty,
                      "unset providers should default to on-device and require no keys")
    }

    // MARK: - Individual cloud provider requirements

    func testAssemblyAISTTRequiresAssemblyAIKey() async {
        selectProviders(
            stt: "AssemblyAI Universal-Streaming",
            llm: "Local MLX",
            tts: "Apple TTS (On-Device)"
        )

        let missing = await manager.validateRequiredKeys()
        XCTAssertEqual(missing, [.assemblyAI])
    }

    func testAnthropicLLMRequiresAnthropicKey() async {
        selectProviders(
            stt: "Apple Speech (On-Device)",
            llm: "Anthropic Claude",
            tts: "Apple TTS (On-Device)"
        )

        let missing = await manager.validateRequiredKeys()
        XCTAssertEqual(missing, [.anthropic])
    }

    func testElevenLabsTTSRequiresElevenLabsKey() async {
        selectProviders(
            stt: "Apple Speech (On-Device)",
            llm: "Local MLX",
            tts: "ElevenLabs Flash"
        )

        let missing = await manager.validateRequiredKeys()
        XCTAssertEqual(missing, [.elevenLabs])
    }

    // MARK: - De-duplication when one provider covers two roles

    func testDeepgramSTTAndTTSRequiresDeepgramOnlyOnce() async {
        selectProviders(
            stt: "Deepgram Nova-3",
            llm: "Local MLX",
            tts: "Deepgram Aura-2"
        )

        let missing = await manager.validateRequiredKeys()
        XCTAssertEqual(missing, [.deepgram],
                       "Deepgram covers both STT and TTS, so it must appear only once")
    }

    func testOpenAISTTAndLLMRequiresOpenAIOnlyOnce() async {
        // OpenAI Whisper for STT and OpenAI for LLM both map to the openAI key.
        selectProviders(
            stt: "OpenAI Whisper",
            llm: "OpenAI",
            tts: "Apple TTS (On-Device)"
        )

        let missing = await manager.validateRequiredKeys()
        XCTAssertEqual(missing, [.openAI],
                       "OpenAI covers both STT and LLM, so it must appear only once")
    }

    // MARK: - Multiple distinct providers

    func testMultipleDistinctCloudProvidersAllReported() async {
        selectProviders(
            stt: "Groq Whisper (Cloud)",
            llm: "Anthropic Claude",
            tts: "ElevenLabs Turbo"
        )

        let missing = Set(await manager.validateRequiredKeys())
        XCTAssertEqual(missing, [.groq, .anthropic, .elevenLabs])
    }

    // MARK: - Present keys are filtered out

    func testConfiguredKeyIsNotReportedMissing() async throws {
        selectProviders(
            stt: "Apple Speech (On-Device)",
            llm: "Anthropic Claude",
            tts: "Apple TTS (On-Device)"
        )

        // Configure the anthropic key so it should drop out of the missing list.
        // The unit-test host on the simulator can lack the keychain entitlement that
        // SecItemAdd requires (errSecMissingEntitlement, -34018). When the keychain
        // cannot be written, skip rather than report a host limitation as a logic
        // failure. This test runs in full on a properly entitled host or device.
        do {
            try await manager.setKey(.anthropic, value: "configured-anthropic-key")
        } catch let APIKeyError.keychainError(status) where status == errSecMissingEntitlement {
            throw XCTSkip("Keychain unavailable in this test host (errSecMissingEntitlement \(status)); skipping configured-key validation")
        }

        let missing = await manager.validateRequiredKeys()
        XCTAssertFalse(missing.contains(.anthropic),
                       "a configured key must not be reported as missing")
        XCTAssertTrue(missing.isEmpty,
                      "with the only required key present, nothing should be missing")
    }
}
