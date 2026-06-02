// UnaMentis - Barge-In Corpus
// ===========================
//
// The labeled audio the measurement runs against. Each clip carries its true
// type (command / engagement / noise / echo), which fixes the expected outcome
// (see BargeInClipType): positives should be detected and classified, negatives
// (noise, the app's own TTS echo) should not trigger a barge-in.
//
// Two ways to source clips:
//   - A built-in `simulatorSeed()` that synthesizes utterances with the real
//     session TTS and generates synthetic noise. Needs no bundled files, so the
//     simulator integration test is hermetic. It validates the harness mechanics
//     and the detection/classification logic on clean speech.
//   - A `manifest.json` of real recorded human utterances (varied speakers, at
//     known SNRs) plus echo clips, for the device run that is the goal's source
//     of truth. The seed is the floor, real recordings are how the bar is met.

import AVFoundation
import Foundation

/// One labeled clip specification.
public struct BargeInCorpusClip: Sendable, Codable {
    /// How the clip's audio is produced.
    public enum Source: String, Sendable, Codable {
        /// Synthesize `text` with the session TTS (used for utterances and echo).
        case tts
        /// Generate synthetic low-amplitude background noise.
        case noise
        /// Load `file` (relative to the manifest) from disk.
        case file
    }

    public let id: String
    public let type: BargeInClipType
    public let source: Source
    /// Spoken text for `tts`, or reference text for a recording.
    public let text: String?
    /// Path relative to the manifest directory, for `file`.
    public let file: String?
    /// Synthetic noise duration in seconds, for `noise`.
    public let durationSec: Double?

    public init(
        id: String,
        type: BargeInClipType,
        source: Source,
        text: String? = nil,
        file: String? = nil,
        durationSec: Double? = nil
    ) {
        self.id = id
        self.type = type
        self.source = source
        self.text = text
        self.file = file
        self.durationSec = durationSec
    }
}

/// A loadable manifest of clips.
public struct BargeInManifest: Sendable, Codable {
    public let clips: [BargeInCorpusClip]
    public init(clips: [BargeInCorpusClip]) { self.clips = clips }
}

public enum BargeInCorpus {

    /// Built-in, file-free seed for the simulator. Real recordings are added via
    /// a manifest for the device run.
    public static func simulatorSeed() -> [BargeInCorpusClip] {
        var clips: [BargeInCorpusClip] = []

        let commands = [
            "bookmark this",
            "flag this for review",
            "next",
            "skip this one",
            "repeat that"
        ]
        for (i, text) in commands.enumerated() {
            clips.append(BargeInCorpusClip(id: "cmd-\(i)", type: .command, source: .tts, text: text))
        }

        let engagements = [
            "why does that happen",
            "can you explain that differently",
            "what does that word mean",
            "I don't understand the second part",
            "tell me more about this"
        ]
        for (i, text) in engagements.enumerated() {
            clips.append(BargeInCorpusClip(id: "eng-\(i)", type: .engagement, source: .tts, text: text))
        }

        // Negatives: low-amplitude background noise (content-based, so an
        // injection run can reject it). Echo clips are deliberately NOT here:
        // echo rejection is an acoustic-echo-cancellation phenomenon that needs
        // the real mic/speaker path, so it is a device/real-acoustic corpus
        // concept (BargeInClipType.echo) measured on device, not by injection.
        clips.append(BargeInCorpusClip(id: "noise-0", type: .noise, source: .noise, durationSec: 1.5))
        clips.append(BargeInCorpusClip(id: "noise-1", type: .noise, source: .noise, durationSec: 1.0))

        return clips
    }

    /// Load a manifest.json and resolve relative file paths against its directory.
    public static func load(manifestPath: String) throws -> [BargeInCorpusClip] {
        let url = URL(fileURLWithPath: manifestPath)
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(BargeInManifest.self, from: data)
        let dir = url.deletingLastPathComponent().path
        return manifest.clips.map { clip in
            guard clip.source == .file, let file = clip.file, !file.hasPrefix("/") else { return clip }
            return BargeInCorpusClip(
                id: clip.id, type: clip.type, source: .file,
                text: clip.text, file: "\(dir)/\(file)", durationSec: clip.durationSec
            )
        }
    }

    /// Generate a synthetic low-amplitude white-noise buffer (16kHz mono float32).
    /// Amplitude is deliberately well below speech so a content-aware VAD rejects
    /// it; deterministic per id so runs are reproducible.
    static func syntheticNoise(id: String, durationSec: Double) -> AVAudioPCMBuffer? {
        let sampleRate = 16_000.0
        let frameCount = AVAudioFrameCount(durationSec * sampleRate)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        guard let channel = buffer.floatChannelData?[0] else { return nil }

        // Deterministic LCG seeded by the clip id.
        var state = UInt64(bitPattern: Int64(id.hashValue)) | 1
        let amplitude: Float = 0.004
        for i in 0..<Int(frameCount) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            // Top 32 bits -> [0,1) -> [-1,1) (symmetric, not the negative-biased
            // [-1,0) a 31-bit shift would give).
            let unit = Float(Double(state >> 32) / Double(UInt64(1) << 32)) * 2.0 - 1.0
            channel[i] = unit * amplitude
        }
        return buffer
    }
}
