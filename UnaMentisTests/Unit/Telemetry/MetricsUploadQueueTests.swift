// UnaMentis - MetricsUploadQueue Tests
// Real-implementation tests for the offline metrics queue and its AnyCodable
// payload wrapper. The queue persists to UserDefaults under "MetricsUploadQueue";
// each test isolates that key by snapshotting and clearing it in setUp/tearDown.
//
// No mocks: MetricsUploadQueue and AnyCodable are internal types with no paid
// external dependencies, so they are exercised directly.

import XCTest
@testable import UnaMentis

final class MetricsUploadQueueTests: XCTestCase {

    // MARK: - Properties

    private let storageKey = "MetricsUploadQueue"
    private var originalQueueData: Data?

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        originalQueueData = UserDefaults.standard.data(forKey: storageKey)
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    override func tearDown() async throws {
        if let originalQueueData {
            UserDefaults.standard.set(originalQueueData, forKey: storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func makeSnapshot(
        e2eMedianMs: Int = 400,
        turnsTotal: Int = 5,
        ttfaMedianMs: Int? = 250
    ) -> MetricsSnapshot {
        MetricsSnapshot(
            latencies: LatencyMetrics(
                sttMedianMs: 100,
                sttP99Ms: 200,
                llmMedianMs: 150,
                llmP99Ms: 300,
                ttsMedianMs: 80,
                ttsP99Ms: 160,
                e2eMedianMs: e2eMedianMs,
                e2eP99Ms: 900,
                ttfaMedianMs: ttfaMedianMs,
                ttfaP99Ms: ttfaMedianMs.map { $0 + 100 }
            ),
            costs: CostMetrics(
                sttTotal: Decimal(string: "0.01")!,
                ttsTotal: Decimal(string: "0.02")!,
                llmInputTokens: 1000,
                llmOutputTokens: 500,
                llmTotal: Decimal(string: "0.03")!,
                totalSession: Decimal(string: "0.06")!
            ),
            quality: QualityMetrics(
                turnsTotal: turnsTotal,
                interruptions: 1,
                interruptionSuccessRate: 0.2,
                thermalThrottleEvents: 0,
                networkDegradations: 0,
                errorsTotal: 2,
                errorsByStage: ["llm": 1, "tts": 1]
            )
        )
    }

    // MARK: - Enqueue and Count

    func testEnqueue_incrementsCount() async {
        let queue = MetricsUploadQueue()
        await queue.enqueue(makeSnapshot(), sessionDuration: 60)
        await queue.enqueue(makeSnapshot(), sessionDuration: 120)

        let count = await queue.count
        XCTAssertEqual(count, 2)
    }

    func testEnqueue_transformsSnapshotFieldsIntoPayload() async {
        let queue = MetricsUploadQueue()
        await queue.enqueue(makeSnapshot(e2eMedianMs: 432, turnsTotal: 7), sessionDuration: 90)

        let pending = await queue.getPending()
        XCTAssertEqual(pending.count, 1)

        guard let payload = pending.first?.payload else {
            XCTFail("expected a queued payload")
            return
        }
        // Spot check that core latency/quality fields are carried through.
        XCTAssertEqual(payload["e2eLatencyMedian"]?.value as? Int, 432)
        XCTAssertEqual(payload["turnsTotal"]?.value as? Int, 7)
        XCTAssertEqual(payload["sessionDuration"]?.value as? Double, 90)
        XCTAssertEqual(payload["error_count"]?.value as? Int, 2)
    }

    func testEnqueue_includesTTFAWhenPresent() async {
        let queue = MetricsUploadQueue()
        await queue.enqueue(makeSnapshot(ttfaMedianMs: 275), sessionDuration: 60)

        let pending = await queue.getPending()
        XCTAssertEqual(pending.first?.payload["ttfaMedian"]?.value as? Int, 275)
        XCTAssertEqual(pending.first?.payload["ttfaP99"]?.value as? Int, 375)
    }

    func testEnqueue_omitsTTFAWhenAbsent() async {
        let queue = MetricsUploadQueue()
        await queue.enqueue(makeSnapshot(ttfaMedianMs: nil), sessionDuration: 60)

        let pending = await queue.getPending()
        XCTAssertNil(pending.first?.payload["ttfaMedian"])
        XCTAssertNil(pending.first?.payload["ttfaP99"])
    }

    // MARK: - getPending Filtering

    func testGetPending_excludesItemsAtOrAboveMaxRetries() async {
        let queue = MetricsUploadQueue()
        await queue.enqueue(makeSnapshot(), sessionDuration: 60)

        let pending = await queue.getPending()
        guard let id = pending.first?.id else {
            XCTFail("expected one pending item")
            return
        }

        // maxRetries is 5. Increment retries to that threshold.
        for _ in 0..<5 {
            await queue.incrementRetry(id)
        }

        // The item still occupies the queue but is no longer reported as pending.
        let remainingCount = await queue.count
        XCTAssertEqual(remainingCount, 1)
        let stillPending = await queue.getPending()
        XCTAssertTrue(stillPending.isEmpty, "an item at maxRetries must be filtered out of pending")
    }

    func testIncrementRetry_belowThreshold_keepsItemPending() async {
        let queue = MetricsUploadQueue()
        await queue.enqueue(makeSnapshot(), sessionDuration: 60)
        guard let id = await queue.getPending().first?.id else {
            XCTFail("expected one pending item")
            return
        }

        await queue.incrementRetry(id)
        await queue.incrementRetry(id)

        let pending = await queue.getPending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.retryCount, 2, "retry count must persist across increments")
    }

    func testIncrementRetry_preservesPayloadAndId() async {
        let queue = MetricsUploadQueue()
        await queue.enqueue(makeSnapshot(e2eMedianMs: 321), sessionDuration: 60)
        guard let original = await queue.getPending().first else {
            XCTFail("expected one pending item")
            return
        }

        await queue.incrementRetry(original.id)

        guard let updated = await queue.getPending().first else {
            XCTFail("expected the item to remain pending")
            return
        }
        XCTAssertEqual(updated.id, original.id, "the item identity must be preserved")
        XCTAssertEqual(updated.payload["e2eLatencyMedian"]?.value as? Int, 321)
        XCTAssertEqual(updated.queuedAt, original.queuedAt)
    }

    // MARK: - markCompleted

    func testMarkCompleted_removesOnlyTheMatchingItem() async {
        let queue = MetricsUploadQueue()
        await queue.enqueue(makeSnapshot(e2eMedianMs: 100), sessionDuration: 30)
        await queue.enqueue(makeSnapshot(e2eMedianMs: 200), sessionDuration: 60)

        let pending = await queue.getPending()
        XCTAssertEqual(pending.count, 2)
        let firstId = pending[0].id

        await queue.markCompleted(firstId)

        let remaining = await queue.getPending()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertFalse(remaining.contains { $0.id == firstId })
    }

    func testMarkCompleted_unknownId_isNoOp() async {
        let queue = MetricsUploadQueue()
        await queue.enqueue(makeSnapshot(), sessionDuration: 60)

        await queue.markCompleted(UUID())

        let count = await queue.count
        XCTAssertEqual(count, 1)
    }

    // MARK: - clear

    func testClear_emptiesTheQueue() async {
        let queue = MetricsUploadQueue()
        await queue.enqueue(makeSnapshot(), sessionDuration: 60)
        await queue.enqueue(makeSnapshot(), sessionDuration: 60)

        await queue.clear()

        let count = await queue.count
        XCTAssertEqual(count, 0)
        let pending = await queue.getPending()
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - Persistence Round Trip

    func testPersistence_survivesAcrossNewInstances() async {
        let queue = MetricsUploadQueue()
        await queue.enqueue(makeSnapshot(e2eMedianMs: 654, turnsTotal: 9), sessionDuration: 75)

        // A fresh instance loads the persisted queue from UserDefaults in init.
        let reloaded = MetricsUploadQueue()
        let pending = await reloaded.getPending()

        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.payload["e2eLatencyMedian"]?.value as? Int, 654)
        XCTAssertEqual(pending.first?.payload["turnsTotal"]?.value as? Int, 9)
    }

    func testClear_persistsEmptyStateAcrossInstances() async {
        let queue = MetricsUploadQueue()
        await queue.enqueue(makeSnapshot(), sessionDuration: 60)
        await queue.clear()

        let reloaded = MetricsUploadQueue()
        let count = await reloaded.count
        XCTAssertEqual(count, 0)
    }

    func testRetryCount_persistsAcrossInstances() async {
        let queue = MetricsUploadQueue()
        await queue.enqueue(makeSnapshot(), sessionDuration: 60)
        guard let id = await queue.getPending().first?.id else {
            XCTFail("expected one pending item")
            return
        }
        await queue.incrementRetry(id)
        await queue.incrementRetry(id)

        let reloaded = MetricsUploadQueue()
        let pending = await reloaded.getPending()
        XCTAssertEqual(pending.first?.retryCount, 2)
    }
}

// MARK: - AnyCodable Tests

final class AnyCodableTests: XCTestCase {

    private func roundTrip(_ value: AnyCodable) throws -> AnyCodable {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(AnyCodable.self, from: data)
    }

    func testInt_roundTrips() throws {
        let decoded = try roundTrip(AnyCodable(42))
        XCTAssertEqual(decoded.value as? Int, 42)
    }

    func testDouble_roundTrips() throws {
        let decoded = try roundTrip(AnyCodable(3.5))
        XCTAssertEqual(decoded.value as? Double, 3.5)
    }

    func testString_roundTrips() throws {
        let decoded = try roundTrip(AnyCodable("hello"))
        XCTAssertEqual(decoded.value as? String, "hello")
    }

    func testBool_roundTrips() throws {
        // Bool is decoded before Int, so true must come back as a Bool.
        let decoded = try roundTrip(AnyCodable(true))
        XCTAssertEqual(decoded.value as? Bool, true)
    }

    func testArray_roundTrips() throws {
        let decoded = try roundTrip(AnyCodable([1, 2, 3]))
        let array = decoded.value as? [Any]
        XCTAssertEqual(array?.count, 3)
        XCTAssertEqual(array?[0] as? Int, 1)
        XCTAssertEqual(array?[2] as? Int, 3)
    }

    func testNestedDictionary_roundTrips() throws {
        let original = AnyCodable(["llm": 1, "tts": 2] as [String: Any])
        let decoded = try roundTrip(original)
        let dict = decoded.value as? [String: Any]
        XCTAssertEqual(dict?["llm"] as? Int, 1)
        XCTAssertEqual(dict?["tts"] as? Int, 2)
    }

    func testNull_encodesAndDecodesAsNSNull() throws {
        // An unsupported value type encodes as null and decodes back to NSNull.
        let encoded = try JSONEncoder().encode(AnyCodable(Date()))
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: encoded)
        XCTAssertTrue(decoded.value is NSNull)
    }

    func testHeterogeneousDictionary_roundTrips() throws {
        let original = AnyCodable([
            "count": 5,
            "rate": 0.5,
            "stage": "llm",
            "ok": true
        ] as [String: Any])
        let decoded = try roundTrip(original)
        let dict = decoded.value as? [String: Any]
        XCTAssertEqual(dict?["count"] as? Int, 5)
        XCTAssertEqual(dict?["rate"] as? Double, 0.5)
        XCTAssertEqual(dict?["stage"] as? String, "llm")
        XCTAssertEqual(dict?["ok"] as? Bool, true)
    }
}
