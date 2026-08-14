// UnaMentis - Reading Summary Pre-Generator
// Background summarization of imported documents for foveated reader context.
//
// Shaped after ReadingAudioPreGenerator: fire and forget from the import path,
// one task per item, progress tracking, results persisted as they complete.
// Two passes run per document:
//   1. Micro-summaries, one to two sentences for each group of chunks.
//   2. A single outline pass over those micro-summaries, producing a coarse map
//      of the whole document.
//
// Nothing here blocks import or playback. With no LLM available the status stays
// pending and the work is retried the next time the item is opened.
//
// Part of Services/ReadingPlayback

import Foundation
import Logging

// MARK: - Errors

/// Failures specific to summary pre-generation
public enum ReadingSummaryError: Error, Sendable {
    /// The LLM returned nothing usable
    case emptyResponse
}

// MARK: - Reading Summary Pre-Generator

/// Actor that pre-generates section summaries and a document outline for reading items.
///
/// Results are persisted through `ReadingSummaryStore` so they survive relaunch.
/// The reader's FOV context manager consumes them to build a foveated window
/// around the current position.
public actor ReadingSummaryPreGenerator {

    /// Shared singleton instance
    public static let shared = ReadingSummaryPreGenerator()

    /// Resolves the LLM used for summarization, or nil when none is configured
    public typealias LLMResolver = @Sendable () async -> (any LLMService)?

    private let logger = Logger(label: "com.unamentis.reading.summary.pregen")

    private let store: ReadingSummaryStore
    private let resolveLLM: LLMResolver

    /// Summarization settings. The cost-optimized LLM config keeps this cheap,
    /// matching how ContextSummarizer treats compression work.
    private let config: SummarizerConfig

    /// In-progress generation tasks keyed by item ID
    private var inProgressTasks: [UUID: Task<Void, Never>] = [:]

    /// Progress tracking for in-flight generation (completed sections, total sections)
    private var progressMap: [UUID: (completed: Int, total: Int)] = [:]

    /// Initialize the pre-generator
    /// - Parameters:
    ///   - store: Sidecar persistence for generated records
    ///   - config: Summarizer settings, including the cost-optimized LLM config
    ///   - resolveLLM: Supplies the LLM service, or nil when none is configured
    public init(
        store: ReadingSummaryStore = .shared,
        config: SummarizerConfig = .default,
        resolveLLM: @escaping LLMResolver = ReadingSummaryPreGenerator.defaultLLMResolver
    ) {
        self.store = store
        self.config = config
        self.resolveLLM = resolveLLM
    }

    // MARK: - Public API

    /// Generate summaries for a reading item if they are missing or stale.
    ///
    /// Returns immediately. Generation runs in a detached task and writes partial
    /// results as each section completes.
    ///
    /// - Parameters:
    ///   - itemId: The reading item's UUID
    ///   - title: Document title, used to ground the outline pass
    ///   - chunks: All chunks of the document (index + text)
    ///   - sectionMarkers: Structural markers captured at import, may be empty
    ///   - force: Regenerate even when a completed record already exists
    public func preGenerate(
        itemId: UUID,
        title: String,
        chunks: [PreGenChunkSpec],
        sectionMarkers: [DocumentSectionMarker] = [],
        force: Bool = false
    ) {
        guard !chunks.isEmpty else { return }

        guard inProgressTasks[itemId] == nil else {
            logger.debug("Summary generation already in progress for \(itemId)")
            return
        }

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.generate(
                itemId: itemId,
                title: title,
                chunks: chunks,
                sectionMarkers: sectionMarkers,
                force: force
            )
            await self.removeTask(itemId: itemId)
        }

        inProgressTasks[itemId] = task
    }

    /// The persisted record for an item, if any
    public func summaryRecord(itemId: UUID) async -> ReadingDocumentSummaryRecord? {
        await store.load(itemId: itemId)
    }

    /// Whether generation is currently running for an item
    public func isGenerating(itemId: UUID) -> Bool {
        inProgressTasks[itemId] != nil
    }

    /// Current progress for an item, or nil when nothing is running
    public func getProgress(itemId: UUID) -> (completed: Int, total: Int)? {
        progressMap[itemId]
    }

    /// Wait for in-progress generation to finish. Returns immediately if idle.
    public func waitForGeneration(itemId: UUID) async {
        guard let task = inProgressTasks[itemId] else { return }
        await task.value
    }

    /// Discard the stored summaries for an item, cancelling any in-flight
    /// generation first so a late per-section save cannot recreate the sidecar
    /// for a deleted item.
    public func discard(itemId: UUID) async {
        inProgressTasks[itemId]?.cancel()
        inProgressTasks[itemId] = nil
        progressMap[itemId] = nil
        await store.delete(itemId: itemId)
    }

    // MARK: - Generation

    /// Decide whether work is needed, group the chunks, and run the two passes
    private func generate(
        itemId: UUID,
        title: String,
        chunks: [PreGenChunkSpec],
        sectionMarkers: [DocumentSectionMarker],
        force: Bool
    ) async {
        let existing = await store.load(itemId: itemId)
        if !force, let existing, !existing.needsGeneration(forChunkCount: chunks.count) {
            logger.debug("Summaries already available for \(itemId)")
            return
        }

        let ranges = ReadingSectionGrouper.makeSections(
            totalChunks: chunks.count,
            markers: sectionMarkers
        )
        guard !ranges.isEmpty else { return }

        logger.info("Starting summary generation for \(itemId), \(ranges.count) sections")

        await run(itemId: itemId, title: title, chunks: chunks, ranges: ranges)
    }

    private func run(
        itemId: UUID,
        title: String,
        chunks: [PreGenChunkSpec],
        ranges: [ReadingSectionRange]
    ) async {
        // Start from the persisted record so a retry never destroys previously
        // generated sections: a killed run's partial summaries stay usable for
        // context until this run replaces them. Sections from a different
        // chunking are cleared, since their ranges no longer mean anything.
        var record = await store.load(itemId: itemId) ?? ReadingDocumentSummaryRecord(
            itemId: itemId,
            status: .inProgress,
            totalChunks: chunks.count
        )
        if record.totalChunks != chunks.count {
            record.sections = []
            record.outline = nil
        }
        record.status = .inProgress
        record.totalChunks = chunks.count
        record.lastAttemptAt = Date()
        progressMap[itemId] = (completed: 0, total: ranges.count)

        // No LLM configured: leave the record pending so the next open retries,
        // keeping whatever sections it already carries.
        guard let llm = await resolveLLM() else {
            logger.info("No LLM available, deferring summary generation for \(itemId)")
            record.status = .pending
            await store.save(record)
            return
        }
        await store.save(record)

        var summaries: [ReadingSectionSummary] = []
        var failedSections = 0

        for (position, range) in ranges.enumerated() {
            guard !Task.isCancelled else { break }

            let text = sectionText(chunks: chunks, range: range)
            guard !text.isEmpty else {
                progressMap[itemId] = (completed: position + 1, total: ranges.count)
                continue
            }

            do {
                let summary = try await summarize(
                    prompt: Self.sectionPrompt(title: title, sectionTitle: range.title, text: text),
                    llm: llm,
                    llmConfig: config.llmConfig
                )
                summaries.append(ReadingSectionSummary(
                    index: position,
                    startChunkIndex: range.startChunkIndex,
                    endChunkIndex: range.endChunkIndex,
                    title: range.title,
                    summary: summary
                ))
                // Persist partial results so an interrupted run is not wasted.
                record.sections = summaries
                await store.save(record)
            } catch {
                failedSections += 1
                logger.warning(
                    "Section \(position) summary failed for \(itemId): \(error.localizedDescription)"
                )
            }

            progressMap[itemId] = (completed: position + 1, total: ranges.count)
        }

        // A cancelled run must not write anything further: the item may have
        // been deleted, and a partial record must stay retryable, not final.
        guard !Task.isCancelled else {
            logger.info("Summary generation cancelled for \(itemId)")
            return
        }

        guard !summaries.isEmpty else {
            logger.warning("Summary generation produced nothing for \(itemId)")
            record.status = .failed
            await store.save(record)
            return
        }

        record.outline = await buildOutline(title: title, summaries: summaries, llm: llm)
        record.sections = summaries
        // Any failed section keeps the record retryable: marking it completed
        // would make needsGeneration false forever and permanently strand the
        // missing sections after one transient LLM failure. The partial
        // sections stay usable for context in the meantime.
        record.status = failedSections == 0 ? .completed : .failed
        record.generatedAt = Date()
        await store.save(record)

        logger.info(
            "Summary generation \(failedSections == 0 ? "complete" : "partial (will retry)") for \(itemId): \(summaries.count)/\(ranges.count) sections"
        )
    }

    /// Build the whole-document outline in a single pass over the micro-summaries.
    /// Falls back to a locally derived outline when the LLM pass fails, so the
    /// reader always has a global map once summaries exist.
    private func buildOutline(
        title: String,
        summaries: [ReadingSectionSummary],
        llm: any LLMService
    ) async -> ReadingDocumentOutline {
        do {
            let response = try await summarize(
                prompt: Self.outlinePrompt(title: title, summaries: summaries),
                llm: llm,
                llmConfig: outlineLLMConfig(sectionCount: summaries.count)
            )
            let parsed = Self.parseOutline(response, summaries: summaries)
            if !parsed.entries.isEmpty {
                return parsed
            }
        } catch {
            logger.warning("Outline pass failed for '\(title)': \(error.localizedDescription)")
        }
        return Self.fallbackOutline(title: title, summaries: summaries)
    }

    /// Run one summarization request.
    ///
    /// This follows ContextSummarizer's pattern (cost-optimized config, system
    /// prompt plus user prompt) but keeps the error rather than falling back to
    /// truncated prompt text, because the caller has to tell success from failure
    /// to set the persisted status correctly.
    private func summarize(
        prompt: String,
        llm: any LLMService,
        llmConfig: LLMConfig
    ) async throws -> String {
        let messages = [
            LLMMessage(role: .system, content: config.systemPrompt),
            LLMMessage(role: .user, content: prompt)
        ]
        let response = try await llm.complete(messages: messages, config: llmConfig)
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ReadingSummaryError.emptyResponse }
        return trimmed
    }

    /// The outline pass emits one line per section, so it needs more headroom
    /// than a single micro-summary. Stays inside provider max_tokens limits.
    private func outlineLLMConfig(sectionCount: Int) -> LLMConfig {
        var outlineConfig = config.llmConfig
        // ~20 tokens per outline line plus the overview sentence.
        let needed = 64 + sectionCount * 20
        outlineConfig.maxTokens = min(4096, max(outlineConfig.maxTokens, needed))
        return outlineConfig
    }

    /// Concatenated chunk text for a section, capped at the summarizer's input limit
    private func sectionText(chunks: [PreGenChunkSpec], range: ReadingSectionRange) -> String {
        let text = chunks
            .filter { $0.index >= range.startChunkIndex && $0.index <= range.endChunkIndex }
            .map(\.text)
            .joined(separator: " ")
        return String(text.prefix(config.maxInputLength))
    }

    private func removeTask(itemId: UUID) {
        inProgressTasks.removeValue(forKey: itemId)
        progressMap.removeValue(forKey: itemId)
    }

    // MARK: - Prompts

    static func sectionPrompt(title: String, sectionTitle: String?, text: String) -> String {
        let heading = sectionTitle.map { "The section is titled \"\($0)\".\n" } ?? ""
        return """
        Summarize this passage from the document "\(title)".
        \(heading)Write one or two sentences describing what the passage covers. \
        Do not add any preamble.

        Passage:
        \(text)

        Summary:
        """
    }

    static func outlinePrompt(title: String, summaries: [ReadingSectionSummary]) -> String {
        // Numbered by position in this list, not by section index: skipped or
        // failed sections leave index gaps, and a gapped prompt makes the model
        // renumber contiguously anyway, misaligning every line after the gap.
        // parseOutline maps positions back to section indexes.
        let body = summaries.enumerated().map { position, summary in
            let label = summary.title.map { " (\($0))" } ?? ""
            return "\(position + 1)\(label): \(summary.summary)"
        }.joined(separator: "\n")

        return """
        Below are section summaries for the document "\(title)", in reading order.
        Produce a compact outline of the whole document.

        Format exactly:
        Overview: <one sentence describing the document as a whole>
        1. <short clause describing section 1, at most 15 words>
        2. <short clause describing section 2, at most 15 words>
        ... one numbered line for every section, in order.

        Output nothing else.

        Sections:
        \(body)
        """
    }

    // MARK: - Outline Parsing

    /// Parse the outline pass response into structured entries.
    /// Sections the model skipped fall back to their own micro-summary.
    static func parseOutline(
        _ response: String,
        summaries: [ReadingSectionSummary]
    ) -> ReadingDocumentOutline {
        var overview = ""
        var lines: [Int: String] = [:]

        for rawLine in response.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if overview.isEmpty, line.lowercased().hasPrefix("overview:") {
                overview = String(line.dropFirst("overview:".count))
                    .trimmingCharacters(in: .whitespaces)
                continue
            }

            guard let separator = line.firstIndex(of: "."),
                  let number = Int(line[line.startIndex..<separator]) else { continue }
            let description = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !description.isEmpty else { continue }
            lines[number - 1] = description
        }

        guard !lines.isEmpty else {
            return ReadingDocumentOutline(overview: overview, entries: [])
        }

        // Positional mapping mirrors outlinePrompt's positional numbering.
        let entries = summaries.enumerated().map { position, summary in
            ReadingOutlineEntry(
                sectionIndex: summary.index,
                title: summary.title,
                line: lines[position] ?? firstSentence(of: summary.summary)
            )
        }

        return ReadingDocumentOutline(
            overview: overview.isEmpty ? defaultOverview(summaries: summaries) : overview,
            entries: entries
        )
    }

    /// Outline derived locally from the micro-summaries, used when the LLM
    /// outline pass is unavailable or unusable.
    static func fallbackOutline(
        title: String,
        summaries: [ReadingSectionSummary]
    ) -> ReadingDocumentOutline {
        ReadingDocumentOutline(
            overview: defaultOverview(summaries: summaries),
            entries: summaries.map { summary in
                ReadingOutlineEntry(
                    sectionIndex: summary.index,
                    title: summary.title,
                    line: firstSentence(of: summary.summary)
                )
            }
        )
    }

    private static func defaultOverview(summaries: [ReadingSectionSummary]) -> String {
        guard let first = summaries.first else { return "" }
        return firstSentence(of: first.summary)
    }

    private static func firstSentence(of text: String) -> String {
        var sentence: String?
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.bySentences, .localized]
        ) { substring, _, _, stop in
            sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines)
            stop = true
        }
        return sentence ?? text
    }

    // MARK: - Default LLM Resolution

    /// Resolve the summarization LLM from the same shared resolution the
    /// reader's barge-in Q&A uses. Returns nil when no server is configured, so
    /// generation defers instead of failing against an unreachable host.
    public static let defaultLLMResolver: LLMResolver = {
        SelfHostedLLMService.configuredReaderService()
    }
}
