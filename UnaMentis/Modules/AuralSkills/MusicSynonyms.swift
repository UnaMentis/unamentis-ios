// UnaMentis - Music Evaluation Profile (Aural Skills)
// The module-supplied synonym resource and strictness profile for spoken
// music labels, following the Phase 4 design (RFC 0004 item 3): the module
// chooses a named profile and the synonym resource travels ON the profile.
//
// Why the profile is STRICT rather than standard: ear-training answers come
// in confusable near-pairs ("major third" vs "minor third", "perfect cadence"
// vs "imperfect cadence") that the standard-level enhanced fuzzy tiers accept
// as matches (n-gram similarity of "perfect cadence" and "imperfect cadence"
// clears the fixed 0.80 threshold). A false accept teaches the wrong ear, so
// this profile runs the Levenshtein baseline only, with a high minimum
// confidence that rejects two-edit confusables at these label lengths, and
// the synonym vocabulary is ALSO expanded into each spec's acceptable-answer
// list so equivalents ("m3", "flat third", "authentic cadence", "half close")
// match exactly. The SynonymResource still rides the profile so the host can
// consult it once a tier-selective fuzzy configuration exists (tracked as a
// spec friction; see the module report and RFC 0004 follow-ups).

import Foundation

/// The Aural Skills evaluation profile: music synonym groups, the strictness
/// profile, and the acceptable-answer expansion used to build EvaluationSpecs.
enum MusicEvaluation {

    // MARK: Synonym groups

    /// Music-domain synonym groups: interval names, chord qualities, cadence
    /// names, and solfège syllables. Keys and members are matched lowercase.
    static let synonymGroups: [String: Set<String>] = [
        // Intervals.
        "minor second": ["minor 2nd", "m2", "half step", "semitone"],
        "major second": ["major 2nd", "whole step", "whole tone"],
        "minor third": ["minor 3rd", "m3", "flat third", "flat 3"],
        "major third": ["major 3rd"],
        "perfect fourth": ["perfect 4th", "p4", "fourth", "4th"],
        "tritone": ["augmented fourth", "diminished fifth", "aug 4", "dim 5"],
        "perfect fifth": ["perfect 5th", "p5", "fifth", "5th"],
        "minor sixth": ["minor 6th", "m6", "flat sixth", "flat 6"],
        "major sixth": ["major 6th"],
        "minor seventh": ["minor 7th", "m7", "flat seventh", "flat 7"],
        "major seventh": ["major 7th"],
        "octave": ["perfect octave", "perfect 8th", "p8", "eighth"],
        // Chord qualities.
        "major": ["maj", "major triad", "major chord", "major key"],
        "minor": ["min", "minor triad", "minor chord", "minor key"],
        "diminished": ["dim", "diminished triad", "diminished chord"],
        "augmented": ["aug", "augmented triad", "augmented chord"],
        // Cadences.
        "perfect cadence": ["authentic cadence", "v i", "v to i", "five one", "full close"],
        "plagal cadence": ["amen cadence", "iv i", "iv to i", "four one"],
        "imperfect cadence": ["half cadence", "half close", "i v", "one five"],
        "interrupted cadence": ["deceptive cadence", "v vi", "five six", "surprise cadence"],
        // Solfège (MOVABLE do). Groups hold phonetic spellings and functional
        // names of ONE degree; they never cross a chromatic boundary. The
        // chromatic syllables (ra, me, fi, se, si, le, te) are separate
        // degrees this module exists to teach apart, so "me" is not a synonym
        // of "mi" (it is the lowered third) and "si" is not a synonym of "ti"
        // (in movable do it is the raised fifth, which this module's own
        // augmented-triad degrees spell "do, mi, si"). See the solfège policy
        // note on AuralTheory.scaleDegrees.
        "do": ["doh", "doe", "dough", "tonic"],
        "re": ["ray", "supertonic"],
        "mi": ["mee", "mediant"],
        "fa": ["fah", "subdominant"],
        "sol": ["so", "soh", "sole", "dominant"],
        "la": ["lah", "submediant"],
        "ti": ["tee", "tea", "leading tone"]
    ]

    /// The synonym resource carried on the profile. `AnswerCategory.title`
    /// (the category aural specs use) consults the historical slot; the
    /// SynonymResource category slots are a KB-shaped friction noted for the
    /// RFC process.
    static let resource = SynonymResource(historical: synonymGroups)

    // MARK: Strictness profile

    /// The named profile for aural-label evaluation. Level .strict keeps the
    /// discrimination-hostile enhanced tiers (phonetic, n-gram, token) out of
    /// the match path; minimumConfidence 0.9 rejects two-edit confusable
    /// pairs at these label lengths while still forgiving one-edit STT slips
    /// on long words like "diminished".
    static let profile = StrictnessProfile(
        id: "aural-labels-strict",
        level: .strict,
        fuzzyThresholdPercent: 0.10,
        minimumConfidence: 0.9,
        exactOnly: false,
        synonyms: resource
    )

    // MARK: Spec building

    /// All accepted labels for an item: the pack's acceptable list expanded
    /// with the synonym groups of the primary answer (and of each acceptable
    /// answer that itself names a group).
    static func expandedAcceptable(primary: String, acceptable: [String]) -> [String] {
        var accepted: [String] = []
        var seen = Set<String>()

        func add(_ label: String) {
            let key = label.lowercased().trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key != primary.lowercased(), !seen.contains(key) else { return }
            seen.insert(key)
            accepted.append(label)
        }

        for label in acceptable {
            add(label)
        }
        for label in synonyms(of: primary) {
            add(label)
        }
        for label in acceptable {
            for synonym in synonyms(of: label) {
                add(synonym)
            }
        }
        return accepted
    }

    /// The evaluation spec for one aural item.
    static func spec(for item: AuralItem) -> EvaluationSpec {
        EvaluationSpec(
            primaryAnswer: item.answer.primary,
            acceptableAnswers: expandedAcceptable(
                primary: item.answer.primary,
                acceptable: item.answer.acceptable ?? []
            ),
            category: .title,
            strictness: profile,
            evaluatorTiers: [.textExact, .textFuzzy]
        )
    }

    /// Every member of the synonym group containing `label` (empty when the
    /// label names no group).
    private static func synonyms(of label: String) -> [String] {
        let key = label.lowercased().trimmingCharacters(in: .whitespaces)
        if let group = synonymGroups[key] {
            return group.sorted()
        }
        for (groupKey, group) in synonymGroups where group.contains(key) {
            return ([groupKey] + group.subtracting([key]).sorted())
        }
        return []
    }
}
