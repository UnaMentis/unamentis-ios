// UnaMentis - Barge-In Responder Tests
// Verifies the shared conversational barge-in layer: commands route to execute,
// engagements run the pause -> filler -> LLM -> TTS -> resume loop in order, and
// the surface always resumes even if the LLM/TTS fails.

import XCTest
@testable import UnaMentis

/// Records the responder's delegate callbacks for assertions. Not a Mock of a
/// paid external API; it is a test spy for the in-process delegate contract.
@MainActor
final class RecordingBargeInDelegate: BargeInResponderDelegate {
    var events: [String] = []
    var playedChunks = 0
    var executedCommand: VoiceCommand?
    var responseText: String?
    var fillerToReturn: TTSAudioChunk?

    func bargeInExecuteCommand(_ command: VoiceCommand) async {
        events.append("command:\(command.rawValue)")
        executedCommand = command
    }
    func bargeInWillRespond() async { events.append("willRespond") }
    func bargeInPlay(_ chunk: TTSAudioChunk) async { events.append("play"); playedChunks += 1 }
    func bargeInDidRespond(responseText text: String) async {
        events.append("didRespond")
        responseText = text
    }
    func bargeInFiller(forUtterance utterance: String) async -> TTSAudioChunk? {
        fillerToReturn
    }
}

final class BargeInResponderTests: XCTestCase {

    private func chunk() -> TTSAudioChunk {
        TTSAudioChunk(audioData: Data([1, 2, 3, 4]),
                      format: .pcmFloat32(sampleRate: 24_000, channels: 1),
                      sequenceNumber: 0, isFirst: true, isLast: true)
    }

    @MainActor
    func testCommandRoutesToExecuteAndSkipsLLM() async {
        let delegate = RecordingBargeInDelegate()
        let responder = BargeInResponder(validCommands: [.bookmark, .flag]) { _ in "system" }
        await responder.setDelegate(delegate)
        let llm = MockLLMService()
        let tts = MockTTSService()

        let result = await responder.handle(transcript: "bookmark this", llm: llm, tts: tts)

        XCTAssertEqual(result.category, .command)
        XCTAssertEqual(delegate.executedCommand, .bookmark)
        XCTAssertEqual(delegate.events, ["command:bookmark"])
        let llmCalls = await llm.streamCompletionCallCount
        XCTAssertEqual(llmCalls, 0, "a command must not call the LLM")
    }

    @MainActor
    func testEngagementRunsResponseLoopInOrder() async {
        let delegate = RecordingBargeInDelegate()
        let responder = BargeInResponder { _ in "Answer the question." }
        await responder.setDelegate(delegate)
        let llm = MockLLMService()
        await llm.configure(summaryResponse: "The sky is blue because of Rayleigh scattering.")
        let tts = MockTTSService()

        let result = await responder.handle(transcript: "why is the sky blue?", llm: llm, tts: tts)

        XCTAssertEqual(result.category, .engagement)
        XCTAssertEqual(delegate.events, ["willRespond", "play", "didRespond"])
        XCTAssertEqual(delegate.playedChunks, 1)
        XCTAssertEqual(delegate.responseText, "The sky is blue because of Rayleigh scattering.")
        let llmCalls = await llm.streamCompletionCallCount
        XCTAssertEqual(llmCalls, 1)
    }

    @MainActor
    func testEngagementLeadsWithFillerWhenProvided() async {
        let delegate = RecordingBargeInDelegate()
        delegate.fillerToReturn = chunk()
        let responder = BargeInResponder { _ in "system" }
        await responder.setDelegate(delegate)
        let llm = MockLLMService()
        let tts = MockTTSService()

        await responder.handle(transcript: "can you explain that differently", llm: llm, tts: tts)

        // Filler plays first, then the response chunk(s).
        XCTAssertEqual(delegate.events.first, "willRespond")
        XCTAssertEqual(delegate.events.dropFirst().first, "play", "filler plays before the LLM answer")
        XCTAssertGreaterThanOrEqual(delegate.playedChunks, 2, "filler + at least one response chunk")
        XCTAssertEqual(delegate.events.last, "didRespond")
    }

    @MainActor
    func testEngagementResumesEvenWhenLLMErrors() async {
        let delegate = RecordingBargeInDelegate()
        let responder = BargeInResponder { _ in "system" }
        await responder.setDelegate(delegate)
        let llm = MockLLMService()
        await llm.configureToFail(with: .connectionFailed("boom"))
        let tts = MockTTSService()

        await responder.handle(transcript: "what does that word mean", llm: llm, tts: tts)

        // Must still hand control back so narration resumes.
        XCTAssertEqual(delegate.events.first, "willRespond")
        XCTAssertEqual(delegate.events.last, "didRespond")
        XCTAssertEqual(delegate.playedChunks, 0, "no audio when the LLM failed")
    }
}
