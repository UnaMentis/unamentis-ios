// UnaMentis - PronunciationProcessorTests
// Unit tests for the pronunciation-hint text transformer used to feed correct
// pronunciations to TTS services.
//
// This is pure, deterministic string transformation: SSML phoneme generation,
// respelling injection, whole-word matching, and longest-first ordering. Bugs
// here silently mispronounce proper nouns, so the exact output shape matters.

import XCTest
@testable import UnaMentis

final class PronunciationProcessorTests: XCTestCase {

    private func hint(
        _ term: String,
        ipa: String,
        respelling: String? = nil,
        language: String? = nil
    ) -> PronunciationProcessor.PronunciationHint {
        PronunciationProcessor.PronunciationHint(
            term: term,
            ipa: ipa,
            respelling: respelling,
            language: language
        )
    }

    // MARK: - Empty / passthrough

    func testEmptyHintsLeavesTextUnchanged() {
        let processor = PronunciationProcessor(hints: [:], outputFormat: .ssml)
        XCTAssertEqual(processor.process("The Medici family"), "The Medici family")
    }

    func testPlainFormatLeavesTextUnchangedEvenWithHints() {
        let processor = PronunciationProcessor(
            hints: ["Medici": hint("Medici", ipa: "ˈmɛdɪtʃi")],
            outputFormat: .plain
        )
        XCTAssertEqual(processor.process("The Medici family"), "The Medici family")
    }

    // MARK: - SSML phoneme generation

    func testSSMLPhonemeWrapsTermWithIPA() {
        let processor = PronunciationProcessor(
            hints: ["Medici": hint("Medici", ipa: "ˈmɛdɪtʃi")],
            outputFormat: .ssml
        )
        let result = processor.process("The Medici ruled Florence")
        XCTAssertEqual(
            result,
            "The <phoneme alphabet=\"ipa\" ph=\"ˈmɛdɪtʃi\">Medici</phoneme> ruled Florence"
        )
    }

    func testSSMLPhonemeStripsSurroundingSlashesFromIPA() {
        // Curriculum IPA often arrives wrapped in slashes (/.../). Those are not
        // valid inside an SSML ph attribute and must be trimmed.
        let processor = PronunciationProcessor(
            hints: ["Medici": hint("Medici", ipa: "/ˈmɛdɪtʃi/")],
            outputFormat: .ssml
        )
        let result = processor.process("Medici")
        XCTAssertEqual(result, "<phoneme alphabet=\"ipa\" ph=\"ˈmɛdɪtʃi\">Medici</phoneme>")
    }

    func testSSMLPhonemeIncludesLanguageWhenProvided() {
        let processor = PronunciationProcessor(
            hints: ["Medici": hint("Medici", ipa: "ˈmɛːditʃi", language: "it")],
            outputFormat: .ssml
        )
        let result = processor.process("Medici")
        XCTAssertEqual(
            result,
            "<phoneme alphabet=\"ipa\" ph=\"ˈmɛːditʃi\" xml:lang=\"it\">Medici</phoneme>"
        )
    }

    // MARK: - Whole-word matching

    func testReplacementMatchesWholeWordsOnly() {
        // "art" must not match inside "Bartholomew" or "started".
        let processor = PronunciationProcessor(
            hints: ["art": hint("art", ipa: "ɑːrt")],
            outputFormat: .ssml
        )
        let result = processor.process("Bartholomew started his art")
        XCTAssertEqual(
            result,
            "Bartholomew started his <phoneme alphabet=\"ipa\" ph=\"ɑːrt\">art</phoneme>"
        )
    }

    func testAllOccurrencesOfWholeWordReplaced() {
        let processor = PronunciationProcessor(
            hints: ["Gough": hint("Gough", ipa: "ɡɒf")],
            outputFormat: .ssml
        )
        let result = processor.process("Gough met Gough")
        XCTAssertEqual(
            result,
            "<phoneme alphabet=\"ipa\" ph=\"ɡɒf\">Gough</phoneme> met <phoneme alphabet=\"ipa\" ph=\"ɡɒf\">Gough</phoneme>"
        )
    }

    // MARK: - Respelling format

    func testRespellingFormatAppendsHintInParentheses() {
        let processor = PronunciationProcessor(
            hints: ["Medici": hint("Medici", ipa: "ˈmɛdɪtʃi", respelling: "MED-ih-chee")],
            outputFormat: .respelling
        )
        let result = processor.process("The Medici family")
        XCTAssertEqual(result, "The Medici (MED-ih-chee) family")
    }

    func testRespellingFormatLeavesTermUntouchedWhenNoRespelling() {
        // No respelling string means there is nothing to inject; the term is unchanged.
        let processor = PronunciationProcessor(
            hints: ["Medici": hint("Medici", ipa: "ˈmɛdɪtʃi", respelling: nil)],
            outputFormat: .respelling
        )
        XCTAssertEqual(processor.process("The Medici family"), "The Medici family")
    }

    // MARK: - SSML wrapper

    func testSSMLWrapperWrapsProcessedTextInSpeakTag() {
        let processor = PronunciationProcessor(
            hints: ["Medici": hint("Medici", ipa: "ˈmɛdɪtʃi")],
            outputFormat: .ssml
        )
        let result = processor.processWithSSMLWrapper("Medici")
        XCTAssertEqual(
            result,
            "<speak><phoneme alphabet=\"ipa\" ph=\"ˈmɛdɪtʃi\">Medici</phoneme></speak>"
        )
    }

    func testSSMLWrapperOmittedWhenNoHints() {
        // With no hints there is nothing to mark up, so no <speak> wrapper is added.
        let processor = PronunciationProcessor(hints: [:], outputFormat: .ssml)
        XCTAssertEqual(processor.processWithSSMLWrapper("plain text"), "plain text")
    }

    func testSSMLWrapperOmittedForNonSSMLFormat() {
        let processor = PronunciationProcessor(
            hints: ["Medici": hint("Medici", ipa: "ˈmɛdɪtʃi", respelling: "MED-ih-chee")],
            outputFormat: .respelling
        )
        let result = processor.processWithSSMLWrapper("Medici")
        XCTAssertEqual(result, "Medici (MED-ih-chee)")
        XCTAssertFalse(result.contains("<speak>"))
    }

    // MARK: - Initialization from curriculum guide

    func testInitFromPronunciationGuideAppliesEntries() {
        let guide: [String: TranscriptData.PronunciationEntry] = [
            "Medici": TranscriptData.PronunciationEntry(
                ipa: "ˈmɛdɪtʃi",
                respelling: "MED-ih-chee",
                language: "it"
            )
        ]
        let processor = PronunciationProcessor(pronunciationGuide: guide, outputFormat: .ssml)
        let result = processor.process("Medici")
        XCTAssertEqual(
            result,
            "<phoneme alphabet=\"ipa\" ph=\"ˈmɛdɪtʃi\" xml:lang=\"it\">Medici</phoneme>"
        )
    }

    func testNilPronunciationGuideProducesNoChanges() {
        let processor = PronunciationProcessor(pronunciationGuide: nil, outputFormat: .ssml)
        XCTAssertEqual(processor.process("Unchanged text"), "Unchanged text")
    }

    // MARK: - String convenience extension

    func testStringExtensionAppliesHints() {
        let guide: [String: TranscriptData.PronunciationEntry] = [
            "Gough": TranscriptData.PronunciationEntry(ipa: "ɡɒf", respelling: "goff", language: nil)
        ]
        let result = "Gough".withPronunciationHints(from: guide, format: .respelling)
        XCTAssertEqual(result, "Gough (goff)")
    }
}
