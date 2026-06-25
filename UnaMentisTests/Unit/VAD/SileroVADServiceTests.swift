// UnaMentis - Silero VAD Service Tests
//
// Exercises the REAL behavior of SileroVADService, the speech/silence gate at the
// front of the voice pipeline. In the test bundle the CoreML model is absent, so
// prepare() falls back to the deterministic dB-RMS path. These tests assert the
// produced VADResult values for that path:
//   rms -> db = 20*log10(rms), normalized over [-60dB, -20dB], smoothed (running
//   average over smoothingWindow), then compared against configuration.threshold.
// We build REAL AVAudioPCMBuffers (no mocks) at known amplitudes and sample rates
// so the expected confidence is derivable from the source math. We also assert the
// inactive-guard contract (no speech before prepare / after shutdown), that configure
// preserves untouched fields, that the threshold actually gates the decision, that
// resampling from 48kHz still works, and that reset() clears smoothing state.
//
// The VAD value-type suite asserts the real clamp logic, the documented default
// configuration, the provider identifiers/allCases, and the user-facing error strings.

import XCTest
@preconcurrency import AVFoundation
@testable import UnaMentis

// MARK: - Buffer Helper

/// Builds a real 16kHz-or-other mono Float32 PCM buffer filled with the given samples.
/// No mocks: this is genuine AVFoundation audio used to drive the dB-RMS fallback math.
private enum VADTestBuffer {

    /// Create a mono Float32 buffer at `sampleRate` filled with a constant amplitude.
    static func constant(
        sampleRate: Double,
        amplitude: Float,
        frameCount: AVAudioFrameCount = 512
    ) -> AVAudioPCMBuffer {
        samples(sampleRate: sampleRate, frameCount: frameCount) { _ in amplitude }
    }

    /// Create a mono Float32 buffer at `sampleRate` filled with a sine tone.
    static func tone(
        sampleRate: Double,
        amplitude: Float,
        frequency: Float = 440,
        frameCount: AVAudioFrameCount = 512
    ) -> AVAudioPCMBuffer {
        samples(sampleRate: sampleRate, frameCount: frameCount) { i in
            amplitude * sin(2 * Float.pi * frequency * Float(i) / Float(sampleRate))
        }
    }

    /// Create a buffer where each sample is produced by `valueAt`.
    static func samples(
        sampleRate: Double,
        frameCount: AVAudioFrameCount,
        valueAt: (Int) -> Float
    ) -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            fatalError("Failed to build test AVAudioPCMBuffer")
        }
        buffer.frameLength = frameCount
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            channel[i] = valueAt(i)
        }
        return buffer
    }
}

// MARK: - SileroVADService Tests

final class SileroVADServiceTests: XCTestCase {

    /// Make a prepared service. In the test bundle the model is absent, so prepare()
    /// catches the load failure and activates the dB-RMS fallback path.
    private func makePreparedService(
        _ configuration: VADConfiguration = .default
    ) async throws -> SileroVADService {
        let service = SileroVADService(configuration: configuration)
        try await service.prepare()
        return service
    }

    // MARK: Inactive guard

    func testInactiveBeforePrepareReturnsNoSpeech() async {
        let service = SileroVADService()

        let active = await service.isActive
        XCTAssertFalse(active, "Service must not be active before prepare()")

        let buffer = VADTestBuffer.constant(sampleRate: 16000, amplitude: 0.5)
        let result = await service.processBuffer(buffer)

        // Even a loud buffer must produce no speech while inactive (safety contract).
        XCTAssertFalse(result.isSpeech)
        XCTAssertEqual(result.confidence, 0, accuracy: 0.0001)
    }

    func testPrepareActivatesEvenWithoutModel() async throws {
        let service = SileroVADService()
        try await service.prepare()

        let active = await service.isActive
        XCTAssertTrue(active, "prepare() must activate the fallback path when the model is absent")
    }

    func testShutdownDeactivatesAndGuardsProcessing() async throws {
        let service = try await makePreparedService()

        await service.shutdown()
        let active = await service.isActive
        XCTAssertFalse(active)

        let loud = VADTestBuffer.constant(sampleRate: 16000, amplitude: 0.5)
        let result = await service.processBuffer(loud)
        XCTAssertFalse(result.isSpeech, "After shutdown the inactive guard must reject all buffers")
        XCTAssertEqual(result.confidence, 0, accuracy: 0.0001)
    }

    // MARK: dB-RMS fallback decisions

    func testSilenceYieldsNoSpeechAndLowConfidence() async throws {
        let service = try await makePreparedService()

        // All zeros: rms = 0 -> db clamped to -200 -> normalized 0.
        let silence = VADTestBuffer.constant(sampleRate: 16000, amplitude: 0.0)
        let result = await service.processBuffer(silence)

        XCTAssertFalse(result.isSpeech)
        XCTAssertEqual(result.confidence, 0, accuracy: 0.0001)
    }

    func testLoudConstantYieldsSpeechWithHighConfidence() async throws {
        let service = try await makePreparedService()

        // amplitude 0.5 -> rms 0.5 -> db ~ -6.0 -> above -20dB ceiling -> normalized 1.0.
        let loud = VADTestBuffer.constant(sampleRate: 16000, amplitude: 0.5)
        let result = await service.processBuffer(loud)

        XCTAssertTrue(result.isSpeech)
        XCTAssertEqual(result.confidence, 1.0, accuracy: 0.0001,
                       "A -6dB signal saturates the [-60,-20]dB mapping to 1.0")
    }

    func testLoudSineYieldsSpeech() async throws {
        let service = try await makePreparedService()

        // A 0.5-amplitude sine has rms = 0.5/sqrt(2) ~ 0.354 -> db ~ -9dB, which is above
        // the -20dB ceiling, so the [-60,-20]dB mapping saturates to exactly 1.0.
        let tone = VADTestBuffer.tone(sampleRate: 16000, amplitude: 0.5)
        let result = await service.processBuffer(tone)

        XCTAssertTrue(result.isSpeech)
        XCTAssertEqual(result.confidence, 1.0, accuracy: 0.0001,
                       "A -9dB tone saturates the [-60,-20]dB mapping to 1.0")
    }

    func testModerateLevelProducesIntermediateConfidence() async throws {
        let service = try await makePreparedService()

        // amplitude ~0.0158 -> db ~ -36dB -> normalized (-36+60)/40 = 0.6.
        let moderate = VADTestBuffer.constant(sampleRate: 16000, amplitude: 0.015849)
        let result = await service.processBuffer(moderate)

        XCTAssertEqual(result.confidence, 0.6, accuracy: 0.02,
                       "A -36dB signal maps to ~0.6 on the [-60,-20]dB scale")
        XCTAssertTrue(result.isSpeech, "0.6 >= default threshold 0.5 -> speech")
    }

    // MARK: Threshold gating

    func testHighThresholdGatesModerateBufferToSilence() async throws {
        // Same ~-36dB moderate buffer that reads as speech at 0.5 must read as silence at 0.9.
        let service = try await makePreparedService(
            VADConfiguration(threshold: 0.9, contextWindow: 3, smoothingWindow: 5,
                             minSpeechDuration: 0.1, minSilenceDuration: 0.5)
        )

        let moderate = VADTestBuffer.constant(sampleRate: 16000, amplitude: 0.015849)
        let result = await service.processBuffer(moderate)

        XCTAssertEqual(result.confidence, 0.6, accuracy: 0.02)
        XCTAssertFalse(result.isSpeech, "0.6 < threshold 0.9 -> silence")
    }

    func testLowThresholdLetsModerateBufferReadAsSpeech() async throws {
        let service = try await makePreparedService(
            VADConfiguration(threshold: 0.1, contextWindow: 3, smoothingWindow: 5,
                             minSpeechDuration: 0.1, minSilenceDuration: 0.5)
        )

        let moderate = VADTestBuffer.constant(sampleRate: 16000, amplitude: 0.015849)
        let result = await service.processBuffer(moderate)

        XCTAssertEqual(result.confidence, 0.6, accuracy: 0.02)
        XCTAssertTrue(result.isSpeech, "0.6 >= threshold 0.1 -> speech")
    }

    // MARK: Resampling

    func testLoudBufferAt48kHzStillDetectsSpeech() async throws {
        let service = try await makePreparedService()

        // 48kHz loud buffer takes the resample-to-16kHz path then the fallback.
        let loud48k = VADTestBuffer.tone(sampleRate: 48000, amplitude: 0.5, frameCount: 1536)
        let result = await service.processBuffer(loud48k)

        // After resampling the 0.5-amplitude tone keeps an RMS near 0.35 (about -9dB),
        // well above the -20dB ceiling, so the confidence saturates to exactly 1.0.
        XCTAssertTrue(result.isSpeech, "A loud 48kHz buffer must still register as speech after resampling")
        XCTAssertEqual(result.confidence, 1.0, accuracy: 0.0001,
                       "The resampled loud tone stays above the -20dB ceiling and saturates to 1.0")
    }

    func testSilenceAt48kHzStillDetectsNoSpeech() async throws {
        let service = try await makePreparedService()

        let silence48k = VADTestBuffer.constant(sampleRate: 48000, amplitude: 0.0, frameCount: 1536)
        let result = await service.processBuffer(silence48k)

        XCTAssertFalse(result.isSpeech)
        XCTAssertEqual(result.confidence, 0, accuracy: 0.0001)
    }

    func testNoResampleSegmentDurationUsesInputRate() async throws {
        let service = try await makePreparedService()

        // 16kHz, no resample: segmentDuration = frameLength / sampleRate = 512 / 16000.
        let buffer = VADTestBuffer.constant(sampleRate: 16000, amplitude: 0.5, frameCount: 512)
        let result = await service.processBuffer(buffer)

        XCTAssertEqual(result.segmentDuration, 512.0 / 16000.0, accuracy: 0.0001)
    }

    // MARK: Smoothing and reset

    func testSmoothingAveragesAcrossConsecutiveBuffers() async throws {
        // smoothingWindow 5; feed 4 silence frames then 1 loud frame.
        // Smoothed = (0 + 0 + 0 + 0 + 1) / 5 = 0.2, which is below the default 0.5 threshold.
        let service = try await makePreparedService()

        let silence = VADTestBuffer.constant(sampleRate: 16000, amplitude: 0.0)
        for _ in 0..<4 {
            _ = await service.processBuffer(silence)
        }
        let loud = VADTestBuffer.constant(sampleRate: 16000, amplitude: 0.5)
        let result = await service.processBuffer(loud)

        XCTAssertEqual(result.confidence, 0.2, accuracy: 0.01,
                       "Running average of four 0.0 frames and one 1.0 frame is 0.2")
        XCTAssertFalse(result.isSpeech, "Stale silence drags the smoothed value below threshold")
    }

    func testResetClearsStaleSmoothingHistory() async throws {
        let service = try await makePreparedService()

        // Prime the smoothing buffer with silence so a later loud frame would be dragged down.
        let silence = VADTestBuffer.constant(sampleRate: 16000, amplitude: 0.0)
        for _ in 0..<4 {
            _ = await service.processBuffer(silence)
        }

        await service.reset()

        // After reset the loud frame is the only value in the window -> 1.0, not 0.2.
        let loud = VADTestBuffer.constant(sampleRate: 16000, amplitude: 0.5)
        let result = await service.processBuffer(loud)

        XCTAssertEqual(result.confidence, 1.0, accuracy: 0.0001,
                       "reset() clears smoothing history so the new loud frame is not averaged with stale silence")
        XCTAssertTrue(result.isSpeech)
    }

    // MARK: Configuration

    func testConfigureThresholdContextPreservesOtherFields() async throws {
        // Start from a non-default config so we can see which fields survive.
        let initial = VADConfiguration(threshold: 0.5, contextWindow: 3, smoothingWindow: 7,
                                       minSpeechDuration: 0.25, minSilenceDuration: 0.75)
        let service = SileroVADService(configuration: initial)

        await service.configure(threshold: 0.8, contextWindow: 9)
        let config = await service.configuration

        XCTAssertEqual(config.threshold, 0.8, accuracy: 0.0001)
        XCTAssertEqual(config.contextWindow, 9)
        // These three must be preserved from the prior configuration.
        XCTAssertEqual(config.smoothingWindow, 7)
        XCTAssertEqual(config.minSpeechDuration, 0.25, accuracy: 0.0001)
        XCTAssertEqual(config.minSilenceDuration, 0.75, accuracy: 0.0001)
    }

    func testConfigureFullReplacesEntireConfiguration() async throws {
        let service = SileroVADService(configuration: .default)

        let replacement = VADConfiguration(threshold: 0.33, contextWindow: 11, smoothingWindow: 2,
                                           minSpeechDuration: 0.2, minSilenceDuration: 0.9)
        await service.configure(replacement)
        let config = await service.configuration

        XCTAssertEqual(config.threshold, 0.33, accuracy: 0.0001)
        XCTAssertEqual(config.contextWindow, 11)
        XCTAssertEqual(config.smoothingWindow, 2)
        XCTAssertEqual(config.minSpeechDuration, 0.2, accuracy: 0.0001)
        XCTAssertEqual(config.minSilenceDuration, 0.9, accuracy: 0.0001)
    }

    func testSmoothingWindowOfOneDisablesAveraging() async throws {
        // With smoothingWindow 1, each frame stands alone: a loud frame after silence
        // is immediately 1.0 with no averaging.
        let config = VADConfiguration(threshold: 0.5, contextWindow: 3, smoothingWindow: 1,
                                      minSpeechDuration: 0.1, minSilenceDuration: 0.5)
        let service = try await makePreparedService(config)

        let silence = VADTestBuffer.constant(sampleRate: 16000, amplitude: 0.0)
        _ = await service.processBuffer(silence)
        _ = await service.processBuffer(silence)

        let loud = VADTestBuffer.constant(sampleRate: 16000, amplitude: 0.5)
        let result = await service.processBuffer(loud)

        XCTAssertEqual(result.confidence, 1.0, accuracy: 0.0001,
                       "smoothingWindow 1 means no averaging with prior silence")
        XCTAssertTrue(result.isSpeech)
    }
}

// MARK: - VAD Value Type Tests

final class VADValueTypeTests: XCTestCase {

    // MARK: VADResult clamping

    func testVADResultClampsNegativeConfidenceToZero() {
        let result = VADResult(isSpeech: false, confidence: -0.5)
        XCTAssertEqual(result.confidence, 0.0, accuracy: 0.0001)
    }

    func testVADResultClampsAboveOneConfidenceToOne() {
        let result = VADResult(isSpeech: true, confidence: 1.7)
        XCTAssertEqual(result.confidence, 1.0, accuracy: 0.0001)
    }

    func testVADResultPreservesInRangeConfidence() {
        let result = VADResult(isSpeech: true, confidence: 0.42)
        XCTAssertEqual(result.confidence, 0.42, accuracy: 0.0001)
    }

    // MARK: VADConfiguration default

    func testDefaultConfigurationHasDocumentedValues() {
        let config = VADConfiguration.default
        XCTAssertEqual(config.threshold, 0.5, accuracy: 0.0001)
        XCTAssertEqual(config.contextWindow, 3)
        XCTAssertEqual(config.smoothingWindow, 5)
        XCTAssertEqual(config.minSpeechDuration, 0.1, accuracy: 0.0001)
        XCTAssertEqual(config.minSilenceDuration, 0.5, accuracy: 0.0001)
    }

    // MARK: VADProvider

    func testProviderIdentifiers() {
        XCTAssertEqual(VADProvider.silero.identifier, "silero")
        XCTAssertEqual(VADProvider.ten.identifier, "ten")
        XCTAssertEqual(VADProvider.webrtc.identifier, "webrtc")
    }

    func testProviderAllCasesCount() {
        XCTAssertEqual(VADProvider.allCases.count, 3)
        XCTAssertEqual(Set(VADProvider.allCases), [.silero, .ten, .webrtc])
    }

    // MARK: VADError messages

    func testErrorDescriptions() {
        XCTAssertEqual(
            VADError.modelLoadFailed("no file").errorDescription,
            "Failed to load VAD model: no file"
        )
        XCTAssertEqual(
            VADError.processingFailed("bad output").errorDescription,
            "VAD processing failed: bad output"
        )
        XCTAssertEqual(
            VADError.invalidAudioFormat.errorDescription,
            "Invalid audio format for VAD processing"
        )
        XCTAssertEqual(
            VADError.notPrepared.errorDescription,
            "VAD service not prepared. Call prepare() first."
        )
        XCTAssertEqual(
            VADError.configurationError("bad threshold").errorDescription,
            "VAD configuration error: bad threshold"
        )
    }
}
