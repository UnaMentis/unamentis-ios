// UnaMentis - Barge-In Measurement Harness
// ========================================
//
// Runs a labeled corpus through the REAL detection pipeline and aggregates the
// goal criteria. For each clip it does one real-time-paced pass that feeds the
// audio to the VAD -> BargeInDetector path (detection + reaction latency), then
// classifies the clip's known utterance text (command vs engagement) and records
// a BargeInClipOutcome. BargeInMetrics turns the outcomes into the numbers the
// skill checks against .claude/goals/barge-in.json.
//
// There is NO STT here. On the simulator the harness classifies each TTS clip's
// known text, which isolates the classifier's accuracy from recognition errors
// and keeps the harness off Apple Speech (a hard project mandate). STT
// time-to-first-partial is a real-streaming-STT measurement that belongs to the
// on-device STT workstream; it is device-only.
//
// Frames are paced in real time so the VAD experiences the real cadence and the
// reaction latency is meaningful. The injection path excludes hardware capture
// latency and speaker echo, and the Silero CoreML model may behave differently
// on the simulator. The goal's source of truth is a real-acoustic DEVICE run
// (mic + speaker + echo) with the real streaming STT.

import AVFoundation
import Foundation

// MARK: - Result

/// Serializable result of a measurement run (written to build/barge-in-results).
public struct BargeInMeasurementResult: Sendable, Codable {
    public let mode: String
    public let sttProvider: String
    public let ttsProvider: String
    public let confidenceThreshold: Float
    public let confirmationMs: Int
    public let metrics: BargeInMetrics
    public let outcomes: [BargeInClipOutcome]
    public let thermalState: String
    public let peakMemoryMB: Double?
    public let clipCount: Int
}

public enum BargeInHarnessError: Error {
    case audioGenerationFailed(String)
}

// MARK: - Harness

public actor BargeInMeasurementHarness {

    private let vadService: any VADService
    private let detectorConfig: BargeInDetectorConfig
    private let classifier: BargeInClassifier
    private let generator = KBAudioGenerator()

    public init(
        vadService: any VADService = SileroVADService(),
        detectorConfig: BargeInDetectorConfig = BargeInDetectorConfig(),
        classifier: BargeInClassifier = BargeInClassifier()
    ) {
        self.vadService = vadService
        self.detectorConfig = detectorConfig
        self.classifier = classifier
    }

    /// Run the full corpus and aggregate metrics.
    public func run(corpus: [BargeInCorpusClip], mode: String = "simulator") async -> BargeInMeasurementResult {
        var outcomes: [BargeInClipOutcome] = []
        var peakMemoryMB: Double = 0

        // Activate the VAD (loads the Silero CoreML model, or falls back to
        // energy-based detection). Without this, processBuffer returns silence.
        try? await vadService.prepare()

        for clip in corpus {
            let buffer: AVAudioPCMBuffer
            do {
                buffer = try await bufferFor(clip)
            } catch {
                outcomes.append(BargeInClipOutcome(clipId: clip.id, type: clip.type, detected: false))
                continue
            }
            let outcome = await measureClip(clip, buffer: buffer)
            outcomes.append(outcome)
            peakMemoryMB = max(peakMemoryMB, Self.currentMemoryMB())
        }

        return BargeInMeasurementResult(
            mode: mode,
            sttProvider: "none (known-text classification; STT first-partial is device-only)",
            ttsProvider: TTSProvider.pocketTTS.rawValue,
            confidenceThreshold: detectorConfig.confidenceThreshold,
            confirmationMs: detectorConfig.sustainedSpeechMs,
            metrics: BargeInMetrics.compute(from: outcomes),
            outcomes: outcomes,
            thermalState: Self.thermalString(),
            peakMemoryMB: peakMemoryMB > 0 ? peakMemoryMB : nil,
            clipCount: corpus.count
        )
    }

    // MARK: Per-clip measurement

    private func measureClip(_ clip: BargeInCorpusClip, buffer: AVAudioPCMBuffer) async -> BargeInClipOutcome {
        // Clear VAD smoothing/state so the previous clip does not bleed in.
        await vadService.reset()

        let detector = BargeInDetector(config: detectorConfig)
        let collector = EventCollector()
        let eventTask = Task { for await event in detector.events { await collector.add(event) } }
        await detector.arm()

        // Feed 32ms frames (512 samples @ 16kHz) to the VAD and detector, paced
        // in real time so the VAD experiences the real cadence and the reaction
        // latency is meaningful. No STT here: the harness measures detection and
        // classification. STT time-to-first-partial is a real-streaming-STT
        // measurement that belongs to the on-device STT workstream.
        let onset = mach_absolute_time()
        let frameSize: AVAudioFrameCount = 512
        var position: AVAudioFrameCount = 0
        while position < buffer.frameLength {
            if let frame = Self.slice(buffer, from: position, count: frameSize) {
                let vad = await vadService.processBuffer(frame)
                await detector.process(vad)
            }
            position += frameSize
            try? await Task.sleep(nanoseconds: 32_000_000)
        }
        // Grace for confirm/resume to settle after the last frame.
        try? await Task.sleep(nanoseconds: 250_000_000)
        // finish() ends the event stream; await the consumer so every emitted
        // event is collected before we read it (no cancel-before-drain race).
        await detector.finish()
        await eventTask.value

        let events = await collector.all()
        let confirmed = events.first { $0.kind == .confirmed }
        let detected = confirmed != nil
        let reactionMs = confirmed.map { Self.machToMs($0.machTime &- onset) }

        // Classify the known utterance text (the TTS speaks exactly this), which
        // isolates the classifier's accuracy from STT errors. On device, the real
        // STT transcript is used instead, folding in recognition errors.
        let transcript = clip.text ?? ""
        var predicted: BargeInCategory?
        if detected && !transcript.isEmpty {
            predicted = await classifier.classify(transcript: transcript).category
        }

        return BargeInClipOutcome(
            clipId: clip.id,
            type: clip.type,
            detected: detected,
            reactionMs: reactionMs,
            firstPartialMs: nil,
            predictedClass: predicted,
            transcript: transcript.isEmpty ? nil : transcript
        )
    }

    private func bufferFor(_ clip: BargeInCorpusClip) async throws -> AVAudioPCMBuffer {
        switch clip.source {
        case .tts:
            return try await generator.generateAudio(for: clip.text ?? "", using: .pocketTTS).buffer
        case .file:
            return try await generator.loadAudioFile(at: clip.file ?? "").buffer
        case .noise:
            guard let buffer = BargeInCorpus.syntheticNoise(id: clip.id, durationSec: clip.durationSec ?? 1.0) else {
                throw BargeInHarnessError.audioGenerationFailed(clip.id)
            }
            return buffer
        }
    }

    // MARK: Helpers

    /// Extract a sub-buffer [start, start+count) from a mono float32 buffer.
    /// Returns a freshly allocated, disconnected buffer (hence `sending`) so the
    /// caller can hand it to an actor (STT/VAD) without a data race.
    private static func slice(_ buffer: AVAudioPCMBuffer, from start: AVAudioFrameCount, count: AVAudioFrameCount) -> sending AVAudioPCMBuffer? {
        guard start < buffer.frameLength, let src = buffer.floatChannelData?[0] else { return nil }
        let n = min(count, buffer.frameLength - start)
        guard n > 0 else { return nil }

        // Copy into a value-type array and a fresh format so the returned buffer
        // is a fully disconnected region (safe to send to an actor). All harness
        // input buffers are 16kHz mono float32 (STT format).
        let samples = Array(UnsafeBufferPointer(start: src + Int(start), count: Int(n)))
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16_000, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n),
              let dst = out.floatChannelData?[0] else { return nil }
        out.frameLength = n
        samples.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress { dst.update(from: base, count: Int(n)) }
        }
        return out
    }

    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    private static func machToMs(_ delta: UInt64) -> Double {
        Double(delta) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000.0
    }

    private static func thermalString() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func currentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / (1024 * 1024)
    }
}

// MARK: - Private accumulators

private actor EventCollector {
    private var events: [BargeInEvent] = []
    func add(_ event: BargeInEvent) { events.append(event) }
    func all() -> [BargeInEvent] { events }
}
