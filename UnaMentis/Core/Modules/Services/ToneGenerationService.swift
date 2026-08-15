// UnaMentis - Tone Generation Host Service
// RFC 0007, capability "audio.tonegen/1".
//
// Host synthesis of symbolic music prompts (notes, melodic sequences, harmonic
// stacks, simple progressions) for the Aural Skills module and any future
// music-adjacent module. This service is PURE SYNTHESIS: it renders PCM and
// owns no audio hardware, no engine, no player node. Playback happens through
// the ONE unified pipeline: the rendered `PreRenderedAudio` travels inside an
// `Utterance` to `VoiceSession.speak`, the exact route Phase 2 built for
// server-pregenerated question audio (AudioPlaybackOrchestrator over the
// shared AudioEngine). That keeps the "modules never own audio" mandate true
// for non-speech audio with zero new playback machinery.
//
// Synthesis details:
// - Equal temperament, A4 = 440 Hz, MIDI note numbering (C4 = 60).
// - Pure sine timbre in v1 (`ToneTimbre.sine`); richer timbres are additive
//   enum cases per RFC 0007's open questions.
// - Every event gets a soft cosine attack/release envelope so buffer edges
//   never click, a hard requirement of the RFC.
// - Rendering is deterministic and side-effect free, so conformance tests run
//   it for real, headlessly.

import Foundation

// MARK: - Pitch

/// One equal-tempered pitch, addressed by MIDI note number (A4 = 69 = 440 Hz).
///
/// Parseable from scientific note names ("C4", "Eb4", "F#3") so content packs
/// can carry human-readable pitches.
public struct TonePitch: Sendable, Equatable, Hashable {
    /// MIDI note number (C4 = 60, A4 = 69). Valid range 0...127.
    public let midiNote: Int

    /// A pitch from a MIDI note number, clamped to the MIDI range.
    public init(midi: Int) {
        self.midiNote = min(max(midi, 0), 127)
    }

    /// A pitch from a scientific note name: letter A-G, optional accidental
    /// (# or b), octave -1...9 (e.g. "C4", "Eb4", "F#3"). Nil if unparseable.
    public init?(noteName: String) {
        let trimmed = noteName.trimmingCharacters(in: .whitespaces)
        guard let letter = trimmed.first else { return nil }

        let baseSemitones: [Character: Int] = [
            "C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11
        ]
        guard let base = baseSemitones[Character(letter.uppercased())] else { return nil }

        var rest = trimmed.dropFirst()
        var accidental = 0
        if let mark = rest.first {
            if mark == "#" || mark == "\u{266F}" {
                accidental = 1
                rest = rest.dropFirst()
            } else if mark == "b" || mark == "\u{266D}" {
                accidental = -1
                rest = rest.dropFirst()
            }
        }

        guard let octave = Int(rest), (-1...9).contains(octave) else { return nil }
        let midi = (octave + 1) * 12 + base + accidental
        guard (0...127).contains(midi) else { return nil }
        self.midiNote = midi
    }

    /// Equal-tempered frequency in Hz (A4 = 440).
    public var frequency: Double {
        440.0 * pow(2.0, Double(midiNote - 69) / 12.0)
    }

    /// The pitch transposed by `semitones` (clamped to the MIDI range).
    public func transposed(by semitones: Int) -> TonePitch {
        TonePitch(midi: midiNote + semitones)
    }
}

// MARK: - Timbre

/// The waveform family used for synthesis. v1 ships pure sine; additional
/// cases (e.g. a sampled piano) are additive per RFC 0007.
public enum ToneTimbre: String, Sendable, Equatable {
    case sine
}

// MARK: - Events and Prompts

/// One timed sonic event: a single note (one pitch) or a harmonic stack
/// (several pitches sounded together), followed by optional silence.
public struct ToneEvent: Sendable, Equatable {
    /// The pitches sounded simultaneously. One pitch = a note; several = an
    /// interval or chord sounded harmonically.
    public var pitches: [TonePitch]

    /// Duration of the sounding portion, in beats.
    public var beats: Double

    /// Silence appended after the event, in beats (separates melodic notes
    /// and progression chords).
    public var gapBeats: Double

    public init(pitches: [TonePitch], beats: Double = 1.0, gapBeats: Double = 0.0) {
        self.pitches = pitches
        self.beats = beats
        self.gapBeats = gapBeats
    }
}

/// A complete symbolic prompt: an event sequence at a tempo with a timbre.
public struct TonePrompt: Sendable, Equatable {
    /// The events, played in order.
    public var events: [ToneEvent]

    /// Tempo in beats per minute (quarter-note beat basis).
    public var tempo: Double

    /// Synthesis timbre.
    public var timbre: ToneTimbre

    public init(events: [ToneEvent], tempo: Double = 80, timbre: ToneTimbre = .sine) {
        self.events = events
        self.tempo = tempo
        self.timbre = timbre
    }

    /// A single sustained note.
    public static func note(_ pitch: TonePitch, beats: Double = 1.0, tempo: Double = 80) -> TonePrompt {
        TonePrompt(events: [ToneEvent(pitches: [pitch], beats: beats)], tempo: tempo)
    }

    /// A melodic sequence: the pitches played one after another in the order
    /// given (callers order them ascending or descending).
    public static func melodic(
        _ pitches: [TonePitch],
        beatsPerNote: Double = 1.0,
        gapBeats: Double = 0.15,
        tempo: Double = 80
    ) -> TonePrompt {
        let events = pitches.map {
            ToneEvent(pitches: [$0], beats: beatsPerNote, gapBeats: gapBeats)
        }
        return TonePrompt(events: events, tempo: tempo)
    }

    /// A harmonic stack: all pitches sounded together (interval or chord).
    public static func harmonic(
        _ pitches: [TonePitch],
        beats: Double = 2.0,
        tempo: Double = 80
    ) -> TonePrompt {
        TonePrompt(events: [ToneEvent(pitches: pitches, beats: beats)], tempo: tempo)
    }

    /// A chord progression: each stack sounded in sequence (cadences).
    public static func progression(
        _ chords: [[TonePitch]],
        beatsPerChord: Double = 1.5,
        gapBeats: Double = 0.2,
        tempo: Double = 80
    ) -> TonePrompt {
        let events = chords.map {
            ToneEvent(pitches: $0, beats: beatsPerChord, gapBeats: gapBeats)
        }
        return TonePrompt(events: events, tempo: tempo)
    }
}

// MARK: - Errors

/// Typed tone-generation failures.
public enum ToneGenerationError: Error, LocalizedError, Equatable {
    /// The prompt has no events, or an event has no pitches.
    case emptyPrompt
    /// Tempo must be positive and finite.
    case invalidTempo(Double)
    /// An event's duration must be positive and finite.
    case invalidDuration(Double)

    public var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            return "The tone prompt contains no sounding events."
        case .invalidTempo(let tempo):
            return "Invalid tempo: \(tempo) BPM."
        case .invalidDuration(let beats):
            return "Invalid event duration: \(beats) beats."
        }
    }
}

// MARK: - Service Protocol

/// The host tone-generation service (RFC 0007, capability "audio.tonegen/1").
///
/// Pure synthesis: renders symbolic prompts to `PreRenderedAudio` that plays
/// through the module's `VoiceSession` (the unified pipeline). Modules never
/// touch audio internals; they render here and speak the result.
public protocol ToneGenerationService: Sendable {
    /// Render a prompt to raw mono float32 PCM wrapped as `PreRenderedAudio`,
    /// ready for `VoiceSession.speak` via `Utterance.preRendered`.
    func render(_ prompt: TonePrompt) throws -> PreRenderedAudio

    /// Convenience: the rendered prompt wrapped as a speakable `Utterance`.
    /// `spokenFallback` is the text the pipeline would synthesize if the
    /// pre-rendered audio ever failed to play; it must not reveal answers.
    func utterance(for prompt: TonePrompt, spokenFallback: String) throws -> Utterance
}

extension ToneGenerationService {
    public func utterance(for prompt: TonePrompt, spokenFallback: String) throws -> Utterance {
        Utterance(text: spokenFallback, preRendered: try render(prompt))
    }
}

// MARK: - Default Implementation

/// The production tone generator: deterministic sine synthesis with a soft
/// cosine attack/release envelope, rendered at 24 kHz mono float32 (the same
/// shape the pre-rendered TTS path already plays).
public struct DefaultToneGenerationService: ToneGenerationService {
    /// Shared stateless instance (safe: the type holds only constants).
    public static let shared = DefaultToneGenerationService()

    /// Output sample rate. 24 kHz matches the on-device TTS output the
    /// playback path is tuned for; Nyquist comfortably covers MIDI 127.
    public let sampleRate: Double

    /// Peak amplitude of a single sounded pitch. Stacks are scaled by
    /// 1/sqrt(pitchCount) so chords stay at a similar perceived loudness.
    private let baseAmplitude: Double = 0.5

    /// Absolute peak the summed partials may reach. Every partial starts at
    /// phase 0 and they do align, so the worst case is amplitude * pitchCount:
    /// the 1/sqrt(n) scaling alone reaches exactly 1.0 at four pitches and
    /// CLIPS from five up (a seventh or ninth chord in a future pack). The
    /// headroom cap below makes clipping impossible at any stack size.
    private let peakCeiling: Double = 0.95

    /// Longest prompt this service will render, in seconds. `render` is public
    /// API, so an absurd tempo or beat count must surface as a typed error
    /// rather than trap in the Double-to-Int frame-count conversion or try to
    /// allocate an unbounded buffer.
    public static let maximumPromptDuration: TimeInterval = 300

    /// Attack and release lengths in seconds. Short enough to feel immediate,
    /// long enough that no buffer edge ever clicks.
    private let attackSeconds: Double = 0.012
    private let releaseSeconds: Double = 0.045

    public init(sampleRate: Double = 24_000) {
        self.sampleRate = sampleRate
    }

    public func render(_ prompt: TonePrompt) throws -> PreRenderedAudio {
        guard prompt.tempo.isFinite, prompt.tempo > 0 else {
            throw ToneGenerationError.invalidTempo(prompt.tempo)
        }
        guard !prompt.events.isEmpty else {
            throw ToneGenerationError.emptyPrompt
        }

        let secondsPerBeat = 60.0 / prompt.tempo
        var samples: [Float] = []
        var renderedSeconds = 0.0

        for event in prompt.events {
            guard !event.pitches.isEmpty else {
                throw ToneGenerationError.emptyPrompt
            }
            guard event.beats.isFinite, event.beats > 0,
                  event.gapBeats.isFinite, event.gapBeats >= 0 else {
                throw ToneGenerationError.invalidDuration(event.beats)
            }

            let duration = event.beats * secondsPerBeat
            let gapDuration = event.gapBeats * secondsPerBeat
            renderedSeconds += duration + gapDuration
            guard duration.isFinite, gapDuration.isFinite,
                  renderedSeconds.isFinite, renderedSeconds <= Self.maximumPromptDuration else {
                throw ToneGenerationError.invalidDuration(event.beats)
            }

            samples.append(contentsOf: renderEvent(event, duration: duration))

            let gapFrames = Int((gapDuration * sampleRate).rounded())
            if gapFrames > 0 {
                samples.append(contentsOf: [Float](repeating: 0, count: gapFrames))
            }
        }

        // A short tail of silence so playback never truncates the release.
        samples.append(contentsOf: [Float](repeating: 0, count: Int(sampleRate * 0.05)))

        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        return PreRenderedAudio(source: .data(data), sampleRate: sampleRate, channels: 1)
    }

    /// Render one event: summed sines under a soft attack/release envelope.
    private func renderEvent(_ event: ToneEvent, duration: Double) -> [Float] {
        let frameCount = max(1, Int((duration * sampleRate).rounded()))
        let pitchCount = Double(event.pitches.count)
        // Perceptual scaling, capped so the aligned partials can never exceed
        // the headroom ceiling (equal loudness where it is safe, guaranteed
        // no clipping where it is not).
        let amplitude = min(baseAmplitude / pitchCount.squareRoot(), peakCeiling / pitchCount)
        let phaseIncrements = event.pitches.map { 2.0 * Double.pi * $0.frequency / sampleRate }

        // Scale the envelope down for very short events so attack + release
        // always fit inside the event.
        var attackFrames = Int(attackSeconds * sampleRate)
        var releaseFrames = Int(releaseSeconds * sampleRate)
        if attackFrames + releaseFrames >= frameCount {
            let scale = Double(frameCount) / Double(attackFrames + releaseFrames + 1)
            attackFrames = max(1, Int(Double(attackFrames) * scale))
            releaseFrames = max(1, Int(Double(releaseFrames) * scale))
        }

        var rendered = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var value = 0.0
            for increment in phaseIncrements {
                value += sin(increment * Double(frame))
            }
            rendered[frame] = Float(value * amplitude * envelopeGain(
                frame: frame,
                frameCount: frameCount,
                attackFrames: attackFrames,
                releaseFrames: releaseFrames
            ))
        }
        return rendered
    }

    /// Raised-cosine attack/release gain: 0 at the edges, 1 in the sustain.
    private func envelopeGain(
        frame: Int,
        frameCount: Int,
        attackFrames: Int,
        releaseFrames: Int
    ) -> Double {
        if frame < attackFrames {
            let progress = Double(frame) / Double(attackFrames)
            return 0.5 * (1.0 - cos(Double.pi * progress))
        }
        let framesFromEnd = frameCount - 1 - frame
        if framesFromEnd < releaseFrames {
            let progress = Double(framesFromEnd) / Double(releaseFrames)
            return 0.5 * (1.0 - cos(Double.pi * progress))
        }
        return 1.0
    }
}
