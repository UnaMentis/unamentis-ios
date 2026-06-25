// UnaMentis - FOVContextManager Behavior Tests
//
// Exercises the REAL FOVContextManager actor, the component that assembles the
// hierarchical LLM context for a voice tutoring turn. These tests focus on
// manager-level logic that the buffer value-type tests in FOVContextTests.swift
// do not cover:
//   - buildContext turn-count capping per model tier and barge-in ordering
//   - model/tier reconfiguration changing the cap buildContext applies
//   - expandWorkingBuffer append behavior (and its empty-input no-op)
//   - episodic trimming limits (topic completions and user questions cap at 10)
//   - learner-signal thresholds surfacing in episodic content (clarification > 2,
//     repetition > 1)
//   - compressEpisodicBuffer no-op without a summarizer and the 3-into-1 merge
//     (with mastery averaging) when a real ContextSummarizer is wired up
//   - reset vs resetImmediateBuffer scope
//   - the static buildSystemPrompt conditional sections and exact boundaries
//
// The only mocked dependency is the paid LLM API, via MockLLMService from the
// shared Helpers, used to back a REAL ContextSummarizer for the compression test.

import XCTest
@testable import UnaMentis

final class FOVContextManagerBehaviorTests: XCTestCase {

    // MARK: - buildContext: turn-count capping + barge-in ordering

    /// A cloud tier (128k) keeps at most 10 verbatim turns. With a longer history,
    /// immediateBufferTurnCount must be capped at 10 and only the most recent turns
    /// must appear in the rendered immediate context.
    func testBuildContext_capsTurnCountToCloudTierAndKeepsMostRecent() async {
        let manager = FOVContextManager(modelContextWindow: 128_000)

        // 14 turns, each uniquely identifiable by index.
        var history: [LLMMessage] = []
        for i in 0..<14 {
            history.append(LLMMessage(role: .user, content: "TURN_MARKER_\(i)"))
        }

        let context = await manager.buildContext(conversationHistory: history)

        // Cloud tier conversationTurnCount is 10, history is 14, so cap to 10.
        XCTAssertEqual(context.immediateBufferTurnCount, 10)

        // The oldest 4 turns (0...3) must be dropped, the last 10 (4...13) kept.
        XCTAssertFalse(context.immediateContext.contains("TURN_MARKER_3"))
        XCTAssertTrue(context.immediateContext.contains("TURN_MARKER_4"))
        XCTAssertTrue(context.immediateContext.contains("TURN_MARKER_13"))
    }

    /// When the history is shorter than the tier cap, the count reflects the actual
    /// history length, not the cap.
    func testBuildContext_turnCountIsHistoryLengthWhenBelowCap() async {
        let manager = FOVContextManager(modelContextWindow: 128_000)

        let history = [
            LLMMessage(role: .user, content: "only one"),
            LLMMessage(role: .assistant, content: "and a reply")
        ]

        let context = await manager.buildContext(conversationHistory: history)

        XCTAssertEqual(context.immediateBufferTurnCount, 2)
    }

    /// The barge-in utterance is always rendered first in the immediate context,
    /// ahead of recent conversation turns.
    func testBuildContext_bargeInRendersBeforeRecentTurns() async {
        let manager = FOVContextManager(modelContextWindow: 128_000)
        let history = [LLMMessage(role: .assistant, content: "PRIOR_ASSISTANT_LINE")]

        let context = await manager.buildContext(
            conversationHistory: history,
            bargeInUtterance: "WAIT_INTERRUPT"
        )

        let bargeInRange = context.immediateContext.range(of: "WAIT_INTERRUPT")
        let priorRange = context.immediateContext.range(of: "PRIOR_ASSISTANT_LINE")
        XCTAssertNotNil(bargeInRange, "Barge-in utterance must appear")
        XCTAssertNotNil(priorRange, "Prior turn must appear")
        if let bargeInRange, let priorRange {
            XCTAssertLessThan(
                bargeInRange.lowerBound,
                priorRange.lowerBound,
                "Barge-in must be rendered before the recent turn"
            )
        }
        // ImmediateBuffer.render wraps the barge-in with this framing.
        XCTAssertTrue(context.immediateContext.contains("interrupted"))
    }

    /// systemPrompt on the built context is exactly the base prompt supplied at init.
    func testBuildContext_systemPromptIsBasePrompt() async {
        let basePrompt = "CUSTOM_BASE_SYSTEM_PROMPT_XYZ"
        let manager = FOVContextManager(
            modelContextWindow: 128_000,
            baseSystemPrompt: basePrompt
        )

        let context = await manager.buildContext()

        XCTAssertEqual(context.systemPrompt, basePrompt)
        // The custom prompt must be honored, not silently replaced by the default.
        XCTAssertNotEqual(context.systemPrompt, FOVContextManager.defaultSystemPrompt)
    }

    // MARK: - Model / tier reconfiguration changes the applied cap

    /// forModel("gpt-4o") yields a cloud-tier manager (cap 10).
    func testForModel_gpt4oProducesCloudTier() async {
        let manager = FOVContextManager.forModel("gpt-4o")

        let config = await manager.getBudgetConfig()
        XCTAssertEqual(config.tier, .cloud)
        XCTAssertEqual(config.conversationTurnCount, 10)
    }

    /// Switching the context window from an on-device window (8000 -> onDevice,
    /// cap 5) to a cloud window (128000 -> cloud, cap 10) changes the cap that
    /// buildContext applies to the same history.
    func testUpdateContextWindow_changesTurnCapAppliedByBuildContext() async {
        let manager = FOVContextManager(modelContextWindow: 8_000)

        // Confirm starting tier.
        let onDeviceConfig = await manager.getBudgetConfig()
        XCTAssertEqual(onDeviceConfig.tier, .onDevice)
        XCTAssertEqual(onDeviceConfig.conversationTurnCount, 5)

        // 12 turns of history exceeds both caps.
        var history: [LLMMessage] = []
        for i in 0..<12 {
            history.append(LLMMessage(role: .user, content: "H\(i)"))
        }

        let onDeviceContext = await manager.buildContext(conversationHistory: history)
        XCTAssertEqual(onDeviceContext.immediateBufferTurnCount, 5)

        // Reconfigure to a cloud window.
        await manager.updateContextWindow(128_000)
        let cloudConfig = await manager.getBudgetConfig()
        XCTAssertEqual(cloudConfig.tier, .cloud)

        let cloudContext = await manager.buildContext(conversationHistory: history)
        XCTAssertEqual(cloudContext.immediateBufferTurnCount, 10)
    }

    /// updateModelConfig classifies by the model's known context window.
    func testUpdateModelConfig_reclassifiesTier() async {
        let manager = FOVContextManager(modelContextWindow: 128_000)
        let startTier = await manager.getBudgetConfig().tier
        XCTAssertEqual(startTier, .cloud)

        // ministral -> 8_192 -> onDevice tier.
        await manager.updateModelConfig(model: "ministral-3b")
        let newTier = await manager.getBudgetConfig().tier
        XCTAssertEqual(newTier, .onDevice)
    }

    // MARK: - Working buffer + expansion

    /// updateWorkingBuffer makes topic title, content, and objectives appear in the
    /// working context of a built context.
    func testUpdateWorkingBuffer_surfacesTopicContentAndObjectives() async {
        let manager = FOVContextManager(modelContextWindow: 128_000)

        await manager.updateWorkingBuffer(
            topicTitle: "Newton's Laws",
            topicContent: "An object in motion stays in motion.",
            learningObjectives: ["Define inertia", "Apply F equals m a"]
        )

        let context = await manager.buildContext()
        XCTAssertTrue(context.workingContext.contains("Newton's Laws"))
        XCTAssertTrue(context.workingContext.contains("object in motion"))
        XCTAssertTrue(context.workingContext.contains("Define inertia"))
    }

    /// expandWorkingBuffer appends an "## Additional Context" section containing the
    /// retrieved items' source title and content.
    func testExpandWorkingBuffer_appendsAdditionalContextSection() async {
        let manager = FOVContextManager(modelContextWindow: 128_000)
        await manager.updateWorkingBuffer(
            topicTitle: "Photosynthesis",
            topicContent: "Plants use light."
        )

        await manager.expandWorkingBuffer(with: [
            RetrievedContent(
                sourceTitle: "Chloroplast Notes",
                content: "Chlorophyll absorbs red and blue light.",
                relevanceScore: 0.9
            )
        ])

        let context = await manager.buildContext()
        XCTAssertTrue(context.workingContext.contains("## Additional Context"))
        XCTAssertTrue(context.workingContext.contains("Chloroplast Notes"))
        XCTAssertTrue(context.workingContext.contains("Chlorophyll absorbs"))
    }

    /// Expanding with empty content is a no-op: no "Additional Context" marker added.
    func testExpandWorkingBuffer_emptyContentDoesNotAppend() async {
        let manager = FOVContextManager(modelContextWindow: 128_000)
        await manager.updateWorkingBuffer(
            topicTitle: "Topic",
            topicContent: "Base content."
        )

        await manager.expandWorkingBuffer(with: [])

        let context = await manager.buildContext()
        XCTAssertFalse(context.workingContext.contains("## Additional Context"))
        XCTAssertTrue(context.workingContext.contains("Base content."))
    }

    // MARK: - Semantic buffer

    /// updateSemanticBuffer surfaces the curriculum position render and outline.
    func testUpdateSemanticBuffer_surfacesPositionAndOutline() async {
        let manager = FOVContextManager(modelContextWindow: 128_000)

        await manager.updateSemanticBuffer(
            curriculumOutline: "1. Cells\n2. Genetics\n3. Evolution",
            position: CurriculumPosition(
                curriculumTitle: "Biology 101",
                currentTopicIndex: 1,
                totalTopics: 3
            )
        )

        let context = await manager.buildContext()
        XCTAssertTrue(context.semanticContext.contains("Biology 101"))
        // CurriculumPosition.render reports a 1-based "Topic N of M" and an integer
        // percent: Int((2 / 3) * 100) == 66.
        XCTAssertTrue(context.semanticContext.contains("Topic 2 of 3 (66%)"))
        XCTAssertTrue(context.semanticContext.contains("Genetics"))
    }

    // MARK: - Episodic trimming limits

    /// recordTopicCompletion keeps at most the last 10 summaries, dropping the oldest.
    /// The episodic render only surfaces the most recent 5 (topicSummaries.suffix(5)),
    /// so the oldest completions must never appear and the most recent must.
    func testRecordTopicCompletion_dropsOldestAndKeepsMostRecent() async {
        let manager = FOVContextManager(modelContextWindow: 128_000)

        // Zero-padded titles so an old marker is never a substring of a kept one
        // (for example "TOPIC_01" is not a substring of "TOPIC_11").
        for i in 0..<12 {
            await manager.recordTopicCompletion(
                FOVTopicSummary(
                    topicId: UUID(),
                    title: String(format: "TOPIC_%02d", i),
                    summary: "summary \(i)",
                    masteryLevel: 0.5
                )
            )
        }

        let context = await manager.buildContext()
        // The oldest completions are dropped well outside the rendered window.
        XCTAssertFalse(context.episodicContext.contains("TOPIC_00"))
        XCTAssertFalse(context.episodicContext.contains("TOPIC_01"))
        // The most recent completions survive and render.
        XCTAssertTrue(context.episodicContext.contains("TOPIC_11"))
        XCTAssertTrue(context.episodicContext.contains("TOPIC_10"))
    }

    /// The 10-summary retention cap (vs the render window of 5) is observable through
    /// compression: with 12 completions the buffer still holds 10 (> 5), so
    /// compressEpisodicBuffer merges the first 3 into "Earlier topics". If the buffer
    /// were trimmed to 5 or fewer no merge would happen, so the merge proves > 5 retained.
    func testRecordTopicCompletion_retainsMoreThanRenderWindow() async {
        let mockLLM = MockLLMService()
        await mockLLM.configure(summaryResponse: "MERGED_OLD")
        let summarizer = ContextSummarizer(llmService: mockLLM)
        let manager = FOVContextManager(
            modelContextWindow: 128_000,
            summarizer: summarizer
        )

        for i in 0..<12 {
            await manager.recordTopicCompletion(
                FOVTopicSummary(
                    topicId: UUID(),
                    title: "TOPIC_\(i)",
                    summary: "summary \(i)",
                    masteryLevel: 0.5
                )
            )
        }

        await manager.compressEpisodicBuffer()

        // The merge ran, so more than 5 summaries were retained after the 12 records.
        let callCount = await mockLLM.streamCompletionCallCount
        XCTAssertEqual(callCount, 1)
    }

    /// recordUserQuestion caps stored questions at 10 and drops the oldest. The render
    /// surfaces only the last 3, so the oldest questions never appear and the most
    /// recent do.
    func testRecordUserQuestion_dropsOldestAndKeepsMostRecent() async {
        let manager = FOVContextManager(modelContextWindow: 128_000)

        // Zero-padded so an old marker is never a substring of a kept one.
        for i in 0..<12 {
            await manager.recordUserQuestion(String(format: "QUESTION_%02d", i))
        }

        let context = await manager.buildContext()
        // Render surfaces only the last 3 questions (suffix(3) = 09, 10, 11).
        XCTAssertFalse(context.episodicContext.contains("QUESTION_00"))
        XCTAssertFalse(context.episodicContext.contains("QUESTION_08"))
        XCTAssertTrue(context.episodicContext.contains("QUESTION_11"))
    }

    // MARK: - Learner-signal thresholds in episodic content

    /// Clarification note appears in episodic content only when the count exceeds 2.
    /// LearnerSignals.render gates on clarificationRequests > 2.
    func testRecordClarificationRequest_appearsOnlyAboveThreshold() async {
        let manager = FOVContextManager(modelContextWindow: 128_000)

        // Two requests: at threshold, not above. No clarification line.
        await manager.recordClarificationRequest()
        await manager.recordClarificationRequest()
        var context = await manager.buildContext()
        XCTAssertFalse(context.episodicContext.contains("clarification"))

        // Third request crosses the > 2 boundary. LearnerSignals.render emits the
        // exact count, so assert the precise phrasing, not just the word.
        await manager.recordClarificationRequest()
        context = await manager.buildContext()
        XCTAssertTrue(context.episodicContext.contains("Has asked for clarification 3 times"))
    }

    /// Repetition note appears only when the count exceeds 1 (> 1 boundary).
    func testRecordRepetitionRequest_appearsOnlyAboveThreshold() async {
        let manager = FOVContextManager(modelContextWindow: 128_000)

        // One repetition: at boundary, not above.
        await manager.recordRepetitionRequest()
        var context = await manager.buildContext()
        XCTAssertFalse(context.episodicContext.contains("repetition"))

        // Second repetition crosses > 1. Assert the exact rendered count phrasing.
        await manager.recordRepetitionRequest()
        context = await manager.buildContext()
        XCTAssertTrue(context.episodicContext.contains("Has requested repetition 2 times"))
    }

    // MARK: - compressEpisodicBuffer

    /// With no summarizer configured, compression is a no-op: no "Earlier topics"
    /// merge entry is produced and the recent summaries render unchanged.
    func testCompressEpisodicBuffer_noSummarizerIsNoOp() async {
        let manager = FOVContextManager(modelContextWindow: 128_000)

        for i in 0..<6 {
            await manager.recordTopicCompletion(
                FOVTopicSummary(
                    topicId: UUID(),
                    title: "T\(i)",
                    summary: "s\(i)",
                    masteryLevel: 0.4
                )
            )
        }

        await manager.compressEpisodicBuffer()

        let context = await manager.buildContext()
        // No summarizer means no merge: no "Earlier topics" entry appears, and the
        // most recent original summary still renders.
        XCTAssertFalse(context.episodicContext.contains("Earlier topics"))
        XCTAssertTrue(context.episodicContext.contains("T5"))
    }

    /// With a real ContextSummarizer (backed by the paid-API mock) and more than 5
    /// summaries, compression merges the first 3 into a single "Earlier topics" entry
    /// using the summarizer's returned text, and leaves the rest. With exactly 6
    /// inputs the post-merge buffer has 4 entries, all within the render window of 5,
    /// so the merge is fully observable through buildContext.
    func testCompressEpisodicBuffer_mergesFirstThreeIntoEarlierTopics() async {
        let mockLLM = MockLLMService()
        await mockLLM.configure(summaryResponse: "CONDENSED_EARLIER_TOPICS")
        let summarizer = ContextSummarizer(llmService: mockLLM)

        let manager = FOVContextManager(
            modelContextWindow: 128_000,
            summarizer: summarizer
        )

        // Six uniquely-titled summaries; the first three (T0, T1, T2) are merged.
        for i in 0..<6 {
            await manager.recordTopicCompletion(
                FOVTopicSummary(
                    topicId: UUID(),
                    title: "T\(i)",
                    summary: "body \(i)",
                    masteryLevel: 0.5
                )
            )
        }

        await manager.compressEpisodicBuffer()

        let context = await manager.buildContext()
        // The merged entry uses the configured summarizer output.
        XCTAssertTrue(context.episodicContext.contains("Earlier topics"))
        XCTAssertTrue(context.episodicContext.contains("CONDENSED_EARLIER_TOPICS"))
        // The first three originals were replaced by the merge.
        XCTAssertFalse(context.episodicContext.contains("T0:"))
        XCTAssertFalse(context.episodicContext.contains("T1:"))
        XCTAssertFalse(context.episodicContext.contains("T2:"))
        // The untouched tail survives.
        XCTAssertTrue(context.episodicContext.contains("T3"))
        XCTAssertTrue(context.episodicContext.contains("T5"))

        // The summarizer (and thus the paid-API mock) was actually invoked once.
        let callCount = await mockLLM.streamCompletionCallCount
        XCTAssertEqual(callCount, 1)
    }

    /// With 5 or fewer summaries, compression does nothing even with a summarizer,
    /// because the merge guard requires more than 5.
    func testCompressEpisodicBuffer_belowThresholdDoesNotMerge() async {
        let mockLLM = MockLLMService()
        let summarizer = ContextSummarizer(llmService: mockLLM)
        let manager = FOVContextManager(
            modelContextWindow: 128_000,
            summarizer: summarizer
        )

        for i in 0..<5 {
            await manager.recordTopicCompletion(
                FOVTopicSummary(
                    topicId: UUID(),
                    title: "T\(i)",
                    summary: "s\(i)",
                    masteryLevel: 0.5
                )
            )
        }

        await manager.compressEpisodicBuffer()

        // 5 is not greater than 5, so the merge guard fails: no summarizer call,
        // and no "Earlier topics" entry is produced.
        let context = await manager.buildContext()
        XCTAssertFalse(context.episodicContext.contains("Earlier topics"))
        let callCount = await mockLLM.streamCompletionCallCount
        XCTAssertEqual(callCount, 0)
    }

    // MARK: - reset vs resetImmediateBuffer

    /// reset clears all four buffers: a subsequent build has empty immediate, working,
    /// episodic, and semantic content.
    func testReset_clearsAllBuffers() async {
        let manager = FOVContextManager(modelContextWindow: 128_000)
        await manager.updateWorkingBuffer(
            topicTitle: "WORK_TITLE",
            topicContent: "work body"
        )
        await manager.updateSemanticBuffer(
            curriculumOutline: "SEM_OUTLINE",
            position: CurriculumPosition(curriculumTitle: "SEM_COURSE", totalTopics: 2)
        )
        await manager.recordUserQuestion("EPISODIC_Q")

        await manager.reset()

        let context = await manager.buildContext(
            conversationHistory: [LLMMessage(role: .user, content: "IMM_LINE")]
        )
        XCTAssertFalse(context.workingContext.contains("WORK_TITLE"))
        XCTAssertFalse(context.semanticContext.contains("SEM_COURSE"))
        XCTAssertFalse(context.episodicContext.contains("EPISODIC_Q"))
    }

    /// resetImmediateBuffer clears only the immediate buffer; working and semantic
    /// state survive.
    func testResetImmediateBuffer_preservesWorkingAndSemantic() async {
        let manager = FOVContextManager(modelContextWindow: 128_000)
        await manager.updateWorkingBuffer(
            topicTitle: "KEEP_WORK",
            topicContent: "kept body"
        )
        await manager.updateSemanticBuffer(
            curriculumOutline: "kept outline",
            position: CurriculumPosition(curriculumTitle: "KEEP_COURSE", totalTopics: 3)
        )

        await manager.resetImmediateBuffer()

        // A build with a fresh barge-in shows the new immediate, while working and
        // semantic context still carry the earlier state.
        let context = await manager.buildContext(bargeInUtterance: "NEW_BARGE_IN")
        XCTAssertTrue(context.immediateContext.contains("NEW_BARGE_IN"))
        XCTAssertTrue(context.workingContext.contains("KEEP_WORK"))
        XCTAssertTrue(context.semanticContext.contains("KEEP_COURSE"))
    }

    // MARK: - Static buildSystemPrompt

    /// The teachback assessment block is always present, regardless of inputs.
    func testBuildSystemPrompt_alwaysIncludesTeachback() {
        let prompt = FOVContextManager.buildSystemPrompt()
        XCTAssertTrue(prompt.contains("TEACHBACK ASSESSMENT"))
    }

    /// When a depth is provided, its displayName, aiInstructions, and math style are
    /// injected. When absent, the CONTENT DEPTH header is not present.
    func testBuildSystemPrompt_depthSectionConditional() {
        let withDepth = FOVContextManager.buildSystemPrompt(depth: .advanced)
        XCTAssertTrue(withDepth.contains("CONTENT DEPTH: \(ContentDepth.advanced.displayName)"))
        XCTAssertTrue(withDepth.contains(ContentDepth.advanced.aiInstructions))
        XCTAssertTrue(withDepth.contains("MATH PRESENTATION: \(ContentDepth.advanced.mathPresentationStyle)"))

        let withoutDepth = FOVContextManager.buildSystemPrompt(depth: nil)
        XCTAssertFalse(withoutDepth.contains("CONTENT DEPTH:"))
    }

    /// Learning objectives are numbered 1., 2., ... when present, and the section is
    /// absent when the list is empty.
    func testBuildSystemPrompt_learningObjectivesNumbered() {
        let prompt = FOVContextManager.buildSystemPrompt(
            learningObjectives: ["Understand cells", "Explain mitosis"]
        )
        XCTAssertTrue(prompt.contains("LEARNING OBJECTIVES FOR THIS SESSION:"))
        XCTAssertTrue(prompt.contains("1. Understand cells"))
        XCTAssertTrue(prompt.contains("2. Explain mitosis"))

        let none = FOVContextManager.buildSystemPrompt(learningObjectives: [])
        XCTAssertFalse(none.contains("LEARNING OBJECTIVES FOR THIS SESSION:"))
    }

    /// Misconception triggers are listed as bullet lines when present, absent otherwise.
    func testBuildSystemPrompt_misconceptionTriggersBulleted() {
        let prompt = FOVContextManager.buildSystemPrompt(
            misconceptionTriggers: ["Heavier objects fall faster", "Plants eat soil"]
        )
        XCTAssertTrue(prompt.contains("COMMON MISCONCEPTIONS TO WATCH FOR:"))
        XCTAssertTrue(prompt.contains("- Heavier objects fall faster"))
        XCTAssertTrue(prompt.contains("- Plants eat soil"))

        let none = FOVContextManager.buildSystemPrompt(misconceptionTriggers: [])
        XCTAssertFalse(none.contains("COMMON MISCONCEPTIONS TO WATCH FOR:"))
    }

    /// LEARNER SIGNALS section appears only when clarificationRequests > 2. Boundary:
    /// 2 clarifications produces no note, 3 produces the note.
    func testBuildSystemPrompt_clarificationSignalBoundary() {
        let atBoundary = FOVContextManager.buildSystemPrompt(
            learnerSignals: LearnerSignals(clarificationRequests: 2)
        )
        XCTAssertFalse(atBoundary.contains("LEARNER SIGNALS:"))

        let aboveBoundary = FOVContextManager.buildSystemPrompt(
            learnerSignals: LearnerSignals(clarificationRequests: 3)
        )
        XCTAssertTrue(aboveBoundary.contains("LEARNER SIGNALS:"))
        XCTAssertTrue(aboveBoundary.contains("asked for 3 clarifications"))
    }

    /// LEARNER SIGNALS section appears only when repetitionRequests > 1. Boundary:
    /// 1 repetition produces no note, 2 produces the note.
    func testBuildSystemPrompt_repetitionSignalBoundary() {
        let atBoundary = FOVContextManager.buildSystemPrompt(
            learnerSignals: LearnerSignals(repetitionRequests: 1)
        )
        XCTAssertFalse(atBoundary.contains("LEARNER SIGNALS:"))

        let aboveBoundary = FOVContextManager.buildSystemPrompt(
            learnerSignals: LearnerSignals(repetitionRequests: 2)
        )
        XCTAssertTrue(aboveBoundary.contains("LEARNER SIGNALS:"))
        XCTAssertTrue(aboveBoundary.contains("asked for 2 repetitions"))
    }
}
