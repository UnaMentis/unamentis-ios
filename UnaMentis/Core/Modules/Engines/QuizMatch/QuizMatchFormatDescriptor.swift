// UnaMentis - Quiz Match Format Descriptor
// MODULE_SDK_SPEC.md section 6.1, schema "format-descriptor.quiz-match/1"
//
// A format descriptor is DATA: the complete rule set of one quiz competition
// format, consumed by the generic QuizMatchEngine. New competitions should
// require no new engine code, only a new descriptor (plus content packs).
//
// The schema follows spec section 6.1 with two additive extensions the live
// Knowledge Bowl behavior required (flagged for the RFC process):
// - `oral`: oral-round question count and answer-capture endpointing
//   (silence threshold, max utterance duration, optional answer timeout).
//   Spec 6.1 has a written-round config but no oral-round equivalent, and no
//   home for endpointing, which Phase 2 made configuration rather than code.
// - `conference.milestoneSeconds` is intentionally NOT a field: milestone
//   announcements follow the hands-free countdown pattern (30s/15s/10s, then
//   5-1 ticks) and are engine behavior, not per-format data.
//
// Per the versioning policy (spec section 10), unknown JSON fields are
// tolerated and all extensions are optional.

import Foundation

/// The complete rule set of one quiz competition format
/// (`format-descriptor.quiz-match/1`).
public struct QuizMatchFormatDescriptor: Codable, Sendable, Equatable {
    /// Stable format identifier, e.g. "kb-colorado", "qb-naqt".
    public var formatId: String

    /// The engine contract this descriptor targets, e.g. "quiz-match/1".
    public var engine: String

    /// Which match phases this format includes.
    public var phases: [Phase]

    /// Buzz semantics.
    public var buzz: BuzzRules

    /// Point values.
    public var scoring: ScoringRules

    /// What happens after an incorrect oral answer.
    public var rebound: ReboundRules

    /// Team deliberation timing; nil when the format has no conference.
    public var conference: ConferenceRules?

    /// Written (multiple choice) round configuration; nil when the format has
    /// no written phase.
    public var written: WrittenRules?

    /// Oral round configuration (additive extension; see header note).
    public var oral: OralRules?

    /// Question presentation form.
    public var questionForm: QuestionForm

    /// Answer evaluation configuration.
    public var evaluation: EvaluationRules

    public init(
        formatId: String,
        engine: String = "quiz-match/1",
        phases: [Phase],
        buzz: BuzzRules,
        scoring: ScoringRules,
        rebound: ReboundRules,
        conference: ConferenceRules? = nil,
        written: WrittenRules? = nil,
        oral: OralRules? = nil,
        questionForm: QuestionForm,
        evaluation: EvaluationRules
    ) {
        self.formatId = formatId
        self.engine = engine
        self.phases = phases
        self.buzz = buzz
        self.scoring = scoring
        self.rebound = rebound
        self.conference = conference
        self.written = written
        self.oral = oral
        self.questionForm = questionForm
        self.evaluation = evaluation
    }

    // MARK: - Phases

    public enum Phase: String, Codable, Sendable {
        case written
        case oral
    }

    // MARK: - Buzz

    public struct BuzzRules: Codable, Sendable, Equatable {
        public enum Mode: String, Codable, Sendable {
            /// The whole team answers together (Knowledge Bowl).
            case team
            /// One player buzzes and answers alone (Quiz Bowl).
            case individual
        }

        public var mode: Mode

        /// Whether an incorrect buzz locks that side out of the question.
        public var lockout: Bool

        /// Whether the moderator must recognize the buzzer before the answer
        /// counts (Science Bowl style).
        public var recognitionRequired: Bool

        public init(mode: Mode, lockout: Bool, recognitionRequired: Bool) {
            self.mode = mode
            self.lockout = lockout
            self.recognitionRequired = recognitionRequired
        }
    }

    // MARK: - Scoring

    public struct ScoringRules: Codable, Sendable, Equatable {
        /// Points for a correct answer (after the power mark, if pyramidal).
        public var correct: Int

        /// Points for an incorrect interrupt (a buzz before the question is
        /// finished). Negative for formats with negs (NAQT -5); zero when
        /// wrong answers simply score nothing.
        public var incorrect: Int

        /// Points for a correct answer before the power mark (pyramidal
        /// formats only). Nil when the format has no powers.
        public var power: Int?

        /// Bonus question configuration. Nil when the format has no bonuses.
        public var bonus: BonusRules?

        public init(correct: Int, incorrect: Int, power: Int? = nil, bonus: BonusRules? = nil) {
            self.correct = correct
            self.incorrect = incorrect
            self.power = power
            self.bonus = bonus
        }
    }

    public struct BonusRules: Codable, Sendable, Equatable {
        /// Number of parts per bonus (NAQT 3, Science Bowl 4).
        public var partCount: Int

        /// Points per correctly answered part.
        public var pointsPerPart: Int

        public init(partCount: Int, pointsPerPart: Int) {
            self.partCount = partCount
            self.pointsPerPart = pointsPerPart
        }
    }

    // MARK: - Rebound

    public struct ReboundRules: Codable, Sendable, Equatable {
        public enum Order: String, Codable, Sendable {
            /// The question passes to the next team in order.
            case nextTeam = "next-team"
            /// Any remaining team may buzz.
            case open
        }

        public var enabled: Bool
        public var order: Order

        public init(enabled: Bool, order: Order) {
            self.enabled = enabled
            self.order = order
        }
    }

    // MARK: - Conference

    public struct ConferenceRules: Codable, Sendable, Equatable {
        /// Deliberation time in seconds.
        public var seconds: Double

        /// Whether the team may talk during deliberation (Colorado: no).
        public var verbalAllowed: Bool

        public init(seconds: Double, verbalAllowed: Bool) {
            self.seconds = seconds
            self.verbalAllowed = verbalAllowed
        }
    }

    // MARK: - Written

    public struct WrittenRules: Codable, Sendable, Equatable {
        /// Number of written questions.
        public var questions: Int

        /// Choice labels in order, e.g. ["A","B","C","D"] or ["W","X","Y","Z"].
        public var choices: [String]

        /// Time limit for the whole written round, in seconds.
        public var timeLimitSec: Int

        public init(questions: Int, choices: [String], timeLimitSec: Int) {
            self.questions = questions
            self.choices = choices
            self.timeLimitSec = timeLimitSec
        }
    }

    // MARK: - Oral (additive extension)

    public struct OralRules: Codable, Sendable, Equatable {
        /// Format-default number of oral questions per match. Sessions may
        /// override (practice sessions pick their own count).
        public var questions: Int

        /// Silence after speech that finalizes a spoken answer, in seconds.
        public var answerSilenceSec: Double

        /// Hard cap on one spoken answer's duration, in seconds.
        public var maxUtteranceSec: Double

        /// How long to wait for any speech at all before timing the answer
        /// out. Nil means no timeout (the learner controls the mic).
        public var answerTimeoutSec: Double?

        public init(
            questions: Int,
            answerSilenceSec: Double,
            maxUtteranceSec: Double,
            answerTimeoutSec: Double? = nil
        ) {
            self.questions = questions
            self.answerSilenceSec = answerSilenceSec
            self.maxUtteranceSec = maxUtteranceSec
            self.answerTimeoutSec = answerTimeoutSec
        }
    }

    // MARK: - Question Form

    public enum QuestionForm: String, Codable, Sendable {
        /// Short factual questions, read in full (Knowledge Bowl).
        case short
        /// Pyramidal clues, hardest first, with a power mark (Quiz Bowl).
        case pyramidal
    }

    // MARK: - Evaluation

    public struct EvaluationRules: Codable, Sendable, Equatable {
        /// Named host strictness profile (MODULE_SDK_SPEC.md section 5.2),
        /// e.g. "kb-standard", "colorado-strict".
        public var profile: String

        /// Evaluator tiers to run, in order. Leaf names match `EvaluatorKind`
        /// raw values ("textExact", "textFuzzy", "numeric", "choice", ...).
        public var tiers: [String]

        public init(profile: String, tiers: [String]) {
            self.profile = profile
            self.tiers = tiers
        }
    }
}

// MARK: - JSON Loading

extension QuizMatchFormatDescriptor {
    /// Decode a descriptor from JSON data.
    public static func decode(from data: Data) throws -> QuizMatchFormatDescriptor {
        try JSONDecoder().decode(QuizMatchFormatDescriptor.self, from: data)
    }

    /// Encode this descriptor as JSON data.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Load a bundled descriptor resource, e.g. "kb-colorado".
    public static func load(named name: String, in bundle: Bundle = .main) throws -> QuizMatchFormatDescriptor {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw QuizMatchDescriptorError.resourceNotFound(name)
        }
        return try decode(from: Data(contentsOf: url))
    }
}

/// Errors loading format descriptors.
public enum QuizMatchDescriptorError: Error, LocalizedError, Equatable {
    case resourceNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .resourceNotFound(let name):
            return "Format descriptor resource '\(name)' not found."
        }
    }
}
