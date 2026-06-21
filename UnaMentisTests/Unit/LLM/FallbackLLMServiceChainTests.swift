// UnaMentis - FallbackLLMService Chain Behavior Tests
// Complements FallbackLLMServiceTests with the chain's finer-grained guarantees:
// per-tier model override, the no-leak-before-content rule, mid-stream commitment
// (a partial answer rather than a crash), recovery after several failures, and
// that a tier failing to START (streamCompletion throws) is skipped.
//
// All test doubles here are internal services standing in for tiers, not paid
// APIs, so they are named without the Mock prefix.

import XCTest
@testable import UnaMentis

final class FallbackLLMServiceChainTests: XCTestCase {

    // MARK: - Test doubles

    /// Finishes without ever yielding content. This is the shape an auth/load/
    /// connection failure takes in the real providers (their streams finish
    /// rather than throw), so the chain must treat it as a failed tier.
    private actor SilentTier: LLMService {
        let metrics = LLMMetrics(medianTTFT: 0, p99TTFT: 0, totalInputTokens: 0, totalOutputTokens: 0)
        var costPerInputToken: Decimal { 0 }
        var costPerOutputToken: Decimal { 0 }
        func streamCompletion(messages: [LLMMessage], config: LLMConfig) async throws -> AsyncStream<LLMToken> {
            AsyncStream { $0.finish() }
        }
    }

    /// Yields the given pieces of content then a done token.
    private actor ScriptedTier: LLMService {
        private let pieces: [String]
        init(_ pieces: [String]) { self.pieces = pieces }
        let metrics = LLMMetrics(medianTTFT: 0.01, p99TTFT: 0.02, totalInputTokens: 0, totalOutputTokens: 0)
        var costPerInputToken: Decimal { 0 }
        var costPerOutputToken: Decimal { 0 }
        func streamCompletion(messages: [LLMMessage], config: LLMConfig) async throws -> AsyncStream<LLMToken> {
            let pieces = self.pieces
            return AsyncStream { c in
                for piece in pieces { c.yield(LLMToken(content: piece, isDone: false)) }
                c.yield(LLMToken(content: "", isDone: true, stopReason: .endTurn))
                c.finish()
            }
        }
    }

    /// Records the config model it was handed, so a model-override test can prove
    /// the override reached the tier. Emits one content token so it commits.
    private actor ModelCapturingTier: LLMService {
        private(set) var capturedModel: String?
        let metrics = LLMMetrics(medianTTFT: 0, p99TTFT: 0, totalInputTokens: 0, totalOutputTokens: 0)
        var costPerInputToken: Decimal { 0 }
        var costPerOutputToken: Decimal { 0 }
        func streamCompletion(messages: [LLMMessage], config: LLMConfig) async throws -> AsyncStream<LLMToken> {
            capturedModel = config.model
            return AsyncStream { c in
                c.yield(LLMToken(content: "ok", isDone: false))
                c.yield(LLMToken(content: "", isDone: true, stopReason: .endTurn))
                c.finish()
            }
        }
    }

    /// Yields one content token, then finishes WITHOUT a clean done token, the
    /// shape of a dropped connection after partial content.
    private actor MidStreamDropTier: LLMService {
        private let firstChunk: String
        init(_ firstChunk: String) { self.firstChunk = firstChunk }
        let metrics = LLMMetrics(medianTTFT: 0, p99TTFT: 0, totalInputTokens: 0, totalOutputTokens: 0)
        var costPerInputToken: Decimal { 0 }
        var costPerOutputToken: Decimal { 0 }
        func streamCompletion(messages: [LLMMessage], config: LLMConfig) async throws -> AsyncStream<LLMToken> {
            let firstChunk = self.firstChunk
            return AsyncStream { c in
                c.yield(LLMToken(content: firstChunk, isDone: false))
                c.finish() // drop, no done token
            }
        }
    }

    /// streamCompletion throws immediately (could not even start the request).
    private actor StartThrowsTier: LLMService {
        struct StartError: Error {}
        let metrics = LLMMetrics(medianTTFT: 0, p99TTFT: 0, totalInputTokens: 0, totalOutputTokens: 0)
        var costPerInputToken: Decimal { 0 }
        var costPerOutputToken: Decimal { 0 }
        func streamCompletion(messages: [LLMMessage], config: LLMConfig) async throws -> AsyncStream<LLMToken> {
            throw StartError()
        }
    }

    private struct ConstructionError: Error {}

    private let config = LLMConfig(model: "default-model", maxTokens: 32, temperature: 0, stream: true)
    private let messages = [LLMMessage(role: .user, content: "hello")]

    private func collect(_ service: FallbackLLMService) async -> [LLMToken] {
        var tokens: [LLMToken] = []
        guard let stream = try? await service.streamCompletion(messages: messages, config: config) else { return tokens }
        for await token in stream { tokens.append(token) }
        return tokens
    }

    private func collectText(_ service: FallbackLLMService) async -> String {
        await collect(service).map { $0.content }.joined()
    }

    // MARK: - Per-tier model override

    func testTierModelOverridesConfigModel() async {
        let capturing = ModelCapturingTier()
        let service = FallbackLLMService(tiers: [
            LLMFallbackTier(label: "override", model: "tier-specific-model") { capturing }
        ])
        _ = await collectText(service)

        let captured = await capturing.capturedModel
        XCTAssertEqual(captured, "tier-specific-model", "A tier's model must override the config model so a fallback never sends another provider's model id")
    }

    func testTierWithoutModelKeepsConfigModel() async {
        let capturing = ModelCapturingTier()
        let service = FallbackLLMService(tiers: [
            LLMFallbackTier(label: "passthrough") { capturing }
        ])
        _ = await collectText(service)

        let captured = await capturing.capturedModel
        XCTAssertEqual(captured, "default-model", "Without a tier model, the config model is used unchanged")
    }

    // MARK: - No leaking before content

    func testFailedTierNeverLeaksTokensBeforeFallback() async {
        // The silent tier finishes empty; only the second tier's text must appear.
        let service = FallbackLLMService(tiers: [
            LLMFallbackTier(label: "silent") { SilentTier() },
            LLMFallbackTier(label: "good") { ScriptedTier(["recovered ", "answer"]) }
        ])
        let text = await collectText(service)
        XCTAssertEqual(text, "recovered answer")
    }

    func testEmptyLeadingChunksDoNotCommitTheTier() async {
        // A tier that yields only empty-content tokens never produces content, so
        // the chain must move on rather than commit to it.
        let service = FallbackLLMService(tiers: [
            LLMFallbackTier(label: "empties") { ScriptedTier(["", "", ""]) },
            LLMFallbackTier(label: "good") { ScriptedTier(["real"]) }
        ])
        let text = await collectText(service)
        XCTAssertEqual(text, "real")
    }

    // MARK: - Mid-stream commitment

    func testMidStreamDropYieldsPartialAnswerNotFallbackMessage() async {
        // Once content begins the tier is committed. A drop should surface the
        // partial answer, never the calm all-failed message and never a crash.
        let partial = "Here is the start of the"
        let service = FallbackLLMService(tiers: [
            LLMFallbackTier(label: "drops") { MidStreamDropTier(partial) },
            LLMFallbackTier(label: "never-reached") { ScriptedTier(["SHOULD NOT APPEAR"]) }
        ])
        let text = await collectText(service)
        XCTAssertEqual(text, partial, "A committed tier that drops yields its partial output")
        XCTAssertFalse(text.contains("trouble reaching"), "A partial answer must not trigger the all-failed message")
        XCTAssertFalse(text.contains("SHOULD NOT APPEAR"), "The chain must not fall through after committing")
    }

    // MARK: - Tier that fails to start

    func testTierThatThrowsOnStartIsSkipped() async {
        let service = FallbackLLMService(tiers: [
            LLMFallbackTier(label: "throws-on-start") { StartThrowsTier() },
            LLMFallbackTier(label: "good") { ScriptedTier(["after start failure"]) }
        ])
        let text = await collectText(service)
        XCTAssertEqual(text, "after start failure")
    }

    // MARK: - Recovery after several failures

    func testRecoversAfterMultipleMixedFailures() async {
        let service = FallbackLLMService(tiers: [
            LLMFallbackTier(label: "cannot-build") { throw ConstructionError() },
            LLMFallbackTier(label: "throws-on-start") { StartThrowsTier() },
            LLMFallbackTier(label: "silent") { SilentTier() },
            LLMFallbackTier(label: "finally-good") { ScriptedTier(["made it"]) }
        ])
        let text = await collectText(service)
        XCTAssertEqual(text, "made it")
    }

    // MARK: - All-failed terminal token shape

    func testAllFailedEmitsContentThenDoneToken() async {
        let service = FallbackLLMService(tiers: [
            LLMFallbackTier(label: "silent") { SilentTier() }
        ])
        let tokens = await collect(service)
        XCTAssertFalse(tokens.isEmpty)
        // The message token carries content and is not marked done; the chain
        // then emits a terminal done token so consumers see a clean end.
        XCTAssertTrue(tokens.first?.content.contains("trouble reaching") ?? false)
        XCTAssertTrue(tokens.last?.isDone ?? false, "The stream must end with a done token")
        XCTAssertEqual(tokens.last?.stopReason, .endTurn)
    }

    // MARK: - Wrapper itself does not bill

    func testWrapperReportsZeroCost() async {
        let service = FallbackLLMService(tiers: [])
        let input = await service.costPerInputToken
        let output = await service.costPerOutputToken
        XCTAssertEqual(input, 0)
        XCTAssertEqual(output, 0)
    }
}
