// UnaMentis - Oral Exam Delivery Metrics Tests
//
// The delivery-metrics math (MODULE_SDK_SPEC.md section 6.2 deliveryMetrics) is
// a pure computation over captured segments, so it is exhaustively testable
// without any audio: pace (words per minute), filler-word counting, and
// hesitation-gap counting from utterance segment timing.

import XCTest
@testable import UnaMentis

final class OralExamDeliveryMetricsTests: XCTestCase {

    private func segment(
        _ text: String,
        start: TimeInterval,
        end: TimeInterval,
        endedBy: UtteranceResult.EndReason = .silence
    ) -> OralExamCapturedSegment {
        OralExamCapturedSegment(transcript: text, start: start, end: end, endedBy: endedBy)
    }

    // MARK: - Pace

    func testPace_wordsPerMinuteOverSpeakingTime() {
        // 30 words over a 15 second segment ending on silence (2s threshold)
        // = 30 words / 13 speaking seconds * 60 = ~138 wpm.
        let words = Array(repeating: "word", count: 30).joined(separator: " ")
        let metrics = OralExamDeliveryAnalyzer.metrics(
            from: [segment(words, start: 0, end: 15)],
            silenceThreshold: 2.0
        )
        XCTAssertEqual(metrics.wordCount, 30)
        XCTAssertEqual(metrics.speakingSeconds, 13, accuracy: 0.001)
        XCTAssertEqual(metrics.wordsPerMinute, 30.0 / 13.0 * 60, accuracy: 0.5)
    }

    func testPace_zeroBelowMinimumSpeakingTime() {
        // A very short segment yields no meaningful rate.
        let metrics = OralExamDeliveryAnalyzer.metrics(
            from: [segment("just a few words here", start: 0, end: 3)],
            silenceThreshold: 2.0
        )
        XCTAssertEqual(metrics.wordsPerMinute, 0)
    }

    func testPace_maxDurationSegmentKeepsFullDuration() {
        // A segment cut off at max utterance duration includes no trailing
        // endpointer silence to subtract.
        let words = Array(repeating: "word", count: 40).joined(separator: " ")
        let metrics = OralExamDeliveryAnalyzer.metrics(
            from: [segment(words, start: 0, end: 12, endedBy: .maxUtteranceDuration)],
            silenceThreshold: 2.0
        )
        XCTAssertEqual(metrics.speakingSeconds, 12, accuracy: 0.001)
    }

    // MARK: - Filler Words

    func testFillerCount_singleAndPhraseFillers() {
        let text = "um so the answer is like you know basically the mitochondria uh"
        // Fillers: um, like, you know, basically, uh = 5.
        XCTAssertEqual(OralExamDeliveryAnalyzer.fillerCount(in: text), 5)
    }

    func testFillerCount_phraseConsumesTokens() {
        // "you know" counts once as a phrase, not "know" plus a stray token.
        XCTAssertEqual(OralExamDeliveryAnalyzer.fillerCount(in: "you know you know"), 2)
    }

    func testFillerCount_noFillers() {
        XCTAssertEqual(OralExamDeliveryAnalyzer.fillerCount(in: "a clear and precise answer"), 0)
    }

    // MARK: - Hesitations

    func testHesitations_silenceGapsMidMonologueCount() {
        // Three silence-ended segments: the first two are followed by more
        // speech (2 hesitations); the last is terminal (not a hesitation).
        let segments = [
            segment("first part", start: 0, end: 5),
            segment("second part", start: 7, end: 12),
            segment("third part", start: 14, end: 19)
        ]
        let metrics = OralExamDeliveryAnalyzer.metrics(from: segments, silenceThreshold: 2.0)
        XCTAssertEqual(metrics.hesitationCount, 2)
    }

    func testHesitations_maxDurationSegmentIsNotHesitation() {
        // A segment ended by max duration (not silence) is not a hesitation
        // even when followed by more speech.
        let segments = [
            segment("long uninterrupted", start: 0, end: 10, endedBy: .maxUtteranceDuration),
            segment("continued", start: 10, end: 14, endedBy: .silence)
        ]
        let metrics = OralExamDeliveryAnalyzer.metrics(from: segments, silenceThreshold: 2.0)
        XCTAssertEqual(metrics.hesitationCount, 0)
    }

    // MARK: - Empty

    func testEmpty_returnsZeroMetrics() {
        XCTAssertEqual(OralExamDeliveryAnalyzer.metrics(from: [], silenceThreshold: 2.0), .empty)
    }
}
