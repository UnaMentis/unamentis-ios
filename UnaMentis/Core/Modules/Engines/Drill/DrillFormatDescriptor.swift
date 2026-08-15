// UnaMentis - Drill Format Descriptor
// MODULE_SDK_SPEC.md section 6.3, schema "format-descriptor.drill/1"
//
// A drill format descriptor is DATA: the complete parameterization of one rapid
// item-practice session, consumed by the generic DrillEngine. New drill formats
// (a vocabulary drill, a mental-math drill, a future flash-card or aural-skills
// pack) should require no new engine code, only a new descriptor plus a content
// pack.
//
// Spec section 6.3 is a one-paragraph sketch ("Descriptor selects item types,
// session shapes (count, time-boxed, streak), scheduling policy (scheduler-driven
// review vs free practice), and watch suitability per item type"). This is the
// concrete Codable form of that sketch, following the QuizMatchFormatDescriptor
// precedent (section 6.1). The frictions this surfaces against the sketch are
// filed for the RFC process (docs/modules/rfcs/, and the final report):
//
// - The sketch names no oral-block equivalent, but a voice-driven drill needs
//   answer endpointing (silence threshold, max utterance) exactly as the
//   quiz-match `oral` block does (RFC 0005 item 1's precedent). Added here as an
//   optional `voice` block reusing the same field names.
// - `itemTypes` is a list of schema-qualified item-type names the format
//   accepts (e.g. "drill-items/1"); the sketch says "item types" without shape.
// - `sessionShapes` is a list (count and/or time-boxed) rather than a single
//   value, so one format can offer several session lengths. A session picks one.
//
// Per the versioning policy (section 10), unknown JSON fields are tolerated and
// every field beyond the identity core is optional or defaulted.

import Foundation

/// The complete parameterization of one drill format
/// (`format-descriptor.drill/1`).
public struct DrillFormatDescriptor: Codable, Sendable, Equatable {
    /// Stable format identifier, e.g. "sat-vocab-drill", "sat-math-mental".
    public var formatId: String

    /// The engine contract this descriptor targets. Always "drill/1" here.
    public var engine: String

    /// Item-type/schema names this format accepts (e.g. "drill-items/1"). The
    /// module selects a pack whose items match; the engine stays schema-agnostic.
    public var itemTypes: [String]

    /// The session shapes this format offers. A session picks one; the module
    /// surfaces the choice. Nonempty in practice (defaults to a single count).
    public var sessionShapes: [SessionShape]

    /// How items are ordered within a session.
    public var schedulingPolicy: SchedulingPolicy

    /// Answer-capture voice policy (endpointing). Nil uses engine defaults.
    public var voice: VoiceRules?

    public init(
        formatId: String,
        engine: String = "drill/1",
        itemTypes: [String],
        sessionShapes: [SessionShape],
        schedulingPolicy: SchedulingPolicy,
        voice: VoiceRules? = nil
    ) {
        self.formatId = formatId
        self.engine = engine
        self.itemTypes = itemTypes
        self.sessionShapes = sessionShapes
        self.schedulingPolicy = schedulingPolicy
        self.voice = voice
    }

    // MARK: - Session Shape

    /// One session length this format offers (spec 6.3 "session shapes").
    public struct SessionShape: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            /// Run a fixed number of items.
            case count
            /// Run as many items as fit in a time budget.
            case timeBoxed = "time-boxed"
        }

        public var kind: Kind

        /// For `count`, the number of items. For `timeBoxed`, the number of
        /// seconds. The unit is implied by `kind` (spec 6.3 keeps these one field).
        public var value: Int

        public init(kind: Kind, value: Int) {
            self.kind = kind
            self.value = value
        }

        /// A fixed-count session of `n` items.
        public static func count(_ n: Int) -> SessionShape {
            SessionShape(kind: .count, value: n)
        }

        /// A time-boxed session of `seconds` seconds.
        public static func timeBoxed(seconds: Int) -> SessionShape {
            SessionShape(kind: .timeBoxed, value: seconds)
        }
    }

    // MARK: - Scheduling Policy

    /// How items are ordered within a session (spec 6.3 "scheduling policy").
    public enum SchedulingPolicy: String, Codable, Sendable {
        /// Pack order (optionally shuffled by the session). No mastery read.
        case free
        /// Review order: items are sorted by ascending stored mastery for their
        /// skill tag, so the weakest skills come first. Reads the ProgressStore.
        case review
    }

    // MARK: - Voice (answer-capture endpointing)

    /// Answer-capture voice policy for a drill, mirroring the quiz-match `oral`
    /// block (RFC 0005 item 1). A mental-math drill wants a tighter silence
    /// threshold than a vocabulary drill; both are data, not code.
    public struct VoiceRules: Codable, Sendable, Equatable {
        /// Silence after speech that finalizes a spoken answer, in seconds.
        public var answerSilenceSec: Double

        /// Hard cap on one spoken answer's duration, in seconds.
        public var maxUtteranceSec: Double

        /// How long to wait for any speech before timing the answer out. Nil
        /// means no timeout (the learner controls the mic).
        public var answerTimeoutSec: Double?

        public init(
            answerSilenceSec: Double,
            maxUtteranceSec: Double,
            answerTimeoutSec: Double? = nil
        ) {
            self.answerSilenceSec = answerSilenceSec
            self.maxUtteranceSec = maxUtteranceSec
            self.answerTimeoutSec = answerTimeoutSec
        }
    }
}

// MARK: - Derived Pipeline Configuration

extension DrillFormatDescriptor {
    /// The voice pipeline configuration this drill calls for: endpointing from
    /// the `voice` block, with the drill defaults when it is absent. The module
    /// passes this to `VoiceSessionService.acquire`.
    public func voicePipelineConfig(
        locale: Locale = Locale(identifier: "en-US"),
        bargeIn: BargeInPolicy = .off
    ) -> VoicePipelineConfig {
        let endpointing = EndpointingPolicy(
            silenceThreshold: voice?.answerSilenceSec ?? EndpointingPolicy.default.silenceThreshold,
            maxUtteranceDuration: voice?.maxUtteranceSec ?? EndpointingPolicy.default.maxUtteranceDuration
        )
        return VoicePipelineConfig(
            locale: locale,
            endpointing: endpointing,
            bargeIn: bargeIn,
            buzzMode: nil,
            answerTimeout: voice?.answerTimeoutSec.map { .seconds($0) },
            conference: nil
        )
    }
}

// MARK: - JSON Loading

extension DrillFormatDescriptor {
    /// Decode a descriptor from JSON data.
    public static func decode(from data: Data) throws -> DrillFormatDescriptor {
        try JSONDecoder().decode(DrillFormatDescriptor.self, from: data)
    }

    /// Encode this descriptor as JSON data.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Load a bundled descriptor resource, e.g. "sat-vocab-drill".
    public static func load(named name: String, in bundle: Bundle = .main) throws -> DrillFormatDescriptor {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw DrillDescriptorError.resourceNotFound(name)
        }
        return try decode(from: Data(contentsOf: url))
    }
}

/// Errors loading drill format descriptors.
public enum DrillDescriptorError: Error, LocalizedError, Equatable {
    case resourceNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .resourceNotFound(let name):
            return "Drill format descriptor resource '\(name)' not found."
        }
    }
}
