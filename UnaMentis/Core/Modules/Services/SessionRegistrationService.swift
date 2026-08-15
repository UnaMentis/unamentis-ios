// UnaMentis - Session Registration Host Service
// MODULE_SDK_SPEC.md section 5.9, capability "session.registration/1"
//
// Module sessions register as first-class app sessions. One contract closes
// three gaps at once (section 5.9):
//   - the Watch control plane (pause/mute/stop, progress) works for module
//     sessions, not just core curriculum sessions;
//   - module sessions appear in the session error-log drill-down;
//   - latency/stability metrics can cover module sessions.
//
// The watch hookup uses the exact same mechanism core sessions use
// (WatchConnectivityService.syncSessionState + setCommandHandler): on begin we
// install the command handler and push initial state; on update we push new
// state; on end we clear the handler and push idle. Only one session holds the
// watch handler at a time, matching the existing single-handler model.
//
// That single slot is arbitrated, not assumed: `begin` hands the slot to the
// newest registration and tells the previous holder it lost it, and `end`
// clears the handler only if this session still owns it. Unconditional
// install/clear let a second module session strip watch control from a live
// first session and then, on ending, leave the first with no control at all.
//
// The watch plane and error sink are injected behind small protocols so the
// service is unit-testable without WatchConnectivity or a live TelemetryEngine.

import Foundation
import Logging

// MARK: - Descriptor and Summary

/// Which controls a registered module session honors from the watch.
public struct ModuleSessionControls: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let pause = ModuleSessionControls(rawValue: 1 << 0)
    public static let mute = ModuleSessionControls(rawValue: 1 << 1)
    public static let stop = ModuleSessionControls(rawValue: 1 << 2)

    /// A voice practice session that can be paused and stopped from the watch.
    public static let voicePractice: ModuleSessionControls = [.pause, .stop]
}

/// What a module tells the host when it begins a session (MODULE_SDK_SPEC.md
/// section 5.9): title, kind, owning module, and supported controls.
public struct ModuleSessionDescriptor: Sendable {
    public let module: String
    public let title: String
    public let activityKind: ModuleActivityKind
    public let controls: ModuleSessionControls
    /// Total units of work (e.g. question count) for the progress ring.
    public let totalUnits: Int

    public init(
        module: String,
        title: String,
        activityKind: ModuleActivityKind,
        controls: ModuleSessionControls,
        totalUnits: Int
    ) {
        self.module = module
        self.title = title
        self.activityKind = activityKind
        self.controls = controls
        self.totalUnits = totalUnits
    }
}

/// Progress reported by a running module session.
public struct ModuleSessionProgress: Sendable {
    /// Completed units (0-based index or count completed).
    public let completedUnits: Int
    public let isPaused: Bool
    public let isMuted: Bool

    public init(completedUnits: Int, isPaused: Bool = false, isMuted: Bool = false) {
        self.completedUnits = completedUnits
        self.isPaused = isPaused
        self.isMuted = isMuted
    }
}

/// Final summary handed to the host at end (MODULE_SDK_SPEC.md section 5.9).
public struct ModuleSessionSummary: Sendable {
    public let completedUnits: Int
    public let duration: TimeInterval

    public init(completedUnits: Int, duration: TimeInterval) {
        self.completedUnits = completedUnits
        self.duration = duration
    }
}

// MARK: - Watch Control Plane Abstraction

/// The slice of the watch control plane a registered session needs. Production
/// is an adapter over `WatchConnectivityService.shared`; tests inject a spy.
@MainActor
public protocol ModuleWatchControlPlane: AnyObject {
    func sync(_ state: WatchSessionState)
    func setCommandHandler(_ handler: @escaping @Sendable (SessionCommand) async -> CommandResponse)
    func clearCommandHandler()
}

/// Sink for module session errors, so they reach the session error-log
/// drill-down (MODULE_SDK_SPEC.md section 5.9). Production forwards to the
/// app-global TelemetryEngine's `.module` stage.
public protocol ModuleSessionErrorSink: Sendable {
    func record(_ error: Error) async
}

// MARK: - Registered Session

/// A live registered module session. Returned by `begin`. The module calls
/// `update(progress:)` as it advances, `reportError(_:)` on failures, and
/// `end(summary:)` when done. Control commands from the watch invoke the
/// callbacks the module supplies.
@MainActor
public final class RegisteredSession {
    private let descriptor: ModuleSessionDescriptor
    private weak var watch: (any ModuleWatchControlPlane)?
    private let errorSink: any ModuleSessionErrorSink
    private let telemetry: any ModuleTelemetryService
    private let startTime: Date
    private let logger = Logger(label: "com.unamentis.modules.session")

    /// Control callbacks the module supplies. Absent controls are ignored.
    private let onPause: (@MainActor () -> Void)?
    private let onResume: (@MainActor () -> Void)?
    private let onMute: (@MainActor (Bool) -> Void)?
    private let onStop: (@MainActor () -> Void)?

    private var lastProgress = ModuleSessionProgress(completedUnits: 0)
    private var ended = false

    /// Whether this session still owns the single watch command-handler slot.
    /// WatchConnectivityService holds exactly ONE handler, so a later session
    /// takes it over; the earlier session must then stop touching it. Without
    /// this, the second session's `end()` cleared the slot out from under the
    /// first, leaving a live session with no watch control and a watch showing
    /// idle.
    private(set) var ownsWatchSlot = true

    init(
        descriptor: ModuleSessionDescriptor,
        watch: (any ModuleWatchControlPlane)?,
        errorSink: any ModuleSessionErrorSink,
        telemetry: any ModuleTelemetryService,
        onPause: (@MainActor () -> Void)?,
        onResume: (@MainActor () -> Void)?,
        onMute: (@MainActor (Bool) -> Void)?,
        onStop: (@MainActor () -> Void)?
    ) {
        self.descriptor = descriptor
        self.watch = watch
        self.errorSink = errorSink
        self.telemetry = telemetry
        self.startTime = Date()
        self.onPause = onPause
        self.onResume = onResume
        self.onMute = onMute
        self.onStop = onStop

        // Install the watch command handler and push initial state, exactly as
        // core sessions do. The handler routes watch commands to the module's
        // control callbacks and returns updated state.
        watch?.setCommandHandler { [weak self] command in
            await self?.handleWatchCommand(command) ?? CommandResponse(
                command: command, success: false, error: "Session not available"
            )
        }
        watch?.sync(watchState(from: lastProgress, isActive: true))

        Task { [telemetry, module = descriptor.module, kind = descriptor.activityKind] in
            await telemetry.record(.sessionStart, module: module)
            await telemetry.record(.activityStart(kind: kind, voiceInitiated: true), module: module)
        }
    }

    /// Report progress; pushes updated state to the watch while this session
    /// owns the watch slot (a displaced session keeps running locally but must
    /// not overwrite the newer session's watch state).
    public func update(progress: ModuleSessionProgress) {
        guard !ended else { return }
        lastProgress = progress
        guard ownsWatchSlot else { return }
        watch?.sync(watchState(from: progress, isActive: true))
    }

    /// Give up the watch slot to a newer registration. The session stays fully
    /// usable; it simply stops publishing to, and clearing, the shared handler.
    func resignWatchSlot() {
        guard ownsWatchSlot else { return }
        ownsWatchSlot = false
        logger.warning("Module session '\(descriptor.title)' lost the watch slot to a newer session")
    }

    /// Route a module session error into the session error-log drill-down.
    public func reportError(_ error: Error) {
        let sink = errorSink
        Task { await sink.record(error) }
    }

    /// End the session: emit end telemetry, clear the watch handler, push idle.
    public func end(summary: ModuleSessionSummary) {
        guard !ended else { return }
        ended = true
        let duration = summary.duration > 0 ? summary.duration : Date().timeIntervalSince(startTime)
        Task { [telemetry, module = descriptor.module, kind = descriptor.activityKind] in
            await telemetry.record(.activityEnd(kind: kind), module: module)
            await telemetry.record(.sessionEnd(duration: duration), module: module)
        }
        // Only the slot's current owner clears it. A displaced session ending
        // must not strip watch control from the session that took over.
        if ownsWatchSlot {
            ownsWatchSlot = false
            watch?.clearCommandHandler()
            watch?.sync(.idle)
        }
    }

    // MARK: Watch plumbing

    private func handleWatchCommand(_ command: SessionCommand) async -> CommandResponse {
        logger.info("Module session watch command: \(command.commandDescription)")
        guard ownsWatchSlot else {
            // A stale closure from a displaced session: never act on it.
            return CommandResponse(
                command: command, success: false, error: "Session no longer active"
            )
        }
        switch command {
        case .pause:
            if descriptor.controls.contains(.pause) { onPause?() }
        case .resume:
            if descriptor.controls.contains(.pause) { onResume?() }
        case .mute:
            if descriptor.controls.contains(.mute) { onMute?(true) }
        case .unmute:
            if descriptor.controls.contains(.mute) { onMute?(false) }
        case .stop:
            if descriptor.controls.contains(.stop) { onStop?() }
        }
        return CommandResponse(
            command: command,
            success: true,
            updatedState: watchState(from: lastProgress, isActive: !ended)
        )
    }

    private func watchState(from progress: ModuleSessionProgress, isActive: Bool) -> WatchSessionState {
        WatchSessionState(
            isActive: isActive,
            isPaused: progress.isPaused,
            isMuted: progress.isMuted,
            // Module sessions surface their title as the topic line; the module
            // name is not curriculum, so curriculumTitle stays nil.
            curriculumTitle: nil,
            topicTitle: descriptor.title,
            sessionMode: .curriculum,
            currentSegment: progress.completedUnits,
            totalSegments: descriptor.totalUnits,
            elapsedSeconds: Date().timeIntervalSince(startTime)
        )
    }
}

// MARK: - Service Protocol

/// The host session-registration service (MODULE_SDK_SPEC.md section 5.9).
@MainActor
public protocol SessionRegistrationService: AnyObject, Sendable {
    /// Begin a registered module session. The returned handle publishes to the
    /// watch and receives control commands. Control callbacks are optional; only
    /// the controls declared in the descriptor are wired.
    func begin(
        _ descriptor: ModuleSessionDescriptor,
        onPause: (@MainActor () -> Void)?,
        onResume: (@MainActor () -> Void)?,
        onMute: (@MainActor (Bool) -> Void)?,
        onStop: (@MainActor () -> Void)?
    ) -> RegisteredSession
}

// MARK: - Production Implementation

/// Session registration wired to the real watch control plane and the
/// app-global TelemetryEngine.
@MainActor
public final class DefaultSessionRegistrationService: SessionRegistrationService {
    private let watch: any ModuleWatchControlPlane
    private let errorSink: any ModuleSessionErrorSink
    private let telemetry: any ModuleTelemetryService
    private let logger = Logger(label: "com.unamentis.modules.registration")

    /// The registration that currently owns the single watch handler slot.
    /// Weak: a session that is gone releases the slot by itself.
    private weak var watchSlotOwner: RegisteredSession?

    public init(
        watch: any ModuleWatchControlPlane,
        errorSink: any ModuleSessionErrorSink,
        telemetry: any ModuleTelemetryService
    ) {
        self.watch = watch
        self.errorSink = errorSink
        self.telemetry = telemetry
    }

    public func begin(
        _ descriptor: ModuleSessionDescriptor,
        onPause: (@MainActor () -> Void)? = nil,
        onResume: (@MainActor () -> Void)? = nil,
        onMute: (@MainActor (Bool) -> Void)? = nil,
        onStop: (@MainActor () -> Void)? = nil
    ) -> RegisteredSession {
        // Arbitrate the single watch slot explicitly. A second module session
        // takes it over (the newest session is the one the learner is in), and
        // the previous holder is told so it stops publishing and, critically,
        // does not clear the slot when it eventually ends.
        if let existing = watchSlotOwner {
            logger.warning(
                "A module session is already registered; the new '\(descriptor.title)' session takes the watch slot"
            )
            existing.resignWatchSlot()
        }
        let session = RegisteredSession(
            descriptor: descriptor,
            watch: watch,
            errorSink: errorSink,
            telemetry: telemetry,
            onPause: onPause,
            onResume: onResume,
            onMute: onMute,
            onStop: onStop
        )
        watchSlotOwner = session
        return session
    }
}

// MARK: - Production Adapters

/// Adapts `WatchConnectivityService.shared` to the `ModuleWatchControlPlane`
/// slice the registration service needs.
@MainActor
public final class WatchConnectivityControlPlane: ModuleWatchControlPlane {
    public init() {}

    public func sync(_ state: WatchSessionState) {
        WatchConnectivityService.shared.syncSessionState(state)
    }

    public func setCommandHandler(_ handler: @escaping @Sendable (SessionCommand) async -> CommandResponse) {
        WatchConnectivityService.shared.setCommandHandler(handler)
    }

    public func clearCommandHandler() {
        WatchConnectivityService.shared.clearCommandHandler()
    }
}

/// Forwards module session errors to the app-global TelemetryEngine's `.module`
/// stage, so they appear in the session error-log drill-down (commit ab645bb).
public struct TelemetryModuleSessionErrorSink: ModuleSessionErrorSink {
    private let engine: TelemetryEngine

    public init(engine: TelemetryEngine) {
        self.engine = engine
    }

    public func record(_ error: Error) async {
        await engine.recordError(error, stage: .module)
    }
}
