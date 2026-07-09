//
//  KBEvaluationBridge.swift
//  UnaMentis
//
//  Bridges Knowledge Bowl answer types and regional strictness onto the host
//  ResponseEvaluationService (MODULE_SDK_SPEC.md section 5.2, Phase 4).
//
//  Knowledge Bowl no longer owns answer validation. It expresses its regional
//  strictness as a NAMED host strictness profile and maps KBAnswerType onto the
//  platform AnswerCategory, then evaluates through `host.evaluation`. The KB
//  synonym bundle rides on the profile (SynonymResource.knowledgeBowl), not the
//  evaluator, so the evaluator stays KB-agnostic.
//

import Foundation

// MARK: - Validation Result

/// Result of answer validation. Kept here after KBAnswerValidator was lifted
/// into the host ResponseEvaluationService: KB call sites and stored attempts
/// still use this shape, populated via `KBEvaluationBridge.kbResult(from:)`.
struct KBValidationResult: Sendable {
    /// Whether the answer was correct.
    let isCorrect: Bool
    /// Confidence level of the match (0.0-1.0).
    let confidence: Float
    /// How the answer was matched.
    let matchType: KBMatchType
    /// The answer that was matched against (if correct).
    let matchedAnswer: String?

    /// Points earned (can be modified by caller based on timing, rebound, etc.).
    var pointsEarned: Int {
        isCorrect ? 1 : 0
    }
}

/// Maps Knowledge Bowl concepts to host evaluation inputs and back.
enum KBEvaluationBridge {

    // MARK: - Strictness Profiles

    /// The Colorado strict profile: exact + acceptable + baseline Levenshtein,
    /// no enhanced tiers. `exactOnly` stays false to match the legacy validator,
    /// which ran Levenshtein at `.strict` (only the enhanced tiers were gated).
    static let coloradoStrict = StrictnessProfile(
        id: "colorado-strict",
        level: .strict,
        fuzzyThresholdPercent: 0.20,
        minimumConfidence: 0.6,
        exactOnly: false,
        synonyms: nil
    )

    /// The KB standard profile (Minnesota, Washington): enhanced algorithmic
    /// tiers on, semantic/LLM off. Carries the KB synonym bundle.
    static let kbStandard = StrictnessProfile(
        id: "kb-standard",
        level: .standard,
        fuzzyThresholdPercent: 0.20,
        minimumConfidence: 0.6,
        exactOnly: false,
        synonyms: .knowledgeBowl
    )

    /// The KB lenient profile (practice mode): all algorithmic tiers plus, when
    /// the host manages the assets, semantic/LLM. Carries the KB synonym bundle.
    static let kbLenient = StrictnessProfile(
        id: "kb-lenient",
        level: .lenient,
        fuzzyThresholdPercent: 0.30,
        minimumConfidence: 0.5,
        exactOnly: false,
        synonyms: .knowledgeBowl
    )

    /// The named profile for a KB regional strictness level.
    static func profile(for strictness: KBValidationStrictness) -> StrictnessProfile {
        switch strictness {
        case .strict: return coloradoStrict
        case .standard: return kbStandard
        case .lenient: return kbLenient
        }
    }

    // MARK: - Answer Category

    /// Map a KBAnswerType onto the platform AnswerCategory.
    static func category(for answerType: KBAnswerType) -> AnswerCategory {
        switch answerType {
        case .text: return .text
        case .person: return .person
        case .place: return .place
        case .numeric: return .numeric
        case .date: return .date
        case .title: return .title
        case .scientific: return .scientific
        case .multipleChoice: return .choice
        }
    }

    // MARK: - Spec Construction

    /// The evaluator tier list KB uses: exact then the fuzzy stack. Numeric
    /// answers additionally request the numeric evaluator so intent is explicit
    /// (the fuzzy path already reproduces the legacy numeric behavior).
    private static func tiers(for category: AnswerCategory) -> [EvaluatorKind] {
        switch category {
        case .choice:
            return [.choice]
        case .numeric:
            return [.textExact, .numeric, .textFuzzy]
        default:
            return [.textExact, .textFuzzy]
        }
    }

    /// Build an EvaluationSpec from KB answer fields and strictness.
    static func spec(
        primary: String,
        acceptable: [String]?,
        answerType: KBAnswerType,
        strictness: KBValidationStrictness
    ) -> EvaluationSpec {
        let category = category(for: answerType)
        return EvaluationSpec(
            primaryAnswer: primary,
            acceptableAnswers: acceptable ?? [],
            category: category,
            strictness: profile(for: strictness),
            evaluatorTiers: tiers(for: category),
            numericTolerance: 0,
            choiceOptions: nil
        )
    }

    /// Build a spec for a KB question and strictness.
    static func spec(for question: KBQuestion, strictness: KBValidationStrictness) -> EvaluationSpec {
        spec(
            primary: question.answer.primary,
            acceptable: question.answer.acceptable,
            answerType: question.answer.answerType,
            strictness: strictness
        )
    }

    // MARK: - Result Mapping

    /// Map a host EvaluationResult back to a KBValidationResult so KB call sites
    /// and stored attempts keep their existing shape (KBMatchType, confidence).
    static func kbResult(from result: EvaluationResult) -> KBValidationResult {
        let matchType: KBMatchType
        switch result.matchType {
        case .exact: matchType = .exact
        case .acceptable: matchType = .acceptable
        case .fuzzy: matchType = .fuzzy
        case .ai: matchType = .ai
        case .none: matchType = .none
        }
        return KBValidationResult(
            isCorrect: result.verdict == .correct,
            confidence: result.confidence,
            matchType: matchType,
            matchedAnswer: result.matchedAgainst
        )
    }
}
