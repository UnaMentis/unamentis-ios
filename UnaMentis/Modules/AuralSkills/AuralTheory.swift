// UnaMentis - Aural Skills Music Theory Tables and Item Generator
// The fixed movable-do theory tables (intervals, triad qualities, solfège
// degrees) and the deterministic generator that expands compact pack
// templates into concrete aural-items/1 items. Expansion is pure and stable:
// the same pack JSON always yields the same items in the same order, so
// tests can pin counts and the drill's non-shuffled order is reproducible.

import Foundation

// MARK: - Theory Tables

/// Fixed music-theory data for item generation and coaching (movable do).
enum AuralTheory {

    /// One simple interval, m2 through P8 (tritone included).
    struct Interval: Sendable {
        let shortName: String       // "m3"
        let semitones: Int

        /// How many diatonic LETTER steps the interval spans: a second is 1,
        /// a third 2, a fourth 3, a fifth 4, a sixth 5, a seventh 6, an octave
        /// 7. This is what makes the upper note's SPELLING correct rather than
        /// merely enharmonic: a major third above E must be some kind of G
        /// (G#), never any kind of A (Ab). The tritone is spelled as an
        /// augmented fourth (3 steps), matching its primary role in this pack.
        let diatonicSteps: Int

        let primary: String         // "minor third"
        let acceptable: [String]
        let upperDegree: String     // solfège of the upper note above do
        let coaching: String

        /// Case-insensitive-safe id component ("m3" vs "M3" would collide
        /// once lowercased, so majors use "maj").
        var idSlug: String {
            if shortName.hasPrefix("M") {
                return "maj" + shortName.dropFirst()
            }
            return shortName.lowercased()
        }
    }

    /// All simple intervals in ascending size order.
    static let intervals: [Interval] = [
        Interval(
            shortName: "m2", semitones: 1, diatonicSteps: 1, primary: "minor second",
            acceptable: ["minor 2nd", "m2", "half step", "semitone"],
            upperDegree: "ra",
            coaching: "A minor second is one half step, from do up to ra. Think of a close, tense leaning sound."
        ),
        Interval(
            shortName: "M2", semitones: 2, diatonicSteps: 1, primary: "major second",
            acceptable: ["major 2nd", "whole step", "whole tone"],
            upperDegree: "re",
            coaching: "A major second is a whole step, do to re, the first step of the major scale."
        ),
        Interval(
            shortName: "m3", semitones: 3, diatonicSteps: 2, primary: "minor third",
            acceptable: ["minor 3rd", "m3", "flat third", "flat 3"],
            upperDegree: "me",
            coaching: "A minor third is do to me, three half steps. Sing do, then the darker lowered third."
        ),
        Interval(
            shortName: "M3", semitones: 4, diatonicSteps: 2, primary: "major third",
            acceptable: ["major 3rd"],
            upperDegree: "mi",
            coaching: "A major third is do to mi, four half steps, the bright opening of a major chord."
        ),
        Interval(
            shortName: "P4", semitones: 5, diatonicSteps: 3, primary: "perfect fourth",
            acceptable: ["perfect 4th", "P4", "fourth", "4th"],
            upperDegree: "fa",
            coaching: "A perfect fourth is do to fa. Sing do, re, mi, fa to find it inside the scale."
        ),
        Interval(
            shortName: "TT", semitones: 6, diatonicSteps: 3, primary: "tritone",
            acceptable: ["augmented fourth", "diminished fifth", "aug 4", "dim 5"],
            upperDegree: "fi",
            coaching: "A tritone is do to fi, six half steps, the restless sound between fourth and fifth."
        ),
        Interval(
            shortName: "P5", semitones: 7, diatonicSteps: 4, primary: "perfect fifth",
            acceptable: ["perfect 5th", "P5", "fifth", "5th"],
            upperDegree: "sol",
            coaching: "A perfect fifth is do to sol, the open, stable frame of the scale."
        ),
        Interval(
            shortName: "m6", semitones: 8, diatonicSteps: 5, primary: "minor sixth",
            acceptable: ["minor 6th", "m6", "flat sixth", "flat 6"],
            upperDegree: "le",
            coaching: "A minor sixth is do to le, eight half steps, wide with a wistful color."
        ),
        Interval(
            shortName: "M6", semitones: 9, diatonicSteps: 5, primary: "major sixth",
            acceptable: ["major 6th"],
            upperDegree: "la",
            coaching: "A major sixth is do to la, nine half steps, wide and warm."
        ),
        Interval(
            shortName: "m7", semitones: 10, diatonicSteps: 6, primary: "minor seventh",
            acceptable: ["minor 7th", "m7", "flat seventh", "flat 7"],
            upperDegree: "te",
            coaching: "A minor seventh is do to te, ten half steps, the dominant seventh reach."
        ),
        Interval(
            shortName: "M7", semitones: 11, diatonicSteps: 6, primary: "major seventh",
            acceptable: ["major 7th"],
            upperDegree: "ti",
            coaching: "A major seventh is do to ti, eleven half steps, leaning strongly toward the octave."
        ),
        Interval(
            shortName: "P8", semitones: 12, diatonicSteps: 7, primary: "octave",
            acceptable: ["perfect octave", "perfect 8th", "P8", "eighth"],
            upperDegree: "do",
            coaching: "An octave is do to high do, the same note name twelve half steps up."
        )
    ]

    /// Look up an interval by short name. Case matters where folding is
    /// ambiguous ("m3" is minor, "M3" is major); case-insensitive matching is
    /// used only when it is unambiguous ("p5", "tt").
    static func interval(named shortName: String) -> Interval? {
        if let exact = intervals.first(where: { $0.shortName == shortName }) {
            return exact
        }
        let folded = intervals.filter { $0.shortName.lowercased() == shortName.lowercased() }
        return folded.count == 1 ? folded.first : nil
    }

    /// One triad quality.
    struct TriadQuality: Sendable {
        let name: String            // "major"
        let semitoneOffsets: [Int]  // from the root
        let primary: String
        let acceptable: [String]
        let degrees: [String]
        let coaching: String

        /// Diatonic LETTER steps for the three chord members. Every quality
        /// here is tertian (root, some third, some fifth), so all four stack
        /// on the same letters and only the accidentals differ: E augmented is
        /// E, G#, B# (not E, G#, C), and A augmented is A, C#, E# (not F).
        var diatonicSteps: [Int] { [0, 2, 4] }
    }

    static let triadQualities: [TriadQuality] = [
        TriadQuality(
            name: "major", semitoneOffsets: [0, 4, 7],
            primary: "major", acceptable: ["major triad", "major chord", "maj"],
            degrees: ["do", "mi", "sol"],
            coaching: "A major triad stacks do, mi, sol. The bright major third sits at the bottom."
        ),
        TriadQuality(
            name: "minor", semitoneOffsets: [0, 3, 7],
            primary: "minor", acceptable: ["minor triad", "minor chord", "min"],
            degrees: ["do", "me", "sol"],
            coaching: "A minor triad stacks do, me, sol. The lowered third darkens the sound."
        ),
        TriadQuality(
            name: "diminished", semitoneOffsets: [0, 3, 6],
            primary: "diminished", acceptable: ["diminished triad", "diminished chord", "dim"],
            degrees: ["do", "me", "se"],
            coaching: "A diminished triad stacks two minor thirds, do, me, se. It sounds tight and unstable."
        ),
        TriadQuality(
            name: "augmented", semitoneOffsets: [0, 4, 8],
            primary: "augmented", acceptable: ["augmented triad", "augmented chord", "aug"],
            degrees: ["do", "mi", "si"],
            coaching: "An augmented triad stacks two major thirds, do, mi, si. It sounds stretched and unresolved."
        )
    ]

    static func triadQuality(named name: String) -> TriadQuality? {
        triadQualities.first { $0.name.lowercased() == name.lowercased() }
    }

    /// One major-scale degree with its movable-do syllable.
    struct ScaleDegree: Sendable {
        let number: Int
        let semitonesAboveTonic: Int
        let syllable: String
        let acceptable: [String]
        let coaching: String

        /// Diatonic LETTER steps above the tonic. Degree 1 is 0 steps through
        /// degree 7 at 6, so degree 7 over G is F# (an F), never Gb.
        var diatonicSteps: Int { number - 1 }
    }

    /// SOLFÈGE POLICY (movable do). This module exists to teach the very
    /// distinctions the chromatic syllables encode, so a chromatic syllable is
    /// NEVER accepted for its diatonic neighbour, in either direction:
    ///
    ///   ra/re, me/mi, fi/fa, se/sol, si/sol, le/la, te/ti
    ///
    /// In particular `me` is the LOWERED third (the minor third the module's
    /// own minor-triad coaching spells "do, me, sol"), so accepting it for
    /// `mi` would train the learner to conflate major and minor thirds, and
    /// `si` is the RAISED fifth this module uses in its augmented-triad
    /// degrees ("do, mi, si"), so accepting it for `ti` would contradict the
    /// module's own table. The fixed-do convention where "si" names the
    /// seventh degree does not apply here. Phonetic renderings of a diatonic
    /// syllable that are not themselves syllables ("doh", "mee", "soh", "tee")
    /// stay accepted: they are STT spellings, not a different degree.
    static let scaleDegrees: [ScaleDegree] = [
        ScaleDegree(
            number: 1, semitonesAboveTonic: 0, syllable: "do",
            acceptable: ["doh", "doe", "dough", "tonic", "one", "first degree"],
            coaching: "Do is the tonic, the home note the chord settled on."
        ),
        ScaleDegree(
            number: 2, semitonesAboveTonic: 2, syllable: "re",
            acceptable: ["ray", "two", "second degree", "supertonic"],
            coaching: "Re sits one whole step above do. Sing do, then step up once."
        ),
        ScaleDegree(
            number: 3, semitonesAboveTonic: 4, syllable: "mi",
            // "me" is deliberately absent: it is the lowered third.
            acceptable: ["mee", "three", "third degree", "mediant"],
            coaching: "Mi is the major third of the tonic chord you just heard."
        ),
        ScaleDegree(
            number: 4, semitonesAboveTonic: 5, syllable: "fa",
            acceptable: ["fah", "four", "fourth degree", "subdominant"],
            coaching: "Fa leans back down toward mi. Sing do, re, mi, fa to reach it."
        ),
        ScaleDegree(
            number: 5, semitonesAboveTonic: 7, syllable: "sol",
            acceptable: ["so", "soh", "sole", "five", "fifth degree", "dominant"],
            coaching: "Sol is the dominant, the strong fifth of the tonic chord."
        ),
        ScaleDegree(
            number: 6, semitonesAboveTonic: 9, syllable: "la",
            acceptable: ["lah", "six", "sixth degree", "submediant"],
            coaching: "La sits a whole step above sol, the start of the relative minor."
        ),
        ScaleDegree(
            number: 7, semitonesAboveTonic: 11, syllable: "ti",
            // "si" is deliberately absent: in movable do it is the raised
            // fifth this module's augmented triad already uses.
            acceptable: ["tee", "tea", "seven", "seventh degree", "leading tone"],
            coaching: "Ti is the leading tone. Hear how it pulls up to do."
        )
    ]

    static func scaleDegree(_ number: Int) -> ScaleDegree? {
        scaleDegrees.first { $0.number == number }
    }

    // MARK: Note-name helpers

    /// A note name parsed into its SPELLING parts rather than its pitch class.
    ///
    /// This is the whole point of the type: G#4 and Ab4 sound the same and are
    /// the same MIDI number, but they are different notes on the page, and
    /// which one is right depends on the root the generator transposed from.
    /// A single fixed chromatic table cannot express that, so spelling is
    /// derived from the root's LETTER instead.
    struct SpelledNote: Sendable, Equatable {
        /// Letter index, 0 = C through 6 = B.
        let letterIndex: Int
        /// Accidental in semitones: -2 (double flat) through +2 (double sharp).
        let accidental: Int
        /// Scientific octave (C4 is middle C, MIDI 60).
        let octave: Int

        /// Semitones above C for each natural letter, C through B.
        static let letterSemitones = [0, 2, 4, 5, 7, 9, 11]
        /// Letter names in the same order.
        static let letterNames: [Character] = ["C", "D", "E", "F", "G", "A", "B"]

        /// MIDI note number this spelling sounds.
        var midi: Int {
            (octave + 1) * 12 + Self.letterSemitones[letterIndex] + accidental
        }

        /// The scientific note name ("G#4", "Bb3", "B#3").
        var name: String {
            let mark = accidental >= 0
                ? String(repeating: "#", count: accidental)
                : String(repeating: "b", count: -accidental)
            return "\(Self.letterNames[letterIndex])\(mark)\(octave)"
        }
    }

    /// The maximum accidental the generator will EMIT.
    ///
    /// `TonePitch(noteName:)` parses exactly one accidental character, so a
    /// double sharp or double flat would be silently read as its natural and
    /// the wrong pitch would sound. Rather than emit a name the host tone
    /// generator cannot round-trip, the generator refuses to spell it and the
    /// content error surfaces. Widen this only after that parser is widened.
    static let maxEmittableAccidental = 1

    /// Parse a scientific note name (letter, optional accidentals, octave)
    /// into its spelling parts. Nil if the name is not spelled that way or
    /// does not land in the MIDI range.
    static func spelledNote(_ noteName: String) -> SpelledNote? {
        var rest = Substring(noteName.trimmingCharacters(in: .whitespaces))
        guard let letter = rest.popFirst(),
              let letterIndex = SpelledNote.letterNames.firstIndex(
                  of: Character(letter.uppercased())
              )
        else { return nil }

        var accidental = 0
        while let mark = rest.first {
            if mark == "#" || mark == "\u{266F}" {
                accidental += 1
            } else if mark == "b" || mark == "\u{266D}" {
                accidental -= 1
            } else {
                break
            }
            rest = rest.dropFirst()
        }

        guard abs(accidental) <= 2,
              let octave = Int(rest), (-1...9).contains(octave)
        else { return nil }

        let note = SpelledNote(letterIndex: letterIndex, accidental: accidental, octave: octave)
        guard (0...127).contains(note.midi) else { return nil }
        return note
    }

    /// Spell the note that lies `diatonicSteps` LETTER steps above `root` and
    /// sounds at `targetMidi`.
    ///
    /// The letter comes from the root's letter plus the interval's diatonic
    /// size (so a major third above E is a G of some kind), the octave comes
    /// from that SPELLED letter and not from `targetMidi / 12 - 1` (or B#3
    /// would print as B#4), and the accidental is whatever closes the gap
    /// between the letter's natural pitch and the sounding pitch. Nil when the
    /// result would need an accidental the host tone parser cannot read back.
    static func spelledName(
        root: SpelledNote,
        diatonicSteps: Int,
        targetMidi: Int
    ) -> String? {
        let absoluteLetter = root.letterIndex + diatonicSteps
        let letterIndex = ((absoluteLetter % 7) + 7) % 7
        let octave = root.octave + Int(floor(Double(absoluteLetter) / 7.0))

        let naturalMidi = (octave + 1) * 12 + SpelledNote.letterSemitones[letterIndex]
        let accidental = targetMidi - naturalMidi
        guard abs(accidental) <= maxEmittableAccidental else { return nil }

        let spelled = SpelledNote(
            letterIndex: letterIndex, accidental: accidental, octave: octave
        )
        guard (0...127).contains(spelled.midi) else { return nil }
        return spelled.name
    }

    /// A slug-safe form of a note name for item IDs ("F#3" -> "fs3").
    static func noteSlug(_ noteName: String) -> String {
        noteName.lowercased()
            .replacingOccurrences(of: "#", with: "s")
    }
}

// MARK: - Generator

/// Deterministically expands pack entries (items plus templates) into the
/// concrete item list the drill runs on.
enum AuralItemGenerator {

    /// Expand all entries, preserving pack order (items in place, template
    /// expansions in template-declared order).
    ///
    /// Expansion THROWS on malformed content rather than dropping it. A pack
    /// that names an unknown template kind, an unknown interval, or a root the
    /// tone generator cannot play used to lose those items silently, which in
    /// the field looks like a short drill and nothing else.
    static func expand(_ entries: [AuralPackEntry]) throws -> [AuralItem] {
        var items: [AuralItem] = []
        for entry in entries {
            if let item = entry.item {
                items.append(item)
            } else if let template = entry.template {
                items.append(contentsOf: try expand(template))
            }
        }
        return items
    }

    /// Expand one template.
    static func expand(_ template: AuralItemTemplate) throws -> [AuralItem] {
        switch template.kind {
        case "interval":
            return try expandInterval(template)
        case "triad":
            return try expandTriad(template)
        case "tonality":
            return try expandTonality(template)
        case "solfege":
            return try expandSolfege(template)
        default:
            throw AuralSkillsError.unknownTemplateKind(template.kind)
        }
    }

    /// Parse a template root into its spelling, or surface it as content error.
    private static func spelledRoot(_ root: String) throws -> AuralTheory.SpelledNote {
        guard let note = AuralTheory.spelledNote(root), TonePitch(noteName: root) != nil else {
            throw AuralSkillsError.unplayableRoot(root)
        }
        return note
    }

    /// Spell one note above a root, or surface it as content error.
    private static func spelled(
        root: AuralTheory.SpelledNote,
        rootName: String,
        diatonicSteps: Int,
        semitones: Int
    ) throws -> String {
        guard let name = AuralTheory.spelledName(
            root: root, diatonicSteps: diatonicSteps, targetMidi: root.midi + semitones
        ) else {
            throw AuralSkillsError.unspellableNote(root: rootName, semitonesAbove: semitones)
        }
        return name
    }

    private static func expandInterval(_ template: AuralItemTemplate) throws -> [AuralItem] {
        let intervalNames = template.intervals ?? AuralTheory.intervals.map(\.shortName)
        let styles = template.styles ?? ["melodic-asc"]
        var items: [AuralItem] = []

        for name in intervalNames {
            guard let interval = AuralTheory.interval(named: name) else {
                throw AuralSkillsError.unknownTemplateValue(field: "interval", value: name)
            }
            for style in styles {
                for root in template.roots {
                    let rootNote = try spelledRoot(root)
                    let upper = try spelled(
                        root: rootNote,
                        rootName: root,
                        diatonicSteps: interval.diatonicSteps,
                        semitones: interval.semitones
                    )
                    let styleSlug = styleShortSlug(style)
                    let skill = style == "harmonic" ? "interval.harmonic" : "interval.melodic"
                    items.append(AuralItem(
                        id: "interval-\(interval.idSlug)-\(styleSlug)-"
                            + "\(AuralTheory.noteSlug(root))-d\(template.difficulty)",
                        kind: "interval",
                        prompt: AuralPromptSpec(synthesis: AuralSynthesisSpec(
                            notes: [root, upper],
                            style: style,
                            tempo: template.tempo,
                            timbre: "sine"
                        )),
                        answer: AuralAnswer(
                            primary: interval.primary,
                            acceptable: interval.acceptable
                        ),
                        solfege: AuralSolfege(
                            degrees: ["do", interval.upperDegree],
                            coaching: interval.coaching
                        ),
                        difficulty: template.difficulty,
                        skills: [skill],
                        examTags: template.examTags
                    ))
                }
            }
        }
        return items
    }

    private static func expandTriad(_ template: AuralItemTemplate) throws -> [AuralItem] {
        try expandQualities(template, kind: "triad", skills: ["chord.triad"]) { quality in
            AuralAnswer(primary: quality.primary, acceptable: quality.acceptable)
        }
    }

    /// Tonality items reuse triad synthesis but ask only major vs minor.
    private static func expandTonality(_ template: AuralItemTemplate) throws -> [AuralItem] {
        try expandQualities(template, kind: "tonality", skills: ["tonality.triad"]) { quality in
            AuralAnswer(
                primary: quality.name,
                acceptable: quality.name == "major" ? ["major key", "maj"] : ["minor key", "min"]
            )
        }
    }

    private static func expandQualities(
        _ template: AuralItemTemplate,
        kind: String,
        skills: [String],
        answer: (AuralTheory.TriadQuality) -> AuralAnswer
    ) throws -> [AuralItem] {
        let qualityNames = template.qualities ?? AuralTheory.triadQualities.map(\.name)
        let styles = template.styles ?? ["harmonic"]
        var items: [AuralItem] = []

        for name in qualityNames {
            guard let quality = AuralTheory.triadQuality(named: name) else {
                throw AuralSkillsError.unknownTemplateValue(field: "quality", value: name)
            }
            for style in styles {
                for root in template.roots {
                    let rootNote = try spelledRoot(root)
                    let notes = try zip(quality.diatonicSteps, quality.semitoneOffsets)
                        .map { steps, semitones in
                            try spelled(
                                root: rootNote, rootName: root,
                                diatonicSteps: steps, semitones: semitones
                            )
                        }
                    items.append(AuralItem(
                        id: "\(kind)-\(quality.name)-\(styleShortSlug(style))-"
                            + "\(AuralTheory.noteSlug(root))-d\(template.difficulty)",
                        kind: kind,
                        prompt: AuralPromptSpec(synthesis: AuralSynthesisSpec(
                            notes: notes,
                            style: style,
                            tempo: template.tempo,
                            timbre: "sine"
                        )),
                        answer: answer(quality),
                        solfege: AuralSolfege(degrees: quality.degrees, coaching: quality.coaching),
                        difficulty: template.difficulty,
                        skills: skills,
                        examTags: template.examTags
                    ))
                }
            }
        }
        return items
    }

    private static func expandSolfege(_ template: AuralItemTemplate) throws -> [AuralItem] {
        let degreeNumbers = template.degrees ?? AuralTheory.scaleDegrees.map(\.number)
        var items: [AuralItem] = []

        for number in degreeNumbers {
            guard let degree = AuralTheory.scaleDegree(number) else {
                throw AuralSkillsError.unknownTemplateValue(field: "degree", value: "\(number)")
            }
            for tonic in template.roots {
                let tonicNote = try spelledRoot(tonic)
                // The context chord is the major tonic triad, spelled tertian.
                let tonicChord = try zip([0, 2, 4], [0, 4, 7]).map { steps, semitones in
                    try spelled(
                        root: tonicNote, rootName: tonic,
                        diatonicSteps: steps, semitones: semitones
                    )
                }
                let target = try spelled(
                    root: tonicNote, rootName: tonic,
                    diatonicSteps: degree.diatonicSteps,
                    semitones: degree.semitonesAboveTonic
                )
                items.append(AuralItem(
                    id: "solfege-\(degree.number)-\(AuralTheory.noteSlug(tonic))-d\(template.difficulty)",
                    kind: "solfege",
                    prompt: AuralPromptSpec(synthesis: AuralSynthesisSpec(
                        notes: [target],
                        contextChord: tonicChord,
                        style: "melodic",
                        tempo: template.tempo,
                        timbre: "sine"
                    )),
                    answer: AuralAnswer(primary: degree.syllable, acceptable: degree.acceptable),
                    solfege: AuralSolfege(degrees: [degree.syllable], coaching: degree.coaching),
                    difficulty: template.difficulty,
                    skills: ["solfege.degree"],
                    examTags: template.examTags
                ))
            }
        }
        return items
    }

    private static func styleShortSlug(_ style: String) -> String {
        switch style {
        case "melodic-asc": return "asc"
        case "melodic-desc": return "desc"
        case "harmonic": return "harm"
        case "melodic": return "mel"
        case "progression": return "prog"
        default: return style.replacingOccurrences(of: "/", with: "-")
        }
    }
}

// MARK: - Prompt Building

/// Maps an item's symbolic synthesis block onto a host `TonePrompt`.
enum AuralPromptBuilder {

    /// The default drill tempo when an item declares none.
    static let defaultTempo: Double = 80

    /// Build the playable prompt for an item. Nil if the synthesis block has
    /// no parseable pitches (a content error surfaced by tests).
    static func prompt(for item: AuralItem) -> TonePrompt? {
        let synthesis = item.prompt.synthesis
        let tempo = synthesis.tempo.map(Double.init) ?? defaultTempo

        switch synthesis.style {
        case "progression":
            guard let chords = synthesis.chords, !chords.isEmpty else { return nil }
            let stacks = chords.map { $0.compactMap(TonePitch.init(noteName:)) }
            guard stacks.allSatisfy({ !$0.isEmpty }) else { return nil }
            return .progression(stacks, tempo: tempo)

        case "harmonic":
            guard let pitches = parsedNotes(synthesis), pitches.count >= 2 else { return nil }
            return .harmonic(pitches, tempo: tempo)

        case "melodic-asc", "melodic-desc", "melodic":
            guard var pitches = parsedNotes(synthesis), !pitches.isEmpty else { return nil }
            if synthesis.style == "melodic-asc" {
                pitches.sort { $0.midiNote < $1.midiNote }
            } else if synthesis.style == "melodic-desc" {
                pitches.sort { $0.midiNote > $1.midiNote }
            }

            var events: [ToneEvent] = []
            if let context = synthesis.contextChord {
                let contextPitches = context.compactMap(TonePitch.init(noteName:))
                if !contextPitches.isEmpty {
                    events.append(ToneEvent(pitches: contextPitches, beats: 2.0, gapBeats: 0.6))
                }
            }
            events.append(contentsOf: pitches.map {
                ToneEvent(pitches: [$0], beats: 1.0, gapBeats: 0.15)
            })
            return TonePrompt(events: events, tempo: tempo)

        default:
            return nil
        }
    }

    private static func parsedNotes(_ synthesis: AuralSynthesisSpec) -> [TonePitch]? {
        guard let notes = synthesis.notes else { return nil }
        let pitches = notes.compactMap(TonePitch.init(noteName:))
        guard pitches.count == notes.count else { return nil }
        return pitches
    }
}
