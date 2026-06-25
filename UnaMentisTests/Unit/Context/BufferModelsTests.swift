// UnaMentis - Buffer Models Tests
//
// Unit tests for the FOV context buffer value types in BufferModels.swift. These are
// pure, deterministic value types with no external dependencies, so every test uses the
// real types with no mocks. The behaviors exercised here are the load-bearing contracts
// that the context-management system depends on:
//
//   - ModelTier.from(contextWindow:) boundary classification (the exact thresholds).
//   - ModelTier.budgets and conversationTurns per tier.
//   - ModelContextWindows.contextWindow(for:) order-sensitive substring matching, which is
//     the bug class to protect (for example "gpt-4o" must not fall through to "gpt-4").
//   - AdaptiveBudgetConfig delegation to the tier and Equatable behavior.
//   - FOVContext.toSystemMessage section assembly, empty-buffer skipping, and ordering.
//   - Token-budget-gated rendering for the immediate, working, episodic, and semantic
//     buffers, including which parts are dropped when the budget is too small.
//   - LearnerSignals and CurriculumPosition string rendering, including the count
//     thresholds and the progress percentage math.
//   - ConversationTurn.init(from: LLMMessage) role mapping and content copy.
//   - ExpansionResult / RetrievedContent token estimation.
//
// All expected values are derived directly from the source. The token estimate is always
// character count integer-divided by 4, so test fixtures use carefully sized strings.

import XCTest
@testable import UnaMentis

final class BufferModelsTests: XCTestCase {

    // MARK: - ModelTier.from(contextWindow:) boundaries

    func testModelTierFrom_classifiesAtExactBoundaries() {
        // The source uses ranges: 128_000... -> cloud, 32_000..<128_000 -> midRange,
        // 8_000..<32_000 -> onDevice, default -> tiny. Test each boundary edge.
        let cases: [(window: Int, expected: ModelTier)] = [
            (128_000, .cloud),
            (127_999, .midRange),
            (32_000, .midRange),
            (31_999, .onDevice),
            (8_000, .onDevice),
            (7_999, .tiny),
            (0, .tiny)
        ]

        for testCase in cases {
            XCTAssertEqual(
                ModelTier.from(contextWindow: testCase.window),
                testCase.expected,
                "contextWindow \(testCase.window) should classify as \(testCase.expected)"
            )
        }
    }

    // MARK: - ModelTier.budgets

    func testModelTierBudgets_cloudMatchesDocumentedValues() {
        let budgets = ModelTier.cloud.budgets
        XCTAssertEqual(budgets.total, 12_000)
        XCTAssertEqual(budgets.immediate, 3_000)
        XCTAssertEqual(budgets.working, 5_000)
        XCTAssertEqual(budgets.episodic, 2_500)
        XCTAssertEqual(budgets.semantic, 1_500)
    }

    func testModelTierBudgets_tinyMatchesDocumentedValues() {
        let budgets = ModelTier.tiny.budgets
        XCTAssertEqual(budgets.total, 2_000)
        XCTAssertEqual(budgets.immediate, 800)
        XCTAssertEqual(budgets.working, 700)
        XCTAssertEqual(budgets.episodic, 300)
        XCTAssertEqual(budgets.semantic, 200)
    }

    func testModelTierBudgets_midRangeAndOnDeviceMatchDocumentedValues() {
        let mid = ModelTier.midRange.budgets
        XCTAssertEqual(mid.total, 8_000)
        XCTAssertEqual(mid.immediate, 2_000)
        XCTAssertEqual(mid.working, 3_500)
        XCTAssertEqual(mid.episodic, 1_500)
        XCTAssertEqual(mid.semantic, 1_000)

        let onDevice = ModelTier.onDevice.budgets
        XCTAssertEqual(onDevice.total, 4_000)
        XCTAssertEqual(onDevice.immediate, 1_200)
        XCTAssertEqual(onDevice.working, 1_500)
        XCTAssertEqual(onDevice.episodic, 800)
        XCTAssertEqual(onDevice.semantic, 500)
    }

    func testModelTierConversationTurns_perTier() {
        XCTAssertEqual(ModelTier.cloud.conversationTurns, 10)
        XCTAssertEqual(ModelTier.midRange.conversationTurns, 7)
        XCTAssertEqual(ModelTier.onDevice.conversationTurns, 5)
        XCTAssertEqual(ModelTier.tiny.conversationTurns, 3)
    }

    // MARK: - ModelContextWindows.contextWindow(for:)

    func testContextWindow_orderSensitiveAndKnownModels() {
        // "gpt-4o" contains "gpt-4", but the gpt-4o check precedes the gpt-4 check, so the
        // order-sensitive matching must return 128_000, not 8_192. This is the bug class
        // the lookup is most fragile to.
        let cases: [(model: String, expected: Int)] = [
            ("gpt-4o", 128_000),
            ("gpt-4-turbo", 128_000),
            ("gpt-4", 8_192),
            ("gpt-3.5", 16_385),
            ("claude-3-5-sonnet", 200_000),
            ("claude-2", 100_000),
            ("qwen2.5", 32_768),
            ("llama3.2", 128_000),
            ("llama3.1", 128_000),
            ("mistral", 32_768),
            ("ministral", 8_192),
            ("phi", 4_096),
            ("some-unknown-model", 8_192)
        ]

        for testCase in cases {
            XCTAssertEqual(
                ModelContextWindows.contextWindow(for: testCase.model),
                testCase.expected,
                "model \(testCase.model) should map to \(testCase.expected)"
            )
        }
    }

    func testContextWindow_isCaseInsensitive() {
        // The source lowercases the input before matching, so uppercase still resolves.
        XCTAssertEqual(ModelContextWindows.contextWindow(for: "GPT-4O"), 128_000)
        XCTAssertEqual(ModelContextWindows.contextWindow(for: "Claude-3-5-Sonnet"), 200_000)
    }

    // MARK: - AdaptiveBudgetConfig

    func testAdaptiveBudgetConfig_delegatesAccessorsToTierBudgets() {
        // A 128_000 window is cloud tier. Every budget accessor must match cloud.budgets.
        let config = AdaptiveBudgetConfig(modelContextWindow: 128_000)
        XCTAssertEqual(config.tier, .cloud)
        XCTAssertEqual(config.immediateTokenBudget, ModelTier.cloud.budgets.immediate)
        XCTAssertEqual(config.workingTokenBudget, ModelTier.cloud.budgets.working)
        XCTAssertEqual(config.episodicTokenBudget, ModelTier.cloud.budgets.episodic)
        XCTAssertEqual(config.semanticTokenBudget, ModelTier.cloud.budgets.semantic)
        XCTAssertEqual(config.totalBudget, ModelTier.cloud.budgets.total)
        XCTAssertEqual(config.conversationTurnCount, ModelTier.cloud.conversationTurns)
    }

    func testAdaptiveBudgetConfig_forModelResolvesWindowThenTier() {
        let config = AdaptiveBudgetConfig.forModel("gpt-4o")
        XCTAssertEqual(config.modelContextWindow, 128_000)
        XCTAssertEqual(config.tier, .cloud)
    }

    func testAdaptiveBudgetConfig_equalForSameWindow() {
        let a = AdaptiveBudgetConfig(modelContextWindow: 32_000)
        let b = AdaptiveBudgetConfig(modelContextWindow: 32_000)
        XCTAssertEqual(a, b)

        let different = AdaptiveBudgetConfig(modelContextWindow: 128_000)
        XCTAssertNotEqual(a, different)
    }

    // MARK: - FOVContext.toSystemMessage

    func testToSystemMessage_includesAllNonEmptySectionsInSemanticOrder() {
        let context = FOVContext(
            systemPrompt: "You are a tutor.",
            immediateContext: "imm",
            workingContext: "work",
            episodicContext: "epi",
            semanticContext: "sem",
            immediateBufferTurnCount: 0,
            budgetConfig: AdaptiveBudgetConfig(modelContextWindow: 128_000)
        )

        let message = context.toSystemMessage()
        // System prompt first, then semantic, episodic, working, immediate. Sections are
        // joined by a blank line.
        let expected = """
        You are a tutor.

        ## CURRICULUM OVERVIEW
        sem

        ## SESSION HISTORY
        epi

        ## CURRENT TOPIC CONTEXT
        work

        ## IMMEDIATE CONTEXT
        imm
        """
        XCTAssertEqual(message, expected)
    }

    func testToSystemMessage_skipsEmptyBuffers() {
        let context = FOVContext(
            systemPrompt: "Base prompt.",
            immediateContext: "here-now",
            workingContext: "",
            episodicContext: "",
            semanticContext: "",
            immediateBufferTurnCount: 0,
            budgetConfig: AdaptiveBudgetConfig(modelContextWindow: 8_192)
        )

        let message = context.toSystemMessage()
        // Empty buffers contribute no header at all.
        XCTAssertFalse(message.contains("## CURRICULUM OVERVIEW"))
        XCTAssertFalse(message.contains("## SESSION HISTORY"))
        XCTAssertFalse(message.contains("## CURRENT TOPIC CONTEXT"))
        XCTAssertTrue(message.contains("## IMMEDIATE CONTEXT"))
        XCTAssertEqual(message, "Base prompt.\n\n## IMMEDIATE CONTEXT\nhere-now")
    }

    func testTotalTokenEstimate_sumsAllFiveBuffersDividedByFour() {
        // Lengths: prompt 8, imm 4, work 4, epi 4, sem 4 -> total chars 24, /4 = 6.
        let context = FOVContext(
            systemPrompt: "12345678",
            immediateContext: "aaaa",
            workingContext: "bbbb",
            episodicContext: "cccc",
            semanticContext: "dddd",
            immediateBufferTurnCount: 0,
            budgetConfig: AdaptiveBudgetConfig(modelContextWindow: 8_192)
        )
        XCTAssertEqual(context.totalTokenEstimate, 6)
    }

    // MARK: - ImmediateBuffer.render

    func testImmediateRender_bargeInAlwaysIncludedEvenWithZeroBudget() {
        // The barge-in utterance is appended before any budget check, so even a budget of 0
        // keeps it while the budget-gated current segment and turns are dropped.
        let buffer = ImmediateBuffer(
            currentSegment: TranscriptSegmentContext(id: "s1", content: "teaching content", segmentIndex: 0),
            recentTurns: [ConversationTurn(role: .user, content: "an earlier user line")],
            bargeInUtterance: "wait, stop"
        )

        let rendered = buffer.render(tokenBudget: 0)
        XCTAssertEqual(rendered, "The user just interrupted with: \"wait, stop\"")
        XCTAssertFalse(rendered.contains("Currently teaching"))
        XCTAssertFalse(rendered.contains("an earlier user line"))
    }

    func testImmediateRender_ampleBudgetIncludesAllParts() {
        // With a generous budget every part renders. The barge-in leads, the current segment
        // follows, and recent turns are appended.
        let buffer = ImmediateBuffer(
            currentSegment: TranscriptSegmentContext(id: "s1", content: "photosynthesis", segmentIndex: 0),
            recentTurns: [
                ConversationTurn(role: .user, content: "first question"),
                ConversationTurn(role: .assistant, content: "first answer")
            ],
            bargeInUtterance: "hold on"
        )

        // Parts assemble as: barge-in (appended first), then the current segment is appended
        // (parts = [bargeIn, segment]), then turns iterate reversed and each inserts at index 1.
        // Reversed turns are [assistant "first answer", user "first question"].
        //   assistant inserts at 1 -> [bargeIn, assistant, segment]
        //   user inserts at 1      -> [bargeIn, user, assistant, segment]
        let rendered = buffer.render(tokenBudget: 10_000)
        let expected = [
            "The user just interrupted with: \"hold on\"",
            "[User]: first question",
            "[Assistant]: first answer",
            "Currently teaching: photosynthesis"
        ].joined(separator: "\n\n")
        XCTAssertEqual(rendered, expected)
    }

    func testImmediateRender_currentSegmentDroppedWhenBudgetTooSmall() {
        // A budget that cannot fit the segment text leaves only the barge-in. The barge-in
        // alone already pushes estimatedTokens above the budget of 1, and the segment text
        // "Currently teaching: x" is 21 chars (5 tokens), so the segment is dropped.
        let buffer = ImmediateBuffer(
            currentSegment: TranscriptSegmentContext(id: "s1", content: "x", segmentIndex: 0),
            bargeInUtterance: "stop"
        )
        let rendered = buffer.render(tokenBudget: 1)
        XCTAssertEqual(rendered, "The user just interrupted with: \"stop\"")
    }

    func testImmediateRender_turnsRenderedNewestFirstWithoutBargeIn() {
        // Without a barge-in, recent turns iterate newest-first and insert at the front, so
        // the newest turn appears before the older one.
        let buffer = ImmediateBuffer(
            recentTurns: [
                ConversationTurn(role: .user, content: "OLD"),
                ConversationTurn(role: .assistant, content: "NEW")
            ]
        )
        let rendered = buffer.render(tokenBudget: 10_000)
        XCTAssertEqual(rendered, "[Assistant]: NEW\n\n[User]: OLD")
    }

    // MARK: - WorkingBuffer.render

    func testWorkingRender_includesAllSectionsWithAmpleBudget() {
        let buffer = WorkingBuffer(
            topicTitle: "Cells",
            topicContent: "The basic unit of life.",
            learningObjectives: ["Define a cell", "List organelles"],
            glossaryTerms: [GlossaryTerm(term: "Nucleus", definition: "control center")],
            misconceptionTriggers: [
                MisconceptionTrigger(
                    triggerPhrase: "cells are tiny animals",
                    misconception: "category error",
                    remediation: "cells are units, not organisms"
                )
            ]
        )

        let rendered = buffer.render(tokenBudget: 10_000)
        let expected = [
            "Topic: Cells\nThe basic unit of life.",
            "Learning Objectives:\n- Define a cell\n- List organelles",
            "Key Terms:\n- Nucleus: control center",
            "Watch for these common misconceptions:\n" +
                "- If student says 'cells are tiny animals': cells are units, not organisms"
        ].joined(separator: "\n\n")
        XCTAssertEqual(rendered, expected)
    }

    func testWorkingRender_tinyBudgetKeepsOnlyTitleSection() {
        // The title section is always appended unconditionally. Optional sections require
        // estimatedTokens < tokenBudget, so a budget of 0 drops every optional section.
        let buffer = WorkingBuffer(
            topicTitle: "Cells",
            topicContent: "Basic unit.",
            learningObjectives: ["Define a cell"],
            glossaryTerms: [GlossaryTerm(term: "Nucleus", definition: "control center")]
        )
        let rendered = buffer.render(tokenBudget: 0)
        XCTAssertEqual(rendered, "Topic: Cells\nBasic unit.")
    }

    func testWorkingRender_emptyOptionalSectionsAreOmitted() {
        // With no objectives, glossary, or misconceptions, only the title section appears.
        let buffer = WorkingBuffer(topicTitle: "Solo", topicContent: "Only this.")
        let rendered = buffer.render(tokenBudget: 10_000)
        XCTAssertEqual(rendered, "Topic: Solo\nOnly this.")
    }

    // MARK: - EpisodicBuffer.render

    func testEpisodicRender_learnerSignalsRenderedFirst() {
        let signals = LearnerSignals(pacePreference: .fast)
        let buffer = EpisodicBuffer(
            topicSummaries: [
                FOVTopicSummary(topicId: UUID(), title: "T1", summary: "s1", masteryLevel: 0.5)
            ],
            learnerSignals: signals
        )
        let rendered = buffer.render(tokenBudget: 10_000)
        // Learner signals render first, then the topic summaries block, joined by a blank line.
        XCTAssertEqual(
            rendered,
            "Learner profile: Preferred pace: fast\n\nTopics covered:\n- T1: s1"
        )
    }

    func testEpisodicRender_topicSummariesUseSuffixOfFive() {
        // Six summaries provided, only the last five appear (suffix(5)). The first must be
        // dropped while the last five remain.
        let summaries = (1...6).map {
            FOVTopicSummary(topicId: UUID(), title: "T\($0)", summary: "s\($0)", masteryLevel: 0.5)
        }
        let buffer = EpisodicBuffer(topicSummaries: summaries)
        let rendered = buffer.render(tokenBudget: 10_000)

        XCTAssertFalse(rendered.contains("- T1: s1"))
        for index in 2...6 {
            XCTAssertTrue(rendered.contains("- T\(index): s\(index)"), "expected summary T\(index)")
        }
    }

    func testEpisodicRender_userQuestionsUseSuffixOfThree() {
        // Four questions provided, only the last three render (suffix(3)).
        let questions = (1...4).map {
            UserQuestion(question: "Q\($0)", wasAnswered: false)
        }
        let buffer = EpisodicBuffer(userQuestions: questions)
        let rendered = buffer.render(tokenBudget: 10_000)

        XCTAssertFalse(rendered.contains("- Q1"))
        XCTAssertTrue(rendered.contains("Student's earlier questions:\n- Q2\n- Q3\n- Q4"))
    }

    func testEpisodicRender_emptyBufferRendersEmptyString() {
        let buffer = EpisodicBuffer()
        XCTAssertEqual(buffer.render(tokenBudget: 10_000), "")
    }

    // MARK: - SemanticBuffer.render

    func testSemanticRender_positionAlwaysRenderedAndOutlineIncludedWhenWithinBudget() {
        let buffer = SemanticBuffer(
            curriculumOutline: "Unit 1, Unit 2",
            currentPosition: CurriculumPosition(
                curriculumTitle: "Biology",
                currentTopicIndex: 0,
                totalTopics: 4
            )
        )
        let rendered = buffer.render(tokenBudget: 10_000)
        // Position (index 0 of 4 -> Int((1/4)*100) = 25%) renders first, then the untruncated
        // outline, joined by a blank line. No ellipsis because the outline fits the budget.
        XCTAssertEqual(
            rendered,
            "Course: Biology | Progress: Topic 1 of 4 (25%)\n\nCourse outline:\nUnit 1, Unit 2"
        )
    }

    func testSemanticRender_outlineTruncatedWhenExceedingBudget() {
        // The outline is 80 chars (20 tokens). The position renders "Course: B" (9 chars),
        // and available = tokenBudget - parts.joined().count/4. With tokenBudget 5 and the
        // position consuming 9/4 = 2 tokens, available = 3, which is less than the outline's
        // 20 tokens, so the outline is truncated to available*4 = 12 chars plus "...".
        let outline = String(repeating: "x", count: 80)
        let buffer = SemanticBuffer(
            curriculumOutline: outline,
            currentPosition: CurriculumPosition(curriculumTitle: "B")
        )
        let rendered = buffer.render(tokenBudget: 5)

        // Position renders "Course: B" (no unit, totalTopics 0 so no progress line).
        // available = 5 - "Course: B".count/4 = 5 - 9/4 = 5 - 2 = 3 tokens.
        // truncatedLength = 3 * 4 = 12, so 12 x's plus the ellipsis.
        let expected = "Course: B\n\nCourse outline:\n" + String(repeating: "x", count: 12) + "..."
        XCTAssertEqual(rendered, expected)
        XCTAssertFalse(rendered.contains(outline))
    }

    // MARK: - LearnerSignals.render

    func testLearnerSignalsRender_emptyReturnsEmptyString() {
        XCTAssertEqual(LearnerSignals().render(), "")
    }

    func testLearnerSignalsRender_paceAndStyleLines() {
        let signals = LearnerSignals(
            pacePreference: .slow,
            explanationStylePreference: .analogy
        )
        XCTAssertEqual(
            signals.render(),
            "Learner profile: Preferred pace: slow; Prefers analogy explanations"
        )
    }

    func testLearnerSignalsRender_clarificationThresholdIsStrictlyGreaterThanTwo() {
        // 2 clarification requests produce no line, 3 produce the line.
        let atThreshold = LearnerSignals(clarificationRequests: 2)
        XCTAssertEqual(atThreshold.render(), "")

        let aboveThreshold = LearnerSignals(clarificationRequests: 3)
        XCTAssertEqual(
            aboveThreshold.render(),
            "Learner profile: Has asked for clarification 3 times"
        )
    }

    func testLearnerSignalsRender_repetitionThresholdIsStrictlyGreaterThanOne() {
        // 1 repetition request produces no line, 2 produce the line.
        let atThreshold = LearnerSignals(repetitionRequests: 1)
        XCTAssertEqual(atThreshold.render(), "")

        let aboveThreshold = LearnerSignals(repetitionRequests: 2)
        XCTAssertEqual(
            aboveThreshold.render(),
            "Learner profile: Has requested repetition 2 times"
        )
    }

    // MARK: - CurriculumPosition.render

    func testCurriculumPositionRender_emptyReturnsEmptyString() {
        XCTAssertEqual(CurriculumPosition().render(), "")
    }

    func testCurriculumPositionRender_progressPercentageMath() {
        // Index 4 of 10 topics: progress = Int((4 + 1) / 10 * 100) = 50.
        let position = CurriculumPosition(
            curriculumTitle: "Algebra",
            currentTopicIndex: 4,
            totalTopics: 10,
            currentUnitTitle: "Linear Equations"
        )
        XCTAssertEqual(
            position.render(),
            "Course: Algebra | Unit: Linear Equations | Progress: Topic 5 of 10 (50%)"
        )
    }

    func testCurriculumPositionRender_progressOmittedWhenNoTotalTopics() {
        // With totalTopics 0 the progress line is suppressed even though an index exists.
        let position = CurriculumPosition(
            curriculumTitle: "Geometry",
            currentTopicIndex: 3,
            totalTopics: 0
        )
        XCTAssertEqual(position.render(), "Course: Geometry")
    }

    // MARK: - ConversationTurn.init(from: LLMMessage)

    func testConversationTurnFromMessage_mapsRolesAndCopiesContent() {
        let cases: [(messageRole: LLMMessage.Role, expected: ConversationTurn.Role)] = [
            (.user, .user),
            (.assistant, .assistant),
            (.system, .system)
        ]

        for testCase in cases {
            let message = LLMMessage(role: testCase.messageRole, content: "payload-\(testCase.messageRole.rawValue)")
            let turn = ConversationTurn(from: message)
            XCTAssertEqual(turn.role, testCase.expected)
            XCTAssertEqual(turn.content, "payload-\(testCase.messageRole.rawValue)")
        }
    }

    // MARK: - ExpansionResult / RetrievedContent token estimation

    func testRetrievedContent_estimatedTokensIsContentCountOverFour() {
        // 12-character content -> 12 / 4 = 3 tokens.
        let content = RetrievedContent(
            sourceTitle: "Source",
            content: "123456789012",
            relevanceScore: 0.9
        )
        XCTAssertEqual(content.estimatedTokens, 3)
    }

    func testExpansionResult_totalTokensIsSumOfRetrievedEstimates() {
        // Contents of 8 chars (2 tokens) and 4 chars (1 token) -> total 3 tokens.
        let result = ExpansionResult(
            query: "what is x",
            scope: .currentTopic,
            retrievedContent: [
                RetrievedContent(sourceTitle: "A", content: "12345678", relevanceScore: 0.5),
                RetrievedContent(sourceTitle: "B", content: "1234", relevanceScore: 0.4)
            ]
        )
        XCTAssertEqual(result.totalTokens, 3)
    }
}
