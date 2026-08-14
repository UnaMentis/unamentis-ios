// UnaMentis - Reading FOV Context Manager
// Builds foveated context windows around the current reading position
// for barge-in Q&A during document playback
//
// Resolution falls off with distance from the reading position:
//   - a compact header plus the global outline, always present once generated
//   - micro-summaries for the material before the near window ("Earlier")
//   - raw chunk text for the near window (a few chunks either side)
//   - micro-summaries for the material after the near window ("Upcoming")
//
// Part of Core/Context

import Foundation
import Logging

// MARK: - Reading Context Window

/// Foveated context window around the current reading position
public struct ReadingContextWindow: Sendable {
    /// The system prompt for reading Q&A
    public let systemPrompt: String

    /// Rendered global outline of the whole document (empty when not generated yet)
    public let outlineText: String

    /// Micro-summaries for sections before the near window (empty when none)
    public let earlierSummaryText: String

    /// Text from chunks before the current position
    public let precedingText: String

    /// Text of the current chunk being read
    public let currentText: String

    /// Text from chunks after the current position
    public let followingText: String

    /// Micro-summaries for sections after the near window (empty when none)
    public let upcomingSummaryText: String

    /// Document metadata
    public let documentTitle: String
    public let documentAuthor: String?

    /// Current position info
    public let currentChunkIndex: Int32
    public let totalChunks: Int

    public init(
        systemPrompt: String,
        outlineText: String = "",
        earlierSummaryText: String = "",
        precedingText: String,
        currentText: String,
        followingText: String,
        upcomingSummaryText: String = "",
        documentTitle: String,
        documentAuthor: String?,
        currentChunkIndex: Int32,
        totalChunks: Int
    ) {
        self.systemPrompt = systemPrompt
        self.outlineText = outlineText
        self.earlierSummaryText = earlierSummaryText
        self.precedingText = precedingText
        self.currentText = currentText
        self.followingText = followingText
        self.upcomingSummaryText = upcomingSummaryText
        self.documentTitle = documentTitle
        self.documentAuthor = documentAuthor
        self.currentChunkIndex = currentChunkIndex
        self.totalChunks = totalChunks
    }

    /// Combined context for LLM, coarse to fine and back out again
    public var fullContext: String {
        var parts: [String] = []

        parts.append(systemPrompt)
        parts.append("")
        parts.append("## Document: \(documentTitle)")

        if let author = documentAuthor, !author.isEmpty {
            parts.append("Author: \(author)")
        }

        parts.append("Progress: Segment \(currentChunkIndex + 1) of \(totalChunks)")
        parts.append("")

        if !outlineText.isEmpty {
            parts.append("## Document Outline")
            parts.append(outlineText)
            parts.append("")
        }

        if !earlierSummaryText.isEmpty {
            parts.append("## Earlier in the Document")
            parts.append(earlierSummaryText)
            parts.append("")
        }

        if !precedingText.isEmpty {
            parts.append("## Previously Read")
            parts.append(precedingText)
            parts.append("")
        }

        parts.append("## Currently Reading")
        parts.append(currentText)

        if !followingText.isEmpty {
            parts.append("")
            parts.append("## Coming Up Next")
            parts.append(followingText)
        }

        if !upcomingSummaryText.isEmpty {
            parts.append("")
            parts.append("## Later in the Document")
            parts.append(upcomingSummaryText)
        }

        return parts.joined(separator: "\n")
    }

    /// Estimated token count (rough approximation: ~4 chars per token)
    public var estimatedTokenCount: Int {
        fullContext.count / 4
    }
}

// MARK: - Reading FOV Context Manager

/// Builds foveated context windows around the current reading position
/// for barge-in Q&A during document playback
///
/// When the user interrupts reading to ask a question, this manager provides
/// full resolution text near the position, compressed summaries further away,
/// and a global outline so the model always knows the document's overall shape.
public actor ReadingFOVContextManager {

    // MARK: - Properties

    private let logger = Logger(label: "com.unamentis.reading.fovcontext")

    /// Number of chunks to include before current position
    private let precedingChunkCount: Int

    /// Number of chunks to include after current position
    private let followingChunkCount: Int

    /// Maximum characters for each raw-text band of the near window
    private let maxSectionCharacters: Int

    /// Maximum characters for the assembled context as a whole
    private let maxTotalCharacters: Int

    /// System prompt for reading Q&A
    private let systemPrompt: String

    // MARK: - Initialization

    /// Initialize the reading context manager
    /// - Parameters:
    ///   - precedingChunkCount: Chunks to include before current (default: 3)
    ///   - followingChunkCount: Chunks to include after current (default: 2)
    ///   - maxSectionCharacters: Max chars per raw-text band (default: 4000)
    ///   - maxTotalCharacters: Max chars for the whole context (default: 16000)
    public init(
        precedingChunkCount: Int = 3,
        followingChunkCount: Int = 2,
        maxSectionCharacters: Int = 4000,
        maxTotalCharacters: Int = 16_000
    ) {
        self.precedingChunkCount = precedingChunkCount
        self.followingChunkCount = followingChunkCount
        self.maxSectionCharacters = maxSectionCharacters
        self.maxTotalCharacters = maxTotalCharacters
        self.systemPrompt = Self.defaultSystemPrompt

        logger.info("ReadingFOVContextManager initialized")
    }

    // MARK: - Context Building

    /// Build a foveated context window around the current reading position
    /// - Parameters:
    ///   - chunks: All chunks for the document
    ///   - currentIndex: Current chunk index being read
    ///   - title: Document title
    ///   - author: Document author (optional)
    ///   - summary: Precomputed outline and section summaries, when available
    /// - Returns: Context window ready for LLM
    public func buildContext(
        chunks: [ReadingChunkData],
        currentIndex: Int32,
        title: String,
        author: String? = nil,
        summary: ReadingDocumentSummaryRecord? = nil
    ) -> ReadingContextWindow {
        var parts = assembleParts(
            chunks: chunks,
            currentIndex: currentIndex,
            summary: summary
        )

        // Per-band cap on the raw near window before the global budget pass.
        parts.preceding = fitBand(parts.preceding, keepingEndNearest: true)
        parts.following = fitBand(parts.following, keepingEndNearest: false)

        var window = makeWindow(
            parts: parts,
            title: title,
            author: author,
            currentIndex: currentIndex,
            totalChunks: chunks.count
        )

        // Granularity-aware trimming: distant summaries go first, then the outer
        // edges of the near window, and the outline is compressed last so the
        // model never loses the document's overall shape. Pieces are dropped in
        // batches sized by the measured overshoot before re-rendering, so the
        // full context is not re-assembled once per dropped piece: this runs on
        // every chunk change and barge-in turn inside the latency budget.
        var trimSteps = 0
        var renderedCount = window.fullContext.count
        while renderedCount > maxTotalCharacters {
            let overshoot = renderedCount - maxTotalCharacters
            var freed = 0
            while freed < overshoot, let dropped = trim(&parts) {
                trimSteps += 1
                freed += dropped
            }
            guard freed > 0 else { break }
            window = makeWindow(
                parts: parts,
                title: title,
                author: author,
                currentIndex: currentIndex,
                totalChunks: chunks.count
            )
            renderedCount = window.fullContext.count
        }

        logger.debug(
            "Built reading context",
            metadata: [
                "chunkIndex": .stringConvertible(currentIndex),
                "outlineChars": .stringConvertible(window.outlineText.count),
                "earlierChars": .stringConvertible(window.earlierSummaryText.count),
                "precedingChars": .stringConvertible(window.precedingText.count),
                "currentChars": .stringConvertible(window.currentText.count),
                "followingChars": .stringConvertible(window.followingText.count),
                "upcomingChars": .stringConvertible(window.upcomingSummaryText.count),
                "trimSteps": .stringConvertible(trimSteps),
                "estimatedTokens": .stringConvertible(window.estimatedTokenCount)
            ]
        )

        return window
    }

    /// Build LLM messages for a barge-in question during reading
    /// - Parameters:
    ///   - question: The user's question
    ///   - chunks: All chunks for the document
    ///   - currentIndex: Current chunk index
    ///   - title: Document title
    ///   - author: Document author
    ///   - summary: Precomputed outline and section summaries, when available
    ///   - conversationHistory: Previous Q&A exchanges during this reading session
    /// - Returns: Array of LLM messages ready for the model
    public func buildBargeInMessages(
        question: String,
        chunks: [ReadingChunkData],
        currentIndex: Int32,
        title: String,
        author: String? = nil,
        summary: ReadingDocumentSummaryRecord? = nil,
        conversationHistory: [(question: String, answer: String)] = []
    ) -> [LLMMessage] {
        let context = buildContext(
            chunks: chunks,
            currentIndex: currentIndex,
            title: title,
            author: author,
            summary: summary
        )

        var messages: [LLMMessage] = []

        // System message with reading context
        messages.append(LLMMessage(
            role: .system,
            content: context.fullContext
        ))

        // Add conversation history from this reading session
        for exchange in conversationHistory {
            messages.append(LLMMessage(role: .user, content: exchange.question))
            messages.append(LLMMessage(role: .assistant, content: exchange.answer))
        }

        // Add current question
        messages.append(LLMMessage(role: .user, content: question))

        return messages
    }

    // MARK: - Working Parts

    /// One droppable unit of context, tagged with its distance from the reading
    /// position so trimming can always give up the farthest thing first.
    private struct Piece {
        let distance: Int
        let text: String
    }

    /// Everything the window is assembled from, in a form trimming can shrink
    /// one granular unit at a time.
    private struct ContextParts {
        var outlineOverview: String = ""
        var outlineLines: [Piece] = []
        var earlier: [Piece] = []
        var upcoming: [Piece] = []
        var preceding: [Piece] = []
        var current: String = ""
        var following: [Piece] = []
    }

    // MARK: - Assembly

    private func assembleParts(
        chunks: [ReadingChunkData],
        currentIndex: Int32,
        summary: ReadingDocumentSummaryRecord?
    ) -> ContextParts {
        var parts = ContextParts()
        let current = Int(currentIndex)

        if current >= 0, current < chunks.count {
            parts.current = chunks[current].text
        }

        // Near window. Clamp both bounds so an out-of-range currentIndex cannot
        // trap on the slice subscript.
        let precedingEnd = min(max(current, 0), chunks.count)
        let precedingStart = max(0, min(current - precedingChunkCount, precedingEnd))
        parts.preceding = chunks[precedingStart..<precedingEnd].map {
            Piece(distance: current - Int($0.index), text: $0.text)
        }

        let followingEnd = min(chunks.count, current + 1 + followingChunkCount)
        if current + 1 < chunks.count, current >= 0 {
            parts.following = chunks[(current + 1)..<followingEnd].map {
                Piece(distance: Int($0.index) - current, text: $0.text)
            }
        }

        // A record built against a different chunking (re-import, chunker tuning
        // change) would attribute summaries to the wrong positions; ignore it and
        // let background regeneration replace it.
        guard let summary, summary.hasContent, summary.totalChunks == chunks.count else { return parts }

        // Bands cover only what the near window does not already show at full
        // resolution, so nothing is said twice.
        let nearStart = Int32(precedingStart)
        let nearEnd = Int32(max(followingEnd - 1, current))

        for section in summary.sections {
            if section.endChunkIndex < nearStart {
                parts.earlier.append(Piece(
                    distance: section.distance(from: currentIndex),
                    text: Self.renderSection(section)
                ))
            } else if section.startChunkIndex > nearEnd {
                parts.upcoming.append(Piece(
                    distance: section.distance(from: currentIndex),
                    text: Self.renderSection(section)
                ))
            }
        }

        if let outline = summary.outline {
            parts.outlineOverview = outline.overview
            // The record comes from a JSON sidecar on disk; duplicate section
            // indexes in a torn or hand-edited file must degrade, not trap.
            let rangeBySection = Dictionary(
                summary.sections.map { ($0.index, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            parts.outlineLines = outline.entries.map { entry in
                let section = rangeBySection[entry.sectionIndex]
                return Piece(
                    distance: section?.distance(from: currentIndex) ?? Int.max,
                    text: Self.renderOutlineEntry(entry, section: section)
                )
            }
        }

        return parts
    }

    private func makeWindow(
        parts: ContextParts,
        title: String,
        author: String?,
        currentIndex: Int32,
        totalChunks: Int
    ) -> ReadingContextWindow {
        var outlineParts: [String] = []
        if !parts.outlineOverview.isEmpty {
            outlineParts.append("Overview: \(parts.outlineOverview)")
        }
        outlineParts.append(contentsOf: parts.outlineLines.map(\.text))

        return ReadingContextWindow(
            systemPrompt: systemPrompt,
            outlineText: outlineParts.joined(separator: "\n"),
            earlierSummaryText: parts.earlier.map(\.text).joined(separator: "\n"),
            precedingText: parts.preceding.map(\.text).joined(separator: "\n\n"),
            currentText: parts.current,
            followingText: parts.following.map(\.text).joined(separator: "\n\n"),
            upcomingSummaryText: parts.upcoming.map(\.text).joined(separator: "\n"),
            documentTitle: title,
            documentAuthor: author,
            currentChunkIndex: currentIndex,
            totalChunks: totalChunks
        )
    }

    // MARK: - Trimming

    /// Drop exactly one unit of context, cheapest first.
    /// - Returns: the dropped text's character count, or nil when nothing
    ///   further can be given up.
    private func trim(_ parts: inout ContextParts) -> Int? {
        // 1. Distant micro-summaries, farthest first, in either direction.
        if let dropped = dropFarthest(&parts.earlier, &parts.upcoming) { return dropped }

        // 2. Shrink the near window from its outer edges. The current chunk is
        //    the one thing the reader definitely asked about, so it always stays.
        if let dropped = dropFarthest(&parts.preceding, &parts.following) { return dropped }

        // 3. Compress the outline last, and only down to its overview line.
        if let farthest = parts.outlineLines.enumerated().max(by: { $0.element.distance < $1.element.distance }) {
            let dropped = farthest.element.text.count
            parts.outlineLines.remove(at: farthest.offset)
            return dropped
        }

        return nil
    }

    /// Remove the farthest entry across a pair of bands ordered with the
    /// farthest "before" piece first and the farthest "after" piece last, which
    /// holds for both the summary bands and the raw near window.
    /// - Returns: the removed text's character count, or nil when both are empty.
    private func dropFarthest(_ before: inout [Piece], _ after: inout [Piece]) -> Int? {
        let farthestBefore = before.first?.distance
        let farthestAfter = after.last?.distance

        switch (farthestBefore, farthestAfter) {
        case let (beforeDistance?, afterDistance?):
            // Ties favor dropping backwards: the reader is heading forwards.
            if beforeDistance >= afterDistance {
                return before.removeFirst().text.count
            }
            return after.removeLast().text.count
        case (_?, nil):
            return before.removeFirst().text.count
        case (nil, _?):
            return after.removeLast().text.count
        case (nil, nil):
            return nil
        }
    }

    /// Fit one raw band inside `maxSectionCharacters` by dropping whole chunks
    /// from its outer edge. If a single chunk still does not fit, it is cut back
    /// to a sentence boundary rather than an arbitrary character.
    /// - Parameter keepingEndNearest: true for the preceding band, where the last
    ///   chunk is closest to the reading position.
    private func fitBand(_ band: [Piece], keepingEndNearest: Bool) -> [Piece] {
        var result = band
        while joinedLength(result) > maxSectionCharacters, result.count > 1 {
            if keepingEndNearest {
                result.removeFirst()
            } else {
                result.removeLast()
            }
        }

        guard let only = result.first, result.count == 1, only.text.count > maxSectionCharacters else {
            return result
        }

        let trimmed = Self.trimToSentenceBoundary(
            only.text,
            limit: maxSectionCharacters,
            keepingTail: keepingEndNearest
        )
        return [Piece(distance: only.distance, text: trimmed)]
    }

    private func joinedLength(_ band: [Piece]) -> Int {
        guard !band.isEmpty else { return 0 }
        let separators = (band.count - 1) * 2
        return band.reduce(separators) { $0 + $1.text.count }
    }

    // MARK: - Rendering

    private static func renderSection(_ section: ReadingSectionSummary) -> String {
        let label = section.title.map { "\($0) (\(section.segmentRangeDescription))" }
            ?? section.segmentRangeDescription.capitalizedFirst
        return "- \(label): \(section.summary)"
    }

    private static func renderOutlineEntry(
        _ entry: ReadingOutlineEntry,
        section: ReadingSectionSummary?
    ) -> String {
        var label = "\(entry.sectionIndex + 1)."
        if let title = entry.title {
            label += " \(title)"
        }
        if let section {
            label += " (\(section.segmentRangeDescription))"
        }
        return "\(label): \(entry.line)"
    }

    /// Cut text back to a sentence boundary within a character limit.
    /// - Parameter keepingTail: keep the end of the text (closest to the reading
    ///   position) rather than the beginning.
    static func trimToSentenceBoundary(
        _ text: String,
        limit: Int,
        keepingTail: Bool
    ) -> String {
        guard text.count > limit, limit > 0 else { return text }

        var sentences: [String] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.bySentences, .localized]
        ) { substring, _, _, _ in
            if let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sentence.isEmpty {
                sentences.append(sentence)
            }
        }

        let ordered = keepingTail ? Array(sentences.reversed()) : sentences
        var kept: [String] = []
        var length = 0
        for sentence in ordered {
            let addition = sentence.count + (kept.isEmpty ? 0 : 1)
            if length + addition > limit { break }
            kept.append(sentence)
            length += addition
        }

        guard !kept.isEmpty else {
            // A single sentence longer than the whole budget: fall back to a word
            // boundary so the text still ends somewhere readable.
            return trimToWordBoundary(text, limit: limit, keepingTail: keepingTail)
        }

        let restored = keepingTail ? Array(kept.reversed()) : kept
        return restored.joined(separator: " ")
    }

    private static func trimToWordBoundary(
        _ text: String,
        limit: Int,
        keepingTail: Bool
    ) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let ordered = keepingTail ? Array(words.reversed()) : words

        var kept: [String] = []
        var length = 0
        for word in ordered {
            let addition = word.count + (kept.isEmpty ? 0 : 1)
            if length + addition > limit { break }
            kept.append(word)
            length += addition
        }

        guard !kept.isEmpty else {
            // No boundary exists inside the limit (URLs, base64, spaceless
            // scripts): keep the nearest raw characters rather than silently
            // emptying the band, matching the old suffix-truncation guarantee.
            return keepingTail ? String(text.suffix(limit)) : String(text.prefix(limit))
        }
        let restored = keepingTail ? Array(kept.reversed()) : kept
        return restored.joined(separator: " ")
    }

    // MARK: - Default System Prompt

    private static let defaultSystemPrompt = """
        You are a helpful reading assistant. The user is listening to a document \
        being read aloud and has paused to ask you a question.

        Answer the question based on the document content provided below. \
        The outline describes the whole document, the summary sections describe \
        material away from the current position, and the passages around \
        "Currently Reading" are the exact text being read.

        Be concise and direct. If the answer is in the document, cite the \
        relevant passage. If the question is about something not in the \
        document, say so clearly.

        Keep responses brief since the user will resume listening after your answer.
        """
}

// MARK: - String Helper

private extension String {
    /// Capitalize only the first character, leaving the rest untouched
    var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
