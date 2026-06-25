// UnaMentis - ChatterboxSettingsViewModelTests
// Unit tests for ChatterboxSettingsViewModel
//
// These tests validate the real outcomes of the view model's pure logic:
// preset application, configuration mapping, description thresholds, and
// reference-audio handling. The view model is @AppStorage backed, so each
// test clears the relevant UserDefaults keys to start from a known state.

import XCTest
@testable import UnaMentis

@MainActor
final class ChatterboxSettingsViewModelTests: XCTestCase {

    // Keys the view model persists through @AppStorage. Cleared before each
    // test so assertions run against deterministic default state.
    private let persistedKeys = [
        "chatterbox_preset",
        "chatterbox_exaggeration",
        "chatterbox_cfg_weight",
        "chatterbox_speed",
        "chatterbox_paralinguistic_tags",
        "chatterbox_use_multilingual",
        "chatterbox_language",
        "chatterbox_streaming",
        "chatterbox_use_fixed_seed",
        "chatterbox_seed",
        "chatterbox_voice_cloning_enabled",
        "chatterbox_reference_audio"
    ]

    private func clearPersistedKeys() {
        let defaults = UserDefaults.standard
        for key in persistedKeys {
            defaults.removeObject(forKey: key)
        }
    }

    override func setUp() async throws {
        clearPersistedKeys()
    }

    override func tearDown() async throws {
        clearPersistedKeys()
    }

    // MARK: - Preset Application

    func testSelectedPresetSetter_appliesPresetValues() {
        let vm = ChatterboxSettingsViewModel()

        vm.selectedPreset = .expressive

        // Setter must persist the raw value and apply the preset's config.
        XCTAssertEqual(vm.selectedPresetRaw, "expressive")
        XCTAssertEqual(vm.exaggeration, 0.8, accuracy: 0.0001)
        XCTAssertEqual(vm.cfgWeight, 0.3, accuracy: 0.0001)
        XCTAssertEqual(vm.speed, 0.9, accuracy: 0.0001)
        XCTAssertTrue(vm.enableParalinguisticTags)
        XCTAssertTrue(vm.useStreaming)
    }

    func testSelectedPresetSetter_customDoesNotApplyConfig() {
        let vm = ChatterboxSettingsViewModel()

        // Establish a non-default value, then switch to custom.
        vm.exaggeration = 0.123
        vm.selectedPreset = .custom

        // Custom must record the raw value but leave user values untouched.
        XCTAssertEqual(vm.selectedPresetRaw, "custom")
        XCTAssertEqual(vm.exaggeration, 0.123, accuracy: 0.0001)
    }

    func testApplyPreset_naturalEnablesParalinguisticTags() {
        let vm = ChatterboxSettingsViewModel()

        vm.applyPreset(.natural)

        XCTAssertEqual(vm.exaggeration, 0.3, accuracy: 0.0001)
        XCTAssertEqual(vm.cfgWeight, 0.3, accuracy: 0.0001)
        XCTAssertTrue(vm.enableParalinguisticTags)
    }

    func testApplyPreset_customIsNoOp() {
        let vm = ChatterboxSettingsViewModel()
        vm.exaggeration = 0.77
        vm.cfgWeight = 0.11

        vm.applyPreset(.custom)

        // applyPreset guards against .custom and must change nothing.
        XCTAssertEqual(vm.exaggeration, 0.77, accuracy: 0.0001)
        XCTAssertEqual(vm.cfgWeight, 0.11, accuracy: 0.0001)
    }

    func testMarkAsCustom_switchesFromPresetToCustom() {
        let vm = ChatterboxSettingsViewModel()
        vm.selectedPresetRaw = ChatterboxPreset.natural.rawValue

        vm.markAsCustom()

        XCTAssertEqual(vm.selectedPresetRaw, "custom")
    }

    func testMarkAsCustom_alreadyCustomStaysCustom() {
        let vm = ChatterboxSettingsViewModel()
        vm.selectedPresetRaw = ChatterboxPreset.custom.rawValue

        vm.markAsCustom()

        XCTAssertEqual(vm.selectedPresetRaw, "custom")
    }

    func testOnSliderValueChanged_marksCustom() {
        let vm = ChatterboxSettingsViewModel()
        vm.selectedPresetRaw = ChatterboxPreset.default.rawValue

        vm.onSliderValueChanged()

        XCTAssertEqual(vm.selectedPresetRaw, "custom")
    }

    // MARK: - Configuration Mapping

    func testCurrentConfig_mapsSettingsToConfig() {
        let vm = ChatterboxSettingsViewModel()
        vm.exaggeration = 0.7
        vm.cfgWeight = 0.4
        vm.speed = 1.2
        vm.enableParalinguisticTags = true
        vm.useMultilingual = true
        vm.languageCode = "fr"
        vm.useStreaming = false

        let config = vm.currentConfig

        XCTAssertEqual(config.exaggeration, 0.7, accuracy: 0.0001)
        XCTAssertEqual(config.cfgWeight, 0.4, accuracy: 0.0001)
        XCTAssertEqual(config.speed, 1.2, accuracy: 0.0001)
        XCTAssertTrue(config.enableParalinguisticTags)
        XCTAssertTrue(config.useMultilingual)
        XCTAssertEqual(config.language, "fr")
        XCTAssertFalse(config.useStreaming)
    }

    func testCurrentConfig_seedOnlyIncludedWhenFixedSeedEnabled() {
        let vm = ChatterboxSettingsViewModel()
        vm.seed = 1234

        // Without fixed seed, the config seed must be nil for random output.
        vm.useFixedSeed = false
        XCTAssertNil(vm.currentConfig.seed)

        // With fixed seed, the config carries the exact seed value.
        vm.useFixedSeed = true
        XCTAssertEqual(vm.currentConfig.seed, 1234)
    }

    func testCurrentConfig_emptyReferenceAudioMapsToNil() {
        let vm = ChatterboxSettingsViewModel()

        vm.referenceAudioPath = ""
        XCTAssertNil(vm.currentConfig.referenceAudioPath)

        vm.referenceAudioPath = "/tmp/voice.wav"
        XCTAssertEqual(vm.currentConfig.referenceAudioPath, "/tmp/voice.wav")
    }

    // MARK: - Description Thresholds

    func testExaggerationDescription_boundaryValues() {
        let vm = ChatterboxSettingsViewModel()

        vm.exaggeration = 0.0
        XCTAssertEqual(vm.exaggerationDescription, "Monotone")
        vm.exaggeration = 0.2
        XCTAssertEqual(vm.exaggerationDescription, "Subdued")
        vm.exaggeration = 0.5
        XCTAssertEqual(vm.exaggerationDescription, "Balanced")
        vm.exaggeration = 0.6
        XCTAssertEqual(vm.exaggerationDescription, "Expressive")
        vm.exaggeration = 0.8
        XCTAssertEqual(vm.exaggerationDescription, "Dramatic")
        vm.exaggeration = 1.0
        XCTAssertEqual(vm.exaggerationDescription, "Very Dramatic")
        vm.exaggeration = 1.5
        XCTAssertEqual(vm.exaggerationDescription, "Very Dramatic")
    }

    func testCfgWeightDescription_boundaryValues() {
        let vm = ChatterboxSettingsViewModel()

        vm.cfgWeight = 0.0
        XCTAssertEqual(vm.cfgWeightDescription, "Creative")
        vm.cfgWeight = 0.3
        XCTAssertEqual(vm.cfgWeightDescription, "Natural")
        vm.cfgWeight = 0.5
        XCTAssertEqual(vm.cfgWeightDescription, "Balanced")
        vm.cfgWeight = 0.7
        XCTAssertEqual(vm.cfgWeightDescription, "Controlled")
    }

    func testSpeedDescription_boundaryValues() {
        let vm = ChatterboxSettingsViewModel()

        vm.speed = 0.5
        XCTAssertEqual(vm.speedDescription, "Slow")
        vm.speed = 0.8
        XCTAssertEqual(vm.speedDescription, "Normal")
        vm.speed = 1.1
        XCTAssertEqual(vm.speedDescription, "Fast")
        vm.speed = 1.5
        XCTAssertEqual(vm.speedDescription, "Very Fast")
    }

    // MARK: - Language Selection

    func testSelectedLanguage_getterParsesCode() {
        let vm = ChatterboxSettingsViewModel()
        vm.languageCode = "ja"

        XCTAssertEqual(vm.selectedLanguage, .japanese)
    }

    func testSelectedLanguage_getterFallsBackToEnglishOnUnknownCode() {
        let vm = ChatterboxSettingsViewModel()
        vm.languageCode = "xx-not-a-language"

        XCTAssertEqual(vm.selectedLanguage, .english)
    }

    func testSelectedLanguage_setterWritesCode() {
        let vm = ChatterboxSettingsViewModel()

        vm.selectedLanguage = .german

        XCTAssertEqual(vm.languageCode, "de")
    }

    // MARK: - Reference Audio

    func testHasReferenceAudio_falseWhenPathEmpty() {
        let vm = ChatterboxSettingsViewModel()
        vm.referenceAudioPath = ""

        XCTAssertFalse(vm.hasReferenceAudio)
    }

    func testHasReferenceAudio_falseWhenFileMissing() {
        let vm = ChatterboxSettingsViewModel()
        vm.referenceAudioPath = "/nonexistent/path/voice.wav"

        // Path is non-empty but the file does not exist.
        XCTAssertFalse(vm.hasReferenceAudio)
    }

    func testHasReferenceAudio_trueWhenFileExists() throws {
        let vm = ChatterboxSettingsViewModel()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatterbox_ref_\(UUID().uuidString).wav")
        try Data([0x00, 0x01]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        vm.referenceAudioPath = tempURL.path

        XCTAssertTrue(vm.hasReferenceAudio)
    }

    func testReferenceAudioFileName_returnsLastPathComponent() {
        let vm = ChatterboxSettingsViewModel()
        vm.referenceAudioPath = "/Users/test/recordings/my voice.wav"

        XCTAssertEqual(vm.referenceAudioFileName, "my voice.wav")
    }

    func testReferenceAudioFileName_emptyWhenNoPath() {
        let vm = ChatterboxSettingsViewModel()
        vm.referenceAudioPath = ""

        XCTAssertEqual(vm.referenceAudioFileName, "")
    }

    func testClearReferenceAudio_resetsPath() {
        let vm = ChatterboxSettingsViewModel()
        vm.referenceAudioPath = "/tmp/voice.wav"

        vm.clearReferenceAudio()

        XCTAssertEqual(vm.referenceAudioPath, "")
    }

    // MARK: - Reset

    func testResetToDefaults_restoresAllValues() {
        let vm = ChatterboxSettingsViewModel()
        // Mutate everything away from defaults.
        vm.selectedPresetRaw = ChatterboxPreset.custom.rawValue
        vm.exaggeration = 1.2
        vm.cfgWeight = 0.9
        vm.speed = 1.8
        vm.enableParalinguisticTags = true
        vm.useMultilingual = true
        vm.languageCode = "fr"
        vm.useStreaming = false
        vm.useFixedSeed = true
        vm.seed = 999
        vm.referenceAudioPath = "/tmp/voice.wav"

        vm.resetToDefaults()

        XCTAssertEqual(vm.selectedPresetRaw, "default")
        XCTAssertEqual(vm.exaggeration, 0.5, accuracy: 0.0001)
        XCTAssertEqual(vm.cfgWeight, 0.5, accuracy: 0.0001)
        XCTAssertEqual(vm.speed, 1.0, accuracy: 0.0001)
        XCTAssertFalse(vm.enableParalinguisticTags)
        XCTAssertFalse(vm.useMultilingual)
        XCTAssertEqual(vm.languageCode, "en")
        XCTAssertTrue(vm.useStreaming)
        XCTAssertFalse(vm.useFixedSeed)
        XCTAssertEqual(vm.seed, 42)
        XCTAssertEqual(vm.referenceAudioPath, "")
    }

    // MARK: - Static Lists

    func testAvailablePresetsAndLanguages_matchCanonicalCases() {
        let vm = ChatterboxSettingsViewModel()

        XCTAssertEqual(vm.availablePresets, ChatterboxPreset.allCases)
        XCTAssertEqual(vm.availableLanguages, ChatterboxLanguage.allCases)
        XCTAssertEqual(vm.presetDisplayName, vm.selectedPreset.displayName)
    }
}
