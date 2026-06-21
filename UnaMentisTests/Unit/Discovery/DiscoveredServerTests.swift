// UnaMentis - Discovered Server Model Tests
// Verifies URL construction, init defaults, Codable round-trips and Equatable
// for the value type that flows across actor boundaries, plus the discovery
// method and discovery state helpers that drive the connection UI.

import XCTest
@testable import UnaMentis

final class DiscoveredServerTests: XCTestCase {

    // MARK: - Init Defaults

    func testInitAppliesDefaults() {
        let before = Date()
        let server = DiscoveredServer(
            name: "Lab Server",
            host: "192.168.1.50",
            port: 8766,
            discoveryMethod: .bonjour
        )
        let after = Date()

        XCTAssertEqual(server.name, "Lab Server")
        XCTAssertEqual(server.host, "192.168.1.50")
        XCTAssertEqual(server.port, 8766)
        XCTAssertEqual(server.discoveryMethod, .bonjour)
        XCTAssertTrue(server.metadata.isEmpty, "Metadata should default to empty")

        // Default timestamp is the moment of construction.
        XCTAssertGreaterThanOrEqual(server.timestamp, before)
        XCTAssertLessThanOrEqual(server.timestamp, after)
    }

    func testInitGeneratesUniqueIdentifiers() {
        let a = DiscoveredServer(name: "A", host: "h", port: 1, discoveryMethod: .manual)
        let b = DiscoveredServer(name: "A", host: "h", port: 1, discoveryMethod: .manual)
        XCTAssertNotEqual(a.id, b.id, "Each discovered server should get a fresh UUID by default")
    }

    func testInitRespectsExplicitMetadataAndTimestamp() {
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let server = DiscoveredServer(
            name: "Meta",
            host: "10.0.0.1",
            port: 11434,
            discoveryMethod: .subnetScan,
            timestamp: ts,
            metadata: ["version": "1.2.3", "region": "us"]
        )
        XCTAssertEqual(server.timestamp, ts)
        XCTAssertEqual(server.metadata["version"], "1.2.3")
        XCTAssertEqual(server.metadata["region"], "us")
    }

    // MARK: - URL Construction

    func testBaseURLBuildsHTTPURLFromHostAndPort() {
        let server = DiscoveredServer(
            name: "S", host: "192.168.1.10", port: 8766, discoveryMethod: .cached
        )
        XCTAssertEqual(server.baseURL?.absoluteString, "http://192.168.1.10:8766")
    }

    func testHealthURLAppendsHealthPath() {
        let server = DiscoveredServer(
            name: "S", host: "localhost", port: 11400, discoveryMethod: .cached
        )
        XCTAssertEqual(server.healthURL?.absoluteString, "http://localhost:11400/health")
        XCTAssertEqual(server.healthURL?.lastPathComponent, "health")
    }

    func testURLsForCommonGatewayPort() {
        let server = DiscoveredServer(
            name: "Gateway", host: "127.0.0.1", port: 11400, discoveryMethod: .subnetScan
        )
        XCTAssertEqual(server.baseURL?.scheme, "http")
        XCTAssertEqual(server.baseURL?.host, "127.0.0.1")
        XCTAssertEqual(server.baseURL?.port, 11400)
    }

    // MARK: - Codable

    func testCodableRoundTripPreservesAllFields() throws {
        let original = DiscoveredServer(
            id: UUID(),
            name: "Round Trip",
            host: "192.168.0.42",
            port: 8766,
            discoveryMethod: .qrCode,
            timestamp: Date(timeIntervalSince1970: 1_650_000_000),
            metadata: ["a": "1", "b": "2"]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DiscoveredServer.self, from: data)

        XCTAssertEqual(decoded, original, "Codable round-trip must be lossless")
        XCTAssertEqual(decoded.metadata, original.metadata)
        XCTAssertEqual(decoded.discoveryMethod, .qrCode)
    }

    // MARK: - Equatable

    func testEqualityRequiresMatchingIdentity() {
        let id = UUID()
        let ts = Date(timeIntervalSince1970: 1_600_000_000)
        let lhs = DiscoveredServer(id: id, name: "X", host: "h", port: 1,
                                   discoveryMethod: .manual, timestamp: ts)
        let rhs = DiscoveredServer(id: id, name: "X", host: "h", port: 1,
                                   discoveryMethod: .manual, timestamp: ts)
        XCTAssertEqual(lhs, rhs)
    }

    func testServersWithDifferentIdsAreNotEqual() {
        let ts = Date(timeIntervalSince1970: 1_600_000_000)
        let lhs = DiscoveredServer(id: UUID(), name: "X", host: "h", port: 1,
                                   discoveryMethod: .manual, timestamp: ts)
        let rhs = DiscoveredServer(id: UUID(), name: "X", host: "h", port: 1,
                                   discoveryMethod: .manual, timestamp: ts)
        XCTAssertNotEqual(lhs, rhs, "Identity is part of equality for an Identifiable value")
    }
}

// MARK: - Discovery Method

final class DiscoveryMethodTests: XCTestCase {

    func testRawValuesMatchWireFormat() {
        XCTAssertEqual(DiscoveryMethod.cached.rawValue, "cached")
        XCTAssertEqual(DiscoveryMethod.bonjour.rawValue, "bonjour")
        XCTAssertEqual(DiscoveryMethod.multipeer.rawValue, "multipeer")
        XCTAssertEqual(DiscoveryMethod.subnetScan.rawValue, "subnet_scan")
        XCTAssertEqual(DiscoveryMethod.manual.rawValue, "manual")
        XCTAssertEqual(DiscoveryMethod.qrCode.rawValue, "qr_code")
    }

    func testDisplayNames() {
        XCTAssertEqual(DiscoveryMethod.cached.displayName, "Cached")
        XCTAssertEqual(DiscoveryMethod.bonjour.displayName, "Bonjour")
        XCTAssertEqual(DiscoveryMethod.multipeer.displayName, "Peer-to-Peer")
        XCTAssertEqual(DiscoveryMethod.subnetScan.displayName, "Network Scan")
        XCTAssertEqual(DiscoveryMethod.manual.displayName, "Manual")
        XCTAssertEqual(DiscoveryMethod.qrCode.displayName, "QR Code")
    }

    func testConstructibleFromRawValue() {
        XCTAssertEqual(DiscoveryMethod(rawValue: "subnet_scan"), .subnetScan)
        XCTAssertEqual(DiscoveryMethod(rawValue: "qr_code"), .qrCode)
        XCTAssertNil(DiscoveryMethod(rawValue: "unknown_method"))
    }

    func testCodableUsesRawString() throws {
        let data = try JSONEncoder().encode(DiscoveryMethod.subnetScan)
        let json = String(data: data, encoding: .utf8)
        XCTAssertEqual(json, "\"subnet_scan\"", "Method must encode as its wire raw value")

        let decoded = try JSONDecoder().decode(DiscoveryMethod.self, from: data)
        XCTAssertEqual(decoded, .subnetScan)
    }
}

// MARK: - Discovery State

final class DiscoveryStateTests: XCTestCase {

    private let server = DiscoveredServer(
        name: "S", host: "127.0.0.1", port: 8766, discoveryMethod: .cached
    )

    func testIsDiscoveringForActiveStates() {
        XCTAssertTrue(DiscoveryState.discovering.isDiscovering)
        XCTAssertTrue(DiscoveryState.tryingTier(.bonjour).isDiscovering)
    }

    func testIsDiscoveringFalseForTerminalStates() {
        XCTAssertFalse(DiscoveryState.idle.isDiscovering)
        XCTAssertFalse(DiscoveryState.connected(server).isDiscovering)
        XCTAssertFalse(DiscoveryState.manualConfigRequired.isDiscovering)
        XCTAssertFalse(DiscoveryState.failed("nope").isDiscovering)
    }

    func testIsConnectedOnlyForConnectedState() {
        XCTAssertTrue(DiscoveryState.connected(server).isConnected)

        XCTAssertFalse(DiscoveryState.idle.isConnected)
        XCTAssertFalse(DiscoveryState.discovering.isConnected)
        XCTAssertFalse(DiscoveryState.tryingTier(.cached).isConnected)
        XCTAssertFalse(DiscoveryState.manualConfigRequired.isConnected)
        XCTAssertFalse(DiscoveryState.failed("x").isConnected)
    }

    func testEquatableDistinguishesAssociatedValues() {
        XCTAssertEqual(DiscoveryState.tryingTier(.cached), DiscoveryState.tryingTier(.cached))
        XCTAssertNotEqual(DiscoveryState.tryingTier(.cached), DiscoveryState.tryingTier(.bonjour))

        XCTAssertEqual(DiscoveryState.failed("a"), DiscoveryState.failed("a"))
        XCTAssertNotEqual(DiscoveryState.failed("a"), DiscoveryState.failed("b"))

        XCTAssertEqual(DiscoveryState.connected(server), DiscoveryState.connected(server))
        XCTAssertNotEqual(DiscoveryState.idle, DiscoveryState.discovering)
    }
}
