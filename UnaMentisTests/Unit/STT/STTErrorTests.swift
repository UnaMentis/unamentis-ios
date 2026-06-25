// UnaMentis - STTError Tests
// Unit tests for the STTError LocalizedError mapping
//
// STTError is the common error currency across every STT provider
// (Deepgram, AssemblyAI, Groq, GLM-ASR, self-hosted). Its errorDescription
// values surface to logs and, via LocalizedError, to user-facing messaging.
// The descriptions, including interpolation of the connectionFailed /
// streamingFailed associated values, are a real contract worth protecting
// against accidental wording or interpolation regressions.

import XCTest
@testable import UnaMentis

final class STTErrorTests: XCTestCase {

    // MARK: - Associated-Value Interpolation

    func testConnectionFailed_interpolatesUnderlyingMessage() {
        let error = STTError.connectionFailed("HTTP 503")
        XCTAssertEqual(error.errorDescription, "STT connection failed: HTTP 503")
    }

    func testStreamingFailed_interpolatesUnderlyingMessage() {
        let error = STTError.streamingFailed("socket closed")
        XCTAssertEqual(error.errorDescription, "STT streaming failed: socket closed")
    }

    // MARK: - Static Descriptions

    func testInvalidAudioFormat_description() {
        XCTAssertEqual(
            STTError.invalidAudioFormat.errorDescription,
            "Invalid audio format for STT processing"
        )
    }

    func testNotStreaming_description() {
        XCTAssertEqual(STTError.notStreaming.errorDescription, "Not currently streaming")
    }

    func testAlreadyStreaming_description() {
        XCTAssertEqual(STTError.alreadyStreaming.errorDescription, "Already streaming")
    }

    func testAuthenticationFailed_description() {
        XCTAssertEqual(
            STTError.authenticationFailed.errorDescription,
            "STT authentication failed"
        )
    }

    func testRateLimited_description() {
        XCTAssertEqual(STTError.rateLimited.errorDescription, "STT rate limit exceeded")
    }

    func testQuotaExceeded_description() {
        XCTAssertEqual(STTError.quotaExceeded.errorDescription, "STT quota exceeded")
    }

    // MARK: - LocalizedError Bridging

    func testLocalizedDescription_bridgesToErrorDescription() {
        // STTError conforms to LocalizedError, so `localizedDescription` (the
        // path most call sites and SwiftUI use) must return the same string as
        // errorDescription. This guards the bridge rather than the wording.
        let error = STTError.connectionFailed("timeout")
        XCTAssertEqual(error.localizedDescription, "STT connection failed: timeout")
    }

    // MARK: - Distinctness

    func testEveryCase_hasANonEmptyDistinctDescription() {
        // Two different failure modes should never produce identical user-facing
        // text, otherwise diagnostics become ambiguous. Cover all cases with
        // representative associated values.
        let allErrors: [STTError] = [
            .connectionFailed("a"),
            .streamingFailed("b"),
            .invalidAudioFormat,
            .notStreaming,
            .alreadyStreaming,
            .authenticationFailed,
            .rateLimited,
            .quotaExceeded
        ]

        let descriptions = allErrors.compactMap { $0.errorDescription }
        XCTAssertEqual(descriptions.count, allErrors.count, "Every case must have a description")
        for description in descriptions {
            XCTAssertFalse(description.isEmpty)
        }
        XCTAssertEqual(
            Set(descriptions).count,
            descriptions.count,
            "Each STTError case must map to a distinct description"
        )
    }
}
