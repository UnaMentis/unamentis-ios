// UnaMentis - Oral Exam Format Descriptor
// MODULE_SDK_SPEC.md section 6.2, schema "format-descriptor.oral-exam/1"
//
// A format descriptor is DATA: the complete stage structure, rubric, examiner
// configuration, and evaluation rules of one oral examination format, consumed
// by the generic OralExamEngine. New exams (Maturita, Matura, Leaving Cert,
// IB Individual Oral) should require no new engine code, only new descriptors
// plus oral-syllabus content packs.
//
// The schema follows spec section 6.2 with one additive extension flagged for
// the RFC process:
// - `listening`: response endpointing for long-form capture (silence threshold
//   and max utterance duration). Spec 6.2 has no home for endpointing even
//   though Phase 2 made it configuration rather than code, exactly the gap
//   RFC 0005 item 1 records for quiz-match. Absent the block, the engine's
//   long-form defaults apply.
//
// Per the versioning policy (spec section 10), unknown JSON fields are
// tolerated and all extensions are optional.

import Foundation

/// The complete rule set of one oral examination format
/// (`format-descriptor.oral-exam/1`).
public struct OralExamFormatDescriptor: Codable, Sendable, Equatable {
    /// Stable format identifier, e.g. "fr-grand-oral", "practice-viva".
    public var formatId: String

    /// The engine contract this descriptor targets, e.g. "oral-exam/1".
    public var engine: String

    /// The exam's language as a BCP-47 tag (e.g. "fr-FR"). This is the language
    /// the session content runs in; the app shell stays in the UI language.
    public var language: String

    /// The exam's stages, in order.
    public var stages: [Stage]

    /// Rubric dimension names, in display order (e.g. "structure", "clarity").
    public var rubric: [String]

    /// Examiner persona configuration.
    public var examiner: ExaminerRules

    /// Evaluation configuration: rubric tiers plus delivery metrics.
    public var evaluation: EvaluationRules

    /// Long-form response endpointing (additive extension; see header note).
    public var listening: ListeningRules?

    public init(
        formatId: String,
        engine: String = "oral-exam/1",
        language: String,
        stages: [Stage],
        rubric: [String],
        examiner: ExaminerRules,
        evaluation: EvaluationRules,
        listening: ListeningRules? = nil
    ) {
        self.formatId = formatId
        self.engine = engine
        self.language = language
        self.stages = stages
        self.rubric = rubric
        self.examiner = examiner
        self.evaluation = evaluation
        self.listening = listening
    }

    // MARK: - Stages

    public struct Stage: Codable, Sendable, Equatable {
        /// What happens during a stage.
        public enum Kind: String, Codable, Sendable {
            /// Timed silent preparation (notes, thinking). No capture.
            case preparation
            /// Timed monologue: the learner presents while the host listens.
            case presentation
            /// Adaptive questioning: the examiner asks grounded follow-ups.
            case questioning
        }

        public var kind: Kind

        /// Stage duration in seconds.
        public var seconds: Double

        /// Whether the learner may use notes (presentation stages; Grand Oral
        /// famously prohibits them). Nil means the format does not say.
        public var notesAllowed: Bool?

        /// Questioning style, e.g. "jury", "conversation". Free-form per spec
        /// 6.2; nil for non-questioning stages.
        public var style: String?

        /// How many grounded follow-ups the examiner asks per root question
        /// (questioning stages). Nil means no follow-ups.
        public var followUpDepth: Int?

        public init(
            kind: Kind,
            seconds: Double,
            notesAllowed: Bool? = nil,
            style: String? = nil,
            followUpDepth: Int? = nil
        ) {
            self.kind = kind
            self.seconds = seconds
            self.notesAllowed = notesAllowed
            self.style = style
            self.followUpDepth = followUpDepth
        }
    }

    // MARK: - Examiner

    public struct ExaminerRules: Codable, Sendable, Equatable {
        /// Number of examiner personas (Grand Oral: a jury of two).
        public var personaCount: Int

        /// The examiner's register: "formal", "encouraging", or "strict".
        public var register: String

        public init(personaCount: Int, register: String) {
            self.personaCount = personaCount
            self.register = register
        }
    }

    // MARK: - Evaluation

    public struct EvaluationRules: Codable, Sendable, Equatable {
        /// Evaluator tiers to run. Leaf names match `EvaluatorKind` raw values;
        /// oral exams use ["llmRubric"].
        public var tiers: [String]

        /// Delivery metrics the engine computes from transcript timing:
        /// "pace", "fillerWords", "hesitations".
        public var deliveryMetrics: [String]

        public init(tiers: [String], deliveryMetrics: [String]) {
            self.tiers = tiers
            self.deliveryMetrics = deliveryMetrics
        }
    }

    // MARK: - Listening (additive extension)

    public struct ListeningRules: Codable, Sendable, Equatable {
        /// Silence after speech that finalizes one long-form utterance segment,
        /// in seconds. Long-form monologues want a generous value.
        public var responseSilenceSec: Double

        /// Hard cap on one utterance segment's duration, in seconds.
        public var maxUtteranceSec: Double

        public init(responseSilenceSec: Double, maxUtteranceSec: Double) {
            self.responseSilenceSec = responseSilenceSec
            self.maxUtteranceSec = maxUtteranceSec
        }
    }

    // MARK: - Derived Values

    /// Engine defaults for long-form capture when the descriptor carries no
    /// `listening` block: a 2 second silence threshold (a presenter pausing for
    /// thought should not be endpointed like a quiz answer) and a 3 minute
    /// utterance segment cap.
    public static let defaultResponseSilenceSec = 2.0
    public static let defaultMaxUtteranceSec = 180.0

    /// The effective silence threshold for this format.
    public var responseSilenceSeconds: Double {
        listening?.responseSilenceSec ?? Self.defaultResponseSilenceSec
    }

    /// The effective per-segment utterance cap for this format.
    public var maxUtteranceSeconds: Double {
        listening?.maxUtteranceSec ?? Self.defaultMaxUtteranceSec
    }

    /// The first stage of the given kind, if the format has one.
    public func stage(ofKind kind: Stage.Kind) -> Stage? {
        stages.first { $0.kind == kind }
    }
}

// MARK: - Descriptor-Derived Pipeline Configuration

extension OralExamFormatDescriptor {
    /// The voice pipeline configuration this format calls for: long-form
    /// endpointing (generous silence threshold and max utterance) and no
    /// answer timeout (the stage timer, not the mic, bounds the learner).
    ///
    /// The locale defaults to en-US rather than the descriptor's language
    /// deliberately: `VoicePipelineConfig.locale` is accepted but not plumbed
    /// into STT (RFC 0002 item 6), so passing fr-FR here would claim a
    /// capability the pipeline does not deliver. When the locale plumbing
    /// lands, callers switch to `Locale(identifier: language)`.
    public func voicePipelineConfig(
        locale: Locale = Locale(identifier: "en-US"),
        bargeIn: BargeInPolicy = .off
    ) -> VoicePipelineConfig {
        VoicePipelineConfig(
            locale: locale,
            endpointing: EndpointingPolicy(
                silenceThreshold: responseSilenceSeconds,
                maxUtteranceDuration: maxUtteranceSeconds
            ),
            bargeIn: bargeIn
        )
    }
}

// MARK: - JSON Loading

extension OralExamFormatDescriptor {
    /// Decode a descriptor from JSON data.
    public static func decode(from data: Data) throws -> OralExamFormatDescriptor {
        try JSONDecoder().decode(OralExamFormatDescriptor.self, from: data)
    }

    /// Encode this descriptor as JSON data.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Load a bundled descriptor resource, e.g. "fr-grand-oral".
    public static func load(named name: String, in bundle: Bundle = .main) throws -> OralExamFormatDescriptor {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw OralExamDescriptorError.resourceNotFound(name)
        }
        return try decode(from: Data(contentsOf: url))
    }
}

/// Errors loading oral exam format descriptors.
public enum OralExamDescriptorError: Error, LocalizedError, Equatable {
    case resourceNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .resourceNotFound(let name):
            return "Oral exam format descriptor resource '\(name)' not found."
        }
    }
}
