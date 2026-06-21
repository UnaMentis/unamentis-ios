// UnaMentis - FallbackLLMService Tests
// Proves the runtime fallback chain degrades safely: never stranded, never crash.

import XCTest
@testable import UnaMentis

final class FallbackLLMServiceTests: XCTestCase {

    // MARK: - Test doubles (internal services, not paid APIs)

    /// A service whose stream finishes without ever producing content, the shape
    /// a load/auth/connection failure takes in the real providers.
    private actor EmptyLLMService: LLMService {
        let metrics = LLMMetrics(medianTTFT: 0, p99TTFT: 0, totalInputTokens: 0, totalOutputTokens: 0)
        var costPerInputToken: Decimal { 0 }
        var costPerOutputToken: Decimal { 0 }
        func streamCompletion(messages: [LLMMessage], config: LLMConfig) async throws -> AsyncStream<LLMToken> {
            AsyncStream { $0.finish() }
        }
    }

    /// A service that yields a fixed sentence, standing in for a working tier.
    private actor WorkingLLMService: LLMService {
        private let text: String
        init(_ text: String) { self.text = text }
        let metrics = LLMMetrics(medianTTFT: 0.01, p99TTFT: 0.02, totalInputTokens: 0, totalOutputTokens: 0)
        var costPerInputToken: Decimal { 0 }
        var costPerOutputToken: Decimal { 0 }
        func streamCompletion(messages: [LLMMessage], config: LLMConfig) async throws -> AsyncStream<LLMToken> {
            let text = self.text
            return AsyncStream { c in
                c.yield(LLMToken(content: text, isDone: false))
                c.yield(LLMToken(content: "", isDone: true, stopReason: .endTurn))
                c.finish()
            }
        }
    }

    private struct TierError: Error {}

    private let config = LLMConfig(model: "", maxTokens: 32, temperature: 0, stream: true)
    private let messages = [LLMMessage(role: .user, content: "hello")]

    private func collect(_ service: FallbackLLMService) async -> String {
        var out = ""
        guard let stream = try? await service.streamCompletion(messages: messages, config: config) else { return out }
        for await token in stream { out += token.content }
        return out
    }

    // MARK: - Tests

    func testFirstWorkingTierServesResponse() async {
        let service = FallbackLLMService(tiers: [
            LLMFallbackTier(label: "primary") { WorkingLLMService("primary answer") }
        ])
        let out = await collect(service)
        XCTAssertEqual(out, "primary answer")
    }

    func testFallsBackPastConstructionFailure() async {
        let service = FallbackLLMService(tiers: [
            LLMFallbackTier(label: "broken") { throw TierError() },
            LLMFallbackTier(label: "fallback") { WorkingLLMService("fallback answer") }
        ])
        let out = await collect(service)
        XCTAssertEqual(out, "fallback answer")
    }

    func testFallsBackPastEmptyStream() async {
        let service = FallbackLLMService(tiers: [
            LLMFallbackTier(label: "empty") { EmptyLLMService() },
            LLMFallbackTier(label: "fallback") { WorkingLLMService("recovered") }
        ])
        let out = await collect(service)
        XCTAssertEqual(out, "recovered")
    }

    func testEarlierWorkingTierWinsOverLater() async {
        let service = FallbackLLMService(tiers: [
            LLMFallbackTier(label: "first") { WorkingLLMService("first") },
            LLMFallbackTier(label: "second") { WorkingLLMService("second") }
        ])
        let out = await collect(service)
        XCTAssertEqual(out, "first")
    }

    func testAllTiersFailEmitsGracefulMessage() async {
        let service = FallbackLLMService(tiers: [
            LLMFallbackTier(label: "broken") { throw TierError() },
            LLMFallbackTier(label: "empty") { EmptyLLMService() }
        ])
        let out = await collect(service)
        XCTAssertFalse(out.isEmpty, "Must never leave the user with nothing")
        XCTAssertTrue(out.contains("trouble reaching"), "Should emit the calm all-failed message, got: \(out)")
    }

    func testNoTiersEmitsGracefulMessage() async {
        let service = FallbackLLMService(tiers: [])
        let out = await collect(service)
        XCTAssertTrue(out.contains("trouble reaching"))
    }
}
