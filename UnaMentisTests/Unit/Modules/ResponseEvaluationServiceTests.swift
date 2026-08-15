//
//  ResponseEvaluationServiceTests.swift
//  UnaMentisTests
//
//  Service-level tests for the host ResponseEvaluationService
//  (MODULE_SDK_SPEC.md section 5.2, Phase 4). These complement the KB golden
//  parity suite: they exercise the service's own contract independent of KB,
//  covering profile strictness differences, evaluator selection order,
//  unavailable-evaluator behavior, numeric tolerance, and choice normalization.
//

import XCTest
@testable import UnaMentis

@available(iOS 18.0, *)
final class ResponseEvaluationServiceTests: XCTestCase {

    private func makeService() -> DefaultResponseEvaluationService {
        DefaultResponseEvaluationService()
    }

    // MARK: - Available Evaluators

    func testAvailableEvaluators_advertisesOnlyImplementedKinds() {
        let service = makeService()
        // The algorithmic tiers plus llmRubric, which now ships via the
        // injected LLMRubricEvaluating seam (the Oral Exam feedback path). The
        // default service wires the production rubric evaluator, so llmRubric
        // is advertised (MODULE_SDK_SPEC.md sections 5.2, 6.2).
        XCTAssertEqual(
            service.availableEvaluators,
            [.textExact, .textFuzzy, .numeric, .choice, .llmRubric]
        )
        // Still declared but unavailable: semantic, pitchRhythm.
        XCTAssertFalse(service.availableEvaluators.contains(.semantic))
        XCTAssertFalse(service.availableEvaluators.contains(.pitchRhythm))
        // A service constructed without a rubric evaluator omits llmRubric.
        XCTAssertFalse(
            DefaultResponseEvaluationService(rubricEvaluator: nil)
                .availableEvaluators.contains(.llmRubric)
        )
    }

    func testAvailableEvaluators_mapToAdvertisedCapabilities() {
        // Every advertised eval.* capability has a backing available evaluator.
        let service = makeService()
        let evalCaps = HostCapabilities.provided.filter { $0.hasPrefix("eval.") }
        let backing = Set(service.availableEvaluators.map(\.capability))
        XCTAssertEqual(evalCaps, backing)
    }

    // MARK: - Profile Strictness Differences

    func testProfileStrictness_synonymPassesLenientFailsStrict() async {
        let service = makeService()
        // "USA" vs "United States" is a synonym match: requires an enhanced tier.
        let strict = EvaluationSpec(
            primaryAnswer: "United States",
            category: .place,
            strictness: KBEvaluationBridge.coloradoStrict
        )
        let standard = EvaluationSpec(
            primaryAnswer: "United States",
            category: .place,
            strictness: KBEvaluationBridge.kbStandard
        )

        let strictResult = await service.evaluate(LearnerResponse(text: "USA"), against: strict)
        let standardResult = await service.evaluate(LearnerResponse(text: "USA"), against: standard)

        XCTAssertEqual(strictResult.verdict, .incorrect,
                       "Synonym tier must not run under the strict profile")
        XCTAssertEqual(standardResult.verdict, .correct,
                       "Synonym tier must run under the standard profile")
        XCTAssertEqual(standardResult.tierUsed, .standard)
    }

    func testProfileStrictness_exactStillPassesEverywhere() async {
        let service = makeService()
        let profiles: [StrictnessProfile] = [
            KBEvaluationBridge.coloradoStrict,
            KBEvaluationBridge.kbStandard,
            KBEvaluationBridge.kbLenient
        ]
        for profile in profiles {
            let spec = EvaluationSpec(primaryAnswer: "Paris", strictness: profile)
            let result = await service.evaluate(LearnerResponse(text: "paris"), against: spec)
            XCTAssertEqual(result.verdict, .correct, "exact must pass under \(profile.id)")
            XCTAssertEqual(result.matchType, .exact)
            XCTAssertEqual(result.evaluator, .textExact)
        }
    }

    // MARK: - Evaluator Selection Order

    func testSelectionOrder_exactBeatsFuzzy() async {
        let service = makeService()
        // Primary and an acceptable both plausible; exact primary must win and be
        // attributed to textExact with confidence 1.0.
        let spec = EvaluationSpec(
            primaryAnswer: "color",
            acceptableAnswers: ["colour"],
            strictness: KBEvaluationBridge.kbStandard
        )
        let result = await service.evaluate(LearnerResponse(text: "color"), against: spec)
        XCTAssertEqual(result.evaluator, .textExact)
        XCTAssertEqual(result.matchType, .exact)
        XCTAssertEqual(result.confidence, 1.0, accuracy: 0.0001)
    }

    func testSelectionOrder_acceptableBeforeFuzzy() async {
        let service = makeService()
        let spec = EvaluationSpec(
            primaryAnswer: "carbon dioxide",
            acceptableAnswers: ["CO2"],
            strictness: KBEvaluationBridge.kbStandard
        )
        let result = await service.evaluate(LearnerResponse(text: "CO2"), against: spec)
        XCTAssertEqual(result.matchType, .acceptable)
        XCTAssertEqual(result.evaluator, .textExact)
    }

    // MARK: - Unavailable Evaluator Behavior

    func testUnavailableEvaluator_lenientDegradesToAlgorithmic() async {
        // The lenient profile requests semantic/LLM tiers conceptually, but those
        // are unavailable. A pair that only a semantic tier could catch must fail;
        // an algorithmic pair must still pass. This proves graceful degradation.
        let service = makeService()
        let spec = EvaluationSpec(
            primaryAnswer: "happy",
            category: .text,
            strictness: KBEvaluationBridge.kbLenient
        )
        // "joyful" is a semantic synonym with no algorithmic overlap: must fail
        // because the semantic tier is unavailable.
        let semanticOnly = await service.evaluate(LearnerResponse(text: "joyful"), against: spec)
        XCTAssertEqual(semanticOnly.verdict, .incorrect)

        // A close typo still passes via the algorithmic Levenshtein tier.
        let typo = await service.evaluate(LearnerResponse(text: "hapy"), against: spec)
        XCTAssertEqual(typo.verdict, .correct)
    }

    // MARK: - Numeric Tolerance

    func testNumeric_withinToleranceIsCorrect() async {
        let service = makeService()
        let spec = EvaluationSpec(
            primaryAnswer: "100",
            category: .numeric,
            strictness: StrictnessProfile(id: "numeric-strict", level: .strict, exactOnly: true),
            evaluatorTiers: [.numeric],
            numericTolerance: 5
        )
        let inTolerance = await service.evaluate(LearnerResponse(text: "103"), against: spec)
        XCTAssertEqual(inTolerance.verdict, .correct)
        XCTAssertEqual(inTolerance.evaluator, .numeric)
    }

    func testNumeric_outsideToleranceIsIncorrect() async {
        let service = makeService()
        let spec = EvaluationSpec(
            primaryAnswer: "100",
            category: .numeric,
            strictness: StrictnessProfile(id: "numeric-strict", level: .strict, exactOnly: true),
            evaluatorTiers: [.numeric],
            numericTolerance: 5
        )
        let outOfTolerance = await service.evaluate(LearnerResponse(text: "120"), against: spec)
        XCTAssertEqual(outOfTolerance.verdict, .incorrect)
    }

    func testNumeric_exactZeroToleranceMatches() async {
        let service = makeService()
        let spec = EvaluationSpec(
            primaryAnswer: "42",
            category: .numeric,
            strictness: StrictnessProfile(id: "numeric-strict", level: .strict, exactOnly: true),
            evaluatorTiers: [.numeric],
            numericTolerance: 0
        )
        let exact = await service.evaluate(LearnerResponse(text: "42"), against: spec)
        XCTAssertEqual(exact.verdict, .correct)
        let off = await service.evaluate(LearnerResponse(text: "43"), against: spec)
        XCTAssertEqual(off.verdict, .incorrect)
    }

    // MARK: - Choice Normalization

    func testChoice_correctIndexIsCorrect() async {
        let service = makeService()
        let spec = EvaluationSpec(
            primaryAnswer: "Oxygen",
            category: .choice,
            strictness: KBEvaluationBridge.kbStandard,
            evaluatorTiers: [.choice],
            choiceOptions: ["Hydrogen", "Oxygen", "Carbon", "Nitrogen"]
        )
        let result = await service.evaluate(LearnerResponse(text: "", selectedIndex: 1), against: spec)
        XCTAssertEqual(result.verdict, .correct)
        XCTAssertEqual(result.evaluator, .choice)
        XCTAssertEqual(result.matchedAgainst, "Oxygen")
    }

    func testChoice_wrongIndexIsIncorrect() async {
        let service = makeService()
        let spec = EvaluationSpec(
            primaryAnswer: "Oxygen",
            category: .choice,
            strictness: KBEvaluationBridge.kbStandard,
            evaluatorTiers: [.choice],
            choiceOptions: ["Hydrogen", "Oxygen", "Carbon", "Nitrogen"]
        )
        let result = await service.evaluate(LearnerResponse(text: "", selectedIndex: 0), against: spec)
        XCTAssertEqual(result.verdict, .incorrect)
        XCTAssertEqual(result.evaluator, .choice)
    }

    func testChoice_outOfRangeIndexIsIncorrect() async {
        let service = makeService()
        let spec = EvaluationSpec(
            primaryAnswer: "Oxygen",
            category: .choice,
            strictness: KBEvaluationBridge.kbStandard,
            evaluatorTiers: [.choice],
            choiceOptions: ["Hydrogen", "Oxygen"]
        )
        let high = await service.evaluate(LearnerResponse(text: "", selectedIndex: 9), against: spec)
        let negative = await service.evaluate(LearnerResponse(text: "", selectedIndex: -1), against: spec)
        XCTAssertEqual(high.verdict, .incorrect)
        XCTAssertEqual(negative.verdict, .incorrect)
    }

    func testChoice_sameFirstLetterOptionsDoNotCollide() async {
        // The choice normalizer keeps only the first letter, which is right for
        // a LABEL ("A", "B") and catastrophic for full option text: any two
        // options sharing a first letter matched each other.
        let service = makeService()
        let periodic = EvaluationSpec(
            primaryAnswer: "Nitrogen",
            category: .choice,
            strictness: KBEvaluationBridge.kbStandard,
            evaluatorTiers: [.choice],
            choiceOptions: ["Hydrogen", "Neon", "Nitrogen", "Oxygen"]
        )
        let neon = await service.evaluate(LearnerResponse(text: "", selectedIndex: 1), against: periodic)
        XCTAssertEqual(neon.verdict, .incorrect, "Neon is not Nitrogen")
        let nitrogen = await service.evaluate(LearnerResponse(text: "", selectedIndex: 2), against: periodic)
        XCTAssertEqual(nitrogen.verdict, .correct)

        let capitals = EvaluationSpec(
            primaryAnswer: "Prague",
            category: .choice,
            strictness: KBEvaluationBridge.kbStandard,
            evaluatorTiers: [.choice],
            choiceOptions: ["Paris", "Prague"]
        )
        let paris = await service.evaluate(LearnerResponse(text: "", selectedIndex: 0), against: capitals)
        XCTAssertEqual(paris.verdict, .incorrect, "Paris is not Prague")

        let planets = EvaluationSpec(
            primaryAnswer: "Mars",
            category: .choice,
            strictness: KBEvaluationBridge.kbStandard,
            evaluatorTiers: [.choice],
            choiceOptions: ["Mercury", "Mars"]
        )
        let mercury = await service.evaluate(LearnerResponse(text: "", selectedIndex: 0), against: planets)
        XCTAssertEqual(mercury.verdict, .incorrect, "Mercury is not Mars")
        XCTAssertEqual(mercury.confidence, 0)
    }

    func testChoice_answerGivenAsALetterOrNumberLabelStillWorks() async {
        let service = makeService()
        let letter = EvaluationSpec(
            primaryAnswer: "C",
            category: .choice,
            strictness: KBEvaluationBridge.kbStandard,
            evaluatorTiers: [.choice],
            choiceOptions: ["Neon", "Nitrogen", "Oxygen", "Argon"]
        )
        let third = await service.evaluate(LearnerResponse(text: "", selectedIndex: 2), against: letter)
        XCTAssertEqual(third.verdict, .correct, "Label C selects the third option")
        let first = await service.evaluate(LearnerResponse(text: "", selectedIndex: 0), against: letter)
        XCTAssertEqual(first.verdict, .incorrect)

        let numbered = EvaluationSpec(
            primaryAnswer: "2)",
            category: .choice,
            strictness: KBEvaluationBridge.kbStandard,
            evaluatorTiers: [.choice],
            choiceOptions: ["Neon", "Nitrogen"]
        )
        let second = await service.evaluate(LearnerResponse(text: "", selectedIndex: 1), against: numbered)
        XCTAssertEqual(second.verdict, .correct, "A 1-based numeric label selects that option")
    }

    // MARK: - Fuzzy Tolerance (RFC 0004 item 6: a deliberate profile change)

    func testFuzzy_shortAnswersNoLongerGetTwoFreeEdits() async {
        // The old `max(2, ...)` floor tolerated two edits on every candidate,
        // which on a short answer is the whole answer.
        let service = makeService()
        let iran = EvaluationSpec(
            primaryAnswer: "Iran", category: .place, strictness: KBEvaluationBridge.kbStandard
        )
        let iraq = await service.evaluate(LearnerResponse(text: "Iraq"), against: iran)
        XCTAssertEqual(iraq.verdict, .incorrect, "Iraq must not be accepted for Iran")

        let australia = EvaluationSpec(
            primaryAnswer: "Australia", category: .place, strictness: KBEvaluationBridge.kbStandard
        )
        let austria = await service.evaluate(LearnerResponse(text: "Austria"), against: australia)
        XCTAssertEqual(austria.verdict, .incorrect, "Austria must not be accepted for Australia")

        let china = EvaluationSpec(
            primaryAnswer: "China", category: .place, strictness: KBEvaluationBridge.kbStandard
        )
        let chile = await service.evaluate(LearnerResponse(text: "Chile"), against: china)
        XCTAssertEqual(chile.verdict, .incorrect, "Chile must not be accepted for China")
    }

    func testFuzzy_genuineTyposOnLongerAnswersStillPass() async {
        // The tightening must not cost real misspelling tolerance.
        let service = makeService()
        let spec = EvaluationSpec(
            primaryAnswer: "Mississippi", strictness: KBEvaluationBridge.kbStandard
        )
        let typo = await service.evaluate(LearnerResponse(text: "Mississipi"), against: spec)
        XCTAssertEqual(typo.verdict, .correct)
        XCTAssertEqual(typo.matchType, .fuzzy)

        let photosynthesis = EvaluationSpec(
            primaryAnswer: "Photosynthesis", strictness: KBEvaluationBridge.kbStandard
        )
        let close = await service.evaluate(LearnerResponse(text: "Photosynthysis"), against: photosynthesis)
        XCTAssertEqual(close.verdict, .correct)
    }

    func testNumeric_neverFuzzyMatchesOnDigitEdits() async {
        // A digit edit changes the value, so the fuzzy stack must not run for
        // numeric answers even when the spec lists textFuzzy.
        let service = makeService()
        let spec = EvaluationSpec(
            primaryAnswer: "1000",
            category: .numeric,
            strictness: KBEvaluationBridge.kbStandard,
            evaluatorTiers: [.textExact, .numeric, .textFuzzy]
        )
        for wrong in ["1002", "100", "10000", "2000"] {
            let result = await service.evaluate(LearnerResponse(text: wrong), against: spec)
            XCTAssertEqual(result.verdict, .incorrect, "\(wrong) must not match 1000")
        }
        let exact = await service.evaluate(LearnerResponse(text: "1,000"), against: spec)
        XCTAssertEqual(exact.verdict, .correct, "Comma formatting still normalizes to an exact match")
        let words = await service.evaluate(LearnerResponse(text: "thousand"), against: spec)
        XCTAssertEqual(words.verdict, .correct, "Written numbers still normalize")
    }

    func testConfidence_usesTheNormalizedAnswerLength() async {
        // The old denominator was the RAW candidate, so normalization that
        // shortened the string inflated confidence.
        let service = makeService()
        let spec = EvaluationSpec(
            primaryAnswer: "The Great Gatsby",
            category: .title,
            strictness: KBEvaluationBridge.kbStandard
        )
        let typo = await service.evaluate(LearnerResponse(text: "Great Gatsbi"), against: spec)
        XCTAssertEqual(typo.verdict, .correct)
        // "great gatsby" is 12 characters after normalization, one edit away.
        XCTAssertEqual(typo.confidence, 1.0 - 1.0 / 12.0, accuracy: 0.001)
    }

    // MARK: - Empty / Garbage

    func testEmptyInputIsIncorrect() async {
        let service = makeService()
        let spec = EvaluationSpec(primaryAnswer: "Photosynthesis", strictness: KBEvaluationBridge.kbStandard)
        let empty = await service.evaluate(LearnerResponse(text: ""), against: spec)
        XCTAssertEqual(empty.verdict, .incorrect)
    }

    func testEmptyInputNeverFuzzyMatchesAShortAnswer() async {
        let service = makeService()
        let spec = EvaluationSpec(primaryAnswer: "pi", strictness: KBEvaluationBridge.kbStandard)
        let empty = await service.evaluate(LearnerResponse(text: "   "), against: spec)
        XCTAssertEqual(empty.verdict, .incorrect)
    }

    // MARK: - Rubric Tier Failure

    func testRubricFailure_reportsUnavailableNotIncorrect() async {
        // An unreachable model is an infrastructure failure. Reporting it as
        // `incorrect` grades the learner down for an outage.
        let service = DefaultResponseEvaluationService(rubricEvaluator: FailingRubricEvaluator())
        let spec = EvaluationSpec(
            primaryAnswer: "the water cycle",
            strictness: KBEvaluationBridge.kbStandard,
            evaluatorTiers: [.llmRubric],
            rubric: ["structure", "clarity"]
        )
        let result = await service.evaluate(
            LearnerResponse(text: "Water evaporates, condenses, and falls again."), against: spec
        )
        XCTAssertEqual(result.verdict, .unavailable)
        XCTAssertNotEqual(result.verdict, .incorrect)
        XCTAssertEqual(result.evaluator, .llmRubric)
    }
}

/// A rubric evaluator that always fails, standing in for an unreachable model.
/// ALLOWED: an internal host seam stand-in, not a paid-API mock.
private struct FailingRubricEvaluator: LLMRubricEvaluating {
    func evaluate(_ request: LLMRubricRequest) async throws -> RubricFeedback {
        throw LLMRubricError.noLLMAvailable
    }
}
