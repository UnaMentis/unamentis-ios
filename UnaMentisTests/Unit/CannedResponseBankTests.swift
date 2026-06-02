// UnaMentis - CannedResponseBank Tests
// Verifies the instant barge-in filler core: pre-render with the session TTS,
// select an intent-matched clip from a rotating library, preserve the audio
// format, and convert a clip to a playable chunk for the unified AudioEngine.

import XCTest
@testable import UnaMentis

final class CannedResponseBankTests: XCTestCase {

    /// Populate a bank using the mock TTS (which emits pcmFloat32 @ 24kHz).
    private func makePopulatedBank() async -> CannedResponseBank {
        let bank = CannedResponseBank()
        let mockTTS = MockTTSService()
        await bank.populate(using: mockTTS)
        return bank
    }

    func testPopulate_withTTS_marksReady() async {
        let bank = await makePopulatedBank()
        let ready = await bank.isReady
        XCTAssertTrue(ready, "Bank should be ready after populating with a working TTS")
    }

    func testGetResponse_forEngagement_returnsClipWithPreservedFormat() async {
        let bank = await makePopulatedBank()
        guard let clip = await bank.getResponse(for: .engagement) else {
            return XCTFail("Expected an engagement clip after populate")
        }
        XCTAssertFalse(clip.audioData.isEmpty, "Clip must carry rendered audio")
        XCTAssertEqual(clip.intent, .engagement)

        // The TTS format must be preserved so playback is faithful (not assumed).
        guard case .pcmFloat32(let rate, let channels) = clip.format else {
            return XCTFail("Expected pcmFloat32 format preserved from the TTS chunk")
        }
        XCTAssertEqual(rate, 24000, "Sample rate must be preserved from the TTS format")
        XCTAssertEqual(channels, 1)
    }

    func testGetResponse_forBargeInQuestion_classifiesToEngagement() async {
        let bank = await makePopulatedBank()
        // A user barging in with a question is the most common case.
        guard let clip = await bank.getResponse(forUtterance: "Why is the sky blue?") else {
            return XCTFail("Expected a clip for a barge-in question")
        }
        XCTAssertEqual(clip.intent, .engagement,
                       "A question utterance should classify to engagement filler")
    }

    func testGetResponse_rotatesThroughLibrary_toMimicSpontaneity() async {
        let bank = await makePopulatedBank()
        var seen: [String] = []
        for _ in 0..<24 {
            if let clip = await bank.getResponse(for: .engagement) {
                seen.append(clip.text)
            }
        }
        XCTAssertEqual(seen.count, 24, "Every call should return a clip")
        // Real rotation across the curated library, not the same line every time.
        XCTAssertGreaterThanOrEqual(Set(seen).count, 6,
                                    "Filler should rotate through several phrases, not repeat one")
        // Anti-repetition: no two consecutive fillers are identical.
        for i in 1..<seen.count {
            XCTAssertNotEqual(seen[i], seen[i - 1],
                              "Consecutive barge-in fillers must differ")
        }
    }

    func testToTTSAudioChunk_roundTripsDataAndFormat() async {
        let bank = await makePopulatedBank()
        guard let clip = await bank.getResponse(for: .engagement) else {
            return XCTFail("Expected a clip")
        }
        let chunk = clip.toTTSAudioChunk()
        XCTAssertEqual(chunk.audioData, clip.audioData, "Chunk must carry the clip's audio verbatim")
        XCTAssertTrue(chunk.isFirst)
        XCTAssertTrue(chunk.isLast)
        guard case .pcmFloat32(let rate, _) = chunk.format else {
            return XCTFail("Chunk should carry the preserved pcmFloat32 format")
        }
        XCTAssertEqual(rate, 24000)
        // And it must be convertible to a real playback buffer (the unified engine path).
        XCTAssertNoThrow(try chunk.toAVAudioPCMBuffer(),
                         "Filler chunk must convert to an AVAudioPCMBuffer for the unified AudioEngine")
    }

    func testClear_emptiesBank() async {
        let bank = await makePopulatedBank()
        await bank.clear()
        let ready = await bank.isReady
        XCTAssertFalse(ready)
        let clip = await bank.getResponse(for: .engagement)
        XCTAssertNil(clip, "Cleared bank should return no clips")
    }
}
