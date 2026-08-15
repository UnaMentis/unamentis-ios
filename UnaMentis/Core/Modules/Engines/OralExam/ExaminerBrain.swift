// UnaMentis - Examiner Brain
// MODULE_SDK_SPEC.md section 6.2: the adaptive-questioning seam.
//
// The OralExamEngine owns the stage state machine; WHAT the examiner asks and
// HOW rubric scores are produced is delegated to an injected ExaminerBrain.
// This keeps the engine deterministic and headless-testable, and it keeps LLM
// routing out of engine code entirely: the production brain (module-side)
// rides the app's LLM policy, tests inject a scripted brain, and the
// rule-based brain below is the offline Tier 0 floor.
//
// Grounding requirement (ORAL_EXAM_STUDIO_MODULE_SPEC.md section 4): follow-up
// questions must derive from the syllabus item, the exam's question pool, and
// the learner's own words. Generic questions are a defect. Every brain
// receives the full ExaminerContext so it has no excuse.

import Foundation

// MARK: - Context

/// Everything an examiner brain may ground a question or a rubric evaluation
/// in. Built by the engine per call.
public struct ExaminerContext: Sendable {
    /// The syllabus topic under examination.
    public let topic: OralExamTopic

    /// The exam's language (BCP-47), from the descriptor.
    public let language: String

    /// The examiner register from the descriptor ("formal", "encouraging",
    /// "strict").
    public let register: String

    /// Number of examiner personas (a jury of two alternates voices).
    public let personaCount: Int

    /// The learner's presentation transcript so far (empty in volley mode).
    public let presentationTranscript: String

    /// The question/answer exchange so far, oldest first.
    public let exchange: [OralExamExchange]

    /// The depth of the question being requested: 0 for a new root question,
    /// 1+ for a follow-up grounded in the learner's latest answer.
    public let followUpDepth: Int

    public init(
        topic: OralExamTopic,
        language: String,
        register: String,
        personaCount: Int,
        presentationTranscript: String,
        exchange: [OralExamExchange],
        followUpDepth: Int
    ) {
        self.topic = topic
        self.language = language
        self.register = register
        self.personaCount = personaCount
        self.presentationTranscript = presentationTranscript
        self.exchange = exchange
        self.followUpDepth = followUpDepth
    }
}

// MARK: - Question

/// A question the examiner asks, attributed to a persona so multi-juror
/// formats can alternate voices.
public struct ExaminerQuestion: Sendable, Equatable {
    public let text: String

    /// Which persona asks (0-based, below the descriptor's personaCount).
    public let personaIndex: Int

    public init(text: String, personaIndex: Int) {
        self.text = text
        self.personaIndex = personaIndex
    }
}

// MARK: - Brain Protocol

/// Generates grounded examiner questions and rubric evaluations for the
/// OralExamEngine.
public protocol ExaminerBrain: Sendable {
    /// The next question to ask. `context.followUpDepth` of 0 requests a new
    /// root question; 1+ requests a follow-up grounded in the learner's
    /// latest answer (`context.exchange.last`).
    func nextQuestion(_ context: ExaminerContext) async throws -> ExaminerQuestion

    /// Score the session against the rubric dimensions, returning 0-5 per
    /// dimension, one improvement action per dimension, and a spoken summary
    /// under 60 seconds when read.
    func evaluateRubric(
        _ context: ExaminerContext,
        rubric: [String],
        deliveryMetrics: OralExamDeliveryMetrics
    ) async throws -> RubricFeedback
}

// MARK: - Rule-Based Brain (offline Tier 0 floor)

/// A deterministic, fully offline examiner: root questions come from the
/// topic's exemplar question pool, follow-ups quote the learner's own words
/// into fixed probe templates, and rubric scores are transparent heuristics
/// over the delivery metrics and transcript volume.
///
/// This is the graceful degradation path when no LLM is reachable (spec goal
/// 2, server-optional by construction) and the deterministic brain the
/// conformance suite drives. It is deliberately honest about being shallow:
/// its feedback labels itself as offline coaching.
public struct RuleBasedExaminerBrain: ExaminerBrain {
    public init() {}

    public func nextQuestion(_ context: ExaminerContext) async throws -> ExaminerQuestion {
        let personaIndex = context.exchange.count % max(1, context.personaCount)

        if context.followUpDepth == 0 {
            let rootsAsked = context.exchange.filter { $0.followUpDepth == 0 }.count
            let pool = context.topic.exemplarQuestions
            let text: String
            if pool.isEmpty {
                text = "Please explain the main idea of \(context.topic.title) in your own words."
            } else {
                text = pool[rootsAsked % pool.count]
            }
            return ExaminerQuestion(text: text, personaIndex: personaIndex)
        }

        // Follow-up: quote the learner's own words back into a probe template
        // (grounding floor: the learner's answer plus the topic, never a
        // free-floating generic question).
        let lastAnswer = context.exchange.last?.answer ?? ""
        let quoted = Self.leadingWords(of: lastAnswer, count: 8)
        let templates = [
            "You said \"%@\". Can you develop that point further?",
            "You mentioned \"%@\". How does that connect to \(context.topic.title)?",
            "Going back to \"%@\": what evidence supports that claim?"
        ]
        let template = templates[(context.followUpDepth - 1) % templates.count]
        let text = quoted.isEmpty
            ? "Could you say more about how that relates to \(context.topic.title)?"
            : String(format: template, quoted)
        return ExaminerQuestion(text: text, personaIndex: personaIndex)
    }

    public func evaluateRubric(
        _ context: ExaminerContext,
        rubric: [String],
        deliveryMetrics metrics: OralExamDeliveryMetrics
    ) async throws -> RubricFeedback {
        let answeredCount = context.exchange.filter { !$0.answer.isEmpty }.count
        let scores = rubric.map { dimension in
            RubricScore(
                dimension: dimension,
                score: Self.heuristicScore(for: dimension, metrics: metrics, answeredCount: answeredCount),
                improvementAction: Self.improvementAction(for: dimension, metrics: metrics)
            )
        }
        let summary = Self.summary(scores: scores, metrics: metrics)
        return RubricFeedback(scores: scores, spokenSummary: summary)
    }

    // MARK: Heuristics

    /// Comfortable spoken-exam pace band, words per minute.
    static let comfortablePace = 110.0...170.0

    static func heuristicScore(
        for dimension: String,
        metrics: OralExamDeliveryMetrics,
        answeredCount: Int
    ) -> Int {
        var score = 3
        switch dimension.lowercased() {
        case "delivery":
            if metrics.wordsPerMinute > 0, comfortablePace.contains(metrics.wordsPerMinute) { score += 1 }
            if metrics.fillerWordCount > 8 { score -= 1 }
            if metrics.hesitationCount > 4 { score -= 1 }
        case "clarity":
            if metrics.fillerWordCount > 8 { score -= 1 }
            if metrics.wordCount >= 120 { score += 1 }
        case "interaction":
            if answeredCount >= 3 { score += 1 }
            if answeredCount == 0 { score -= 2 }
        case "structure", "argumentation":
            if metrics.wordCount >= 200 { score += 1 }
            if metrics.wordCount < 40 { score -= 1 }
        default:
            break
        }
        return min(5, max(0, score))
    }

    static func improvementAction(for dimension: String, metrics: OralExamDeliveryMetrics) -> String {
        switch dimension.lowercased() {
        case "delivery":
            if metrics.wordsPerMinute > comfortablePace.upperBound {
                return "Slow down: aim for roughly 140 words per minute."
            }
            if metrics.fillerWordCount > 4 {
                return "Replace filler words with a silent pause before key points."
            }
            return "Vary your pace to emphasize the ideas that matter most."
        case "clarity":
            return "Open each answer with its conclusion, then give your reasons."
        case "structure":
            return "Signpost your plan up front and return to it as you move between parts."
        case "argumentation":
            return "Back each claim with one concrete example or piece of evidence."
        case "interaction":
            return "Reference the examiner's exact words when you answer a follow-up."
        default:
            return "Rehearse this dimension once more and compare your two attempts."
        }
    }

    static func summary(scores: [RubricScore], metrics: OralExamDeliveryMetrics) -> String {
        let strongest = scores.max { $0.score < $1.score }
        let weakest = scores.min { $0.score < $1.score }
        var parts: [String] = ["Offline coaching summary."]
        if let strongest {
            parts.append("Your strongest dimension this attempt was \(strongest.dimension).")
        }
        if let weakest {
            parts.append("Focus next on \(weakest.dimension): \(weakest.improvementAction)")
        }
        if metrics.wordsPerMinute > 0 {
            parts.append("You spoke at about \(Int(metrics.wordsPerMinute)) words per minute.")
        }
        if metrics.fillerWordCount > 0 {
            parts.append("I counted \(metrics.fillerWordCount) filler words.")
        }
        parts.append("These scores are practice signals, not a prediction of a real exam grade.")
        return parts.joined(separator: " ")
    }

    /// The first `count` words of a learner answer, for quoting back.
    static func leadingWords(of text: String, count: Int) -> String {
        let words = text.split(separator: " ").prefix(count)
        return words.joined(separator: " ")
    }
}
