// UnaMentis - Drill Engine Models
// MODULE_SDK_SPEC.md section 6.3, engine "drill/1"
//
// The value types the DrillEngine consumes and emits. All are module-agnostic:
// the engine has zero knowledge of SAT Prep, Aural Skills, or any future
// flash-card module. Modules adapt their pack content onto `DrillItem` (carrying
// a host `EvaluationSpec` and a skill tag) and render `DrillEvent`s however their
// UI wants. This mirrors the QuizMatchEngine models (section 6.1) so the two
// engines stay shaped alike.

import Foundation

// MARK: - Items

/// One drill item as the engine sees it: a spoken prompt (plus optional
/// pre-rendered audio and on-screen text), how to judge answers to it, and the
/// skill tag that both roll up proficiency and drives review ordering.
public struct DrillItem: Sendable, Identifiable {
    /// Stable item identifier (feeds AttemptRecord.itemId).
    public let id: String

    /// The prompt text the session speaks (a question answerable in a word or a
    /// short phrase for voice-friendly drills).
    public let prompt: String

    /// Optional text to display on screen. Defaults to `prompt` when nil. Lets a
    /// drill show a compact form (an equation) while speaking a longer read-out.
    public let displayText: String?

    /// Server-pregenerated or cached audio for the prompt, when available.
    public let preRenderedAudio: PreRenderedAudio?

    /// What a response to this item is judged against (numeric for math items,
    /// text-fuzzy for verbal items). The module builds this per item.
    public let evaluation: EvaluationSpec

    /// The skill tag this item exercises. Rolls up proficiency (maps to
    /// `StandardDomain`) AND drives review-policy ordering (items are sorted by
    /// ascending stored mastery for this tag). Nonempty in practice.
    public let skillTag: String

    /// The knowledge domain this item exercises, for proficiency roll-up. When
    /// nil, `skillTag` is used as the domain.
    public let domain: String?

    public init(
        id: String,
        prompt: String,
        displayText: String? = nil,
        preRenderedAudio: PreRenderedAudio? = nil,
        evaluation: EvaluationSpec,
        skillTag: String,
        domain: String? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.displayText = displayText
        self.preRenderedAudio = preRenderedAudio
        self.evaluation = evaluation
        self.skillTag = skillTag
        self.domain = domain
    }

    /// The domain this item rolls proficiency up to (`domain` or `skillTag`).
    public var effectiveDomain: String { domain ?? skillTag }

    /// The text to show on screen (`displayText` or `prompt`).
    public var effectiveDisplayText: String { displayText ?? prompt }
}

/// Supplies drill items to the engine. The module builds the ordered item list
/// (applying the scheduling policy against the ProgressStore) and hands it to the
/// engine, so the engine stays free of any content or persistence dependency.
public typealias DrillItemProvider = @Sendable () async -> [DrillItem]

// MARK: - Judgment

/// The engine's ruling on one drill answer.
public struct DrillJudgment: Sendable {
    /// The full host evaluation result.
    public let evaluation: EvaluationResult

    /// The answer text that was judged.
    public let answerText: String

    /// Whether the ruling was correct.
    public var isCorrect: Bool { evaluation.verdict == .correct }

    /// Time from prompt end to submission, in milliseconds.
    public let responseTimeMs: Int

    /// The streak length after this answer (consecutive correct; 0 on a miss).
    public let streak: Int

    public init(
        evaluation: EvaluationResult,
        answerText: String,
        responseTimeMs: Int,
        streak: Int
    ) {
        self.evaluation = evaluation
        self.answerText = answerText
        self.responseTimeMs = responseTimeMs
        self.streak = streak
    }
}

// MARK: - Summary

/// Final state of a completed (or stopped) drill round.
public struct DrillSummary: Sendable {
    /// Number of items that received a submitted answer.
    public let answeredItems: Int

    /// Number of answers judged correct.
    public let correctAnswers: Int

    /// The longest streak reached during the round.
    public let bestStreak: Int

    /// Total round duration.
    public let duration: TimeInterval

    public init(answeredItems: Int, correctAnswers: Int, bestStreak: Int, duration: TimeInterval) {
        self.answeredItems = answeredItems
        self.correctAnswers = correctAnswers
        self.bestStreak = bestStreak
        self.duration = duration
    }
}

// MARK: - Events

/// Everything the engine tells its consumer. The engine is UI-agnostic: a module
/// view model renders these however it wants (screens, TTS feedback, watch
/// progress). Names follow the DrillEvent set the task specifies.
public enum DrillEvent: Sendable {
    /// The round began.
    case roundStarted(totalItems: Int)

    /// An item is up and about to be presented (spoken and/or shown).
    case itemPresented(index: Int, item: DrillItem)

    /// The answer window opened for the item at `index`: the prompt finished and
    /// the engine will accept an answer (speech capture follows when the session's
    /// auto-listen option is on; headless drivers submit explicitly here).
    case answerWindowOpened(index: Int)

    /// The engine is capturing a spoken answer for the item at `index`.
    case listening(index: Int)

    /// Speech capture ended without a submitted answer (the mic stopped; any
    /// partial transcript stays with the consumer).
    case listeningStopped(index: Int)

    /// A complete utterance was captured; the consumer may submit or re-listen.
    case answerCaptured(transcript: String)

    /// Speech capture failed (surfaced, never swallowed).
    case listenFailed(message: String)

    /// Prompt narration failed (surfaced, never silence).
    case speakFailed(message: String)

    /// An answer was judged.
    case evaluated(index: Int, judgment: DrillJudgment)

    /// The current item was skipped without an answer (no attempt is recorded).
    case itemSkipped(index: Int)

    /// The running streak changed (grew on a correct answer, reset to 0 on a
    /// miss or skip).
    case streakChanged(streak: Int)

    /// The round paused / resumed (watch control plane integration points).
    case paused
    case resumed

    /// The round ended (all items played, provider exhausted, or stopped).
    case roundEnded(summary: DrillSummary)
}

// MARK: - Engine State

/// The engine's phase within one item cycle.
public enum DrillEngineState: Sendable, Equatable {
    case idle
    case presenting(index: Int)
    case awaitingAnswer(index: Int)
    case feedback(index: Int)
    case ended
}

// MARK: - Host Context

/// The host services the engine emits progress and telemetry through, plus the
/// module identity that namespaces them (MODULE_SDK_SPEC.md sections 5.4 and
/// 5.6). Injected so the engine stays host-agnostic and headless-testable. Same
/// shape as QuizMatchHostContext so a module wires either engine identically.
public struct DrillHostContext: Sendable {
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
public struct DrillSessionOptions: Sendable {
    /// The activity kind this drill reports in telemetry (e.g. "vocab-drill").
    public let activityKind: ModuleActivityKind

    /// Whether the engine starts capturing speech as soon as an item is
    /// presented (voice-first behavior). Headless harnesses turn this off and
    /// drive `startListening`/`submitAnswer` explicitly, as QuizMatch does.
    public let autoListen: Bool

    public init(activityKind: ModuleActivityKind, autoListen: Bool = true) {
        self.activityKind = activityKind
        self.autoListen = autoListen
    }
}
