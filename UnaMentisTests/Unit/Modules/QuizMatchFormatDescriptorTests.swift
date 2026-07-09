// UnaMentis - Quiz Match Format Descriptor Tests
//
// Covers the Phase 5 format-descriptor schema (MODULE_SDK_SPEC.md 6.1):
// - JSON round-trip (Codable in both directions)
// - the two authored descriptor resources parse with the exact values the
//   live code exhibits (kb-colorado) and the Quiz Bowl spec requires
//   (qb-naqt-skeleton)
// - the Knowledge Bowl adapter derives a descriptor identical to the authored
//   kb-colorado.json, keeping data and code in lockstep
// - additive-schema tolerance: unknown JSON fields are ignored
// - VoicePipelineConfig derivation (endpointing, conference, buzz mode)

import XCTest
@testable import UnaMentis

final class QuizMatchFormatDescriptorTests: XCTestCase {

    // MARK: - Round Trip

    func testRoundTrip_preservesAllFields() throws {
        let descriptor = QuizMatchFormatDescriptor(
            formatId: "round-trip",
            engine: "quiz-match/1",
            phases: [.oral],
            buzz: .init(mode: .individual, lockout: true, recognitionRequired: true),
            scoring: .init(
                correct: 10,
                incorrect: -5,
                power: 15,
                bonus: .init(partCount: 3, pointsPerPart: 10)
            ),
            rebound: .init(enabled: true, order: .open),
            conference: .init(seconds: 20, verbalAllowed: true),
            written: .init(questions: 25, choices: ["W", "X", "Y", "Z"], timeLimitSec: 1200),
            oral: .init(questions: 24, answerSilenceSec: 2.0, maxUtteranceSec: 30, answerTimeoutSec: 5),
            questionForm: .pyramidal,
            evaluation: .init(profile: "kb-standard", tiers: ["textExact", "textFuzzy"])
        )

        let decoded = try QuizMatchFormatDescriptor.decode(from: descriptor.encoded())
        XCTAssertEqual(decoded, descriptor)
    }

    func testRoundTrip_preservesNilOptionals() throws {
        let descriptor = QuizMatchFormatDescriptor(
            formatId: "minimal",
            phases: [.oral],
            buzz: .init(mode: .team, lockout: false, recognitionRequired: false),
            scoring: .init(correct: 5, incorrect: 0),
            rebound: .init(enabled: false, order: .nextTeam),
            questionForm: .short,
            evaluation: .init(profile: "kb-standard", tiers: ["textExact"])
        )

        let decoded = try QuizMatchFormatDescriptor.decode(from: descriptor.encoded())
        XCTAssertEqual(decoded, descriptor)
        XCTAssertNil(decoded.conference)
        XCTAssertNil(decoded.written)
        XCTAssertNil(decoded.oral)
        XCTAssertNil(decoded.scoring.power)
        XCTAssertNil(decoded.scoring.bonus)
    }

    // MARK: - Additive Schema Tolerance

    func testDecode_toleratesUnknownFields() throws {
        let json = """
        {
          "formatId": "future",
          "engine": "quiz-match/1",
          "phases": ["oral"],
          "buzz": { "mode": "team", "lockout": false, "recognitionRequired": false },
          "scoring": { "correct": 5, "incorrect": 0, "futureScoringField": 7 },
          "rebound": { "enabled": true, "order": "next-team" },
          "questionForm": "short",
          "evaluation": { "profile": "kb-standard", "tiers": ["textExact"] },
          "someFutureTopLevelField": { "nested": true }
        }
        """
        let descriptor = try QuizMatchFormatDescriptor.decode(from: Data(json.utf8))
        XCTAssertEqual(descriptor.formatId, "future")
        XCTAssertEqual(descriptor.scoring.correct, 5)
    }

    // MARK: - kb-colorado.json (format descriptor #1)

    func testKBColoradoResource_matchesLiveKnowledgeBowlBehavior() throws {
        let descriptor = try QuizMatchFormatDescriptor.load(named: "kb-colorado")

        XCTAssertEqual(descriptor.formatId, "kb-colorado")
        XCTAssertEqual(descriptor.engine, "quiz-match/1")
        XCTAssertEqual(descriptor.phases, [.written, .oral])

        // Team buzz, no lockout, no moderator recognition.
        XCTAssertEqual(descriptor.buzz.mode, .team)
        XCTAssertFalse(descriptor.buzz.lockout)
        XCTAssertFalse(descriptor.buzz.recognitionRequired)

        // 5 points per correct oral answer, no negs, no powers, no bonuses
        // (KBRegionalConfig.forRegion(.colorado)).
        XCTAssertEqual(descriptor.scoring.correct, 5)
        XCTAssertEqual(descriptor.scoring.incorrect, 0)
        XCTAssertNil(descriptor.scoring.power)
        XCTAssertNil(descriptor.scoring.bonus)

        // Rebound to the next team.
        XCTAssertTrue(descriptor.rebound.enabled)
        XCTAssertEqual(descriptor.rebound.order, .nextTeam)

        // 15 second nonverbal conference (Colorado prohibits verbal conferring).
        XCTAssertEqual(descriptor.conference?.seconds, 15)
        XCTAssertEqual(descriptor.conference?.verbalAllowed, false)

        // Written round: 60 questions, A-D, 15 minutes
        // (KBRegionalConfig, not the spec 6.1 example's 2700 seconds).
        XCTAssertEqual(descriptor.written?.questions, 60)
        XCTAssertEqual(descriptor.written?.choices, ["A", "B", "C", "D"])
        XCTAssertEqual(descriptor.written?.timeLimitSec, 900)

        // Oral round: 50 questions, the 2.5 s answer endpointing KB has
        // always used, 60 s max utterance, no answer timeout.
        XCTAssertEqual(descriptor.oral?.questions, 50)
        XCTAssertEqual(descriptor.oral?.answerSilenceSec, 2.5)
        XCTAssertEqual(descriptor.oral?.maxUtteranceSec, 60)
        XCTAssertNil(descriptor.oral?.answerTimeoutSec)

        XCTAssertEqual(descriptor.questionForm, .short)

        // The live oral call site evaluates at the kb-standard profile
        // regardless of region (RFC 0004 item 5); the descriptor records the
        // behavior the app actually has, not the aspirational colorado-strict.
        XCTAssertEqual(descriptor.evaluation.profile, "kb-standard")
        XCTAssertEqual(descriptor.evaluation.tiers, ["textExact", "textFuzzy"])
    }

    func testKBAdapterDescriptor_matchesAuthoredColoradoResource() throws {
        let authored = try QuizMatchFormatDescriptor.load(named: "kb-colorado")
        let derived = KBQuizMatchAdapter.descriptor(for: KBRegionalConfig.forRegion(.colorado))
        XCTAssertEqual(derived, authored)
    }

    // MARK: - qb-naqt-skeleton.json (format generality proof)

    func testQBNAQTSkeletonResource_expressesNAQTRules() throws {
        let descriptor = try QuizMatchFormatDescriptor.load(named: "qb-naqt-skeleton")

        XCTAssertEqual(descriptor.formatId, "qb-naqt-skeleton")
        XCTAssertEqual(descriptor.engine, "quiz-match/1")

        // No written phase.
        XCTAssertEqual(descriptor.phases, [.oral])
        XCTAssertNil(descriptor.written)

        // Individual buzz with lockout.
        XCTAssertEqual(descriptor.buzz.mode, .individual)
        XCTAssertTrue(descriptor.buzz.lockout)
        XCTAssertFalse(descriptor.buzz.recognitionRequired)

        // NAQT scoring: 10 correct, 15 power, -5 neg, 3 x 10 bonuses.
        XCTAssertEqual(descriptor.scoring.correct, 10)
        XCTAssertEqual(descriptor.scoring.power, 15)
        XCTAssertEqual(descriptor.scoring.incorrect, -5)
        XCTAssertEqual(descriptor.scoring.bonus?.partCount, 3)
        XCTAssertEqual(descriptor.scoring.bonus?.pointsPerPart, 10)

        // No conference; pyramidal tossups; 24 per match.
        XCTAssertNil(descriptor.conference)
        XCTAssertEqual(descriptor.questionForm, .pyramidal)
        XCTAssertEqual(descriptor.oral?.questions, 24)

        // Placeholder evaluation profile until QB gets its own.
        XCTAssertEqual(descriptor.evaluation.profile, "kb-standard")
    }

    // MARK: - VoicePipelineConfig Derivation

    func testVoicePipelineConfig_fromKBColorado() throws {
        let descriptor = try QuizMatchFormatDescriptor.load(named: "kb-colorado")
        let config = descriptor.voicePipelineConfig()

        XCTAssertEqual(config.endpointing.silenceThreshold, 2.5)
        XCTAssertEqual(config.endpointing.maxUtteranceDuration, 60)
        XCTAssertEqual(config.bargeIn, .off)
        XCTAssertEqual(config.buzzMode, .team)
        XCTAssertNil(config.answerTimeout)
        XCTAssertEqual(config.conference?.duration, 15)
    }

    func testVoicePipelineConfig_fromQBSkeleton() throws {
        let descriptor = try QuizMatchFormatDescriptor.load(named: "qb-naqt-skeleton")
        let config = descriptor.voicePipelineConfig()

        XCTAssertEqual(config.buzzMode, .individual)
        XCTAssertEqual(config.answerTimeout, .seconds(5))
        XCTAssertNil(config.conference)
    }

    // MARK: - Loading Errors

    func testLoad_missingResourceThrowsTypedError() {
        XCTAssertThrowsError(try QuizMatchFormatDescriptor.load(named: "no-such-format")) { error in
            XCTAssertEqual(
                error as? QuizMatchDescriptorError,
                .resourceNotFound("no-such-format")
            )
        }
    }
}
