//
//  KBOnDeviceTTSTests.swift
//  UnaMentisTests
//
//  Tests for KBOnDeviceTTS text-to-speech service
//

import AVFoundation
import XCTest
@testable import UnaMentis

@MainActor
final class KBOnDeviceTTSTests: XCTestCase {

    // MARK: - Initialization Tests

    func testInit_startsWithDefaultState() async {
        let tts = KBOnDeviceTTS()

        let speaking = await tts.isSpeaking
        let paused = await tts.isPaused
        let progress = await tts.progress
        XCTAssertFalse(speaking)
        XCTAssertFalse(paused)
        XCTAssertEqual(progress, 0)
    }

    // MARK: - VoiceConfig Tests

    func testVoiceConfig_defaultValues() {
        let config = KBOnDeviceTTS.VoiceConfig()

        XCTAssertEqual(config.language, "en-US")
        XCTAssertEqual(config.rate, AVSpeechUtteranceDefaultSpeechRate)
        XCTAssertEqual(config.pitchMultiplier, 1.0)
        XCTAssertEqual(config.volume, 1.0)
        XCTAssertEqual(config.preUtteranceDelay, 0)
        XCTAssertEqual(config.postUtteranceDelay, 0)
    }

    func testVoiceConfig_questionPace_hasSlowerRate() {
        let config = KBOnDeviceTTS.VoiceConfig.questionPace

        XCTAssertLessThan(config.rate, AVSpeechUtteranceDefaultSpeechRate)
        XCTAssertEqual(config.pitchMultiplier, 1.0)
    }

    func testVoiceConfig_slowPace_hasSlowRate() {
        let config = KBOnDeviceTTS.VoiceConfig.slowPace

        XCTAssertLessThan(config.rate, KBOnDeviceTTS.VoiceConfig.questionPace.rate)
    }

    func testVoiceConfig_fastPace_hasFasterRate() {
        let config = KBOnDeviceTTS.VoiceConfig.fastPace

        XCTAssertGreaterThan(config.rate, AVSpeechUtteranceDefaultSpeechRate)
    }

    func testVoiceConfig_paceOrder_slowToFast() {
        let slow = KBOnDeviceTTS.VoiceConfig.slowPace.rate
        let question = KBOnDeviceTTS.VoiceConfig.questionPace.rate
        let fast = KBOnDeviceTTS.VoiceConfig.fastPace.rate

        XCTAssertLessThan(slow, question)
        XCTAssertLessThan(question, fast)
    }

    // MARK: - Stop Tests

    func testStop_resetsState() async {
        let tts = KBOnDeviceTTS()

        await tts.stop()

        let speaking = await tts.isSpeaking
        let paused = await tts.isPaused
        let progress = await tts.progress
        XCTAssertFalse(speaking)
        XCTAssertFalse(paused)
        XCTAssertEqual(progress, 0)
    }

    // MARK: - Pause/Resume Tests

    func testPause_whenNotSpeaking_doesNothing() async {
        let tts = KBOnDeviceTTS()

        await tts.pause()

        // Should not change to paused if not speaking
        let paused = await tts.isPaused
        XCTAssertFalse(paused)
    }

    func testResume_whenNotPaused_doesNothing() async {
        let tts = KBOnDeviceTTS()

        await tts.resume()

        // Should be safe to call when not paused
        let paused = await tts.isPaused
        XCTAssertFalse(paused)
    }

    // MARK: - Available Voices Tests

    func testAvailableVoices_returnsVoicesForLanguage() {
        let voices = KBOnDeviceTTS.availableVoices(for: "en-US")

        // Should have at least one English voice
        XCTAssertGreaterThan(voices.count, 0)

        // All returned voices should be for English
        for voice in voices {
            XCTAssertTrue(voice.language.hasPrefix("en"))
        }
    }

    func testAvailableVoices_withDefaultLanguage_returnsEnglishVoices() {
        let voices = KBOnDeviceTTS.availableVoices()

        XCTAssertGreaterThan(voices.count, 0)
        // The default language is en-US, so every returned voice must be English.
        for voice in voices {
            XCTAssertTrue(voice.language.hasPrefix("en"))
        }
    }

    func testAvailableVoices_filtersStrictlyByLanguagePrefix() {
        // The real contract is the two-letter prefix filter, not "does not crash".
        // An obscure code yields only voices whose language starts with that prefix
        // (typically none on a normal device, but the invariant must always hold).
        let voices = KBOnDeviceTTS.availableVoices(for: "zz-ZZ")

        for voice in voices {
            XCTAssertTrue(voice.language.hasPrefix("zz"))
        }

        // Spanish voices ship on iOS; assert the filter does not leak other languages.
        let spanish = KBOnDeviceTTS.availableVoices(for: "es-ES")
        for voice in spanish {
            XCTAssertTrue(voice.language.hasPrefix("es"))
            XCTAssertFalse(voice.language.hasPrefix("en"))
        }
    }

    func testBestVoice_returnsVoiceForLanguage() {
        let voice = KBOnDeviceTTS.bestVoice(for: "en-US")

        // Should return a voice on any iOS device
        XCTAssertNotNil(voice)
        XCTAssertTrue(voice!.language.hasPrefix("en"))
    }

    func testBestVoice_withDefaultLanguage_returnsEnglishVoice() {
        let voice = KBOnDeviceTTS.bestVoice()

        XCTAssertNotNil(voice)
        XCTAssertTrue(voice?.language.hasPrefix("en") ?? false)
    }

    func testBestVoice_prefersEnhancedWhenAvailable() {
        // The selection contract: if any enhanced-quality voice exists for the
        // language, bestVoice MUST return an enhanced one. Assert the real branch
        // taken instead of merely checking for non-nil.
        let available = KBOnDeviceTTS.availableVoices(for: "en-US")
        let hasEnhanced = available.contains { $0.quality == .enhanced }

        let voice = KBOnDeviceTTS.bestVoice(for: "en-US")
        XCTAssertNotNil(voice)

        if hasEnhanced {
            XCTAssertEqual(voice?.quality, .enhanced)
        }
    }

    // MARK: - Preview Support Tests

    #if DEBUG
    func testPreview_createsValidInstance() async {
        let tts = KBOnDeviceTTS.preview()

        let speaking = await tts.isSpeaking
        XCTAssertFalse(speaking)
    }
    #endif

    // MARK: - State Consistency Tests

    func testState_afterMultipleStopCalls_remainsConsistent() async {
        let tts = KBOnDeviceTTS()

        // Multiple stops should be safe
        await tts.stop()
        await tts.stop()
        await tts.stop()

        let speaking = await tts.isSpeaking
        let paused = await tts.isPaused
        let progress = await tts.progress
        XCTAssertFalse(speaking)
        XCTAssertFalse(paused)
        XCTAssertEqual(progress, 0)
    }

    func testState_pauseResumeSequence_whenNotSpeaking() async {
        let tts = KBOnDeviceTTS()

        // These should all be no-ops when not speaking
        await tts.pause()
        await tts.resume()
        await tts.pause()
        await tts.resume()

        let speaking = await tts.isSpeaking
        let paused = await tts.isPaused
        XCTAssertFalse(speaking)
        XCTAssertFalse(paused)
    }

    // MARK: - Configuration Tests

    func testVoiceConfig_customConfiguration() {
        let config = KBOnDeviceTTS.VoiceConfig(
            language: "en-GB",
            rate: 0.5,
            pitchMultiplier: 1.2,
            volume: 0.8,
            preUtteranceDelay: 0.5,
            postUtteranceDelay: 1.0
        )

        XCTAssertEqual(config.language, "en-GB")
        XCTAssertEqual(config.rate, 0.5)
        XCTAssertEqual(config.pitchMultiplier, 1.2)
        XCTAssertEqual(config.volume, 0.8)
        XCTAssertEqual(config.preUtteranceDelay, 0.5)
        XCTAssertEqual(config.postUtteranceDelay, 1.0)
    }

    // MARK: - Speech Rate Validation Tests

    func testSpeechRates_areWithinValidRange() {
        // AVSpeechUtterance rate should be between 0 and 1
        let slow = KBOnDeviceTTS.VoiceConfig.slowPace.rate
        let question = KBOnDeviceTTS.VoiceConfig.questionPace.rate
        let fast = KBOnDeviceTTS.VoiceConfig.fastPace.rate

        XCTAssertGreaterThan(slow, AVSpeechUtteranceMinimumSpeechRate)
        XCTAssertLessThan(fast, AVSpeechUtteranceMaximumSpeechRate)

        XCTAssertGreaterThan(question, AVSpeechUtteranceMinimumSpeechRate)
        XCTAssertLessThan(question, AVSpeechUtteranceMaximumSpeechRate)
    }

    // MARK: - Volume and Pitch Tests

    func testVoiceConfig_volumeAndPitch_areNormalized() {
        let configs: [KBOnDeviceTTS.VoiceConfig] = [
            .questionPace,
            .slowPace,
            .fastPace
        ]

        for config in configs {
            // Volume should be between 0 and 1
            XCTAssertGreaterThanOrEqual(config.volume, 0)
            XCTAssertLessThanOrEqual(config.volume, 1)

            // Pitch multiplier should be reasonable (0.5 to 2.0 typical range)
            XCTAssertGreaterThan(config.pitchMultiplier, 0)
            XCTAssertLessThanOrEqual(config.pitchMultiplier, 2)
        }
    }
}
