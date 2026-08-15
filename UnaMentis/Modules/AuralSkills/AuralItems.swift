// UnaMentis - Aural Skills Item Schema (aural-items/1)
// The module-side content schema per AURAL_SKILLS_MODULE_SPEC.md section 3.
//
// Key property of the schema: prompts are SYNTHESIZED, not recorded. Items
// declare notes/chords symbolically and the host tone generator (RFC 0007,
// audio.tonegen/1) renders them, so packs are tiny and transposition is free.
//
// The pack's items.json is an array of `AuralPackEntry` values, each either a
// concrete item or a compact template the module's deterministic generator
// (AuralItemGenerator) expands at load. Templates keep the JSON small while
// the drill still sees every transposition as a first-class item. The pack
// JSON remains the source of truth; the generator adds nothing that is not
// derivable from it plus the fixed music-theory tables.

import Foundation

// MARK: - Item

/// One drillable aural item (aural-items/1).
public struct AuralItem: Codable, Sendable, Equatable, Identifiable {
    /// Stable item identifier (namespaces attempts and mastery).
    public let id: String

    /// The item kind: "interval", "triad", "tonality", "cadence", "solfege".
    public let kind: String

    /// The symbolic synthesis prompt.
    public let prompt: AuralPromptSpec

    /// The expected answer and acceptable alternatives.
    public let answer: AuralAnswer

    /// Solfège context (movable-do) used for coaching, if applicable.
    public let solfege: AuralSolfege?

    /// Difficulty, 1 (easiest) upward.
    public let difficulty: Int

    /// Skill tags (e.g. "interval.melodic", "cadence").
    public let skills: [String]

    /// Exam-alignment tags (e.g. "abrsm.g3"). Content metadata, not code.
    public let examTags: [String]?

    public init(
        id: String,
        kind: String,
        prompt: AuralPromptSpec,
        answer: AuralAnswer,
        solfege: AuralSolfege? = nil,
        difficulty: Int,
        skills: [String],
        examTags: [String]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.prompt = prompt
        self.answer = answer
        self.solfege = solfege
        self.difficulty = difficulty
        self.skills = skills
        self.examTags = examTags
    }
}

/// The prompt wrapper: today always a synthesis block. Recorded excerpts are
/// a later additive field per the module spec.
public struct AuralPromptSpec: Codable, Sendable, Equatable {
    public let synthesis: AuralSynthesisSpec

    public init(synthesis: AuralSynthesisSpec) {
        self.synthesis = synthesis
    }
}

/// A symbolic synthesis block: what to play and how.
public struct AuralSynthesisSpec: Codable, Sendable, Equatable {
    /// Note names for note/interval/melody items (e.g. ["C4", "Eb4"]).
    public let notes: [String]?

    /// Chord stacks for progression items (each inner array sounds together).
    public let chords: [[String]]?

    /// A chord sounded before `notes` to establish tonal context (the tonic
    /// chord for scale-degree items). Additive schema field.
    public let contextChord: [String]?

    /// Presentation style: "melodic-asc", "melodic-desc", "melodic" (played
    /// in the given order), "harmonic", or "progression".
    public let style: String

    /// Tempo in BPM. Nil = the module default.
    public let tempo: Int?

    /// Timbre name ("sine" today; "piano" arrives with richer host timbres).
    public let timbre: String?

    public init(
        notes: [String]? = nil,
        chords: [[String]]? = nil,
        contextChord: [String]? = nil,
        style: String,
        tempo: Int? = nil,
        timbre: String? = nil
    ) {
        self.notes = notes
        self.chords = chords
        self.contextChord = contextChord
        self.style = style
        self.tempo = tempo
        self.timbre = timbre
    }
}

/// The expected answer: one primary label plus acceptable alternatives.
public struct AuralAnswer: Codable, Sendable, Equatable {
    public let primary: String
    public let acceptable: [String]?

    public init(primary: String, acceptable: [String]? = nil) {
        self.primary = primary
        self.acceptable = acceptable
    }
}

/// Movable-do solfège context for coaching.
public struct AuralSolfege: Codable, Sendable, Equatable {
    /// The solfège degrees the item spans (e.g. ["do", "me"]).
    public let degrees: [String]

    /// A brief spoken coaching line for wrong answers.
    public let coaching: String?

    public init(degrees: [String], coaching: String? = nil) {
        self.degrees = degrees
        self.coaching = coaching
    }
}

// MARK: - Pack Entry (item or template)

/// One entry in an aural-items/1 pack: either a concrete item or a compact
/// template the generator expands at load.
///
/// The schema is "exactly one of the two", and decoding ENFORCES it. Optional
/// members alone would let `{}` (or a typo like `"tempate"`) decode happily
/// into an entry carrying neither, which the generator would then skip; the
/// pack would load short by however many entries were malformed, with nothing
/// anywhere saying so.
public struct AuralPackEntry: PackItem, Equatable {
    public let item: AuralItem?
    public let template: AuralItemTemplate?

    public init(item: AuralItem) {
        self.item = item
        self.template = nil
    }

    public init(template: AuralItemTemplate) {
        self.item = nil
        self.template = template
    }

    private enum CodingKeys: String, CodingKey {
        case item
        case template
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let item = try container.decodeIfPresent(AuralItem.self, forKey: .item)
        let template = try container.decodeIfPresent(AuralItemTemplate.self, forKey: .template)

        guard item != nil || template != nil else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "An aural-items/1 pack entry must carry either "
                    + "an 'item' or a 'template'; this one carries neither."
            ))
        }
        self.item = item
        self.template = template
    }
}

/// A compact, deterministic item template. Expansion is pure: the same
/// template always yields the same items in the same order.
public struct AuralItemTemplate: Codable, Sendable, Equatable {
    /// Template kind: "interval", "triad", "tonality", or "solfege".
    public let kind: String

    /// Interval short names for interval templates (e.g. ["m2", "P5"]).
    public let intervals: [String]?

    /// Triad quality names for triad/tonality templates (e.g. ["major"]).
    public let qualities: [String]?

    /// Scale degrees (1...7) for solfège templates.
    public let degrees: [Int]?

    /// Presentation styles to expand over ("melodic-asc", "melodic-desc",
    /// "harmonic"). Solfège templates ignore this.
    public let styles: [String]?

    /// Root (or tonic) note names to expand over (the free transposition).
    public let roots: [String]

    /// Tempo in BPM for the expanded prompts.
    public let tempo: Int?

    /// Difficulty assigned to every expanded item.
    public let difficulty: Int

    /// Exam-alignment tags applied to every expanded item.
    public let examTags: [String]?

    public init(
        kind: String,
        intervals: [String]? = nil,
        qualities: [String]? = nil,
        degrees: [Int]? = nil,
        styles: [String]? = nil,
        roots: [String],
        tempo: Int? = nil,
        difficulty: Int,
        examTags: [String]? = nil
    ) {
        self.kind = kind
        self.intervals = intervals
        self.qualities = qualities
        self.degrees = degrees
        self.styles = styles
        self.roots = roots
        self.tempo = tempo
        self.difficulty = difficulty
        self.examTags = examTags
    }
}
