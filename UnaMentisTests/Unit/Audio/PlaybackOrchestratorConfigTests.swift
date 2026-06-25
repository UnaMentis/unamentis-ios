// UnaMentis - Playback Orchestrator Configuration Tests
//
// PlaybackOrchestratorConfig is a small Sendable tuning struct with four named presets
// (default, readingList, session, knowledgeBowl). It has no computed properties, no init
// validation, and is neither Equatable nor Codable, so there is no derived-value or
// round-trip contract to test. The behavior worth protecting is the documented, DISTINCT
// per-preset tuning that drives real playback behavior (prefetch depth, inter-segment
// silence, skip-back retention, buffer timeout). These tests pin the exact per-preset
// values so a silent edit to any preset is caught, and assert the documented ordering and
// uniqueness relationships between presets that the orchestrator and module design rely on.
// All expected values are derived directly from PlaybackOrchestratorConfig.swift.

import XCTest
@testable import UnaMentis

final class PlaybackOrchestratorConfigTests: XCTestCase {

    // MARK: - Exact preset values

    func testDefaultPresetCarriesDocumentedValues() {
        let config = PlaybackOrchestratorConfig.default

        XCTAssertEqual(config.prefetchDepth, 3)
        XCTAssertEqual(config.interSegmentSilenceMs, 0)
        XCTAssertEqual(config.retainBehindCount, 0)
        XCTAssertEqual(config.bufferTimeoutSeconds, 10)
    }

    func testReadingListPresetCarriesDocumentedValues() {
        // Reading list: deep prefetch, natural pacing silence, skip-back retention.
        let config = PlaybackOrchestratorConfig.readingList

        XCTAssertEqual(config.prefetchDepth, 5)
        XCTAssertEqual(config.interSegmentSilenceMs, 600)
        XCTAssertEqual(config.retainBehindCount, 6)
        XCTAssertEqual(config.bufferTimeoutSeconds, 10)
    }

    func testSessionPresetCarriesDocumentedValues() {
        // Session: shallow prefetch, no gaps, no retention, longer timeout for live synthesis.
        let config = PlaybackOrchestratorConfig.session

        XCTAssertEqual(config.prefetchDepth, 2)
        XCTAssertEqual(config.interSegmentSilenceMs, 0)
        XCTAssertEqual(config.retainBehindCount, 0)
        XCTAssertEqual(config.bufferTimeoutSeconds, 15)
    }

    func testKnowledgeBowlPresetCarriesDocumentedValues() {
        // Knowledge Bowl: single segment, no prefetch, no silence, no retention.
        let config = PlaybackOrchestratorConfig.knowledgeBowl

        XCTAssertEqual(config.prefetchDepth, 0)
        XCTAssertEqual(config.interSegmentSilenceMs, 0)
        XCTAssertEqual(config.retainBehindCount, 0)
        XCTAssertEqual(config.bufferTimeoutSeconds, 10)
    }

    // MARK: - Preset distinctness (documented differentiators)

    func testReadingListIsTheOnlyPresetWithInterSegmentSilence() {
        // Silence is the reading list's defining pacing feature. Every other preset must
        // stay at conversation-like zero silence, otherwise sessions would gain dead air.
        XCTAssertEqual(PlaybackOrchestratorConfig.readingList.interSegmentSilenceMs, 600)
        XCTAssertEqual(PlaybackOrchestratorConfig.default.interSegmentSilenceMs, 0)
        XCTAssertEqual(PlaybackOrchestratorConfig.session.interSegmentSilenceMs, 0)
        XCTAssertEqual(PlaybackOrchestratorConfig.knowledgeBowl.interSegmentSilenceMs, 0)
    }

    func testReadingListIsTheOnlyPresetThatRetainsForSkipBack() {
        // Only the reading list keeps played segments behind the playhead for instant skip-back.
        XCTAssertGreaterThan(PlaybackOrchestratorConfig.readingList.retainBehindCount, 0)
        XCTAssertEqual(PlaybackOrchestratorConfig.default.retainBehindCount, 0)
        XCTAssertEqual(PlaybackOrchestratorConfig.session.retainBehindCount, 0)
        XCTAssertEqual(PlaybackOrchestratorConfig.knowledgeBowl.retainBehindCount, 0)
    }

    func testPrefetchDepthOrderingAcrossPresets() {
        // Documented relationship: reading list prefetches deepest, default sits below it,
        // session is shallower than default, and knowledge bowl does not prefetch at all.
        let readingList = PlaybackOrchestratorConfig.readingList.prefetchDepth
        let standard = PlaybackOrchestratorConfig.default.prefetchDepth
        let session = PlaybackOrchestratorConfig.session.prefetchDepth
        let knowledgeBowl = PlaybackOrchestratorConfig.knowledgeBowl.prefetchDepth

        XCTAssertGreaterThan(readingList, standard)
        XCTAssertGreaterThan(standard, session)
        XCTAssertGreaterThan(session, knowledgeBowl)
        XCTAssertEqual(knowledgeBowl, 0)
    }

    func testSessionHasTheLongestBufferTimeout() {
        // Sessions synthesize segments live, so they tolerate a longer wait than the
        // pre-cached / pre-synthesized presets before declaring a buffer timeout.
        let session = PlaybackOrchestratorConfig.session.bufferTimeoutSeconds

        XCTAssertGreaterThan(session, PlaybackOrchestratorConfig.default.bufferTimeoutSeconds)
        XCTAssertGreaterThan(session, PlaybackOrchestratorConfig.readingList.bufferTimeoutSeconds)
        XCTAssertGreaterThan(session, PlaybackOrchestratorConfig.knowledgeBowl.bufferTimeoutSeconds)
    }
}
