// UnaMentis - Barge-In Measurement Harness Integration Test
// Validates the end-to-end measurement wiring on the simulator: TTS generation
// -> VAD -> BargeInDetector -> STT injection -> classification -> outcome ->
// metrics -> JSON. Exact metric VALUES are not asserted here (simulator STT/VAD
// differ from device); the device run is the goal's source of truth. The
// deterministic math is covered by BargeInMetricsTests.

import XCTest
@testable import UnaMentis

final class BargeInMeasurementTests: XCTestCase {

    func testHarnessRunsAndPopulatesAllMetrics() async throws {
        let corpus = [
            BargeInCorpusClip(id: "cmd", type: .command, source: .tts, text: "bookmark this"),
            BargeInCorpusClip(id: "eng", type: .engagement, source: .tts, text: "why does that happen"),
            BargeInCorpusClip(id: "noise", type: .noise, source: .noise, durationSec: 1.0)
        ]

        let harness = BargeInMeasurementHarness()
        let result = await harness.run(corpus: corpus, mode: "simulator")

        // Mechanics: every clip produced an outcome, counts reflect composition.
        XCTAssertEqual(result.clipCount, 3)
        XCTAssertEqual(result.outcomes.count, 3)
        XCTAssertEqual(result.metrics.positiveSamples, 2, "command + engagement are positives")
        XCTAssertEqual(result.metrics.negativeSamples, 1, "noise is a negative")
        XCTAssertEqual(Set(result.outcomes.map(\.clipId)), ["cmd", "eng", "noise"])

        // The result must serialize (this is what the skill writes to disk).
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(BargeInMeasurementResult.self, from: data)
        XCTAssertEqual(decoded.outcomes.count, 3)

        // Surface the actual numbers for inspection (not asserted).
        print("=== Barge-In Measurement (simulator) ===")
        print("thermal=\(result.thermalState) peakMemMB=\(result.peakMemoryMB ?? -1)")
        for o in result.outcomes {
            let reaction = o.reactionMs.map { String(format: "%.0fms", $0) } ?? "n/a"
            let partial = o.firstPartialMs.map { String(format: "%.0fms", $0) } ?? "n/a"
            print("  [\(o.type.rawValue)] \(o.clipId): detected=\(o.detected) reaction=\(reaction) firstPartial=\(partial) predicted=\(o.predictedClass?.rawValue ?? "nil") transcript=\(o.transcript ?? "")")
        }
        let m = result.metrics
        print("recall=\(m.detectionRecall as Any) fpr=\(m.falsePositiveRate as Any) f1=\(m.commandVsEngagementMacroF1 as Any) reactionMedian=\(m.reactionMsMedian as Any)")
    }

    /// Driven by scripts/measure-barge-in.sh: runs the full seed and writes the
    /// result JSON to build/barge-in-results/latest.json (path derived from this
    /// source file via #filePath), where the script reads and grades it. The
    /// mode is detected at compile time (no env vars, which do not reach the
    /// simulator test process).
    func testEmitMeasurementJSON() async throws {
        #if targetEnvironment(simulator)
        let mode = "simulator"
        #else
        let mode = "device"
        #endif

        let corpus = BargeInCorpus.simulatorSeed()
        let harness = BargeInMeasurementHarness()
        let result = await harness.run(corpus: corpus, mode: mode)
        let data = try JSONEncoder().encode(result)

        let outURL = Self.resultsDirectory().appendingPathComponent("latest.json")
        try FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: outURL)
        print("BARGEIN_WROTE \(outURL.path)")
    }

    /// <projectRoot>/build/barge-in-results, derived from this file's host path.
    private static func resultsDirectory() -> URL {
        URL(fileURLWithPath: #filePath)   // .../UnaMentisTests/Integration/<this file>
            .deletingLastPathComponent()  // .../UnaMentisTests/Integration
            .deletingLastPathComponent()  // .../UnaMentisTests
            .deletingLastPathComponent()  // project root
            .appendingPathComponent("build/barge-in-results")
    }
}
