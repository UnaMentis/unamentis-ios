// UnaMentis - Context Summarizer Tests
// Unit tests for the FOV context summarizer
//
// Exercises real ContextSummarizer behavior (caching, guards, compression,
// concept extraction, and LLM-error fallback). The LLM is a paid external
// API, so it is the only dependency that uses a mock (MockLLMService from
// the Helpers). All summarizer logic under test is real.

import XCTest
@testable import UnaMentis

final class ContextSummarizerTests: XCTestCase {

    var llm: MockLLMService!
    var summarizer: ContextSummarizer!

    override func setUp() async throws {
        llm = MockLLMService()
        summarizer = ContextSummarizer(llmService: llm)
    }

    override func tearDown() async throws {
        llm = nil
        summarizer = nil
    }

    // MARK: - summarizeTurns

    func testSummarizeTurns_emptyReturnsEmptyWithoutCallingLLM() async {
        // When
        let result = await summarizer.summarizeTurns([])

        // Then
        XCTAssertEqual(result, "")
        let callCount = await llm.streamCompletionCallCount
        XCTAssertEqual(callCount, 0, "Empty input should short-circuit before any LLM call")
    }

    func testSummarizeTurns_returnsLLMResponse() async {
        // Given
        await llm.configure(summaryResponse: "Student explored photosynthesis basics.")
        let turns = [
            ConversationTurn(role: .user, content: "What is photosynthesis?"),
            ConversationTurn(role: .assistant, content: "It converts light to energy.")
        ]

        // When
        let summary = await summarizer.summarizeTurns(turns)

        // Then
        XCTAssertEqual(summary, "Student explored photosynthesis basics.")
        let callCount = await llm.streamCompletionCallCount
        XCTAssertEqual(callCount, 1)
    }

    func testSummarizeTurns_identicalInputUsesCache() async {
        // Given
        await llm.configure(summaryResponse: "Cached summary text.")
        let turns = [
            ConversationTurn(role: .user, content: "Explain mitosis."),
            ConversationTurn(role: .assistant, content: "Mitosis divides cells.")
        ]

        // When
        let first = await summarizer.summarizeTurns(turns)
        // Change the configured response; the cache should make this irrelevant.
        await llm.configure(summaryResponse: "A different summary.")
        let second = await summarizer.summarizeTurns(turns)

        // Then
        XCTAssertEqual(first, second, "Repeat call with identical turns should hit cache")
        XCTAssertEqual(first, "Cached summary text.")
        let callCount = await llm.streamCompletionCallCount
        XCTAssertEqual(callCount, 1, "Cache hit must not trigger a second LLM call")
    }

    func testSummarizeTurns_passesSystemPromptAndUserPromptToLLM() async {
        // Given
        let turns = [ConversationTurn(role: .user, content: "Define entropy.")]

        // When
        _ = await summarizer.summarizeTurns(turns)

        // Then
        let messages = await llm.lastMessages
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?.first?.role, .system)
        XCTAssertEqual(messages?.last?.role, .user)
        // The formatted user prompt should embed the verbatim turn content.
        XCTAssertTrue(messages?.last?.content.contains("Define entropy.") ?? false)
        XCTAssertTrue(messages?.last?.content.contains("[User]") ?? false)
    }

    func testSummarizeTurns_clearCacheForcesRegeneration() async {
        // Given
        await llm.configure(summaryResponse: "First.")
        let turns = [ConversationTurn(role: .user, content: "Topic A")]
        _ = await summarizer.summarizeTurns(turns)

        // When
        await summarizer.clearCache()
        await llm.configure(summaryResponse: "Second.")
        let result = await summarizer.summarizeTurns(turns)

        // Then
        XCTAssertEqual(result, "Second.", "After clearing cache the LLM should be queried again")
        let callCount = await llm.streamCompletionCallCount
        XCTAssertEqual(callCount, 2)
    }

    // MARK: - summarizeTopicContent

    func testSummarizeTopicContent_emptyReturnsEmpty() async {
        let result = await summarizer.summarizeTopicContent("")
        XCTAssertEqual(result, "")
        let callCount = await llm.streamCompletionCallCount
        XCTAssertEqual(callCount, 0)
    }

    func testSummarizeTopicContent_returnsLLMResponse() async {
        // Given
        await llm.configure(summaryResponse: "Topic overview.")

        // When
        let result = await summarizer.summarizeTopicContent("Detailed topic content about cells.")

        // Then
        XCTAssertEqual(result, "Topic overview.")
    }

    func testSummarizeTopicContent_cachesByContent() async {
        // Given
        await llm.configure(summaryResponse: "Overview one.")
        let content = "Repeated content for caching."
        _ = await summarizer.summarizeTopicContent(content)

        // When
        await llm.configure(summaryResponse: "Overview two.")
        let second = await summarizer.summarizeTopicContent(content)

        // Then
        XCTAssertEqual(second, "Overview one.")
        let callCount = await llm.streamCompletionCallCount
        XCTAssertEqual(callCount, 1)
    }

    // MARK: - summarizeQuestions

    func testSummarizeQuestions_emptyReturnsEmpty() async {
        let result = await summarizer.summarizeQuestions([])
        XCTAssertEqual(result, "")
        let callCount = await llm.streamCompletionCallCount
        XCTAssertEqual(callCount, 0)
    }

    func testSummarizeQuestions_includesQuestionsInPrompt() async {
        // Given
        let questions = [
            UserQuestion(question: "Why is the sky blue?", wasAnswered: true),
            UserQuestion(question: "How does refraction work?", wasAnswered: false)
        ]

        // When
        _ = await summarizer.summarizeQuestions(questions)

        // Then
        let messages = await llm.lastMessages
        let userPrompt = messages?.last?.content ?? ""
        XCTAssertTrue(userPrompt.contains("Why is the sky blue?"))
        XCTAssertTrue(userPrompt.contains("How does refraction work?"))
    }

    // MARK: - generateProgressSummary

    func testGenerateProgressSummary_emptyTopicsReturnsEmpty() async {
        let result = await summarizer.generateProgressSummary(
            topicSummaries: [],
            signals: LearnerSignals()
        )
        XCTAssertEqual(result, "")
        let callCount = await llm.streamCompletionCallCount
        XCTAssertEqual(callCount, 0)
    }

    func testGenerateProgressSummary_embedsMasteryAndSignals() async {
        // Given
        let topics = [
            FOVTopicSummary(
                topicId: UUID(),
                title: "Algebra",
                summary: "Linear equations",
                masteryLevel: 0.75
            )
        ]
        var signals = LearnerSignals()
        signals.pacePreference = .slow
        signals.clarificationRequests = 3

        // When
        _ = await summarizer.generateProgressSummary(topicSummaries: topics, signals: signals)

        // Then
        let messages = await llm.lastMessages
        let userPrompt = messages?.last?.content ?? ""
        XCTAssertTrue(userPrompt.contains("Algebra"))
        XCTAssertTrue(userPrompt.contains("75%"), "Mastery should be rendered as a percentage")
        XCTAssertTrue(userPrompt.contains("slow"))
        XCTAssertTrue(userPrompt.contains("clarification"))
    }

    // MARK: - compressToFit

    func testCompressToFit_withinBudgetReturnsUnchangedWithoutLLM() async {
        // Given: 40 chars is ~10 tokens, well under the budget.
        let text = String(repeating: "a", count: 40)

        // When
        let result = await summarizer.compressToFit(text, targetTokens: 100)

        // Then
        XCTAssertEqual(result, text, "Text already within budget should be returned verbatim")
        let callCount = await llm.streamCompletionCallCount
        XCTAssertEqual(callCount, 0, "No compression needed means no LLM call")
    }

    func testCompressToFit_overBudgetInvokesLLM() async {
        // Given: ~250 tokens of input (1000 chars) compressed to 100 tokens.
        await llm.configure(summaryResponse: "Condensed.")
        let text = String(repeating: "b", count: 1000)

        // When
        let result = await summarizer.compressToFit(text, targetTokens: 100)

        // Then
        XCTAssertEqual(result, "Condensed.")
        let callCount = await llm.streamCompletionCallCount
        XCTAssertEqual(callCount, 1)
    }

    func testCompressToFit_heavyCompressionUsesEssentialSummaryPrompt() async {
        // Given: ratio of target/estimated is well under 0.5 (heavy compression branch).
        // 4000 chars is ~1000 tokens, target 100 -> ratio 0.1.
        let text = String(repeating: "c", count: 4000)

        // When
        _ = await summarizer.compressToFit(text, targetTokens: 100)

        // Then
        let messages = await llm.lastMessages
        let userPrompt = messages?.last?.content ?? ""
        XCTAssertTrue(userPrompt.contains("Essential summary"),
                      "Heavy compression should use the essential-summary prompt")
    }

    func testCompressToFit_lightCompressionUsesCondensePrompt() async {
        // Given: ratio between 0.5 and 1.0 (light compression branch).
        // 1000 chars is ~250 tokens, target 200 -> ratio 0.8.
        let text = String(repeating: "d", count: 1000)

        // When
        _ = await summarizer.compressToFit(text, targetTokens: 200)

        // Then
        let messages = await llm.lastMessages
        let userPrompt = messages?.last?.content ?? ""
        XCTAssertTrue(userPrompt.contains("Condensed version"),
                      "Light compression should use the condense prompt")
    }

    // MARK: - extractKeyConcepts

    func testExtractKeyConcepts_splitsCommaSeparatedResponse() async {
        // Given
        await llm.configure(summaryResponse: "Mitosis, Meiosis, Cell cycle")

        // When
        let concepts = await summarizer.extractKeyConcepts("Some biology content.")

        // Then
        XCTAssertEqual(concepts, ["Mitosis", "Meiosis", "Cell cycle"])
    }

    func testExtractKeyConcepts_trimsWhitespaceAroundConcepts() async {
        // Given
        await llm.configure(summaryResponse: "  Force ,  Mass ,Acceleration  ")

        // When
        let concepts = await summarizer.extractKeyConcepts("Physics content.")

        // Then
        XCTAssertEqual(concepts, ["Force", "Mass", "Acceleration"])
    }

    // MARK: - LLM Error Fallback

    func testGenerateSummary_fallsBackToTruncationOnLLMError() async {
        // Given
        await llm.configureToFail(with: .rateLimited(retryAfter: 30))
        let turns = [
            ConversationTurn(role: .user, content: String(repeating: "x", count: 300))
        ]

        // When
        let summary = await summarizer.summarizeTurns(turns)

        // Then: the fallback truncates the prompt and appends an ellipsis.
        XCTAssertFalse(summary.isEmpty, "Fallback must still return a usable string")
        XCTAssertTrue(summary.hasSuffix("..."), "Fallback truncation appends an ellipsis")
    }

    // MARK: - Configuration

    func testUpdateConfig_changesSystemPromptSentToLLM() async {
        // Given
        let custom = SummarizerConfig(
            systemPrompt: "CUSTOM-SYSTEM-PROMPT",
            llmConfig: .costOptimized,
            maxInputLength: 1000,
            cacheExpiration: 60
        )
        await summarizer.updateConfig(custom)

        // When
        _ = await summarizer.summarizeTurns([ConversationTurn(role: .user, content: "Hi")])

        // Then
        let messages = await llm.lastMessages
        XCTAssertEqual(messages?.first?.content, "CUSTOM-SYSTEM-PROMPT")
    }

    func testUpdateConfig_maxInputLengthTruncatesTopicContent() async {
        // Given: a tiny max input length so the topic content is clipped in the prompt.
        let custom = SummarizerConfig(
            systemPrompt: "S",
            llmConfig: .costOptimized,
            maxInputLength: 10,
            cacheExpiration: 60
        )
        await summarizer.updateConfig(custom)
        let longContent = String(repeating: "Z", count: 500)

        // When
        _ = await summarizer.summarizeTopicContent(longContent)

        // Then: the user prompt embeds at most maxInputLength characters of content.
        let messages = await llm.lastMessages
        let userPrompt = messages?.last?.content ?? ""
        let zCount = userPrompt.filter { $0 == "Z" }.count
        XCTAssertLessThanOrEqual(zCount, 10, "Content should be clipped to maxInputLength")
        XCTAssertGreaterThan(zCount, 0)
    }

    // MARK: - Config Presets

    func testSummarizerConfig_defaultUsesCostOptimizedModel() {
        let config = SummarizerConfig.default
        XCTAssertEqual(config.llmConfig.model, LLMConfig.costOptimized.model)
        XCTAssertEqual(config.maxInputLength, 4000)
        XCTAssertEqual(config.cacheExpiration, 3600)
    }

    func testSummarizerConfig_minimalIsSmallerThanDefault() {
        let minimal = SummarizerConfig.minimal
        XCTAssertLessThan(minimal.maxInputLength, SummarizerConfig.default.maxInputLength)
        XCTAssertLessThan(minimal.cacheExpiration, SummarizerConfig.default.cacheExpiration)
        XCTAssertEqual(minimal.llmConfig.maxTokens, 150)
    }
}
