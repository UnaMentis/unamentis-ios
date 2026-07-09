// UnaMentis - Quiz Match Engine Models
// MODULE_SDK_SPEC.md section 6.1, engine "quiz-match/1"
//
// The value types the QuizMatchEngine consumes and emits. All are
// module-agnostic: the engine has zero knowledge of Knowledge Bowl, Quiz
// Bowl, or any other format. Modules adapt their content onto
// `QuizMatchQuestion` (carrying a host `EvaluationSpec`) and render
// `QuizMatchEvent`s however their UI wants.

import Foundation

// MARK: - Questions

/// One oral question as the engine sees it: presentation text (plus optional
/// pre-rendered audio), how to judge answers to it, and format extras
/// (power mark, attached bonus).
public struct QuizMatchQuestion: Sendable, Identifiable {
    /// Stable item identifier (feeds AttemptRecord.itemId).
    public let id: String

    /// The question text the session speaks.
    public let text: String

    /// Server-pregenerated or cached audio for the question, when available.
    public let preRenderedAudio: PreRenderedAudio?

    /// What a response to this question is judged against.
    public let evaluation: EvaluationSpec

    /// The knowledge domain this question exercises, for proficiency roll-up
    /// (maps to `StandardDomain`). Nil skips proficiency reporting.
    public let domain: String?

    /// Character index of the power mark for pyramidal formats: a correct
    /// answer on a buzz before this index scores the power value. Nil for
    /// short-form questions and unpowered tossups.
    public let powerMarkIndex: Int?

    /// The bonus awarded for answering this question correctly, in formats
    /// with bonuses. Nil otherwise.
    public let bonus: QuizMatchBonus?

    public init(
        id: String,
        text: String,
        preRenderedAudio: PreRenderedAudio? = nil,
        evaluation: EvaluationSpec,
        domain: String? = nil,
        powerMarkIndex: Int? = nil,
        bonus: QuizMatchBonus? = nil
    ) {
        self.id = id
        self.text = text
        self.preRenderedAudio = preRenderedAudio
        self.evaluation = evaluation
        self.domain = domain
        self.powerMarkIndex = powerMarkIndex
        self.bonus = bonus
    }
}

/// A multi-part bonus attached to a question.
public struct QuizMatchBonus: Sendable {
    public struct Part: Sendable {
        public let text: String
        public let evaluation: EvaluationSpec

        public init(text: String, evaluation: EvaluationSpec) {
            self.text = text
            self.evaluation = evaluation
        }
    }

    /// Optional lead-in read before the first part.
    public let leadIn: String?
    public let parts: [Part]

    public init(leadIn: String? = nil, parts: [Part]) {
        self.leadIn = leadIn
        self.parts = parts
    }
}

/// Supplies questions to the engine by index (0-based). Return nil to end the
/// match early. Backed by a module's ContentStore-selected question list.
public typealias QuizMatchQuestionProvider = @Sendable (Int) async -> QuizMatchQuestion?

// MARK: - Judgment

/// The engine's ruling on one answer.
public struct QuizMatchJudgment: Sendable {
    /// The full host evaluation result.
    public let evaluation: EvaluationResult

    /// The answer text that was judged.
    public let answerText: String

    /// Whether the ruling was correct.
    public var isCorrect: Bool { evaluation.verdict == .correct }

    /// Points awarded for this answer (may be negative for interrupt negs).
    public let pointsAwarded: Int

    /// Whether the answer came from a buzz before the power mark (pyramidal).
    public let wasPower: Bool

    /// Whether the answer came from a buzz before the question finished.
    public let wasInterrupt: Bool

    /// Which participant answered.
    public let participant: Int

    /// Time from answer window opening to submission, in milliseconds.
    public let responseTimeMs: Int

    public init(
        evaluation: EvaluationResult,
        answerText: String,
        pointsAwarded: Int,
        wasPower: Bool,
        wasInterrupt: Bool,
        participant: Int,
        responseTimeMs: Int
    ) {
        self.evaluation = evaluation
        self.answerText = answerText
        self.pointsAwarded = pointsAwarded
        self.wasPower = wasPower
        self.wasInterrupt = wasInterrupt
        self.participant = participant
        self.responseTimeMs = responseTimeMs
    }
}

// MARK: - Summary

/// Final state of a completed (or stopped) match.
public struct QuizMatchSummary: Sendable {
    /// Final score per participant slot.
    public let scores: [Int]

    /// Number of questions that received a submitted answer.
    public let answeredQuestions: Int

    /// Number of answers judged correct.
    public let correctAnswers: Int

    /// Total match duration.
    public let duration: TimeInterval

    public init(scores: [Int], answeredQuestions: Int, correctAnswers: Int, duration: TimeInterval) {
        self.scores = scores
        self.answeredQuestions = answeredQuestions
        self.correctAnswers = correctAnswers
        self.duration = duration
    }
}

// MARK: - Events

/// Everything the engine tells its consumer. The engine is UI-agnostic: a
/// module view model renders these however it wants (screens, TTS feedback,
/// watch progress).
public enum QuizMatchEvent: Sendable {
    /// The match began.
    case matchStarted(totalQuestions: Int)

    /// A question is up and about to be read.
    case questionPresented(index: Int, question: QuizMatchQuestion)

    /// Question narration finished. `interrupted` is true when narration was
    /// cut short by a skip or a buzz.
    case questionReadingFinished(index: Int, interrupted: Bool)

    /// Conference (deliberation) time began.
    case conferenceStarted(seconds: TimeInterval)

    /// Periodic conference progress (about 10 Hz), for countdown UI.
    case conferenceTick(remaining: TimeInterval, progress: Double)

    /// A spoken-milestone point was reached (hands-free pattern: 30/15/10).
    case conferenceMilestone(secondsRemaining: Int)

    /// A final-countdown tick point was reached (hands-free pattern: 5-1).
    case conferenceCountdownTick(secondsRemaining: Int)

    /// Conference ended. `skipped` is true when a participant ended it early.
    case conferenceEnded(skipped: Bool)

    /// The answer window opened (speech capture follows when the session's
    /// auto-listen option is on; headless harnesses drive it explicitly).
    case answerWindowOpened(index: Int)

    /// The answer window is open and the engine is capturing speech.
    case listeningStarted(index: Int)

    /// Speech capture ended without a submitted answer (user stopped the mic;
    /// any partial transcript stays with the consumer).
    case listeningStopped(index: Int)

    /// A complete utterance was captured; the consumer may submit or re-listen.
    case answerCaptured(transcript: String)

    /// Speech capture failed (surfaced, never swallowed).
    case listenFailed(message: String)

    /// Question or bonus narration failed (surfaced, never silence).
    case speakFailed(message: String)

    /// An answer was judged.
    case evaluated(index: Int, judgment: QuizMatchJudgment)

    /// The current question was skipped without an answer (no attempt is
    /// recorded, matching solo-practice semantics).
    case answerSkipped(index: Int)

    /// Scores changed.
    case scoreChanged(scores: [Int])

    /// An incorrect answer opened the question to another participant
    /// (descriptor rebound rules; only with more than one participant).
    case reboundOffered(toParticipant: Int)

    /// A bonus sequence began.
    case bonusStarted(index: Int, partCount: Int)

    /// One bonus part is up and was read.
    case bonusPartPresented(part: Int, text: String)

    /// One bonus part was judged.
    case bonusPartEvaluated(part: Int, correct: Bool, points: Int)

    /// The bonus sequence finished.
    case bonusCompleted(totalPoints: Int)

    /// The match paused / resumed (watch control plane integration points).
    case paused
    case resumed

    /// The match ended (all questions played, provider exhausted, or stopped).
    case matchEnded(summary: QuizMatchSummary)
}

// MARK: - Engine State

/// The engine's phase within one question cycle.
public enum QuizMatchEngineState: Sendable, Equatable {
    case idle
    case readingQuestion(index: Int)
    case conference(index: Int)
    case awaitingAnswer(index: Int)
    case feedback(index: Int)
    case bonus(index: Int, part: Int)
    case ended
}

// MARK: - Host Context

/// The host services the engine emits progress and telemetry through,
/// plus the module identity that namespaces them (MODULE_SDK_SPEC.md
/// sections 5.4 and 5.6). Injected so the engine stays host-agnostic and
/// headless-testable.
public struct QuizMatchHostContext: Sendable {
    /// The module ID that namespaces attempts and telemetry.
    public let moduleId: String

    public let evaluation: any ResponseEvaluationService
    public let progress: any ProgressStoreService
    public let telemetry: any ModuleTelemetryService

    public init(
        moduleId: String,
        evaluation: any ResponseEvaluationService,
        progress: any ProgressStoreService,
        telemetry: any ModuleTelemetryService
    ) {
        self.moduleId = moduleId
        self.evaluation = evaluation
        self.progress = progress
        self.telemetry = telemetry
    }
}

// MARK: - Session Options

/// Per-session knobs on top of the format descriptor.
public struct QuizMatchSessionOptions: Sendable {
    /// Number of questions this session plays. Practice sessions choose their
    /// own count; competition sessions use the descriptor's oral default.
    public let questionCount: Int

    /// Number of scoring participants (1 for solo practice).
    public let participantCount: Int

    /// Whether the engine starts capturing speech as soon as the answer
    /// window opens (KB oral practice behavior). Headless harnesses turn
    /// this off and drive `startListening`/`submitAnswer` explicitly.
    public let autoListen: Bool

    public init(questionCount: Int, participantCount: Int = 1, autoListen: Bool = true) {
        self.questionCount = questionCount
        self.participantCount = max(1, participantCount)
        self.autoListen = autoListen
    }
}
