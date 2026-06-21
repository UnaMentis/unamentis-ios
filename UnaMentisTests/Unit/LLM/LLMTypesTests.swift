// UnaMentis - LLM Shared Types Tests
// Exercises the deterministic shared logic that every LLM provider depends on:
// token estimation (protocol extension + TokenEstimation utility), the
// LLMProvider catalog, LLMConfig presets, and LLMError message mapping.

import XCTest
@testable import UnaMentis

final class LLMTypesTests: XCTestCase {

    // A concrete, internal LLMService used only to reach the protocol-extension
    // default methods (estimateTokenCount, contextWindowSize, complete) with a
    // real type. It is not a paid API, so it is named without the Mock prefix.
    private actor TinyLLMService: LLMService {
        let scripted: [String]
        init(scripted: [String]) { self.scripted = scripted }

        let metrics = LLMMetrics(medianTTFT: 0, p99TTFT: 0, totalInputTokens: 0, totalOutputTokens: 0)
        var costPerInputToken: Decimal { 0 }
        var costPerOutputToken: Decimal { 0 }

        func streamCompletion(messages: [LLMMessage], config: LLMConfig) async throws -> AsyncStream<LLMToken> {
            let scripted = self.scripted
            return AsyncStream { c in
                for piece in scripted {
                    c.yield(LLMToken(content: piece, isDone: false))
                }
                c.yield(LLMToken(content: "", isDone: true, stopReason: .endTurn))
                c.finish()
            }
        }
    }

    // MARK: - Protocol-extension token estimation

    func testEstimateTokenCountForTextRoughlyFourCharsPerToken() async {
        let service = TinyLLMService(scripted: [])
        // 16 characters / 4 = 4 tokens.
        let count = await service.estimateTokenCount("abcdefghijklmnop")
        XCTAssertEqual(count, 4)
    }

    func testEstimateTokenCountNeverReturnsZeroForNonEmptyText() async {
        let service = TinyLLMService(scripted: [])
        // A single character would floor to 0 tokens, but the floor is 1.
        let count = await service.estimateTokenCount("a")
        XCTAssertEqual(count, 1)
    }

    func testEstimateTokenCountForMessagesAddsPerMessageOverhead() async {
        let service = TinyLLMService(scripted: [])
        let messages = [
            LLMMessage(role: .system, content: "abcd"),   // 1 token + 4 overhead
            LLMMessage(role: .user, content: "abcdefgh")    // 2 tokens + 4 overhead
        ]
        // (4 + 1) + (4 + 2) = 11
        let count = await service.estimateTokenCount(for: messages)
        XCTAssertEqual(count, 11)
    }

    // MARK: - Protocol-extension complete()

    func testCompleteCollectsStreamedContent() async throws {
        let service = TinyLLMService(scripted: ["Hello, ", "world"])
        let result = try await service.complete(
            messages: [LLMMessage(role: .user, content: "hi")],
            config: .default
        )
        XCTAssertEqual(result, "Hello, world")
    }

    // MARK: - TokenEstimation utility

    func testTokenEstimationEstimateUsesConfigurableCharsPerToken() {
        // 20 chars / 4 = 5 tokens at the default ratio.
        XCTAssertEqual(TokenEstimation.estimate(String(repeating: "x", count: 20)), 5)
        // 20 chars / 5 = 4 tokens at a custom ratio.
        XCTAssertEqual(TokenEstimation.estimate(String(repeating: "x", count: 20), charsPerToken: 5), 4)
    }

    func testTokenEstimationEstimateFloorsAtOne() {
        XCTAssertEqual(TokenEstimation.estimate(""), 1)
        XCTAssertEqual(TokenEstimation.estimate("ab"), 1)
    }

    func testTokenEstimationMessagesIncludesOverhead() {
        let messages = [
            LLMMessage(role: .user, content: String(repeating: "x", count: 8)) // 2 tokens + 4
        ]
        XCTAssertEqual(TokenEstimation.estimate(messages: messages), 6)
    }

    func testFitsInContextRejectsOversizedConversation() {
        // ~10000 chars -> ~2500 tokens. Tiny window after reserving output means
        // the conversation does not fit.
        let big = LLMMessage(role: .user, content: String(repeating: "x", count: 10_000))
        XCTAssertFalse(
            TokenEstimation.fitsInContext(messages: [big], contextWindow: 2000, reservedForOutput: 500)
        )
    }

    func testFitsInContextAcceptsSmallConversation() {
        let small = LLMMessage(role: .user, content: "hello there")
        XCTAssertTrue(
            TokenEstimation.fitsInContext(messages: [small], contextWindow: 128_000)
        )
    }

    // MARK: - LLMProvider catalog

    func testProviderIdentifiersAreStableAndUnique() {
        let identifiers = LLMProvider.allCases.map { $0.identifier }
        XCTAssertEqual(Set(identifiers).count, identifiers.count, "Provider identifiers must be unique")
        XCTAssertEqual(LLMProvider.openAI.identifier, "openai")
        XCTAssertEqual(LLMProvider.anthropic.identifier, "anthropic")
        XCTAssertEqual(LLMProvider.google.identifier, "google")
        XCTAssertEqual(LLMProvider.selfHosted.identifier, "selfhosted")
        XCTAssertEqual(LLMProvider.localMLX.identifier, "mlx")
    }

    func testProviderDisplayNameMatchesRawValue() {
        XCTAssertEqual(LLMProvider.openAI.displayName, "OpenAI")
        XCTAssertEqual(LLMProvider.anthropic.displayName, "Anthropic Claude")
    }

    func testEveryProviderListsAtLeastOneModel() {
        for provider in LLMProvider.allCases {
            XCTAssertFalse(provider.availableModels.isEmpty, "\(provider) must offer a model")
        }
    }

    func testOnlySelfHostedAndLocalAreFree() {
        XCTAssertTrue(LLMProvider.selfHosted.isFree)
        XCTAssertTrue(LLMProvider.localMLX.isFree)
        XCTAssertFalse(LLMProvider.openAI.isFree)
        XCTAssertFalse(LLMProvider.anthropic.isFree)
        XCTAssertFalse(LLMProvider.google.isFree)
    }

    func testOnlyLocalMLXRunsWithoutNetwork() {
        XCTAssertFalse(LLMProvider.localMLX.requiresNetwork)
        // Self-hosted lives on a local network but still needs connectivity.
        XCTAssertTrue(LLMProvider.selfHosted.requiresNetwork)
        XCTAssertTrue(LLMProvider.openAI.requiresNetwork)
        XCTAssertTrue(LLMProvider.anthropic.requiresNetwork)
        XCTAssertTrue(LLMProvider.google.requiresNetwork)
    }

    func testProviderRoundTripsThroughRawValue() {
        for provider in LLMProvider.allCases {
            XCTAssertEqual(LLMProvider(rawValue: provider.rawValue), provider)
        }
    }

    // MARK: - LLMConfig presets

    func testDefaultPresetTargetsGPT4oStreaming() {
        let config = LLMConfig.default
        XCTAssertEqual(config.model, "gpt-4o")
        XCTAssertTrue(config.stream)
        XCTAssertEqual(config.maxTokens, 1024)
    }

    func testCostOptimizedPresetUsesCheaperModelAndFewerTokens() {
        let cheap = LLMConfig.costOptimized
        let standard = LLMConfig.default
        XCTAssertEqual(cheap.model, "gpt-4o-mini")
        XCTAssertLessThan(cheap.maxTokens, standard.maxTokens)
        XCTAssertLessThan(cheap.temperature, standard.temperature)
    }

    func testHighQualityPresetRaisesTokenBudget() {
        let high = LLMConfig.highQuality
        XCTAssertEqual(high.model, "gpt-4o")
        XCTAssertGreaterThan(high.maxTokens, LLMConfig.default.maxTokens)
    }

    func testConfigEncodesAndDecodesRoundTrip() throws {
        let original = LLMConfig(
            model: "claude-3-5-sonnet-20241022",
            maxTokens: 512,
            temperature: 0.42,
            topP: 0.9,
            stopSequences: ["STOP"],
            systemPrompt: "Be concise.",
            stream: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMConfig.self, from: data)
        XCTAssertEqual(decoded.model, original.model)
        XCTAssertEqual(decoded.maxTokens, original.maxTokens)
        XCTAssertEqual(decoded.temperature, original.temperature)
        XCTAssertEqual(decoded.topP, original.topP)
        XCTAssertEqual(decoded.stopSequences, original.stopSequences)
        XCTAssertEqual(decoded.systemPrompt, original.systemPrompt)
        XCTAssertEqual(decoded.stream, original.stream)
    }

    // MARK: - LLMError mapping

    func testRateLimitedDescriptionIncludesRetryDelayWhenPresent() {
        let withDelay = LLMError.rateLimited(retryAfter: 30)
        XCTAssertEqual(withDelay.errorDescription, "Rate limited. Retry after 30 seconds.")

        let withoutDelay = LLMError.rateLimited(retryAfter: nil)
        XCTAssertEqual(withoutDelay.errorDescription, "LLM rate limit exceeded")
    }

    func testAuthAndQuotaErrorsHaveStableMessages() {
        XCTAssertEqual(LLMError.authenticationFailed.errorDescription, "LLM authentication failed")
        XCTAssertEqual(LLMError.quotaExceeded.errorDescription, "LLM quota exceeded")
        XCTAssertEqual(LLMError.contentFiltered.errorDescription, "Content was filtered by safety systems")
    }

    func testParameterizedErrorsEmbedTheirContext() {
        XCTAssertEqual(
            LLMError.connectionFailed("timeout").errorDescription,
            "LLM connection failed: timeout"
        )
        XCTAssertEqual(
            LLMError.streamFailed("dropped").errorDescription,
            "LLM streaming failed: dropped"
        )
        XCTAssertEqual(
            LLMError.invalidRequest("bad model").errorDescription,
            "Invalid LLM request: bad model"
        )
        XCTAssertEqual(
            LLMError.modelNotFound("gpt-5").errorDescription,
            "Model not found: gpt-5"
        )
        XCTAssertEqual(
            LLMError.contextLengthExceeded(maxTokens: 200_000).errorDescription,
            "Context length exceeded maximum of 200000 tokens"
        )
    }

    // MARK: - LLMToken / LLMMessage value semantics

    func testLLMTokenDefaultsAreContentOnly() {
        let token = LLMToken(content: "hi", isDone: false)
        XCTAssertEqual(token.content, "hi")
        XCTAssertFalse(token.isDone)
        XCTAssertNil(token.stopReason)
        XCTAssertNil(token.tokenCount)
    }

    func testStopReasonRawValuesMatchProviderStrings() {
        XCTAssertEqual(StopReason.endTurn.rawValue, "end_turn")
        XCTAssertEqual(StopReason.maxTokens.rawValue, "max_tokens")
        XCTAssertEqual(StopReason.stopSequence.rawValue, "stop_sequence")
    }
}
