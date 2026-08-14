// UnaMentis - Reading Summary Store
// Sidecar persistence for precomputed reading summaries and outlines.
//
// Summaries live in a JSON file per reading item under Application Support
// rather than on the Core Data entity. They are regenerable derived data, they
// are read as a whole rather than queried, and keeping them out of the model
// avoids coupling the reader's context layer to schema migrations.
//
// Part of Core/ReadingList

import Foundation
import Logging

/// Reads and writes per-item summary records as JSON sidecar files
public actor ReadingSummaryStore {

    /// Shared instance backed by the app's Application Support directory
    public static let shared = ReadingSummaryStore()

    private let logger = Logger(label: "com.unamentis.reading.summary.store")

    /// Directory holding one JSON file per reading item
    private let directoryURL: URL

    /// In-memory cache so repeated context assembly does not hit disk
    private var cache: [UUID: ReadingDocumentSummaryRecord] = [:]

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Initialize the store
    /// - Parameter directoryURL: Override storage location (used by tests).
    ///   Defaults to Application Support/ReadingSummaries.
    public init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directoryURL = base.appendingPathComponent("ReadingSummaries", isDirectory: true)
        }
        try? FileManager.default.createDirectory(
            at: self.directoryURL,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Access

    /// Load the record for an item, or nil when none exists or it is stale.
    /// Records written by an older schema are discarded so generation reruns.
    public func load(itemId: UUID) -> ReadingDocumentSummaryRecord? {
        if let cached = cache[itemId] {
            return cached
        }

        let url = fileURL(for: itemId)
        guard let data = try? Data(contentsOf: url) else { return nil }

        do {
            let record = try decoder.decode(ReadingDocumentSummaryRecord.self, from: data)
            guard record.schemaVersion == ReadingDocumentSummaryRecord.currentSchemaVersion else {
                logger.info("Discarding summary record with schema \(record.schemaVersion) for \(itemId)")
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            cache[itemId] = record
            return record
        } catch {
            logger.warning("Failed to decode summary record for \(itemId): \(error.localizedDescription)")
            return nil
        }
    }

    /// Persist a record, replacing any existing one for the same item
    public func save(_ record: ReadingDocumentSummaryRecord) {
        cache[record.itemId] = record
        do {
            let data = try encoder.encode(record)
            try data.write(to: fileURL(for: record.itemId), options: .atomic)
        } catch {
            logger.error("Failed to write summary record for \(record.itemId): \(error.localizedDescription)")
        }
    }

    /// Remove the record for an item, for example when the item is deleted
    public func delete(itemId: UUID) {
        cache.removeValue(forKey: itemId)
        try? FileManager.default.removeItem(at: fileURL(for: itemId))
    }

    /// Drop the in-memory cache without touching disk
    public func clearCache() {
        cache.removeAll()
    }

    // MARK: - Private

    private func fileURL(for itemId: UUID) -> URL {
        directoryURL.appendingPathComponent("\(itemId.uuidString).json")
    }
}
