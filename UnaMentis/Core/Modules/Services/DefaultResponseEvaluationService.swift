// UnaMentis - Default Response Evaluation Service
// MODULE_SDK_SPEC.md section 5.2.
//
// The production evaluator. It reproduces Knowledge Bowl's algorithmic answer
// validation, generalized off KB types: category-aware normalization, the
// exact/acceptable/Levenshtein baseline, and the enhanced tiers (synonyms,
// Double Metaphone, n-gram, token, linguistic) gated by the spec's named
// strictness profile. The tables of synonyms come from the profile, not the
// evaluator (EvaluationSynonyms).
//
// llmRubric ships via the injected LLMRubricEvaluating seam (structured rubric
// scoring over the app's LLM routing policy; the Oral Exam engine's feedback
// path). semantic remains declared but NOT advertised: the KB embeddings tier
// was never wired into a live call site, so there is no implemented, testable
// tier to lift; it lights up once the host manages shared embedding assets
// (section 5.2). pitchRhythm is reserved.

import Foundation
import OSLog

/// The host answer-evaluation service, actor-isolated for Swift 6 concurrency.
public actor DefaultResponseEvaluationService: ResponseEvaluationService {
    private let logger = Logger(subsystem: "com.unamentis", category: "ResponseEvaluation")

    private let phonetic = EvalPhoneticMatcher()
    private let ngram = EvalNGramMatcher()
    private let token = EvalTokenMatcher()
    private let linguistic = EvalLinguisticMatcher()

    /// The llmRubric tier (capability "eval.llm-rubric/1"), injected so the
    /// algorithmic evaluators stay LLM-free and tests can script it. The
    /// production default rides the app's LLM routing policy.
    private let rubricEvaluator: (any LLMRubricEvaluating)?

    public init(rubricEvaluator: (any LLMRubricEvaluating)? = LLMRubricEvaluator.production()) {
        self.rubricEvaluator = rubricEvaluator
    }

    // MARK: - Available Evaluators

    /// Only the evaluators that are actually implemented and testable are
    /// advertised. Advertising an unimplemented tier would let a module launch
    /// into a gap (RFC 0001 rule: implemented + tested before advertised).
    /// llmRubric is advertised when a rubric evaluator is wired (the default);
    /// semantic and pitchRhythm remain absent.
    public nonisolated var availableEvaluators: Set<EvaluatorKind> {
        var evaluators: Set<EvaluatorKind> = [.textExact, .textFuzzy, .numeric, .choice]
        if rubricEvaluator != nil {
            evaluators.insert(.llmRubric)
        }
        return evaluators
    }

    // MARK: - Evaluate

    public func evaluate(
        _ response: LearnerResponse,
        against spec: EvaluationSpec
    ) async -> EvaluationResult {
        // Rubric evaluation is holistic (structured scoring over a rubric,
        // not answer matching) and short-circuits the text path. It runs only
        // when the spec asks for the tier AND carries rubric dimensions.
        if spec.evaluatorTiers.contains(.llmRubric),
           let rubric = spec.rubric, !rubric.isEmpty,
           let rubricEvaluator {
            return await evaluateRubric(
                response, rubric: rubric, spec: spec, evaluator: rubricEvaluator
            )
        }

        // Choice evaluation is index-based and short-circuits the text path.
        if spec.evaluatorTiers.contains(.choice), spec.category == .choice || response.selectedIndex != nil {
            return evaluateChoice(response, against: spec)
        }

        let tier = spec.strictness.level

        // 1. Exact primary match.
        let normalizedUser = normalize(response.text, for: spec.category)
        let normalizedPrimary = normalize(spec.primaryAnswer, for: spec.category)
        if !normalizedUser.isEmpty, normalizedUser == normalizedPrimary {
            return EvaluationResult(
                verdict: .correct,
                matchedAgainst: spec.primaryAnswer,
                evaluator: .textExact,
                confidence: 1.0,
                tierUsed: tier,
                matchType: .exact
            )
        }

        // 2. Acceptable alternatives.
        for alt in spec.acceptableAnswers {
            if !normalizedUser.isEmpty, normalizedUser == normalize(alt, for: spec.category) {
                return EvaluationResult(
                    verdict: .correct,
                    matchedAgainst: alt,
                    evaluator: .textExact,
                    confidence: 1.0,
                    tierUsed: tier,
                    matchType: .acceptable
                )
            }
        }

        // 2.5. Numeric tolerance. When the spec asks for numeric evaluation with
        // a tolerance, compare parsed values within |a - b| <= tolerance. This
        // runs regardless of exactOnly (tolerance is the numeric analogue of the
        // exact/acceptable check, not a fuzzy tier).
        if spec.category == .numeric, spec.evaluatorTiers.contains(.numeric), spec.numericTolerance > 0 {
            if let userValue = numericValue(normalizedUser),
               let target = numericValue(normalize(spec.primaryAnswer, for: .numeric)),
               abs(userValue - target) <= spec.numericTolerance {
                return EvaluationResult(
                    verdict: .correct,
                    matchedAgainst: spec.primaryAnswer,
                    evaluator: .numeric,
                    confidence: 1.0,
                    tierUsed: tier,
                    matchType: .exact
                )
            }
        }

        // 3+. Fuzzy stack (numeric answers inherit the same path KB used, so
        // numeric near-misses within Levenshtein still match, matching legacy).
        if !spec.strictness.exactOnly, spec.evaluatorTiers.contains(.textFuzzy) || spec.evaluatorTiers.contains(.numeric) {
            if let fuzzy = fuzzyMatch(normalizedUser, spec: spec, tier: tier) {
                return fuzzy
            }
        }

        // No match. Attribute to the last text-ish evaluator in the spec.
        let decidingEvaluator = spec.evaluatorTiers.contains(.numeric) && spec.category == .numeric
            ? EvaluatorKind.numeric
            : (spec.strictness.exactOnly ? .textExact : .textFuzzy)
        return .miss(evaluator: decidingEvaluator, tier: tier)
    }

    // MARK: - LLM Rubric

    /// Run the llmRubric tier: score the response against the spec's rubric
    /// dimensions and fold the result into an EvaluationResult. The spec's
    /// `primaryAnswer` carries the topic/syllabus context for grounding.
    /// Verdict mapping: mean score >= 3 is correct, >= 2 is partial (the
    /// spec 5.2 `partial` verdict's first producer), below is incorrect.
    private func evaluateRubric(
        _ response: LearnerResponse,
        rubric: [String],
        spec: EvaluationSpec,
        evaluator: any LLMRubricEvaluating
    ) async -> EvaluationResult {
        let tier = spec.strictness.level
        let request = LLMRubricRequest(
            rubricDimensions: rubric,
            language: "en-US",
            topicTitle: spec.primaryAnswer,
            syllabusContext: spec.acceptableAnswers.joined(separator: "\n"),
            transcript: response.text
        )
        do {
            let feedback = try await evaluator.evaluate(request)
            let mean = feedback.scores.isEmpty
                ? 0
                : Double(feedback.scores.reduce(0) { $0 + $1.score }) / Double(feedback.scores.count)
            let verdict: EvaluationResult.Verdict = mean >= 3 ? .correct : (mean >= 2 ? .partial : .incorrect)
            return EvaluationResult(
                verdict: verdict,
                matchedAgainst: verdict == .incorrect ? nil : spec.primaryAnswer,
                evaluator: .llmRubric,
                confidence: Float(mean / 5.0),
                tierUsed: tier,
                matchType: verdict == .incorrect ? .none : .ai
            )
        } catch {
            logger.error("llmRubric evaluation failed: \(error.localizedDescription)")
            return .miss(evaluator: .llmRubric, tier: tier)
        }
    }

    // MARK: - Choice

    private func evaluateChoice(
        _ response: LearnerResponse,
        against spec: EvaluationSpec
    ) -> EvaluationResult {
        let tier = spec.strictness.level
        guard let options = spec.choiceOptions,
              let index = response.selectedIndex,
              index >= 0, index < options.count else {
            return .miss(evaluator: .choice, tier: tier)
        }
        let selected = options[index]
        let isCorrect = normalize(selected, for: .choice) == normalize(spec.primaryAnswer, for: .choice)
        return EvaluationResult(
            verdict: isCorrect ? .correct : .incorrect,
            matchedAgainst: isCorrect ? selected : nil,
            evaluator: .choice,
            confidence: isCorrect ? 1.0 : 0,
            tierUsed: tier,
            matchType: isCorrect ? .exact : .none
        )
    }

    // MARK: - Fuzzy Match (moved from KBAnswerValidator.fuzzyMatch)

    private func fuzzyMatch(
        _ userAnswer: String,
        spec: EvaluationSpec,
        tier: StrictnessProfile.Level
    ) -> EvaluationResult? {
        let candidates = [spec.primaryAnswer] + spec.acceptableAnswers
        let category = spec.category
        let profile = spec.strictness

        // 1. Levenshtein baseline (runs at every non-exactOnly tier).
        for candidate in candidates {
            let normalizedCandidate = normalize(candidate, for: category)
            let distance = levenshteinDistance(userAnswer, normalizedCandidate)
            let candidateThreshold = max(2, Int(Double(candidate.count) * profile.fuzzyThresholdPercent))
            if distance <= candidateThreshold {
                let confidence = 1.0 - (Float(distance) / Float(max(1, candidate.count)))
                if confidence >= profile.minimumConfidence {
                    return correct(candidate, .textFuzzy, confidence, tier, .fuzzy)
                }
            }
        }

        // Enhanced tiers only at .standard and above.
        guard tier >= .standard else { return nil }

        // 2. Synonyms (profile-supplied resource).
        if let synonyms = profile.synonyms {
            for candidate in candidates where synonyms.areSynonyms(userAnswer, candidate, for: category) {
                return correct(candidate, .textFuzzy, 0.95, tier, .fuzzy)
            }
        }

        // 3. Phonetic (Double Metaphone).
        for candidate in candidates where phonetic.arePhoneticMatch(userAnswer, candidate) {
            return correct(candidate, .textFuzzy, 0.90, tier, .fuzzy)
        }

        // 4. N-gram similarity.
        for candidate in candidates {
            let score = ngram.nGramScore(userAnswer, candidate)
            if score >= 0.80 {
                return correct(candidate, .textFuzzy, score, tier, .fuzzy)
            }
        }

        // 5. Token similarity.
        for candidate in candidates {
            let score = token.tokenScore(userAnswer, candidate)
            if score >= 0.80 {
                return correct(candidate, .textFuzzy, score, tier, .fuzzy)
            }
        }

        // 6. Linguistic (lemmatization).
        for candidate in candidates where linguistic.areLemmasEquivalent(userAnswer, candidate) {
            return correct(candidate, .textFuzzy, 0.85, tier, .fuzzy)
        }

        // Semantic / llmRubric tiers are unavailable in this build (see header),
        // so .lenient degrades to the algorithmic result above.
        return nil
    }

    private func correct(
        _ matched: String,
        _ evaluator: EvaluatorKind,
        _ confidence: Float,
        _ tier: StrictnessProfile.Level,
        _ matchType: EvaluationResult.MatchType
    ) -> EvaluationResult {
        EvaluationResult(
            verdict: .correct,
            matchedAgainst: matched,
            evaluator: evaluator,
            confidence: confidence,
            tierUsed: tier,
            matchType: matchType
        )
    }

    /// Parse a normalized numeric string into a value, or nil if not numeric.
    private func numericValue(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: "")
        return Double(cleaned)
    }

    // MARK: - Levenshtein (moved from KBAnswerValidator)

    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let m = s1.count
        let n = s2.count
        if m == 0 { return n }
        if n == 0 { return m }

        let (shorter, longer) = m < n ? (s1, s2) : (s2, s1)
        let shortLen = shorter.count
        let longLen = longer.count
        let shortArray = Array(shorter)
        let longArray = Array(longer)

        var previousRow = [Int](0...shortLen)
        var currentRow = [Int](repeating: 0, count: shortLen + 1)

        for i in 1...longLen {
            currentRow[0] = i
            for j in 1...shortLen {
                let cost = longArray[i - 1] == shortArray[j - 1] ? 0 : 1
                currentRow[j] = min(
                    previousRow[j] + 1,
                    currentRow[j - 1] + 1,
                    previousRow[j - 1] + cost
                )
            }
            swap(&previousRow, &currentRow)
        }
        return previousRow[shortLen]
    }
}
