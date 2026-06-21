// UnaMentis - Discovery Tier Tests
// Locks the tier ordering, per-tier timeouts and display names, and the
// human-readable descriptions for every DiscoveryError case. These drive the
// fallback hierarchy and the discovery UI, so the contract must be exact.

import XCTest
@testable import UnaMentis

final class DiscoveryTierTests: XCTestCase {

    // MARK: - Raw Values and Ordering

    func testRawValuesEncodePreferenceOrder() {
        // Lower raw value means tried first in the fallback hierarchy.
        XCTAssertEqual(DiscoveryTier.cached.rawValue, 1)
        XCTAssertEqual(DiscoveryTier.bonjour.rawValue, 2)
        XCTAssertEqual(DiscoveryTier.multipeer.rawValue, 3)
        XCTAssertEqual(DiscoveryTier.subnetScan.rawValue, 4)
    }

    func testPriorityMatchesRawValue() {
        for tier in DiscoveryTier.allCases {
            XCTAssertEqual(tier.priority, tier.rawValue,
                           "Priority must equal the raw value so sorting prefers earlier tiers")
        }
    }

    func testPriorityOrderingIsStrictlyIncreasing() {
        // Cached should sort before Bonjour before subnet scan.
        XCTAssertLessThan(DiscoveryTier.cached.priority, DiscoveryTier.bonjour.priority)
        XCTAssertLessThan(DiscoveryTier.bonjour.priority, DiscoveryTier.multipeer.priority)
        XCTAssertLessThan(DiscoveryTier.multipeer.priority, DiscoveryTier.subnetScan.priority)
    }

    func testAllCasesAreEnumeratedInOrder() {
        XCTAssertEqual(DiscoveryTier.allCases, [.cached, .bonjour, .multipeer, .subnetScan])
    }

    // MARK: - Display Names

    func testEveryTierHasNonEmptyDisplayName() {
        for tier in DiscoveryTier.allCases {
            XCTAssertFalse(tier.displayName.isEmpty, "\(tier) must have a UI display name")
        }
    }

    func testDisplayNamesAreDistinct() {
        let names = DiscoveryTier.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count,
                       "Each tier must have a unique display name for the UI")
    }

    func testSpecificDisplayNames() {
        XCTAssertEqual(DiscoveryTier.cached.displayName, "Checking saved server")
        XCTAssertEqual(DiscoveryTier.bonjour.displayName, "Scanning local network")
        XCTAssertEqual(DiscoveryTier.multipeer.displayName, "Trying peer-to-peer")
        XCTAssertEqual(DiscoveryTier.subnetScan.displayName, "Deep network scan")
    }

    // MARK: - Timeouts

    func testTimeoutsAreExactAndPositive() {
        XCTAssertEqual(DiscoveryTier.cached.timeout, 2)
        XCTAssertEqual(DiscoveryTier.bonjour.timeout, 3)
        XCTAssertEqual(DiscoveryTier.multipeer.timeout, 5)
        XCTAssertEqual(DiscoveryTier.subnetScan.timeout, 10)

        for tier in DiscoveryTier.allCases {
            XCTAssertGreaterThan(tier.timeout, 0, "\(tier) timeout must be positive")
        }
    }

    func testTimeoutsGrowWithDepthOfSearch() {
        // Cheaper tiers get less time; the aggressive subnet scan gets the most.
        XCTAssertLessThan(DiscoveryTier.cached.timeout, DiscoveryTier.bonjour.timeout)
        XCTAssertLessThan(DiscoveryTier.bonjour.timeout, DiscoveryTier.multipeer.timeout)
        XCTAssertLessThan(DiscoveryTier.multipeer.timeout, DiscoveryTier.subnetScan.timeout)
    }

    // MARK: - Sendable / Equatable enum behavior

    func testTierIsConstructibleFromRawValue() {
        XCTAssertEqual(DiscoveryTier(rawValue: 1), .cached)
        XCTAssertEqual(DiscoveryTier(rawValue: 4), .subnetScan)
        XCTAssertNil(DiscoveryTier(rawValue: 0))
        XCTAssertNil(DiscoveryTier(rawValue: 99))
    }
}

// MARK: - Discovery Error

final class DiscoveryErrorTests: XCTestCase {

    func testStaticErrorDescriptions() {
        XCTAssertEqual(DiscoveryError.timeout.errorDescription, "Discovery timed out")
        XCTAssertEqual(DiscoveryError.networkUnavailable.errorDescription, "Network is unavailable")
        XCTAssertEqual(DiscoveryError.invalidResponse.errorDescription, "Invalid response from server")
        XCTAssertEqual(DiscoveryError.cancelled.errorDescription, "Discovery was cancelled")
    }

    func testHealthCheckFailedEmbedsReason() {
        let reason = "status 503"
        let error = DiscoveryError.healthCheckFailed(reason)
        XCTAssertEqual(error.errorDescription, "Health check failed: \(reason)")
        XCTAssertTrue(error.errorDescription?.contains(reason) ?? false,
                      "The failure reason must surface in the message")
    }

    func testTierNotAvailableUsesTierDisplayName() {
        let error = DiscoveryError.tierNotAvailable(.subnetScan)
        XCTAssertEqual(error.errorDescription,
                       "\(DiscoveryTier.subnetScan.displayName) is not available")
        XCTAssertTrue(error.errorDescription?.contains("Deep network scan") ?? false)
    }

    func testEveryErrorCaseHasNonEmptyDescription() {
        let cases: [DiscoveryError] = [
            .timeout,
            .networkUnavailable,
            .invalidResponse,
            .healthCheckFailed("x"),
            .cancelled,
            .tierNotAvailable(.cached)
        ]
        for error in cases {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true,
                           "\(error) must produce a user-facing description")
        }
    }
}
