// UnaMentis - Response Evaluation Host Service
// MODULE_SDK_SPEC.md section 5.2, capabilities "eval.*".
//
// The platform answer-evaluation service. It generalizes Knowledge Bowl's
// algorithmic answer validation (exact, acceptable-alternatives, Levenshtein
// fuzzy, and the enhanced tiers: domain synonyms, Double Metaphone phonetics,
// n-gram, token, and linguistic matching) into a host service every module can
// use, with named strictness profiles in place of KB's hardcoded regional
// strictness.
//
// Phase 4 scope (MODULE_SDK_SPEC.md section 13):
// - textExact, textFuzzy, numeric, and choice evaluators ship and are tested.
//   textFuzzy is the moved KB algorithm stack, generalized to carry no KB
//   types: domain synonyms arrive as a profile-supplied resource, not baked-in.
// - semantic and llmRubric are DECLARED but advertised unavailable: the KB
//   embeddings/LLM tiers are never wired into the live call site (the oral
//   session constructs the validator with no embeddings/LLM service), so there
//   is no implemented, testable tier to lift. When those land as host-managed
//   shared model assets they light up behind these kinds.
// - pitchRhythm is reserved (section 5.2) and always unavailable.

import Foundation

// MARK: - Evaluator Kinds

/// The evaluators the platform can offer (MODULE_SDK_SPEC.md section 5.2). Raw
/// values are the capability leaf names (`eval.<leaf>/1`).
public enum EvaluatorKind: String, Sendable, CaseIterable, Hashable {
    case textExact          // eval.text-exact/1
    case textFuzzy          // eval.text-fuzzy/1  (Levenshtein, phonetic, token, synonyms)
    case numeric            // eval.numeric/1     (tolerance, units)
    case choice             // eval.choice/1      (MC with format-specific labels)
    case semantic           // eval.semantic/1    (embedding model, downloadable asset)
    case llmRubric          // eval.llm-rubric/1  (structured rubric scoring)
    case pitchRhythm        // eval.pitch-rhythm/1 (reserved; aural skills)

    /// The versioned host-capability name this evaluator advertises.
    public var capability: String {
        switch self {
        case .textExact: return "eval.text-exact/1"
        case .textFuzzy: return "eval.text-fuzzy/1"
        case .numeric: return "eval.numeric/1"
        case .choice: return "eval.choice/1"
        case .semantic: return "eval.semantic/1"
        case .llmRubric: return "eval.llm-rubric/1"
        case .pitchRhythm: return "eval.pitch-rhythm/1"
        }
    }
}

// MARK: - Learner Response

/// A learner's response to be evaluated (MODULE_SDK_SPEC.md section 5.2).
///
/// Phase 4 carries the transcribed/typed text and, for choice evaluation, an
/// optional selected index. Richer response shapes (audio features for
/// pitchRhythm, structured rubric input) are additive later fields.
public struct LearnerResponse: Sendable, Equatable {
    /// The learner's answer as text (STT transcript or typed input).
    public let text: String

    /// For choice questions: the index the learner selected, if any.
    public let selectedIndex: Int?

    public init(text: String, selectedIndex: Int? = nil) {
        self.text = text
        self.selectedIndex = selectedIndex
    }
}

// MARK: - Answer Category

/// How to normalize and match an answer. A platform-level generalization of
/// KB's `KBAnswerType`, carrying no KB types.
public enum AnswerCategory: String, Sendable, CaseIterable, Hashable {
    case text
    case person
    case place
    case numeric
    case date
    case title
    case scientific
    case choice
}

// MARK: - Strictness Profile

/// A named evaluator-strictness profile (MODULE_SDK_SPEC.md sections 5.2, 5.7).
///
/// Profiles replace KB's hardcoded regional strictness. A profile names which
/// tiers may run and supplies the domain-synonym resource (KB's synonyms are no
/// longer baked into the evaluator; they are profile data). Server-delivered
/// profiles (section 5.7) can override the bundled ones without code changes.
public struct StrictnessProfile: Sendable, Equatable {
    /// How permissive the fuzzy stack is, mirroring KB's three levels.
    public enum Level: Int, Sendable, Comparable, Equatable {
        /// Exact + acceptable + baseline Levenshtein only. No enhanced tiers.
        case strict = 1
        /// + synonyms, phonetic, n-gram, token, linguistic.
        case standard = 2
        /// + semantic (embeddings) and llmRubric when those assets are present.
        case lenient = 3

        public static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Stable profile identifier (e.g. "colorado-strict", "kb-standard").
    public let id: String
    public let level: Level

    /// Maximum Levenshtein error as a fraction of the candidate length.
    public let fuzzyThresholdPercent: Double
    /// Minimum confidence for a fuzzy match to count.
    public let minimumConfidence: Float

    /// When true, even baseline Levenshtein is skipped (exact/acceptable only).
    public let exactOnly: Bool

    /// Domain synonym resource this profile supplies to the fuzzy stack. Nil
    /// means the profile carries no synonyms.
    public let synonyms: SynonymResource?

    public init(
        id: String,
        level: Level,
        fuzzyThresholdPercent: Double = 0.20,
        minimumConfidence: Float = 0.6,
        exactOnly: Bool = false,
        synonyms: SynonymResource? = nil
    ) {
        self.id = id
        self.level = level
        self.fuzzyThresholdPercent = fuzzyThresholdPercent
        self.minimumConfidence = minimumConfidence
        self.exactOnly = exactOnly
        self.synonyms = synonyms
    }
}

// MARK: - Evaluation Spec

/// What a response is judged against (MODULE_SDK_SPEC.md section 5.2).
///
/// Carries the primary answer, acceptable alternatives, the strictness profile,
/// the ordered evaluator tier list to try, an optional rubric (reserved for
/// llmRubric), a numeric tolerance, and choice options.
public struct EvaluationSpec: Sendable, Equatable {
    /// The canonical correct answer.
    public let primaryAnswer: String
    /// Additional accepted answers.
    public let acceptableAnswers: [String]
    /// How to normalize and match.
    public let category: AnswerCategory
    /// Named strictness profile.
    public let strictness: StrictnessProfile
    /// Evaluators to try, in order. The service runs the first ones it supports.
    public let evaluatorTiers: [EvaluatorKind]
    /// Reserved for llmRubric scoring; carried now so specs are forward-stable.
    public let rubric: [String]?
    /// Absolute tolerance for numeric evaluation (|a - b| <= tolerance).
    public let numericTolerance: Double
    /// Options for choice evaluation, in index order.
    public let choiceOptions: [String]?

    public init(
        primaryAnswer: String,
        acceptableAnswers: [String] = [],
        category: AnswerCategory = .text,
        strictness: StrictnessProfile,
        evaluatorTiers: [EvaluatorKind] = [.textExact, .textFuzzy],
        rubric: [String]? = nil,
        numericTolerance: Double = 0,
        choiceOptions: [String]? = nil
    ) {
        self.primaryAnswer = primaryAnswer
        self.acceptableAnswers = acceptableAnswers
        self.category = category
        self.strictness = strictness
        self.evaluatorTiers = evaluatorTiers
        self.rubric = rubric
        self.numericTolerance = numericTolerance
        self.choiceOptions = choiceOptions
    }
}

// MARK: - Evaluation Result

/// The verdict of an evaluation (MODULE_SDK_SPEC.md section 5.2).
public struct EvaluationResult: Sendable, Equatable {
    public enum Verdict: String, Sendable, Equatable {
        case correct
        case incorrect
        case partial
    }

    /// How the decision maps to KB-style match semantics. Raw values match the
    /// legacy `KBMatchType` so the golden parity contract can compare directly
    /// without a KB dependency.
    public enum MatchType: String, Sendable, Equatable {
        case exact
        case acceptable
        case fuzzy
        case ai
        case none
    }

    /// correct / incorrect / partial.
    public let verdict: Verdict
    /// The answer string the response matched against (nil if none).
    public let matchedAgainst: String?
    /// Which evaluator decided.
    public let evaluator: EvaluatorKind
    /// Confidence in the decision (0.0 to 1.0).
    public let confidence: Float
    /// The strictness tier the deciding evaluator ran at.
    public let tierUsed: StrictnessProfile.Level
    /// KB-style match classification for the decision.
    public let matchType: MatchType

    public init(
        verdict: Verdict,
        matchedAgainst: String?,
        evaluator: EvaluatorKind,
        confidence: Float,
        tierUsed: StrictnessProfile.Level,
        matchType: MatchType
    ) {
        self.verdict = verdict
        self.matchedAgainst = matchedAgainst
        self.evaluator = evaluator
        self.confidence = confidence
        self.tierUsed = tierUsed
        self.matchType = matchType
    }

    /// A negative result attributed to the given evaluator.
    static func miss(evaluator: EvaluatorKind, tier: StrictnessProfile.Level) -> EvaluationResult {
        EvaluationResult(
            verdict: .incorrect,
            matchedAgainst: nil,
            evaluator: evaluator,
            confidence: 0,
            tierUsed: tier,
            matchType: .none
        )
    }
}

// MARK: - Service Protocol

/// The host answer-evaluation service (MODULE_SDK_SPEC.md section 5.2).
public protocol ResponseEvaluationService: Sendable {
    /// Evaluate a response against a spec, returning the verdict, what it
    /// matched, which evaluator decided, confidence, and the tier used.
    func evaluate(_ response: LearnerResponse, against spec: EvaluationSpec) async -> EvaluationResult

    /// The evaluators this build actually implements and can run. Maps to the
    /// `eval.*` capabilities advertised in `HostCapabilities`.
    var availableEvaluators: Set<EvaluatorKind> { get }
}
