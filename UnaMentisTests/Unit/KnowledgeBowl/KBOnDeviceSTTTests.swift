//
//  KBOnDeviceSTTTests.swift
//  UnaMentisTests
//
//  Tests for KBOnDeviceSTT, the on-device STT adapter that drives the shared
//  AppleSpeechSTTService from the unified AudioEngine.
//
//  NOTE: The legacy KBOnDeviceSTT was a @MainActor ObservableObject exposing
//  isListening/transcript/isFinal/error/authorizationStatus, a stopListening()
//  method, and a dedicated KBSTTError enum. That observable design was removed
//  when the type became a public actor conforming to STTService (the streaming
//  provider abstraction). Tests covering the removed surface were dropped; the
//  tests below target the current actor API and its real contracts.
//

import AVFoundation
import Speech
import XCTest
@testable import UnaMentis

final class KBOnDeviceSTTTests: XCTestCase {

    // MARK: - Availability Tests

    /// KBOnDeviceSTT.isAvailable is documented to delegate to the shared
    /// AppleSpeechSTTService. Assert the delegation contract rather than a
    /// device-dependent absolute value, so the test is deterministic on any
    /// simulator while still protecting the wiring.
    func testIsAvailable_delegatesToAppleSpeechService() {
        XCTAssertEqual(KBOnDeviceSTT.isAvailable, AppleSpeechSTTService.isAvailable)
    }

    // MARK: - Authorization Tests
    //
    // Note: A test that called KBOnDeviceSTT.requestAuthorization() was removed.
    // SFSpeechRecognizer.requestAuthorization presents a system permission dialog
    // on first use; in a headless simulator run no one dismisses it, so the
    // continuation never resumes and the test hangs to its full time allowance.
    // The assertion it carried ("result is one of the four enum cases") was also
    // a tautology over the status type rather than a real contract. The delegation
    // wiring is still protected by testIsAvailable_delegatesToAppleSpeechService.

    // MARK: - Initial State Tests

    /// A freshly constructed adapter must not be streaming and must report the
    /// on-device (free) cost. These are concrete STTService contract values.
    func testInit_startsIdleAndFree() async {
        let stt = KBOnDeviceSTT()

        let isStreaming = await stt.isStreaming
        let cost = await stt.costPerHour

        XCTAssertFalse(isStreaming)
        XCTAssertEqual(cost, Decimal(0))
    }

    // MARK: - Streaming Guard Tests

    /// sendAudio before startStreaming must surface STTError.notStreaming.
    /// This protects the provider abstraction's precondition, a real failure
    /// path that callers depend on.
    func testSendAudio_whenNotStreaming_throwsNotStreaming() async throws {
        let stt = KBOnDeviceSTT()

        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)
        )
        buffer.frameLength = 256

        do {
            try await stt.sendAudio(buffer)
            XCTFail("Expected STTError.notStreaming when not streaming")
        } catch let error as STTError {
            guard case .notStreaming = error else {
                return XCTFail("Expected .notStreaming, got \(error)")
            }
        }
    }

    /// stopStreaming while idle is a documented no-op: it must not throw and
    /// must leave the adapter not streaming.
    func testStopStreaming_whenNotStreaming_isSafeNoOp() async throws {
        let stt = KBOnDeviceSTT()

        try await stt.stopStreaming()

        let isStreaming = await stt.isStreaming
        XCTAssertFalse(isStreaming)
    }

    /// cancelStreaming while idle must not throw and must leave the adapter
    /// not streaming. Repeated cancels must remain consistent.
    func testCancelStreaming_whenIdle_remainsConsistent() async {
        let stt = KBOnDeviceSTT()

        await stt.cancelStreaming()
        await stt.cancelStreaming()

        let isStreaming = await stt.isStreaming
        XCTAssertFalse(isStreaming)
    }

    // MARK: - Preview Support Tests

    #if DEBUG
    /// preview() must return an instance that honors the full initial STTService
    /// contract, not streaming and reporting the on-device (free) cost, so the
    /// preview factory cannot silently drift from a real init.
    func testPreview_createsIdleInstance() async {
        let stt = KBOnDeviceSTT.preview()

        let isStreaming = await stt.isStreaming
        let cost = await stt.costPerHour

        XCTAssertFalse(isStreaming)
        XCTAssertEqual(cost, Decimal(0))
    }
    #endif
}
