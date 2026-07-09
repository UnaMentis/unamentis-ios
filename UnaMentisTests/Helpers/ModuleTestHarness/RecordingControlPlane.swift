// UnaMentis - Recording Session-Registration Control Plane (shared test harness)
// A watch control plane + error sink pair the harness records against and can
// drive, for SessionRegistration checks (MODULE_SDK_SPEC.md section 5.9).
//
// The production control plane is WatchConnectivity; this in-memory double
// records the WatchSessionState pushes and installed command handler, and lets a
// test drive pause/stop by sending a SessionCommand through the handler exactly
// as the watch would. That is what makes "pause/stop can be driven by tests"
// (the harness requirement) real rather than a stub.
//
// ALLOWED: in-memory host seam, not a mock of a paid external API.

import Foundation
@testable import UnaMentis

/// A watch control plane that records state pushes and can deliver commands.
/// ALLOWED: in-memory host seam, not a mock of a paid external API.
@MainActor
final class RecordingWatchControlPlane: ModuleWatchControlPlane {
    private(set) var syncedStates: [WatchSessionState] = []
    private var handler: (@Sendable (SessionCommand) async -> CommandResponse)?
    private(set) var handlerCleared = false

    func sync(_ state: WatchSessionState) {
        syncedStates.append(state)
    }

    func setCommandHandler(_ handler: @escaping @Sendable (SessionCommand) async -> CommandResponse) {
        self.handler = handler
        handlerCleared = false
    }

    func clearCommandHandler() {
        handler = nil
        handlerCleared = true
    }

    /// Deliver a watch command as if the paired watch sent it, driving the
    /// registered session's control callbacks. Returns the session's response,
    /// or nil if no handler is installed.
    func deliver(_ command: SessionCommand) async -> CommandResponse? {
        guard let handler else { return nil }
        return await handler(command)
    }

    /// The most recently pushed watch state, if any.
    var lastState: WatchSessionState? { syncedStates.last }
}

/// An error sink that records module session errors for assertions.
/// ALLOWED: in-memory host seam, not a mock of a paid external API.
actor RecordingErrorSink: ModuleSessionErrorSink {
    private(set) var errors: [Error] = []

    func record(_ error: Error) async {
        errors.append(error)
    }
}
