// UnaMentis - Audio Engine Configuration Tests
//
// Unit tests for AudioEngineConfig and its supporting types. The behavior under test
// is pure, deterministic logic with no external dependencies, so the real types are
// used directly with no mocks.
//
// The contracts protected here are the ones with real branching logic, not stored
// property echoes:
//   - ThermalThreshold.isExceededBy decides when audio quality should throttle. It is a
//     >= comparison over the 0..3 thermal ordering, so the full matrix is exercised.
//   - ThermalThreshold.init(from:) maps each ProcessInfo.ThermalState to its case.
//   - BitDepth.avFormat maps each bit depth to the matching AVAudioCommonFormat.
//   - CaseIterable counts and user-facing rawValue strings (shown in settings UI).
//   - The three presets carry distinct, documented tuning. The distinguishing fields
//     are asserted so a silent preset change is caught.
//   - AudioEngineConfig Codable round-trips, protecting the enum rawValue coding.
//   - AudioEngineError.errorDescription user-facing strings for every case.
//
// Expected values are derived directly from AudioEngineConfig.swift.

import AVFoundation
import XCTest
@testable import UnaMentis

final class AudioEngineConfigTests: XCTestCase {

    // MARK: - ThermalThreshold.isExceededBy

    func testIsExceededBy_fullMatrixAgainstHardcodedTruthTable() {
        // The decision is "throttle when state is at or above the threshold" over the
        // ordering nominal < fair < serious < critical. The expected results are a
        // hardcoded 4x4 truth table, not re-derived from the source formula, so a flip in
        // the comparison direction (> vs >=) or a reordering of the cases is caught
        // against an independent reference rather than a mirror of the implementation.
        //
        // Rows are thresholds, columns are states in order [nominal, fair, serious, critical].
        let states: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]
        let truthTable: [(ThermalThreshold, [Bool])] = [
            // nominal threshold (floor): every state meets or exceeds it.
            (.nominal, [true, true, true, true]),
            // fair threshold: nominal is below, fair and above meet it.
            (.fair, [false, true, true, true]),
            // serious threshold (default preset): only serious and critical throttle.
            (.serious, [false, false, true, true]),
            // critical threshold (privacy-first preset): only critical throttles.
            (.critical, [false, false, false, true])
        ]

        for (threshold, expectedRow) in truthTable {
            for (index, state) in states.enumerated() {
                let expected = expectedRow[index]
                XCTAssertEqual(
                    threshold.isExceededBy(state),
                    expected,
                    "threshold \(threshold) vs state \(state): expected \(expected)"
                )
            }
        }
    }

    // MARK: - ThermalThreshold.init(from:)

    func testInitFromThermalState_mapsEachStateToMatchingCase() {
        let cases: [(ProcessInfo.ThermalState, ThermalThreshold)] = [
            (.nominal, .nominal),
            (.fair, .fair),
            (.serious, .serious),
            (.critical, .critical)
        ]
        for (state, expected) in cases {
            XCTAssertEqual(
                ThermalThreshold(from: state),
                expected,
                "ThermalState \(state) should map to \(expected)"
            )
        }
    }

    // MARK: - BitDepth.avFormat

    func testBitDepthAvFormat_mapsEachDepthToMatchingCommonFormat() {
        let cases: [(BitDepth, AVAudioCommonFormat)] = [
            (.int16, .pcmFormatInt16),
            (.int32, .pcmFormatInt32),
            (.float32, .pcmFormatFloat32)
        ]
        for (depth, expected) in cases {
            XCTAssertEqual(
                depth.avFormat,
                expected,
                "BitDepth \(depth) should map to \(expected)"
            )
        }
    }

    // MARK: - CaseIterable and rawValues

    func testBitDepth_caseIterableCountAndUserFacingRawValues() {
        XCTAssertEqual(BitDepth.allCases.count, 3)
        // These strings appear in the settings UI, so their text is part of the contract.
        // All three are pinned so a rename of any case is caught.
        XCTAssertEqual(BitDepth.int16.rawValue, "16-bit Integer")
        XCTAssertEqual(BitDepth.int32.rawValue, "32-bit Integer")
        XCTAssertEqual(BitDepth.float32.rawValue, "32-bit Float")
    }

    func testThermalThreshold_caseIterableCountAndUserFacingRawValues() {
        XCTAssertEqual(ThermalThreshold.allCases.count, 4)
        XCTAssertEqual(ThermalThreshold.nominal.rawValue, "Nominal")
        XCTAssertEqual(ThermalThreshold.fair.rawValue, "Fair")
        XCTAssertEqual(ThermalThreshold.serious.rawValue, "Serious")
        XCTAssertEqual(ThermalThreshold.critical.rawValue, "Critical")
    }

    // MARK: - Presets

    func testDefaultPreset_carriesDocumentedTuning() {
        let config = AudioEngineConfig.default
        XCTAssertEqual(config.sampleRate, 48000)
        XCTAssertEqual(config.bufferSize, 1024)
        XCTAssertEqual(config.bitDepth, .float32)
        XCTAssertEqual(config.thermalThrottleThreshold, .serious)
        XCTAssertTrue(config.enableAdaptiveQuality)
        XCTAssertEqual(config.levelUpdateInterval, 0.1, accuracy: 1e-9)
    }

    func testLowLatencyPreset_tradesSampleRateAndBufferForResponsiveness() {
        let config = AudioEngineConfig.lowLatency
        // Half the default sample rate and buffer for lower latency.
        XCTAssertEqual(config.sampleRate, 24000)
        XCTAssertEqual(config.bufferSize, 512)
        // Faster UI level updates and a more sensitive VAD trigger.
        XCTAssertEqual(config.levelUpdateInterval, 0.05, accuracy: 1e-9)
        XCTAssertEqual(config.vadThreshold, 0.4, accuracy: 1e-6)
    }

    func testPrivacyFirstPreset_favorsOnDeviceLowFootprintTuning() {
        let config = AudioEngineConfig.privacyFirst
        XCTAssertEqual(config.sampleRate, 16000)
        XCTAssertEqual(config.bitDepth, .int16)
        // Adaptive quality is off and throttling only kicks in at critical thermal state.
        XCTAssertFalse(config.enableAdaptiveQuality)
        XCTAssertEqual(config.thermalThrottleThreshold, .critical)
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip_preservesDistinguishingFields() throws {
        // Encoding then decoding must reproduce the config, which protects the rawValue
        // coding of BitDepth, VADProvider, and ThermalThreshold enums.
        let original = AudioEngineConfig.default
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AudioEngineConfig.self, from: data)

        XCTAssertEqual(decoded.sampleRate, original.sampleRate)
        XCTAssertEqual(decoded.bitDepth, original.bitDepth)
        XCTAssertEqual(decoded.vadProvider, original.vadProvider)
        XCTAssertEqual(decoded.thermalThrottleThreshold, original.thermalThrottleThreshold)
    }

    func testCodableRoundTrip_preservesPrivacyFirstEnumRawValues() throws {
        // Privacy-first uses the int16 depth and critical threshold, which differ from the
        // defaults, so a broken enum coding would surface here even if the default round-trips.
        let original = AudioEngineConfig.privacyFirst
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AudioEngineConfig.self, from: data)

        XCTAssertEqual(decoded.bitDepth, .int16)
        XCTAssertEqual(decoded.thermalThrottleThreshold, .critical)
        XCTAssertFalse(decoded.enableAdaptiveQuality)
        XCTAssertEqual(decoded.sampleRate, 16000)
    }

    // MARK: - AudioEngineError descriptions

    func testErrorDescription_returnsDocumentedUserFacingStrings() {
        let cases: [(AudioEngineError, String)] = [
            (.audioSessionConfigurationFailed("mic busy"),
             "Audio session configuration failed: mic busy"),
            (.engineStartFailed("no input"),
             "Audio engine start failed: no input"),
            (.voiceProcessingNotAvailable,
             "Voice processing is not available on this device"),
            (.invalidConfiguration("bad rate"),
             "Invalid audio configuration: bad rate"),
            (.notRunning,
             "Audio engine is not running"),
            (.alreadyRunning,
             "Audio engine is already running"),
            (.playbackFailed("buffer empty"),
             "Audio playback failed: buffer empty"),
            (.bufferConversionFailed,
             "Failed to convert audio data to playable buffer")
        ]

        for (error, expected) in cases {
            XCTAssertEqual(
                error.errorDescription,
                expected,
                "errorDescription mismatch for \(error)"
            )
        }
    }
}
