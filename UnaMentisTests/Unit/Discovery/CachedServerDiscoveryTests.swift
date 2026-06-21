// UnaMentis - Cached Server Discovery Tests
// Exercises the real cache read/write logic and the no-network early returns
// of discover() against a real, isolated UserDefaults suite. The healthy-cache
// path performs a live URLSession request, so it is intentionally not exercised
// here; only the branches that return before any network call are covered.

import XCTest
@testable import UnaMentis

final class CachedServerDiscoveryTests: XCTestCase {

    private let suiteName = "discovery.cached.tests"
    private var defaults: UserDefaults!

    // The keys mirror CachedServerDiscovery.Keys (which are private), so the
    // tests verify the persisted layout rather than trusting the implementation.
    private let hostKey = "discovery.cached.host"
    private let portKey = "discovery.cached.port"
    private let nameKey = "discovery.cached.name"
    private let timestampKey = "discovery.cached.timestamp"

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(defaults, "Could not create an isolated UserDefaults suite")
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try super.tearDownWithError()
    }

    private func makeDiscovery() -> CachedServerDiscovery {
        // Hand the actor its own UserDefaults instance bound to the same suite.
        // A freshly constructed instance lives in its own isolation region (it is
        // not reachable from the task-isolated test `self`), so sending it across
        // the actor boundary is safe. Because UserDefaults(suiteName:) shares one
        // backing store per suite, this instance and `self.defaults` read and write
        // the exact same persisted values, so the assertions remain valid.
        let actorDefaults = UserDefaults(suiteName: suiteName)!
        return CachedServerDiscovery(userDefaults: actorDefaults)
    }

    // MARK: - Tier identity

    func testTierIsCached() async {
        let discovery = makeDiscovery()
        let tier = await discovery.tier
        XCTAssertEqual(tier, .cached)
    }

    // MARK: - saveToCache

    func testSaveToCacheWritesAllFields() async {
        let discovery = makeDiscovery()
        let server = DiscoveredServer(
            name: "Saved Lab",
            host: "192.168.1.77",
            port: 8766,
            discoveryMethod: .bonjour
        )

        let before = Date()
        await discovery.saveToCache(server)
        let after = Date()

        XCTAssertEqual(defaults.string(forKey: hostKey), "192.168.1.77")
        XCTAssertEqual(defaults.integer(forKey: portKey), 8766)
        XCTAssertEqual(defaults.string(forKey: nameKey), "Saved Lab")

        // saveToCache stamps "now", not the server's original timestamp.
        let storedTimestamp = defaults.object(forKey: timestampKey) as? Date
        XCTAssertNotNil(storedTimestamp, "A fresh timestamp must be persisted")
        if let storedTimestamp {
            XCTAssertGreaterThanOrEqual(storedTimestamp, before)
            XCTAssertLessThanOrEqual(storedTimestamp, after)
        }
    }

    func testSaveToCacheOverwritesPreviousEntry() async {
        let discovery = makeDiscovery()
        await discovery.saveToCache(
            DiscoveredServer(name: "Old", host: "10.0.0.1", port: 1111, discoveryMethod: .manual)
        )
        await discovery.saveToCache(
            DiscoveredServer(name: "New", host: "10.0.0.2", port: 2222, discoveryMethod: .manual)
        )

        XCTAssertEqual(defaults.string(forKey: hostKey), "10.0.0.2")
        XCTAssertEqual(defaults.integer(forKey: portKey), 2222)
        XCTAssertEqual(defaults.string(forKey: nameKey), "New")
    }

    // MARK: - clearCache

    func testClearCacheRemovesAllFields() async {
        let discovery = makeDiscovery()
        await discovery.saveToCache(
            DiscoveredServer(name: "Temp", host: "172.16.0.5", port: 8766, discoveryMethod: .cached)
        )

        await discovery.clearCache()

        XCTAssertNil(defaults.string(forKey: hostKey))
        XCTAssertEqual(defaults.integer(forKey: portKey), 0, "Removed integer key reads back as 0")
        XCTAssertNil(defaults.string(forKey: nameKey))
        XCTAssertNil(defaults.object(forKey: timestampKey))
    }

    func testClearCacheIsIdempotent() async {
        let discovery = makeDiscovery()
        // Clearing an already-empty cache must not crash or write anything.
        await discovery.clearCache()
        await discovery.clearCache()
        XCTAssertNil(defaults.string(forKey: hostKey))
    }

    // MARK: - discover() no-network early returns

    func testDiscoverReturnsNilWhenNoCachedHost() async throws {
        let discovery = makeDiscovery()
        // Empty isolated suite means no cached host, so discover short-circuits
        // before any network access.
        let result = try await discovery.discover(timeout: 1)
        XCTAssertNil(result, "No cached host should produce no server, with no network call")
    }

    func testDiscoverReturnsNilWhenCachedHostIsEmptyString() async throws {
        defaults.set("", forKey: hostKey)
        defaults.set(8766, forKey: portKey)

        let discovery = makeDiscovery()
        let result = try await discovery.discover(timeout: 1)
        XCTAssertNil(result, "An empty cached host must be treated as no cache")
    }

    func testDiscoverReturnsNilWhenPortIsInvalid() async throws {
        defaults.set("192.168.1.20", forKey: hostKey)
        defaults.set(0, forKey: portKey) // port must be > 0

        let discovery = makeDiscovery()
        let result = try await discovery.discover(timeout: 1)
        XCTAssertNil(result, "A non-positive cached port must be rejected before any health check")
    }

    func testDiscoverReturnsNilWhenPortMissing() async throws {
        // Host present but no port key at all: integer(forKey:) returns 0, rejected.
        defaults.set("192.168.1.21", forKey: hostKey)

        let discovery = makeDiscovery()
        let result = try await discovery.discover(timeout: 1)
        XCTAssertNil(result, "A missing cached port reads as 0 and must be rejected")
    }

    // MARK: - Round trip through the actor's own API

    func testSaveThenClearLeavesDiscoverWithNothingToFind() async throws {
        let discovery = makeDiscovery()
        await discovery.saveToCache(
            DiscoveredServer(name: "Cycle", host: "192.168.1.99", port: 8766, discoveryMethod: .cached)
        )
        XCTAssertEqual(defaults.string(forKey: hostKey), "192.168.1.99")

        await discovery.clearCache()

        // After clearing, the no-cache early return applies again.
        let result = try await discovery.discover(timeout: 1)
        XCTAssertNil(result)
    }

    // MARK: - Cancellation

    func testCancelDoesNotThrowAndIsObservable() async throws {
        let discovery = makeDiscovery()
        await discovery.cancel()
        // With an empty cache, discover still returns nil cleanly after a cancel.
        let result = try await discovery.discover(timeout: 1)
        XCTAssertNil(result)
    }
}
