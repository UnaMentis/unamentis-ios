// UnaMentis - Oral Syllabus Content (schema "oral-syllabus/1")
// MODULE_SDK_SPEC.md section 7: oral exam topics, seed materials, and
// exemplar question pools as a content pack.
//
// The starter pack ships bundled (manifest + items JSON resources) with the
// mandatory license/attribution and integrity hash. Loading verifies both,
// exactly as the ContentStore does for imported packs, and refuses a corrupt
// pack rather than silently loading it.
//
// Why the module loads its bundled pack itself: DefaultContentStoreService
// currently exposes only the bundled Knowledge Bowl pack; there is no host
// registration point for other modules' bundled packs yet. Per the RFC 0001
// item 2 ruling, bundled content loading before that host seam exists is not
// a capability, so this module declares "content.oral-syllabus/1" as optional
// only and reads its bundled resources directly with the same PackManifest
// verification. Flagged for the RFC process (a bundled-pack registration API
// on ContentStore). Imported packs (coach distribution) still flow through
// `host.content.importPack`, which handles this schema already.

import Foundation

// MARK: - Item Schema

/// One oral exam topic in schema `oral-syllabus/1`.
public struct OralSyllabusItem: PackItem, Identifiable, Sendable, Equatable {
    /// Stable item identifier.
    public let id: String

    /// Topic title, spoken when the session starts.
    public let title: String

    /// BCP-47 tag of the topic's language (a pack may carry several; the UI
    /// filters to what the pipeline supports today).
    public let locale: String

    /// Knowledge domain for proficiency roll-up (StandardDomain raw value).
    public let domain: String

    /// Seed material summary: what the examiner grounds questions in.
    public let summary: String

    /// Exemplar jury questions (six or more per topic in the starter pack).
    public let juryQuestions: [String]

    /// Hints about what strong answers look like, per rubric dimension.
    public let rubricHints: [String]

    public init(
        id: String,
        title: String,
        locale: String,
        domain: String,
        summary: String,
        juryQuestions: [String],
        rubricHints: [String]
    ) {
        self.id = id
        self.title = title
        self.locale = locale
        self.domain = domain
        self.summary = summary
        self.juryQuestions = juryQuestions
        self.rubricHints = rubricHints
    }

    /// The engine-facing topic value for this item.
    public var engineTopic: OralExamTopic {
        OralExamTopic(
            id: id,
            title: title,
            summary: summary,
            exemplarQuestions: juryQuestions,
            rubricHints: rubricHints,
            domain: domain
        )
    }
}

// MARK: - Bundled Pack Loading

/// Loads and verifies the bundled starter pack.
public enum OralSyllabusPack {
    public static let packId = "oral-syllabus-starter"
    static let manifestResource = "oral-syllabus-starter-manifest"
    static let itemsResource = "oral-syllabus-starter-items"

    public enum LoadError: Error, LocalizedError, Equatable {
        case resourceMissing(String)
        case manifestUnreadable(String)
        case licenseMissing
        case integrityMismatch
        case itemsUnreadable(String)

        public var errorDescription: String? {
            switch self {
            case .resourceMissing(let name):
                return "Bundled oral syllabus resource '\(name)' is missing."
            case .manifestUnreadable(let reason):
                return "Oral syllabus pack manifest could not be read: \(reason)."
            case .licenseMissing:
                return "The oral syllabus pack is missing required license information."
            case .integrityMismatch:
                return "The oral syllabus pack failed its integrity check."
            case .itemsUnreadable(let reason):
                return "Oral syllabus items could not be read: \(reason)."
            }
        }
    }

    /// Load the bundled starter pack, verifying license and integrity
    /// (section 7 rules: no license, no load; hash mismatch, no load).
    public static func loadBundled(
        bundle: Bundle = .main
    ) throws -> (manifest: PackManifest, items: [OralSyllabusItem]) {
        guard let manifestURL = bundle.url(forResource: manifestResource, withExtension: "json") else {
            throw LoadError.resourceMissing(manifestResource)
        }
        guard let itemsURL = bundle.url(forResource: itemsResource, withExtension: "json") else {
            throw LoadError.resourceMissing(itemsResource)
        }

        let manifest: PackManifest
        do {
            manifest = try JSONDecoder().decode(PackManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw LoadError.manifestUnreadable(error.localizedDescription)
        }

        guard !manifest.license.spdx.isEmpty, !manifest.license.attribution.isEmpty else {
            throw LoadError.licenseMissing
        }

        guard let itemsData = try? Data(contentsOf: itemsURL) else {
            throw LoadError.itemsUnreadable("missing items payload")
        }
        guard DefaultContentStoreService.sha256Hex(itemsData) == manifest.integrity.sha256.lowercased() else {
            throw LoadError.integrityMismatch
        }

        let items: [OralSyllabusItem]
        do {
            items = try JSONDecoder().decode([OralSyllabusItem].self, from: itemsData)
        } catch {
            throw LoadError.itemsUnreadable(error.localizedDescription)
        }
        return (manifest, items)
    }

    /// Bundled topics whose locale the current pipeline can run. STT locale
    /// plumbing is en-US only today (RFC 0002 item 6), so non-English topics
    /// stay listed but unavailable in the UI until that gap closes.
    public static func sessionReadyItems(from items: [OralSyllabusItem]) -> [OralSyllabusItem] {
        items.filter { $0.locale.lowercased().hasPrefix("en") }
    }
}
