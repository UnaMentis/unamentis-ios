// UnaMentis - Barge-In Metrics Tests
// Deterministic checks of the aggregation math with hand-computed expectations.

import XCTest
@testable import UnaMentis

final class BargeInMetricsTests: XCTestCase {

    private func outcome(
        _ id: String,
        _ type: BargeInClipType,
        detected: Bool,
        reaction: Double? = nil,
        firstPartial: Double? = nil,
        predicted: BargeInCategory? = nil
    ) -> BargeInClipOutcome {
        BargeInClipOutcome(
            clipId: id, type: type, detected: detected,
            reactionMs: reaction, firstPartialMs: firstPartial, predictedClass: predicted
        )
    }

    func testPerfectRun() {
        let outcomes = [
            outcome("c1", .command, detected: true, reaction: 100, firstPartial: 300, predicted: .command),
            outcome("c2", .command, detected: true, reaction: 200, firstPartial: 320, predicted: .command),
            outcome("e1", .engagement, detected: true, reaction: 150, firstPartial: 400, predicted: .engagement),
            outcome("e2", .engagement, detected: true, reaction: 250, firstPartial: 350, predicted: .engagement),
            outcome("n1", .noise, detected: false),
            outcome("n2", .noise, detected: false),
            outcome("x1", .echo, detected: false),
            outcome("x2", .echo, detected: false)
        ]
        let m = BargeInMetrics.compute(from: outcomes)

        XCTAssertEqual(m.detectionRecall, 1.0)
        XCTAssertEqual(m.falsePositiveRate, 0.0)
        XCTAssertEqual(m.commandVsEngagementMacroF1, 1.0)
        XCTAssertEqual(m.positiveSamples, 4)
        XCTAssertEqual(m.negativeSamples, 4)
        XCTAssertEqual(m.detectedCount, 4)
        XCTAssertEqual(m.falsePositiveCount, 0)
        XCTAssertEqual(m.classifiedSamples, 4)
        // reactions [100,200,150,250] -> median 175, p95 (nearest-rank) 250
        XCTAssertEqual(m.reactionMsMedian, 175)
        XCTAssertEqual(m.reactionMsP95, 250)
    }

    func testMissedDetectionAndFalsePositive() {
        let outcomes = [
            outcome("c1", .command, detected: true, reaction: 120, predicted: .command),
            outcome("c2", .command, detected: false), // missed
            outcome("e1", .engagement, detected: true, reaction: 180, predicted: .engagement),
            outcome("e2", .engagement, detected: true, reaction: 160, predicted: .engagement),
            outcome("n1", .noise, detected: true), // false positive
            outcome("n2", .noise, detected: false),
            outcome("x1", .echo, detected: false),
            outcome("x2", .echo, detected: false)
        ]
        let m = BargeInMetrics.compute(from: outcomes)

        XCTAssertEqual(m.detectionRecall, 0.75)            // 3 of 4 positives detected
        XCTAssertEqual(m.falsePositiveRate, 0.25)          // 1 of 4 negatives detected
        XCTAssertEqual(m.detectedCount, 3)
        XCTAssertEqual(m.falsePositiveCount, 1)
        XCTAssertEqual(m.classifiedSamples, 3)             // only detected+predicted positives
    }

    func testMacroF1WithOneMisclassification() {
        // c2 is a command misclassified as engagement; everything else correct.
        let outcomes = [
            outcome("c1", .command, detected: true, predicted: .command),
            outcome("c2", .command, detected: true, predicted: .engagement),
            outcome("e1", .engagement, detected: true, predicted: .engagement),
            outcome("e2", .engagement, detected: true, predicted: .engagement)
        ]
        let m = BargeInMetrics.compute(from: outcomes)
        // command F1 = 0.6667, engagement F1 = 0.8, macro = 0.7333
        XCTAssertNotNil(m.commandVsEngagementMacroF1)
        XCTAssertEqual(m.commandVsEngagementMacroF1!, 0.7333, accuracy: 0.001)
    }

    func testEmptyOutcomesYieldNilMetrics() {
        let m = BargeInMetrics.compute(from: [])
        XCTAssertNil(m.detectionRecall)
        XCTAssertNil(m.falsePositiveRate)
        XCTAssertNil(m.commandVsEngagementMacroF1)
        XCTAssertNil(m.reactionMsMedian)
        XCTAssertNil(m.sttFirstPartialMsMedian)
        XCTAssertEqual(m.positiveSamples, 0)
        XCTAssertEqual(m.negativeSamples, 0)
    }

    func testFirstPartialMedianIgnoresMissingValues() {
        let outcomes = [
            outcome("c1", .command, detected: true, firstPartial: 300, predicted: .command),
            outcome("c2", .command, detected: true, firstPartial: nil, predicted: .command),
            outcome("e1", .engagement, detected: true, firstPartial: 500, predicted: .engagement)
        ]
        let m = BargeInMetrics.compute(from: outcomes)
        // [300, 500] -> median 400
        XCTAssertEqual(m.sttFirstPartialMsMedian, 400)
        XCTAssertEqual(m.firstPartialSamples, 2)
    }

    func testFirstPartialExcludesFalsePositives() {
        // A noise clip wrongly detected with a first-partial must not skew the
        // STT latency median, which should reflect true positives only.
        let outcomes = [
            outcome("c1", .command, detected: true, firstPartial: 400, predicted: .command),
            outcome("n1", .noise, detected: true, firstPartial: 50) // false positive
        ]
        let m = BargeInMetrics.compute(from: outcomes)
        XCTAssertEqual(m.sttFirstPartialMsMedian, 400, "the 50ms false-positive partial is excluded")
        XCTAssertEqual(m.firstPartialSamples, 1)
        XCTAssertEqual(m.falsePositiveCount, 1)
    }

    func testCodableRoundTrip() throws {
        let m = BargeInMetrics.compute(from: [
            outcome("c1", .command, detected: true, reaction: 100, predicted: .command),
            outcome("n1", .noise, detected: false)
        ])
        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(BargeInMetrics.self, from: data)
        XCTAssertEqual(decoded, m)
    }
}
