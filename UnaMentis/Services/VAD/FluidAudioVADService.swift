// UnaMentis - FluidAudio Silero VAD Service
//
// Real on-device neural Voice Activity Detection using FluidAudio's Silero v5
// CoreML model (Apple Neural Engine). This replaces SileroVADService, whose
// silero_vad.mlmodelc was never bundled, so it always degraded to a dB-energy
// RMS fallback. FluidAudio downloads and loads the real model on first use, the
// same package already used for on-device STT (Parakeet EOU).
//
// FluidAudio's VAD operates on 4096-sample chunks at 16 kHz (~256 ms). The audio
// engine delivers smaller buffers, so this service resamples each buffer to
// 16 kHz mono and accumulates samples until a full chunk is available, then runs
// the model and threads its recurrent state across chunks (Silero is stateful).
// Between chunk evaluations it returns the most recent probability so the VAD
// signal stays continuous for the barge-in detector.

#if canImport(FluidAudio)

@preconcurrency import AVFoundation
import FluidAudio
import Logging

public actor FluidAudioVADService: VADService {

    // MARK: - Properties

    private let logger = Logger(label: "com.unamentis.vad.fluidaudio")

    public private(set) var configuration: VADConfiguration
    public private(set) var isActive: Bool = false

    private var manager: VadManager?
    private var streamState: VadStreamState?

    /// FluidAudio's Silero v5 model consumes 4096-sample chunks at 16 kHz.
    private let chunkSize = 4096
    private let targetSampleRate: Double = 16000

    /// Accumulates resampled 16 kHz mono samples until a full chunk is ready.
    private var sampleBuffer: [Float] = []
    /// Most recent model probability, held between chunk evaluations.
    private var lastProbability: Float = 0

    /// Cached resampler for non-16 kHz input.
    private var resampleConverter: AVAudioConverter?
    private var lastInputFormat: AVAudioFormat?

    // MARK: - Initialization

    public init(configuration: VADConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: - VADService

    public func configure(threshold: Float, contextWindow: Int) async {
        configuration = VADConfiguration(
            threshold: threshold,
            contextWindow: contextWindow,
            smoothingWindow: configuration.smoothingWindow,
            minSpeechDuration: configuration.minSpeechDuration,
            minSilenceDuration: configuration.minSilenceDuration
        )
    }

    public func configure(_ configuration: VADConfiguration) async {
        self.configuration = configuration
    }

    public func prepare() async throws {
        logger.info("Preparing FluidAudio Silero VAD...")
        let mgr = try await VadManager(config: .default)
        manager = mgr
        streamState = await mgr.makeStreamState()
        sampleBuffer.removeAll(keepingCapacity: true)
        lastProbability = 0
        isActive = true
        logger.info("FluidAudio Silero VAD ready (real Neural Engine model)")
    }

    public func processBuffer(_ buffer: AVAudioPCMBuffer) async -> VADResult {
        let startTime = Date()
        guard isActive, let manager, let state = streamState else {
            return VADResult(isSpeech: false, confidence: 0, timestamp: startTime.timeIntervalSince1970)
        }

        sampleBuffer.append(contentsOf: resampleTo16k(buffer))

        var nextState = state
        while sampleBuffer.count >= chunkSize {
            let chunk = Array(sampleBuffer.prefix(chunkSize))
            sampleBuffer.removeFirst(chunkSize)
            do {
                let result = try await manager.processStreamingChunk(chunk, state: nextState)
                nextState = result.state
                lastProbability = result.probability
            } catch {
                logger.error("FluidAudio VAD chunk failed: \(error.localizedDescription)")
            }
        }
        streamState = nextState

        let isSpeech = lastProbability >= configuration.threshold
        return VADResult(
            isSpeech: isSpeech,
            confidence: lastProbability,
            timestamp: startTime.timeIntervalSince1970,
            segmentDuration: Double(buffer.frameLength) / max(buffer.format.sampleRate, 1)
        )
    }

    public func reset() async {
        sampleBuffer.removeAll(keepingCapacity: true)
        lastProbability = 0
        if let manager {
            streamState = await manager.makeStreamState()
        }
    }

    public func shutdown() async {
        isActive = false
        manager = nil
        streamState = nil
        sampleBuffer.removeAll()
        resampleConverter = nil
        lastInputFormat = nil
    }

    // MARK: - Resampling

    /// Resample an audio buffer to 16 kHz mono Float samples for the VAD model.
    private func resampleTo16k(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if buffer.format.sampleRate == targetSampleRate,
           buffer.format.channelCount == 1,
           let data = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            return []
        }

        if resampleConverter == nil || lastInputFormat != buffer.format {
            resampleConverter = AVAudioConverter(from: buffer.format, to: outputFormat)
            lastInputFormat = buffer.format
        }
        guard let converter = resampleConverter else { return [] }

        let ratio = targetSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return []
        }

        var consumed = false
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if error != nil { return [] }

        guard let data = outputBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(outputBuffer.frameLength)))
    }
}

#endif
