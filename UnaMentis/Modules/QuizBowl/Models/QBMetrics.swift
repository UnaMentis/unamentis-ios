// UnaMentis - Quiz Bowl Metrics
// The Quiz Bowl performance metrics the spec calls for (QUIZ_BOWL_MODULE_SPEC.md
// section 6): power rate, neg rate, points-per-bonus, and a celerity proxy.
//
// These are pure functions over recorded tossup outcomes and bonus totals, kept
// free of any engine or UI type so they are trivially unit-testable and reusable
// by the dashboard and a future watch surface. A tossup outcome carries only what
// the metrics need: whether it was correct, a power, a neg, and a response-time
// proxy for celerity (the engine reports responseTimeMs; a true character-depth
// celerity needs the buzz index, tracked as a spec friction).
//
// Writing style: no em dashes (see .claude/rules/writing-style.md).

import Foundation

// MARK: - Tossup Outcome

/// The minimal record of one answered tossup the metrics fold over.
public struct QBTossupOutcome: Sendable, Equatable {
    public let correct: Bool
    /// A correct answer on a buzz before the power mark.
    public let wasPower: Bool
    /// An incorrect interrupt buzz that scored the neg value.
    public let wasNeg: Bool
    /// Time from the answer window opening to submission, in milliseconds. Used
    /// as the celerity proxy (lower is faster).
    public let responseTimeMs: Int

    public init(correct: Bool, wasPower: Bool, wasNeg: Bool, responseTimeMs: Int) {
        self.correct = correct
        self.wasPower = wasPower
        self.wasNeg = wasNeg
        self.responseTimeMs = responseTimeMs
    }
}

// MARK: - Metrics

/// Aggregate Quiz Bowl metrics for a set of tossup outcomes and bonuses.
public struct QBMetrics: Sendable, Equatable {
    /// Total tossups that received a submitted answer.
    public let tossupsAnswered: Int
    /// Tossups answered correctly (tens plus powers).
    public let tossupsCorrect: Int
    /// Correct answers earned before the power mark.
    public let powers: Int
    /// Incorrect interrupt buzzes that negged.
    public let negs: Int
    /// Number of bonuses heard (attempted).
    public let bonusesHeard: Int
    /// Total bonus points earned across those bonuses.
    public let bonusPoints: Int
    /// Sum of response times for correct answers, for the celerity proxy.
    private let correctResponseMsSum: Int

    /// Power rate: powers as a share of correct answers. 0 when none correct.
    public var powerRate: Double {
        tossupsCorrect > 0 ? Double(powers) / Double(tossupsCorrect) : 0
    }

    /// Neg rate: negs as a share of answered tossups. 0 when none answered.
    public var negRate: Double {
        tossupsAnswered > 0 ? Double(negs) / Double(tossupsAnswered) : 0
    }

    /// Points per bonus (PPB): mean bonus points across bonuses heard. 0 when
    /// no bonuses were heard.
    public var pointsPerBonus: Double {
        bonusesHeard > 0 ? Double(bonusPoints) / Double(bonusesHeard) : 0
    }

    /// Celerity proxy: the mean response time on correct answers, in seconds.
    /// Lower is faster. This is a proxy: NAQT celerity is defined on buzz depth
    /// in the question, which needs the buzz character index; the engine surfaces
    /// only responseTimeMs today (tracked as a spec friction). Nil when there is
    /// no correct answer to average.
    public var celeritySecondsProxy: Double? {
        tossupsCorrect > 0 ? Double(correctResponseMsSum) / Double(tossupsCorrect) / 1000 : nil
    }

    public init(
        tossupsAnswered: Int,
        tossupsCorrect: Int,
        powers: Int,
        negs: Int,
        bonusesHeard: Int,
        bonusPoints: Int,
        correctResponseMsSum: Int
    ) {
        self.tossupsAnswered = tossupsAnswered
        self.tossupsCorrect = tossupsCorrect
        self.powers = powers
        self.negs = negs
        self.bonusesHeard = bonusesHeard
        self.bonusPoints = bonusPoints
        self.correctResponseMsSum = correctResponseMsSum
    }

    /// Empty metrics (no play yet).
    public static let empty = QBMetrics(
        tossupsAnswered: 0, tossupsCorrect: 0, powers: 0, negs: 0,
        bonusesHeard: 0, bonusPoints: 0, correctResponseMsSum: 0
    )

    /// Fold tossup outcomes and bonus totals into aggregate metrics.
    public static func compute(
        tossups: [QBTossupOutcome],
        bonusTotals: [Int]
    ) -> QBMetrics {
        var answered = 0
        var correct = 0
        var powers = 0
        var negs = 0
        var correctMs = 0
        for outcome in tossups {
            answered += 1
            if outcome.correct {
                correct += 1
                correctMs += outcome.responseTimeMs
                if outcome.wasPower { powers += 1 }
            }
            if outcome.wasNeg { negs += 1 }
        }
        return QBMetrics(
            tossupsAnswered: answered,
            tossupsCorrect: correct,
            powers: powers,
            negs: negs,
            bonusesHeard: bonusTotals.count,
            bonusPoints: bonusTotals.reduce(0, +),
            correctResponseMsSum: correctMs
        )
    }
}
