// UnaMentis - TTSAudioChunkTests
// Unit tests for TTS audio-format mapping, PCM buffer construction,
// error descriptions, and provider cost calculations.
//
// All of this is deterministic, network-free decoding/format logic that the
// playback pipeline depends on. WAV header stripping and frame-count math in
// particular are easy to break and would silently corrupt playback.

import XCTest
import AVFoundation
@testable import UnaMentis

final class TTSAudioChunkTests: XCTestCase {

    // MARK: - TTSAudioFormat -> AVAudioFormat

    func testPCMFloat32MapsToFloat32Format() throws {
        let format = TTSAudioFormat.pcmFloat32(sampleRate: 22050, channels: 1)
        let avFormat = try XCTUnwrap(format.avAudioFormat)
        XCTAssertEqual(avFormat.commonFormat, .pcmFormatFloat32)
        XCTAssertEqual(avFormat.sampleRate, 22050)
        XCTAssertEqual(avFormat.channelCount, 1)
    }

    func testPCMInt16MapsToInt16Format() throws {
        let format = TTSAudioFormat.pcmInt16(sampleRate: 24000, channels: 1)
        let avFormat = try XCTUnwrap(format.avAudioFormat)
        XCTAssertEqual(avFormat.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(avFormat.sampleRate, 24000)
        XCTAssertEqual(avFormat.channelCount, 1)
    }

    func testCompressedFormatsHaveNoAVFormat() {
        // mp3/opus/aac require decoding first, so there is no direct AVAudioFormat.
        XCTAssertNil(TTSAudioFormat.mp3.avAudioFormat)
        XCTAssertNil(TTSAudioFormat.opus.avAudioFormat)
        XCTAssertNil(TTSAudioFormat.aac.avAudioFormat)
    }

    // MARK: - toAVAudioPCMBuffer: frame-count math

    func testInt16BufferFrameCountFromRawPCM() throws {
        // 200 bytes of Int16 mono = 100 frames (2 bytes per frame).
        let raw = Data(count: 200)
        let chunk = TTSAudioChunk(
            audioData: raw,
            format: .pcmInt16(sampleRate: 24000, channels: 1),
            sequenceNumber: 0,
            isFirst: true,
            isLast: true
        )
        let buffer = try chunk.toAVAudioPCMBuffer()
        XCTAssertEqual(buffer.frameLength, 100)
        XCTAssertEqual(buffer.format.commonFormat, .pcmFormatInt16)
    }

    func testFloat32BufferFrameCountFromRawPCM() throws {
        // 400 bytes of Float32 mono = 100 frames (4 bytes per frame).
        let raw = Data(count: 400)
        let chunk = TTSAudioChunk(
            audioData: raw,
            format: .pcmFloat32(sampleRate: 22050, channels: 1),
            sequenceNumber: 0,
            isFirst: true,
            isLast: true
        )
        let buffer = try chunk.toAVAudioPCMBuffer()
        XCTAssertEqual(buffer.frameLength, 100)
    }

    // MARK: - toAVAudioPCMBuffer: WAV header stripping

    func testWavHeaderIsStrippedBeforeFraming() throws {
        // A real RIFF/WAV payload: 44-byte header + 200 bytes of Int16 samples.
        // The buffer must reflect only the 200 sample bytes (100 frames), proving
        // the 44-byte header was dropped rather than treated as audio.
        var wav = Data([0x52, 0x49, 0x46, 0x46]) // "RIFF"
        wav.append(Data(count: 40))               // rest of the 44-byte header
        wav.append(Data(count: 200))              // 200 bytes of Int16 PCM
        XCTAssertEqual(wav.count, 244)

        let chunk = TTSAudioChunk(
            audioData: wav,
            format: .pcmInt16(sampleRate: 22050, channels: 1),
            sequenceNumber: 0,
            isFirst: true,
            isLast: true
        )
        let buffer = try chunk.toAVAudioPCMBuffer()
        XCTAssertEqual(buffer.frameLength, 100, "header bytes should not count as audio frames")
    }

    func testNonWavDataIsNotStripped() throws {
        // Raw PCM that happens NOT to start with RIFF must be kept intact.
        // 244 bytes of Int16 = 122 frames; nothing should be dropped.
        var raw = Data([0x00, 0x01, 0x02, 0x03]) // not "RIFF"
        raw.append(Data(count: 240))
        XCTAssertEqual(raw.count, 244)

        let chunk = TTSAudioChunk(
            audioData: raw,
            format: .pcmInt16(sampleRate: 22050, channels: 1),
            sequenceNumber: 0,
            isFirst: true,
            isLast: true
        )
        let buffer = try chunk.toAVAudioPCMBuffer()
        XCTAssertEqual(buffer.frameLength, 122, "raw PCM should not have a header stripped")
    }

    // MARK: - toAVAudioPCMBuffer: error path

    func testCompressedFormatThrowsInvalidAudioFormat() {
        // mp3 has no AVAudioFormat, so buffer construction must surface a typed error.
        let chunk = TTSAudioChunk(
            audioData: Data(count: 128),
            format: .mp3,
            sequenceNumber: 0,
            isFirst: true,
            isLast: true
        )
        XCTAssertThrowsError(try chunk.toAVAudioPCMBuffer()) { error in
            guard case TTSError.invalidAudioFormat = error else {
                return XCTFail("expected .invalidAudioFormat, got \(error)")
            }
        }
    }

    // MARK: - TTSError descriptions

    func testErrorDescriptionsIncludeContext() {
        XCTAssertEqual(
            TTSError.synthesizeFailed("boom").errorDescription,
            "TTS synthesis failed: boom"
        )
        XCTAssertEqual(
            TTSError.connectionFailed("HTTP 500").errorDescription,
            "TTS connection failed: HTTP 500"
        )
        XCTAssertEqual(
            TTSError.voiceNotFound("aura-zeus-en").errorDescription,
            "Voice not found: aura-zeus-en"
        )
        XCTAssertEqual(TTSError.invalidAudioFormat.errorDescription, "Invalid audio format from TTS")
        XCTAssertEqual(TTSError.bufferCreationFailed.errorDescription, "Failed to create audio buffer")
        XCTAssertEqual(TTSError.authenticationFailed.errorDescription, "TTS authentication failed")
        XCTAssertEqual(TTSError.rateLimited.errorDescription, "TTS rate limit exceeded")
        XCTAssertEqual(TTSError.quotaExceeded.errorDescription, "TTS quota exceeded")
    }

    // MARK: - Provider cost calculations (deterministic, no network)

    func testDeepgramCostPerCharacter() async {
        let service = DeepgramTTSService(apiKey: "test_key")
        let cost = await service.costPerCharacter
        // $0.0135 per 1000 chars.
        XCTAssertEqual(cost, Decimal(0.0135) / 1000)
    }

    func testElevenLabsCostPerCharacter() async throws {
        let service = ElevenLabsTTSService(apiKey: "test_key")
        let cost = await service.costPerCharacter
        // Turbo v2.5: $18 per 1M characters = $0.000018/char.
        let expected = try XCTUnwrap(Decimal(string: "0.000018"))
        XCTAssertEqual(cost, expected)
    }

    func testAppleTTSIsFree() async {
        let service = AppleTTSService()
        let cost = await service.costPerCharacter
        XCTAssertEqual(cost, 0)
    }

    func testSelfHostedIsFree() async {
        let service = SelfHostedTTSService(baseURL: URL(string: "http://localhost:11402")!)
        let cost = await service.costPerCharacter
        XCTAssertEqual(cost, 0)
    }

    func testChatterboxIsFree() async {
        let service = ChatterboxTTSService(baseURL: URL(string: "http://localhost:8004")!)
        let cost = await service.costPerCharacter
        XCTAssertEqual(cost, 0)
    }
}
