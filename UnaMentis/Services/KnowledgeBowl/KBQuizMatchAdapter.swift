// UnaMentis - Knowledge Bowl Quiz Match Adapter
// Adapts Knowledge Bowl onto the generic QuizMatchEngine (MODULE_SDK_SPEC.md
// section 6.1, migration Phase 5).
//
// The dependency direction is one-way by design: the engine knows nothing
// about Knowledge Bowl; KB expresses its format as a QuizMatchFormatDescriptor
// and its questions as QuizMatchQuestions. The Colorado descriptor produced
// here is the same rule set authored as the bundled resource
// Resources/FormatDescriptors/kb-colorado.json (a parity test keeps the two
// in lockstep), derived live from KBRegionalConfig so Minnesota and
// Washington sessions get their regional values too.

import Foundation

enum KBQuizMatchAdapter {
    /// The silence-based utterance endpointing KB oral practice has always
    /// used for spoken answers (previously the view model's
    /// `autoSubmitSilenceThreshold`).
    static let answerSilenceSec: Double = 2.5

    /// Hard cap on one spoken answer's duration.
    static let maxUtteranceSec: Double = 60

    // MARK: - Descriptor

    /// Express a KB regional rule set as a quiz-match format descriptor.
    static func descriptor(for config: KBRegionalConfig) -> QuizMatchFormatDescriptor {
        QuizMatchFormatDescriptor(
            formatId: "kb-\(config.region.rawValue)",
            engine: "quiz-match/1",
            phases: [.written, .oral],
            buzz: .init(mode: .team, lockout: false, recognitionRequired: false),
            scoring: .init(
                correct: config.oralPointsPerCorrect,
                incorrect: 0,
                power: nil,
                bonus: nil
            ),
            rebound: .init(enabled: config.reboundEnabled, order: .nextTeam),
            conference: .init(
                seconds: config.conferenceTime,
                verbalAllowed: config.verbalConferringAllowed
            ),
            written: .init(
                questions: config.writtenQuestionCount,
                choices: ["A", "B", "C", "D"],
                timeLimitSec: Int(config.writtenTimeLimit)
            ),
            oral: .init(
                questions: config.oralQuestionCount,
                answerSilenceSec: answerSilenceSec,
                maxUtteranceSec: maxUtteranceSec,
                answerTimeoutSec: nil
            ),
            questionForm: .short,
            evaluation: .init(
                // The live oral call site has always evaluated at the KB
                // standard profile regardless of region (RFC 0004 item 5);
                // this preserves that behavior. Switching Colorado to
                // colorado-strict is a deliberate, flagged follow-up.
                profile: KBEvaluationBridge.kbStandard.id,
                tiers: [
                    EvaluatorKind.textExact.rawValue,
                    EvaluatorKind.textFuzzy.rawValue
                ]
            )
        )
    }

    // MARK: - Questions

    /// Map a KB question onto the engine's question model, carrying the host
    /// evaluation spec KB has evaluated against since Phase 4.
    static func engineQuestion(
        from question: KBQuestion,
        strictness: KBValidationStrictness
    ) -> QuizMatchQuestion {
        QuizMatchQuestion(
            id: question.id.uuidString,
            text: question.text,
            preRenderedAudio: nil,
            evaluation: KBEvaluationBridge.spec(for: question, strictness: strictness),
            domain: question.domain.rawValue,
            powerMarkIndex: nil,
            bonus: nil
        )
    }
}
