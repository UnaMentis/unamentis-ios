// UnaMentis - MetricsUploadService Tests
// Unit tests for upload endpoint resolution and telemetry consent gating
//
// Tests cover: base URL configuration (https and legacy host:port forms),
// consent gating at the upload boundary, and the telemetry fields that feed
// the upload payload (TTFA latency, typed error counters).

import XCTest
@testable import UnaMentis

/// Unit tests for MetricsUploadService endpoint resolution and consent gating
final class MetricsUploadServiceTests: XCTestCase {

    // MARK: - Properties

    private let consentKey = "telemetryConsentGranted"
    private let queueStorageKey = "MetricsUploadQueue"
    private var originalConsent: Any?
    private var originalQueueData: Data?

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        originalConsent = UserDefaults.standard.object(forKey: consentKey)
        originalQueueData = UserDefaults.standard.data(forKey: queueStorageKey)
        UserDefaults.standard.removeObject(forKey: consentKey)
        UserDefaults.standard.removeObject(forKey: queueStorageKey)
    }

    override func tearDown() async throws {
        if let originalConsent {
            UserDefaults.standard.set(originalConsent, forKey: consentKey)
        } else {
            UserDefaults.standard.removeObject(forKey: consentKey)
        }
        if let originalQueueData {
            UserDefaults.standard.set(originalQueueData, forKey: queueStorageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: queueStorageKey)
        }
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func makeSnapshot() -> MetricsSnapshot {
        MetricsSnapshot(
            latencies: LatencyMetrics(
                sttMedianMs: 100,
                sttP99Ms: 200,
                llmMedianMs: 150,
                llmP99Ms: 300,
                ttsMedianMs: 80,
                ttsP99Ms: 160,
                e2eMedianMs: 400,
                e2eP99Ms: 900,
                ttfaMedianMs: 250,
                ttfaP99Ms: 480
            ),
            costs: CostMetrics(
                sttTotal: 0,
                ttsTotal: 0,
                llmInputTokens: 0,
                llmOutputTokens: 0,
                llmTotal: 0,
                totalSession: 0
            ),
            quality: QualityMetrics(
                turnsTotal: 5,
                interruptions: 1,
                interruptionSuccessRate: 0.2,
                thermalThrottleEvents: 0,
                networkDegradations: 0,
                errorsTotal: 2,
                errorsByStage: ["llm": 1, "tts": 1]
            )
        )
    }

    // MARK: - Endpoint Resolution Tests

    func testConfigureWithHostAndPort_buildsLegacyHTTPEndpoint() async {
        let service = MetricsUploadService()
        await service.configure(serverHost: "192.168.1.10")

        let endpoint = await service.endpointURL
        XCTAssertEqual(endpoint?.absoluteString, "http://192.168.1.10:8766/api/metrics")
    }

    func testConfigureWithHTTPSBaseURL_appendsMetricsPath() async {
        let service = MetricsUploadService()
        await service.configure(baseURL: "https://telemetry.example.org")

        let endpoint = await service.endpointURL
        XCTAssertEqual(endpoint?.absoluteString, "https://telemetry.example.org/api/metrics")
    }

    func testConfigureWithTrailingSlash_normalizesPath() async {
        let service = MetricsUploadService()
        await service.configure(baseURL: "https://telemetry.example.org/")

        let endpoint = await service.endpointURL
        XCTAssertEqual(endpoint?.absoluteString, "https://telemetry.example.org/api/metrics")
    }

    func testConfigureWithCustomPortAndPath_preservesBoth() async {
        let service = MetricsUploadService()
        await service.configure(baseURL: "https://example.org:9443/telemetry")

        let endpoint = await service.endpointURL
        XCTAssertEqual(endpoint?.absoluteString, "https://example.org:9443/telemetry/api/metrics")
    }

    func testConfigureWithMissingScheme_disablesUploads() async {
        let service = MetricsUploadService()
        await service.configure(baseURL: "telemetry.example.org")

        let endpoint = await service.endpointURL
        XCTAssertNil(endpoint)
    }

    func testConfigureWithUnsupportedScheme_disablesUploads() async {
        let service = MetricsUploadService()
        await service.configure(baseURL: "ftp://telemetry.example.org")

        let endpoint = await service.endpointURL
        XCTAssertNil(endpoint)
    }

    // MARK: - Consent Gating Tests

    func testConsentDefaultsToOff() {
        XCTAssertFalse(UserDefaults.standard.bool(forKey: consentKey))
    }

    func testUploadWithoutConsent_dropsSnapshotWithoutQueueing() async {
        UserDefaults.standard.set(false, forKey: consentKey)
        let service = MetricsUploadService()

        await service.upload(makeSnapshot(), sessionDuration: 60)

        let pending = await service.pendingUploadCount()
        XCTAssertEqual(pending, 0)
    }

    func testUploadWithConsentButNoEndpoint_queuesSnapshot() async {
        UserDefaults.standard.set(true, forKey: consentKey)
        let service = MetricsUploadService()

        await service.upload(makeSnapshot(), sessionDuration: 60)

        let pending = await service.pendingUploadCount()
        XCTAssertEqual(pending, 1)
    }
}

/// Unit tests for the telemetry fields that feed the upload payload
final class TelemetryUploadMetricsTests: XCTestCase {

    private enum TestStageError: Error {
        case sample
    }

    func testRecordErrorWithStage_incrementsTypedCounters() async {
        let telemetry = TelemetryEngine()

        await telemetry.recordError(TestStageError.sample, stage: .llm)
        await telemetry.recordError(TestStageError.sample, stage: .llm)
        await telemetry.recordError(TestStageError.sample, stage: .network)

        let snapshot = await telemetry.exportMetrics()
        XCTAssertEqual(snapshot.quality.errorsTotal, 3)
        XCTAssertEqual(snapshot.quality.errorsByStage?["llm"], 2)
        XCTAssertEqual(snapshot.quality.errorsByStage?["network"], 1)
    }

    func testStreamFailureEvents_incrementTypedCounters() async {
        let telemetry = TelemetryEngine()

        await telemetry.recordEvent(.sttStreamFailed(TestStageError.sample))
        await telemetry.recordEvent(.ttsStreamFailed(TestStageError.sample))

        let snapshot = await telemetry.exportMetrics()
        XCTAssertEqual(snapshot.quality.errorsTotal, 2)
        XCTAssertEqual(snapshot.quality.errorsByStage?["stt"], 1)
        XCTAssertEqual(snapshot.quality.errorsByStage?["tts"], 1)
    }

    func testRecordTTFALatency_exportsMedianAndP99() async {
        let telemetry = TelemetryEngine()

        // Values chosen to be exactly representable in binary floating point
        await telemetry.recordLatency(.ttfa, 0.25)
        await telemetry.recordLatency(.ttfa, 0.5)
        await telemetry.recordLatency(.ttfa, 0.75)

        let snapshot = await telemetry.exportMetrics()
        XCTAssertEqual(snapshot.latencies.ttfaMedianMs, 500)
        XCTAssertEqual(snapshot.latencies.ttfaP99Ms, 750)
    }

    func testNoTTFASamples_exportsNilTTFA() async {
        let telemetry = TelemetryEngine()

        let snapshot = await telemetry.exportMetrics()
        XCTAssertNil(snapshot.latencies.ttfaMedianMs)
        XCTAssertNil(snapshot.latencies.ttfaP99Ms)
    }
}
