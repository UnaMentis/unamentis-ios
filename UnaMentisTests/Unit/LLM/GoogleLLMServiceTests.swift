// UnaMentis - GoogleLLMService streaming tests
// Exercises the real Gemini streamGenerateContent SSE parser and request
// builder through the StubURLProtocol seam. Only the paid HTTP boundary is
// stubbed; request construction, query-parameter auth, and the line-by-line
// SSE parsing under test are all real.
//
// Every expected value is derived from GoogleLLMService.swift:
// - parts[].text are joined into one token's content
// - non-empty text yields LLMToken(content:, isDone: false)
// - finishReason != "FINISH_REASON_UNSPECIFIED" yields a final token with
//   stopReason (.maxTokens for "MAX_TOKENS", else .endTurn) and tokenCount
//   equal to the number of content deltas, then finishes the stream
// - the API key is a query parameter and the model lives in the path
// - non-2xx statuses are caught inside the stream Task and swallowed, so the
//   stream finishes with no content tokens (documented swallow contract)

import Foundation
import XCTest
@testable import UnaMentis

final class GoogleLLMServiceTests: XCTestCase {

    private var session: URLSession!

    /// The default Gemini model used throughout these tests. We pass an
    /// explicit model so url.path is predictable and matches the stub path.
    private let flashModel = "gemini-2.5-flash"

    /// url.path for streamGenerateContent includes the model and the
    /// ":streamGenerateContent" suffix. The key/alt live in the query string.
    private func streamPath(for model: String) -> String {
        "/v1beta/models/\(model):streamGenerateContent"
    }

    private func flashConfig() -> LLMConfig {
        LLMConfig(model: flashModel, maxTokens: 256, temperature: 0.7, stream: true)
    }

    private func userMessages() -> [LLMMessage] {
        [LLMMessage(role: .user, content: "Hello")]
    }

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

    /// Collects all tokens emitted by a stream into an array.
    private func collect(_ stream: AsyncStream<LLMToken>) async -> [LLMToken] {
        var tokens: [LLMToken] = []
        for await token in stream {
            tokens.append(token)
        }
        return tokens
    }

    // MARK: - Multi-part joining

    func testMultiplePartsWithinOneCandidateAreJoinedIntoSingleToken() async throws {
        // parts: [{text:"foo"}, {text:"bar"}] joins to "foobar" in one content token,
        // then a STOP finishReason closes the stream.
        let body = """
        data: {"candidates":[{"content":{"parts":[{"text":"foo"},{"text":"bar"}]}}]}
        data: {"candidates":[{"finishReason":"STOP"}]}

        """
        StubURLProtocol.stub(path: streamPath(for: flashModel), statusCode: 200, body: Data(body.utf8))

        let service = GoogleLLMService(apiKey: "test-key", session: session)
        let stream = try await service.streamCompletion(messages: userMessages(), config: flashConfig())
        let tokens = await collect(stream)

        // One content token plus one done token.
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens[0].content, "foobar")
        XCTAssertFalse(tokens[0].isDone)
        XCTAssertTrue(tokens[1].isDone)
        XCTAssertEqual(tokens[1].stopReason, .endTurn)
        // The joined parts counted as exactly one content delta, so the done
        // token reports tokenCount 1 and carries empty content.
        XCTAssertEqual(tokens[1].content, "")
        XCTAssertEqual(tokens[1].tokenCount, 1)
    }

    // MARK: - Ordering of multiple deltas

    func testTwoCandidateDeltasAcrossTwoLinesAreYieldedInOrder() async throws {
        let body = """
        data: {"candidates":[{"content":{"parts":[{"text":"Hello "}]}}]}
        data: {"candidates":[{"content":{"parts":[{"text":"world"}]}}]}
        data: {"candidates":[{"finishReason":"STOP"}]}

        """
        StubURLProtocol.stub(path: streamPath(for: flashModel), statusCode: 200, body: Data(body.utf8))

        let service = GoogleLLMService(apiKey: "test-key", session: session)
        let stream = try await service.streamCompletion(messages: userMessages(), config: flashConfig())
        let tokens = await collect(stream)

        let contentTokens = tokens.filter { !$0.isDone }
        XCTAssertEqual(contentTokens.map(\.content), ["Hello ", "world"])

        // The done token reports tokenCount equal to the number of content deltas (2).
        let doneToken = try XCTUnwrap(tokens.last)
        XCTAssertTrue(doneToken.isDone)
        XCTAssertEqual(doneToken.tokenCount, 2)
    }

    // MARK: - Finish-reason mapping

    func testMaxTokensFinishReasonMapsToMaxTokensStopReason() async throws {
        let body = """
        data: {"candidates":[{"content":{"parts":[{"text":"partial"}]}}]}
        data: {"candidates":[{"finishReason":"MAX_TOKENS"}]}

        """
        StubURLProtocol.stub(path: streamPath(for: flashModel), statusCode: 200, body: Data(body.utf8))

        let service = GoogleLLMService(apiKey: "test-key", session: session)
        let stream = try await service.streamCompletion(messages: userMessages(), config: flashConfig())
        let tokens = await collect(stream)

        let doneToken = try XCTUnwrap(tokens.last)
        XCTAssertTrue(doneToken.isDone)
        XCTAssertEqual(doneToken.stopReason, .maxTokens)
        // One content delta was emitted before the done token.
        XCTAssertEqual(doneToken.tokenCount, 1)
        XCTAssertEqual(doneToken.content, "")
    }

    func testStopFinishReasonMapsToEndTurnStopReason() async throws {
        let body = """
        data: {"candidates":[{"content":{"parts":[{"text":"done"}]}}]}
        data: {"candidates":[{"finishReason":"STOP"}]}

        """
        StubURLProtocol.stub(path: streamPath(for: flashModel), statusCode: 200, body: Data(body.utf8))

        let service = GoogleLLMService(apiKey: "test-key", session: session)
        let stream = try await service.streamCompletion(messages: userMessages(), config: flashConfig())
        let tokens = await collect(stream)

        // The single "done" delta was emitted as a content token, then a STOP
        // closed the stream with the done token carrying empty content and the
        // count of content deltas (1).
        let contentTokens = tokens.filter { !$0.isDone }
        XCTAssertEqual(contentTokens.map(\.content), ["done"])

        let doneToken = try XCTUnwrap(tokens.last)
        XCTAssertTrue(doneToken.isDone)
        XCTAssertEqual(doneToken.stopReason, .endTurn)
        XCTAssertEqual(doneToken.content, "")
        XCTAssertEqual(doneToken.tokenCount, 1)
    }

    func testStreamEndingWithoutFinishReasonStillYieldsEndTurnDoneToken() async throws {
        // When the SSE body ends with no finishReason line at all, the parser
        // falls through the loop and reaches the post-loop branch (source lines
        // 176 to 179), which yields a synthetic done token with .endTurn and a
        // tokenCount equal to the content deltas seen. This is a distinct code
        // path from the finishReason-triggered done token.
        let body = """
        data: {"candidates":[{"content":{"parts":[{"text":"alpha"}]}}]}
        data: {"candidates":[{"content":{"parts":[{"text":"beta"}]}}]}

        """
        StubURLProtocol.stub(path: streamPath(for: flashModel), statusCode: 200, body: Data(body.utf8))

        let service = GoogleLLMService(apiKey: "test-key", session: session)
        let stream = try await service.streamCompletion(messages: userMessages(), config: flashConfig())
        let tokens = await collect(stream)

        let contentTokens = tokens.filter { !$0.isDone }
        XCTAssertEqual(contentTokens.map(\.content), ["alpha", "beta"])

        // Exactly one done token closes the stream even without a finishReason.
        let doneTokens = tokens.filter(\.isDone)
        XCTAssertEqual(doneTokens.count, 1)
        let doneToken = try XCTUnwrap(tokens.last)
        XCTAssertTrue(doneToken.isDone)
        XCTAssertEqual(doneToken.stopReason, .endTurn)
        XCTAssertEqual(doneToken.content, "")
        XCTAssertEqual(doneToken.tokenCount, 2)
    }

    func testUnspecifiedFinishReasonDoesNotFinishStreamAndLaterDeltaStillEmits() async throws {
        // A FINISH_REASON_UNSPECIFIED line must NOT close the stream. The later
        // real delta must still be parsed and emitted, proving the guard works.
        let body = """
        data: {"candidates":[{"content":{"parts":[{"text":"early"}]},"finishReason":"FINISH_REASON_UNSPECIFIED"}]}
        data: {"candidates":[{"content":{"parts":[{"text":"late"}]}}]}
        data: {"candidates":[{"finishReason":"STOP"}]}

        """
        StubURLProtocol.stub(path: streamPath(for: flashModel), statusCode: 200, body: Data(body.utf8))

        let service = GoogleLLMService(apiKey: "test-key", session: session)
        let stream = try await service.streamCompletion(messages: userMessages(), config: flashConfig())
        let tokens = await collect(stream)

        let contentTokens = tokens.filter { !$0.isDone }
        // Both deltas survive: the UNSPECIFIED reason did not short-circuit the stream.
        XCTAssertEqual(contentTokens.map(\.content), ["early", "late"])

        let doneToken = try XCTUnwrap(tokens.last)
        XCTAssertTrue(doneToken.isDone)
        XCTAssertEqual(doneToken.stopReason, .endTurn)
        XCTAssertEqual(doneToken.tokenCount, 2)
    }

    // MARK: - Malformed and ignored lines

    func testMalformedAndNonDataLinesAreIgnored() async throws {
        // Lines without the "data: " prefix are skipped; a "data:" line whose
        // JSON has no candidates is skipped. Only the real delta is emitted.
        let body = """
        : this is an SSE comment
        event: message
        data: {"usageMetadata":{"promptTokenCount":3}}
        data: not-json
        data: {"candidates":[{"content":{"parts":[{"text":"real"}]}}]}
        data: {"candidates":[{"finishReason":"STOP"}]}

        """
        StubURLProtocol.stub(path: streamPath(for: flashModel), statusCode: 200, body: Data(body.utf8))

        let service = GoogleLLMService(apiKey: "test-key", session: session)
        let stream = try await service.streamCompletion(messages: userMessages(), config: flashConfig())
        let tokens = await collect(stream)

        let contentTokens = tokens.filter { !$0.isDone }
        XCTAssertEqual(contentTokens.map(\.content), ["real"])

        let doneToken = try XCTUnwrap(tokens.last)
        XCTAssertTrue(doneToken.isDone)
        XCTAssertEqual(doneToken.tokenCount, 1)
    }

    // MARK: - Request building (Gemini distinctive auth and path)

    func testRequestUrlCarriesApiKeyAndModelAndAltSseInQueryAndPath() async throws {
        let body = """
        data: {"candidates":[{"content":{"parts":[{"text":"hi"}]}}]}
        data: {"candidates":[{"finishReason":"STOP"}]}

        """
        StubURLProtocol.stub(path: streamPath(for: flashModel), statusCode: 200, body: Data(body.utf8))

        let service = GoogleLLMService(apiKey: "test-key", session: session)
        let stream = try await service.streamCompletion(messages: userMessages(), config: flashConfig())
        _ = await collect(stream)

        let recorded = try XCTUnwrap(StubURLProtocol.recordedURL())

        // Path includes the model and the :streamGenerateContent suffix.
        XCTAssertEqual(recorded.path, streamPath(for: flashModel))

        // Query items carry the API key and alt=sse (Gemini's distinctive auth-in-query).
        let components = try XCTUnwrap(URLComponents(url: recorded, resolvingAgainstBaseURL: false))
        let items = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(items.first(where: { $0.name == "key" })?.value, "test-key")
        XCTAssertEqual(items.first(where: { $0.name == "alt" })?.value, "sse")

        // Full string sanity check covering host, model, and both query params.
        let absolute = recorded.absoluteString
        XCTAssertTrue(absolute.contains("/models/\(flashModel):streamGenerateContent"), absolute)
        XCTAssertTrue(absolute.contains("key=test-key"), absolute)
        XCTAssertTrue(absolute.contains("alt=sse"), absolute)

        // Gemini streams over POST.
        XCTAssertEqual(StubURLProtocol.recordedMethod(), "POST")
    }

    // MARK: - Non-2xx swallow contract

    func testUnauthorizedStatusYieldsEmptyStream() async throws {
        // 401 maps to LLMError.authenticationFailed, which is caught inside the
        // stream Task and swallowed, so no content tokens are emitted.
        StubURLProtocol.stub(path: streamPath(for: flashModel), statusCode: 401, body: Data("unauthorized".utf8))

        let service = GoogleLLMService(apiKey: "test-key", session: session)
        let stream = try await service.streamCompletion(messages: userMessages(), config: flashConfig())
        let tokens = await collect(stream)

        XCTAssertTrue(tokens.isEmpty, "401 must yield an empty stream (documented swallow)")
    }

    func testForbiddenStatusYieldsEmptyStream() async throws {
        // 403 shares the auth branch with 401 (source: statusCode == 401 || 403)
        // and maps to LLMError.authenticationFailed, caught and swallowed. Even
        // though the stubbed body contains a well-formed content delta, the
        // status check fires before any line is parsed, so no token is emitted.
        let body = """
        data: {"candidates":[{"content":{"parts":[{"text":"should-not-appear"}]}}]}
        data: {"candidates":[{"finishReason":"STOP"}]}

        """
        StubURLProtocol.stub(path: streamPath(for: flashModel), statusCode: 403, body: Data(body.utf8))

        let service = GoogleLLMService(apiKey: "test-key", session: session)
        let stream = try await service.streamCompletion(messages: userMessages(), config: flashConfig())
        let tokens = await collect(stream)

        XCTAssertTrue(tokens.isEmpty, "403 must yield an empty stream (documented swallow)")
    }

    func testRateLimitedStatusYieldsEmptyStream() async throws {
        // 429 maps to LLMError.rateLimited, also caught and swallowed.
        StubURLProtocol.stub(path: streamPath(for: flashModel), statusCode: 429, body: Data("slow down".utf8))

        let service = GoogleLLMService(apiKey: "test-key", session: session)
        let stream = try await service.streamCompletion(messages: userMessages(), config: flashConfig())
        let tokens = await collect(stream)

        XCTAssertTrue(tokens.isEmpty, "429 must yield an empty stream (documented swallow)")
    }

    func testServerErrorStatusYieldsEmptyStream() async throws {
        // A 500 fails the statusCode == 200 guard (source line 134) and throws
        // LLMError.connectionFailed, which the catch block swallows by finishing
        // the continuation. Confirms the non-auth, non-429 error path also yields
        // a genuinely empty stream rather than surfacing a thrown error.
        StubURLProtocol.stub(path: streamPath(for: flashModel), statusCode: 500, body: Data("oops".utf8))

        let service = GoogleLLMService(apiKey: "test-key", session: session)
        let stream = try await service.streamCompletion(messages: userMessages(), config: flashConfig())
        let tokens = await collect(stream)

        XCTAssertTrue(tokens.isEmpty, "500 must yield an empty stream (documented swallow)")
    }

    // MARK: - Model-driven cost properties

    func testProModelDrivesProPricingAfterStream() async throws {
        // currentModel is set from config.model inside streamCompletion. Drive a
        // tiny stream with a pro model, then assert the per-token cost estimates.
        let proModel = "gemini-2.5-pro"
        let body = """
        data: {"candidates":[{"content":{"parts":[{"text":"x"}]}}]}
        data: {"candidates":[{"finishReason":"STOP"}]}

        """
        StubURLProtocol.stub(path: streamPath(for: proModel), statusCode: 200, body: Data(body.utf8))

        let service = GoogleLLMService(apiKey: "test-key", session: session)
        let config = LLMConfig(model: proModel, maxTokens: 256, temperature: 0.7, stream: true)
        let stream = try await service.streamCompletion(messages: userMessages(), config: config)
        _ = await collect(stream)

        let inputCost = await service.costPerInputToken
        let outputCost = await service.costPerOutputToken
        XCTAssertEqual(inputCost, Decimal(1.25) / 1_000_000)
        XCTAssertEqual(outputCost, Decimal(10.0) / 1_000_000)
    }

    func testFlashModelDrivesFlashPricingAfterStream() async throws {
        let body = """
        data: {"candidates":[{"content":{"parts":[{"text":"x"}]}}]}
        data: {"candidates":[{"finishReason":"STOP"}]}

        """
        StubURLProtocol.stub(path: streamPath(for: flashModel), statusCode: 200, body: Data(body.utf8))

        let service = GoogleLLMService(apiKey: "test-key", session: session)
        let stream = try await service.streamCompletion(messages: userMessages(), config: flashConfig())
        _ = await collect(stream)

        let inputCost = await service.costPerInputToken
        let outputCost = await service.costPerOutputToken
        XCTAssertEqual(inputCost, Decimal(0.30) / 1_000_000)
        XCTAssertEqual(outputCost, Decimal(2.50) / 1_000_000)
    }
}
