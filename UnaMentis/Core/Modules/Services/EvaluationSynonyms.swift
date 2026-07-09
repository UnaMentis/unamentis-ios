// UnaMentis - Evaluation Synonym Resource
// MODULE_SDK_SPEC.md section 5.2 / 5.7.
//
// Domain synonym data supplied to the fuzzy evaluator by a strictness profile.
// This is the generalization of Knowledge Bowl's KBSynonymDictionaries /
// KBSynonymMatcher: the synonym tables are no longer baked into the evaluator,
// they are profile-supplied data. The knowledge-bowl bundle below reproduces
// KB's dictionaries verbatim so the lift is behavior-preserving; other modules
// (or server-delivered profiles, section 5.7) supply their own.

import Foundation

// MARK: - Synonym Resource

/// A bundle of domain synonym dictionaries plus the matching logic over them.
/// Category-scoped: `.place` consults the places table, `.scientific` the
/// scientific table, and so on, mirroring the KB mapping.
public struct SynonymResource: Sendable, Equatable {
    /// Per-domain synonym groups. Each key maps to its set of equivalents.
    public let places: [String: Set<String>]
    public let scientific: [String: Set<String>]
    public let historical: [String: Set<String>]
    public let mathematics: [String: Set<String>]

    public init(
        places: [String: Set<String>] = [:],
        scientific: [String: Set<String>] = [:],
        historical: [String: Set<String>] = [:],
        mathematics: [String: Set<String>] = [:]
    ) {
        self.places = places
        self.scientific = scientific
        self.historical = historical
        self.mathematics = mathematics
    }

    /// Select the dictionary a category consults. `.text`/`.choice` use none.
    /// This is the KBSynonymMatcher category-to-dictionary mapping, generalized.
    private func dictionary(for category: AnswerCategory) -> [String: Set<String>]? {
        switch category {
        case .place:
            return places
        case .scientific:
            return scientific
        case .person, .title:
            return historical
        case .numeric, .date:
            return mathematics
        case .text, .choice:
            return nil
        }
    }

    /// All synonyms for `text` in `category`, including the text itself.
    func synonyms(_ text: String, for category: AnswerCategory) -> Set<String> {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dict = dictionary(for: category) else {
            return [normalized]
        }

        if let group = dict[normalized] {
            var result = group
            result.insert(normalized)
            return result
        }
        for (key, group) in dict where group.contains(normalized) {
            var result = group
            result.insert(key)
            result.insert(normalized)
            return result
        }
        return [normalized]
    }

    /// Whether two strings are synonyms in `category`.
    func areSynonyms(_ lhs: String, _ rhs: String, for category: AnswerCategory) -> Bool {
        let a = lhs.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let b = rhs.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if a == b { return true }
        return !synonyms(a, for: category).isDisjoint(with: synonyms(b, for: category))
    }
}

// MARK: - Knowledge Bowl Bundle

extension SynonymResource {
    /// The Knowledge Bowl synonym bundle, moved verbatim from the former
    /// KBSynonymDictionaries so the evaluation lift preserves KB behavior.
    static let knowledgeBowl = SynonymResource(
        places: [
            "usa": ["united states", "united states of america", "us", "america"],
            "uk": ["united kingdom", "great britain", "britain", "england"],
            "uae": ["united arab emirates"],
            "nyc": ["new york city", "new york"],
            "la": ["los angeles"],
            "sf": ["san francisco"],
            "dc": ["washington dc", "washington d.c.", "district of columbia"],
            "nz": ["new zealand"],
            "ussr": ["soviet union", "union of soviet socialist republics"],
            "prc": ["peoples republic of china", "china"],
            "drc": ["democratic republic of congo", "congo"],
            "mount": ["mt"],
            "saint": ["st"],
            "fort": ["ft"],
            "lake": ["lk"],
            "river": ["riv"],
            "mountain": ["mt", "mtn"]
        ],
        scientific: [
            "h2o": ["water", "dihydrogen monoxide"],
            "co2": ["carbon dioxide"],
            "o2": ["oxygen", "dioxygen"],
            "h2": ["hydrogen", "dihydrogen"],
            "n2": ["nitrogen", "dinitrogen"],
            "nacl": ["sodium chloride", "table salt", "salt"],
            "h2so4": ["sulfuric acid"],
            "hcl": ["hydrochloric acid"],
            "nh3": ["ammonia"],
            "ch4": ["methane"],
            "c6h12o6": ["glucose"],
            "dna": ["deoxyribonucleic acid"],
            "rna": ["ribonucleic acid"],
            "atp": ["adenosine triphosphate"],
            "co": ["carbon monoxide"],
            "no2": ["nitrogen dioxide"],
            "so2": ["sulfur dioxide"],
            "caco3": ["calcium carbonate"],
            "fe2o3": ["iron oxide", "rust"],
            "au": ["gold"],
            "ag": ["silver"],
            "fe": ["iron"],
            "cu": ["copper"],
            "pb": ["lead"],
            "hg": ["mercury"],
            "k": ["potassium"],
            "na": ["sodium"],
            "ca": ["calcium"],
            "mg": ["magnesium"]
        ],
        historical: [
            "wwi": ["world war i", "world war one", "first world war", "great war", "world war 1"],
            "wwii": ["world war ii", "world war two", "second world war", "world war 2"],
            "usa": ["united states", "united states of america", "us", "america"],
            "ussr": ["soviet union", "union of soviet socialist republics"],
            "bc": ["bce", "before common era", "before christ"],
            "ad": ["ce", "common era", "anno domini"],
            "fdr": ["franklin delano roosevelt", "franklin roosevelt", "franklin d roosevelt"],
            "jfk": ["john f kennedy", "john fitzgerald kennedy"],
            "mlk": ["martin luther king", "martin luther king jr"],
            "abe": ["abraham lincoln", "lincoln"],
            "gw": ["george washington", "washington"],
            "potus": ["president of the united states", "president"],
            "scotus": ["supreme court of the united states", "supreme court"],
            "nato": ["north atlantic treaty organization"],
            "un": ["united nations"],
            "eu": ["european union"]
        ],
        mathematics: [
            "pi": ["π", "3.14159", "3.14"],
            "e": ["eulers number", "2.71828", "2.718"],
            "phi": ["golden ratio", "φ", "1.618"],
            "sqrt": ["square root"],
            "cbrt": ["cube root"],
            "log": ["logarithm"],
            "ln": ["natural logarithm", "natural log"],
            "sin": ["sine"],
            "cos": ["cosine"],
            "tan": ["tangent"],
            "arcsin": ["inverse sine", "asin"],
            "arccos": ["inverse cosine", "acos"],
            "arctan": ["inverse tangent", "atan"]
        ]
    )
}
