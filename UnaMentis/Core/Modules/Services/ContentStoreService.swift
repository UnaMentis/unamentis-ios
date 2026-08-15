// UnaMentis - Content Store Host Service
// MODULE_SDK_SPEC.md section 5.3, capability "content.canonical-question/1"
//
// The host-owned content layer. Modules never read raw bundle files or manage
// their own download caches: they query for packs, pull typed items out of a
// pack, import packs from a URL (coach/AirDrop distribution), and download packs
// from the server. Pack integrity (sha256) and schema compatibility are the
// store's job (section 5.3): a corrupt or mismatched pack is refused with a
// user-visible error, never loaded silently.
//
// Phase 3 scope is what Knowledge Bowl exercises: the bundled
// kb-sample-questions.json is exposed as pack id "kb-sample-questions";
// importPack parses and integrity-checks a PackManifest (section 7); download
// wires to the existing ModuleService/ModuleRegistry server path. The canonical
// question transformer layer (section 5.3) is a later phase.
//
// Integrity is checked at IMPORT and again at every LOAD (files on disk change
// after import), and the declared schema's major version is checked against
// what this build understands, so the header's promise ("a corrupt or
// mismatched pack is refused with a user-visible error, never loaded silently")
// holds on both paths.

import CryptoKit
import Foundation
import Logging

// MARK: - Pack Manifest (MODULE_SDK_SPEC.md section 7)

/// The manifest that accompanies a content pack. A minimal Codable matching
/// MODULE_SDK_SPEC.md section 7. Licensing and integrity are mandatory: a pack
/// without a clear license or a matching hash does not load.
public struct PackManifest: Codable, Sendable, Equatable {
    public struct License: Codable, Sendable, Equatable {
        /// SPDX identifier (e.g. "CC-BY-4.0"). Mandatory.
        public let spdx: String
        /// Human-readable attribution. Mandatory.
        public let attribution: String

        public init(spdx: String, attribution: String) {
            self.spdx = spdx
            self.attribution = attribution
        }
    }

    public struct Integrity: Codable, Sendable, Equatable {
        /// Lowercase hex SHA-256 of the pack's item payload.
        public let sha256: String

        public init(sha256: String) {
            self.sha256 = sha256
        }
    }

    public let packId: String
    public let name: String
    public let version: String
    /// Item schema version (e.g. "canonical-question/1").
    public let schema: String
    public let locale: String
    public let license: License
    public let integrity: Integrity
    public let itemCount: Int

    public init(
        packId: String,
        name: String,
        version: String,
        schema: String,
        locale: String,
        license: License,
        integrity: Integrity,
        itemCount: Int
    ) {
        self.packId = packId
        self.name = name
        self.version = version
        self.schema = schema
        self.locale = locale
        self.license = license
        self.integrity = integrity
        self.itemCount = itemCount
    }
}

// MARK: - Pack Handle and Queries

/// A resolved, loadable content pack (bundled, imported, or downloaded).
public struct ContentPackHandle: Sendable, Equatable, Identifiable {
    public enum Origin: String, Sendable {
        case bundled
        case imported
        case downloaded
    }

    public let packId: String
    public let name: String
    public let schema: String
    public let locale: String
    public let origin: Origin
    /// The file backing the pack's items, if the pack is disk-backed.
    public let itemsURL: URL?

    public var id: String { packId }

    public init(
        packId: String,
        name: String,
        schema: String,
        locale: String,
        origin: Origin,
        itemsURL: URL?
    ) {
        self.packId = packId
        self.name = name
        self.schema = schema
        self.locale = locale
        self.origin = origin
        self.itemsURL = itemsURL
    }
}

/// A query over available packs.
public struct PackQuery: Sendable {
    /// Restrict to a specific schema (e.g. "canonical-question/1"). Nil = any.
    public var schema: String?
    /// Restrict to a specific locale. Nil = any.
    public var locale: String?

    public init(schema: String? = nil, locale: String? = nil) {
        self.schema = schema
        self.locale = locale
    }

    public static let all = PackQuery()
}

/// A query over the items in a pack. Phase 3 supports a simple count cap; richer
/// filtering (domain, difficulty) stays in the module engine for now.
public struct ItemQuery: Sendable {
    public var limit: Int?

    public init(limit: Int? = nil) {
        self.limit = limit
    }

    public static let all = ItemQuery()
}

/// Marker for a decodable pack item. Modules conform their own item types
/// (Knowledge Bowl conforms KBQuestion) so the store stays module-agnostic.
public protocol PackItem: Codable, Sendable {}

// MARK: - Errors

public enum ContentStoreError: Error, LocalizedError, Equatable {
    case packNotFound(String)
    case manifestUnreadable(String)
    /// Integrity check failed: the item payload hash does not match the manifest.
    case integrityMismatch(expected: String, actual: String)
    /// The pack's license block is missing required fields.
    case licenseMissing
    case itemsUnreadable(String)
    case downloadUnavailable(String)
    /// The pack declares a schema this build cannot load (malformed, or a major
    /// version newer than the host understands).
    case schemaUnsupported(String)

    public var errorDescription: String? {
        switch self {
        case .packNotFound(let id):
            return "Content pack not found: \(id)."
        case .manifestUnreadable(let reason):
            return "Pack manifest could not be read: \(reason)."
        case .integrityMismatch:
            return "This content pack failed its integrity check and was not loaded."
        case .licenseMissing:
            return "This content pack is missing required license information."
        case .itemsUnreadable(let reason):
            return "Pack items could not be read: \(reason)."
        case .downloadUnavailable(let reason):
            return "Pack download is unavailable: \(reason)."
        case .schemaUnsupported(let schema):
            return "This content pack needs a newer version of the app (schema \(schema))."
        }
    }
}

// MARK: - Service Protocol

/// The host content store (MODULE_SDK_SPEC.md section 5.3).
public protocol ContentStoreService: Sendable {
    /// Packs available to modules: bundled, imported, and downloaded.
    func packs(matching query: PackQuery) async -> [ContentPackHandle]

    /// Download a pack from the server (Tier 1).
    func download(_ packId: String) async throws -> ContentPackHandle

    /// Import a pack from a URL (Files/AirDrop, coach distribution). The URL is
    /// a directory or archive folder containing `manifest.json` and `items.json`.
    /// The item payload is integrity-checked against the manifest hash before
    /// the pack is registered.
    func importPack(from url: URL) async throws -> ContentPackHandle

    /// Decode typed items from a pack.
    func items<T: PackItem>(_ type: T.Type, from handle: ContentPackHandle, query: ItemQuery) async throws -> [T]
}

// MARK: - Production Implementation

/// Content store backed by the app bundle (for the bundled KB pack), an
/// on-disk import directory, and the existing ModuleService download path.
public actor DefaultContentStoreService: ContentStoreService {
    private let logger = Logger(label: "com.unamentis.modules.contentstore")
    private let bundle: Bundle
    private let importsRoot: URL
    private let fileManager = FileManager.default

    /// Packs imported this run (kept in memory; on-disk manifests are the
    /// durable record under `importsRoot`).
    private var importedPacks: [String: ContentPackHandle] = [:]

    /// The bundled Knowledge Bowl pack, exposed under a stable pack id.
    private static let kbSamplePackId = "kb-sample-questions"

    public init(bundle: Bundle = .main, importsRoot: URL? = nil) {
        self.bundle = bundle
        if let importsRoot {
            self.importsRoot = importsRoot
        } else {
            let documents = (try? FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.importsRoot = documents.appendingPathComponent("ContentPacks", isDirectory: true)
        }
    }

    // MARK: Packs

    public func packs(matching query: PackQuery) async -> [ContentPackHandle] {
        var results: [ContentPackHandle] = []

        // Bundled KB pack.
        if let url = bundle.url(forResource: "kb-sample-questions", withExtension: "json") {
            results.append(ContentPackHandle(
                packId: Self.kbSamplePackId,
                name: "Knowledge Bowl Sample Questions",
                schema: "canonical-question/1",
                locale: "en-US",
                origin: .bundled,
                itemsURL: url
            ))
        }

        // Imported packs discovered on disk plus any registered this run.
        results.append(contentsOf: loadImportedHandles())

        return results.filter { handle in
            (query.schema == nil || handle.schema == query.schema)
                && (query.locale == nil || handle.locale == query.locale)
        }
    }

    private func loadImportedHandles() -> [ContentPackHandle] {
        var handles = Array(importedPacks.values)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: importsRoot, includingPropertiesForKeys: nil
        ) else { return handles }
        for dir in entries where dir.hasDirectoryPath {
            let manifestURL = dir.appendingPathComponent("manifest.json")
            let itemsURL = dir.appendingPathComponent("items.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(PackManifest.self, from: data),
                  importedPacks[manifest.packId] == nil else { continue }
            // A pack whose schema this build cannot load is not offered at all,
            // rather than handed out and failing later inside a module.
            guard Self.isSchemaSupported(manifest.schema) else {
                logger.warning("Skipping pack \(manifest.packId): unsupported schema \(manifest.schema)")
                continue
            }
            handles.append(ContentPackHandle(
                packId: manifest.packId,
                name: manifest.name,
                schema: manifest.schema,
                locale: manifest.locale,
                origin: .imported,
                itemsURL: itemsURL
            ))
        }
        return handles
    }

    // MARK: Download

    public func download(_ packId: String) async throws -> ContentPackHandle {
        // Wire to the existing server path. ModuleService downloads and registers
        // the content in ModuleRegistry; the returned handle points modules at
        // the same identifier. Full pack-file materialization lands with the
        // server pack format; Phase 3 reuses the module download endpoint.
        do {
            let downloaded = try await ModuleService.shared.downloadModule(moduleId: packId)
            return ContentPackHandle(
                packId: downloaded.id,
                name: downloaded.name,
                schema: "canonical-question/1",
                locale: "en-US",
                origin: .downloaded,
                itemsURL: nil
            )
        } catch {
            throw ContentStoreError.downloadUnavailable(error.localizedDescription)
        }
    }

    // MARK: Import

    public func importPack(from url: URL) async throws -> ContentPackHandle {
        let manifestURL = url.appendingPathComponent("manifest.json")
        let itemsURL = url.appendingPathComponent("items.json")

        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            throw ContentStoreError.manifestUnreadable("missing manifest.json")
        }
        let manifest: PackManifest
        do {
            manifest = try JSONDecoder().decode(PackManifest.self, from: manifestData)
        } catch {
            throw ContentStoreError.manifestUnreadable(error.localizedDescription)
        }

        // Licensing is mandatory (section 7).
        guard !manifest.license.spdx.isEmpty, !manifest.license.attribution.isEmpty else {
            throw ContentStoreError.licenseMissing
        }

        // Schema compatibility is the store's job (section 5.3), so it is
        // actually checked here rather than merely claimed in the header.
        guard Self.isSchemaSupported(manifest.schema) else {
            throw ContentStoreError.schemaUnsupported(manifest.schema)
        }

        guard let itemsData = try? Data(contentsOf: itemsURL) else {
            throw ContentStoreError.itemsUnreadable("missing items.json")
        }

        // Integrity check: the manifest hash must match the item payload.
        let actualHash = Self.sha256Hex(itemsData)
        guard actualHash == manifest.integrity.sha256.lowercased() else {
            throw ContentStoreError.integrityMismatch(
                expected: manifest.integrity.sha256.lowercased(), actual: actualHash
            )
        }

        // Persist a copy under the imports root so the pack survives relaunch.
        let destination = importsRoot.appendingPathComponent(sanitized(manifest.packId), isDirectory: true)
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try? manifestData.write(to: destination.appendingPathComponent("manifest.json"), options: [.atomic])
        try? itemsData.write(to: destination.appendingPathComponent("items.json"), options: [.atomic])

        let handle = ContentPackHandle(
            packId: manifest.packId,
            name: manifest.name,
            schema: manifest.schema,
            locale: manifest.locale,
            origin: .imported,
            itemsURL: destination.appendingPathComponent("items.json")
        )
        importedPacks[manifest.packId] = handle
        logger.info("Imported pack \(manifest.packId) (\(manifest.itemCount) items)")
        return handle
    }

    // MARK: Items

    public func items<T: PackItem>(_ type: T.Type, from handle: ContentPackHandle, query: ItemQuery) async throws -> [T] {
        // A limit of zero or less asks for nothing. Passing it through reached
        // Array.prefix(-1), which traps.
        if let limit = query.limit, limit <= 0 {
            return []
        }

        guard Self.isSchemaSupported(handle.schema) else {
            throw ContentStoreError.schemaUnsupported(handle.schema)
        }
        guard let url = handle.itemsURL, let data = try? Data(contentsOf: url) else {
            throw ContentStoreError.itemsUnreadable(handle.packId)
        }

        // Re-verify integrity at LOAD time, not only at import. Files on disk
        // change after import (sync, partial write, tampering), and the store
        // promises a corrupt pack is never loaded silently.
        try verifyIntegrityIfManifestPresent(for: url, data: data)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // The bundled KB pack wraps items in a { version, questions: [...] }
        // envelope. Try that envelope first, then fall back to a bare array so
        // imported packs can ship items.json as a plain [T].
        let items: [T]
        if let envelope = try? decoder.decode(PackItemsEnvelope<T>.self, from: data) {
            items = envelope.questions
        } else {
            do {
                items = try decoder.decode([T].self, from: data)
            } catch {
                throw ContentStoreError.itemsUnreadable(error.localizedDescription)
            }
        }

        if let limit = query.limit, items.count > limit {
            return Array(items.prefix(limit))
        }
        return items
    }

    // MARK: Integrity and Schema

    /// The item-schema major version this build can load.
    static let supportedSchemaMajor = 1

    /// Whether the host can load a pack declaring `schema`.
    ///
    /// Schemas are `"<name>/<major>"` (for example "canonical-question/1"). A
    /// malformed schema, or a major version newer than this build, is refused:
    /// loading unknown-shaped items would fail deep inside a module instead of
    /// as a clear, user-visible store error.
    static func isSchemaSupported(_ schema: String) -> Bool {
        let parts = schema.split(separator: "/")
        guard parts.count == 2, !parts[0].isEmpty,
              let major = Int(parts[1]), major > 0 else { return false }
        return major <= supportedSchemaMajor
    }

    /// Re-verify a pack payload against its manifest hash when a manifest sits
    /// beside the items file. Packs ship either as `<dir>/manifest.json` +
    /// `<dir>/items.json` (imported and bundled folder packs) or as flat
    /// `<name>-manifest.json` + `<name>-items.json` resources; both are checked.
    /// A pack with no manifest beside it (the bundled KB sample) is loaded as
    /// before.
    private func verifyIntegrityIfManifestPresent(for itemsURL: URL, data: Data) throws {
        guard let manifestURL = Self.manifestURL(besides: itemsURL, fileManager: fileManager),
              let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PackManifest.self, from: manifestData) else {
            return
        }
        guard Self.isSchemaSupported(manifest.schema) else {
            throw ContentStoreError.schemaUnsupported(manifest.schema)
        }
        let expected = manifest.integrity.sha256.lowercased()
        guard !expected.isEmpty else { return }
        let actual = Self.sha256Hex(data)
        guard actual == expected else {
            logger.error("Pack \(manifest.packId) failed its load-time integrity check")
            throw ContentStoreError.integrityMismatch(expected: expected, actual: actual)
        }
    }

    /// The manifest that belongs to an items file, in either pack layout.
    static func manifestURL(besides itemsURL: URL, fileManager: FileManager) -> URL? {
        let directory = itemsURL.deletingLastPathComponent()
        let sibling = directory.appendingPathComponent("manifest.json")
        if fileManager.fileExists(atPath: sibling.path) {
            return sibling
        }
        let name = itemsURL.deletingPathExtension().lastPathComponent
        guard name.hasSuffix("-items") else { return nil }
        let flat = directory
            .appendingPathComponent(name.replacingOccurrences(of: "-items", with: "-manifest"))
            .appendingPathExtension("json")
        return fileManager.fileExists(atPath: flat.path) ? flat : nil
    }

    // MARK: Helpers

    private func sanitized(_ component: String) -> String {
        ModuleStorePath.safeComponent(component)
    }

    /// Lowercase hex SHA-256 of the given data.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Envelope matching the bundled KB questions file
/// (`{ "version": ..., "questions": [...] }`).
private struct PackItemsEnvelope<T: Codable & Sendable>: Codable, Sendable {
    let questions: [T]
}
