//
//  KBTransformerTests.swift
//  UnaMentisTests
//
//  Tests for KBTransformer including canonical question transformation.
//

import XCTest
@testable import UnaMentis

final class KBTransformerTests: XCTestCase {

    private var transformer: KBTransformer!

    override func setUp() {
        super.setUp()
        transformer = KBTransformer()
    }

    override func tearDown() {
        transformer = nil
        super.tearDown()
    }

    // MARK: - Canonical Question Transformation Tests

    func testTransform_canonicalQuestion_returnsKBQuestion() {
        let canonical = makeCanonicalQuestion()

        let result = transformer.transform(canonical)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.answer.primary, canonical.answer.primary)
    }

    func testTransform_canonicalQuestion_usesMediumFormText() {
        let canonical = makeCanonicalQuestion(
            mediumForm: "Medium form question text",
            shortForm: "Short form"
        )

        let result = transformer.transform(canonical)

        XCTAssertNotNil(result)
        // The transformer runs text through TextCleaner.cleanQuizBowlText, which
        // ensures a terminal sentence ending. The medium form lacks punctuation,
        // so a period is appended. Assert the exact cleaned output.
        XCTAssertEqual(result?.text, "Medium form question text.")
    }

    func testTransform_canonicalQuestion_fallsBackToShortForm() {
        let canonical = makeCanonicalQuestion(
            mediumForm: "",
            shortForm: "Short form question"
        )

        let result = transformer.transform(canonical)

        XCTAssertNotNil(result)
        // Same cleaning contract as the medium-form path: the short form lacks
        // terminal punctuation, so cleanQuizBowlText appends a period.
        XCTAssertEqual(result?.text, "Short form question.")
    }

    func testTransform_canonicalQuestion_mapsDomain() {
        let canonical = makeCanonicalQuestion(domain: .science)

        let result = transformer.transform(canonical)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.domain, .science)
    }

    func testTransform_canonicalQuestion_mapsAllDomains() {
        // Every PrimaryDomain must map to its same-named KBDomain. Asserting only
        // non-nil would let a broken mapping (wrong domain, or all collapsing to
        // one value) pass. The KBDomain and PrimaryDomain enums share raw values
        // 1:1, so comparing rawValue proves the correct per-domain mapping.
        let domains: [PrimaryDomain] = [
            .science, .mathematics, .literature, .history,
            .socialStudies, .arts, .currentEvents, .language,
            .technology, .popCulture, .religionPhilosophy, .miscellaneous
        ]

        for domain in domains {
            let canonical = makeCanonicalQuestion(domain: domain)
            let result = transformer.transform(canonical)

            XCTAssertEqual(
                result?.domain.rawValue,
                domain.rawValue,
                "PrimaryDomain \(domain.rawValue) should map to the same-named KBDomain"
            )
        }
    }

    func testTransform_canonicalQuestion_mapsDifficulty() {
        let canonical = makeCanonicalQuestion(absoluteDifficulty: 4)

        let result = transformer.transform(canonical)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.difficulty, .varsity)
    }

    func testTransform_canonicalQuestion_setsCorrectSuitability() {
        let canonical = makeCanonicalQuestion(
            requiresCalculation: false,
            mcqPossible: true,
            requiresVisual: false
        )

        let result = transformer.transform(canonical)

        XCTAssertNotNil(result)
        XCTAssertTrue(result?.suitability.forWritten ?? false)
        XCTAssertTrue(result?.suitability.forOral ?? false)
        XCTAssertTrue(result?.suitability.mcqPossible ?? false)
        XCTAssertFalse(result?.suitability.requiresVisual ?? true)
    }

    func testTransform_canonicalQuestion_calculationQuestionNotForOral() {
        let canonical = makeCanonicalQuestion(requiresCalculation: true)

        let result = transformer.transform(canonical)

        XCTAssertNotNil(result)
        XCTAssertFalse(result?.suitability.forOral ?? true)
    }

    func testTransform_emptyContent_returnsNil() {
        let canonical = makeCanonicalQuestion(mediumForm: "", shortForm: "")

        let result = transformer.transform(canonical)

        XCTAssertNil(result)
    }

    // MARK: - Canonicalize Tests

    func testCanonicalize_kbQuestion_returnsCanonicalQuestion() {
        let kbQuestion = makeKBQuestion()

        let result = transformer.canonicalize(kbQuestion)

        XCTAssertEqual(result.answer.primary, kbQuestion.answer.primary)
        XCTAssertFalse(result.content.mediumForm.isEmpty)
    }

    func testCanonicalize_preservesAnswerAlternatives() {
        let kbQuestion = makeKBQuestion(
            answer: "Paris",
            acceptableAnswers: ["Paris, France", "City of Light"]
        )

        let result = transformer.canonicalize(kbQuestion)

        XCTAssertEqual(result.answer.acceptable, ["Paris, France", "City of Light"])
    }

    func testCanonicalize_setsKnowledgeBowlCompatible() {
        let kbQuestion = makeKBQuestion()

        let result = transformer.canonicalize(kbQuestion)

        XCTAssertTrue(result.compatibleFormats.contains(.knowledgeBowl))
    }

    func testCanonicalize_mapsAnswerType() {
        let kbQuestion = makeKBQuestion(answerType: .person)

        let result = transformer.canonicalize(kbQuestion)

        XCTAssertEqual(result.answer.answerType, .person)
    }

    // MARK: - isCompatible Tests

    func testIsCompatible_validQuestion_returnsTrue() {
        let canonical = makeCanonicalQuestion()

        let result = transformer.isCompatible(canonical)

        XCTAssertTrue(result)
    }

    func testIsCompatible_emptyContent_returnsFalse() {
        let canonical = makeCanonicalQuestion(mediumForm: "", shortForm: "")

        let result = transformer.isCompatible(canonical)

        XCTAssertFalse(result)
    }

    // MARK: - Quality Score Tests

    func testQualityScore_idealQuestion_highScore() {
        let canonical = makeCanonicalQuestion(
            mediumForm: "A well-formed medium length question",
            mcqPossible: true,
            hasFormula: false,
            acceptableAnswers: ["alt1", "alt2"]
        )

        let score = transformer.qualityScore(canonical)

        XCTAssertGreaterThan(score, 0.8)
    }

    func testQualityScore_formulaQuestion_lowerScore() {
        // The only difference between the two inputs is hasFormula. A formula
        // question forfeits the +0.1 "voice-friendly" bonus, so it must score
        // strictly lower than its formula-free counterpart by exactly that amount.
        // A bare "< 0.9" upper bound would pass even if the penalty were removed.
        let formulaQuestion = makeCanonicalQuestion(hasFormula: true)
        let plainQuestion = makeCanonicalQuestion(hasFormula: false)

        let formulaScore = transformer.qualityScore(formulaQuestion)
        let plainScore = transformer.qualityScore(plainQuestion)

        XCTAssertLessThan(formulaScore, plainScore)
        XCTAssertEqual(plainScore - formulaScore, 0.1, accuracy: 0.0001)
    }

    func testQualityScore_commonKBDomain_bonusScore() {
        // History is in the KB-common domain set (+0.05); technology is not.
        // The two inputs are otherwise identical, so the common domain must score
        // strictly higher. ">=" would pass even if the domain bonus were dropped.
        let historyQuestion = makeCanonicalQuestion(domain: .history)
        let techQuestion = makeCanonicalQuestion(domain: .technology)

        let historyScore = transformer.qualityScore(historyQuestion)
        let techScore = transformer.qualityScore(techQuestion)

        XCTAssertGreaterThan(historyScore, techScore)
        XCTAssertEqual(historyScore - techScore, 0.05, accuracy: 0.0001)
    }

    // MARK: - Batch Transformation Tests

    func testTransformBatch_multipleQuestions_transformsAll() {
        let questions = [
            makeCanonicalQuestion(mediumForm: "Question 1"),
            makeCanonicalQuestion(mediumForm: "Question 2"),
            makeCanonicalQuestion(mediumForm: "Question 3")
        ]

        let results = transformer.transformBatch(questions)

        XCTAssertEqual(results.count, 3)
    }

    func testTransformBatch_mixedValidity_filtersInvalid() {
        let questions = [
            makeCanonicalQuestion(mediumForm: "Valid question"),
            makeCanonicalQuestion(mediumForm: "", shortForm: ""), // Invalid
            makeCanonicalQuestion(mediumForm: "Another valid")
        ]

        let results = transformer.transformBatch(questions)

        XCTAssertEqual(results.count, 2)
    }

    // MARK: - Imported Question Tests

    func testTransform_importedQuestion_returnsKBQuestion() {
        let imported = makeImportedQuestion()

        let result = transformer.transform(imported)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.answer.primary, imported.answer)
    }

    func testTransform_importedQuestion_mapsStringDomain() {
        let imported = makeImportedQuestion(domain: "science")

        let result = transformer.transform(imported)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.domain, .science)
    }

    func testTransform_importedQuestion_unknownDomain_returnsNil() {
        let imported = makeImportedQuestion(domain: "unknown_domain_xyz")

        let result = transformer.transform(imported)

        XCTAssertNil(result)
    }

    func testTransform_importedQuestion_mapsDifficulty() {
        let easyImport = makeImportedQuestion(difficulty: "easy")
        let hardImport = makeImportedQuestion(difficulty: "varsity")

        let easyResult = transformer.transform(easyImport)
        let hardResult = transformer.transform(hardImport)

        XCTAssertEqual(easyResult?.difficulty, .foundational)
        XCTAssertEqual(hardResult?.difficulty, .varsity)
    }

    // MARK: - Test Helpers

    private func makeCanonicalQuestion(
        mediumForm: String = "What is the capital of France?",
        shortForm: String = "Capital of France?",
        domain: PrimaryDomain = .socialStudies,
        absoluteDifficulty: Int = 3,
        requiresCalculation: Bool = false,
        mcqPossible: Bool = true,
        requiresVisual: Bool = false,
        hasFormula: Bool = false,
        acceptableAnswers: [String]? = nil
    ) -> CanonicalQuestion {
        let content = QuestionContent(
            pyramidalFull: "",
            mediumForm: mediumForm,
            shortForm: shortForm
        )

        let answer = AnswerSpec(
            primary: "Paris",
            acceptable: acceptableAnswers
        )

        let metadata = QuestionMetadata(
            requiresCalculation: requiresCalculation,
            hasFormula: hasFormula
        )

        let domains = [DomainTag(primary: domain)]

        let difficulty = DifficultyRating(absoluteLevel: absoluteDifficulty)

        let hints = TransformationHints(
            mcqPossible: mcqPossible,
            requiresVisual: requiresVisual
        )

        return CanonicalQuestion(
            content: content,
            answer: answer,
            metadata: metadata,
            domains: domains,
            difficulty: difficulty,
            compatibleFormats: [.knowledgeBowl, .general],
            transformationHints: hints
        )
    }

    private func makeKBQuestion(
        text: String = "What is the capital of France?",
        answer: String = "Paris",
        acceptableAnswers: [String]? = nil,
        answerType: KBAnswerType = .place,
        domain: KBDomain = .socialStudies,
        difficulty: KBDifficulty = .intermediate
    ) -> KBQuestion {
        KBQuestion(
            id: UUID(),
            text: text,
            answer: KBAnswer(
                primary: answer,
                acceptable: acceptableAnswers,
                answerType: answerType
            ),
            domain: domain,
            difficulty: difficulty,
            gradeLevel: .highSchool,
            suitability: KBSuitability()
        )
    }

    private func makeImportedQuestion(
        text: String = "What is the speed of light?",
        answer: String = "299,792,458 m/s",
        domain: String = "science",
        difficulty: String? = "intermediate"
    ) -> KBTransformer.ImportedQuestion {
        KBTransformer.ImportedQuestion(
            text: text,
            answer: answer,
            acceptableAnswers: nil,
            domain: domain,
            subdomain: nil,
            difficulty: difficulty,
            gradeLevel: nil,
            source: "Test Source",
            mcqOptions: nil,
            requiresCalculation: nil,
            hasFormula: nil,
            yearWritten: nil
        )
    }
}
