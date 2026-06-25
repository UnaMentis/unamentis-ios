// UnaMentis - DeviceMetrics Tests
// Validates the derived health properties on the DeviceMetrics value type in
// Core/Telemetry. These properties drive the device-stress detection that the
// telemetry engine logs against and that the UI surfaces, so their boundary
// behavior (the exact thresholds for CPU, memory, and thermal stress) is the
// real contract worth protecting.
//
// DeviceMetrics is a pure Sendable struct with no external dependencies, so it
// is constructed directly with no mocks.

import XCTest
@testable import UnaMentis

final class DeviceMetricsTests: XCTestCase {

    // MARK: - memoryUsagePercent

    func testMemoryUsagePercent_computesRatioAsPercentage() {
        let metrics = DeviceMetrics(memoryUsed: 512, memoryTotal: 2048)
        // 512 / 2048 == 0.25 -> 25%.
        XCTAssertEqual(metrics.memoryUsagePercent, 25.0, accuracy: 0.0001)
    }

    func testMemoryUsagePercent_zeroTotal_returnsZeroNotNaN() {
        // Guards against division by zero when total memory is unknown.
        let metrics = DeviceMetrics(memoryUsed: 100, memoryTotal: 0)
        XCTAssertEqual(metrics.memoryUsagePercent, 0)
    }

    // MARK: - isUnderStress: CPU threshold (> 80)

    func testIsUnderStress_cpuAtThreshold_isNotStressed() {
        // The threshold is strictly greater than 80, so exactly 80 is fine.
        let metrics = DeviceMetrics(cpuUsage: 80, memoryUsed: 0, memoryTotal: 100, thermalState: .nominal)
        XCTAssertFalse(metrics.isUnderStress)
    }

    func testIsUnderStress_cpuAboveThreshold_isStressed() {
        let metrics = DeviceMetrics(cpuUsage: 80.1, memoryUsed: 0, memoryTotal: 100, thermalState: .nominal)
        XCTAssertTrue(metrics.isUnderStress)
    }

    // MARK: - isUnderStress: memory threshold (> 85%)

    func testIsUnderStress_memoryAtThreshold_isNotStressed() {
        // 85 / 100 == 85%, which is the boundary and not strictly above it.
        let metrics = DeviceMetrics(cpuUsage: 0, memoryUsed: 85, memoryTotal: 100, thermalState: .nominal)
        XCTAssertEqual(metrics.memoryUsagePercent, 85, accuracy: 0.0001)
        XCTAssertFalse(metrics.isUnderStress)
    }

    func testIsUnderStress_memoryAboveThreshold_isStressed() {
        let metrics = DeviceMetrics(cpuUsage: 0, memoryUsed: 86, memoryTotal: 100, thermalState: .nominal)
        XCTAssertTrue(metrics.isUnderStress)
    }

    // MARK: - isUnderStress: thermal threshold (>= serious)

    func testIsUnderStress_thermalFair_isNotStressed() {
        // Fair is below the serious threshold, so it does not count as stress.
        let metrics = DeviceMetrics(cpuUsage: 0, memoryUsed: 0, memoryTotal: 100, thermalState: .fair)
        XCTAssertFalse(metrics.isUnderStress)
    }

    func testIsUnderStress_thermalSerious_isStressed() {
        let metrics = DeviceMetrics(cpuUsage: 0, memoryUsed: 0, memoryTotal: 100, thermalState: .serious)
        XCTAssertTrue(metrics.isUnderStress)
    }

    func testIsUnderStress_thermalCritical_isStressed() {
        let metrics = DeviceMetrics(cpuUsage: 0, memoryUsed: 0, memoryTotal: 100, thermalState: .critical)
        XCTAssertTrue(metrics.isUnderStress)
    }

    func testIsUnderStress_allNominal_isNotStressed() {
        let metrics = DeviceMetrics(cpuUsage: 10, memoryUsed: 10, memoryTotal: 100, thermalState: .nominal)
        XCTAssertFalse(metrics.isUnderStress)
    }

    // MARK: - thermalStateString

    func testThermalStateString_mapsEachState() {
        XCTAssertEqual(DeviceMetrics(thermalState: .nominal).thermalStateString, "Normal")
        XCTAssertEqual(DeviceMetrics(thermalState: .fair).thermalStateString, "Fair")
        XCTAssertEqual(DeviceMetrics(thermalState: .serious).thermalStateString, "Serious")
        XCTAssertEqual(DeviceMetrics(thermalState: .critical).thermalStateString, "Critical")
    }

    // MARK: - Defaults

    func testDefaultInit_isNotUnderStress() {
        // A zeroed default sample must read as healthy, otherwise empty device
        // history (which returns a default DeviceMetrics) would falsely alarm.
        let metrics = DeviceMetrics()
        XCTAssertFalse(metrics.isUnderStress)
        XCTAssertEqual(metrics.memoryUsagePercent, 0)
        XCTAssertEqual(metrics.thermalStateString, "Normal")
    }
}
