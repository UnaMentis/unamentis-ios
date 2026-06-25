// UnaMentis - STT Audio Conversion Tests
// Unit tests for the AVAudioPCMBuffer -> Int16 PCM conversions used by the
// cloud STT providers.
//
// Two distinct conversion extensions feed real network payloads:
//   - toPCMInt16Data(): used by Deepgram (linear16 WebSocket) and the
//     self-hosted Whisper streaming path.
//   - toData(): used by AssemblyAI (base64 PCM over WebSocket).
//
// Both turn Float32 samples into little-endian Int16 PCM. The byte layout and
// the clamping of out-of-range samples are the real contract: if conversion
// drifts, the server receives corrupted or wrong-length audio and transcription
// silently degrades. The GLM-ASR conversion (toGLMASRPCMData) is covered
// elsewhere; this file covers the two cloud-provider conversions, which behave
// slightly differently from each other at the clamp boundaries.

import XCTest
import AVFoundation
@testable import UnaMentis

final class STTAudioConversionTests: XCTestCase {

    // MARK: - Helpers

    /// Build a mono Float32 buffer at 16kHz filled with the given samples.
    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        )!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = buffer.floatChannelData![0]
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }
        return buffer
    }

    /// Read the little-endian Int16 samples out of converted PCM data.
    private func int16Samples(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int16.self))
        }
    }

    // MARK: - toPCMInt16Data (Deepgram / self-hosted)

    func testToPCMInt16Data_producesTwoBytesPerSample() {
        let buffer = makeBuffer([Float](repeating: 0.0, count: 256))

        let data = buffer.toPCMInt16Data()

        XCTAssertNotNil(data)
        // 256 samples * 2 bytes/sample = 512 bytes. A wrong length means the
        // server would misalign the audio frames.
        XCTAssertEqual(data?.count, 512)
    }

    func testToPCMInt16Data_silenceMapsToZero() {
        let buffer = makeBuffer([0.0, 0.0, 0.0])

        let samples = int16Samples(buffer.toPCMInt16Data()!)

        XCTAssertEqual(samples, [0, 0, 0])
    }

    func testToPCMInt16Data_fullScaleSamplesMapToFullScaleInt16() {
        // +1.0 -> +32767, -1.0 -> -32767 (this extension scales by 32767.0).
        let buffer = makeBuffer([1.0, -1.0])

        let samples = int16Samples(buffer.toPCMInt16Data()!)

        XCTAssertEqual(samples, [32767, -32767])
    }

    func testToPCMInt16Data_clampsOutOfRangeSamples() {
        // Out-of-range floats must saturate, not wrap. This extension clamps the
        // scaled value to [-32768, 32767], so +2.0 -> 32767 and -2.0 -> -32768
        // (Int16.min). Wrapping here would inject loud clicks into the audio.
        let buffer = makeBuffer([2.0, -2.0])

        let samples = int16Samples(buffer.toPCMInt16Data()!)

        XCTAssertEqual(samples, [32767, -32768])
    }

    func testToPCMInt16Data_isLittleEndian() {
        // 1.0 -> 32767 (0x7FFF) must serialize as 0xFF 0x7F on the wire.
        let buffer = makeBuffer([1.0])

        let bytes = Array(buffer.toPCMInt16Data()!)

        XCTAssertEqual(bytes, [0xFF, 0x7F])
    }

    // MARK: - toData (AssemblyAI)

    func testToData_producesTwoBytesPerSample() {
        let buffer = makeBuffer([Float](repeating: 0.0, count: 100))

        let data = buffer.toData()

        XCTAssertNotNil(data)
        XCTAssertEqual(data?.count, 200, "100 samples * 2 bytes = 200 bytes")
    }

    func testToData_fullScaleSamplesMapToFullScaleInt16() {
        // toData scales by Int16.max, so +1.0 -> 32767 and -1.0 -> -32767.
        let buffer = makeBuffer([1.0, -1.0])

        let samples = int16Samples(buffer.toData()!)

        XCTAssertEqual(samples, [32767, -32767])
    }

    func testToData_clampsToUnitRangeBeforeScaling() {
        // toData clamps the float to [-1.0, 1.0] first, so +2.0 -> 32767 and
        // -2.0 -> -32767 (note: NOT Int16.min, unlike toPCMInt16Data). This
        // documents the actual, distinct clamp behavior of the AssemblyAI path.
        let buffer = makeBuffer([2.0, -2.0])

        let samples = int16Samples(buffer.toData()!)

        XCTAssertEqual(samples, [32767, -32767])
    }

    func testToData_silenceMapsToZero() {
        let buffer = makeBuffer([0.0, 0.0])

        let samples = int16Samples(buffer.toData()!)

        XCTAssertEqual(samples, [0, 0])
    }
}
