//
//  KBAnswerValidatorTests.swift
//  UnaMentisTests
//
//  Real tests for KBAnswerValidator with the current async validate() API.
//
//  These exercise the real validation pipeline end to end: exact match,
//  acceptable alternatives, Levenshtein fuzzy matching, and the standard
//  tier algorithms (synonym, phonetic, n-gram, token, linguistic). All
//  matchers are real implementations. The embeddings and LLM tiers are not
//  configured (nil), so no paid external APIs are touched.
//

import XCTest
@testable import UnaMentis

@available(iOS 18.0, *)
final class KBAnswerValidatorTests: XCTestCase {

    // MARK: - Question Builders

    private func textQuestion(
        primary: String,
        acceptable: [String]? = nil,
        answerType: KBAnswerType = .text,
        mcqOptions: [String]? = nil
    ) -> KBQuestion {
        KBQuestion(
            text: "Sample question?",
            answer: KBAnswer(primary: primary, acceptable: acceptable, answerType: answerType),
            domain: .science,
            mcqOptions: mcqOptions
        )
    }

    // MARK: - Exact Match

    func testValidate_exactMatch_isCorrectWithFullConfidence() async {
        let validator = KBAnswerValidator()
        let question = textQuestion(primary: "Paris")

        let result = await validator.validate(userAnswer: "Paris", question: question)

        XCTAssertTrue(result.isCorrect)
        XCTAssertEqual(result.confidence, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.matchType, .exact)
        XCTAssertEqual(result.matchedAnswer, "Paris")
    }

    func testValidate_exactMatch_isCaseInsensitive() async {
        let validator = KBAnswerValidator()
        let question = textQuestion(primary: "Paris")

        let result = await validator.validate(userAnswer: "  paris  ", question: question)

        XCTAssertTrue(result.isCorrect)
        XCTAssertEqual(result.matchType, .exact)
    }

    func testValidate_exactMatch_ignoresArticles() async {
        // normalizeText removes leading articles, so "the moon" == "moon".
        let validator = KBAnswerValidator()
        let question = textQuestion(primary: "the Moon")

        let result = await validator.validate(userAnswer: "Moon", question: question)

        XCTAssertTrue(result.isCorrect)
        XCTAssertEqual(result.matchType, .exact)
    }

    // MARK: - Acceptable Alternatives

    func testValidate_acceptableAlternative_isCorrect() async {
        let validator = KBAnswerValidator()
        let question = textQuestion(primary: "carbon dioxide", acceptable: ["CO2"])

        let result = await validator.validate(userAnswer: "CO2", question: question)

        XCTAssertTrue(result.isCorrect)
        XCTAssertEqual(result.matchType, .acceptable)
        XCTAssertEqual(result.matchedAnswer, "CO2")
    }

    // MARK: - No Match

    func testValidate_completelyWrongAnswer_isIncorrect() async {
        let validator = KBAnswerValidator()
        let question = textQuestion(primary: "Photosynthesis")

        let result = await validator.validate(userAnswer: "Volcano", question: question)

        XCTAssertFalse(result.isCorrect)
        XCTAssertEqual(result.matchType, KBMatchType.none)
        XCTAssertEqual(result.confidence, 0)
        XCTAssertNil(result.matchedAnswer)
    }

    func testValidate_emptyAnswer_isIncorrect() async {
        let validator = KBAnswerValidator()
        let question = textQuestion(primary: "Photosynthesis")

        let result = await validator.validate(userAnswer: "", question: question)

        XCTAssertFalse(result.isCorrect)
    }

    // MARK: - Fuzzy (Levenshtein) Matching

    func testValidate_singleTypo_isAcceptedAsFuzzy() async {
        // "Mississipi" vs "Mississippi" is one deletion; within the default
        // 20% fuzzy threshold of an 11-character word.
        let validator = KBAnswerValidator()
        let question = textQuestion(primary: "Mississippi")

        let result = await validator.validate(userAnswer: "Mississipi", question: question)

        XCTAssertTrue(result.isCorrect)
        XCTAssertGreaterThan(result.confidence, 0.6)
    }

    func testValidate_tooManyDifferences_isRejected() async {
        // A short word with a large relative edit distance should not fuzzy-match.
        let validator = KBAnswerValidator()
        let question = textQuestion(primary: "cat")

        let result = await validator.validate(userAnswer: "dog", question: question)

        XCTAssertFalse(result.isCorrect)
    }

    // MARK: - Strict Mode

    func testValidate_strictMode_rejectsTypos() async {
        // In strict mode, only exact and acceptable matches count: fuzzy is skipped.
        let validator = KBAnswerValidator(config: .strict)
        let question = textQuestion(primary: "Mississippi")

        let result = await validator.validate(userAnswer: "Mississipi", question: question)

        XCTAssertFalse(result.isCorrect)
    }

    func testValidate_strictMode_stillAcceptsExact() async {
        let validator = KBAnswerValidator(config: .strict)
        let question = textQuestion(primary: "Mississippi")

        let result = await validator.validate(userAnswer: "Mississippi", question: question)

        XCTAssertTrue(result.isCorrect)
        XCTAssertEqual(result.matchType, .exact)
    }

    // MARK: - Synonym Matching (standard strictness, domain dictionaries)

    func testValidate_placeSynonym_isAccepted() async {
        // "USA" and "United States" are synonyms in the place dictionary.
        let validator = KBAnswerValidator(strictness: .standard)
        let question = textQuestion(primary: "United States", answerType: .place)

        let result = await validator.validate(userAnswer: "USA", question: question)

        XCTAssertTrue(result.isCorrect)
    }

    func testValidate_scientificSynonym_isAccepted() async {
        // "H2O" is a synonym for "water" in the scientific dictionary.
        let validator = KBAnswerValidator(strictness: .standard)
        let question = textQuestion(primary: "water", answerType: .scientific)

        let result = await validator.validate(userAnswer: "H2O", question: question)

        XCTAssertTrue(result.isCorrect)
    }

    // MARK: - Token Matching (word order / extra words)

    func testValidate_tokenReorder_isAccepted() async {
        // The token matcher handles word-order swaps for multi-word answers.
        let validator = KBAnswerValidator(strictness: .standard)
        let question = textQuestion(primary: "George Washington", answerType: .person)

        let result = await validator.validate(userAnswer: "Washington George", question: question)

        XCTAssertTrue(result.isCorrect)
    }

    // MARK: - Strictness Gating

    func testValidate_strictStrictness_skipsEnhancedTiers() async {
        // At .strict strictness the synonym/phonetic/token tiers are skipped.
        // A pure synonym that is not within Levenshtein distance should fail.
        let validator = KBAnswerValidator(strictness: .strict)
        let question = textQuestion(primary: "United States", answerType: .place)

        let result = await validator.validate(userAnswer: "USA", question: question)

        XCTAssertFalse(result.isCorrect,
                       "Synonym tier must not run at .strict strictness")
    }

    // MARK: - MCQ Validation

    func testValidateMCQ_correctSelection_isCorrect() {
        let validator = KBAnswerValidator()
        let question = textQuestion(
            primary: "Oxygen",
            mcqOptions: ["Hydrogen", "Oxygen", "Carbon", "Nitrogen"]
        )

        let result = validator.validateMCQ(selectedIndex: 1, question: question)

        XCTAssertTrue(result.isCorrect)
        XCTAssertEqual(result.matchType, .exact)
        XCTAssertEqual(result.confidence, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.matchedAnswer, "Oxygen")
    }

    func testValidateMCQ_wrongSelection_isIncorrect() {
        let validator = KBAnswerValidator()
        let question = textQuestion(
            primary: "Oxygen",
            mcqOptions: ["Hydrogen", "Oxygen", "Carbon", "Nitrogen"]
        )

        let result = validator.validateMCQ(selectedIndex: 0, question: question)

        XCTAssertFalse(result.isCorrect)
        XCTAssertEqual(result.matchType, KBMatchType.none)
        XCTAssertNil(result.matchedAnswer)
    }

    func testValidateMCQ_outOfRangeIndex_isIncorrect() {
        let validator = KBAnswerValidator()
        let question = textQuestion(
            primary: "Oxygen",
            mcqOptions: ["Hydrogen", "Oxygen", "Carbon", "Nitrogen"]
        )

        let high = validator.validateMCQ(selectedIndex: 99, question: question)
        let negative = validator.validateMCQ(selectedIndex: -1, question: question)

        XCTAssertFalse(high.isCorrect)
        XCTAssertFalse(negative.isCorrect)
    }

    func testValidateMCQ_noOptions_isIncorrect() {
        let validator = KBAnswerValidator()
        let question = textQuestion(primary: "Oxygen", mcqOptions: nil)

        let result = validator.validateMCQ(selectedIndex: 0, question: question)

        XCTAssertFalse(result.isCorrect)
    }

    // MARK: - Person Name Normalization

    func testValidate_personName_lastCommaFirst_isAccepted() async {
        // normalizePerson converts "Last, First" to "First Last".
        let validator = KBAnswerValidator()
        let question = textQuestion(primary: "George Washington", answerType: .person)

        let result = await validator.validate(userAnswer: "Washington, George", question: question)

        XCTAssertTrue(result.isCorrect)
        XCTAssertEqual(result.matchType, .exact)
    }

    func testValidate_personName_stripsTitle() async {
        // Leading honorific titles are removed during normalization.
        let validator = KBAnswerValidator()
        let question = textQuestion(primary: "Martin Luther King", answerType: .person)

        let result = await validator.validate(userAnswer: "Dr. Martin Luther King", question: question)

        XCTAssertTrue(result.isCorrect)
    }

    // MARK: - Numeric Normalization

    func testValidate_numericWordForm_matchesDigits() async {
        // "seven" normalizes to "7".
        let validator = KBAnswerValidator()
        let question = textQuestion(primary: "7", answerType: .numeric)

        let result = await validator.validate(userAnswer: "seven", question: question)

        XCTAssertTrue(result.isCorrect)
        XCTAssertEqual(result.matchType, .exact)
    }

    func testValidate_numericWithCommas_matches() async {
        // Commas are stripped from numbers during normalization.
        let validator = KBAnswerValidator()
        let question = textQuestion(primary: "1000000", answerType: .numeric)

        let result = await validator.validate(userAnswer: "1,000,000", question: question)

        XCTAssertTrue(result.isCorrect)
        XCTAssertEqual(result.matchType, .exact)
    }

    // MARK: - Title Normalization

    func testValidate_title_dropsLeadingThe() async {
        // normalizeTitle removes a leading "the".
        let validator = KBAnswerValidator()
        let question = textQuestion(primary: "Great Gatsby", answerType: .title)

        let result = await validator.validate(userAnswer: "The Great Gatsby", question: question)

        XCTAssertTrue(result.isCorrect)
        XCTAssertEqual(result.matchType, .exact)
    }

    func testValidate_title_dropsSubtitleAfterColon() async {
        // normalizeTitle removes anything after a colon.
        let validator = KBAnswerValidator()
        let question = textQuestion(primary: "Frankenstein", answerType: .title)

        let result = await validator.validate(
            userAnswer: "Frankenstein: The Modern Prometheus",
            question: question
        )

        XCTAssertTrue(result.isCorrect)
        XCTAssertEqual(result.matchType, .exact)
    }

    // MARK: - Place Normalization

    func testValidate_placeAbbreviation_expands() async {
        // "uk" expands to "united kingdom" during place normalization.
        let validator = KBAnswerValidator()
        let question = textQuestion(primary: "United Kingdom", answerType: .place)

        let result = await validator.validate(userAnswer: "UK", question: question)

        XCTAssertTrue(result.isCorrect)
    }

    // MARK: - KBValidationResult value type

    func testValidationResult_pointsEarned_reflectsCorrectness() {
        let correct = KBValidationResult(isCorrect: true, confidence: 1.0, matchType: .exact, matchedAnswer: "x")
        let wrong = KBValidationResult(isCorrect: false, confidence: 0, matchType: .none, matchedAnswer: nil)

        XCTAssertEqual(correct.pointsEarned, 1)
        XCTAssertEqual(wrong.pointsEarned, 0)
    }
}
