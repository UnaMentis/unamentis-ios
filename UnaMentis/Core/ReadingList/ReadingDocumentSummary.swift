// UnaMentis - Reading Document Summary Model
// Precomputed section summaries and a whole-document outline for a reading item.
//
// These are the coarse resolution layers of the reader's foveated context. Raw
// chunk text is only used near the current position. Everything further away is
// represented by a one to two sentence micro-summary, and the whole document is
// represented by a short outline that is always present.
//
// Part of Core/ReadingList

import Foundation

// MARK: - Section Marker

/// A structural marker captured at import time, for example a markdown heading
/// or a PDF outline entry, mapped to the chunk where that section starts.
public struct DocumentSectionMarker: Codable, Sendable, Equatable {
    /// Human readable section title
    public let title: String

    /// Nesting level (1 = top level heading)
    public let level: Int

    /// Index of the first chunk belonging to this section
    public let chunkIndex: Int32

    public init(title: String, level: Int, chunkIndex: Int32) {
        self.title = title
        self.level = level
        self.chunkIndex = chunkIndex
    }
}

// MARK: - Section Range

/// A contiguous run of chunks treated as one section for summarization
public struct ReadingSectionRange: Sendable, Equatable {
    /// First chunk index in the section
    public let startChunkIndex: Int32

    /// Last chunk index in the section (inclusive)
    public let endChunkIndex: Int32

    /// Section title when real structure was captured at import, nil otherwise
    public let title: String?

    public init(startChunkIndex: Int32, endChunkIndex: Int32, title: String? = nil) {
        self.startChunkIndex = startChunkIndex
        self.endChunkIndex = endChunkIndex
        self.title = title
    }

    /// Number of chunks covered by this range
    public var chunkCount: Int {
        Int(endChunkIndex - startChunkIndex) + 1
    }
}

// MARK: - Section Summary

/// A generated micro-summary for one section of a document
public struct ReadingSectionSummary: Codable, Sendable, Equatable {
    /// Position of this section in reading order (0-based)
    public let index: Int

    /// First chunk index covered by the summary
    public let startChunkIndex: Int32

    /// Last chunk index covered by the summary (inclusive)
    public let endChunkIndex: Int32

    /// Section title when real structure was captured at import
    public let title: String?

    /// One to two sentence summary of the section
    public let summary: String

    public init(
        index: Int,
        startChunkIndex: Int32,
        endChunkIndex: Int32,
        title: String?,
        summary: String
    ) {
        self.index = index
        self.startChunkIndex = startChunkIndex
        self.endChunkIndex = endChunkIndex
        self.title = title
        self.summary = summary
    }

    /// Distance in chunks between this section and a reading position.
    /// Zero when the position falls inside the section.
    public func distance(from chunkIndex: Int32) -> Int {
        if chunkIndex < startChunkIndex {
            return Int(startChunkIndex - chunkIndex)
        }
        if chunkIndex > endChunkIndex {
            return Int(chunkIndex - endChunkIndex)
        }
        return 0
    }

    /// Human readable segment range, 1-based to match the reader's progress display
    public var segmentRangeDescription: String {
        "segments \(startChunkIndex + 1)-\(endChunkIndex + 1)"
    }
}

// MARK: - Outline

/// One line of the whole-document outline
public struct ReadingOutlineEntry: Codable, Sendable, Equatable {
    /// Index of the section this line describes
    public let sectionIndex: Int

    /// Section title when known
    public let title: String?

    /// Single short clause describing the section
    public let line: String

    public init(sectionIndex: Int, title: String?, line: String) {
        self.sectionIndex = sectionIndex
        self.title = title
        self.line = line
    }
}

/// Coarse map of the entire document, built in one pass from the section summaries
public struct ReadingDocumentOutline: Codable, Sendable, Equatable {
    /// One sentence describing the document as a whole
    public let overview: String

    /// One line per section, in reading order
    public let entries: [ReadingOutlineEntry]

    public init(overview: String, entries: [ReadingOutlineEntry]) {
        self.overview = overview
        self.entries = entries
    }
}

// MARK: - Status

/// Lifecycle of summary pre-generation for a reading item
public enum ReadingSummaryStatus: String, Codable, Sendable {
    /// Not generated yet, or deferred because no LLM was available
    case pending
    /// Generation is running right now
    case inProgress = "in_progress"
    /// Summaries and outline are available
    case completed
    /// Generation ran and produced nothing usable
    case failed
}

// MARK: - Record

/// Everything the reader's foveated context needs about one document,
/// persisted as a sidecar file keyed by the reading item's id.
public struct ReadingDocumentSummaryRecord: Codable, Sendable, Equatable {

    /// Bump when the on-disk shape changes so stale records are discarded
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let itemId: UUID

    /// Current generation status
    public var status: ReadingSummaryStatus

    /// Chunk count the summaries were generated against. A mismatch means the
    /// document was re-imported or re-chunked and the record is stale.
    public var totalChunks: Int

    /// Per-section micro-summaries in reading order
    public var sections: [ReadingSectionSummary]

    /// Whole-document outline, nil until the outline pass has run
    public var outline: ReadingDocumentOutline?

    /// When the summaries were last completed
    public var generatedAt: Date?

    /// When generation was last attempted, successful or not
    public var lastAttemptAt: Date?

    public init(
        schemaVersion: Int = ReadingDocumentSummaryRecord.currentSchemaVersion,
        itemId: UUID,
        status: ReadingSummaryStatus = .pending,
        totalChunks: Int = 0,
        sections: [ReadingSectionSummary] = [],
        outline: ReadingDocumentOutline? = nil,
        generatedAt: Date? = nil,
        lastAttemptAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.itemId = itemId
        self.status = status
        self.totalChunks = totalChunks
        self.sections = sections
        self.outline = outline
        self.generatedAt = generatedAt
        self.lastAttemptAt = lastAttemptAt
    }

    /// Whether this record has usable content for context assembly
    public var hasContent: Bool {
        !sections.isEmpty || outline != nil
    }

    /// Whether generation should be attempted (or retried) for a document
    /// with the given chunk count.
    ///
    /// A persisted `.inProgress` status means a previous run was interrupted,
    /// for example the app was killed mid-generation, so it counts as needing
    /// work. Duplicate concurrent runs are prevented in the pre-generator by its
    /// live task table, not by this flag.
    public func needsGeneration(forChunkCount chunkCount: Int) -> Bool {
        if totalChunks != chunkCount { return true }
        switch status {
        case .completed:
            return !hasContent
        case .pending, .failed, .inProgress:
            return true
        }
    }

    /// Sections that end before a given chunk index, nearest last
    public func sections(before chunkIndex: Int32) -> [ReadingSectionSummary] {
        sections.filter { $0.endChunkIndex < chunkIndex }
    }

    /// Sections that start after a given chunk index, nearest first
    public func sections(after chunkIndex: Int32) -> [ReadingSectionSummary] {
        sections.filter { $0.startChunkIndex > chunkIndex }
    }
}

// MARK: - Section Grouper

/// Groups a document's chunks into sections for summarization.
///
/// Uses real structure (markdown headings, PDF outline) when it was captured at
/// import, and falls back to fixed-size groups otherwise. Either way the result
/// is clamped so sections stay in a range that summarizes well.
public enum ReadingSectionGrouper {

    /// Preferred number of chunks per section
    public static let targetChunksPerSection = 12

    /// Sections smaller than this are merged into the previous section
    public static let minChunksPerSection = 8

    /// Sections larger than this are split into even pieces
    public static let maxChunksPerSection = 15

    /// Build section ranges covering every chunk exactly once.
    /// - Parameters:
    ///   - totalChunks: Number of chunks in the document
    ///   - markers: Structural markers captured at import (may be empty)
    ///   - target: Preferred chunks per section
    /// - Returns: Contiguous, non-overlapping ranges in reading order
    public static func makeSections(
        totalChunks: Int,
        markers: [DocumentSectionMarker] = [],
        target: Int = targetChunksPerSection
    ) -> [ReadingSectionRange] {
        guard totalChunks > 0 else { return [] }

        let step = max(1, target)
        let starts = markerStarts(markers, totalChunks: totalChunks, step: step)
        let raw = ranges(fromStarts: starts, totalChunks: totalChunks)
        let splitRanges = raw.flatMap { splitOversized($0, target: step) }
        return merge(splitRanges)
    }

    // MARK: - Private

    /// Section start indices, from markers when available, otherwise evenly spaced
    private static func markerStarts(
        _ markers: [DocumentSectionMarker],
        totalChunks: Int,
        step: Int
    ) -> [(index: Int32, title: String?)] {
        let usable = markers
            .filter { $0.chunkIndex >= 0 && Int($0.chunkIndex) < totalChunks }
            .sorted { $0.chunkIndex < $1.chunkIndex }

        guard !usable.isEmpty else {
            return stride(from: 0, to: totalChunks, by: step).map {
                (index: Int32($0), title: nil)
            }
        }

        var starts: [(index: Int32, title: String?)] = []
        // A document that does not open with a heading still needs a first section.
        if usable[0].chunkIndex > 0 {
            starts.append((index: 0, title: nil))
        }
        for marker in usable where starts.last?.index != marker.chunkIndex {
            starts.append((index: marker.chunkIndex, title: marker.title))
        }
        return starts
    }

    /// Turn start indices into inclusive ranges covering the whole document
    private static func ranges(
        fromStarts starts: [(index: Int32, title: String?)],
        totalChunks: Int
    ) -> [ReadingSectionRange] {
        starts.enumerated().map { position, start in
            let nextStart = position + 1 < starts.count
                ? starts[position + 1].index
                : Int32(totalChunks)
            return ReadingSectionRange(
                startChunkIndex: start.index,
                endChunkIndex: nextStart - 1,
                title: start.title
            )
        }
    }

    /// Split an oversized range into roughly even pieces
    private static func splitOversized(
        _ range: ReadingSectionRange,
        target: Int
    ) -> [ReadingSectionRange] {
        guard range.chunkCount > maxChunksPerSection else { return [range] }

        let pieceCount = max(2, Int((Double(range.chunkCount) / Double(target)).rounded(.up)))
        let baseSize = range.chunkCount / pieceCount
        let remainder = range.chunkCount % pieceCount

        var pieces: [ReadingSectionRange] = []
        var cursor = range.startChunkIndex
        for piece in 0..<pieceCount {
            let size = baseSize + (piece < remainder ? 1 : 0)
            guard size > 0 else { continue }
            let end = cursor + Int32(size) - 1
            pieces.append(ReadingSectionRange(
                startChunkIndex: cursor,
                endChunkIndex: end,
                // Only the first piece carries the heading, the rest are continuations.
                title: piece == 0 ? range.title : nil
            ))
            cursor = end + 1
        }
        return pieces
    }

    /// Fold undersized ranges into the preceding one so no section is too small
    /// to be worth its own summary.
    private static func merge(_ ranges: [ReadingSectionRange]) -> [ReadingSectionRange] {
        var merged: [ReadingSectionRange] = []
        for range in ranges {
            if range.chunkCount < minChunksPerSection, let previous = merged.popLast() {
                merged.append(ReadingSectionRange(
                    startChunkIndex: previous.startChunkIndex,
                    endChunkIndex: range.endChunkIndex,
                    title: previous.title
                ))
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
