// UnaMentis - Session Engine-Path Integration Tests
//
// Drives the COMPLETE chat engine path through SessionManager with a real (but
// headless) AudioEngine and mocked paid services (LLM, TTS), without the
// microphone: user utterance -> LLM stream -> sentence split -> TTS orchestrator
// -> playback completion -> back to userSpeaking -> next turn.
//
// This is the per-surface, simulator-runnable safety net for the class of bug hit
// on device (a second turn duplicating the first). Unlike the pure-unit chat tests
// that force state between turns, this lets the turn complete on its own through
// real playback, so it also proves the turn returns to userSpeaking naturally and
// the dedup guard resets without being forced.

import XCTest
@testable import UnaMentis

@MainActor
final class SessionEnginePathTests: XCTestCase {

    private var audioEngine: AudioEngine!
    private var mockVAD: MockVADService!
    private var telemetry: TelemetryEngine!

    override func setUp() async throws {
        try await super.setUp()
        mockVAD = MockVADService()
        telemetry = TelemetryEngine()
        audioEngine = AudioEngine(config: .default, vadService: mockVAD, telemetry: telemetry)
        try await audioEngine.configure(config: .default)
        try await audioEngine.start()
    }

    override func tearDown() async throws {
        await audioEngine.stop()
        audioEngine = nil
        mockVAD = nil
        telemetry = nil
        try await super.tearDown()
    }

    private func waitUntil(_ predicate: @escaping () -> Bool, maxPolls: Int = 600) async {
        for _ in 0..<maxPolls {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }

    func testTwoTurnsThroughFullEnginePath_noDuplication_returnsToUserSpeaking() async {
        let mockLLM = MockLLMService()
        await mockLLM.configure(summaryResponse: "Sure thing.")
        let mockTTS = MockTTSService()

        let manager = SessionManager(telemetry: telemetry)
        manager._testInjectServices(llm: mockLLM, tts: mockTTS, audioEngine: audioEngine)
        await manager._testForceState(.userSpeaking)

        // Turn 1: runs through LLM -> TTS -> playback completion on its own.
        await manager.injectUserUtterance("first question")
        await waitUntil {
            manager.state == .userSpeaking &&
            manager._testConversationHistory.contains { $0.role == .assistant }
        }
        XCTAssertEqual(manager.state, .userSpeaking,
                       "turn 1 must complete through playback and return to userSpeaking on its own")

        // Turn 2: NOT forced - it can only proceed because turn 1 reset cleanly.
        await manager.injectUserUtterance("second question")
        await waitUntil {
            manager._testConversationHistory.filter { $0.role == .assistant }.count >= 2
        }

        let history = manager._testConversationHistory
        let userContents = history.filter { $0.role == .user }.map(\.content)
        let assistantCount = history.filter { $0.role == .assistant }.count
        XCTAssertEqual(userContents, ["first question", "second question"],
                       "two turns, each user utterance recorded exactly once")
        XCTAssertEqual(assistantCount, 2, "exactly one AI response per turn")
    }

    func testRapidDuplicateUtteranceStillProcessesOnceThroughEnginePath() async {
        let mockLLM = MockLLMService()
        await mockLLM.configure(summaryResponse: "Acknowledged.")
        let mockTTS = MockTTSService()

        let manager = SessionManager(telemetry: telemetry)
        manager._testInjectServices(llm: mockLLM, tts: mockTTS, audioEngine: audioEngine)
        await manager._testForceState(.userSpeaking)

        // Both completion paths firing for one utterance, through the real path.
        await manager.injectUserUtterance("only once please")
        await manager.injectUserUtterance("only once please")

        await waitUntil { manager._testConversationHistory.contains { $0.role == .assistant } }
        // Let any erroneous second turn have time to appear (it must not).
        await waitUntil { manager.state == .userSpeaking }

        let users = manager._testConversationHistory.filter { $0.role == .user && $0.content == "only once please" }
        XCTAssertEqual(users.count, 1, "the duplicate completion must not produce a second turn")
    }
}
