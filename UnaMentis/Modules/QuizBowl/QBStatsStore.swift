// UnaMentis - Quiz Bowl Per-Format Stats Store
// Persists a running QBMetrics summary per format in the module's private
// key/value store (MODULE_SDK_SPEC.md section 5.4, `keyValue(namespace:)`). The
// dashboard reads these to show per-format power rate, points-per-bonus, neg
// rate, and the celerity proxy; the practice session merges a finished session's
// outcomes in at the end.
//
// This is deliberately a module-private KV summary, not a re-derivation from raw
// AttemptRecords: the host attempt store is per-attempt and not tagged by format
// (a QB attempt records the domain, not which format descriptor produced it), so
// the module keeps its own per-format roll-up. Cross-module proficiency still
// flows through the engine's mastery observations.
//
// Writing style: no em dashes (see .claude/rules/writing-style.md).

import Foundation

/// A persisted per-format stats summary. Codable so it round-trips through the
/// module KV store.
public struct QBFormatStats: Codable, Sendable, Equatable {
    public var tossupsAnswered: Int
    public var tossupsCorrect: Int
    public var powers: Int
    public var negs: Int
    public var bonusesHeard: Int
    public var bonusPoints: Int
    public var correctResponseMsSum: Int

    public init(
        tossupsAnswered: Int = 0,
        tossupsCorrect: Int = 0,
        powers: Int = 0,
        negs: Int = 0,
        bonusesHeard: Int = 0,
        bonusPoints: Int = 0,
        correctResponseMsSum: Int = 0
    ) {
        self.tossupsAnswered = tossupsAnswered
        self.tossupsCorrect = tossupsCorrect
        self.powers = powers
        self.negs = negs
        self.bonusesHeard = bonusesHeard
        self.bonusPoints = bonusPoints
        self.correctResponseMsSum = correctResponseMsSum
    }

    /// The metrics view of this summary.
    public var metrics: QBMetrics {
        QBMetrics(
            tossupsAnswered: tossupsAnswered,
            tossupsCorrect: tossupsCorrect,
            powers: powers,
            negs: negs,
            bonusesHeard: bonusesHeard,
            bonusPoints: bonusPoints,
            correctResponseMsSum: correctResponseMsSum
        )
    }

    /// Fold a finished session's outcomes into this running summary.
    public mutating func merge(tossups: [QBTossupOutcome], bonusTotals: [Int]) {
        for outcome in tossups {
            tossupsAnswered += 1
            if outcome.correct {
                tossupsCorrect += 1
                correctResponseMsSum += outcome.responseTimeMs
                if outcome.wasPower { powers += 1 }
            }
            if outcome.wasNeg { negs += 1 }
        }
        bonusesHeard += bonusTotals.count
        bonusPoints += bonusTotals.reduce(0, +)
    }
}

/// Reads and writes per-format stats through a module KV store.
public struct QBStatsStore: Sendable {
    private let kv: any ModuleKVStore

    /// The KV namespace is the Quiz Bowl module id.
    public init(progress: any ProgressStoreService, moduleId: String = "quiz-bowl") {
        self.kv = progress.keyValue(namespace: moduleId)
    }

    private func key(for formatId: String) -> String { "stats.\(formatId)" }

    /// Load the running stats for a format (empty if none yet).
    public func stats(for formatId: String) async -> QBFormatStats {
        guard let data = await kv.data(forKey: key(for: formatId)),
              let stats = try? JSONDecoder().decode(QBFormatStats.self, from: data) else {
            return QBFormatStats()
        }
        return stats
    }

    /// Merge a finished session's outcomes into the format's running stats.
    ///
    /// Serialized through `QBStatsSerializer`: this is a read-modify-write
    /// across two suspension points, and two sessions finishing at once (a
    /// practice session ending while the dashboard's own write is in flight)
    /// would otherwise both read the same baseline and the second write would
    /// erase the first.
    public func record(
        formatId: String,
        tossups: [QBTossupOutcome],
        bonusTotals: [Int]
    ) async {
        await QBStatsSerializer.shared.merge(
            tossups: tossups,
            bonusTotals: bonusTotals,
            forKey: key(for: formatId),
            in: kv
        )
    }
}

// MARK: - Serialized Read-Modify-Write

/// The single owner of Quiz Bowl stats mutation.
///
/// Actor isolation alone does NOT fix the lost update: actors are reentrant, so
/// a second `merge` runs its load while the first is suspended on its own load,
/// and both write from the same baseline. So the actor keeps a chain instead:
/// every merge awaits the previous merge's completion before it reads, which
/// makes each read-modify-write atomic with respect to the others.
///
/// The chain is process-wide (a shared instance) on purpose. `QBStatsStore` is
/// a value type that call sites construct freely, so serializing inside one
/// store instance would not serialize anything: two stores over the same module
/// KV namespace are the exact case that loses an update.
actor QBStatsSerializer {
    static let shared = QBStatsSerializer()

    /// The tail of the serial chain. Assigned before any suspension point, so
    /// arrivals order themselves deterministically.
    private var tail: Task<Void, Never>?

    func merge(
        tossups: [QBTossupOutcome],
        bonusTotals: [Int],
        forKey key: String,
        in kv: any ModuleKVStore
    ) async {
        let previous = tail
        let task = Task {
            await previous?.value
            var stats = QBFormatStats()
            if let data = await kv.data(forKey: key),
               let decoded = try? JSONDecoder().decode(QBFormatStats.self, from: data) {
                stats = decoded
            }
            stats.merge(tossups: tossups, bonusTotals: bonusTotals)
            if let data = try? JSONEncoder().encode(stats) {
                await kv.setData(data, forKey: key)
            }
        }
        tail = task
        await task.value
    }
}
