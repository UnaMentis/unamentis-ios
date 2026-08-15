// UnaMentis - Quiz Bowl Content Item Schema
// The module-side item type Quiz Bowl content packs carry, schema
// "qb-question/1". A self-contained Codable that conforms to the host's
// `PackItem` marker (MODULE_SDK_SPEC.md section 5.3) so DefaultContentStoreService
// decodes it without knowing Quiz Bowl's types, exactly as KBQuestion does.
//
// This schema extends the canonical question shape with the pyramidal fields the
// Quiz Bowl engine path needs: a `powerMarkIndex` (RFC 0005 item 7, the additive
// content-schema field pyramidal scoring requires) and an optional 3-part bonus.
// The item maps into the engine's module-agnostic `QuizMatchQuestion` via
// `QBQuestionMapper`.
//
// Writing style: no em dashes (see .claude/rules/writing-style.md).

import Foundation

// MARK: - Answer

/// The accepted answers for a tossup, starter, or bonus part. `primary` is the
/// canonical answer; `acceptable` lists additional accepted forms.
public struct QBAnswer: Codable, Sendable, Equatable {
    public let primary: String
    public let acceptable: [String]

    public init(primary: String, acceptable: [String] = []) {
        self.primary = primary
        self.acceptable = acceptable
    }

    // `acceptable` is optional in the pack JSON (many answers accept only the
    // primary form). Default it to empty when absent.
    private enum CodingKeys: String, CodingKey { case primary, acceptable }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.primary = try container.decode(String.self, forKey: .primary)
        self.acceptable = try container.decodeIfPresent([String].self, forKey: .acceptable) ?? []
    }
}

// MARK: - Bonus

/// A multi-part bonus attached to a tossup or starter. Mirrors the engine's
/// `QuizMatchBonus` in content form.
public struct QBBonusItem: Codable, Sendable, Equatable {
    public struct Part: Codable, Sendable, Equatable {
        public let text: String
        public let answer: QBAnswer

        public init(text: String, answer: QBAnswer) {
            self.text = text
            self.answer = answer
        }
    }

    /// Optional lead-in read before the first part. For themed bonus sets (UK
    /// Schools' Challenge) this carries the theme, e.g. "These questions are
    /// about rivers of Europe."
    public let leadIn: String?
    public let parts: [Part]

    public init(leadIn: String? = nil, parts: [Part]) {
        self.leadIn = leadIn
        self.parts = parts
    }
}

// MARK: - Item

/// One Quiz Bowl content item: a pyramidal tossup or a short starter, its answer,
/// its domain, an optional pyramidal power mark, and an optional attached bonus.
///
/// `PackItem` conformance lets the host content store decode a `[QBItem]` payload
/// generically. The domain string maps onto `StandardDomain` for proficiency
/// roll-up; the power-mark character index feeds the engine's power scoring.
public struct QBItem: Codable, Sendable, Equatable, Identifiable, PackItem {
    /// Stable item identifier (feeds AttemptRecord.itemId).
    public let id: String

    /// The full tossup or starter text the session speaks. For pyramidal
    /// tossups this is all clues concatenated, hardest first.
    public let text: String

    /// What a response to this item is judged against.
    public let answer: QBAnswer

    /// The knowledge domain this item exercises (maps to StandardDomain).
    public let domain: String

    /// Character index of the power mark for pyramidal tossups: a correct answer
    /// on a buzz before this index scores the power value (RFC 0005 item 7). Nil
    /// for short starters and unpowered tossups.
    public let powerMarkIndex: Int?

    /// The bonus awarded for a correct answer, in formats with bonuses. Nil
    /// otherwise.
    public let bonus: QBBonusItem?

    public init(
        id: String,
        text: String,
        answer: QBAnswer,
        domain: String,
        powerMarkIndex: Int? = nil,
        bonus: QBBonusItem? = nil
    ) {
        self.id = id
        self.text = text
        self.answer = answer
        self.domain = domain
        self.powerMarkIndex = powerMarkIndex
        self.bonus = bonus
    }
}
