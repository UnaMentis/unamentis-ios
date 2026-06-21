// UnaMentis - LLM Provider Cost and Configuration Tests
// Verifies the deterministic, no-network logic of the cloud and self-hosted
// LLM providers: cost-per-token pricing, default models, and cost math.
//
// These tests never reach a paid API. They exercise the pricing constants and
// computed properties each provider exposes, which is the part of the provider
// surface that drives the app's cost tracking.

import XCTest
@testable import UnaMentis

final class LLMProviderCostTests: XCTestCase {

    // Compare two Decimals as Doubles with a tight tolerance. Per-token prices
    // are tiny fractions, so the tolerance is correspondingly tiny.
    private func assertCost(
        _ actual: Decimal,
        equals expected: Double,
        accuracy: Double = 1e-12,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            NSDecimalNumber(decimal: actual).doubleValue,
            expected,
            accuracy: accuracy,
            message,
            file: file,
            line: line
        )
    }

    // MARK: - OpenAI default-model pricing

    // Before any stream call the OpenAI service is on its default "gpt-4o"
    // (non-mini) model, so it must report the full GPT-4o pricing.
    func testOpenAIDefaultModelUsesGPT4oPricing() async {
        let service = OpenAILLMService(apiKey: "test-key")

        let input = await service.costPerInputToken
        let output = await service.costPerOutputToken

        // GPT-4o: $2.50 / 1M input, $10.00 / 1M output.
        assertCost(input, equals: 2.50 / 1_000_000)
        assertCost(output, equals: 10.0 / 1_000_000)
    }

    func testOpenAIInputCostIsCheaperThanOutput() async {
        let service = OpenAILLMService(apiKey: "test-key")
        let input = await service.costPerInputToken
        let output = await service.costPerOutputToken
        XCTAssertLessThan(input, output, "Output tokens should cost more than input tokens")
    }

    // MARK: - Google default-model pricing

    // The Google service defaults to "gemini-2.5-flash" (non-pro), so it reports
    // Flash pricing until a stream sets a pro model.
    func testGoogleDefaultModelUsesFlashPricing() async {
        let service = GoogleLLMService(apiKey: "test-key")

        let input = await service.costPerInputToken
        let output = await service.costPerOutputToken

        // Gemini 2.5 Flash: $0.30 / 1M input, $2.50 / 1M output.
        assertCost(input, equals: 0.30 / 1_000_000)
        assertCost(output, equals: 2.50 / 1_000_000)
    }

    // MARK: - Anthropic pricing

    func testAnthropicPerTokenPricing() async {
        let service = AnthropicLLMService(apiKey: "test-key")

        let input = await service.costPerInputToken
        let output = await service.costPerOutputToken

        // Claude 3.5 Sonnet: $3.00 / 1M input, $15.00 / 1M output.
        assertCost(input, equals: 3.00 / 1_000_000)
        assertCost(output, equals: 15.0 / 1_000_000)
    }

    func testAnthropicCalculateCostCombinesInputAndOutput() async {
        let service = AnthropicLLMService(apiKey: "test-key")

        // 1000 input + 2000 output tokens.
        // 1000 * 3/1M = 0.003, 2000 * 15/1M = 0.030, total = 0.033.
        let total = await service.calculateCost(input: 1000, output: 2000)
        assertCost(total, equals: 0.033, accuracy: 1e-9)
    }

    func testAnthropicCalculateCostZeroTokensIsZero() async {
        let service = AnthropicLLMService(apiKey: "test-key")
        let total = await service.calculateCost(input: 0, output: 0)
        assertCost(total, equals: 0.0)
    }

    func testAnthropicCalculateCostScalesLinearly() async {
        let service = AnthropicLLMService(apiKey: "test-key")
        let single = await service.calculateCost(input: 100, output: 100)
        let double = await service.calculateCost(input: 200, output: 200)
        // Cost is linear in token count, so doubling tokens doubles the cost.
        assertCost(double, equals: NSDecimalNumber(decimal: single).doubleValue * 2.0, accuracy: 1e-9)
    }

    // MARK: - Self-hosted is free

    func testSelfHostedHasZeroCost() async {
        let url = URL(string: "http://localhost:11434")!
        let service = SelfHostedLLMService(baseURL: url, modelName: "qwen2.5:7b")

        let input = await service.costPerInputToken
        let output = await service.costPerOutputToken

        XCTAssertEqual(input, 0, "Self-hosted models incur no API cost")
        XCTAssertEqual(output, 0, "Self-hosted models incur no API cost")
    }

    // MARK: - Default metrics seeded per provider

    func testProvidersSeedDistinctDefaultMetrics() async {
        let openAI = await OpenAILLMService(apiKey: "k").metrics
        let google = await GoogleLLMService(apiKey: "k").metrics
        let anthropic = await AnthropicLLMService(apiKey: "k").metrics
        let selfHosted = await SelfHostedLLMService(
            baseURL: URL(string: "http://localhost:11434")!,
            modelName: "qwen2.5:7b"
        ).metrics

        // Each provider ships a sensible non-negative seed for TTFT before any
        // real measurement lands, and median should not exceed p99.
        for metrics in [openAI, google, anthropic, selfHosted] {
            XCTAssertGreaterThanOrEqual(metrics.medianTTFT, 0)
            XCTAssertLessThanOrEqual(metrics.medianTTFT, metrics.p99TTFT)
            XCTAssertEqual(metrics.totalInputTokens, 0)
            XCTAssertEqual(metrics.totalOutputTokens, 0)
        }

        // Self-hosted is expected to be the fastest seed (local), cloud slower.
        XCTAssertLessThanOrEqual(selfHosted.medianTTFT, anthropic.medianTTFT)
    }

    // MARK: - Default context window from the protocol extension

    func testCloudProvidersUseDefaultContextWindow() async {
        // None of the cloud providers override contextWindowSize, so they all
        // inherit the protocol-extension default of 128K.
        let openAI = await OpenAILLMService(apiKey: "k").contextWindowSize
        let google = await GoogleLLMService(apiKey: "k").contextWindowSize
        let anthropic = await AnthropicLLMService(apiKey: "k").contextWindowSize

        XCTAssertEqual(openAI, 128_000)
        XCTAssertEqual(google, 128_000)
        XCTAssertEqual(anthropic, 128_000)
    }
}
