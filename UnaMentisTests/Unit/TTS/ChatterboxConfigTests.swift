// UnaMentis - ChatterboxConfigTests
// Unit tests for Chatterbox TTS configuration, presets, persistence, and the
// supporting language/preset enums.
//
// ChatterboxConfig values are serialized into the synthesis request body
// (exaggeration, cfg_weight, speed, language, seed), so preset values and the
// UserDefaults defaulting logic are real contracts worth protecting.

import XCTest
@testable import UnaMentis

final class ChatterboxConfigTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultConfigValues() {
        let config = ChatterboxConfig.default
        XCTAssertEqual(config.exaggeration, 0.5)
        XCTAssertEqual(config.cfgWeight, 0.5)
        XCTAssertEqual(config.speed, 1.0)
        XCTAssertFalse(config.enableParalinguisticTags)
        XCTAssertFalse(config.useMultilingual)
        XCTAssertEqual(config.language, "en")
        XCTAssertTrue(config.useStreaming)
        XCTAssertNil(config.seed)
        XCTAssertNil(config.referenceAudioPath)
    }

    // MARK: - Presets

    func testNaturalPresetEnablesTagsAndLowersGuidance() {
        // Natural delivery uses lower exaggeration/cfg and turns on tag reactions.
        let config = ChatterboxConfig.natural
        XCTAssertEqual(config.exaggeration, 0.3)
        XCTAssertEqual(config.cfgWeight, 0.3)
        XCTAssertTrue(config.enableParalinguisticTags)
    }

    func testExpressivePresetRaisesExaggerationAndSlowsSpeed() {
        let config = ChatterboxConfig.expressive
        XCTAssertEqual(config.exaggeration, 0.8)
        XCTAssertEqual(config.speed, 0.9)
        XCTAssertTrue(config.enableParalinguisticTags)
    }

    func testLowLatencyPresetSpeedsUpAndDisablesTags() {
        let config = ChatterboxConfig.lowLatency
        XCTAssertEqual(config.speed, 1.1)
        XCTAssertFalse(config.enableParalinguisticTags)
        XCTAssertTrue(config.useStreaming)
    }

    func testPresetsAreDistinct() {
        // Each named preset must produce a materially different config so that
        // switching presets actually changes synthesis behavior.
        XCTAssertNotEqual(ChatterboxConfig.natural, ChatterboxConfig.expressive)
        XCTAssertNotEqual(ChatterboxConfig.default, ChatterboxConfig.lowLatency)
        XCTAssertNotEqual(ChatterboxConfig.natural, ChatterboxConfig.lowLatency)
    }

    // MARK: - Preset enum mapping

    func testPresetEnumResolvesToMatchingConfig() {
        XCTAssertEqual(ChatterboxPreset.default.config, ChatterboxConfig.default)
        XCTAssertEqual(ChatterboxPreset.natural.config, ChatterboxConfig.natural)
        XCTAssertEqual(ChatterboxPreset.expressive.config, ChatterboxConfig.expressive)
        XCTAssertEqual(ChatterboxPreset.lowLatency.config, ChatterboxConfig.lowLatency)
        // Custom intentionally falls back to default values until the user overrides them.
        XCTAssertEqual(ChatterboxPreset.custom.config, ChatterboxConfig.default)
    }

    func testPresetDisplayNames() {
        XCTAssertEqual(ChatterboxPreset.lowLatency.displayName, "Low Latency")
        XCTAssertEqual(ChatterboxPreset.default.displayName, "Default")
        XCTAssertEqual(ChatterboxPreset.custom.displayName, "Custom")
    }

    // MARK: - Codable round trip

    func testConfigCodableRoundTrip() throws {
        let original = ChatterboxConfig(
            exaggeration: 0.75,
            cfgWeight: 0.4,
            speed: 1.25,
            enableParalinguisticTags: true,
            useMultilingual: true,
            language: "fr",
            useStreaming: false,
            seed: 4242,
            referenceAudioPath: "/tmp/ref.wav"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatterboxConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - UserDefaults loading

    func testFromUserDefaultsUsesCorrectDefaultsWhenUnset() {
        let suiteName = "ChatterboxConfigTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // With nothing stored, fromUserDefaults must use the documented defaults,
        // notably useStreaming = true even though UserDefaults.bool returns false
        // for an unset key. We swap the standard suite for an isolated one.
        withStandardDefaults(defaults) {
            let config = ChatterboxConfig.fromUserDefaults()
            XCTAssertEqual(config.exaggeration, 0.5)
            XCTAssertEqual(config.cfgWeight, 0.5)
            XCTAssertEqual(config.speed, 1.0)
            XCTAssertEqual(config.language, "en")
            XCTAssertTrue(config.useStreaming, "useStreaming must default to true when unset")
            XCTAssertNil(config.seed, "seed must be nil unless a fixed seed is requested")
        }
    }

    func testFromUserDefaultsReadsStoredValues() {
        let suiteName = "ChatterboxConfigTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(0.9, forKey: "chatterbox_exaggeration")
        defaults.set(0.2, forKey: "chatterbox_cfg_weight")
        defaults.set(1.4, forKey: "chatterbox_speed")
        defaults.set(true, forKey: "chatterbox_paralinguistic_tags")
        defaults.set("de", forKey: "chatterbox_language")
        defaults.set(false, forKey: "chatterbox_streaming")
        defaults.set(true, forKey: "chatterbox_use_fixed_seed")
        defaults.set(777, forKey: "chatterbox_seed")

        withStandardDefaults(defaults) {
            let config = ChatterboxConfig.fromUserDefaults()
            XCTAssertEqual(config.exaggeration, 0.9, accuracy: 0.0001)
            XCTAssertEqual(config.cfgWeight, 0.2, accuracy: 0.0001)
            XCTAssertEqual(config.speed, 1.4, accuracy: 0.0001)
            XCTAssertTrue(config.enableParalinguisticTags)
            XCTAssertEqual(config.language, "de")
            XCTAssertFalse(config.useStreaming)
            XCTAssertEqual(config.seed, 777)
        }
    }

    func testFromUserDefaultsIgnoresSeedWhenFixedSeedDisabled() {
        let suiteName = "ChatterboxConfigTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A stored seed value must be ignored unless the user opted into a fixed seed.
        defaults.set(false, forKey: "chatterbox_use_fixed_seed")
        defaults.set(999, forKey: "chatterbox_seed")

        withStandardDefaults(defaults) {
            let config = ChatterboxConfig.fromUserDefaults()
            XCTAssertNil(config.seed)
        }
    }

    // MARK: - Language enum

    func testLanguageEnumCoversAdvertisedLanguageCount() {
        // Chatterbox advertises 23 multilingual languages; the enum must match.
        XCTAssertEqual(ChatterboxLanguage.allCases.count, 23)
    }

    func testLanguageRawValuesAreBCP47Codes() {
        XCTAssertEqual(ChatterboxLanguage.english.rawValue, "en")
        XCTAssertEqual(ChatterboxLanguage.japanese.rawValue, "ja")
        XCTAssertEqual(ChatterboxLanguage.chinese.rawValue, "zh")
    }

    func testLanguageNativeNames() {
        XCTAssertEqual(ChatterboxLanguage.japanese.nativeName, "日本語")
        XCTAssertEqual(ChatterboxLanguage.french.nativeName, "Français")
    }

    // MARK: - Paralinguistic tags

    func testParalinguisticTagRawValuesAreBracketed() {
        XCTAssertEqual(ChatterboxParalinguisticTag.laugh.rawValue, "[laugh]")
        XCTAssertEqual(ChatterboxParalinguisticTag.gasp.rawValue, "[gasp]")
        XCTAssertEqual(ChatterboxParalinguisticTag.allCases.count, 5)
    }

    // MARK: - Helpers

    /// Run `body` with UserDefaults.standard temporarily backed by `replacement`
    /// via an added suite, then remove it. fromUserDefaults reads UserDefaults.standard,
    /// so we mirror the test keys into the standard domain through a scratch suite.
    private func withStandardDefaults(_ replacement: UserDefaults, _ body: () -> Void) {
        let keys = [
            "chatterbox_exaggeration", "chatterbox_cfg_weight", "chatterbox_speed",
            "chatterbox_paralinguistic_tags", "chatterbox_use_multilingual",
            "chatterbox_language", "chatterbox_streaming",
            "chatterbox_use_fixed_seed", "chatterbox_seed"
        ]
        let standard = UserDefaults.standard
        // Save and clear any pre-existing standard values for these keys.
        let saved = keys.reduce(into: [String: Any]()) { acc, key in
            if let value = standard.object(forKey: key) { acc[key] = value }
            standard.removeObject(forKey: key)
        }
        // Copy the replacement values into the standard domain.
        for key in keys {
            if let value = replacement.object(forKey: key) {
                standard.set(value, forKey: key)
            }
        }
        defer {
            for key in keys { standard.removeObject(forKey: key) }
            for (key, value) in saved { standard.set(value, forKey: key) }
        }
        body()
    }
}
