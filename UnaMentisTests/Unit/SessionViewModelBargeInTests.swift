// UnaMentis - SessionViewModel Barge-In Adoption Tests
// Validates that the direct-streaming barge-in path drives the single
// BargeInDetector: detector events produce the pause/stop/resume state
// transitions. Real AVAudioPlayer behavior is validated on device; this covers
// the event -> state wiring (audioPlayer is nil here, so its ops are no-ops).

import XCTest
import AVFoundation
@testable import UnaMentis

@MainActor
final class SessionViewModelBargeInTests: XCTestCase {

    private func frame() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        buffer.frameLength = 512
        return buffer
    }

    func testOnsetFrameIsCollectedAndSilenceClears() async {
        // The buffer collection is synchronous in handleVADResult; the detector is
        // nil here so its arm/process are no-ops, isolating the collection logic.
        let vm = SessionViewModel()
        vm.state = .aiSpeaking
        vm.isDirectStreamingMode = true
        vm.isTentativeBargeIn = false

        // A likely-user-speech frame (above threshold) is collected from the onset.
        await vm._testHandleVADResult(buffer: frame(), vadResult: VADResult(isSpeech: true, confidence: 0.9))
        XCTAssertEqual(vm._testBargeInBufferCount, 1, "the barge-in onset frame must be captured")

        // A below-threshold frame while not yet tentative resets collection.
        await vm._testHandleVADResult(buffer: frame(), vadResult: VADResult(isSpeech: false, confidence: 0.1))
        XCTAssertEqual(vm._testBargeInBufferCount, 0, "stray pre-barge-in audio is dropped")
    }

    func testTentativeEventPausesToInterrupted() async {
        let vm = SessionViewModel()
        vm.state = .aiSpeaking
        vm.isDirectStreamingMode = true
        vm.isTentativeBargeIn = false

        await vm._testDispatchBargeInEvent(.tentative)

        XCTAssertEqual(vm.state, .interrupted)
        XCTAssertTrue(vm.isTentativeBargeIn)
    }

    func testConfirmedEventStopsToUserSpeaking() async {
        let vm = SessionViewModel()
        vm.state = .interrupted
        vm.isTentativeBargeIn = true

        await vm._testDispatchBargeInEvent(.confirmed)

        XCTAssertEqual(vm.state, .userSpeaking)
        XCTAssertFalse(vm.isTentativeBargeIn)
    }

    func testResumedEventReturnsToAiSpeaking() async {
        let vm = SessionViewModel()
        vm.state = .interrupted
        vm.isTentativeBargeIn = true

        await vm._testDispatchBargeInEvent(.resumed)

        XCTAssertEqual(vm.state, .aiSpeaking)
        XCTAssertFalse(vm.isTentativeBargeIn)
    }

    func testTentativeIgnoredWhenNotDirectStreaming() async {
        // A stale tentative that arrives when no longer in direct-streaming
        // playback must be dropped, not corrupt the state into .interrupted.
        let vm = SessionViewModel()
        vm.state = .aiSpeaking
        vm.isDirectStreamingMode = false
        vm.isTentativeBargeIn = false

        await vm._testDispatchBargeInEvent(.tentative)

        XCTAssertEqual(vm.state, .aiSpeaking, "stale tentative must not pause")
        XCTAssertFalse(vm.isTentativeBargeIn)
    }
}
