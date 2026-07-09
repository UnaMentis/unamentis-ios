// UnaMentis - Knowledge Bowl Progress Adapter
// Bridges Knowledge Bowl's attempt model onto the host ProgressStore and the
// unified proficiency model (MODULE_SDK_SPEC.md section 5.4).
//
// Phase 3 migration: KB records structured attempts through the host
// ProgressStore in addition to its existing KBSessionStore JSON files, so the
// on-disk session history KB already writes is preserved (not orphaned) while
// attempts also flow into the shared, module-namespaced store and roll up into
// cross-module proficiency. This is intentionally additive: KBSessionStore
// remains the source of truth for KB's own stats screens.

import Foundation

/// Maps Knowledge Bowl types onto the host progress/proficiency model.
enum KBProgressAdapter {
    /// The module ID that namespaces KB's progress data. Matches the manifest.
    static let moduleID = "knowledge-bowl"

    /// Map a KB domain onto a StandardDomain. KB's 12 domains map to same-named
    /// standard domains so cross-module features (e.g. Science Bowl) share
    /// science mastery with KB.
    static func standardDomain(for domain: KBDomain) -> StandardDomain {
        StandardDomain(domain.rawValue)
    }

    /// Build an AttemptRecord from a KB attempt.
    static func attemptRecord(from attempt: KBQuestionAttempt) -> AttemptRecord {
        AttemptRecord(
            module: moduleID,
            domain: standardDomain(for: attempt.domain),
            itemId: attempt.questionId.uuidString,
            response: attempt.userAnswer,
            correct: attempt.wasCorrect,
            latencyMs: Int(attempt.responseTime * 1000),
            timestamp: attempt.timestamp
        )
    }

    /// A mastery observation from a KB attempt: correct answers push mastery
    /// toward 100, incorrect toward 0. Faster correct answers could weight
    /// higher later; Phase 3 keeps the signal binary.
    static func masteryObservation(from attempt: KBQuestionAttempt) -> MasteryObservation {
        MasteryObservation(
            module: moduleID,
            domain: standardDomain(for: attempt.domain),
            signal: attempt.wasCorrect ? 100 : 0
        )
    }

    /// Record a KB attempt into the host progress + proficiency store.
    @MainActor
    static func record(_ attempt: KBQuestionAttempt, to store: any ProgressStoreService) {
        let record = attemptRecord(from: attempt)
        let observation = masteryObservation(from: attempt)
        Task {
            await store.store(record)
            await store.reportMastery(observation)
        }
    }
}
