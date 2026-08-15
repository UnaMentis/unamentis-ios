// UnaMentis - Oral Exam Format Descriptor Tests
//
// Covers the oral-exam descriptor schema (MODULE_SDK_SPEC.md section 6.2):
// - JSON round-trip (Codable in both directions)
// - the authored resources parse with the exact values spec 6.2's example
//   requires (fr-grand-oral: 20/10/10 minutes, five rubric dimensions, jury of
//   two formal) plus the practice-scaled variant and the English practice viva
// - additive-schema tolerance: unknown JSON fields are ignored
// - long-form endpointing defaults and VoicePipelineConfig derivation

import XCTest
@testable import UnaMentis

final class OralExamFormatDescriptorTests: XCTestCase {

    // MARK: - Round Trip

    func testRoundTrip_preservesAllFields() throws {
        let descriptor = OralExamFormatDescriptor(
            formatId: "round-trip",
            language: "fr-FR",
            stages: [
                .init(kind: .preparation, seconds: 1200),
                .init(kind: .presentation, seconds: 600, notesAllowed: false),
                .init(kind: .questioning, seconds: 600, style: "jury", followUpDepth: 2)
            ],
            rubric: ["structure", "clarity", "argumentation", "interaction", "delivery"],
            examiner: .init(personaCount: 2, register: "formal"),
            evaluation: .init(tiers: ["llmRubric"], deliveryMetrics: ["pace", "fillerWords", "hesitations"]),
            listening: .init(responseSilenceSec: 2.5, maxUtteranceSec: 200)
        )
        let decoded = try OralExamFormatDescriptor.decode(from: descriptor.encoded())
        XCTAssertEqual(decoded, descriptor)
    }

    func testRoundTrip_preservesNilListening() throws {
        let descriptor = OralExamFormatDescriptor(
            formatId: "minimal",
            language: "en-US",
            stages: [.init(kind: .questioning, seconds: 240, followUpDepth: 1)],
            rubric: ["clarity"],
            examiner: .init(personaCount: 1, register: "encouraging"),
            evaluation: .init(tiers: ["llmRubric"], deliveryMetrics: ["pace"])
        )
        let decoded = try OralExamFormatDescriptor.decode(from: descriptor.encoded())
        XCTAssertEqual(decoded, descriptor)
        XCTAssertNil(decoded.listening)
    }

    // MARK: - Additive Schema Tolerance

    func testDecode_toleratesUnknownFields() throws {
        let json = """
        {
          "formatId": "future",
          "engine": "oral-exam/1",
          "language": "en-US",
          "stages": [{ "kind": "questioning", "seconds": 240, "futureStageField": 1 }],
          "rubric": ["clarity"],
          "examiner": { "personaCount": 1, "register": "formal" },
          "evaluation": { "tiers": ["llmRubric"], "deliveryMetrics": ["pace"] },
          "someFutureTopLevelField": { "nested": true }
        }
        """
        let descriptor = try OralExamFormatDescriptor.decode(from: Data(json.utf8))
        XCTAssertEqual(descriptor.formatId, "future")
        XCTAssertEqual(descriptor.stages.count, 1)
    }

    // MARK: - fr-grand-oral.json (spec 6.2 example, verbatim)

    func testGrandOralResource_matchesSpecExample() throws {
        let descriptor = try OralExamFormatDescriptor.load(named: "fr-grand-oral")

        XCTAssertEqual(descriptor.formatId, "fr-grand-oral")
        XCTAssertEqual(descriptor.engine, "oral-exam/1")
        XCTAssertEqual(descriptor.language, "fr-FR")

        XCTAssertEqual(descriptor.stages.count, 3)
        XCTAssertEqual(descriptor.stages[0].kind, .preparation)
        XCTAssertEqual(descriptor.stages[0].seconds, 1200)
        XCTAssertEqual(descriptor.stages[1].kind, .presentation)
        XCTAssertEqual(descriptor.stages[1].seconds, 600)
        XCTAssertEqual(descriptor.stages[1].notesAllowed, false)
        XCTAssertEqual(descriptor.stages[2].kind, .questioning)
        XCTAssertEqual(descriptor.stages[2].seconds, 600)
        XCTAssertEqual(descriptor.stages[2].style, "jury")
        XCTAssertEqual(descriptor.stages[2].followUpDepth, 2)

        XCTAssertEqual(descriptor.rubric, ["structure", "clarity", "argumentation", "interaction", "delivery"])
        XCTAssertEqual(descriptor.examiner.personaCount, 2)
        XCTAssertEqual(descriptor.examiner.register, "formal")
        XCTAssertEqual(descriptor.evaluation.tiers, ["llmRubric"])
        XCTAssertEqual(descriptor.evaluation.deliveryMetrics, ["pace", "fillerWords", "hesitations"])
    }

    func testGrandOralPracticeVariant_scalesTimingKeepsStructure() throws {
        let full = try OralExamFormatDescriptor.load(named: "fr-grand-oral")
        let practice = try OralExamFormatDescriptor.load(named: "fr-grand-oral-practice")

        // Same stage kinds and rubric, shorter timing.
        XCTAssertEqual(practice.stages.map(\.kind), full.stages.map(\.kind))
        XCTAssertEqual(practice.rubric, full.rubric)
        XCTAssertEqual(practice.examiner, full.examiner)
        for (short, long) in zip(practice.stages, full.stages) {
            XCTAssertLessThan(short.seconds, long.seconds)
        }
    }

    // MARK: - practice-viva.json (English MVP default)

    func testPracticeVivaResource_isEnglishGeneric() throws {
        let descriptor = try OralExamFormatDescriptor.load(named: "practice-viva")
        XCTAssertEqual(descriptor.formatId, "practice-viva")
        XCTAssertEqual(descriptor.language, "en-US")
        XCTAssertEqual(descriptor.stage(ofKind: .preparation)?.seconds, 120)
        XCTAssertEqual(descriptor.stage(ofKind: .presentation)?.seconds, 240)
        XCTAssertEqual(descriptor.stage(ofKind: .questioning)?.seconds, 240)
        XCTAssertEqual(descriptor.stage(ofKind: .questioning)?.followUpDepth, 2)
    }

    // MARK: - Endpointing Defaults and Pipeline Config

    func testResponseEndpointing_defaultsWhenNoListeningBlock() throws {
        let descriptor = try OralExamFormatDescriptor.load(named: "fr-grand-oral")
        // fr-grand-oral has no listening block: engine defaults apply.
        XCTAssertEqual(descriptor.responseSilenceSeconds, OralExamFormatDescriptor.defaultResponseSilenceSec)
        XCTAssertEqual(descriptor.maxUtteranceSeconds, OralExamFormatDescriptor.defaultMaxUtteranceSec)
    }

    func testVoicePipelineConfig_usesLongFormEndpointing() throws {
        let descriptor = try OralExamFormatDescriptor.load(named: "practice-viva")
        let config = descriptor.voicePipelineConfig()
        XCTAssertEqual(config.endpointing.silenceThreshold, 2.0)
        XCTAssertEqual(config.endpointing.maxUtteranceDuration, 180)
        // Locale stays en-US even for fr descriptors: STT locale is not plumbed
        // yet (RFC 0002 item 6).
        XCTAssertEqual(config.locale.identifier, "en-US")
        XCTAssertNil(config.answerTimeout)
    }

    func testLoad_missingResourceThrowsTypedError() {
        XCTAssertThrowsError(try OralExamFormatDescriptor.load(named: "no-such-exam")) { error in
            XCTAssertEqual(error as? OralExamDescriptorError, .resourceNotFound("no-such-exam"))
        }
    }
}
