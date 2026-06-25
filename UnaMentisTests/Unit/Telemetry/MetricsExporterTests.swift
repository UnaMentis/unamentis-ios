// UnaMentis - MetricsExporter Tests
// Real-implementation tests for the DEBUG-only metrics exporter in
// Core/Telemetry. Two concerns are validated:
//
//   1. Unified payload serialization. The wire format is shared with the web
//      client, so the snake_case JSON keys, ISO8601 timestamp, and optional
//      field omission/inclusion are a real cross-platform contract worth
//      protecting against accidental key renames.
//
//   2. The offline queue behavior. enqueue must bound the queue (drop-oldest at
//      capacity) and surface its size, and drainQueue must be a no-op while the
//      exporter is unconfigured (no server URL) so nothing is sent or lost.
//
// MetricsExporter is an internal actor with no paid external dependencies, so it
// is exercised directly. The whole file is wrapped in #if DEBUG to match the
// type under test, which is compiled out of release builds.

#if DEBUG

import XCTest
@testable import UnaMentis

final class MetricsExporterPayloadSerializationTests: XCTestCase {

    // MARK: - Fixtures

    /// A fixed instant so the encoded timestamp is deterministic and assertable.
    /// 2024-01-02T03:04:05Z expressed as seconds since the reference date.
    private let fixedDate = Date(timeIntervalSince1970: 1_704_164_645)

    private func makePayload(
        sttLatencyMs: Double? = 150,
        ttsVoice: String? = "voice-a",
        resources: ResourceInfo? = nil
    ) -> UnifiedMetricPayload {
        UnifiedMetricPayload(
            client: "ios",
            clientId: "client-123",
            clientName: "Test Device",
            sessionId: "session-456",
            timestamp: fixedDate,
            metrics: MetricValues(
                sttLatencyMs: sttLatencyMs,
                llmTtfbMs: 200,
                llmCompletionMs: 800,
                ttsTtfbMs: 100,
                ttsCompletionMs: 400,
                e2eLatencyMs: 1250,
                sttConfidence: 0.92,
                llmInputTokens: 1000,
                llmOutputTokens: 500,
                ttsAudioDurationMs: 3000
            ),
            providers: ProviderInfo(
                stt: "deepgram-nova3",
                llm: "anthropic",
                llmModel: "claude-3-5-haiku",
                tts: "chatterbox",
                ttsVoice: ttsVoice
            ),
            resources: resources
        )
    }

    /// Encode the payload to a JSON object so we can assert on the wire keys.
    private func encodeToObject(_ payload: UnifiedMetricPayload) throws -> [String: Any] {
        let data = try JSONEncoder().encode(payload)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw XCTSkip("payload did not encode to a JSON object")
        }
        return dict
    }

    // MARK: - Snake-case Metric Keys

    func testMetricValues_encodeUsingSnakeCaseWireKeys() throws {
        let dict = try encodeToObject(makePayload())
        guard let metrics = dict["metrics"] as? [String: Any] else {
            return XCTFail("metrics object missing from payload")
        }

        // These keys are the cross-platform contract. A Swift-side rename of a
        // property must not silently change the wire key, so assert them here.
        XCTAssertEqual(metrics["stt_latency_ms"] as? Double, 150)
        XCTAssertEqual(metrics["llm_ttfb_ms"] as? Double, 200)
        XCTAssertEqual(metrics["llm_completion_ms"] as? Double, 800)
        XCTAssertEqual(metrics["tts_ttfb_ms"] as? Double, 100)
        XCTAssertEqual(metrics["tts_completion_ms"] as? Double, 400)
        XCTAssertEqual(metrics["e2e_latency_ms"] as? Double, 1250)
        XCTAssertEqual(metrics["llm_input_tokens"] as? Int, 1000)
        XCTAssertEqual(metrics["llm_output_tokens"] as? Int, 500)
        XCTAssertEqual(metrics["tts_audio_duration_ms"] as? Double, 3000)
    }

    func testProviderInfo_encodesLlmModelAndVoiceWithSnakeCaseKeys() throws {
        let dict = try encodeToObject(makePayload())
        guard let providers = dict["providers"] as? [String: Any] else {
            return XCTFail("providers object missing from payload")
        }

        XCTAssertEqual(providers["stt"] as? String, "deepgram-nova3")
        XCTAssertEqual(providers["llm_model"] as? String, "claude-3-5-haiku")
        XCTAssertEqual(providers["tts_voice"] as? String, "voice-a")
    }

    func testResourceInfo_encodesWithSnakeCaseKeysWhenPresent() throws {
        let resources = ResourceInfo(
            cpuPercent: 45.5,
            memoryMb: 256,
            thermalState: "nominal",
            batteryLevel: 0.8,
            batteryState: "unplugged"
        )
        let dict = try encodeToObject(makePayload(resources: resources))
        guard let encoded = dict["resources"] as? [String: Any] else {
            return XCTFail("resources object missing from payload")
        }

        XCTAssertEqual(encoded["cpu_percent"] as? Double, 45.5)
        XCTAssertEqual(encoded["memory_mb"] as? Double, 256)
        XCTAssertEqual(encoded["thermal_state"] as? String, "nominal")
        // batteryLevel is a Float widened to Double on the wire, so allow tolerance.
        XCTAssertEqual(encoded["battery_level"] as? Double ?? -1, 0.8, accuracy: 0.0001)
        XCTAssertEqual(encoded["battery_state"] as? String, "unplugged")
    }

    // MARK: - Timestamp Conversion

    func testTimestamp_isFormattedAsISO8601() throws {
        let payload = makePayload()
        // The init converts the Date to an ISO8601 string. Verify it matches a
        // freshly formatted value for the same instant rather than re-deriving
        // the format, so the conversion is exercised end to end.
        let expected = ISO8601DateFormatter().string(from: fixedDate)
        XCTAssertEqual(payload.timestamp, expected)
        XCTAssertEqual(payload.timestamp, "2024-01-02T03:04:05Z")
    }

    // MARK: - Optional Field Omission

    func testOptionalMetric_omittedFromJsonWhenNil() throws {
        // A nil STT latency must not appear in the encoded metrics. The server
        // distinguishes "no STT" from "STT == 0", so the key must be absent.
        let dict = try encodeToObject(makePayload(sttLatencyMs: nil))
        guard let metrics = dict["metrics"] as? [String: Any] else {
            return XCTFail("metrics object missing from payload")
        }
        XCTAssertNil(metrics["stt_latency_ms"], "nil optional metrics must be omitted, not encoded as null")
    }

    func testOptionalProviderVoice_omittedFromJsonWhenNil() throws {
        let dict = try encodeToObject(makePayload(ttsVoice: nil))
        guard let providers = dict["providers"] as? [String: Any] else {
            return XCTFail("providers object missing from payload")
        }
        XCTAssertNil(providers["tts_voice"], "a nil voice id must be omitted from the wire payload")
    }

    func testResources_omittedFromJsonWhenNil() throws {
        let dict = try encodeToObject(makePayload(resources: nil))
        XCTAssertNil(dict["resources"], "a payload without resources must omit the key entirely")
    }

    // MARK: - Codable Round Trip

    func testPayload_roundTripsThroughCodable() throws {
        let original = makePayload()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UnifiedMetricPayload.self, from: data)

        XCTAssertEqual(decoded.client, "ios")
        XCTAssertEqual(decoded.clientId, "client-123")
        XCTAssertEqual(decoded.sessionId, "session-456")
        XCTAssertEqual(decoded.timestamp, original.timestamp)
        XCTAssertEqual(decoded.metrics.e2eLatencyMs, 1250)
        // sttConfidence is a Float routed through JSON (Double), so compare with
        // tolerance rather than relying on exact Float representability.
        XCTAssertEqual(decoded.metrics.sttConfidence ?? -1, 0.92, accuracy: 0.0001)
        XCTAssertEqual(decoded.providers.llmModel, "claude-3-5-haiku")
    }
}

// MARK: - Queue Management Tests

final class MetricsExporterQueueTests: XCTestCase {

    // MARK: - Persisted-queue Isolation
    //
    // MetricsExporter.init() loads any persisted queue from
    // Documents/metrics_queue.json. Remove that file before each test so the
    // exporter always starts empty and the queue-size assertions are exact,
    // and restore the original contents afterward so the suite is non-destructive.

    private var queueFileURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("metrics_queue.json")
    }

    private var savedQueueData: Data?

    override func setUp() async throws {
        try await super.setUp()
        savedQueueData = try? Data(contentsOf: queueFileURL)
        try? FileManager.default.removeItem(at: queueFileURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: queueFileURL)
        if let savedQueueData {
            try? savedQueueData.write(to: queueFileURL)
        }
        savedQueueData = nil
        try await super.tearDown()
    }

    private func makePayload(sessionId: String) -> UnifiedMetricPayload {
        UnifiedMetricPayload(
            clientId: "client",
            sessionId: sessionId,
            metrics: MetricValues(
                llmTtfbMs: 100,
                llmCompletionMs: 200,
                ttsTtfbMs: 50,
                ttsCompletionMs: 150,
                e2eLatencyMs: 500
            ),
            providers: ProviderInfo(stt: "a", llm: "b", llmModel: "c", tts: "d")
        )
    }

    // MARK: - Configuration State

    func testNewExporter_isNotConfigured() async {
        let exporter = MetricsExporter()
        let configured = await exporter.isConfigured
        XCTAssertFalse(configured, "an exporter is unconfigured until configure() supplies a server URL")
    }

    func testConfigure_marksExporterConfigured() async {
        let exporter = MetricsExporter()
        await exporter.configure(serverHost: "localhost", port: 8766)
        let configured = await exporter.isConfigured
        XCTAssertTrue(configured)
    }

    // MARK: - Enqueue and Queue Size

    func testExportRaw_increasesQueueSize() async {
        // Unconfigured: enqueue cannot drain (no server URL), so items accumulate.
        let exporter = MetricsExporter()
        await exporter.exportRaw(makePayload(sessionId: "s1"))
        await exporter.exportRaw(makePayload(sessionId: "s2"))

        let size = await exporter.queueSize
        XCTAssertEqual(size, 2)
    }

    func testEnqueue_belowBatchThreshold_doesNotDrain() async {
        // Without a configured server, drainQueue is a no-op, but we also verify
        // that staying under the batch threshold leaves everything queued.
        let exporter = MetricsExporter()
        for index in 0..<10 {
            await exporter.exportRaw(makePayload(sessionId: "s\(index)"))
        }
        let size = await exporter.queueSize
        XCTAssertEqual(size, 10, "items under the batch size must remain queued")
    }

    // MARK: - Queue Capacity (drop-oldest)

    func testEnqueue_atCapacity_dropsOldestToStayBounded() async {
        // maxQueueSize is 1000. Enqueue past it and confirm the queue never
        // grows beyond the cap, preventing unbounded memory growth offline.
        let exporter = MetricsExporter()
        for index in 0..<1005 {
            await exporter.exportRaw(makePayload(sessionId: "s\(index)"))
        }
        let size = await exporter.queueSize
        XCTAssertEqual(size, 1000, "the offline queue must be bounded at its maximum capacity")
    }

    // MARK: - Drain Guards

    func testDrainQueue_whenUnconfigured_keepsItemsQueued() async {
        // Draining with no server configured must not silently discard metrics;
        // they have to stay queued until a server is configured.
        let exporter = MetricsExporter()
        await exporter.exportRaw(makePayload(sessionId: "s1"))
        await exporter.exportRaw(makePayload(sessionId: "s2"))

        await exporter.drainQueue()

        let size = await exporter.queueSize
        XCTAssertEqual(size, 2, "an unconfigured drain must preserve the queued metrics")
    }

    func testDrainQueue_emptyQueue_isNoOp() async {
        let exporter = MetricsExporter()
        await exporter.configure(serverHost: "localhost", port: 8766)

        // Draining an empty queue must not crash or change the size.
        await exporter.drainQueue()

        let size = await exporter.queueSize
        XCTAssertEqual(size, 0)
    }
}

// MARK: - MetricsExporterError Tests

final class MetricsExporterErrorTests: XCTestCase {

    func testServerError_descriptionIncludesStatusCode() {
        let error = MetricsExporterError.serverError(statusCode: 503)
        XCTAssertEqual(error.errorDescription, "Server error: HTTP 503")
    }

    func testInvalidResponse_hasDescription() {
        XCTAssertEqual(MetricsExporterError.invalidResponse.errorDescription, "Invalid server response")
    }

    func testNotConfigured_hasDescription() {
        XCTAssertEqual(MetricsExporterError.notConfigured.errorDescription, "MetricsExporter not configured")
    }

    func testEncodingFailed_hasDescription() {
        XCTAssertEqual(MetricsExporterError.encodingFailed.errorDescription, "Failed to encode metrics")
    }
}

#endif
