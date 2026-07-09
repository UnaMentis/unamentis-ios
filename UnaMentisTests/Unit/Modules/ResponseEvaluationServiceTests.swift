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

    // MARK: - Empty / Garbage

    func testEmptyInputIsIncorrect() async {
        let service = makeService()
        let spec = EvaluationSpec(primaryAnswer: "Photosynthesis", strictness: KBEvaluationBridge.kbStandard)
        let empty = await service.evaluate(LearnerResponse(text: ""), against: spec)
        XCTAssertEqual(empty.verdict, .incorrect)
    }
}
