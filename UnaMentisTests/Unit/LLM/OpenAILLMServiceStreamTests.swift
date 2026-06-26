// UnaMentis - OpenAI LLM streaming spike
//
// Proof that the real OpenAILLMService request building and SSE parsing can be
// exercised end to end through a URLProtocol seam. The paid OpenAI HTTP endpoint
// is the only thing stubbed (via StubURLProtocol + an injected URLSession); the
// actor's real line-buffer parsing, delta extraction, and finish-reason mapping
// run unmodified against a canned server-sent-event body.

import Foundation
import XCTest
@testable import UnaMentis

final class OpenAILLMServiceStreamTests: XCTestCase {

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

    private func collect(_ stream: AsyncStream<LLMToken>) async -> [LLMToken] {
        var tokens: [LLMToken] = []
        for await token in stream {
            tokens.append(token)
        }
        return tokens
    }

    func testStreamCompletion_parsesSSEDeltasInOrder() async throws {
        // Canned OpenAI SSE body: two content deltas then the [DONE] sentinel.
        let sse = """
        data: {"choices":[{"delta":{"content":"Hello"}}]}

        data: {"choices":[{"delta":{"content":" world"}}]}

        data: [DONE]

        """
        StubURLProtocol.stub(
            path: "/v1/chat/completions",
            statusCode: 200,
            body: Data(sse.utf8)
        )

        let service = OpenAILLMService(apiKey: "test-key", session: session)
        let stream = try await service.streamCompletion(
            messages: [LLMMessage(role: .user, content: "hi")],
            config: .default
        )
        let tokens = await collect(stream)

        // The two content deltas are surfaced verbatim and in order.
        let contentTokens = tokens.filter { !$0.content.isEmpty }
        XCTAssertEqual(contentTokens.map(\.content), ["Hello", " world"])

        // The [DONE] sentinel produces a final done token with empty content, the
        // hardcoded .endTurn stop reason, and a tokenCount equal to the two content deltas.
        guard let last = tokens.last else {
            return XCTFail("Expected at least one token")
        }
        XCTAssertTrue(last.isDone)
        XCTAssertEqual(last.content, "", "the [DONE] token carries no content")
        XCTAssertEqual(last.stopReason, .endTurn)
        XCTAssertEqual(last.tokenCount, 2, "the [DONE] token counts both content deltas")

        // The request reached the real OpenAI completions path.
        XCTAssertEqual(StubURLProtocol.recordedURL()?.path, "/v1/chat/completions")
        XCTAssertEqual(StubURLProtocol.recordedMethod(), "POST")
    }

    func testStreamCompletion_mapsFinishReasonLengthToMaxTokens() async throws {
        // A delta carrying finish_reason "length" maps to StopReason.maxTokens.
        let sse = """
        data: {"choices":[{"delta":{"content":"trimmed"},"finish_reason":"length"}]}

        data: [DONE]

        """
        StubURLProtocol.stub(
            path: "/v1/chat/completions",
            statusCode: 200,
            body: Data(sse.utf8)
        )

        let service = OpenAILLMService(apiKey: "test-key", session: session)
        let stream = try await service.streamCompletion(
            messages: [LLMMessage(role: .user, content: "hi")],
            config: .default
        )
        let tokens = await collect(stream)

        guard let contentToken = tokens.first(where: { $0.content == "trimmed" }) else {
            return XCTFail("Expected the content delta to be parsed")
        }
        XCTAssertTrue(contentToken.isDone, "finish_reason present marks the token done")
        XCTAssertEqual(contentToken.stopReason, .maxTokens)
    }

    func testStreamCompletion_mapsFinishReasonStopToEndTurn() async throws {
        // A delta carrying finish_reason "stop" maps to StopReason.endTurn on that token.
        // The source switch maps "stop" -> .endTurn, so isDone is true on the content token.
        let sse = """
        data: {"choices":[{"delta":{"content":"final"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        StubURLProtocol.stub(
            path: "/v1/chat/completions",
            statusCode: 200,
            body: Data(sse.utf8)
        )

        let service = OpenAILLMService(apiKey: "test-key", session: session)
        let stream = try await service.streamCompletion(
            messages: [LLMMessage(role: .user, content: "hi")],
            config: .default
        )
        let tokens = await collect(stream)

        guard let contentToken = tokens.first(where: { $0.content == "final" }) else {
            return XCTFail("Expected the content delta to be parsed")
        }
        XCTAssertTrue(contentToken.isDone, "finish_reason present marks the token done")
        XCTAssertEqual(contentToken.stopReason, .endTurn)
    }

    func testStreamCompletion_unknownFinishReasonYieldsNilStopReasonAndNotDone() async throws {
        // An unrecognized finish_reason (e.g. "content_filter") maps to nil stopReason.
        // The source switch default returns nil, so the token is still yielded with isDone false.
        let sse = """
        data: {"choices":[{"delta":{"content":"flagged"},"finish_reason":"content_filter"}]}

        data: [DONE]

        """
        StubURLProtocol.stub(
            path: "/v1/chat/completions",
            statusCode: 200,
            body: Data(sse.utf8)
        )

        let service = OpenAILLMService(apiKey: "test-key", session: session)
        let stream = try await service.streamCompletion(
            messages: [LLMMessage(role: .user, content: "hi")],
            config: .default
        )
        let tokens = await collect(stream)

        guard let contentToken = tokens.first(where: { $0.content == "flagged" }) else {
            return XCTFail("Expected the content delta to be parsed")
        }
        XCTAssertFalse(contentToken.isDone, "unknown finish_reason leaves isDone false")
        XCTAssertNil(contentToken.stopReason, "unknown finish_reason maps to nil stopReason")
    }

    func testStreamCompletion_doneTokenCountEqualsContentDeltaCount() async throws {
        // Three content deltas are seen, then [DONE]. The source increments outputTokens
        // once per parsed content delta, so the final [DONE] token carries tokenCount 3.
        let sse = """
        data: {"choices":[{"delta":{"content":"one"}}]}

        data: {"choices":[{"delta":{"content":"two"}}]}

        data: {"choices":[{"delta":{"content":"three"}}]}

        data: [DONE]

        """
        StubURLProtocol.stub(
            path: "/v1/chat/completions",
            statusCode: 200,
            body: Data(sse.utf8)
        )

        let service = OpenAILLMService(apiKey: "test-key", session: session)
        let stream = try await service.streamCompletion(
            messages: [LLMMessage(role: .user, content: "hi")],
            config: .default
        )
        let tokens = await collect(stream)

        let contentTokens = tokens.filter { !$0.content.isEmpty }
        XCTAssertEqual(contentTokens.map(\.content), ["one", "two", "three"])

        guard let last = tokens.last else {
            return XCTFail("Expected a final [DONE] token")
        }
        XCTAssertTrue(last.isDone)
        XCTAssertEqual(last.stopReason, .endTurn)
        XCTAssertEqual(last.tokenCount, 3, "final token count equals the number of content deltas")
    }

    func testStreamCompletion_skipsMalformedJSONLineButParsesNeighbors() async throws {
        // A malformed JSON data line fails the try? JSONSerialization decode and is skipped,
        // while the valid deltas before and after it still parse in order.
        let sse = """
        data: {"choices":[{"delta":{"content":"before"}}]}

        data: {not json

        data: {"choices":[{"delta":{"content":"after"}}]}

        data: [DONE]

        """
        StubURLProtocol.stub(
            path: "/v1/chat/completions",
            statusCode: 200,
            body: Data(sse.utf8)
        )

        let service = OpenAILLMService(apiKey: "test-key", session: session)
        let stream = try await service.streamCompletion(
            messages: [LLMMessage(role: .user, content: "hi")],
            config: .default
        )
        let tokens = await collect(stream)

        // Only the two well-formed deltas surface; the malformed line produced no token.
        let contentTokens = tokens.filter { !$0.content.isEmpty }
        XCTAssertEqual(contentTokens.map(\.content), ["before", "after"])

        // The [DONE] token still arrives, carries empty content and the .endTurn stop
        // reason, and counts only the two parsed content deltas.
        guard let last = tokens.last else {
            return XCTFail("Expected a final [DONE] token")
        }
        XCTAssertTrue(last.isDone)
        XCTAssertEqual(last.content, "")
        XCTAssertEqual(last.stopReason, .endTurn)
        XCTAssertEqual(last.tokenCount, 2, "the malformed line is not counted as a content delta")
    }

    func testStreamCompletion_ignoresLinesWithoutDataPrefix() async throws {
        // Lines lacking the "data: " prefix (comments, blank keep-alives, event lines) are
        // ignored by the hasPrefix check; only the prefixed deltas are parsed.
        let sse = """
        : keep-alive comment

        event: message

        data: {"choices":[{"delta":{"content":"kept"}}]}

        data: [DONE]

        """
        StubURLProtocol.stub(
            path: "/v1/chat/completions",
            statusCode: 200,
            body: Data(sse.utf8)
        )

        let service = OpenAILLMService(apiKey: "test-key", session: session)
        let stream = try await service.streamCompletion(
            messages: [LLMMessage(role: .user, content: "hi")],
            config: .default
        )
        let tokens = await collect(stream)

        let contentTokens = tokens.filter { !$0.content.isEmpty }
        XCTAssertEqual(contentTokens.map(\.content), ["kept"], "non-data lines yield no tokens")

        guard let last = tokens.last else {
            return XCTFail("Expected a final [DONE] token")
        }
        XCTAssertTrue(last.isDone)
        XCTAssertEqual(last.stopReason, .endTurn)
        XCTAssertEqual(last.tokenCount, 1, "only the single data-prefixed delta is counted")
    }

    func testStreamCompletion_unauthorizedYieldsNoContentTokens() async throws {
        // A 401 throws LLMError.authenticationFailed inside the stream Task, which is caught
        // and the continuation finishes. The documented swallow contract means the stream
        // produces no tokens at all, not a thrown error to the caller.
        let sse = """
        data: {"choices":[{"delta":{"content":"should-not-appear"}}]}

        data: [DONE]

        """
        StubURLProtocol.stub(
            path: "/v1/chat/completions",
            statusCode: 401,
            body: Data(sse.utf8)
        )

        let service = OpenAILLMService(apiKey: "test-key", session: session)
        let stream = try await service.streamCompletion(
            messages: [LLMMessage(role: .user, content: "hi")],
            config: .default
        )
        let tokens = await collect(stream)

        XCTAssertTrue(tokens.isEmpty, "a 401 yields a stream with no tokens (swallowed inside the Task)")
    }

    func testStreamCompletion_serverErrorYieldsNoContentTokens() async throws {
        // A 500 fails the statusCode == 200 guard, throwing LLMError.connectionFailed which is
        // caught and finishes the stream. Same swallow contract: no tokens reach the caller.
        let sse = """
        data: {"choices":[{"delta":{"content":"should-not-appear"}}]}

        data: [DONE]

        """
        StubURLProtocol.stub(
            path: "/v1/chat/completions",
            statusCode: 500,
            body: Data(sse.utf8)
        )

        let service = OpenAILLMService(apiKey: "test-key", session: session)
        let stream = try await service.streamCompletion(
            messages: [LLMMessage(role: .user, content: "hi")],
            config: .default
        )
        let tokens = await collect(stream)

        XCTAssertTrue(tokens.isEmpty, "a 500 yields a stream with no tokens (swallowed inside the Task)")
    }
}
