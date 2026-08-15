// UnaMentis - Session Registration Service Tests
// MODULE_SDK_SPEC.md section 5.9, capability "session.registration/1".
//
// Verifies that a registered module session publishes watch state on begin and
// update, delivers a stop command from the watch to the module's callback, and
// routes reported errors into the error sink (the session error-log path). Uses
// in-memory test doubles for the watch plane, error sink, and telemetry so no
// WatchConnectivity or live TelemetryEngine is required.
//
// ALLOWED: these are in-memory test doubles for internal host seams, not mocks
// of paid external APIs; they exist so the watch control-plane round-trip is
// deterministically testable.

import XCTest
@testable import UnaMentis

@MainActor
private final class SpyWatchControlPlane: ModuleWatchControlPlane {
    var synced: [WatchSessionState] = []
    var handler: (@Sendable (SessionCommand) async -> CommandResponse)?
    var clearCount = 0

    func sync(_ state: WatchSessionState) {
        synced.append(state)
    }
    func setCommandHandler(_ handler: @escaping @Sendable (SessionCommand) async -> CommandResponse) {
        self.handler = handler
    }
    func clearCommandHandler() {
        clearCount += 1
        handler = nil
    }
}

private actor SpyErrorSink: ModuleSessionErrorSink {
    private(set) var recorded: [String] = []
    func record(_ error: Error) async {
        recorded.append(error.localizedDescription)
    }
    func count() -> Int { recorded.count }
}

private actor SpyTelemetry: ModuleTelemetryService {
    private(set) var events: [(String, String)] = []  // (name-ish, module)
    func record(_ event: ModuleTelemetryEvent, module: String) async {
        let name: String
        switch event {
        case .sessionStart: name = "session.start"
        case .sessionEnd: name = "session.end"
        case .activityStart: name = "activity.start"
        case .activityEnd: name = "activity.end"
        case .attempt: name = "attempt"
        case .custom(let n, _): name = n
        }
        events.append((name, module))
    }
    func names() -> [String] { events.map { $0.0 } }
    func modules() -> Set<String> { Set(events.map { $0.1 }) }
}

@MainActor
final class SessionRegistrationServiceTests: XCTestCase {

    private func makeService() -> (DefaultSessionRegistrationService, SpyWatchControlPlane, SpyErrorSink, SpyTelemetry) {
        let watch = SpyWatchControlPlane()
        let sink = SpyErrorSink()
        let telemetry = SpyTelemetry()
        let service = DefaultSessionRegistrationService(watch: watch, errorSink: sink, telemetry: telemetry)
        return (service, watch, sink, telemetry)
    }

    private func descriptor(total: Int = 10) -> ModuleSessionDescriptor {
        ModuleSessionDescriptor(
            module: "knowledge-bowl",
            title: "KB Oral Practice",
            activityKind: ModuleActivityKind("oral"),
            controls: .voicePractice,
            totalUnits: total
        )
    }

    func testBegin_publishesActiveWatchState() {
        let (service, watch, _, _) = makeService()
        _ = service.begin(descriptor(), onPause: nil, onResume: nil, onMute: nil, onStop: nil)

        XCTAssertEqual(watch.synced.count, 1)
        let state = watch.synced.first
        XCTAssertEqual(state?.isActive, true)
        XCTAssertEqual(state?.topicTitle, "KB Oral Practice")
        XCTAssertEqual(state?.totalSegments, 10)
        XCTAssertNotNil(watch.handler, "Begin should install a watch command handler")
    }

    func testUpdate_publishesProgress() {
        let (service, watch, _, _) = makeService()
        let session = service.begin(descriptor(), onPause: nil, onResume: nil, onMute: nil, onStop: nil)

        session.update(progress: ModuleSessionProgress(completedUnits: 3))

        XCTAssertEqual(watch.synced.count, 2)
        XCTAssertEqual(watch.synced.last?.currentSegment, 3)
    }

    func testStopCommand_invokesModuleCallback() async throws {
        let (service, watch, _, _) = makeService()

        var stopped = false
        // Retain the session: the command handler holds `self` weakly, so a
        // discarded session would deallocate and the command would no-op.
        let session = service.begin(
            descriptor(),
            onPause: nil, onResume: nil, onMute: nil,
            onStop: { stopped = true }
        )

        // Simulate the watch sending a stop command through the installed handler.
        let handler = try XCTUnwrap(watch.handler)
        let response = await handler(.stop)
        withExtendedLifetime(session) {}

        XCTAssertTrue(stopped, "Stop command should invoke the module's stop callback")
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.command, .stop)
    }

    func testPauseCommand_invokesModuleCallback() async throws {
        let (service, watch, _, _) = makeService()

        var paused = false
        let session = service.begin(
            descriptor(),
            onPause: { paused = true }, onResume: nil, onMute: nil, onStop: nil
        )

        let handler = try XCTUnwrap(watch.handler)
        _ = await handler(.pause)
        withExtendedLifetime(session) {}
        XCTAssertTrue(paused)
    }

    func testEnd_clearsHandlerAndPublishesIdle() {
        let (service, watch, _, _) = makeService()
        let session = service.begin(descriptor(), onPause: nil, onResume: nil, onMute: nil, onStop: nil)

        session.end(summary: ModuleSessionSummary(completedUnits: 5, duration: 30))

        XCTAssertEqual(watch.clearCount, 1)
        XCTAssertEqual(watch.synced.last?.isActive, false, "End should publish idle state")
    }

    // MARK: - Two concurrent registered sessions (single watch slot)

    func testSecondSessionTakesTheWatchSlotAndTheFirstStopsPublishing() {
        let (service, watch, _, _) = makeService()
        let first = service.begin(descriptor(total: 10), onPause: nil, onResume: nil, onMute: nil, onStop: nil)
        let second = service.begin(descriptor(total: 20), onPause: nil, onResume: nil, onMute: nil, onStop: nil)

        XCTAssertFalse(first.ownsWatchSlot, "The newer session owns the single watch slot")
        XCTAssertTrue(second.ownsWatchSlot)

        // The displaced session must not overwrite the live session's state.
        let syncedBefore = watch.synced.count
        first.update(progress: ModuleSessionProgress(completedUnits: 7))
        XCTAssertEqual(watch.synced.count, syncedBefore, "A displaced session must not publish")

        second.update(progress: ModuleSessionProgress(completedUnits: 2))
        XCTAssertEqual(watch.synced.last?.currentSegment, 2)
        XCTAssertEqual(watch.synced.last?.totalSegments, 20)
    }

    func testDisplacedSessionEndingDoesNotStripWatchControlFromTheLiveOne() throws {
        let (service, watch, _, _) = makeService()
        let first = service.begin(descriptor(), onPause: nil, onResume: nil, onMute: nil, onStop: nil)
        let second = service.begin(descriptor(), onPause: nil, onResume: nil, onMute: nil, onStop: nil)

        // The first session ends while the second is still running. Clearing
        // the handler unconditionally left the live session with no watch
        // control and the watch showing idle.
        first.end(summary: ModuleSessionSummary(completedUnits: 1, duration: 5))

        XCTAssertEqual(watch.clearCount, 0, "A displaced session must not clear the handler")
        XCTAssertNotNil(watch.handler, "The live session keeps watch control")
        XCTAssertEqual(watch.synced.last?.isActive, true, "The watch must not be told the session is idle")

        // The live session still ends cleanly and owns the teardown.
        second.end(summary: ModuleSessionSummary(completedUnits: 4, duration: 9))
        XCTAssertEqual(watch.clearCount, 1)
        XCTAssertEqual(watch.synced.last?.isActive, false)
        withExtendedLifetime(first) {}
    }

    func testDisplacedSessionRejectsStaleWatchCommands() async throws {
        let (service, watch, _, _) = makeService()
        var firstStopped = false
        var secondStopped = false
        let first = service.begin(
            descriptor(), onPause: nil, onResume: nil, onMute: nil, onStop: { firstStopped = true }
        )
        let firstHandler = try XCTUnwrap(watch.handler)
        let second = service.begin(
            descriptor(), onPause: nil, onResume: nil, onMute: nil, onStop: { secondStopped = true }
        )

        // A stale closure from the displaced session must not act.
        let staleResponse = await firstHandler(.stop)
        XCTAssertFalse(firstStopped)
        XCTAssertFalse(staleResponse.success)

        let liveHandler = try XCTUnwrap(watch.handler)
        _ = await liveHandler(.stop)
        XCTAssertTrue(secondStopped)
        withExtendedLifetime((first, second)) {}
    }

    func testReportError_reachesErrorSink() async {
        let (service, _, sink, _) = makeService()
        let session = service.begin(descriptor(), onPause: nil, onResume: nil, onMute: nil, onStop: nil)

        struct SampleError: LocalizedError { var errorDescription: String? { "boom" } }
        session.reportError(SampleError())

        // reportError dispatches to the sink asynchronously; poll briefly.
        for _ in 0..<50 where await sink.count() == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let recorded = await sink.recorded
        XCTAssertEqual(recorded, ["boom"])
    }

    func testBegin_emitsStartTelemetryWithModuleDimension() async {
        let (service, _, _, telemetry) = makeService()
        _ = service.begin(descriptor(), onPause: nil, onResume: nil, onMute: nil, onStop: nil)

        for _ in 0..<50 where await telemetry.names().isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let names = await telemetry.names()
        XCTAssertTrue(names.contains("session.start"))
        XCTAssertTrue(names.contains("activity.start"))
        let modules = await telemetry.modules()
        XCTAssertEqual(modules, ["knowledge-bowl"])
    }
}
