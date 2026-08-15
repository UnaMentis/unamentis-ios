// UnaMentis - Quiz Bowl Content Provider
// Loads a format's bundled starter pack through the host ContentStore
// (MODULE_SDK_SPEC.md section 5.3). Quiz Bowl never reads bundle files directly:
// it asks the host for packs matching the "qb-question/1" schema, then decodes a
// typed [QBItem] the store integrity-checks and hands back.
//
// Bundled packs live in the app bundle as flat resources (<packId>-manifest.json
// + <packId>-items.json)
// but DefaultContentStoreService's Phase 3 `packs(matching:)` only enumerates the
// single KB sample pack and on-disk imported packs. Rather than edit that host
// service (a hard constraint), Quiz Bowl loads its bundled starter packs from the
// app bundle here and hands them to the store's decode path by pointing a
// ContentPackHandle at the bundled items.json. Integrity and schema still ride
// the pack manifest, and the same code decodes imported packs. The gap (bundled
// non-KB packs are not yet enumerable by the store) is filed as a spec friction.
//
// Writing style: no em dashes (see .claude/rules/writing-style.md).

import Foundation

/// Errors surfaced when a format's content cannot be loaded.
public enum QBContentError: Error, LocalizedError, Equatable {
    case packNotBundled(String)
    case itemsUnreadable(String)
    /// The pack is bundled but its manifest cannot be read or decoded.
    case manifestUnreadable(packId: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .packNotBundled(let id):
            return "Quiz Bowl content pack '\(id)' is not bundled in this build."
        case .itemsUnreadable(let reason):
            return "Quiz Bowl questions could not be read: \(reason)."
        case .manifestUnreadable(let packId, let reason):
            return "Quiz Bowl content pack '\(packId)' has an unreadable manifest: \(reason)."
        }
    }
}

/// The schema Quiz Bowl content packs declare.
public let qbQuestionSchema = "qb-question/1"

enum QBContentProvider {
    /// The locale a pack with no manifest at all reads as.
    static let defaultLocale = "en-US"

    /// Load the items for a bundled starter pack, in file order.
    ///
    /// The pack ships as flat bundle resources (`<packId>-items.json` and
    /// `<packId>-manifest.json`). We resolve its handle and decode through the
    /// host content store so integrity and schema are the store's job, not the
    /// module's.
    static func loadItems(
        packId: String,
        content: any ContentStoreService,
        bundle: Bundle = .main,
        limit: Int? = nil
    ) async throws -> [QBItem] {
        guard let handle = try await bundledHandle(packId: packId, bundle: bundle) else {
            throw QBContentError.packNotBundled(packId)
        }
        do {
            return try await content.items(QBItem.self, from: handle, query: ItemQuery(limit: limit))
        } catch {
            throw QBContentError.itemsUnreadable(error.localizedDescription)
        }
    }

    /// Resolve a bundled starter pack to a ContentPackHandle pointing at its
    /// `items.json`. Returns nil when the pack is not in the bundle at all;
    /// throws when the pack IS bundled but its manifest cannot be read.
    ///
    /// The bundle probe, the manifest read, and the JSON decode run OFF the
    /// calling actor. This is reached from a SwiftUI `.task` on the path that
    /// draws a screen's first frame, and synchronous file I/O plus a JSON
    /// decode belong nowhere near the MainActor, whatever isolation rule the
    /// build's Swift version applies to nonisolated async functions.
    static func bundledHandle(packId: String, bundle: Bundle) async throws -> ContentPackHandle? {
        try await Task.detached(priority: .userInitiated) {
            try resolveBundledHandle(packId: packId, bundle: bundle)
        }.value
    }

    /// The synchronous resolution body. Kept separate so `bundledHandle` can
    /// run it off the calling actor, and so tests can exercise it directly.
    static func resolveBundledHandle(packId: String, bundle: Bundle) throws -> ContentPackHandle? {
        // Two accepted layouts: the folder resource ("<packId>/items.json",
        // which XcodeGen preserves for folder references) and the flat
        // resource ("<packId>-items.json"), which is how the Quiz Bowl starter
        // packs actually ship today.
        let itemsURL = bundle.url(
            forResource: "items", withExtension: "json", subdirectory: packId
        ) ?? bundle.url(forResource: "\(packId)-items", withExtension: "json")

        guard let itemsURL else { return nil }

        let manifestURL = bundle.url(
            forResource: "manifest", withExtension: "json", subdirectory: packId
        ) ?? bundle.url(forResource: "\(packId)-manifest", withExtension: "json")

        // A pack shipped without any manifest reads as the default locale. A
        // manifest that IS present but unreadable or undecodable is a build
        // defect: surface it. The old `try?` chain swallowed both cases into
        // the same silent en-US fallback, which is how the en-GB packs (IHBB
        // Europe, UK Schools' Challenge) came to be handed to the store as
        // en-US with nothing reported.
        var locale = defaultLocale
        if let manifestURL {
            do {
                let data = try Data(contentsOf: manifestURL)
                locale = try JSONDecoder().decode(PackManifest.self, from: data).locale
            } catch {
                throw QBContentError.manifestUnreadable(
                    packId: packId, reason: error.localizedDescription
                )
            }
        }

        return ContentPackHandle(
            packId: packId,
            name: packId,
            schema: qbQuestionSchema,
            locale: locale,
            origin: .bundled,
            itemsURL: itemsURL
        )
    }
}
