// UnaMentis - KyutaiPocketSettingsViewModelTests
// Unit tests for KyutaiPocketSettingsViewModel
//
// Validates real outcomes of the view model's pure logic: voice filtering,
// preset application via the published preset, slider-to-custom transitions,
// reference-audio handling, and the description thresholds. The view model is
// @AppStorage backed, so persisted keys are cleared before each test.

import XCTest
@testable import UnaMentis

@MainActor
final class KyutaiPocketSettingsViewModelTests: XCTestCase {

    private let persistedKeys = [
        "kyutai_pocket_voice_index",
        "kyutai_pocket_temperature",
        "kyutai_pocket_top_p",
        "kyutai_pocket_speed",
        "kyutai_pocket_consistency_steps",
        "kyutai_pocket_use_neural_engine",
        "kyutai_pocket_enable_prefetch",
        "kyutai_pocket_use_fixed_seed",
        "kyutai_pocket_seed",
        "kyutai_pocket_reference_audio",
        "kyutai_pocket_preset"
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

    // MARK: - Voice Filtering

    func testFilteredVoices_allReturnsEveryVoice() {
        let vm = KyutaiPocketSettingsViewModel()
        vm.voiceGenderFilter = .all

        XCTAssertEqual(vm.filteredVoices, KyutaiPocketVoice.allCases)
    }

    func testFilteredVoices_femaleReturnsOnlyFemaleVoices() {
        let vm = KyutaiPocketSettingsViewModel()
        vm.voiceGenderFilter = .female

        let result = vm.filteredVoices

        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.allSatisfy { $0.gender == .female })
        // Alba, Fantine, Cosette, Eponine, Azelma are the five female voices.
        XCTAssertEqual(result.count, 5)
        XCTAssertTrue(result.contains(.alba))
        XCTAssertFalse(result.contains(.marius))
    }

    func testFilteredVoices_maleReturnsOnlyMaleVoices() {
        let vm = KyutaiPocketSettingsViewModel()
        vm.voiceGenderFilter = .male

        let result = vm.filteredVoices

        XCTAssertTrue(result.allSatisfy { $0.gender == .male })
        // Marius, Javert, Jean are the three male voices.
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.contains(.javert))
    }

    // MARK: - Voice Selection Side Effects

    func testSelectedVoiceSetter_writesVoiceIndex() {
        let vm = KyutaiPocketSettingsViewModel()

        vm.selectedVoice = .eponine

        // didSet must mirror the voice into the persisted index.
        XCTAssertEqual(vm.voiceIndex, KyutaiPocketVoice.eponine.rawValue)
        XCTAssertEqual(vm.voiceIndex, 6)
    }

    // MARK: - Preset Application

    func testSelectedPresetSetter_appliesHighQualityConfig() {
        let vm = KyutaiPocketSettingsViewModel()

        vm.selectedPreset = .highQuality

        // High quality uses 4 consistency steps and disables prefetch.
        XCTAssertEqual(vm.consistencySteps, 4)
        XCTAssertFalse(vm.enablePrefetch)
        XCTAssertEqual(vm.topP, 0.95, accuracy: 0.0001)
        // The preset choice must persist so it survives a reload.
        XCTAssertEqual(KyutaiPocketTTSConfig.currentPreset(), .highQuality)
    }

    func testSelectedPresetSetter_batterySaverDisablesNeuralEngine() {
        let vm = KyutaiPocketSettingsViewModel()

        vm.selectedPreset = .batterySaver

        XCTAssertFalse(vm.useNeuralEngine)
        XCTAssertEqual(vm.consistencySteps, 1)
    }

    func testSelectedPresetSetter_customDoesNotOverwriteValues() {
        let vm = KyutaiPocketSettingsViewModel()
        vm.temperature = 0.42

        vm.selectedPreset = .custom

        // Switching to custom must not re-apply any preset config.
        XCTAssertEqual(vm.temperature, 0.42, accuracy: 0.0001)
        XCTAssertEqual(KyutaiPocketTTSConfig.currentPreset(), .custom)
    }

    func testOnSliderValueChanged_switchesToCustomPreset() {
        let vm = KyutaiPocketSettingsViewModel()
        vm.selectedPreset = .default

        vm.onSliderValueChanged()

        XCTAssertEqual(vm.selectedPreset, .custom)
    }

    func testOnSliderValueChanged_alreadyCustomStaysCustom() {
        let vm = KyutaiPocketSettingsViewModel()
        vm.selectedPreset = .custom

        vm.onSliderValueChanged()

        XCTAssertEqual(vm.selectedPreset, .custom)
    }

    func testResetToDefaults_restoresPresetVoiceAndConfig() {
        let vm = KyutaiPocketSettingsViewModel()
        vm.selectedPreset = .highQuality
        vm.selectedVoice = .javert
        vm.voiceCloningEnabled = true
        vm.referenceAudioPath = "/tmp/ref.wav"

        vm.resetToDefaults()

        XCTAssertEqual(vm.selectedPreset, .default)
        XCTAssertEqual(vm.selectedVoice, .alba)
        XCTAssertFalse(vm.voiceCloningEnabled)
        XCTAssertNil(vm.referenceAudioPath)
        // Default preset config values.
        XCTAssertEqual(vm.consistencySteps, 2)
        XCTAssertEqual(vm.temperature, 0.7, accuracy: 0.0001)
        XCTAssertTrue(vm.useNeuralEngine)
    }

    // MARK: - Reference Audio

    func testHasReferenceAudio_reflectsPathPresence() {
        let vm = KyutaiPocketSettingsViewModel()

        vm.referenceAudioPath = nil
        XCTAssertFalse(vm.hasReferenceAudio)

        vm.referenceAudioPath = "/tmp/ref.wav"
        XCTAssertTrue(vm.hasReferenceAudio)
    }

    func testReferenceAudioFileName_returnsLastComponentOrEmpty() {
        let vm = KyutaiPocketSettingsViewModel()

        vm.referenceAudioPath = nil
        XCTAssertEqual(vm.referenceAudioFileName, "")

        vm.referenceAudioPath = "/recordings/clone sample.wav"
        XCTAssertEqual(vm.referenceAudioFileName, "clone sample.wav")
    }

    func testClearReferenceAudio_clearsPathAndDisablesCloning() {
        let vm = KyutaiPocketSettingsViewModel()
        vm.referenceAudioPath = "/tmp/ref.wav"
        vm.voiceCloningEnabled = true

        vm.clearReferenceAudio()

        XCTAssertNil(vm.referenceAudioPath)
        XCTAssertFalse(vm.voiceCloningEnabled)
    }

    // MARK: - Description Thresholds

    func testTemperatureDescription_boundaryValues() {
        let vm = KyutaiPocketSettingsViewModel()

        vm.temperature = 0.0
        XCTAssertEqual(vm.temperatureDescription, "Deterministic")
        vm.temperature = 0.3
        XCTAssertEqual(vm.temperatureDescription, "Consistent")
        vm.temperature = 0.6
        XCTAssertEqual(vm.temperatureDescription, "Balanced")
        vm.temperature = 0.8
        XCTAssertEqual(vm.temperatureDescription, "Creative")
        vm.temperature = 1.0
        XCTAssertEqual(vm.temperatureDescription, "Random")
    }

    func testTopPDescription_boundaryValues() {
        let vm = KyutaiPocketSettingsViewModel()

        vm.topP = 0.0
        XCTAssertEqual(vm.topPDescription, "Focused")
        vm.topP = 0.5
        XCTAssertEqual(vm.topPDescription, "Moderate")
        vm.topP = 0.8
        XCTAssertEqual(vm.topPDescription, "Diverse")
        vm.topP = 0.95
        XCTAssertEqual(vm.topPDescription, "Unrestricted")
    }

    func testSpeedDescription_boundaryValues() {
        let vm = KyutaiPocketSettingsViewModel()

        vm.speed = 0.5
        XCTAssertEqual(vm.speedDescription, "Slow")
        vm.speed = 0.7
        XCTAssertEqual(vm.speedDescription, "Relaxed")
        vm.speed = 1.0
        XCTAssertEqual(vm.speedDescription, "Normal")
        vm.speed = 1.1
        XCTAssertEqual(vm.speedDescription, "Brisk")
        vm.speed = 1.3
        XCTAssertEqual(vm.speedDescription, "Fast")
    }

    func testConsistencyStepsDescription_eachStep() {
        let vm = KyutaiPocketSettingsViewModel()

        vm.consistencySteps = 1
        XCTAssertEqual(vm.consistencyStepsDescription, "Fast")
        vm.consistencySteps = 2
        XCTAssertEqual(vm.consistencyStepsDescription, "Balanced")
        vm.consistencySteps = 3
        XCTAssertEqual(vm.consistencyStepsDescription, "High Quality")
        vm.consistencySteps = 4
        XCTAssertEqual(vm.consistencyStepsDescription, "Best Quality")
        vm.consistencySteps = 9
        XCTAssertEqual(vm.consistencyStepsDescription, "Unknown")
    }

    // MARK: - Model Info Formatting

    func testModelStateDescription_reflectsState() {
        let vm = KyutaiPocketSettingsViewModel()

        vm.modelState = .notDownloaded
        XCTAssertEqual(vm.modelStateDescription, "Not Downloaded")

        vm.modelState = .loaded
        XCTAssertEqual(vm.modelStateDescription, "Loaded")

        vm.modelState = .error("disk full")
        XCTAssertEqual(vm.modelStateDescription, "Error: disk full")
    }

    func testTotalDownloadSizeMB_includesMegabyteSuffix() {
        let vm = KyutaiPocketSettingsViewModel()

        // The download size string must surface a numeric value with the MB
        // suffix so the UI can present a download estimate.
        XCTAssertTrue(vm.totalDownloadSizeMB.hasSuffix(" MB"),
                      "Expected a value formatted with a MB suffix, got \(vm.totalDownloadSizeMB)")
        XCTAssertTrue(vm.totalDownloadSizeMB.contains(where: { $0.isNumber }),
                      "Expected a numeric size in \(vm.totalDownloadSizeMB)")
    }
}
