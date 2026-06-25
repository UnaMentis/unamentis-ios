// UnaMentis - Device Discovery Manager Tests
// Exercises the manager's no-network code paths: QR code JSON parsing and its
// failure handling, and the manual / QR configuration short-circuits that reject
// a server before any health check is attempted. These paths set the published
// state that drives the connection UI, so the contract must be exact.
//
// The healthy paths require a live URLSession request to a real server and are
// intentionally not exercised here. Only branches that resolve before any
// network access are covered. Every invalid input used below produces a nil
// healthURL (a host string containing a space cannot form a URL) or fails JSON
// decoding, so validateServer returns false without touching the network.

import XCTest
@testable import UnaMentis

@MainActor
final class DeviceDiscoveryManagerTests: XCTestCase {

    private var manager: DeviceDiscoveryManager!

    override func setUp() async throws {
        try await super.setUp()
        // DeviceDiscoveryManager is a private-init singleton, so tests share one
        // instance. Each test below asserts only the deterministic post-conditions
        // of its own call (the failure terminal state), which do not depend on the
        // instance's prior state. Cancel first to clear any in-flight discovery.
        manager = DeviceDiscoveryManager.shared
        await manager.cancelDiscovery()
    }

    override func tearDown() async throws {
        await manager.cancelDiscovery()
        manager = nil
        try await super.tearDown()
    }

    // MARK: - configureManually: invalid host short-circuit

    func testConfigureManuallyRejectsHostThatCannotFormAURL() async {
        // A host containing a space yields a nil baseURL/healthURL, so
        // validateServer returns false before any network call is made.
        let result = await manager.configureManually(host: "bad host", port: 8766)

        XCTAssertNil(result, "An unformable host must not produce a connected server")
        XCTAssertEqual(
            manager.state,
            .failed("Could not connect to bad host:8766"),
            "A rejected manual host must surface a failure state naming the target"
        )
        XCTAssertNil(manager.connectedServer,
                     "No server should be marked connected after a rejected manual config")
    }

    func testConfigureManuallyFailureMessageIncludesHostAndPort() async {
        let result = await manager.configureManually(host: "no good", port: 11400, name: "Lab")

        XCTAssertNil(result)
        // The display name is irrelevant to the failure message; host:port is.
        guard case .failed(let message) = manager.state else {
            return XCTFail("Expected a .failed state, got \(manager.state)")
        }
        XCTAssertTrue(message.contains("no good"), "Failure message must name the host")
        XCTAssertTrue(message.contains("11400"), "Failure message must name the port")
    }

    // MARK: - configureFromQRCode: JSON parsing

    func testConfigureFromQRCodeRejectsNonJSONData() async {
        let garbage = Data("this is not json".utf8)
        let result = await manager.configureFromQRCode(garbage)

        XCTAssertNil(result, "Non-JSON QR data cannot configure a server")
        XCTAssertEqual(manager.state, .failed("Invalid QR code"),
                       "Unparseable QR data must produce the invalid-QR failure state")
    }

    func testConfigureFromQRCodeRejectsJSONMissingRequiredHost() async {
        // host is required by QRCodeServerInfo; a payload without it must fail to
        // decode and fall into the catch branch.
        let json = Data(#"{"port": 8766, "name": "No Host"}"#.utf8)
        let result = await manager.configureFromQRCode(json)

        XCTAssertNil(result)
        XCTAssertEqual(manager.state, .failed("Invalid QR code"),
                       "A QR payload missing the required host must be rejected")
    }

    func testConfigureFromQRCodeRejectsJSONMissingRequiredPort() async {
        // port is required; a payload without it must fail to decode.
        let json = Data(#"{"host": "192.168.1.5", "name": "No Port"}"#.utf8)
        let result = await manager.configureFromQRCode(json)

        XCTAssertNil(result)
        XCTAssertEqual(manager.state, .failed("Invalid QR code"))
    }

    func testConfigureFromQRCodeRejectsWrongPortType() async {
        // port must be an Int; a string must fail strict decoding.
        let json = Data(#"{"host": "192.168.1.5", "port": "not-a-number"}"#.utf8)
        let result = await manager.configureFromQRCode(json)

        XCTAssertNil(result)
        XCTAssertEqual(manager.state, .failed("Invalid QR code"))
    }

    // MARK: - clearCache resets connection state

    func testClearCacheResetsToIdleAndClearsConnectedServer() async {
        await manager.clearCache()

        XCTAssertNil(manager.connectedServer,
                     "clearCache must drop any connected server reference")
        XCTAssertEqual(manager.state, .idle,
                       "clearCache must return the manager to idle")
    }

    // MARK: - cancelDiscovery state handling

    func testCancelDiscoveryFromIdleLeavesStateIdle() async {
        // cancelDiscovery only resets to idle when currently discovering; from a
        // non-discovering state it must be a safe no-op on the published state.
        await manager.clearCache() // ensure a known .idle starting point
        XCTAssertEqual(manager.state, .idle)

        await manager.cancelDiscovery()
        XCTAssertEqual(manager.state, .idle,
                       "Cancelling while idle must keep the manager idle")
    }
}
