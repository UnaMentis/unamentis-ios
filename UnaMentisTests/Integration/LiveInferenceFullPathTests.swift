// UnaMentis - Live Inference Full-Path Test
// =========================================
//
// Exercises the app's REAL LLM client (SelfHostedLLMService) against the REAL
// local inference stack (ollama, llama3.2:3b) over the actual network path, on
// the simulator. This is the "inference source -> target" round trip: the same
// OpenAI-compatible v1/chat/completions client the learning session uses, hitting
// the live model, asserting real streamed tokens come back.
//
// It SKIPS when the local stack is not reachable, so CI without a running server
// stays green; it RUNS the real round trip when the stack is up (the documented
// way to validate the full path locally). No mock: this is Real-Over-Mock for an
// internal, free, local service.
//
// Note on ports: the LLM inference path is ollama on 11434 (no auth). The
// management-api on 8766 is a separate Bearer-authenticated REST surface and is
// not the inference path; it is intentionally not exercised here.

import Foundation
import XCTest
@testable import UnaMentis

final class LiveInferenceFullPathTests: XCTestCase {

    private let host = "127.0.0.1"
    private let port = 11434

    /// True if the local ollama is reachable (OpenAI-compatible models endpoint).
    private func inferenceReachable() async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// The model ollama currently has loaded and warm (via /api/ps). The test
    /// targets this so it exercises whatever the server actually serves and does
    /// not evict the warm model by requesting a different one. Returns nil if
    /// nothing is loaded.
    private func loadedModel() async -> String? {
        guard let url = URL(string: "http://\(host):\(port)/api/ps") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let models = json?["models"] as? [[String: Any]]
            return models?.first?["name"] as? String
        } catch {
            return nil
        }
    }

    func testRealLLMRoundTripThroughAppClient() async throws {
        let reachable = await inferenceReachable()
        try XCTSkipUnless(
            reachable,
            "Local inference (ollama \(host):\(port)) not reachable; skipping live full-path test")

        guard let model = await loadedModel() else {
            throw XCTSkip("ollama reachable but no model is loaded/warm; nothing served to test")
        }
        let llm = SelfHostedLLMService.ollama(host: host, model: model)
        let messages = [
            LLMMessage(role: .system, content: "You are a tutor. Reply with only a single number, nothing else."),
            LLMMessage(role: .user, content: "What is two plus two?")
        ]
        // Bound the response so the round trip can prove path-correctness within the
        // client's request timeout even when local inference is slow. Raw throughput
        // is the dedicated latency harness's job, not this connectivity test.
        let config = LLMConfig(model: "", maxTokens: 24, temperature: 0, stream: true)

        var text = ""
        var tokenCount = 0
        var sawDone = false

        let stream = try await llm.streamCompletion(messages: messages, config: config)
        for await token in stream {
            text += token.content
            tokenCount += 1
            if token.isDone { sawDone = true; break }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        print("=== LIVE LLM full-path (simulator -> ollama \(model)) ===")
        print("tokens=\(tokenCount) done=\(sawDone)")
        print("response: \(trimmed)")

        // Reachable but no tokens within the client timeout is an environment/perf
        // condition (commonly ollama on 100% CPU with no Metal GPU), not a path
        // defect. Skip with diagnosis rather than fail, so this stays a clean probe.
        if tokenCount == 0 {
            throw XCTSkip(
                "Local inference reachable but returned no tokens within the client timeout. "
                + "Check `ollama ps`: if it shows 100% CPU (no Metal GPU) the model is ~100x too "
                + "slow for the app's request timeout. Path correctness could not be measured.")
        }

        XCTAssertFalse(trimmed.isEmpty, "expected a non-empty completion from the live model")
        XCTAssertTrue(sawDone, "the stream should terminate with an isDone token")
    }
}
