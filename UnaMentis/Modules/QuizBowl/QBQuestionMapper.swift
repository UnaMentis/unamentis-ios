// UnaMentis - Quiz Bowl Question Mapper
// Adapts Quiz Bowl content (QBItem) onto the generic QuizMatchEngine's
// module-agnostic QuizMatchQuestion, and builds the host EvaluationSpec answers
// are judged against (MODULE_SDK_SPEC.md sections 5.2 and 6.1).
//
// The dependency direction is one-way, like Knowledge Bowl's adapter: the engine
// knows nothing about Quiz Bowl; Quiz Bowl expresses its questions as
// QuizMatchQuestions carrying a host EvaluationSpec. The `powerMarkIndex` on a
// QBItem (RFC 0005 item 7) maps straight onto QuizMatchQuestion.powerMarkIndex,
// which the engine uses for pyramidal power scoring.
//
// Writing style: no em dashes (see .claude/rules/writing-style.md).

import Foundation

enum QBQuestionMapper {
    /// The named strictness profile Quiz Bowl evaluates answers at. Quiz Bowl
    /// answers, like Knowledge Bowl's, benefit from the standard fuzzy stack
    /// (synonyms, phonetic, token) so "FDR" matches "Franklin Roosevelt". The
    /// profile id is descriptive; the evaluator behavior is driven by `level`
    /// (DefaultResponseEvaluationService).
    static let strictnessProfile = StrictnessProfile(id: "qb-standard", level: .standard)

    /// The evaluator tiers a Quiz Bowl answer runs through, matching the format
    /// descriptors' `evaluation.tiers`.
    static let evaluatorTiers: [EvaluatorKind] = [.textExact, .textFuzzy]

    /// Build the host EvaluationSpec for a QB answer.
    static func spec(for answer: QBAnswer) -> EvaluationSpec {
        EvaluationSpec(
            primaryAnswer: answer.primary,
            acceptableAnswers: answer.acceptable,
            category: .text,
            strictness: strictnessProfile,
            evaluatorTiers: evaluatorTiers
        )
    }

    /// Map a QB content item onto the engine's question model, carrying the
    /// pyramidal power mark and any attached bonus.
    static func engineQuestion(from item: QBItem) -> QuizMatchQuestion {
        QuizMatchQuestion(
            id: item.id,
            text: item.text,
            preRenderedAudio: nil,
            evaluation: spec(for: item.answer),
            domain: item.domain,
            powerMarkIndex: item.powerMarkIndex,
            bonus: item.bonus.map(engineBonus(from:))
        )
    }

    /// Map a QB content bonus onto the engine's bonus model.
    static func engineBonus(from bonus: QBBonusItem) -> QuizMatchBonus {
        QuizMatchBonus(
            leadIn: bonus.leadIn,
            parts: bonus.parts.map { part in
                QuizMatchBonus.Part(text: part.text, evaluation: spec(for: part.answer))
            }
        )
    }
}
