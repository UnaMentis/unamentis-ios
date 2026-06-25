// UnaMentis - Confidence Monitor Tests
// Unit tests for ConfidenceMonitor, the actor that analyzes LLM response text for
// uncertainty markers and decides when context expansion should be triggered.
//
// This is pure, deterministic logic with no external dependencies, so the monitor
// uses its real implementation. There are no mocks. The monitor is an actor, so
// every interaction is awaited. Expected numeric values below are derived directly
// from the scoring tables and weights in ConfidenceMonitor.swift. For the default
// config the weights are hedging 0.3, deflection 0.25, knowledgeGap 0.3, vague 0.15,
// confidenceScore == max(0, 1 - uncertaintyScore), expansionThreshold 0.6,
// trendThreshold 0.7.
//
// A small partial suite named ConfidenceMonitorTests already lives in
// FOVContextTests.swift. This file is the dedicated, exhaustive suite, so it uses a
// distinct class name to avoid a redeclaration and focuses on exact computed values,
// trend transitions, reset, scope/priority precedence, ordering, and config behavior
// that the existing suite does not cover.

import XCTest
@testable import UnaMentis

final class ConfidenceMonitorBehaviorTests: XCTestCase {

    // Small tolerance for Double comparisons on weighted sums.
    private let accuracy = 1e-9

    // MARK: - High confidence

    func testAnalyzeResponse_confidentMarkerFreeAnswerIsHighConfidence() async {
        let monitor = ConfidenceMonitor()

        // No hedging, deflection, knowledge-gap, or vague terms appear in this text.
        let analysis = await monitor.analyzeResponse("Paris is the capital of France.")

        XCTAssertEqual(analysis.confidenceScore, 1.0, accuracy: accuracy)
        XCTAssertEqual(analysis.uncertaintyScore, 0.0, accuracy: accuracy)
        XCTAssertTrue(analysis.detectedMarkers.isEmpty)
        XCTAssertTrue(analysis.isHighConfidence)
        XCTAssertFalse(analysis.isLowConfidence)
    }

    // MARK: - Hedging

    func testAnalyzeResponse_hedgedAnswerInsertsHedgingMarker() async {
        let monitor = ConfidenceMonitor()

        // "i'm not sure" weight 0.8, "i'm uncertain" weight 0.9.
        // hedgingScore = min(1, (0.8 + 0.9) / 2) = 0.85.
        // uncertainty = 0.85 * 0.3 = 0.255, confidence = 0.745.
        let analysis = await monitor.analyzeResponse(
            "I'm not sure, and honestly I'm uncertain about that."
        )

        XCTAssertEqual(analysis.hedgingScore, 0.85, accuracy: accuracy)
        XCTAssertEqual(analysis.uncertaintyScore, 0.255, accuracy: accuracy)
        XCTAssertEqual(analysis.confidenceScore, 0.745, accuracy: accuracy)
        XCTAssertEqual(analysis.detectedMarkers, [.hedging])
    }

    func testAnalyzeResponse_heavilyHedgedAndGappedAnswerIsLowConfidence() async {
        let monitor = ConfidenceMonitor()

        // hedging: "i'm uncertain" (0.9) -> min(1, 0.9) = 0.9 -> *0.3 = 0.27
        // knowledgeGap: "i don't know" (0.9) -> 0.9 -> *0.3 = 0.27
        // deflection: "you should ask" (0.6) -> 0.6 -> *0.25 = 0.15
        // uncertaintyScore = 0.27 + 0.27 + 0.15 = 0.69, confidence = 0.31.
        let analysis = await monitor.analyzeResponse(
            "I'm uncertain. Honestly I don't know, you should ask an expert."
        )

        XCTAssertEqual(analysis.uncertaintyScore, 0.69, accuracy: accuracy)
        XCTAssertEqual(analysis.confidenceScore, 0.31, accuracy: accuracy)
        XCTAssertTrue(analysis.isLowConfidence)
        XCTAssertFalse(analysis.isHighConfidence)
    }

    // MARK: - Specific marker classes

    func testAnalyzeResponse_knowledgeGapPhrasePinsScoreAndMarker() async {
        let monitor = ConfidenceMonitor()
        let analysis = await monitor.analyzeResponse("I'm not familiar with that topic.")

        // "i'm not familiar" knowledgeGap weight 0.8 -> *0.3 = 0.24 uncertainty,
        // confidence 0.76, and the only marker is .knowledgeGap.
        XCTAssertEqual(analysis.knowledgeGapScore, 0.8, accuracy: accuracy)
        XCTAssertEqual(analysis.confidenceScore, 0.76, accuracy: accuracy)
        XCTAssertEqual(analysis.detectedMarkers, [.knowledgeGap])
    }

    func testAnalyzeResponse_eachMarkerClassMapsToExactlyOneMarker() async {
        // Table-driven: every phrase class maps to exactly its own marker and no other.
        // The set equality is the contract, not mere membership.
        let cases: [(text: String, expected: ConfidenceMarker)] = [
            ("I'm not sure about this.", .hedging),
            ("I don't know the answer.", .knowledgeGap),
            ("You should ask a specialist.", .deflection),
            ("Beyond the scope of this lesson.", .topicBoundary),
            ("That is not within my abilities.", .outOfScope),
            ("What do you mean by that?", .clarificationNeeded),
            ("I would speculate it is true.", .speculation)
        ]

        for testCase in cases {
            let monitor = ConfidenceMonitor()
            let analysis = await monitor.analyzeResponse(testCase.text)
            XCTAssertEqual(
                analysis.detectedMarkers,
                [testCase.expected],
                "Expected exactly [\(testCase.expected)] for text: \(testCase.text)"
            )
        }
    }

    // MARK: - Confidence / uncertainty clamp

    func testAnalyzeResponse_confidenceFloorsAtZeroWhenUncertaintyExceedsOne() async {
        // The default config caps uncertainty at 0.945, so the max(0, ...) floor can only
        // be exercised with weights whose maxima sum past 1.0. Inflate every weight so a
        // fully saturated response drives raw uncertainty above 1.0, then confirm the
        // floor clamps confidence to exactly 0.0 (not a negative value).
        let monitor = ConfidenceMonitor(
            config: ConfidenceConfig(
                expansionThreshold: 0.6,
                trendThreshold: 0.7,
                hedgingWeight: 1.0,
                deflectionWeight: 1.0,
                knowledgeGapWeight: 1.0,
                vagueLanguageWeight: 1.0
            )
        )

        // hedging "i'm uncertain" (0.9), knowledgeGap "i don't know" (0.9),
        // deflection "you should ask" (0.6), vague "it depends" (>0). Raw uncertainty
        // = 0.9 + 0.9 + 0.6 + vague > 1.0, so confidence must clamp to 0.0.
        let analysis = await monitor.analyzeResponse(
            "I'm uncertain. I don't know. You should ask someone. It depends."
        )

        XCTAssertGreaterThan(analysis.uncertaintyScore, 1.0)
        XCTAssertEqual(analysis.confidenceScore, 0.0, accuracy: accuracy)
    }

    // MARK: - shouldTriggerExpansion: isolated trigger paths

    func testShouldTriggerExpansion_falseForConfidentMarkerFreeResponse() async {
        let monitor = ConfidenceMonitor()
        let analysis = await monitor.analyzeResponse("The mitochondria is the powerhouse of the cell.")

        XCTAssertEqual(analysis.confidenceScore, 1.0, accuracy: accuracy)
        let triggered = await monitor.shouldTriggerExpansion(analysis)
        XCTAssertFalse(triggered)
    }

    func testShouldTriggerExpansion_trueWhenConfidenceBelowThreshold() async {
        let monitor = ConfidenceMonitor()
        // confidence 0.31 (computed above) < expansionThreshold 0.6.
        let analysis = await monitor.analyzeResponse(
            "I'm uncertain. Honestly I don't know, you should ask an expert."
        )

        let triggered = await monitor.shouldTriggerExpansion(analysis)
        XCTAssertTrue(triggered)
        XCTAssertLessThan(analysis.confidenceScore, 0.6)
    }

    func testShouldTriggerExpansion_trueOnHighSignalMarkerAboveThreshold() async {
        let monitor = ConfidenceMonitor()
        // "beyond the scope" inserts .topicBoundary (a high-signal marker) but the
        // deflection phrase "that's beyond" scores only 0.7 * 0.25 = 0.175 of uncertainty,
        // so confidence 0.825 stays above the 0.6 threshold. The marker alone must trigger.
        let analysis = await monitor.analyzeResponse("That's beyond the scope of this lesson.")

        XCTAssertEqual(analysis.confidenceScore, 0.825, accuracy: accuracy)
        XCTAssertEqual(analysis.detectedMarkers, [.topicBoundary])
        let triggered = await monitor.shouldTriggerExpansion(analysis)
        XCTAssertTrue(triggered)
    }

    func testShouldTriggerExpansion_trueOnDecliningTrendBelowTrendThreshold() async {
        let monitor = ConfidenceMonitor()

        // Build a declining trend: high, then progressively lower confidence.
        // Window confidences become [1.0, 0.85, 0.649825].
        _ = await monitor.analyzeResponse("Absolutely, the answer is definitively seven.")
        _ = await monitor.analyzeResponse("It might be seven, perhaps.")
        // Final response is chosen so confidence lands in [expansionThreshold 0.6,
        // trendThreshold 0.7). hedging "i'm not sure" (0.8)->0.24 plus vague "it depends"
        // (0.7345*0.15) gives uncertainty 0.350175, confidence 0.649825. That is NOT below
        // the expansion threshold and .hedging is not a high-signal marker, so ONLY the
        // declining-trend path can fire. This isolates the trend trigger.
        let analysis = await monitor.analyzeResponse("Well, I'm not sure, it depends.")

        XCTAssertEqual(analysis.trend, .declining)
        XCTAssertEqual(analysis.confidenceScore, 0.649825, accuracy: accuracy)
        XCTAssertGreaterThanOrEqual(analysis.confidenceScore, 0.6)
        XCTAssertLessThan(analysis.confidenceScore, 0.7)
        XCTAssertEqual(analysis.detectedMarkers, [.hedging])
        let triggered = await monitor.shouldTriggerExpansion(analysis)
        XCTAssertTrue(triggered)
    }

    func testShouldTriggerExpansion_falseForDecliningTrendAboveTrendThreshold() async {
        let monitor = ConfidenceMonitor()

        // A declining trend alone is not enough: the trend path also requires confidence
        // below trendThreshold 0.7. Drive a small decline that ends above 0.7 with no
        // high-signal marker, so no trigger path fires.
        // Window confidences: [1.0, 1.0, 0.745], delta -0.255 < -0.15 -> declining.
        _ = await monitor.analyzeResponse("The answer is clearly twelve.")
        _ = await monitor.analyzeResponse("Tokyo is the capital of Japan.")
        // hedging "i'm not sure" (0.8) -> *0.3 = 0.24 uncertainty, confidence 0.76 > 0.7.
        let analysis = await monitor.analyzeResponse("Honestly, I'm not sure about that.")

        XCTAssertEqual(analysis.trend, .declining)
        XCTAssertEqual(analysis.confidenceScore, 0.76, accuracy: accuracy)
        // Confidence sits above the default trendThreshold of 0.7, so the trend path is gated off.
        XCTAssertGreaterThanOrEqual(analysis.confidenceScore, ConfidenceConfig.default.trendThreshold)
        XCTAssertEqual(analysis.detectedMarkers, [.hedging])
        let triggered = await monitor.shouldTriggerExpansion(analysis)
        XCTAssertFalse(triggered)
    }

    // MARK: - getExpansionRecommendation

    func testGetExpansionRecommendation_notTriggeredReturnsNoExpansion() async {
        let monitor = ConfidenceMonitor()
        let analysis = await monitor.analyzeResponse("The capital of Japan is Tokyo.")

        let recommendation = await monitor.getExpansionRecommendation(analysis)

        XCTAssertFalse(recommendation.shouldExpand)
        XCTAssertEqual(recommendation.priority, .none)
        XCTAssertEqual(recommendation.suggestedScope, .currentTopic)
        XCTAssertNil(recommendation.reason)
    }

    func testGetExpansionRecommendation_highPriorityWhenConfidenceVeryLow() async {
        let monitor = ConfidenceMonitor()
        // hedging "i'm uncertain" (0.9)->*0.3=0.27, gap "i don't know" (0.9)->*0.3=0.27,
        // deflection "i don't have enough information" (0.9)->*0.25=0.225.
        // uncertainty = 0.765, confidence = 0.235 < 0.3 -> high priority.
        let analysis = await monitor.analyzeResponse(
            "I'm uncertain, I don't know, and I don't have enough information."
        )

        XCTAssertEqual(analysis.confidenceScore, 0.235, accuracy: accuracy)
        let recommendation = await monitor.getExpansionRecommendation(analysis)
        XCTAssertTrue(recommendation.shouldExpand)
        XCTAssertEqual(recommendation.priority, .high)
    }

    func testGetExpansionRecommendation_mediumPriorityForMidConfidence() async {
        let monitor = ConfidenceMonitor()
        // confidence 0.31 is in [0.3, 0.5) -> medium priority.
        let analysis = await monitor.analyzeResponse(
            "I'm uncertain. Honestly I don't know, you should ask an expert."
        )

        XCTAssertEqual(analysis.confidenceScore, 0.31, accuracy: accuracy)
        let recommendation = await monitor.getExpansionRecommendation(analysis)
        XCTAssertEqual(recommendation.priority, .medium)
    }

    func testGetExpansionRecommendation_lowPriorityWhenTriggeredByMarkerAtHighConfidence() async {
        let monitor = ConfidenceMonitor()
        // topicBoundary marker triggers, confidence 0.825 >= 0.5 -> low priority.
        let analysis = await monitor.analyzeResponse("That's beyond the scope of this lesson.")

        XCTAssertEqual(analysis.confidenceScore, 0.825, accuracy: accuracy)
        let recommendation = await monitor.getExpansionRecommendation(analysis)
        XCTAssertTrue(recommendation.shouldExpand)
        XCTAssertEqual(recommendation.priority, .low)
    }

    func testGetExpansionRecommendation_scopeRelatedTopicsForBoundaryMarker() async {
        let monitor = ConfidenceMonitor()
        let analysis = await monitor.analyzeResponse("That's beyond the scope of this lesson.")

        XCTAssertTrue(analysis.detectedMarkers.contains(.topicBoundary))
        let recommendation = await monitor.getExpansionRecommendation(analysis)
        XCTAssertEqual(recommendation.suggestedScope, .relatedTopics)
    }

    func testGetExpansionRecommendation_scopeCurrentUnitForKnowledgeGap() async {
        let monitor = ConfidenceMonitor()
        // "i don't know" -> knowledgeGapScore 0.9 > 0.5, and the marker is .knowledgeGap
        // (not out-of-scope/topic-boundary), so scope falls to .currentUnit.
        let analysis = await monitor.analyzeResponse("I don't know the answer to that.")

        XCTAssertEqual(analysis.knowledgeGapScore, 0.9, accuracy: accuracy)
        XCTAssertFalse(analysis.detectedMarkers.contains(.outOfScope))
        XCTAssertFalse(analysis.detectedMarkers.contains(.topicBoundary))
        let recommendation = await monitor.getExpansionRecommendation(analysis)
        XCTAssertEqual(recommendation.suggestedScope, .currentUnit)
    }

    func testGetExpansionRecommendation_reasonMatchesKnowledgeGapPrecedence() async {
        let monitor = ConfidenceMonitor()
        // knowledgeGapScore > 0.5 has highest precedence in determineExpansionReason.
        let analysis = await monitor.analyzeResponse("I don't know the answer to that.")

        let recommendation = await monitor.getExpansionRecommendation(analysis)
        XCTAssertEqual(recommendation.reason, "Knowledge gap detected in response")
    }

    func testGetExpansionRecommendation_reasonDecliningTrendWhenNoStrongerSignal() async {
        let monitor = ConfidenceMonitor()

        // Isolate the declining-trend reason branch. determineExpansionReason checks, in
        // order: knowledgeGapScore > 0.5, hedgingScore > 0.6, deflectionScore > 0.5,
        // clarification marker, then declining trend. The triggering response must clear all
        // of those higher-precedence checks for the declining-trend reason to surface.
        // "to my knowledge" gives hedgingScore exactly 0.6 (not > 0.6), and "it depends" plus
        // "sort of" saturate vague language. uncertainty = 0.6*0.3 + 1.0*0.15 = 0.33,
        // confidence 0.67. That is above expansionThreshold 0.6, so the only trigger left is
        // the declining trend (confidence 0.67 < trendThreshold 0.7).
        // Window confidences [1.0, 1.0, 0.67], delta -0.33 -> declining.
        _ = await monitor.analyzeResponse("The answer is clearly twelve.")
        _ = await monitor.analyzeResponse("Tokyo is the capital of Japan.")
        let analysis = await monitor.analyzeResponse("To my knowledge, it depends, sort of.")

        XCTAssertEqual(analysis.knowledgeGapScore, 0.0, accuracy: accuracy)
        XCTAssertEqual(analysis.hedgingScore, 0.6, accuracy: accuracy)
        XCTAssertEqual(analysis.questionDeflectionScore, 0.0, accuracy: accuracy)
        XCTAssertFalse(analysis.detectedMarkers.contains(.clarificationNeeded))
        XCTAssertEqual(analysis.trend, .declining)
        XCTAssertEqual(analysis.confidenceScore, 0.67, accuracy: accuracy)
        XCTAssertGreaterThanOrEqual(analysis.confidenceScore, 0.6)
        XCTAssertLessThan(analysis.confidenceScore, 0.7)

        let recommendation = await monitor.getExpansionRecommendation(analysis)
        XCTAssertTrue(recommendation.shouldExpand)
        XCTAssertEqual(recommendation.reason, "Declining confidence trend")
    }

    func testGetExpansionRecommendation_clarificationOnlyResponseDoesNotTrigger() async {
        let monitor = ConfidenceMonitor()
        // "could you clarify" -> knowledgeGapScore 0.5 -> *0.3 = 0.15 uncertainty,
        // confidence 0.85, which is above expansionThreshold 0.6. The .clarificationNeeded
        // marker is not a high-signal marker and the trend is stable, so none of the
        // trigger paths fire. The recommendation must be the not-triggered tuple with a
        // nil reason, even though a clarification marker is present.
        let analysis = await monitor.analyzeResponse("Could you clarify the question for me?")

        XCTAssertEqual(analysis.knowledgeGapScore, 0.5, accuracy: accuracy)
        XCTAssertEqual(analysis.confidenceScore, 0.85, accuracy: accuracy)
        XCTAssertTrue(analysis.detectedMarkers.contains(.clarificationNeeded))

        let triggered = await monitor.shouldTriggerExpansion(analysis)
        XCTAssertFalse(triggered)

        let recommendation = await monitor.getExpansionRecommendation(analysis)
        XCTAssertFalse(recommendation.shouldExpand)
        XCTAssertNil(recommendation.reason)
        XCTAssertEqual(recommendation.priority, .none)
    }

    // MARK: - Trend analysis

    func testCalculateTrend_stableWithFewerThanThreeScores() async {
        let monitor = ConfidenceMonitor()

        _ = await monitor.analyzeResponse("Confident statement one.")
        let analysis = await monitor.analyzeResponse("Confident statement two.")

        // Only two scores recorded, so the trend cannot yet be classified.
        XCTAssertEqual(analysis.trend, .stable)
    }

    func testCalculateTrend_improvingWhenConfidenceRises() async {
        let monitor = ConfidenceMonitor()

        // Rising confidence across the 3-response window (delta > 0.15).
        // Low: "i'm uncertain" + "i don't know" -> low confidence, then high.
        _ = await monitor.analyzeResponse("I'm uncertain, I don't know that.")
        _ = await monitor.analyzeResponse("I think it is probably correct.")
        let analysis = await monitor.analyzeResponse("The answer is clearly twelve.")

        XCTAssertEqual(analysis.trend, .improving)
    }

    func testCalculateTrend_decliningWhenConfidenceFalls() async {
        let monitor = ConfidenceMonitor()

        _ = await monitor.analyzeResponse("The answer is clearly twelve.")
        _ = await monitor.analyzeResponse("I think it is probably correct.")
        let analysis = await monitor.analyzeResponse("I'm uncertain, I don't know that.")

        XCTAssertEqual(analysis.trend, .declining)
    }

    func testCalculateTrend_stableWhenConfidenceFlat() async {
        let monitor = ConfidenceMonitor()

        // Three identical fully-confident responses: delta 0, within +/- 0.15.
        _ = await monitor.analyzeResponse("Tokyo is the capital of Japan.")
        _ = await monitor.analyzeResponse("Tokyo is the capital of Japan.")
        let analysis = await monitor.analyzeResponse("Tokyo is the capital of Japan.")

        XCTAssertEqual(analysis.trend, .stable)
    }

    func testCalculateTrend_usesOnlyMostRecentThreeScores() async {
        let monitor = ConfidenceMonitor()

        // The trend window is the suffix of length 3. A deep dip followed by two recoveries
        // must read as improving even though the very first response was confident, because
        // only the last three scores [low, mid, high] are compared.
        // Scores: [1.0, 0.31 (low), 0.745 (mid), 1.0 (high)]. Window = last three.
        _ = await monitor.analyzeResponse("The answer is clearly twelve.")
        _ = await monitor.analyzeResponse("I'm uncertain. Honestly I don't know, you should ask an expert.")
        _ = await monitor.analyzeResponse("I'm not sure, and honestly I'm uncertain about that.")
        let analysis = await monitor.analyzeResponse("Tokyo is the capital of Japan.")

        // Window delta = 1.0 - 0.31 = 0.69 > 0.15 -> improving.
        XCTAssertEqual(analysis.trend, .improving)
    }

    func testReset_clearsHistorySoTrendReturnsToStable() async {
        let monitor = ConfidenceMonitor()

        // Establish a declining trend, then reset.
        _ = await monitor.analyzeResponse("The answer is clearly twelve.")
        _ = await monitor.analyzeResponse("I think it is probably correct.")
        let declining = await monitor.analyzeResponse("I'm uncertain, I don't know that.")
        XCTAssertEqual(declining.trend, .declining)

        await monitor.reset()

        // After reset, a single response has no history, so the trend is stable again.
        let afterReset = await monitor.analyzeResponse("I'm uncertain, I don't know that.")
        XCTAssertEqual(afterReset.trend, .stable)
    }

    // MARK: - ExpansionPriority ordering

    func testExpansionPriority_comparableOrdering() {
        XCTAssertLessThan(ExpansionPriority.none, ExpansionPriority.low)
        XCTAssertLessThan(ExpansionPriority.low, ExpansionPriority.medium)
        XCTAssertLessThan(ExpansionPriority.medium, ExpansionPriority.high)

        let sorted = [ExpansionPriority.high, .none, .medium, .low].sorted()
        XCTAssertEqual(sorted, [.none, .low, .medium, .high])
    }

    // MARK: - Configuration

    func testTutoringConfig_differsFromDefaultInDocumentedWay() {
        let standard = ConfidenceConfig.default
        let tutoring = ConfidenceConfig.tutoring

        // Tutoring is more sensitive: a higher expansion threshold expands sooner.
        XCTAssertEqual(standard.expansionThreshold, 0.6, accuracy: accuracy)
        XCTAssertEqual(tutoring.expansionThreshold, 0.7, accuracy: accuracy)
        XCTAssertGreaterThan(tutoring.expansionThreshold, standard.expansionThreshold)

        // Knowledge gaps and deflection are weighted more heavily for tutoring.
        XCTAssertEqual(tutoring.knowledgeGapWeight, 0.35, accuracy: accuracy)
        XCTAssertGreaterThan(tutoring.knowledgeGapWeight, standard.knowledgeGapWeight)
        XCTAssertEqual(tutoring.deflectionWeight, 0.3, accuracy: accuracy)
        XCTAssertGreaterThan(tutoring.deflectionWeight, standard.deflectionWeight)
    }

    func testUpdateConfig_changesWhichResponsesTriggerExpansion() async {
        let monitor = ConfidenceMonitor()

        // "i'm not sure" -> hedging 0.8 * default weight 0.3 = 0.24 uncertainty,
        // confidence 0.76. Under the default threshold of 0.6 this does NOT trigger,
        // and the lone .hedging marker is not a high-signal marker.
        let analysisDefault = await monitor.analyzeResponse("Honestly, I'm not sure about that.")
        XCTAssertEqual(analysisDefault.confidenceScore, 0.76, accuracy: accuracy)
        let triggeredDefault = await monitor.shouldTriggerExpansion(analysisDefault)
        XCTAssertFalse(triggeredDefault)

        // Raise the expansion threshold above 0.76 so the same confidence now triggers.
        await monitor.updateConfig(
            ConfidenceConfig(
                expansionThreshold: 0.8,
                trendThreshold: 0.7,
                hedgingWeight: 0.3,
                deflectionWeight: 0.25,
                knowledgeGapWeight: 0.3,
                vagueLanguageWeight: 0.15
            )
        )

        await monitor.reset()
        let analysisRaised = await monitor.analyzeResponse("Honestly, I'm not sure about that.")
        XCTAssertEqual(analysisRaised.confidenceScore, 0.76, accuracy: accuracy)
        let triggeredRaised = await monitor.shouldTriggerExpansion(analysisRaised)
        XCTAssertTrue(triggeredRaised)
    }
}
