// UnaMentis - Recording Telemetry Sink (shared test harness)
// A ModuleTelemetryService that records every event so tests can assert the
// required taxonomy was emitted (MODULE_SDK_SPEC.md section 5.6).
//
// This is not a mock of a paid API: telemetry is an internal service. It records
// in-memory instead of routing to a TelemetryEngine so tests can inspect exactly
// which events a module (or the QuizMatchEngine) produced, including the required
// `module.attempt` event UM-Voice checks for.
//
// ALLOWED: in-memory host seam, not a mock of a paid external API.

import Foundation
@testable import UnaMentis

/// Records module telemetry events for assertions.
/// ALLOWED: in-memory host seam, not a mock of a paid external API.
actor RecordingModuleTelemetryService: ModuleTelemetryService {
    /// One recorded event, tagged with the module that emitted it.
    struct Entry: Sendable {
        let event: ModuleTelemetryEvent
        let module: String
    }

    private(set) var entries: [Entry] = []

    func record(_ event: ModuleTelemetryEvent, module: String) async {
        entries.append(Entry(event: event, module: module))
    }

    // MARK: - Query helpers

    /// The number of `module.attempt` events recorded for the given module.
    func attemptCount(module: String) -> Int {
        entries.filter { entry in
            guard entry.module == module else { return false }
            if case .attempt = entry.event { return true }
            return false
        }.count
    }

    /// Whether at least one event of the given predicate was recorded.
    func contains(module: String, where predicate: (ModuleTelemetryEvent) -> Bool) -> Bool {
        entries.contains { $0.module == module && predicate($0.event) }
    }

    /// All recorded events for the given module, in order.
    func events(module: String) -> [ModuleTelemetryEvent] {
        entries.filter { $0.module == module }.map(\.event)
    }
}
