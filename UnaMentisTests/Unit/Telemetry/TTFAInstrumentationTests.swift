// UnaMentis - TTFA Instrumentation Tests
// Exercises the active-measurement state machine and the optional telemetry
// sink that mirrors completed TTFA measurements into a real TelemetryEngine.
//
// TTFAInstrumentation is a shared actor singleton, so each test leaves it in a
// clean state (no active feature, no sink, no active barge-in) in tearDown to
// avoid cross-test contamination.

import XCTest
@testable import UnaMentis

final class TTFAInstrumentationTests: XCTestCase {

    private var ttfa: TTFAInstrumentation!

    override func setUp() async throws {
        try await super.setUp()
        ttfa = TTFAInstrumentation.shared
        // Ensure a clean starting state regardless of prior test order.
        await ttfa.setTelemetrySink(nil)
        await ttfa.markBargeInResolved()
        // Closing any stray active feature with an error clears activeFeature.
        if await ttfa.isActive {
            await ttfa.markError("test setup reset")
        }
    }

    override func tearDown() async throws {
        await ttfa.setTelemetrySink(nil)
        await ttfa.markBargeInResolved()
        if await ttfa.isActive {
            await ttfa.markError("test teardown reset")
        }
        ttfa = nil
        try await super.tearDown()
    }

    // MARK: - Active State Machine

    func testInitialState_isNotActive() async {
        let active = await ttfa.isActive
        XCTAssertFalse(active)
    }

    func testMarkActivation_setsActive() async {
        await ttfa.markActivation(.readingPlay)
        let active = await ttfa.isActive
        XCTAssertTrue(active)
    }

    func testMarkAudioPlaying_completesAndClearsActive() async {
        await ttfa.markActivation(.readingPlay)
        await ttfa.markAudioPlaying()
        let active = await ttfa.isActive
        XCTAssertFalse(active, "markAudioPlaying completes the measurement and clears the active feature")
    }

    func testMarkError_clearsActive() async {
        await ttfa.markActivation(.sessionChat)
        await ttfa.markError("synthesis failed")
        let active = await ttfa.isActive
        XCTAssertFalse(active)
    }

    func testMilestonesWithoutActivation_doNotActivate() async {
        // Guarded milestone calls are no-ops when nothing is active.
        await ttfa.markTTSFirstChunk()
        await ttfa.markAudioScheduled()
        await ttfa.markCachedHit()
        let active = await ttfa.isActive
        XCTAssertFalse(active)
    }

    func testMarkActivation_supersedesPriorMeasurement() async {
        // Starting a new measurement while one is active auto-closes the old one
        // but leaves a measurement active for the new feature.
        await ttfa.markActivation(.kbOral)
        await ttfa.markActivation(.kbWritten)
        let active = await ttfa.isActive
        XCTAssertTrue(active, "the superseding activation remains active")
    }

    // MARK: - Telemetry Sink Mirroring

    func testMarkAudioPlaying_mirrorsTTFALatencyIntoSink() async throws {
        let engine = TelemetryEngine()
        await engine.startSession()
        // startSession registers the engine as the TTFA sink. Re-assert it
        // explicitly so this test does not depend on that side effect ordering.
        await ttfa.setTelemetrySink(engine)

        await ttfa.markActivation(.readingPlay)
        await ttfa.markAudioPlaying()

        // The sink record happens in a detached task spawned by markAudioPlaying.
        // Poll briefly for the sample to land; it completes near-instantly.
        let sampleCount = try await pollForTTFASample(in: engine)
        XCTAssertGreaterThanOrEqual(sampleCount, 1, "completed TTFA should be mirrored into session metrics")
    }

    func testNoSink_doesNotCrashOnCompletion() async {
        // With no sink set, completing a measurement must still succeed.
        await ttfa.setTelemetrySink(nil)
        await ttfa.markActivation(.sessionCurriculum)
        await ttfa.markAudioPlaying()
        let active = await ttfa.isActive
        XCTAssertFalse(active)
    }

    func testMarkError_doesNotMirrorIntoSink() async throws {
        let engine = TelemetryEngine()
        await engine.startSession()
        await ttfa.setTelemetrySink(engine)

        await ttfa.markActivation(.readingPlay)
        await ttfa.markError("synthesis failed")

        // Give any stray task a chance to run, then confirm no TTFA was recorded.
        for _ in 0..<10 { await Task.yield() }
        let metrics = await engine.currentMetrics
        XCTAssertTrue(metrics.ttfaLatencies.isEmpty, "errors must not be recorded as TTFA latencies")
    }

    // MARK: - Barge-In Timeline State

    func testBargeInMilestones_withoutOnset_areNoOps() async {
        // Without an onset, the guarded barge-in milestones must not throw or
        // change observable state. There is no crash and no active feature.
        await ttfa.markBargeInTentative()
        await ttfa.markBargeInConfirmed()
        await ttfa.markBargeInSttFirstPartial()
        let active = await ttfa.isActive
        XCTAssertFalse(active)
    }

    func testBargeInOnset_thenResolve_completesWithoutAffectingFeatureMeasurement() async {
        // A feature TTFA measurement and a barge-in timeline use independent
        // timing slots and must not interfere with each other.
        await ttfa.markActivation(.sessionChat)
        await ttfa.markBargeInOnset()
        await ttfa.markBargeInConfirmed()
        await ttfa.markBargeInResolved()

        // The feature measurement remains active after the barge-in resolves.
        let active = await ttfa.isActive
        XCTAssertTrue(active, "barge-in timeline must not clear an in-flight feature measurement")

        // Cleaning up the feature measurement to leave a tidy state.
        await ttfa.markAudioPlaying()
        let stillActive = await ttfa.isActive
        XCTAssertFalse(stillActive)
    }

    // MARK: - Helpers

    /// Poll the engine for at least one recorded TTFA sample, bounded to avoid
    /// an unbounded wait. The mirroring task completes near-instantly in practice.
    private func pollForTTFASample(in engine: TelemetryEngine) async throws -> Int {
        for _ in 0..<200 {
            let count = await engine.currentMetrics.ttfaLatencies.count
            if count >= 1 { return count }
            try await Task.sleep(nanoseconds: 1_000_000) // 1ms
        }
        return await engine.currentMetrics.ttfaLatencies.count
    }
}
