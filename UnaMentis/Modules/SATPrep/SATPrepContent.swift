// UnaMentis - SAT Prep Content
// The module-side content model for SAT drills (schema "drill-items/1").
//
// A drill item pack is data (MODULE_SDK_SPEC.md section 7): a licensed,
// integrity-checked bundle of items the DrillEngine plays. `SATDrillItem` is the
// module's `drill-items/1` item type (it conforms to `PackItem` so the host
// ContentStore decodes it without knowing the module's types, section 5.3). This
// file also builds the host `EvaluationSpec` for each item: text-fuzzy for verbal
// items, exact-numeric for math items. The engine and the host own everything
// else; the module only describes its content and how to judge it.
//
// Content licensing: all SAT packs are original UnaMentis content, CC-BY-4.0,
// attribution UnaMentis (see each pack's manifest.json).

import Foundation

// MARK: - Pack Item (schema "drill-items/1")

/// One SAT drill item as authored in a `drill-items/1` content pack.
///
/// Verbal items carry `acceptable` synonyms and are judged with text-fuzzy
/// matching; math items carry an integer `answer` and are judged numerically.
/// The `skillTag` aligns with the SAT domain taxonomy (SAT_MODULE.md) and drives
/// both proficiency roll-up and the drill's review-order scheduling.
public struct SATDrillItem: PackItem, Equatable {
    /// Stable item id (e.g. "voc-001", "mth-001").
    public let id: String

    /// The SAT skill this item exercises (e.g. "words-in-context",
    /// "linear-equations"). Aligns with SAT_MODULE.md's skill taxonomy.
    public let skillTag: String

    /// The SAT content domain (e.g. "craft-and-structure", "algebra"). Aligns
    /// with SAT_MODULE.md's domain taxonomy; used as the proficiency domain.
    public let domain: String

    /// The prompt spoken to the learner: a one-sentence context with a target
    /// question answerable in a word or short phrase (voice-friendly).
    public let prompt: String

    /// A compact on-screen form (e.g. an equation), when the spoken read-out
    /// differs from what is best shown. Nil shows the prompt.
    public let displayText: String?

    /// The canonical correct answer.
    public let answer: String

    /// Additional accepted answers (verbal items: synonyms). Absent for math.
    public let acceptable: [String]?

    public init(
        id: String,
        skillTag: String,
        domain: String,
        prompt: String,
        displayText: String? = nil,
        answer: String,
        acceptable: [String]? = nil
    ) {
        self.id = id
        self.skillTag = skillTag
        self.domain = domain
        self.prompt = prompt
        self.displayText = displayText
        self.answer = answer
        self.acceptable = acceptable
    }

    /// Whether the item's answer is purely numeric (drives the evaluator choice).
    public var isNumeric: Bool {
        Double(answer.replacingOccurrences(of: ",", with: "")) != nil
    }
}

// MARK: - Drill Kind

/// The two SAT drill modes this module ships. Each maps to a bundled format
/// descriptor and a bundled content pack.
public enum SATDrillKind: String, CaseIterable, Sendable, Identifiable {
    case vocab
    case math

    public var id: String { rawValue }

    /// The bundled format descriptor resource name.
    public var descriptorName: String {
        switch self {
        case .vocab: return "sat-vocab-drill"
        case .math: return "sat-math-mental"
        }
    }

    /// The bundled content pack directory name.
    public var packName: String {
        switch self {
        case .vocab: return "sat-vocab-context"
        case .math: return "sat-math-mental"
        }
    }

    /// The telemetry activity kind this drill reports.
    public var activityKind: ModuleActivityKind {
        switch self {
        case .vocab: return ModuleActivityKind("vocab-drill")
        case .math: return ModuleActivityKind("math-drill")
        }
    }

    /// Learner-facing title. Localized at the source, because it reaches the UI
    /// through `Text(String)` and `navigationTitle(String)`, neither of which
    /// localizes a plain string for us.
    public var title: String {
        switch self {
        case .vocab: return String(localized: "Vocabulary in Context")
        case .math: return String(localized: "Mental Math")
        }
    }
}

// MARK: - Evaluation Spec Building

extension SATDrillItem {
    /// SAT domains whose items test a FORM choice rather than a meaning.
    ///
    /// In Standard English Conventions the correct answer and its distractor are
    /// routinely homophones ("they are" against "there" and "their") or share a
    /// lemma ("is" against "are", "has" against "have"). The enhanced fuzzy tiers
    /// score exactly those pairs as matches: Double Metaphone encodes both
    /// "there" and "they are" as 0R, and Apple's lemmatizer maps both "is" and
    /// "are" onto "be". Judging a conventions item with those tiers would mark
    /// the wrong form correct, which is the one ruling this skill cannot afford.
    static let formChoiceDomains: Set<String> = ["standard-english-conventions"]

    /// The host `EvaluationSpec` this item is judged against.
    ///
    /// - Verbal items: text-fuzzy at the standard tier, so spoken synonyms and
    ///   near-misses (Levenshtein, phonetic) count, with the item's `acceptable`
    ///   list as alternatives (MODULE_SDK_SPEC.md section 5.2, eval.text-fuzzy/1).
    /// - Conventions items (see `formChoiceDomains`): text at the strict tier.
    ///   Exact answer, the item's listed alternatives, and the tight Levenshtein
    ///   baseline that still absorbs transcription spelling noise, with the
    ///   phonetic, n-gram, token, and lemma tiers off.
    /// - Math items: numeric with a small tolerance and `exactOnly`, so an
    ///   integer answer matches exactly and the fuzzy stack cannot pass a wrong
    ///   number (eval.numeric/1).
    public func evaluationSpec() -> EvaluationSpec {
        if isNumeric {
            return EvaluationSpec(
                primaryAnswer: answer,
                acceptableAnswers: acceptable ?? [],
                category: .numeric,
                // exactOnly keeps the fuzzy stack from matching a near-miss
                // number; the small tolerance still absorbs "5" vs "5.0".
                strictness: StrictnessProfile(id: "sat-numeric", level: .strict, exactOnly: true),
                evaluatorTiers: [.numeric],
                numericTolerance: 0.5
            )
        }
        if Self.formChoiceDomains.contains(domain) {
            return EvaluationSpec(
                primaryAnswer: answer,
                acceptableAnswers: acceptable ?? [],
                category: .text,
                strictness: StrictnessProfile(id: "sat-conventions", level: .strict),
                evaluatorTiers: [.textExact, .textFuzzy]
            )
        }
        return EvaluationSpec(
            primaryAnswer: answer,
            acceptableAnswers: acceptable ?? [],
            category: .text,
            strictness: StrictnessProfile(id: "sat-verbal", level: .standard),
            evaluatorTiers: [.textExact, .textFuzzy]
        )
    }

    /// The engine's `DrillItem` view of this pack item.
    public func drillItem() -> DrillItem {
        DrillItem(
            id: id,
            prompt: prompt,
            displayText: displayText,
            evaluation: evaluationSpec(),
            skillTag: skillTag,
            domain: domain
        )
    }
}

// MARK: - Pack Loading

/// Loads bundled SAT content packs and format descriptors. Bundled packs ship in
/// the app (manifest.contentPacks.bundled), so this reads them directly from the
/// bundle, integrity-checking the item payload against the pack manifest exactly
/// as the host ContentStore does for imported packs (section 7). A pack whose
/// hash does not match its manifest is refused, never played.
public enum SATPrepPackLoader {
    /// Errors loading a bundled SAT pack.
    ///
    /// A missing resource and a present-but-malformed one are DIFFERENT
    /// failures: they point at different fixes, and the learner-facing text ends
    /// up on screen (`DrillSessionModel.phase == .failed`). The `unreadable`
    /// cases therefore carry the underlying decode failure as their
    /// `failureReason`, so nothing about why a pack refused to load is thrown
    /// away.
    public enum LoadError: Error, LocalizedError, Equatable {
        case descriptorMissing(String)
        case descriptorUnreadable(name: String, reason: String)
        case packMissing(String)
        case manifestUnreadable(name: String, reason: String)
        case itemsUnreadable(name: String, reason: String)
        case integrityMismatch(expected: String, actual: String)
        case licenseMissing(String)
        /// The pack ships more than one item with the same id. Item ids key
        /// attempt records and the scheduler's ordering map, so a colliding pack
        /// is refused rather than silently played with items dropped.
        case duplicateItemIds(name: String, ids: [String])

        public var errorDescription: String? {
            switch self {
            case .descriptorMissing(let name): return "SAT drill descriptor '\(name)' is missing."
            case .descriptorUnreadable(let name, _): return "SAT drill descriptor '\(name)' could not be read."
            case .packMissing(let name): return "SAT content pack '\(name)' is missing."
            case .manifestUnreadable(let name, _): return "SAT pack manifest '\(name)' could not be read."
            case .itemsUnreadable(let name, _): return "SAT pack items '\(name)' could not be read."
            case .integrityMismatch:
                return "An SAT content pack failed its integrity check and was not loaded."
            case .licenseMissing(let name): return "SAT content pack '\(name)' is missing license information."
            case .duplicateItemIds(let name, let ids):
                return "SAT content pack '\(name)' has duplicate item ids: \(ids.joined(separator: ", "))."
            }
        }

        /// The underlying failure, preserved for diagnosis and logging.
        public var failureReason: String? {
            switch self {
            case .descriptorUnreadable(_, let reason),
                 .manifestUnreadable(_, let reason),
                 .itemsUnreadable(_, let reason):
                return reason
            case .integrityMismatch(let expected, let actual):
                return "Expected sha256 \(expected), got \(actual)."
            default:
                return nil
            }
        }
    }

    /// Load the format descriptor for a drill kind.
    ///
    /// A descriptor that is absent from the bundle and one that is present but
    /// malformed report separately: reporting a malformed descriptor as
    /// "missing" sends whoever reads the message hunting for a file that is
    /// sitting right there.
    public static func descriptor(for kind: SATDrillKind, bundle: Bundle = .main) throws -> DrillFormatDescriptor {
        do {
            return try DrillFormatDescriptor.load(named: kind.descriptorName, in: bundle)
        } catch DrillDescriptorError.resourceNotFound {
            throw LoadError.descriptorMissing(kind.descriptorName)
        } catch {
            throw LoadError.descriptorUnreadable(
                name: kind.descriptorName, reason: String(describing: error)
            )
        }
    }

    /// The bundled manifest for a drill kind's pack.
    public static func manifest(for kind: SATDrillKind, bundle: Bundle = .main) throws -> PackManifest {
        guard let url = manifestURL(for: kind, bundle: bundle) else {
            throw LoadError.packMissing(kind.packName)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.manifestUnreadable(
                name: kind.packName, reason: String(describing: error)
            )
        }
        do {
            return try JSONDecoder().decode(PackManifest.self, from: data)
        } catch {
            throw LoadError.manifestUnreadable(
                name: kind.packName, reason: String(describing: error)
            )
        }
    }

    /// Load, integrity-check, and decode the items for a drill kind's pack.
    public static func items(for kind: SATDrillKind, bundle: Bundle = .main) throws -> [SATDrillItem] {
        let manifest = try manifest(for: kind, bundle: bundle)

        guard !manifest.license.spdx.isEmpty, !manifest.license.attribution.isEmpty else {
            throw LoadError.licenseMissing(kind.packName)
        }

        guard let itemsURL = itemsURL(for: kind, bundle: bundle) else {
            throw LoadError.packMissing(kind.packName)
        }
        let itemsData: Data
        do {
            itemsData = try Data(contentsOf: itemsURL)
        } catch {
            throw LoadError.itemsUnreadable(
                name: kind.packName, reason: String(describing: error)
            )
        }

        // Integrity: the manifest hash must match the item payload (section 7).
        let actualHash = sha256Hex(itemsData)
        guard actualHash == manifest.integrity.sha256.lowercased() else {
            throw LoadError.integrityMismatch(
                expected: manifest.integrity.sha256.lowercased(), actual: actualHash
            )
        }

        return try decodeItems(itemsData, packName: kind.packName)
    }

    /// Decode and validate an item payload.
    ///
    /// Split out from `items(for:bundle:)` so the same validation runs on every
    /// route a pack can arrive by (bundled today, imported or server-updated
    /// later) and so it is directly testable. Duplicate ids are a REFUSAL, not a
    /// silent collapse: ids key attempt records, the review scheduler's
    /// ordering map, and the session's item lookup.
    public static func decodeItems(_ data: Data, packName: String) throws -> [SATDrillItem] {
        let items: [SATDrillItem]
        do {
            items = try JSONDecoder().decode([SATDrillItem].self, from: data)
        } catch {
            throw LoadError.itemsUnreadable(name: packName, reason: String(describing: error))
        }
        let duplicates = duplicateIds(in: items)
        guard duplicates.isEmpty else {
            throw LoadError.duplicateItemIds(name: packName, ids: duplicates)
        }
        return items
    }

    /// The ids that appear more than once, in first-seen order.
    static func duplicateIds(in items: [SATDrillItem]) -> [String] {
        var seen: Set<String> = []
        var duplicates: [String] = []
        for item in items where !seen.insert(item.id).inserted {
            if !duplicates.contains(item.id) { duplicates.append(item.id) }
        }
        return duplicates
    }

    // MARK: - Resource URLs

    /// Bundled packs live under Resources/ContentPacks/<packName>/ but Xcode
    /// flattens resource file names, so items and manifest are looked up by their
    /// bundle names. A pack directory therefore ships its files with pack-scoped
    /// names to stay unique in the flat bundle (see project.yml resource entries).
    static func manifestURL(for kind: SATDrillKind, bundle: Bundle) -> URL? {
        bundle.url(forResource: "\(kind.packName)-manifest", withExtension: "json")
    }

    static func itemsURL(for kind: SATDrillKind, bundle: Bundle) -> URL? {
        bundle.url(forResource: "\(kind.packName)-items", withExtension: "json")
    }

    /// Lowercase hex SHA-256, matching the host ContentStore's integrity check.
    static func sha256Hex(_ data: Data) -> String {
        DefaultContentStoreService.sha256Hex(data)
    }
}

// MARK: - Session Scheduling

/// Item ordering for one SAT drill session: the module's side of the drill
/// engine's scheduling contract (`DrillScheduling`, engine "drill/1"), shared by
/// the live drill and the headless conformance run so both order items the same
/// way.
///
/// THE KEY SPACE MATTERS. The engine records mastery under
/// `DrillItem.effectiveDomain` (`domain ?? skillTag`, see
/// `DrillEngine.recordAttempt`), and every SAT item carries a domain, so SAT
/// mastery lives under "algebra", "craft-and-structure", and their siblings,
/// never under a skill tag like "linear-equations". Reading mastery by skill tag
/// therefore reads an empty key space: every lookup returns 0, every comparison
/// ties, and the review sort silently degrades to pack order. This helper reads
/// the key the engine WRITES and projects it onto the skill tag
/// `DrillScheduling.order` asks about.
public enum SATDrillScheduling {

    /// Order `items` under the descriptor's policy.
    ///
    /// `.free` keeps pack order. `.review` sorts by ascending stored mastery, so
    /// the weakest domains lead; ties keep pack order. A domain with no
    /// observations reads 0 and therefore leads, which is the intended
    /// "unpracticed material first" behavior.
    ///
    /// Never traps on malformed content: duplicate item ids resolve
    /// deterministically to the first item carrying the id. `SATPrepPackLoader`
    /// refuses such a pack outright, and this is the second line of defense for
    /// items that arrive by any other route.
    public static func ordered(
        _ items: [SATDrillItem],
        policy: DrillFormatDescriptor.SchedulingPolicy,
        progress: any ProgressStoreService
    ) async -> [SATDrillItem] {
        let drillItems = items.map { $0.drillItem() }
        var masteryByTag: [String: Double] = [:]
        if policy == .review {
            masteryByTag = await masteryBySkillTag(drillItems, progress: progress)
        }
        let ordered = DrillScheduling.order(
            drillItems,
            policy: policy,
            masteryForTag: { masteryByTag[$0] ?? 0 }
        )
        // First occurrence wins. `Dictionary(uniqueKeysWithValues:)` would TRAP
        // here on a duplicate id (it has a uniqueness precondition), taking the
        // whole app down for a content defect.
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ordered.compactMap { byId[$0.id] }
    }

    /// Current mastery per skill tag, read from the domain key space the engine
    /// writes: one proficiency read per distinct domain, then projected onto the
    /// tags of the items in that domain. A tag spanning several domains takes
    /// the lowest of them, which keeps the weakest-first intent.
    static func masteryBySkillTag(
        _ items: [DrillItem],
        progress: any ProgressStoreService
    ) async -> [String: Double] {
        var masteryByDomain: [String: Double] = [:]
        for domain in Set(items.map(\.effectiveDomain)) {
            masteryByDomain[domain] = await progress.proficiency(for: StandardDomain(domain)).mastery
        }
        var masteryByTag: [String: Double] = [:]
        for item in items {
            let mastery = masteryByDomain[item.effectiveDomain] ?? 0
            masteryByTag[item.skillTag] = min(masteryByTag[item.skillTag] ?? mastery, mastery)
        }
        return masteryByTag
    }
}
