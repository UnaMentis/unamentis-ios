// UnaMentis - LM API provider metadata and cost-estimation tests
// Covers LMAPIProviderRegistry coverage and self-consistency, LMAPIPricing and
// ConversationCostEstimate formatting, category metadata, and the
// CombinedCostEstimator pricing math.

import XCTest
@testable import UnaMentis

/// Tests for the provider information registry and cost estimation logic.
final class LMAPIProviderInfoTests: XCTestCase {

    // MARK: - Registry coverage

    func testRegistryReturnsInfoForEveryKeyType() {
        for keyType in APIKeyManager.KeyType.allCases {
            let info = LMAPIProviderRegistry.info(for: keyType)
            XCTAssertEqual(info.id, keyType,
                           "registry must return info whose id matches the requested key type")
            XCTAssertFalse(info.name.isEmpty, "\(keyType.rawValue) provider needs a name")
            XCTAssertFalse(info.shortDescription.isEmpty)
            XCTAssertFalse(info.fullDescription.isEmpty)
            XCTAssertFalse(info.usageInApp.isEmpty)
            XCTAssertFalse(info.categories.isEmpty,
                           "\(keyType.rawValue) provider needs at least one category")
            XCTAssertFalse(info.tips.isEmpty, "\(keyType.rawValue) provider should offer tips")
        }
    }

    func testRecommendedModelsExistForMultiModelProviders() {
        // Single-category providers that ship multiple models should mark exactly
        // one recommended model.
        for keyType in [APIKeyManager.KeyType.openAI, .anthropic, .google] {
            let info = LMAPIProviderRegistry.info(for: keyType)
            let recommended = info.models.filter { $0.isRecommended }
            XCTAssertEqual(recommended.count, 1,
                           "\(keyType.rawValue) should have exactly one recommended model")
        }
    }

    func testDeepgramRecommendsOneModelPerCategory() {
        // Deepgram is a dual-category provider (STT via Nova-3, TTS via Aura-2), so
        // it intentionally marks one recommended model per category rather than a
        // single overall recommendation.
        let info = LMAPIProviderRegistry.info(for: .deepgram)
        let recommended = info.models.filter { $0.isRecommended }
        XCTAssertEqual(recommended.count, 2,
                       "Deepgram should recommend one model for STT and one for TTS")
        XCTAssertTrue(recommended.contains { $0.id == "nova-3" },
                      "Deepgram's recommended STT model should be Nova-3")
        XCTAssertTrue(recommended.contains { $0.id == "aura-2" },
                      "Deepgram's recommended TTS model should be Aura-2")
    }

    func testProviderModelIDsAreUnique() {
        for keyType in APIKeyManager.KeyType.allCases {
            let info = LMAPIProviderRegistry.info(for: keyType)
            let ids = info.models.map(\.id)
            XCTAssertEqual(ids.count, Set(ids).count,
                           "\(keyType.rawValue) has duplicate model ids: \(ids)")
        }
    }

    func testCategoriesMatchKnownRoles() {
        XCTAssertEqual(LMAPIProviderRegistry.info(for: .assemblyAI).categories, [.speechToText])
        XCTAssertEqual(LMAPIProviderRegistry.info(for: .openAI).categories, [.languageModel])
        XCTAssertEqual(LMAPIProviderRegistry.info(for: .elevenLabs).categories, [.textToSpeech])
        XCTAssertEqual(LMAPIProviderRegistry.info(for: .braveSearch).categories, [.utility])
        // Deepgram does both STT and TTS.
        XCTAssertEqual(
            Set(LMAPIProviderRegistry.info(for: .deepgram).categories),
            [.speechToText, .textToSpeech]
        )
    }

    // MARK: - Category metadata

    func testEveryCategoryHasCompleteMetadata() {
        for category in LMAPIProviderCategory.allCases {
            XCTAssertFalse(category.displayName.isEmpty)
            XCTAssertFalse(category.shortLabel.isEmpty)
            XCTAssertFalse(category.icon.isEmpty)
            XCTAssertFalse(category.description.isEmpty)
        }
    }

    func testCategoryShortLabelMatchesRawValue() {
        for category in LMAPIProviderCategory.allCases {
            XCTAssertEqual(category.shortLabel, category.rawValue)
        }
    }

    // MARK: - LMAPIPricing formatting

    func testFreePricingFormatsAsFree() {
        XCTAssertEqual(LMAPIPricing.free.formattedCost, "Free")
    }

    func testInputOnlyPricingFormat() {
        let pricing = LMAPIPricing(inputCost: 0.37, inputUnit: .perMinute)
        XCTAssertEqual(pricing.formattedCost, "$0.370 per minute")
    }

    func testInputAndOutputPricingFormat() {
        let pricing = LMAPIPricing(
            inputCost: 2.50,
            outputCost: 10.00,
            inputUnit: .perMillionInputTokens,
            outputUnit: .perMillionOutputTokens
        )
        XCTAssertEqual(
            pricing.formattedCost,
            "$2.50 per 1M input tokens / $10.00 per 1M output tokens"
        )
    }

    func testVerySmallCostUsesSixDecimals() {
        // Values below 0.01 format with six decimal places.
        let pricing = LMAPIPricing(inputCost: 0.000018, inputUnit: .perCharacter)
        XCTAssertEqual(pricing.formattedCost, "$0.000018 per character")
    }

    func testSubDollarCostUsesThreeDecimals() {
        // Values >= 0.01 and < 1 format with three decimal places.
        let pricing = LMAPIPricing(inputCost: 0.18, inputUnit: .perThousandCharacters)
        XCTAssertEqual(pricing.formattedCost, "$0.180 per 1K characters")
    }

    // MARK: - ConversationCostEstimate formatting

    func testConversationEstimateFormatsZeroAsFree() {
        let estimate = ConversationCostEstimate(
            tenMinuteCost: 0,
            sixtyMinuteCost: 0,
            assumptions: "free tier"
        )
        XCTAssertEqual(estimate.formattedTenMinute, "Free")
        XCTAssertEqual(estimate.formattedSixtyMinute, "Free")
    }

    func testConversationEstimateFormatsTinyCostWithThreshold() {
        let estimate = ConversationCostEstimate(
            tenMinuteCost: 0.004,
            sixtyMinuteCost: 0.54,
            assumptions: "x"
        )
        XCTAssertEqual(estimate.formattedTenMinute, "<$0.01")
        XCTAssertEqual(estimate.formattedSixtyMinute, "$0.54")
    }

    // MARK: - CombinedCostEstimator

    func testEstimateOnDeviceCombinationIsFree() {
        // .google maps to the default branch in every switch, yielding zero cost.
        let estimate = CombinedCostEstimator.estimate(
            durationMinutes: 30,
            sttProvider: .google,
            llmProvider: .google,
            ttsProvider: .google
        )
        XCTAssertEqual(estimate.sttCost, 0)
        XCTAssertEqual(estimate.llmCost, 0)
        XCTAssertEqual(estimate.ttsCost, 0)
        XCTAssertEqual(estimate.totalCost, 0)
        XCTAssertEqual(estimate.sttProvider, "On-Device")
        XCTAssertEqual(estimate.formattedTotal, "Free")
        XCTAssertEqual(estimate.duration, 30)
    }

    func testEstimateDeepgramOpenAIDeepgramMath() {
        let duration = 60
        let estimate = CombinedCostEstimator.estimate(
            durationMinutes: duration,
            sttProvider: .deepgram,
            llmProvider: .openAI,
            ttsProvider: .deepgram
        )

        // Recompute the documented assumptions independently.
        let speechMinutes = Double(duration) * 0.5
        let tokensInput = Double(duration) * 200
        let tokensOutput = Double(duration) * 150
        let ttsCharacters = Double(duration) * 250

        let expectedSTT = speechMinutes * 0.0043
        let expectedLLM = (tokensInput * 2.50 / 1_000_000) + (tokensOutput * 10.0 / 1_000_000)
        let expectedTTS = ttsCharacters * 0.0135 / 1000

        XCTAssertEqual(estimate.sttCost, expectedSTT, accuracy: 1e-9)
        XCTAssertEqual(estimate.llmCost, expectedLLM, accuracy: 1e-9)
        XCTAssertEqual(estimate.ttsCost, expectedTTS, accuracy: 1e-9)
        XCTAssertEqual(estimate.totalCost, expectedSTT + expectedLLM + expectedTTS, accuracy: 1e-9)
        XCTAssertEqual(estimate.sttProvider, "Deepgram")
        XCTAssertEqual(estimate.llmProvider, "OpenAI GPT-4o")
        XCTAssertEqual(estimate.ttsProvider, "Deepgram Aura")
    }

    func testEstimateAnthropicCostsMoreThanOpenAIForSameTokens() {
        let openAI = CombinedCostEstimator.estimate(
            durationMinutes: 30,
            sttProvider: .google,
            llmProvider: .openAI,
            ttsProvider: .google
        )
        let anthropic = CombinedCostEstimator.estimate(
            durationMinutes: 30,
            sttProvider: .google,
            llmProvider: .anthropic,
            ttsProvider: .google
        )
        XCTAssertGreaterThan(anthropic.llmCost, openAI.llmCost,
                             "Claude 3.5 Sonnet is priced above GPT-4o for identical token counts")
        XCTAssertEqual(anthropic.llmProvider, "Claude 3.5 Sonnet")
    }

    func testEstimateAssemblyAIAndElevenLabsBranches() {
        let estimate = CombinedCostEstimator.estimate(
            durationMinutes: 20,
            sttProvider: .assemblyAI,
            llmProvider: .google,
            ttsProvider: .elevenLabs
        )

        let speechMinutes = Double(20) * 0.5
        let ttsCharacters = Double(20) * 250

        XCTAssertEqual(estimate.sttCost, speechMinutes * 0.0062, accuracy: 1e-9)
        XCTAssertEqual(estimate.ttsCost, ttsCharacters * 0.00018, accuracy: 1e-9)
        XCTAssertEqual(estimate.sttProvider, "AssemblyAI")
        XCTAssertEqual(estimate.ttsProvider, "ElevenLabs")
    }

    func testSessionCostEstimateBreakdownIncludesAllProviders() {
        let estimate = CombinedCostEstimator.estimate(durationMinutes: 10)
        let breakdown = estimate.breakdown
        XCTAssertTrue(breakdown.contains("STT"))
        XCTAssertTrue(breakdown.contains("LLM"))
        XCTAssertTrue(breakdown.contains("TTS"))
    }

    func testFormattedTotalUsesTinyThreshold() {
        let tiny = CombinedCostEstimator.SessionCostEstimate(
            sttCost: 0.001,
            llmCost: 0.001,
            ttsCost: 0.001,
            totalCost: 0.003,
            sttProvider: "a",
            llmProvider: "b",
            ttsProvider: "c",
            duration: 1
        )
        XCTAssertEqual(tiny.formattedTotal, "<$0.01")
    }

    func testPreComputedEstimatesAreSelfConsistent() {
        let costOptimized = CombinedCostEstimator.costOptimizedEstimate10Min
        XCTAssertEqual(costOptimized.duration, 10)
        XCTAssertEqual(
            costOptimized.totalCost,
            costOptimized.sttCost + costOptimized.llmCost + costOptimized.ttsCost,
            accuracy: 1e-9
        )

        let balanced60 = CombinedCostEstimator.balancedEstimate60Min
        XCTAssertEqual(balanced60.duration, 60)
        XCTAssertGreaterThan(balanced60.totalCost, 0)
    }
}
