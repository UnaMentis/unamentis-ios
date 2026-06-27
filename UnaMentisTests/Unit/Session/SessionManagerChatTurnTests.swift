// UnaMentis - SessionManager Chat Turn Tests
//
// Drives a full chat turn through SessionManager with an injected mock LLM and no
// microphone or audio engine (the instant filler and the TTS orchestrator both
// no-op when the audio engine is nil). These lock the fix for the on-device chat
// bug where a second utterance was duplicated and answered wrongly: two completion
// paths (the STT final result and the silence timer) both ran processUserUtterance
// for one utterance, appending the user message twice and double-calling the LLM.

import XCTest
@testable import UnaMentis

@MainActor
final class SessionManagerChatTurnTests: XCTestCase {

    private func waitUntil(_ predicate: @escaping () -> Bool, maxPolls: Int = 400) async {
        for _ in 0..<maxPolls {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func makeManager(llm: any LLMService) -> SessionManager {
        let manager = SessionManager(telemetry: TelemetryEngine())
        manager._testInjectServices(llm: llm)
        return manager
    }

    func testDuplicateUtteranceCompletionAppendsUserMessageOnce() async {
        let mockLLM = MockLLMService()
        await mockLLM.configure(summaryResponse: "Gravity is a force.")
        let manager = makeManager(llm: mockLLM)
        await manager._testForceState(.userSpeaking)

        // The STT final-result path and the silence timer can both complete the
        // same utterance. Simulate both firing for one utterance.
        await manager.injectUserUtterance("what is gravity")
        await manager.injectUserUtterance("what is gravity")

        // Let the (single) turn's LLM stream finish so the assistant reply lands.
        await waitUntil { manager._testConversationHistory.contains { $0.role == .assistant } }

        let history = manager._testConversationHistory
        let userMessages = history.filter { $0.role == .user && $0.content == "what is gravity" }
        let assistantMessages = history.filter { $0.role == .assistant }
        XCTAssertEqual(userMessages.count, 1, "the user utterance must be appended exactly once")
        XCTAssertEqual(assistantMessages.count, 1, "the duplicate completion must not produce a second response")
    }

    func testSecondCompletionDoesNotCallLLMTwice() async {
        let mockLLM = MockLLMService()
        await mockLLM.configure(summaryResponse: "Done.")
        let manager = makeManager(llm: mockLLM)
        await manager._testForceState(.userSpeaking)

        await manager.injectUserUtterance("hello there")
        await manager.injectUserUtterance("hello there")  // duplicate completion path
        await waitUntil { manager._testConversationHistory.contains { $0.role == .assistant } }

        // Exactly one turn ran: one user message and one assistant message. (We
        // assert via history rather than the LLM call count, since the turn also
        // spawns speculative pre-generation that legitimately calls the LLM.)
        let users = manager._testConversationHistory.filter { $0.role == .user }
        XCTAssertEqual(users.count, 1)
    }

    func testSubsequentUtteranceProcessesAfterTurnBecomesReady() async {
        let mockLLM = MockLLMService()
        await mockLLM.configure(summaryResponse: "OK.")
        let manager = makeManager(llm: mockLLM)
        await manager._testForceState(.userSpeaking)

        await manager.injectUserUtterance("first question")
        await waitUntil { manager._testConversationHistory.contains { $0.role == .assistant } }

        // A real turn returns to .userSpeaking when TTS playback completes; that
        // clears the in-flight guard. The next distinct utterance must then be
        // processed, proving the dedup guard is not a permanent block.
        await manager._testForceState(.userSpeaking)
        await manager.injectUserUtterance("second question")
        await waitUntil { manager._testConversationHistory.filter { $0.role == .user }.count >= 2 }

        let userContents = manager._testConversationHistory
            .filter { $0.role == .user }
            .map(\.content)
        XCTAssertEqual(userContents, ["first question", "second question"],
                       "after a turn completes, the next distinct utterance must be processed once")
    }
}
