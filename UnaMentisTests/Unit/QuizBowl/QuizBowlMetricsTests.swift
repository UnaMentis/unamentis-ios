// UnaMentis - Quiz Bowl Metrics Tests
// Proves the Quiz Bowl metrics the spec calls for compute correctly from tossup
// outcomes and bonus totals (QUIZ_BOWL_MODULE_SPEC.md section 6): power rate, neg
// rate, points-per-bonus, and the celerity proxy.

import XCTest
@testable import UnaMentis

final class QuizBowlMetricsTests: XCTestCase {
    private func outcome(correct: Bool, power: Bool = false, neg: Bool = false, ms: Int = 0) -> QBTossupOutcome {
        QBTossupOutcome(correct: correct, wasPower: power, wasNeg: neg, responseTimeMs: ms)
    }

    func testEmptyMetrics_areAllZero() {
        let m = QBMetrics.empty
        XCTAssertEqual(m.powerRate, 0)
        XCTAssertEqual(m.negRate, 0)
        XCTAssertEqual(m.pointsPerBonus, 0)
        XCTAssertNil(m.celeritySecondsProxy)
    }

    func testPowerRate_isPowersOverCorrect() {
        let tossups = [
            outcome(correct: true, power: true),
            outcome(correct: true, power: false),
            outcome(correct: false, neg: true)
        ]
        let m = QBMetrics.compute(tossups: tossups, bonusTotals: [])
        XCTAssertEqual(m.tossupsAnswered, 3)
        XCTAssertEqual(m.tossupsCorrect, 2)
        XCTAssertEqual(m.powers, 1)
        XCTAssertEqual(m.powerRate, 0.5, accuracy: 0.0001, "1 power over 2 correct = 0.5")
    }

    func testNegRate_isNegsOverAnswered() {
        let tossups = [
            outcome(correct: true),
            outcome(correct: false, neg: true),
            outcome(correct: false, neg: true),
            outcome(correct: false, neg: false)
        ]
        let m = QBMetrics.compute(tossups: tossups, bonusTotals: [])
        XCTAssertEqual(m.negRate, 0.5, accuracy: 0.0001, "2 negs over 4 answered = 0.5")
    }

    func testPointsPerBonus_isMeanBonusTotal() {
        let m = QBMetrics.compute(tossups: [], bonusTotals: [30, 20, 10])
        XCTAssertEqual(m.bonusesHeard, 3)
        XCTAssertEqual(m.bonusPoints, 60)
        XCTAssertEqual(m.pointsPerBonus, 20, accuracy: 0.0001)
    }

    func testCelerityProxy_isMeanCorrectResponseSeconds() {
        let tossups = [
            outcome(correct: true, ms: 2000),
            outcome(correct: true, ms: 4000),
            outcome(correct: false, neg: true, ms: 500)  // excluded: not correct
        ]
        let m = QBMetrics.compute(tossups: tossups, bonusTotals: [])
        let celerity = try? XCTUnwrap(m.celeritySecondsProxy)
        XCTAssertEqual(celerity ?? 0, 3.0, accuracy: 0.0001, "(2 + 4) / 2 = 3 seconds")
    }

    /// Two sessions finishing at once must both land. `record` is a
    /// read-modify-write across two suspension points, so without a serializer
    /// both reads see the same baseline and the second write erases the first.
    /// Real over mock: the real file-backed progress store on a temp root.
    func testStatsStore_concurrentRecords_doNotLoseUpdates() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QBStats-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = QBStatsStore(progress: FileProgressStoreService(root: root))
        let played = outcome(correct: true, power: true, ms: 1000)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    await store.record(
                        formatId: "qb-naqt", tossups: [played], bonusTotals: [10]
                    )
                }
            }
        }

        let stats = await store.stats(for: "qb-naqt")
        XCTAssertEqual(stats.tossupsAnswered, 16, "Every concurrent record must land")
        XCTAssertEqual(stats.tossupsCorrect, 16)
        XCTAssertEqual(stats.powers, 16)
        XCTAssertEqual(stats.bonusesHeard, 16)
        XCTAssertEqual(stats.bonusPoints, 160)
    }

    func testFormatStats_mergeAccumulatesAcrossSessions() {
        var stats = QBFormatStats()
        stats.merge(tossups: [outcome(correct: true, power: true, ms: 1000)], bonusTotals: [30])
        stats.merge(tossups: [outcome(correct: false, neg: true)], bonusTotals: [])
        let m = stats.metrics
        XCTAssertEqual(m.tossupsAnswered, 2)
        XCTAssertEqual(m.tossupsCorrect, 1)
        XCTAssertEqual(m.powers, 1)
        XCTAssertEqual(m.negs, 1)
        XCTAssertEqual(m.bonusesHeard, 1)
        XCTAssertEqual(m.bonusPoints, 30)
    }
}
