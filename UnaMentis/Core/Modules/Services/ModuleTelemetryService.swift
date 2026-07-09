// UnaMentis - Module Telemetry Host Service
// MODULE_SDK_SPEC.md section 5.6, capability "telemetry/1"
//
// App-global telemetry with a module dimension. This is the host service that
// replaces per-module telemetry: modules never instantiate their own
// TelemetryEngine, they emit through `host.telemetry`, and every event carries
// the emitting module's ID so cross-module analysis stays possible.
//
// The production implementation routes into the app-global `TelemetryEngine`
// (the same actor that owns session latency, cost, and the error-log
// drill-down), so module events land in the one place session telemetry
// already lives. The required taxonomy is small and fixed (section 5.6):
// module.session.start/end, module.activity.start/end, module.attempt. Free-form
// module events are also allowed.

import Foundation

// MARK: - Event Taxonomy

/// The kind of activity a module runs, carried on activity events so telemetry
/// can distinguish (say) a Knowledge Bowl oral round from a written round.
public struct ModuleActivityKind: RawRepresentable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// One telemetry event emitted by a module. The required taxonomy per
/// MODULE_SDK_SPEC.md section 5.6, plus a free-form escape hatch.
public enum ModuleTelemetryEvent: Sendable {
    /// A module session began.
    case sessionStart
    /// A module session ended, with its total duration.
    case sessionEnd(duration: TimeInterval)
    /// An activity within a session began. `voiceInitiated` records whether the
    /// activity was entered hands-free (feeds measured voice coverage).
    case activityStart(kind: ModuleActivityKind, voiceInitiated: Bool)
    /// An activity ended.
    case activityEnd(kind: ModuleActivityKind)
    /// A single attempt (one question/response) was evaluated.
    case attempt(outcome: ModuleAttemptOutcome, latencyMs: Int)
    /// A module-specific event outside the required taxonomy.
    case custom(name: String, detail: String)
}

/// The outcome of one evaluated attempt, kept small on purpose.
public enum ModuleAttemptOutcome: String, Sendable {
    case correct
    case incorrect
    case skipped
    case timeout
}

// MARK: - Service Protocol

/// The host telemetry service (MODULE_SDK_SPEC.md section 5.6). Every recorded
/// event is stamped with the emitting module's ID (the module dimension).
public protocol ModuleTelemetryService: Sendable {
    /// Record a module telemetry event, tagged with the module that emitted it.
    func record(_ event: ModuleTelemetryEvent, module: String) async
}

// MARK: - Production Implementation

/// Routes module telemetry into the app-global `TelemetryEngine`.
///
/// Each event becomes a `TelemetryEvent.custom`-style record carrying the
/// module dimension, so module activity shows up alongside core session
/// telemetry rather than in a private silo. The engine reference is injected so
/// the service uses the same instance the rest of the app already feeds
/// (`AppState.telemetry`); a default standalone engine keeps the service usable
/// before AppState wiring exists (e.g. previews, tests).
public struct TelemetryEngineModuleTelemetryService: ModuleTelemetryService {
    private let engine: TelemetryEngine

    public init(engine: TelemetryEngine) {
        self.engine = engine
    }

    public func record(_ event: ModuleTelemetryEvent, module: String) async {
        // Map the module taxonomy onto the engine's free-form event channel so
        // module telemetry lands in the same buffer as session telemetry. The
        // module ID is always the first field, making the module dimension
        // recoverable from any recorded event.
        let name: String
        let detail: String
        switch event {
        case .sessionStart:
            name = "module.session.start"
            detail = module
        case .sessionEnd(let duration):
            name = "module.session.end"
            detail = "\(module)|durationMs=\(Int(duration * 1000))"
        case .activityStart(let kind, let voiceInitiated):
            name = "module.activity.start"
            detail = "\(module)|kind=\(kind.rawValue)|voiceInitiated=\(voiceInitiated)"
        case .activityEnd(let kind):
            name = "module.activity.end"
            detail = "\(module)|kind=\(kind.rawValue)"
        case .attempt(let outcome, let latencyMs):
            name = "module.attempt"
            detail = "\(module)|outcome=\(outcome.rawValue)|latencyMs=\(latencyMs)"
        case .custom(let customName, let customDetail):
            name = "module.\(customName)"
            detail = customDetail.isEmpty ? module : "\(module)|\(customDetail)"
        }
        await engine.recordModuleEvent(name: name, module: module, detail: detail)
    }
}
