// UnaMentis - Quiz Bowl Format Catalog
// The set of competition formats Quiz Bowl ships, each pairing a bundled
// quiz-match format descriptor with its bundled starter content pack and the
// display metadata the dashboard picker needs (name, flag, blurb).
//
// A format is DATA: adding a competition is a new descriptor JSON, a new pack,
// and one entry here. No engine code changes (MODULE_SDK_SPEC.md section 6.1).
//
// Writing style: no em dashes (see .claude/rules/writing-style.md).

import Foundation

/// One selectable Quiz Bowl competition format.
public struct QBFormat: Identifiable, Sendable, Equatable {
    /// The format descriptor resource name (also the id), e.g. "qb-naqt".
    public let id: String

    /// The bundled content pack id this format practices from.
    public let packId: String

    /// Display name for the picker, e.g. "NAQT".
    public let name: String

    /// A short, spoken-friendly subtitle, e.g. "US pyramidal, powers and negs".
    public let blurb: String

    /// An emoji flag or symbol for the picker (US, EU, UK, or a globe).
    public let flag: String

    public init(id: String, packId: String, name: String, blurb: String, flag: String) {
        self.id = id
        self.packId = packId
        self.name = name
        self.blurb = blurb
        self.flag = flag
    }
}

// MARK: - Bundled Catalog

extension QBFormat {
    /// NAQT: the reference US pyramidal format (powers, negs, 3-part bonuses).
    public static let naqt = QBFormat(
        id: "qb-naqt",
        packId: "qb-starter-naqt",
        name: "NAQT",
        blurb: "US pyramidal tossups with 15-point powers and 5-point negs.",
        flag: "🇺🇸"
    )

    /// ACF: US pyramidal with 5-point negs and no powers.
    public static let acf = QBFormat(
        id: "qb-acf",
        packId: "qb-starter-naqt",
        name: "ACF",
        blurb: "US pyramidal tossups with 5-point negs and no powers.",
        flag: "🇺🇸"
    )

    /// IHBB Europe: NAQT-like European Championship history and culture.
    public static let ihbbEurope = QBFormat(
        id: "ihbb-europe",
        packId: "ihbb-europe-starter",
        name: "IHBB Europe",
        blurb: "International History Bee and Bowl, European Championship.",
        flag: "🇪🇺"
    )

    /// UK Schools' Challenge: starters plus themed bonus sets.
    public static let ukSchoolsChallenge = QBFormat(
        id: "uk-schools-challenge",
        packId: "uk-schools-challenge-starter",
        name: "UK Schools' Challenge",
        blurb: "British starters for ten with themed bonus sets.",
        flag: "🇬🇧"
    )

    /// All bundled formats, in dashboard display order.
    public static let all: [QBFormat] = [.naqt, .acf, .ihbbEurope, .ukSchoolsChallenge]

    /// The format for a descriptor id, or nil if unknown.
    public static func format(id: String) -> QBFormat? {
        all.first { $0.id == id }
    }
}
