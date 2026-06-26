// UnaMentis - Anthropic LLM Service Tests
// Unit tests for AnthropicLLMService streaming against the Claude messages
// event stream.
//
// The paid Anthropic HTTP endpoint is the only thing stubbed, via a real
// URLSession driven by StubURLProtocol (defined in the Curriculum test target).
// The service's real request building and its real bytes.lines event-stream
// parser run unmodified against canned SSE bodies. Every expected value below
// is derived from AnthropicLLMService.swift:
//   - a 'data: {json}' line decodes to AnthropicStreamEvent { type, delta { type?, text? } }
//   - an event with delta.text yields LLMToken(content: text, isDone: false)
//   - type == "message_stop" or 'data: [DONE]' breaks the loop
//   - after the loop a final LLMToken(content: "", isDone: true, stopReason: .endTurn,
//     tokenCount: Int(Double(fullText.count) / 4.0)) is always yielded on the success path
//   - a non-2xx status throws before the loop, so the stream finishes with zero tokens
//   - calculateCost uses inputCostPerToken 3/1M and outputCostPerToken 15/1M

import Foundation
import XCTest
@testable import UnaMentis

final class AnthropicLLMServiceTests: XCTestCase {

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

    /// Builds a canned SSE body with one 'data: {json}' line per element. Real
    /// newlines so the service's bytes.lines parser splits them line by line.
    private func sseBody(_ lines: [String]) -> Data {
        let joined = lines.map { "data: \($0)" }.joined(separator: "\n") + "\n"
        return Data(joined.utf8)
    }

    /// Builds a content_block_delta event. The caller passes text that contains no
    /// JSON-special characters, so it can be embedded directly as a JSON string literal.
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

    // MARK: - Delta ordering

    func testTwoTextDeltasYieldedInOrderAsNonDoneTokens() async throws {
        let body = sseBody([textDeltaEvent("Hello"), textDeltaEvent(" world"), messageStopEvent])
        StubURLProtocol.stub(path: "/v1/messages", statusCode: 200, body: body)

        let stream = try await makeService().streamCompletion(messages: [], config: .default)
        let tokens = await collect(stream)

        // Two content deltas, then the always-appended final done token.
        XCTAssertEqual(tokens.count, 3)

        XCTAssertEqual(tokens[0].content, "Hello")
        XCTAssertFalse(tokens[0].isDone)

        XCTAssertEqual(tokens[1].content, " world")
        XCTAssertFalse(tokens[1].isDone)
    }

    func testFinalTokenHasEmptyContentEndTurnAndApproximateTokenCount() async throws {
        // "Hello" (5) + " world" (6) = 11 chars. Int(Double(11)/4.0) = Int(2.75) = 2.
        let body = sseBody([textDeltaEvent("Hello"), textDeltaEvent(" world"), messageStopEvent])
        StubURLProtocol.stub(path: "/v1/messages", statusCode: 200, body: body)

        let stream = try await makeService().streamCompletion(messages: [], config: .default)
        let tokens = await collect(stream)

        let final = try XCTUnwrap(tokens.last)
        XCTAssertEqual(final.content, "")
        XCTAssertTrue(final.isDone)
        XCTAssertEqual(final.stopReason, .endTurn)
        XCTAssertEqual(final.tokenCount, 2)
    }

    // MARK: - message_stop semantics

    func testMessageStopHaltsEmissionOfLaterDeltasButFinalTokenStillAppears() async throws {
        // A delta after message_stop must be ignored, since message_stop breaks the loop.
        let body = sseBody([
            textDeltaEvent("Hello"),
            messageStopEvent,
            textDeltaEvent("ignored")
        ])
        StubURLProtocol.stub(path: "/v1/messages", statusCode: 200, body: body)

        let stream = try await makeService().streamCompletion(messages: [], config: .default)
        let tokens = await collect(stream)

        // One delta before the stop, plus the final done token. The post-stop delta is dropped.
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens[0].content, "Hello")
        XCTAssertFalse(tokens[0].isDone)

        let final = tokens[1]
        XCTAssertEqual(final.content, "")
        XCTAssertTrue(final.isDone)
        XCTAssertEqual(final.stopReason, .endTurn)
        // Only "Hello" (5 chars) was accumulated: Int(Double(5)/4.0) = Int(1.25) = 1.
        XCTAssertEqual(final.tokenCount, 1)
        XCTAssertFalse(tokens.contains { $0.content == "ignored" })
    }

    // MARK: - Non-2xx swallow contract

    func testNonSuccessStatusYieldsCompletelyEmptyStream() async throws {
        // The guard throws LLMError before the loop runs, the catch finishes the
        // stream, so not even the final done token is emitted.
        let body = sseBody([textDeltaEvent("Hello"), messageStopEvent])
        StubURLProtocol.stub(path: "/v1/messages", statusCode: 500, body: body)

        let stream = try await makeService().streamCompletion(messages: [], config: .default)
        let tokens = await collect(stream)

        XCTAssertTrue(tokens.isEmpty)
    }

    // MARK: - Request shape

    func testRequestUsesMessagesPathAndPostMethod() async throws {
        let body = sseBody([textDeltaEvent("Hi"), messageStopEvent])
        StubURLProtocol.stub(path: "/v1/messages", statusCode: 200, body: body)

        let stream = try await makeService().streamCompletion(messages: [], config: .default)
        _ = await collect(stream)

        XCTAssertEqual(StubURLProtocol.recordedURL()?.path, "/v1/messages")
        XCTAssertEqual(StubURLProtocol.recordedMethod(), "POST")
    }

    // MARK: - Cost calculation

    func testCalculateCostForOneMillionEachIsEighteen() async {
        // 1M * (3/1M) + 1M * (15/1M) = 3 + 15 = 18.
        let cost = await makeService().calculateCost(input: 1_000_000, output: 1_000_000)
        XCTAssertEqual(cost, Decimal(18))
    }

    func testCalculateCostForSmallerMixDerivesFromConstants() async {
        // 2M input * (3/1M) = 6, 500k output * (15/1M) = 7.5, total 13.5.
        let cost = await makeService().calculateCost(input: 2_000_000, output: 500_000)
        XCTAssertEqual(cost, Decimal(string: "13.5"))
    }

    func testCostPerTokenConstantsMatchPublishedRates() async {
        let service = makeService()
        let inputRate = await service.costPerInputToken
        let outputRate = await service.costPerOutputToken
        XCTAssertEqual(inputRate, Decimal(3) / Decimal(1_000_000))
        XCTAssertEqual(outputRate, Decimal(15) / Decimal(1_000_000))
    }

    // MARK: - complete() concatenation

    func testCompleteConcatenatesStreamedDeltaContent() async throws {
        let body = sseBody([textDeltaEvent("Hello"), textDeltaEvent(" world"), messageStopEvent])
        StubURLProtocol.stub(path: "/v1/messages", statusCode: 200, body: body)

        // The final empty done token contributes nothing, so the result is just the joined deltas.
        let result = try await makeService().complete(messages: [], config: .default)
        XCTAssertEqual(result, "Hello world")
    }
}
