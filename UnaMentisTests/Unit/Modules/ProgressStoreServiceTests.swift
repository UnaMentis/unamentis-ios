// UnaMentis - Progress Store Service Tests
// MODULE_SDK_SPEC.md section 5.4, capabilities "progress/1", "proficiency/1".
//
// Real over mock: uses a real FileProgressStoreService rooted at a unique temp
// directory per test. Verifies attempt round-trip, module-private KV isolation,
// proficiency read/write, and that deleteAll erases only the target module.

import XCTest
@testable import UnaMentis

final class ProgressStoreServiceTests: XCTestCase {

    private func makeStore() -> (FileProgressStoreService, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProgressStoreTests-\(UUID().uuidString)", isDirectory: true)
        return (FileProgressStoreService(root: root), root)
    }

    private func removeRoot(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Attempt round-trip

    func testAttempt_roundTrips() async throws {
        let (store, root) = makeStore()
        defer { removeRoot(root) }

        let record = AttemptRecord(
            module: "knowledge-bowl",
            domain: StandardDomain("science"),
            itemId: "q1",
            response: "Au",
            correct: true,
            latencyMs: 900
        )
        await store.store(record)

        let export = await store.exportAll(for: "knowledge-bowl")
        XCTAssertEqual(export.attempts.count, 1)
        let read = try XCTUnwrap(export.attempts.first)
        // Compare the load-bearing fields. Timestamps round-trip through ISO8601
        // (second precision), so compare them within a tolerance rather than by
        // exact equality.
        XCTAssertEqual(read.id, record.id)
        XCTAssertEqual(read.module, record.module)
        XCTAssertEqual(read.domain, record.domain)
        XCTAssertEqual(read.itemId, record.itemId)
        XCTAssertEqual(read.response, record.response)
        XCTAssertEqual(read.correct, record.correct)
        XCTAssertEqual(read.latencyMs, record.latencyMs)
        XCTAssertEqual(read.timestamp.timeIntervalSince1970, record.timestamp.timeIntervalSince1970, accuracy: 1.0)
    }

    func testAttempts_accumulateForModule() async {
        let (store, root) = makeStore()
        defer { removeRoot(root) }

        for i in 0..<5 {
            await store.store(AttemptRecord(
                module: "m", domain: StandardDomain("d"), itemId: "q\(i)",
                response: nil, correct: i.isMultiple(of: 2), latencyMs: 100
            ))
        }
        let export = await store.exportAll(for: "m")
        XCTAssertEqual(export.attempts.count, 5)
    }

    // MARK: - KV namespacing

    func testKV_isolatesModules() async {
        let (store, root) = makeStore()
        defer { removeRoot(root) }

        let kvA = store.keyValue(namespace: "module-a")
        let kvB = store.keyValue(namespace: "module-b")

        await kvA.setString("value-a", forKey: "shared-key")
        await kvB.setString("value-b", forKey: "shared-key")

        let a = await kvA.string(forKey: "shared-key")
        let b = await kvB.string(forKey: "shared-key")
        XCTAssertEqual(a, "value-a")
        XCTAssertEqual(b, "value-b")

        // module-a cannot see module-b's other keys.
        await kvB.setString("only-b", forKey: "b-only-key")
        let leaked = await kvA.string(forKey: "b-only-key")
        XCTAssertNil(leaked)
    }

    func testKV_dataRoundTrips() async {
        let (store, root) = makeStore()
        defer { removeRoot(root) }

        let kv = store.keyValue(namespace: "m")
        let payload = Data([0x01, 0x02, 0x03])
        await kv.setData(payload, forKey: "blob")
        let read = await kv.data(forKey: "blob")
        XCTAssertEqual(read, payload)
    }

    // MARK: - Proficiency

    func testProficiency_defaultsToZero() async {
        let (store, root) = makeStore()
        defer { removeRoot(root) }

        let prof = await store.proficiency(for: StandardDomain("history"))
        XCTAssertEqual(prof.mastery, 0)
        XCTAssertEqual(prof.observationCount, 0)
    }

    func testProficiency_reportMasteryMovesEstimate() async {
        let (store, root) = makeStore()
        defer { removeRoot(root) }

        let domain = StandardDomain("science")
        await store.reportMastery(MasteryObservation(module: "m", domain: domain, signal: 100))
        await store.reportMastery(MasteryObservation(module: "m", domain: domain, signal: 0))

        let prof = await store.proficiency(for: domain)
        XCTAssertEqual(prof.observationCount, 2)
        // Two observations of 100 and 0 fold to an estimate strictly between them.
        XCTAssertGreaterThan(prof.mastery, 0)
        XCTAssertLessThan(prof.mastery, 100)
    }

    // MARK: - Deletion boundary

    func testDeleteAll_deletesOnlyTargetModule() async {
        let (store, root) = makeStore()
        defer { removeRoot(root) }

        await store.store(AttemptRecord(
            module: "keep-me", domain: StandardDomain("d"), itemId: "q",
            response: nil, correct: true, latencyMs: 1
        ))
        await store.store(AttemptRecord(
            module: "delete-me", domain: StandardDomain("d"), itemId: "q",
            response: nil, correct: true, latencyMs: 1
        ))
        await store.keyValue(namespace: "keep-me").setString("v", forKey: "k")
        await store.keyValue(namespace: "delete-me").setString("v", forKey: "k")

        await store.deleteAll(for: "delete-me")

        let deleted = await store.exportAll(for: "delete-me")
        XCTAssertTrue(deleted.attempts.isEmpty)
        XCTAssertTrue(deleted.keyValues.isEmpty)

        // The other module's data survives.
        let kept = await store.exportAll(for: "keep-me")
        XCTAssertEqual(kept.attempts.count, 1)
        XCTAssertEqual(kept.keyValues["k"], "v")
    }

    func testDeleteAll_leavesProficiencyIntact() async {
        let (store, root) = makeStore()
        defer { removeRoot(root) }

        let domain = StandardDomain("science")
        await store.reportMastery(MasteryObservation(module: "delete-me", domain: domain, signal: 80))
        await store.deleteAll(for: "delete-me")

        // Proficiency is shared substrate: one module's erasure must not wipe a
        // domain other modules also contribute to.
        let prof = await store.proficiency(for: domain)
        XCTAssertGreaterThan(prof.mastery, 0)
    }
}
