// UnaMentis - APIKeyManager Keychain lifecycle tests
// Exercises the real public Keychain round-trip (set, get, has, remove) and the
// settings-driven validateRequiredKeys branching with the real APIKeyManager.
//
// TESTING PHILOSOPHY (Real Over Mock):
// The Keychain is a real internal dependency, so these tests use the real
// Keychain via APIKeyManager.shared. Each test restores prior state so it does
// not clobber any developer's real configured keys.

import XCTest
@testable import UnaMentis

/// Tests for APIKeyManager that touch the real Keychain through its public API.
final class APIKeyManagerKeychainTests: XCTestCase {

    private let manager = APIKeyManager.shared

    /// The KeyType this suite uses for write/read/remove cycles. Brave Search is
    /// a utility key unlikely to be configured in a test or CI environment, which
    /// keeps the round-trip from disturbing real provider keys.
    private let testKeyType: APIKeyManager.KeyType = .braveSearch

    /// Saved value of the test key so we can restore the environment afterwards.
    private var savedTestKeyValue: String?

    override func setUp() async throws {
        try await super.setUp()
        // The unit-test host on the simulator can lack the keychain-access
        // entitlement that SecItemAdd requires, which surfaces as errSecMissingEntitlement
        // (-34018). When that is the case the keychain cannot be exercised at all, so
        // skip rather than report a host-environment limitation as a logic failure.
        // On a properly entitled host or device these tests run and assert in full.
        try await Self.skipIfKeychainWritesUnavailable(manager: manager)
        // Snapshot any existing value so the test is non-destructive.
        savedTestKeyValue = await manager.getKey(testKeyType)
        // Start from a clean slate for the test key.
        try? await manager.removeKey(testKeyType)
    }

    /// Probe whether the keychain accepts writes in this host. Throws XCTSkip when
    /// the host is missing the keychain entitlement (errSecMissingEntitlement).
    private static func skipIfKeychainWritesUnavailable(manager: APIKeyManager) async throws {
        let probeKey: APIKeyManager.KeyType = .braveSearch
        let savedProbe = await manager.getKey(probeKey)
        defer {
            // Best-effort restoration of any probe-displaced value happens in the
            // calling test's normal save/restore; nothing to do here on success.
            _ = savedProbe
        }
        do {
            try await manager.setKey(probeKey, value: "keychain-availability-probe")
            // Clean up the probe write so it does not leak into the test.
            try? await manager.removeKey(probeKey)
            // Restore any prior value the probe may have overwritten.
            if let savedProbe {
                try? await manager.setKey(probeKey, value: savedProbe)
            }
        } catch let APIKeyError.keychainError(status) where status == errSecMissingEntitlement {
            throw XCTSkip("Keychain unavailable in this test host (errSecMissingEntitlement \(status)); skipping keychain round-trip tests")
        }
    }

    override func tearDown() async throws {
        // Restore whatever was there before (or ensure removal if nothing existed).
        if let savedTestKeyValue {
            try? await manager.setKey(testKeyType, value: savedTestKeyValue)
        } else {
            try? await manager.removeKey(testKeyType)
        }
        try await super.tearDown()
    }

    // MARK: - Round-trip lifecycle

    func testSetThenGetReturnsStoredValue() async throws {
        let secret = "test-prefix-\(UUID().uuidString)"

        try await manager.setKey(testKeyType, value: secret)

        let fetched = await manager.getKey(testKeyType)
        XCTAssertEqual(fetched, secret, "getKey should return exactly what setKey stored")
    }

    func testSetOverwritesPreviousValue() async throws {
        try await manager.setKey(testKeyType, value: "first-value")
        try await manager.setKey(testKeyType, value: "second-value")

        let fetched = await manager.getKey(testKeyType)
        XCTAssertEqual(fetched, "second-value",
                       "setKey must replace any existing value rather than duplicate it")
    }

    func testHasKeyReflectsPresenceAndAbsence() async throws {
        // Absent after the clean setUp removal.
        let absent = await manager.hasKey(testKeyType)
        XCTAssertFalse(absent, "hasKey should be false before any value is stored")

        try await manager.setKey(testKeyType, value: "present")
        let present = await manager.hasKey(testKeyType)
        XCTAssertTrue(present, "hasKey should be true after a value is stored")
    }

    func testRemoveKeyDeletesStoredValue() async throws {
        try await manager.setKey(testKeyType, value: "to-be-removed")
        let presentBeforeRemove = await manager.hasKey(testKeyType)
        XCTAssertTrue(presentBeforeRemove)

        try await manager.removeKey(testKeyType)

        let fetched = await manager.getKey(testKeyType)
        XCTAssertNil(fetched, "getKey should return nil after the key is removed")
        let presentAfterRemove = await manager.hasKey(testKeyType)
        XCTAssertFalse(presentAfterRemove)
    }

    func testRemoveMissingKeyDoesNotThrow() async throws {
        // setUp already removed it. Deleting a non-existent key maps errSecItemNotFound
        // to success and must not throw.
        try await manager.removeKey(testKeyType)
        let fetched = await manager.getKey(testKeyType)
        XCTAssertNil(fetched)
    }

    func testStoredValuePreservesUnicode() async throws {
        let unicode = "ключ-\u{1F511}-測試-\(UUID().uuidString)"

        try await manager.setKey(testKeyType, value: unicode)

        let fetched = await manager.getKey(testKeyType)
        XCTAssertEqual(fetched, unicode,
                       "UTF-8 round-trip through the Keychain must be lossless")
    }

    // MARK: - Status aggregation

    func testGetKeyStatusCoversAllKeyTypesAndReflectsStoredKey() async throws {
        try await manager.setKey(testKeyType, value: "configured")

        let status = await manager.getKeyStatus()

        XCTAssertEqual(status.count, APIKeyManager.KeyType.allCases.count,
                       "status must include an entry for every key type")
        XCTAssertEqual(status[testKeyType], true,
                       "status for a freshly stored key should be true")
        // Every key type must be represented (no nil entries).
        for keyType in APIKeyManager.KeyType.allCases {
            XCTAssertNotNil(status[keyType], "missing status entry for \(keyType.rawValue)")
        }
    }
}
