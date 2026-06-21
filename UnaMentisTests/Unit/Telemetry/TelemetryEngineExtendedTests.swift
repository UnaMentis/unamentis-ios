// UnaMentis - TelemetryEngine Extended Tests
// Deterministic coverage of branches not exercised by TelemetryEngineTests:
// rate limiting, VAD speech-segment edge detection, audio-processing latency
// dropping, thermal throttle counting, the event buffer cap, empty-export
// behavior, and the cost/quality derived properties.
//
// All tests use the real TelemetryEngine actor. No mocks are involved because
// the engine has no paid external dependencies.

import XCTest
@testable import UnaMentis

final class TelemetryEngineExtendedTests: XCTestCase {

    // MARK: - Properties

    private var telemetry: TelemetryEngine!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        telemetry = TelemetryEngine()
    }

    override func tearDown() async throws {
        telemetry = nil
        try await super.tearDown()
    }

    // MARK: - VAD Speech Segment Edge Detection

    func testVADSpeechDetected_onlyLogsOnTransitionIntoSpeech() async {
        // First speech-detected enters the speech segment and is recorded.
        await telemetry.recordEvent(.vadSpeechDetected(confidence: 0.9))
        // A second consecutive speech-detected while already in a speech segment
        // must be dropped, since we only log segment transitions.
        await telemetry.recordEvent(.vadSpeechDetected(confidence: 0.95))

        let events = await telemetry.recentEvents
        let speechEvents = events.filter { recorded in
            if case .vadSpeechDetected = recorded.event { return true }
            return false
        }
        XCTAssertEqual(speechEvents.count, 1, "consecutive speech frames must not each record an event")
    }

    func testVADSilence_resetsSpeechSegment_allowingNextSpeechToRecord() async throws {
        await telemetry.recordEvent(.vadSpeechDetected(confidence: 0.9))
        // Silence ends the current speech segment.
        await telemetry.recordEvent(.vadSilenceDetected(duration: 2.0))

        // The vadSpeechDetected per-event rate limit is 0.5s. Wait past it so the
        // next onset is suppressed only by segment logic, not the rate limiter.
        // This isolates the segment-reset behavior under test.
        try await Task.sleep(nanoseconds: 600_000_000) // 0.6s

        // A new speech onset after silence is a transition and must record again.
        await telemetry.recordEvent(.vadSpeechDetected(confidence: 0.9))

        let events = await telemetry.recentEvents
        let speechEvents = events.filter { recorded in
            if case .vadSpeechDetected = recorded.event { return true }
            return false
        }
        XCTAssertEqual(speechEvents.count, 2, "a speech onset after silence is a fresh transition")
    }

    // MARK: - Latency Rate Limiting

    func testAudioProcessingLatency_isNotStoredInSessionMetrics() async {
        // Audio processing latency is sampled for logging only, never aggregated.
        await telemetry.recordLatency(.audioProcessing, 0.010)
        await telemetry.recordLatency(.audioProcessing, 0.020)

        let metrics = await telemetry.currentMetrics
        // None of the stored latency buffers should have received the samples.
        XCTAssertTrue(metrics.sttLatencies.isEmpty)
        XCTAssertTrue(metrics.llmLatencies.isEmpty)
        XCTAssertTrue(metrics.ttsLatencies.isEmpty)
        XCTAssertTrue(metrics.e2eLatencies.isEmpty)
        XCTAssertTrue(metrics.ttfaLatencies.isEmpty)
    }

    func testSttEmissionLatency_storesEvenWhenRateLimited() async {
        // The STT emission rate limit (0.1s) suppresses logging but still stores
        // the sample, so rapid emissions must all land in the buffer.
        await telemetry.recordLatency(.sttEmission, 0.100)
        await telemetry.recordLatency(.sttEmission, 0.110)
        await telemetry.recordLatency(.sttEmission, 0.120)

        let metrics = await telemetry.currentMetrics
        XCTAssertEqual(metrics.sttLatencies.count, 3)
    }

    func testTTSTimeToFirstByte_aliasStoresInTTSBuffer() async {
        // Both .ttsTTFB and .ttsTimeToFirstByte feed the same buffer.
        await telemetry.recordLatency(.ttsTTFB, 0.080)
        await telemetry.recordLatency(.ttsTimeToFirstByte, 0.120)

        let metrics = await telemetry.currentMetrics
        XCTAssertEqual(metrics.ttsLatencies.count, 2)
        XCTAssertEqual(metrics.ttsLatencies.median, 0.100, accuracy: 0.0001)
    }

    // MARK: - Event Rate Limiting (global per-minute cap)

    func testGlobalRateLimit_dropsEventsBeyondMaxPerMinute() async {
        // maxEventsPerMinute is 300. Recording well beyond that within one minute
        // window must cap the stored buffer at the limit.
        for index in 0..<350 {
            await telemetry.recordEvent(.topicStarted(topic: "topic-\(index)"))
        }

        let events = await telemetry.recentEvents
        XCTAssertEqual(events.count, 300, "events beyond the per-minute cap must be dropped")
    }

    // MARK: - Thermal Throttle Counting

    func testThermalStateChanged_incrementsThrottleCounter() async {
        await telemetry.recordEvent(.thermalStateChanged(.serious))
        await telemetry.recordEvent(.thermalStateChanged(.critical))

        let metrics = await telemetry.currentMetrics
        XCTAssertEqual(metrics.thermalThrottleEvents, 2)
    }

    // MARK: - Error Recording

    func testRecordErrorWithoutStage_doesNotChangeTypedCounters() async {
        struct SampleError: Error {}
        await telemetry.recordError(SampleError())

        let snapshot = await telemetry.exportMetrics()
        XCTAssertEqual(snapshot.quality.errorsTotal, 0)
        XCTAssertTrue(snapshot.quality.errorsByStage?.isEmpty ?? true)
    }

    func testStreamFailureCounters_areCountedBeforeRateLimiting() async {
        // Error totals must stay accurate even when the buffer is throttled, so
        // exceed the per-minute event cap with a mix that ends in stream failures.
        for index in 0..<300 {
            await telemetry.recordEvent(.topicStarted(topic: "t-\(index)"))
        }
        // These are recorded after the cap is hit; the buffer will not grow but
        // the typed error counters should still increment.
        struct SampleError: Error {}
        await telemetry.recordEvent(.llmStreamFailed(SampleError()))
        await telemetry.recordEvent(.llmStreamFailed(SampleError()))

        let snapshot = await telemetry.exportMetrics()
        XCTAssertEqual(snapshot.quality.errorsByStage?["llm"], 2)
        XCTAssertEqual(snapshot.quality.errorsTotal, 2)
    }

    // MARK: - Export with Empty Buffers

    func testExportMetrics_emptyBuffers_reportZeroLatenciesAndNilTTFA() async {
        let snapshot = await telemetry.exportMetrics()

        XCTAssertEqual(snapshot.latencies.sttMedianMs, 0)
        XCTAssertEqual(snapshot.latencies.sttP99Ms, 0)
        XCTAssertEqual(snapshot.latencies.llmMedianMs, 0)
        XCTAssertEqual(snapshot.latencies.e2eMedianMs, 0)
        XCTAssertNil(snapshot.latencies.ttfaMedianMs)
        XCTAssertNil(snapshot.latencies.ttfaP99Ms)
        XCTAssertEqual(snapshot.quality.turnsTotal, 0)
        XCTAssertEqual(snapshot.quality.interruptionSuccessRate, 0)
    }

    func testExportMetrics_roundsLatencyToMilliseconds() async {
        await telemetry.recordLatency(.endToEndTurn, 0.4567)

        let snapshot = await telemetry.exportMetrics()
        // 0.4567 seconds -> 456.7ms -> truncated to 456 by Int conversion.
        XCTAssertEqual(snapshot.latencies.e2eMedianMs, 456)
    }

    // MARK: - Interruption Success Rate

    func testInterruptionSuccessRate_isInterruptionsOverTurns() async {
        await telemetry.startSession()
        await telemetry.recordEvent(.userFinishedSpeaking(transcript: "a"))
        await telemetry.recordEvent(.userFinishedSpeaking(transcript: "b"))
        await telemetry.recordEvent(.userFinishedSpeaking(transcript: "c"))
        await telemetry.recordEvent(.userFinishedSpeaking(transcript: "d"))
        await telemetry.recordEvent(.userInterrupted)

        let snapshot = await telemetry.exportMetrics()
        XCTAssertEqual(snapshot.quality.turnsTotal, 4)
        XCTAssertEqual(snapshot.quality.interruptions, 1)
        XCTAssertEqual(snapshot.quality.interruptionSuccessRate, 0.25, accuracy: 0.0001)
    }

    // MARK: - currentMetrics Duration

    func testCurrentMetrics_withoutSession_hasZeroDuration() async {
        let metrics = await telemetry.currentMetrics
        XCTAssertEqual(metrics.duration, 0)
    }

    // MARK: - Device Metrics Defaults

    func testGetAverageDeviceMetrics_emptyHistory_returnsDefaults() async {
        let avg = await telemetry.getAverageDeviceMetrics()
        XCTAssertEqual(avg.cpuUsage, 0)
        XCTAssertEqual(avg.memoryUsed, 0)
        XCTAssertEqual(avg.thermalState, .nominal)
    }

    func testGetPeakDeviceMetrics_emptyHistory_returnsDefaults() async {
        let peak = await telemetry.getPeakDeviceMetrics()
        XCTAssertEqual(peak.cpuUsage, 0)
        XCTAssertEqual(peak.memoryUsed, 0)
        XCTAssertEqual(peak.thermalState, .nominal)
    }

    // MARK: - Reset Clears Counters

    func testReset_clearsTurnAndInterruptionCounters() async {
        await telemetry.startSession()
        await telemetry.recordEvent(.userFinishedSpeaking(transcript: "x"))
        await telemetry.recordEvent(.userInterrupted)
        await telemetry.recordEvent(.thermalStateChanged(.serious))

        await telemetry.reset()

        let metrics = await telemetry.currentMetrics
        XCTAssertEqual(metrics.turnsTotal, 0)
        XCTAssertEqual(metrics.interruptions, 0)
        XCTAssertEqual(metrics.thermalThrottleEvents, 0)
        let events = await telemetry.recentEvents
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - startSession Resets Prior State

    func testStartSession_resetsMetricsFromPriorSession() async {
        await telemetry.startSession()
        await telemetry.recordLatency(.endToEndTurn, 0.5)
        await telemetry.recordCost(.stt, amount: 0.10, description: "prior")

        // Starting a new session must clear the prior session's aggregates.
        await telemetry.startSession()

        let metrics = await telemetry.currentMetrics
        XCTAssertTrue(metrics.e2eLatencies.isEmpty)
        XCTAssertEqual(metrics.sttCost, Decimal.zero)
        // The fresh session records its own sessionStarted event.
        let events = await telemetry.recentEvents
        XCTAssertEqual(events.count, 1)
    }
}

// MARK: - SessionMetrics Derived Property Tests

final class SessionMetricsDerivedTests: XCTestCase {

    func testTotalCost_sumsAllCategories() {
        var metrics = SessionMetrics()
        metrics.sttCost = Decimal(string: "0.01")!
        metrics.ttsCost = Decimal(string: "0.02")!
        metrics.llmCost = Decimal(string: "0.03")!
        XCTAssertEqual(metrics.totalCost, Decimal(string: "0.06")!)
    }

    func testCostPerHour_zeroDuration_returnsZero() {
        var metrics = SessionMetrics()
        metrics.sttCost = Decimal(string: "0.05")!
        metrics.duration = 0
        XCTAssertEqual(metrics.costPerHour, 0)
    }

    func testCostPerHour_scalesByDuration() {
        var metrics = SessionMetrics()
        // $0.10 over 60 seconds projects to $6.00 per hour.
        metrics.sttCost = Decimal(string: "0.10")!
        metrics.duration = 60
        XCTAssertEqual(metrics.costPerHour, 6.0, accuracy: 0.0001)
    }
}

// MARK: - Array Statistics Extension Tests

final class TelemetryArrayStatisticsTests: XCTestCase {

    func testMedian_emptyArray_returnsZero() {
        let values: [TimeInterval] = []
        XCTAssertEqual(values.median, 0)
    }

    func testMedian_oddCount_returnsMiddleValue() {
        let values: [TimeInterval] = [0.3, 0.1, 0.2]
        XCTAssertEqual(values.median, 0.2, accuracy: 0.0001)
    }

    func testMedian_evenCount_averagesMiddleTwo() {
        let values: [TimeInterval] = [0.1, 0.2, 0.3, 0.4]
        // Average of the two middle values 0.2 and 0.3.
        XCTAssertEqual(values.median, 0.25, accuracy: 0.0001)
    }

    func testPercentile_emptyArray_returnsZero() {
        let values: [TimeInterval] = []
        XCTAssertEqual(values.percentile(50), 0)
    }

    func testPercentile_nearestRank_p100ReturnsMax() {
        let values: [TimeInterval] = [0.1, 0.2, 0.3, 0.4, 0.5]
        XCTAssertEqual(values.percentile(100), 0.5, accuracy: 0.0001)
    }

    func testPercentile_nearestRank_lowPercentileReturnsMin() {
        let values: [TimeInterval] = [0.1, 0.2, 0.3, 0.4, 0.5]
        // ceil(1 * 5 / 100) = 1 -> rank 1 -> first (smallest) element.
        XCTAssertEqual(values.percentile(1), 0.1, accuracy: 0.0001)
    }

    func testPercentile_midpoint_usesNearestRank() {
        // For 10 values, p50 nearest-rank = ceil(0.5 * 10) = 5 -> 5th element.
        let values: [TimeInterval] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map { Double($0) }
        XCTAssertEqual(values.percentile(50), 5.0, accuracy: 0.0001)
    }

    func testStandardDeviation_knownValues() {
        // Mean = 5, sample variance = 32/7 = 4.5714, stddev = 2.138.
        let values: [TimeInterval] = [2, 4, 4, 4, 5, 5, 7, 9]
        XCTAssertEqual(values.standardDeviation, 2.138, accuracy: 0.001)
    }
}
