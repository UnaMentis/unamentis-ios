// UnaMentis - Discovery Tier Implementation Tests
// Covers the no-network contracts of the Bonjour and subnet-scan tier actors,
// and the URL-construction edge cases of DiscoveredServer that the manager relies
// on to reject malformed hosts before any network call. The actual browsing and
// probing require live networking and the Network framework, so they are not
// exercised here; only deterministic, network-free behavior is asserted.

import XCTest
@testable import UnaMentis

final class DiscoveryTiersTests: XCTestCase {

    // MARK: - Tier identity

    // Each tier actor advertises which tier it implements. The manager uses this
    // identity to drive the fallback ordering and the progress UI, so a mismatch
    // would silently break the hierarchy.

    func testBonjourDiscoveryReportsBonjourTier() async {
        let discovery = BonjourDiscovery()
        let tier = await discovery.tier
        XCTAssertEqual(tier, .bonjour)
    }

    func testSubnetScanDiscoveryReportsSubnetScanTier() async {
        let discovery = SubnetScanDiscovery()
        let tier = await discovery.tier
        XCTAssertEqual(tier, .subnetScan)
    }

    // MARK: - Cancellation is a safe no-op before discovery

    func testBonjourCancelBeforeDiscoverLeavesActorResponsive() async {
        let discovery = BonjourDiscovery()
        // Cancelling a browser that was never started must be a safe no-op that
        // does not deadlock or corrupt the actor: a subsequent call must still
        // return the correct tier (and would hang the test if cancel wedged it).
        await discovery.cancel()
        let tier = await discovery.tier
        XCTAssertEqual(tier, .bonjour, "actor stays responsive after a premature cancel")
    }

    func testSubnetScanCancelBeforeDiscoverLeavesActorResponsive() async {
        let discovery = SubnetScanDiscovery(ports: [8766])
        await discovery.cancel()
        let tier = await discovery.tier
        XCTAssertEqual(tier, .subnetScan, "actor stays responsive after a premature cancel")
    }
}

// MARK: - DiscoveredServer URL edge cases

// The manager and the cached tier short-circuit when a server cannot form a
// valid health URL. These tests pin the boundary between hosts that build a URL
// and hosts that do not, which is the precondition that keeps a malformed host
// from ever reaching the network.
final class DiscoveredServerURLEdgeCaseTests: XCTestCase {

    func testHostWithSpaceProducesNilURLs() {
        let server = DiscoveredServer(
            name: "Bad", host: "bad host", port: 8766, discoveryMethod: .manual
        )
        XCTAssertNil(server.baseURL,
                     "A host containing a space cannot form a URL")
        XCTAssertNil(server.healthURL,
                     "A nil baseURL must yield a nil healthURL, blocking any health check")
    }

    func testEmptyHostStillFormsURLWithEmptyAuthority() {
        // An empty host is not the same as an unformable host: URL(string:) accepts
        // "http://:8766". This documents that an empty host is NOT screened out by
        // URL construction (it would reach the network), unlike a host with a space.
        let server = DiscoveredServer(
            name: "Empty", host: "", port: 8766, discoveryMethod: .manual
        )
        XCTAssertEqual(server.baseURL?.absoluteString, "http://:8766")
        XCTAssertEqual(server.healthURL?.absoluteString, "http://:8766/health")
    }

    func testNumericIPv4HostFormsExpectedHealthURL() {
        let server = DiscoveredServer(
            name: "Probe", host: "10.0.0.42", port: 11434, discoveryMethod: .subnetScan
        )
        XCTAssertEqual(server.healthURL?.absoluteString, "http://10.0.0.42:11434/health")
    }
}
