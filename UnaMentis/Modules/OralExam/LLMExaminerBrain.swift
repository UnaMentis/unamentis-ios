// UnaMentis - LLM Examiner Brain
// The production ExaminerBrain for Oral Exam Studio.
//
// Question generation and rubric scoring both ride the app's LLM routing
// policy through ModuleLLMResolver (the same path LLMRubricEvaluator uses):
// no provider is hardcoded, cloud versus on-device follows current settings,
// and tests script the LLM per the paid-API mock policy.
//
// Grounding (ORAL_EXAM_STUDIO_MODULE_SPEC.md section 4, a hard requirement):
// every question prompt carries (a) the syllabus item (title, summary,
// exemplar question pool) AND (b) the learner's own words (presentation
// transcript and the latest answer for follow-ups). Generic questions are a
// defect, so the prompt explicitly instructs against them.
//
// AI disclosure (EU AI Act Article 50, MODULE_SDK_SPEC.md section 11): the
// persona system prompt bakes in that the examiner is an AI and must never
// claim to be human, reinforcing the host-level disclosure.

import Foundation
import OSLog

public actor LLMExaminerBrain: ExaminerBrain {
    private let resolveLLM: @Sendable () async throws -> ResolvedModuleLLM
    private let rubricEvaluator: any LLMRubricEvaluating

    /// The deterministic offline brain used when the LLM path fails at
    /// runtime. Resolving an LLM successfully at session start says nothing
    /// about the request that follows: a wrong model id, an expired key, or a
    /// dropped connection must degrade to offline coaching, never end the exam
    /// with empty questions and a wrong grade.
    private let fallback: any ExaminerBrain

    private let logger = Logger(subsystem: "com.unamentis", category: "LLMExaminerBrain")

    /// - Parameters:
    ///   - resolveLLM: supplies the LLM for question generation AND the model
    ///     id valid for it, resolved per call so routing follows current
    ///     settings.
    ///   - rubricEvaluator: the eval.llm-rubric/1 implementation used for
    ///     rubric scoring (production or scripted).
    ///   - fallback: the brain used when the LLM path fails at runtime.
    public init(
        resolveLLM: @escaping @Sendable () async throws -> ResolvedModuleLLM,
        rubricEvaluator: any LLMRubricEvaluating,
        fallback: any ExaminerBrain = RuleBasedExaminerBrain()
    ) {
        self.resolveLLM = resolveLLM
        self.rubricEvaluator = rubricEvaluator
        self.fallback = fallback
    }

    /// The production brain on the app's LLM routing policy.
    public static func production() -> LLMExaminerBrain {
        LLMExaminerBrain(
            resolveLLM: { try await ModuleLLMResolver.resolveDetailed() },
            rubricEvaluator: LLMRubricEvaluator.production()
        )
    }

    /// True once the LLM path has failed and the offline brain took over, so
    /// the UI can label the feedback as offline coaching.
    public private(set) var hasDegradedToFallback = false

    // MARK: - Questions

    public func nextQuestion(_ context: ExaminerContext) async throws -> ExaminerQuestion {
        do {
            return try await llmQuestion(context)
        } catch {
            logger.error(
                "Examiner LLM question failed (\(error.localizedDescription)); using the offline brain"
            )
            hasDegradedToFallback = true
            return try await fallback.nextQuestion(context)
        }
    }

    private func llmQuestion(_ context: ExaminerContext) async throws -> ExaminerQuestion {
        let personaIndex = context.exchange.count % max(1, context.personaCount)
        let resolved = try await resolveLLM()
        let messages = Self.questionMessages(for: context, personaIndex: personaIndex)
        let config = LLMConfig(
            // The provider's own model, never LLMConfig.default's hardcoded
            // OpenAI id: Anthropic and Google reject an unknown model and
            // swallow the error, so the question came back empty.
            model: resolved.model,
            maxTokens: 256,
            temperature: 0.7,
            stream: false
        )
        let raw = try await resolved.service.complete(messages: messages, config: config)
        let text = Self.cleanQuestionText(raw)
        guard !text.isEmpty else {
            throw LLMExaminerError.emptyQuestion
        }
        return ExaminerQuestion(text: text, personaIndex: personaIndex)
    }

    /// The grounded question prompt. Visible for tests, which assert the
    /// grounding contract: syllabus item AND the learner's own words.
    static func questionMessages(
        for context: ExaminerContext,
        personaIndex: Int
    ) -> [LLMMessage] {
        let system = """
        You are examiner persona \(personaIndex + 1) of \(max(1, context.personaCount)) \
        on an oral exam jury, register: \(context.register). You are an AI practice \
        examiner; you must never claim to be human, and if asked you state \
        plainly that you are an AI. Ask exactly ONE question, in the language \
        with BCP-47 tag "\(context.language)", and output only the question \
        text with no preamble. The question MUST be grounded in the syllabus \
        topic and, when the learner has spoken, in the learner's own words; \
        a generic question that could be asked of any topic is a failure.
        """

        var user = """
        Syllabus topic: \(context.topic.title)

        Seed material:
        \(context.topic.summary)
        """

        if !context.topic.exemplarQuestions.isEmpty {
            user += "\n\nExemplar jury questions for this topic:\n"
                + context.topic.exemplarQuestions.map { "- \($0)" }.joined(separator: "\n")
        }

        if !context.presentationTranscript.isEmpty {
            user += "\n\nThe learner's presentation, in their own words:\n\(context.presentationTranscript)"
        }

        if !context.exchange.isEmpty {
            user += "\n\nExchange so far:"
            for pair in context.exchange {
                user += "\nExaminer: \(pair.question)\nLearner: \(pair.answer)"
            }
        }

        if context.followUpDepth > 0, let last = context.exchange.last {
            user += """


            Ask a follow-up question (depth \(context.followUpDepth)) that digs into the \
            learner's latest answer: "\(last.answer)". Reference their actual words or claims.
            """
        } else {
            user += "\n\nAsk a new root question about this topic, informed by the exemplar pool"
                + (context.presentationTranscript.isEmpty
                    ? "." : " and by what the learner chose to emphasize.")
        }

        return [
            LLMMessage(role: .system, content: system),
            LLMMessage(role: .user, content: user)
        ]
    }

    /// Strip quotes/whitespace and keep the first question-like line.
    static func cleanQuestionText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? trimmed
        return firstLine
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    // MARK: - Rubric

    public func evaluateRubric(
        _ context: ExaminerContext,
        rubric: [String],
        deliveryMetrics metrics: OralExamDeliveryMetrics
    ) async throws -> RubricFeedback {
        do {
            return try await llmRubric(context, rubric: rubric, deliveryMetrics: metrics)
        } catch {
            logger.error(
                "Examiner rubric evaluation failed (\(error.localizedDescription)); using the offline brain"
            )
            hasDegradedToFallback = true
            return try await fallback.evaluateRubric(context, rubric: rubric, deliveryMetrics: metrics)
        }
    }

    private func llmRubric(
        _ context: ExaminerContext,
        rubric: [String],
        deliveryMetrics metrics: OralExamDeliveryMetrics
    ) async throws -> RubricFeedback {
        var syllabusContext = context.topic.summary
        if !context.topic.rubricHints.isEmpty {
            syllabusContext += "\n\nWhat strong answers look like:\n"
                + context.topic.rubricHints.map { "- \($0)" }.joined(separator: "\n")
        }

        let metricsSummary = String(
            format: "pace %.0f words/min, %d filler words, %d hesitation gaps, %d words total",
            metrics.wordsPerMinute, metrics.fillerWordCount, metrics.hesitationCount, metrics.wordCount
        )

        let request = LLMRubricRequest(
            rubricDimensions: rubric,
            language: context.language,
            topicTitle: context.topic.title,
            syllabusContext: syllabusContext,
            transcript: context.presentationTranscript,
            exchange: context.exchange.map { ($0.question, $0.answer) },
            deliveryMetricsSummary: metricsSummary
        )
        return try await rubricEvaluator.evaluate(request)
    }
}

/// Typed errors for the LLM examiner.
public enum LLMExaminerError: Error, LocalizedError, Equatable {
    case emptyQuestion

    public var errorDescription: String? {
        switch self {
        case .emptyQuestion:
            return "The examiner model returned an empty question."
        }
    }
}
