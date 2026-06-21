// UnaMentis - Barge-In Coordinator Audio-Path Integration Test
// ============================================================
//
// Proves the FULL audio path INTO THE APP, in the simulator, with no hardware
// mic and no device:
//
//   injected audio -> AudioEngine.processAudioBuffer (the exact method the mic
//   tap calls) -> Silero VAD -> AudioEngine.audioStream (Combine) ->
//   BargeInCoordinator -> the surface (pause / execute command / answer + resume)
//
// This is the wiring the reader and the session use. The measurement harness
// (BargeInMeasurementHarness / BargeInMeasurementTests) exercises the detector
// directly; this exercises the app glue AROUND it through the real engine and
// the real Combine subscription, which is what "I barged in and it ignored me"
// is actually about.
//
// What this deterministically verifies on the simulator:
//   - real speech frames flowing through the engine TRIGGER a barge-in (pause)
//   - a command barge-in is EXECUTED on the surface (command routing)
//   - a conversational barge-in is ANSWERED (LLM + TTS) and narration RESUMES
//   - background noise does NOT cause a committed barge-in (no false action)
//
// What it does NOT cover (device remains the source of truth): real microphone
// capture latency, speaker echo into the mic, and the real on-device STT. STT is
// supplied here by a deterministic mock so command-vs-engagement routing can be
// tested without recognition; detection itself needs no transcript.

import AVFoundation
import XCTest
@testable import UnaMentis

@MainActor
final class BargeInCoordinatorAudioPathTests: XCTestCase {

    // MARK: - Spy surface

    /// Records exactly what the coordinator asked the surface to do.
    private final class SpySurface: BargeInSurface {
        private(set) var pauseCount = 0
        private(set) var resumeCount = 0
        private(set) var executed: [VoiceCommand] = []
        private(set) var played = 0

        func bargeInPauseNarration() async { pauseCount += 1 }
        func bargeInResumeNarration() async { resumeCount += 1 }
        func bargeInExecute(command: VoiceCommand) async { executed.append(command) }
        func bargeInPlay(chunk: TTSAudioChunk) async { played += 1 }
    }

    // MARK: - Fixtures

    /// Build a real AudioEngine with a prepared Silero VAD, WITHOUT start()/configure()
    /// so there is no audio session and no hardware mic tap. We inject buffers
    /// straight into processAudioBuffer, which is exactly what the tap callback does.
    private func makeEngineWithPreparedVAD() async -> AudioEngine {
        let vad = SileroVADService()
        try? await vad.prepare()
        return AudioEngine(config: .default, vadService: vad, telemetry: TelemetryEngine())
    }

    private func makeCoordinator(
        engine: AudioEngine,
        surface: BargeInSurface
    ) -> BargeInCoordinator {
        BargeInCoordinator(
            audioEngine: engine,
            llm: MockLLMService(),
            tts: MockTTSService(),
            validCommands: [.bookmark, .flag],
            systemPrompt: { _ in "You are a helpful reading assistant." },
            surface: surface
        )
    }

    /// Generate real on-device TTS speech (what the VAD reliably detects as speech).
    private func speechBuffer(_ text: String) async throws -> AVAudioPCMBuffer {
        try await KBAudioGenerator().generateAudio(for: text, using: .pocketTTS).buffer
    }

    // MARK: - Injection

    /// Feed a buffer through the engine in real-time-paced 512-sample frames,
    /// exactly as the mic tap delivers it. Real-time pacing matters: the detector's
    /// 600ms confirmation timer and the coordinator's 1.0s end-of-utterance timer
    /// are wall-clock, so frames must advance wall-clock to make them fire.
    private func injectFrames(_ buffer: AVAudioPCMBuffer, into engine: AudioEngine) async {
        let frameSize: AVAudioFrameCount = 512
        var position: AVAudioFrameCount = 0
        while position < buffer.frameLength {
            if let frame = Self.slice(buffer, from: position, count: frameSize) {
                await engine.processAudioBuffer(frame)
            }
            position += frameSize
            try? await Task.sleep(nanoseconds: 32_000_000)
        }
    }

    /// An utterance = speech, then enough trailing silence for the coordinator to
    /// declare end-of-utterance (1.0s) and classify, then a small grace for the
    /// LLM/TTS response to run.
    private func injectUtterance(_ speech: AVAudioPCMBuffer, into engine: AudioEngine) async {
        await injectFrames(speech, into: engine)
        await injectFrames(Self.silence(seconds: 1.6), into: engine)
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    // MARK: - Tests

    func testCommandSpeechThroughEngineTriggersAndExecutes() async throws {
        let engine = await makeEngineWithPreparedVAD()
        // STT supplies the transcript the coordinator classifies. Detection needs none.
        try await engine.attachSTT(MockTranscriptSTTService(fixedTranscript: "bookmark this"))

        let spy = SpySurface()
        let coordinator = makeCoordinator(engine: engine, surface: spy)
        await coordinator.start()

        let speech = try await speechBuffer("bookmark this")
        await injectUtterance(speech, into: engine)
        await coordinator.stop()

        XCTAssertGreaterThan(spy.pauseCount, 0,
                             "speech through the engine must trigger a barge-in pause")
        XCTAssertTrue(spy.executed.contains(.bookmark),
                      "a command barge-in must execute the command on the surface (got \(spy.executed))")
    }

    func testEngagementSpeechThroughEngineAnswersAndResumes() async throws {
        let engine = await makeEngineWithPreparedVAD()
        try await engine.attachSTT(MockTranscriptSTTService(fixedTranscript: "why does that happen"))

        let spy = SpySurface()
        let coordinator = makeCoordinator(engine: engine, surface: spy)
        await coordinator.start()

        let speech = try await speechBuffer("why does that happen")
        await injectUtterance(speech, into: engine)
        await coordinator.stop()

        XCTAssertGreaterThan(spy.pauseCount, 0,
                             "a conversational barge-in must pause narration")
        XCTAssertTrue(spy.executed.isEmpty,
                      "an engagement must not be misrouted as a command (got \(spy.executed))")
        XCTAssertGreaterThan(spy.played, 0,
                             "an engagement must produce a spoken answer through the surface")
        XCTAssertGreaterThan(spy.resumeCount, 0,
                             "narration must resume after the engagement is answered")
    }

    func testNoiseThroughEngineDoesNotCommitBargeIn() async throws {
        let engine = await makeEngineWithPreparedVAD()
        let spy = SpySurface()
        let coordinator = makeCoordinator(engine: engine, surface: spy)
        await coordinator.start()

        // ~1.5s of synthetic noise must not become a real barge-in action. A brief
        // tentative that resumes is acceptable; a committed command/answer is not.
        if let noise = BargeInCorpus.syntheticNoise(id: "audio-path-noise", durationSec: 1.5) {
            await injectFrames(noise, into: engine)
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        await coordinator.stop()

        XCTAssertTrue(spy.executed.isEmpty,
                      "background noise must not execute a command (got \(spy.executed))")
        XCTAssertEqual(spy.played, 0,
                       "background noise must not trigger a conversational answer")
    }

    // MARK: - Helpers

    /// 16kHz mono float32 silence of the given duration.
    private static func silence(seconds: Double) -> AVAudioPCMBuffer {
        let sampleRate = 16_000.0
        let count = AVAudioFrameCount(seconds * sampleRate)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        if let channel = buffer.floatChannelData?[0] {
            channel.update(repeating: 0, count: Int(count))
        }
        return buffer
    }

    /// Extract a disconnected [start, start+count) sub-buffer (16kHz mono float32),
    /// safe to hand to an actor. Mirrors the measurement harness's slicer.
    private static func slice(_ buffer: AVAudioPCMBuffer,
                              from start: AVAudioFrameCount,
                              count: AVAudioFrameCount) -> sending AVAudioPCMBuffer? {
        guard start < buffer.frameLength, let src = buffer.floatChannelData?[0] else { return nil }
        let n = min(count, buffer.frameLength - start)
        guard n > 0 else { return nil }
        let samples = Array(UnsafeBufferPointer(start: src + Int(start), count: Int(n)))
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16_000, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n),
              let dst = out.floatChannelData?[0] else { return nil }
        out.frameLength = n
        samples.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress { dst.update(from: base, count: Int(n)) }
        }
        return out
    }
}
