// UnaMentis - Anthropic LLM streaming parser edge cases
//
// Companion to AnthropicLLMServiceTests. That file covers the happy path,
// message_stop halting, request shape, cost, and complete() concatenation.
// This file drives the real bytes.lines event-stream parser in
// AnthropicLLMService through harder boundaries: the [DONE] sentinel branch
// (distinct from message_stop), malformed JSON lines, non-"data:" lines,
// delta events that carry no text, and the documented non-2xx swallow contract.
//
// The paid Anthropic HTTP endpoint is the only thing stubbed, via a real
// URLSession driven by StubURLProtocol (defined in the Curriculum test target).
// Every expected value below is derived from AnthropicLLMService.swift:
//   - only lines starting with "data: " are considered; the first 6 chars are dropped
//   - "[DONE]" breaks the loop; a non-decodable JSON line is skipped via try?
//   - an event decodes to AnthropicStreamEvent { type, delta { type?, text? } };
//     a token is yielded only when delta != nil AND delta.text != nil
//   - type == "message_stop" breaks the loop
//   - on the success path a final LLMToken(content: "", isDone: true,
//     stopReason: .endTurn, tokenCount: Int(Double(fullText.count) / 4.0)) is yielded
//   - a non-2xx status throws LLMError.rateLimited, which the Task catch swallows,
//     finishing the stream with zero tokens

import Foundation
import XCTest
@testable import UnaMentis

final class AnthropicLLMServiceStreamTests: XCTestCase {

    private var session: URLSession!

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() async throws {
        session = nil
        StubURLProtocol.reset()
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Builds a canned SSE body, one "data: <line>" per element, real newlines so the
    /// service's bytes.lines parser splits them line by line.
    private func sseBody(_ lines: [String]) -> Data {
        let joined = lines.map { "data: \($0)" }.joined(separator: "\n") + "\n"
        return Data(joined.utf8)
    }

    /// A content_block_delta event carrying text. The text must contain no JSON-special
    /// characters so it can be embedded directly as a JSON string literal.
    private func textDeltaEvent(_ text: String) -> String {
        "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"\(text)\"}}"
    }

    private let messageStopEvent = "{\"type\":\"message_stop\"}"

    private func collect(_ stream: AsyncStream<LLMToken>) async -> [LLMToken] {
        var tokens: [LLMToken] = []
        for await token in stream {
            tokens.append(token)
        }
        return tokens
    }

    private func makeService() -> AnthropicLLMService {
        AnthropicLLMService(apiKey: "test", session: session)
    }

    // MARK: - [DONE] sentinel branch

    func testDoneSentinelBreaksLoopAndStillEmitsFinalToken() async throws {
        // The "[DONE]" branch (jsonStr == "[DONE]" -> break) is distinct from message_stop.
        // A delta after [DONE] must be dropped, but the always-appended final token still arrives.
        let body = sseBody([
            textDeltaEvent("Hi"),
            "[DONE]",
            textDeltaEvent("after-done")
        ])
        StubURLProtocol.stub(path: "/v1/messages", statusCode: 200, body: body)

        let stream = try await makeService().streamCompletion(messages: [], config: .default)
        let tokens = await collect(stream)

        // One delta before [DONE], then the final done token. The post-[DONE] delta is dropped.
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens[0].content, "Hi")
        XCTAssertFalse(tokens[0].isDone)
        XCTAssertFalse(tokens.contains { $0.content == "after-done" })

        let final = tokens[1]
        XCTAssertEqual(final.content, "")
        XCTAssertTrue(final.isDone)
        XCTAssertEqual(final.stopReason, .endTurn)
        // Only "Hi" (2 chars) accumulated before the break: Int(Double(2)/4.0) = Int(0.5) = 0.
        XCTAssertEqual(final.tokenCount, 0)
    }

    // MARK: - Malformed and non-data lines

    func testMalformedJSONLineIsSkippedAndNeighborsStillParse() async throws {
        // A non-decodable JSON data line fails try? JSONDecoder().decode and is skipped via
        // continue; the valid deltas before and after it still parse in order.
        let body = sseBody([
            textDeltaEvent("before"),
            "{not valid json",
            textDeltaEvent("after"),
            messageStopEvent
        ])
        StubURLProtocol.stub(path: "/v1/messages", statusCode: 200, body: body)

        let stream = try await makeService().streamCompletion(messages: [], config: .default)
        let tokens = await collect(stream)

        let contentTokens = tokens.filter { !$0.content.isEmpty }
        XCTAssertEqual(contentTokens.map(\.content), ["before", "after"])

        // "before" (6) + "after" (5) = 11 chars accumulated. Int(Double(11)/4.0) = Int(2.75) = 2.
        let final = try XCTUnwrap(tokens.last)
        XCTAssertTrue(final.isDone)
        XCTAssertEqual(final.stopReason, .endTurn)
        XCTAssertEqual(final.tokenCount, 2)
    }

    func testLinesWithoutDataPrefixAreIgnored() async throws {
        // Lines lacking the "data: " prefix (SSE comments, event lines, blank keep-alives)
        // fail the line.starts(with: "data: ") guard and contribute no tokens. Built by hand
        // because the sseBody helper always prepends the prefix.
        let raw = """
        : keep-alive comment

        event: content_block_delta

        data: \(textDeltaEvent("kept"))

        data: \(messageStopEvent)

        """
        StubURLProtocol.stub(path: "/v1/messages", statusCode: 200, body: Data(raw.utf8))

        let stream = try await makeService().streamCompletion(messages: [], config: .default)
        let tokens = await collect(stream)

        let contentTokens = tokens.filter { !$0.content.isEmpty }
        XCTAssertEqual(contentTokens.map(\.content), ["kept"], "only the prefixed delta yields a token")

        let final = try XCTUnwrap(tokens.last)
        XCTAssertTrue(final.isDone)
        XCTAssertEqual(final.stopReason, .endTurn)
        // Only "kept" (4 chars) accumulated: Int(Double(4)/4.0) = Int(1.0) = 1.
        XCTAssertEqual(final.tokenCount, 1)
    }

    // MARK: - Decodable events that carry no emittable text

    func testEventsWithoutDeltaTextProduceNoContentButFinalTokenAppears() async throws {
        // These are well-formed AnthropicStreamEvent values that decode successfully but fail
        // the "if let delta = event.delta, let text = delta.text" emit condition:
        //   - message_start has no delta at all
        //   - content_block_start has a delta-less shape
        //   - a content_block_delta whose delta omits text (decodes, text == nil)
        // None of them yield a content token, so fullText stays empty and tokenCount is 0.
        let body = sseBody([
            "{\"type\":\"message_start\"}",
            "{\"type\":\"content_block_start\"}",
            "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\"}}",
            messageStopEvent
        ])
        StubURLProtocol.stub(path: "/v1/messages", statusCode: 200, body: body)

        let stream = try await makeService().streamCompletion(messages: [], config: .default)
        let tokens = await collect(stream)

        // No content tokens, only the always-appended final done token.
        XCTAssertEqual(tokens.count, 1)
        let final = tokens[0]
        XCTAssertEqual(final.content, "")
        XCTAssertTrue(final.isDone)
        XCTAssertEqual(final.stopReason, .endTurn)
        // Nothing accumulated: Int(Double(0)/4.0) = 0.
        XCTAssertEqual(final.tokenCount, 0)
    }

    func testTokenCountFloorsToFourCharsPerTokenAtBoundary() async throws {
        // Exactly 8 accumulated chars exercises the /4.0 division at a clean boundary:
        // "abcd" (4) + "efgh" (4) = 8. Int(Double(8)/4.0) = Int(2.0) = 2.
        let body = sseBody([textDeltaEvent("abcd"), textDeltaEvent("efgh"), messageStopEvent])
        StubURLProtocol.stub(path: "/v1/messages", statusCode: 200, body: body)

        let stream = try await makeService().streamCompletion(messages: [], config: .default)
        let tokens = await collect(stream)

        let final = try XCTUnwrap(tokens.last)
        XCTAssertEqual(final.tokenCount, 2)

        // One char short of the next token: 7 chars -> Int(1.75) = 1, proving it floors not rounds.
        StubURLProtocol.reset()
        let body2 = sseBody([textDeltaEvent("abcd"), textDeltaEvent("efg"), messageStopEvent])
        StubURLProtocol.stub(path: "/v1/messages", statusCode: 200, body: body2)
        let stream2 = try await makeService().streamCompletion(messages: [], config: .default)
        let tokens2 = await collect(stream2)
        let final2 = try XCTUnwrap(tokens2.last)
        XCTAssertEqual(final2.tokenCount, 1)
    }

    // MARK: - Non-2xx swallow contract

    func testRateLimitStatusYieldsCompletelyEmptyStream() async throws {
        // A 429 fails the (200...299) guard, throwing LLMError.rateLimited before any line is
        // read. The Task catch swallows it and finishes, so not even the final token is emitted.
        let body = sseBody([textDeltaEvent("never-seen"), messageStopEvent])
        StubURLProtocol.stub(path: "/v1/messages", statusCode: 429, body: body)

        let stream = try await makeService().streamCompletion(messages: [], config: .default)
        let tokens = await collect(stream)

        XCTAssertTrue(tokens.isEmpty, "a non-2xx response yields a stream with no tokens at all")
    }
}
