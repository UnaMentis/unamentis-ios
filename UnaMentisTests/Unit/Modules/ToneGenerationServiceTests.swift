// UnaMentis - Tone Generation Service Tests
// Verifies the audio.tonegen/1 host capability (RFC 0007) on the REAL
// rendered buffers: frequency correctness (A4 = 440 Hz dominant,
// equal-temperament interval ratios within a cents tolerance), envelope
// softness (no hard buffer edges), harmonic stacks carrying every pitch,
// melodic gaps, and API error behavior.

import XCTest
@testable import UnaMentis

final class ToneGenerationServiceTests: XCTestCase {

    private let service = DefaultToneGenerationService()

    // MARK: - Helpers

    /// Decode a rendered PreRenderedAudio back into float samples.
    private func samples(of audio: PreRenderedAudio) throws -> [Float] {
        guard case .data(let data) = audio.source else {
            XCTFail("Expected in-memory PCM data")
            return []
        }
        XCTAssertEqual(Int(audio.channels), 1, "Tone output must be mono")
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    /// Estimate the dominant frequency of a (single-tone) region by counting
    /// positive-going zero crossings.
    private func zeroCrossingFrequency(
        _ samples: [Float], sampleRate: Double, from start: Int, count: Int
    ) -> Double {
        let end = min(start + count, samples.count)
        guard end > start + 1 else { return 0 }
        var crossings = 0
        for index in (start + 1)..<end where samples[index - 1] < 0 && samples[index] >= 0 {
            crossings += 1
        }
        let seconds = Double(end - start) / sampleRate
        return Double(crossings) / seconds
    }

    /// Goertzel magnitude of one frequency over a region (chord content).
    private func goertzelMagnitude(
        _ samples: [Float], sampleRate: Double, frequency: Double, from start: Int, count: Int
    ) -> Double {
        let end = min(start + count, samples.count)
        guard end > start else { return 0 }
        let omega = 2.0 * Double.pi * frequency / sampleRate
        let coeff = 2.0 * cos(omega)
        var sPrev = 0.0
        var sPrev2 = 0.0
        for index in start..<end {
            let s = Double(samples[index]) + coeff * sPrev - sPrev2
            sPrev2 = sPrev
            sPrev = s
        }
        let power = sPrev2 * sPrev2 + sPrev * sPrev - coeff * sPrev * sPrev2
        return sqrt(max(power, 0))
    }

    // MARK: - Frequency correctness

    func testA4RendersDominant440Hz() throws {
        // 1 beat at 60 BPM = exactly 1 second of tone.
        let audio = try service.render(.note(TonePitch(midi: 69), beats: 1.0, tempo: 60))
        let pcm = try samples(of: audio)
        XCTAssertEqual(audio.sampleRate, service.sampleRate)

        // Measure the sustain (skip the attack, stop before the release).
        let start = Int(service.sampleRate * 0.05)
        let count = Int(service.sampleRate * 0.85)
        let frequency = zeroCrossingFrequency(
            pcm, sampleRate: service.sampleRate, from: start, count: count
        )
        XCTAssertEqual(frequency, 440.0, accuracy: 4.0, "A4 must render as 440 Hz")
    }

    func testPerfectFifthMatchesEqualTemperamentWithinCents() throws {
        // A4 (440) and E5, a perfect fifth up: 2^(7/12) ~ 1.4983, within a
        // few cents of the pure 3:2 ratio.
        let lower = try samples(of: service.render(.note(TonePitch(midi: 69), beats: 1, tempo: 60)))
        let upper = try samples(of: service.render(.note(TonePitch(midi: 76), beats: 1, tempo: 60)))

        let start = Int(service.sampleRate * 0.05)
        let count = Int(service.sampleRate * 0.85)
        let lowerHz = zeroCrossingFrequency(lower, sampleRate: service.sampleRate, from: start, count: count)
        let upperHz = zeroCrossingFrequency(upper, sampleRate: service.sampleRate, from: start, count: count)

        let ratio = upperHz / lowerHz
        let centsFromPureFifth = 1200.0 * log2(ratio / 1.5)
        // Equal temperament sits 1.955 cents under 3:2; allow measurement noise.
        XCTAssertEqual(centsFromPureFifth, -1.955, accuracy: 8.0,
                       "P5 ratio \(ratio) is out of equal-temperament tolerance")

        let centsFromEqualTemperament = 1200.0 * log2(ratio / pow(2.0, 7.0 / 12.0))
        XCTAssertEqual(centsFromEqualTemperament, 0.0, accuracy: 8.0)
    }

    func testHarmonicStackContainsBothPitchesAndNotOthers() throws {
        // A4 + E5 sounded together.
        let audio = try service.render(
            .harmonic([TonePitch(midi: 69), TonePitch(midi: 76)], beats: 2, tempo: 60)
        )
        let pcm = try samples(of: audio)
        let start = Int(service.sampleRate * 0.1)
        let count = Int(service.sampleRate * 1.5)

        let magA4 = goertzelMagnitude(pcm, sampleRate: service.sampleRate, frequency: 440.0, from: start, count: count)
        let magE5 = goertzelMagnitude(pcm, sampleRate: service.sampleRate, frequency: 659.255, from: start, count: count)
        let magAbsent = goertzelMagnitude(pcm, sampleRate: service.sampleRate, frequency: 550.0, from: start, count: count)

        XCTAssertGreaterThan(magA4, magAbsent * 10, "The root pitch must dominate non-chord tones")
        XCTAssertGreaterThan(magE5, magAbsent * 10, "The fifth must dominate non-chord tones")
    }

    // MARK: - Envelope

    func testEnvelopeHasNoHardEdges() throws {
        let audio = try service.render(.note(TonePitch(noteName: "C4")!, beats: 1, tempo: 80))
        let pcm = try samples(of: audio)
        XCTAssertFalse(pcm.isEmpty)

        // Edges start and end at (near) zero.
        XCTAssertLessThan(abs(pcm.first ?? 1), 0.02, "Attack must start from silence")
        XCTAssertLessThan(abs(pcm.last ?? 1), 0.02, "Release must end in silence")

        // Soft attack: the first millisecond stays well below peak.
        let firstMs = pcm.prefix(Int(service.sampleRate / 1000)).map { abs($0) }.max() ?? 1
        let peak = pcm.map { abs($0) }.max() ?? 0
        XCTAssertLessThan(firstMs, peak * 0.5, "Attack must ramp, not step")

        // No discontinuities: adjacent-sample jumps stay near the sine's own
        // maximum slope (a click would jump by the full amplitude).
        var maxDelta: Float = 0
        for index in 1..<pcm.count {
            maxDelta = max(maxDelta, abs(pcm[index] - pcm[index - 1]))
        }
        XCTAssertLessThan(maxDelta, 0.2, "No hard edges anywhere in the buffer")

        // And nothing clips.
        XCTAssertLessThanOrEqual(peak, 1.0)
    }

    func testMelodicSequenceHasSilentGapBetweenNotes() throws {
        // Two notes at 80 BPM: 1 beat tone (0.75 s), 0.15 beat gap.
        let prompt = TonePrompt.melodic(
            [TonePitch(noteName: "C4")!, TonePitch(noteName: "E4")!],
            beatsPerNote: 1.0, gapBeats: 0.15, tempo: 80
        )
        let pcm = try samples(of: try service.render(prompt))

        let noteFrames = Int(0.75 * service.sampleRate)
        let gapFrames = Int(0.15 * 0.75 * service.sampleRate)
        let gapRegion = pcm[(noteFrames + 5)..<(noteFrames + gapFrames - 5)]
        let gapPeak = gapRegion.map { abs($0) }.max() ?? 1
        XCTAssertLessThan(gapPeak, 0.001, "The inter-note gap must be silent")
    }

    func testChordAmplitudeDoesNotClip() throws {
        let chord = [60, 64, 67, 72].map { TonePitch(midi: $0) }
        let pcm = try samples(of: try service.render(.harmonic(chord, beats: 2, tempo: 60)))
        let peak = pcm.map { abs($0) }.max() ?? 0
        XCTAssertLessThanOrEqual(peak, 1.0, "Chords must not clip")
        XCTAssertGreaterThan(peak, 0.1, "Chords must still be audible")
    }

    func testDenseChordsKeepHeadroom() throws {
        // Every partial starts at phase 0 and they do align, so 1/sqrt(n)
        // alone reaches exactly 1.0 at four pitches and CLIPS from five up
        // (a seventh or ninth chord in a future pack).
        for pitchCount in 1...9 {
            let chord = (0..<pitchCount).map { TonePitch(midi: 55 + $0 * 2) }
            let pcm = try samples(of: try service.render(.harmonic(chord, beats: 1, tempo: 60)))
            let peak = pcm.map { abs($0) }.max() ?? 0
            XCTAssertLessThanOrEqual(peak, 1.0, "A \(pitchCount)-pitch stack must not clip")
            XCTAssertGreaterThan(peak, 0.05, "A \(pitchCount)-pitch stack must still be audible")
        }
    }

    // MARK: - API behavior

    func testEmptyPromptThrows() {
        XCTAssertThrowsError(try service.render(TonePrompt(events: [], tempo: 80))) { error in
            XCTAssertEqual(error as? ToneGenerationError, .emptyPrompt)
        }
        let unpitched = TonePrompt(events: [ToneEvent(pitches: [], beats: 1)], tempo: 80)
        XCTAssertThrowsError(try service.render(unpitched)) { error in
            XCTAssertEqual(error as? ToneGenerationError, .emptyPrompt)
        }
    }

    func testInvalidTempoAndDurationThrow() {
        let note = ToneEvent(pitches: [TonePitch(midi: 60)], beats: 1)
        XCTAssertThrowsError(try service.render(TonePrompt(events: [note], tempo: 0))) { error in
            XCTAssertEqual(error as? ToneGenerationError, .invalidTempo(0))
        }
        let zeroBeats = TonePrompt(events: [ToneEvent(pitches: [TonePitch(midi: 60)], beats: 0)], tempo: 80)
        XCTAssertThrowsError(try service.render(zeroBeats)) { error in
            XCTAssertEqual(error as? ToneGenerationError, .invalidDuration(0))
        }
    }

    func testAbsurdDurationsThrowInsteadOfTrapping() {
        // render is public API: a huge beat count, or a tempo so slow that one
        // beat runs for years, must surface as a typed error rather than trap
        // in the Double-to-Int frame-count conversion.
        let hugeBeats = TonePrompt(
            events: [ToneEvent(pitches: [TonePitch(midi: 60)], beats: 1e12)], tempo: 80
        )
        XCTAssertThrowsError(try service.render(hugeBeats)) { error in
            guard case .invalidDuration = (error as? ToneGenerationError) else {
                return XCTFail("Expected invalidDuration, got \(error)")
            }
        }

        let glacialTempo = TonePrompt(
            events: [ToneEvent(pitches: [TonePitch(midi: 60)], beats: 1)], tempo: 0.0000001
        )
        XCTAssertThrowsError(try service.render(glacialTempo)) { error in
            guard case .invalidDuration = (error as? ToneGenerationError) else {
                return XCTFail("Expected invalidDuration, got \(error)")
            }
        }

        let hugeGap = TonePrompt(
            events: [ToneEvent(pitches: [TonePitch(midi: 60)], beats: 1, gapBeats: 1e9)], tempo: 80
        )
        XCTAssertThrowsError(try service.render(hugeGap)) { error in
            guard case .invalidDuration = (error as? ToneGenerationError) else {
                return XCTFail("Expected invalidDuration, got \(error)")
            }
        }

        let infinite = TonePrompt(
            events: [ToneEvent(pitches: [TonePitch(midi: 60)], beats: .infinity)], tempo: 80
        )
        XCTAssertThrowsError(try service.render(infinite))
    }

    func testNoteNameParsing() {
        XCTAssertEqual(TonePitch(noteName: "C4")?.midiNote, 60)
        XCTAssertEqual(TonePitch(noteName: "A4")?.midiNote, 69)
        XCTAssertEqual(TonePitch(noteName: "Eb4")?.midiNote, 63)
        XCTAssertEqual(TonePitch(noteName: "F#3")?.midiNote, 54)
        XCTAssertEqual(TonePitch(noteName: "c4")?.midiNote, 60, "Lowercase letters parse")
        XCTAssertNil(TonePitch(noteName: "H2"))
        XCTAssertNil(TonePitch(noteName: "C"))
        XCTAssertNil(TonePitch(noteName: ""))
        XCTAssertEqual(TonePitch(midi: 69).frequency, 440.0, accuracy: 0.001)
    }

    func testUtteranceCarriesPreRenderedAudio() throws {
        let utterance = try service.utterance(
            for: .note(TonePitch(midi: 60)), spokenFallback: "Here is the sound."
        )
        XCTAssertEqual(utterance.text, "Here is the sound.")
        XCTAssertNotNil(utterance.preRendered)
        XCTAssertEqual(utterance.preRendered?.sampleRate, service.sampleRate)
        XCTAssertEqual(utterance.preRendered?.channels, 1)
    }
}
