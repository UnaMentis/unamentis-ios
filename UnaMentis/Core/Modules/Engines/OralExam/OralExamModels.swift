// UnaMentis - Oral Exam Engine Models
// MODULE_SDK_SPEC.md section 6.2, engine "oral-exam/1"
//
// The value types the OralExamEngine consumes and emits. All are
// module-agnostic: the engine has zero knowledge of Oral Exam Studio or any
// other module. Modules adapt their syllabus content onto `OralExamTopic`
// and render `OralExamEvent`s however their UI wants, exactly the boundary
// QuizMatchEngine draws for quiz formats.

import Foundation

// MARK: - Topic

/// One syllabus topic as the engine sees it: what the learner presents on and
/// what grounds the examiner's questions. Modules map their pack items
/// (schema `oral-syllabus/1`) onto this.
public struct OralExamTopic: Sendable, Equatable, Identifiable {
    /// Stable item identifier (feeds AttemptRecord.itemId).
    public let id: String

    /// The topic title the session announces.
    public let title: String

    /// Seed material summary: the syllabus context the examiner grounds
    /// questions and rubric scoring in.
    public let summary: String

    /// Exemplar jury questions from the pack's question pool. The examiner
    /// grounds root questions in these plus the learner's own words.
    public let exemplarQuestions: [String]

    /// Pack-supplied hints about what strong answers look like per rubric
    /// dimension, fed to rubric evaluation.
    public let rubricHints: [String]

    /// The knowledge domain for proficiency roll-up (maps to StandardDomain).
    /// Nil reports under a generic domain.
    public let domain: String?

    public init(
        id: String,
        title: String,
        summary: String,
        exemplarQuestions: [String],
        rubricHints: [String] = [],
        domain: String? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.exemplarQuestions = exemplarQuestions
        self.rubricHints = rubricHints
        self.domain = domain
    }
}

// MARK: - Session Mode

/// Which slice of the exam this session runs
/// (ORAL_EXAM_STUDIO_MODULE_SPEC.md section 3).
public enum OralExamSessionMode: Sendable, Equatable {
    /// The complete exam flow with the descriptor's stages and timing.
    case fullSimulation

    /// One stage in isolation with immediate coaching.
    case stagePractice(OralExamFormatDescriptor.Stage.Kind)

    /// Rapid follow-up-question practice: the questioning stage only, bounded
    /// by a root-question count rather than the stage clock alone.
    case questionVolley(rootQuestions: Int)
}

// MARK: - Exchange

/// One examiner question and the learner's answer to it.
public struct OralExamExchange: Sendable, Equatable {
    public let question: String
    public let answer: String

    /// 0 for a root question, 1+ for grounded follow-ups.
    public let followUpDepth: Int

    public init(question: String, answer: String, followUpDepth: Int) {
        self.question = question
        self.answer = answer
        self.followUpDepth = followUpDepth
    }
}

// MARK: - Feedback

/// The post-attempt feedback package (ORAL_EXAM_STUDIO_MODULE_SPEC.md
/// section 5): per-dimension rubric scores each with one improvement action,
/// a short spoken summary, and engine-computed delivery metrics.
///
/// Scores are practice signals. Consumers must never present them as
/// predictions of real exam grades.
public struct OralExamFeedback: Sendable, Equatable {
    /// Per-dimension rubric scores with one improvement action each.
    public let scores: [RubricScore]

    /// The spoken feedback summary (target under 60 seconds when read).
    public let spokenSummary: String

    /// Mechanics-of-speaking metrics, computed from transcript timing.
    public let deliveryMetrics: OralExamDeliveryMetrics

    public init(
        scores: [RubricScore],
        spokenSummary: String,
        deliveryMetrics: OralExamDeliveryMetrics
    ) {
        self.scores = scores
        self.spokenSummary = spokenSummary
        self.deliveryMetrics = deliveryMetrics
    }

    /// Mean rubric score across dimensions (0 when there are none).
    public var averageScore: Double {
        guard !scores.isEmpty else { return 0 }
        return Double(scores.reduce(0) { $0 + $1.score }) / Double(scores.count)
    }
}

// MARK: - Summary

/// Final state of a completed (or stopped) oral exam session.
public struct OralExamSummary: Sendable, Equatable {
    /// Stages that ran to their end (timer or early completion).
    public let stagesCompleted: Int

    /// Examiner questions asked (root plus follow-ups).
    public let questionsAsked: Int

    /// Learner utterance segments captured across all stages.
    public let responsesCaptured: Int

    /// Total session duration.
    public let duration: TimeInterval

    /// The assembled feedback, when the session captured enough to score.
    public let feedback: OralExamFeedback?

    public init(
        stagesCompleted: Int,
        questionsAsked: Int,
        responsesCaptured: Int,
        duration: TimeInterval,
        feedback: OralExamFeedback?
    ) {
        self.stagesCompleted = stagesCompleted
        self.questionsAsked = questionsAsked
        self.responsesCaptured = responsesCaptured
        self.duration = duration
        self.feedback = feedback
    }
}

// MARK: - Events

/// Everything the engine tells its consumer. The engine is UI-agnostic: a
/// module view model renders these however it wants.
public enum OralExamEvent: Sendable {
    /// The session began, with the stages it will run.
    case sessionStarted(stageCount: Int)

    /// A stage began. `seconds` is the effective (option-scaled) duration.
    case stageStarted(index: Int, kind: OralExamFormatDescriptor.Stage.Kind, seconds: TimeInterval)

    /// Periodic stage-clock progress (about 10 Hz), for countdown UI.
    case timerTick(remaining: TimeInterval, progress: Double)

    /// A spoken-milestone point was reached (hands-free pattern: 30/15/10
    /// seconds remaining, plus 300/60 for long exam stages).
    case timerMilestone(secondsRemaining: Int)

    /// A final-countdown tick point was reached (hands-free pattern: 5-1).
    case timerCountdownTick(secondsRemaining: Int)

    /// The engine spoke a prompt (stage introduction or root question).
    case promptSpoken(text: String, personaIndex: Int)

    /// The examiner asked a grounded follow-up (spoken like a prompt; depth
    /// is 1+).
    case followUpAsked(question: String, depth: Int, personaIndex: Int)

    /// The engine is capturing one learner utterance segment.
    case listeningStarted(stageIndex: Int)

    /// One learner utterance segment was captured.
    case responseCaptured(stageIndex: Int, transcript: String, endedBy: UtteranceResult.EndReason)

    /// A stage ended. `endedEarly` is true when a command (ready/done) or a
    /// volley count ended it before the stage clock.
    case stageEnded(index: Int, kind: OralExamFormatDescriptor.Stage.Kind, endedEarly: Bool)

    /// Rubric feedback was assembled (emitted before any spoken summary).
    case feedbackReady(OralExamFeedback)

    /// Prompt narration failed (surfaced, never silence).
    case speakFailed(message: String)

    /// Speech capture failed (surfaced, never swallowed).
    case listenFailed(message: String)

    /// The examiner brain failed (question generation or rubric scoring).
    case examinerFailed(message: String)

    /// The session paused / resumed (watch control plane integration points).
    case paused
    case resumed

    /// The session ended (all stages ran, or it was stopped).
    case sessionEnded(summary: OralExamSummary)
}

// MARK: - Engine State

/// The engine's phase within a session.
public enum OralExamEngineState: Sendable, Equatable {
    case idle
    case preparing(stageIndex: Int)
    case presenting(stageIndex: Int)
    case questioning(stageIndex: Int)
    case assemblingFeedback
    case ended
}

// MARK: - Host Context

/// The host services the engine emits progress and telemetry through, plus
/// the module identity that namespaces them (MODULE_SDK_SPEC.md sections 5.4
/// and 5.6). Injected so the engine stays host-agnostic and headless-testable
/// (the QuizMatchHostContext pattern).
public struct OralExamHostContext: Sendable {
    /// The module ID that namespaces attempts and telemetry.
    public let moduleId: String

    public let progress: any ProgressStoreService
    public let telemetry: any ModuleTelemetryService

    public init(
        moduleId: String,
        progress: any ProgressStoreService,
        telemetry: any ModuleTelemetryService
    ) {
        self.moduleId = moduleId
        self.progress = progress
        self.telemetry = telemetry
    }
}

// MARK: - Session Options

/// Per-session knobs on top of the format descriptor.
public struct OralExamSessionOptions: Sendable {
    /// Multiplier applied to stage durations (practice sessions run scaled
    /// timers; 1.0 is exam-faithful).
    public let timeScale: Double

    /// Rate at which the stage clock progresses relative to wall time.
    /// 1.0 is real time; headless test harnesses accelerate it so milestone
    /// and expiry behavior is testable without waiting out real stages.
    public let clockRate: Double

    /// Whether the engine speaks the feedback summary aloud after assembling
    /// it (voice-first default). Headless drivers may turn this off.
    public let speakFeedbackSummary: Bool

    public init(
        timeScale: Double = 1.0,
        clockRate: Double = 1.0,
        speakFeedbackSummary: Bool = true
    ) {
        self.timeScale = max(0.01, timeScale)
        self.clockRate = max(0.01, clockRate)
        self.speakFeedbackSummary = speakFeedbackSummary
    }
}
