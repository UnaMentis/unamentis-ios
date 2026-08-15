// UnaMentis - Aural Skills Content Loader
// Loads the bundled aural-items/1 starter pack THROUGH the host ContentStore
// so licensing and integrity enforcement (MODULE_SDK_SPEC.md section 7) apply
// to this module's content exactly as they do to imported packs.
//
// Mechanics: the pack ships in the app bundle as two flat resources
// (aural-starter-manifest.json, aural-starter-items.json) because the
// project's resource phase flattens directories. The loader stages them into
// a temporary pack directory with the canonical names (manifest.json,
// items.json) and imports through `host.content.importPack(from:)`, which
// hash-checks the payload before registering it. The decoded entries are then
// expanded by the deterministic generator into the concrete item list.
//
// The fallback is deliberately NARROW. An integrity or licensing failure is
// FATAL: falling back to a direct decode on a hash mismatch would load exactly
// the payload the check just rejected, which defeats the check entirely. Only
// a failure of the import SEAM itself (a host whose ContentStore cannot import,
// a staging directory that cannot be written) may fall back to decoding the
// bundled payload directly so the Tier 0 drill still works, and that fallback
// is logged and recorded in `fallbackReason`, never silent.

import Foundation
import Logging

/// Anchor for resolving the app bundle that carries the module's resources
/// (works from the app and from hosted unit tests alike).
private final class AuralSkillsBundleToken {}

/// Module-side loader and cache for the expanded starter-pack items.
actor AuralContentLoader {
    static let shared = AuralContentLoader()

    /// The bundled pack's identity (mirrors the pack manifest).
    static let packId = "aural-starter-2026"
    static let schema = "aural-items/1"

    private static let logger = Logger(label: "com.unamentis.modules.auralskills.content")

    private var cachedItems: [AuralItem]?

    /// Why the last successful load bypassed the ContentStore import path, if
    /// it did. Nil means the pack came through the VERIFIED path. Never set by
    /// an integrity or licensing failure: those throw instead.
    private(set) var fallbackReason: String?

    /// All expanded items from the starter pack. Cached after first load
    /// (expansion is deterministic, so the cache is host-independent).
    func items(host: ModuleHost) async throws -> [AuralItem] {
        if let cachedItems {
            return cachedItems
        }

        let entries: [AuralPackEntry]
        do {
            entries = try await loadThroughContentStore(host: host)
            fallbackReason = nil
        } catch let error as ContentStoreError {
            // The store REACHED the pack and rejected it: a hash mismatch, a
            // missing license, an unreadable manifest or payload. Every one of
            // those is a verdict on the content, so the pack does not load.
            Self.logger.error("Aural starter pack failed content verification: \(error)")
            throw error
        } catch {
            // The import seam itself was unavailable. Decode the bundled
            // payload directly so the offline drill still runs, and say so.
            let reason = String(describing: error)
            Self.logger.warning(
                "ContentStore pack import unavailable, decoding bundled payload directly: \(reason)"
            )
            entries = try loadDirectFromBundle()
            fallbackReason = reason
        }

        let items = try AuralItemGenerator.expand(entries)
        cachedItems = items
        Self.logger.info("Aural starter pack loaded: \(entries.count) entries, \(items.count) items")
        return items
    }

    // MARK: ContentStore path

    private func loadThroughContentStore(host: ModuleHost) async throws -> [AuralPackEntry] {
        let (manifestURL, itemsURL) = try bundledResourceURLs()

        // Stage the flat bundle resources as a canonical pack directory.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("aural-pack-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try FileManager.default.copyItem(
            at: manifestURL, to: staging.appendingPathComponent("manifest.json")
        )
        try FileManager.default.copyItem(
            at: itemsURL, to: staging.appendingPathComponent("items.json")
        )

        let handle = try await host.content.importPack(from: staging)
        return try await host.content.items(AuralPackEntry.self, from: handle, query: .all)
    }

    // MARK: Direct fallback

    private func loadDirectFromBundle() throws -> [AuralPackEntry] {
        let (_, itemsURL) = try bundledResourceURLs()
        let data = try Data(contentsOf: itemsURL)
        return try JSONDecoder().decode([AuralPackEntry].self, from: data)
    }

    // MARK: Bundle resolution

    private func bundledResourceURLs() throws -> (manifest: URL, items: URL) {
        let bundle = Bundle(for: AuralSkillsBundleToken.self)
        guard
            let manifestURL = bundle.url(forResource: "aural-starter-manifest", withExtension: "json")
                ?? Bundle.main.url(forResource: "aural-starter-manifest", withExtension: "json"),
            let itemsURL = bundle.url(forResource: "aural-starter-items", withExtension: "json")
                ?? Bundle.main.url(forResource: "aural-starter-items", withExtension: "json")
        else {
            throw AuralSkillsError.bundledPackMissing
        }
        return (manifestURL, itemsURL)
    }
}
