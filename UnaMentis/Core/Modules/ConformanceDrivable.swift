// UnaMentis - Conformance Drivability
// The headless-driving seam the UM-Voice conformance suite drives modules through.
//
// MODULE_SDK_SPEC.md section 9 requires that "every activity marked voice-first
// completes with zero touch events". The spec does not, however, name the API a
// conformance harness uses to run a module's voice activity without SwiftUI.
// This protocol is that API: a small, UI-free entry point a module adopts so its
// primary voice-first activity can run driven ONLY by a host VoiceSession (the
// scripted one in tests, the real unified pipeline in production).
//
// Design (ratified deviation, tracked for the RFC process, see
// docs/ios/MODULE_AUTHORING.md and the Phase 6 RFC):
// - The spec's audio-only surface (section 8) is "not a view surface"; a module
//   declaring it "commits that its voice-first activities run to completion with
//   the screen locked, driven entirely by VoiceSession". `ConformanceDrivable`
//   makes that commitment executable: the same code path the audio-only surface
//   uses in production is the one conformance drives.
// - The activity receives an already-acquired VoiceSession. The HOST owns
//   acquisition and release (section 5.1 exclusivity); the module never
//   instantiates audio. This keeps the "one voice pipeline" invariant (goal 3)
//   true even in the headless path.
// - The activity returns a `ConformanceRunResult` the suite asserts on: whether
//   the primary activity reached completion, how many attempts it evaluated, and
//   the module-scoped voice states it exercised (so command-vocabulary checks
//   have something concrete to inspect).

import Foundation

// MARK: - Drivable Module

/// A module that can run its primary voice-first activity headlessly, driven
/// only through a host `VoiceSession` (MODULE_SDK_SPEC.md sections 8 and 9).
///
/// Modules whose manifest declares a voice-first experience (voiceCoverage above
/// zero, or the `audio-only` surface) adopt this so the UM-Voice conformance
/// level can certify that the experience completes with zero touch events.
public protocol ConformanceDrivable: ModuleProtocol {
    /// Identity of the primary voice-first activity this module exposes for
    /// headless driving (e.g. "oral-practice", "echo-drill"). Reported in
    /// telemetry and used by the conformance suite for logging.
    var primaryVoiceActivity: ModuleActivityKind { get }

    /// The unified command vocabulary this activity claims (a subset of
    /// `VoiceCommand`, e.g. `[.quit, .skip]`). The conformance suite verifies the
    /// activity honors each claimed command. Empty means the activity claims no
    /// commands beyond the always-available host defaults.
    var claimedVoiceCommands: Set<VoiceCommand> { get }

    /// Run the primary voice-first activity to completion, driven only by the
    /// supplied session. The activity MUST NOT make any UI/touch calls: it speaks
    /// prompts, listens for answers, evaluates through the host, records attempts,
    /// and ends by releasing nothing (the host owns the session lifecycle).
    ///
    /// - Parameters:
    ///   - host: the host services bundle (progress, evaluation, telemetry). The
    ///     same bundle passed to `initialize(host:)`.
    ///   - session: an already-acquired VoiceSession. The activity speaks and
    ///     listens through this and never acquires or releases it.
    ///   - script: the scripted interaction the harness feeds. See
    ///     `ConformanceVoiceScript`. In production the audio-only surface passes
    ///     `.live` (no scripted expectations).
    /// - Returns: what the run accomplished, for the suite to assert on.
    func runPrimaryVoiceActivity(
        host: ModuleHost,
        session: any VoiceSession,
        script: ConformanceVoiceScript
    ) async throws -> ConformanceRunResult
}

// MARK: - Script

/// The scripted interaction a headless conformance run consumes.
///
/// This is intentionally minimal: the harness's `ScriptedVoiceSession` already
/// owns utterance/command injection (transcripts are enqueued on it directly).
/// The script carries only run-shaping knobs the module needs up front, so the
/// module code path is identical to production apart from these values.
public struct ConformanceVoiceScript: Sendable {
    /// How many rounds/questions the activity should run before summarizing.
    /// Nil means "the activity's own default" (production / `.live`).
    public var roundCount: Int?

    /// Whether this is a live (production) run with no scripted expectations.
    /// Modules generally ignore this; it exists so the same entry point serves
    /// both the audio-only surface and the conformance harness.
    public var isLive: Bool

    public init(roundCount: Int? = nil, isLive: Bool = false) {
        self.roundCount = roundCount
        self.isLive = isLive
    }

    /// A live production script (audio-only surface): the activity's own defaults.
    public static let live = ConformanceVoiceScript(roundCount: nil, isLive: true)
}

// MARK: - Result

/// What a headless voice-activity run accomplished, for conformance assertions.
public struct ConformanceRunResult: Sendable, Equatable {
    /// Whether the primary activity reached its natural completion (summary
    /// spoken, no error). The core UM-Voice pass/fail signal.
    public let completed: Bool

    /// Number of learner responses the activity evaluated (attempts). UM-Voice
    /// requires at least one, and requires matching `module.attempt` telemetry.
    public let attemptsEvaluated: Int

    /// The module-scoped voice states the activity entered, in first-seen order.
    /// Lets the suite confirm the activity actually drove distinct states.
    public let voiceStatesEntered: [ModuleVoiceState]

    /// The unified commands the activity observed and acted on during the run
    /// (e.g. a scripted "skip"). Used to verify claimed-command honoring.
    public let commandsHonored: Set<VoiceCommand>

    public init(
        completed: Bool,
        attemptsEvaluated: Int,
        voiceStatesEntered: [ModuleVoiceState] = [],
        commandsHonored: Set<VoiceCommand> = []
    ) {
        self.completed = completed
        self.attemptsEvaluated = attemptsEvaluated
        self.voiceStatesEntered = voiceStatesEntered
        self.commandsHonored = commandsHonored
    }
}
