// UnaMentis - Visual Asset Cache Tests
// Unit tests for VisualAssetCache, the offline cache for curriculum visual assets.
//
// Tests use the real on-disk cache (the shared singleton writes to the caches
// directory) plus the real in-memory layer. Each test uses unique asset IDs and
// clears the cache in tearDown so the shared singleton stays isolated between runs.

import XCTest
import Foundation
@testable import UnaMentis

final class VisualAssetCacheTests: XCTestCase {

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        // Start from a clean cache so disk-item counts and sizes are deterministic.
        try await VisualAssetCache.shared.clearAllCache()
    }

    override func tearDown() async throws {
        // Leave the shared cache empty for the next test class.
        try? await VisualAssetCache.shared.clearAllCache()
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Generate a unique asset id so concurrent or repeated runs do not collide.
    private func uniqueAssetId(_ label: String) -> String {
        "\(label)-\(UUID().uuidString)"
    }

    private func makeData(_ bytes: Int, fill: UInt8 = 0xAB) -> Data {
        Data(repeating: fill, count: bytes)
    }

    // MARK: - Cache / Retrieve

    func testCacheThenRetrieve_returnsSameData() async throws {
        let cache = VisualAssetCache.shared
        let assetId = uniqueAssetId("roundtrip")
        let payload = makeData(1024, fill: 0x11)

        try await cache.cache(assetId: assetId, data: payload)
        let retrieved = await cache.retrieve(assetId: assetId)

        XCTAssertEqual(retrieved, payload, "Retrieve should return the exact bytes that were cached")
    }

    func testRetrieve_unknownAsset_returnsNil() async {
        let cache = VisualAssetCache.shared
        let retrieved = await cache.retrieve(assetId: uniqueAssetId("missing"))
        XCTAssertNil(retrieved, "Retrieving an uncached asset should return nil")
    }

    func testCache_writesToDisk_survivesMemoryClear() async throws {
        let cache = VisualAssetCache.shared
        let assetId = uniqueAssetId("disk-survives")
        let payload = makeData(2048, fill: 0x22)

        try await cache.cache(assetId: assetId, data: payload)

        // Drop the memory layer; data must still come back from disk.
        await cache.clearMemoryCache()

        let retrieved = await cache.retrieve(assetId: assetId)
        XCTAssertEqual(retrieved, payload, "Data should be served from disk after the memory cache is cleared")
    }

    func testCache_overwritesExistingAsset() async throws {
        let cache = VisualAssetCache.shared
        let assetId = uniqueAssetId("overwrite")
        let first = makeData(512, fill: 0x01)
        let second = makeData(700, fill: 0x02)

        try await cache.cache(assetId: assetId, data: first)
        try await cache.cache(assetId: assetId, data: second)

        let retrieved = await cache.retrieve(assetId: assetId)
        XCTAssertEqual(retrieved, second, "Re-caching the same id should overwrite the prior data")
    }

    // MARK: - isCached

    func testIsCached_trueAfterCache_falseForUnknown() async throws {
        let cache = VisualAssetCache.shared
        let assetId = uniqueAssetId("is-cached")

        let beforeCache = await cache.isCached(assetId: assetId)
        XCTAssertFalse(beforeCache, "Asset should not be cached before it is written")

        try await cache.cache(assetId: assetId, data: makeData(256))

        let afterCache = await cache.isCached(assetId: assetId)
        XCTAssertTrue(afterCache, "Asset should report cached after it is written")
    }

    func testIsCached_trueFromDiskOnly() async throws {
        let cache = VisualAssetCache.shared
        let assetId = uniqueAssetId("is-cached-disk")

        try await cache.cache(assetId: assetId, data: makeData(256))
        await cache.clearMemoryCache()

        let cached = await cache.isCached(assetId: assetId)
        XCTAssertTrue(cached, "isCached should detect the on-disk file even after the memory cache is cleared")
    }

    // MARK: - Filename Sanitization

    func testCache_unsafeAssetId_roundTrips() async throws {
        // Asset ids that include path separators and other unsafe characters must
        // be sanitized into a safe filename without losing data integrity.
        let cache = VisualAssetCache.shared
        let assetId = uniqueAssetId("path/with:unsafe*chars?and spaces")
        let payload = makeData(333, fill: 0x55)

        try await cache.cache(assetId: assetId, data: payload)
        let retrieved = await cache.retrieve(assetId: assetId)

        XCTAssertEqual(retrieved, payload, "Assets with unsafe characters in the id should still round-trip")
    }

    func testCache_distinctUnsafeIds_doNotCollide() async throws {
        // Two ids that share the same alphanumerics but differ in unsafe characters
        // sanitize to different filenames because each unsafe run becomes one
        // underscore, preserving the boundary between segments.
        let cache = VisualAssetCache.shared
        let suffix = UUID().uuidString
        let idA = "asset/a-\(suffix)"
        let idB = "asset/b-\(suffix)"

        try await cache.cache(assetId: idA, data: makeData(100, fill: 0xAA))
        try await cache.cache(assetId: idB, data: makeData(100, fill: 0xBB))

        let retrievedA = await cache.retrieve(assetId: idA)
        let retrievedB = await cache.retrieve(assetId: idB)

        XCTAssertEqual(retrievedA, makeData(100, fill: 0xAA))
        XCTAssertEqual(retrievedB, makeData(100, fill: 0xBB))
        XCTAssertNotEqual(retrievedA, retrievedB, "Distinct asset ids must map to distinct cache entries")
    }

    // MARK: - Memory Cache Clearing

    func testClearMemoryCache_keepsDiskData() async throws {
        let cache = VisualAssetCache.shared
        let assetId = uniqueAssetId("clear-memory")
        let payload = makeData(4096, fill: 0x33)

        try await cache.cache(assetId: assetId, data: payload)
        await cache.clearMemoryCache()

        // After clearing memory, the stats should report zero memory items but
        // the disk copy should remain.
        let stats = await cache.cacheStatsSnapshot()
        XCTAssertEqual(stats.memoryItemCount, 0, "Memory item count should reset after clearMemoryCache")
        XCTAssertEqual(stats.memorySizeBytes, 0, "Memory size should reset after clearMemoryCache")

        let stillCached = await cache.isCached(assetId: assetId)
        XCTAssertTrue(stillCached, "Disk data should survive a memory-only clear")
    }

    // MARK: - Clear All Cache

    func testClearAllCache_removesEverything() async throws {
        let cache = VisualAssetCache.shared
        let assetId = uniqueAssetId("clear-all")

        try await cache.cache(assetId: assetId, data: makeData(2048))
        try await cache.clearAllCache()

        let cached = await cache.isCached(assetId: assetId)
        XCTAssertFalse(cached, "clearAllCache should remove both memory and disk entries")

        let size = await cache.cacheSize()
        XCTAssertEqual(size, 0, "Cache size should be zero after clearing everything")
    }

    // MARK: - Size Accounting

    func testCacheSize_reflectsWrittenBytes() async throws {
        let cache = VisualAssetCache.shared
        let id1 = uniqueAssetId("size-1")
        let id2 = uniqueAssetId("size-2")

        try await cache.cache(assetId: id1, data: makeData(1000))
        try await cache.cache(assetId: id2, data: makeData(2000))

        // cacheSize sums the in-memory byte count and the on-disk file sizes.
        // Both assets are small enough to live in memory and on disk, so the
        // reported size should be at least the total on-disk payload.
        let size = await cache.cacheSize()
        XCTAssertGreaterThanOrEqual(size, 3000, "Cache size should account for all written bytes")
    }

    // MARK: - Stats

    func testCacheStats_reportsCountsAndLimits() async throws {
        let cache = VisualAssetCache.shared
        let id1 = uniqueAssetId("stats-1")
        let id2 = uniqueAssetId("stats-2")

        try await cache.cache(assetId: id1, data: makeData(500))
        try await cache.cache(assetId: id2, data: makeData(800))

        let stats = await cache.cacheStatsSnapshot()

        XCTAssertEqual(stats.memoryItemCount, 2, "Both small assets should be held in memory")
        XCTAssertEqual(stats.memorySizeBytes, 1300, "Memory size should equal the sum of cached payloads")
        XCTAssertEqual(stats.diskItemCount, 2, "Two files should exist on disk")

        // The configured memory cap is 50MB.
        XCTAssertEqual(stats.maxMemorySizeBytes, 50 * 1024 * 1024, "Max memory size should match the configured cap")

        XCTAssertGreaterThanOrEqual(stats.totalSizeBytes, 2600, "Total size should include both the memory and disk byte counts")
    }

    func testCacheStats_emptyCache_reportsZeros() async {
        let cache = VisualAssetCache.shared
        let stats = await cache.cacheStatsSnapshot()

        XCTAssertEqual(stats.memoryItemCount, 0)
        XCTAssertEqual(stats.memorySizeBytes, 0)
        XCTAssertEqual(stats.diskItemCount, 0)
        XCTAssertEqual(stats.totalSizeBytes, 0)
    }

    // MARK: - downloadAndCache (cached short-circuit)

    func testDownloadAndCache_returnsCachedWithoutNetwork() async throws {
        // When the asset is already cached, downloadAndCache must return the
        // cached bytes and never touch the network. We point it at an unroutable
        // URL to prove no request is made; if it tried to download it would fail.
        let cache = VisualAssetCache.shared
        let assetId = uniqueAssetId("download-cached")
        let payload = makeData(640, fill: 0x77)

        try await cache.cache(assetId: assetId, data: payload)

        // This URL would fail if actually requested, so a success proves the
        // cached short-circuit fired.
        let unroutable = URL(string: "http://127.0.0.1:0/never-requested")!
        let result = try await cache.downloadAndCache(assetId: assetId, from: unroutable)

        XCTAssertEqual(result, payload, "downloadAndCache should return cached data without performing a network request")
    }

    // MARK: - Memory Promotion on Retrieve

    func testRetrieve_promotesDiskHitIntoMemory() async throws {
        let cache = VisualAssetCache.shared
        let assetId = uniqueAssetId("promote")
        let payload = makeData(1500, fill: 0x44)

        try await cache.cache(assetId: assetId, data: payload)

        // Drop memory, then read. The disk hit should be promoted back into memory.
        await cache.clearMemoryCache()
        _ = await cache.retrieve(assetId: assetId)

        let stats = await cache.cacheStatsSnapshot()
        XCTAssertEqual(stats.memoryItemCount, 1, "A disk hit should be promoted into the memory cache")
        XCTAssertEqual(stats.memorySizeBytes, 1500, "Promoted memory size should equal the asset size")
    }
}

// MARK: - Sendable Stats Accessor (test-only)

/// The production `cacheStats()` returns a non-Sendable `[String: Any]`, which the
/// Swift 6 actor boundary forbids returning into a nonisolated test context. This
/// actor-isolated extension runs inside the actor and projects the stats into a
/// Sendable struct, so the test can read the exact same values without a data race.
/// The values still come from the real production `cacheStats()` dictionary.
struct VisualAssetCacheStatsSnapshot: Sendable {
    let memoryItemCount: Int
    let memorySizeBytes: Int
    let diskItemCount: Int
    let totalSizeBytes: Int
    let maxMemorySizeBytes: Int
}

extension VisualAssetCache {
    func cacheStatsSnapshot() async -> VisualAssetCacheStatsSnapshot {
        let stats = await cacheStats()
        return VisualAssetCacheStatsSnapshot(
            memoryItemCount: stats["memoryItemCount"] as? Int ?? -1,
            memorySizeBytes: stats["memorySizeBytes"] as? Int ?? -1,
            diskItemCount: stats["diskItemCount"] as? Int ?? -1,
            totalSizeBytes: stats["totalSizeBytes"] as? Int ?? -1,
            maxMemorySizeBytes: stats["maxMemorySizeBytes"] as? Int ?? -1
        )
    }
}
