// UnaMentis - FluidAudio On-Device Streaming STT
// ===============================================
//
// Streaming speech-to-text on the Apple Neural Engine via FluidAudio's Parakeet
// realtime EOU model (CoreML). This is the on-device-first, never-Apple-Speech
// recognizer the audio architecture needs: it emits partial hypotheses and a
// native end-of-utterance signal, which is exactly what barge-in + the shared
// BargeInResponder consume.
//
// Gated on `#if canImport(FluidAudio)` so the app builds with or without the
// package. To enable, add the FluidAudio SPM package (see project.yml) on a
// machine where SPM can resolve new packages, then `xcodegen generate`. Models
// auto-download from HuggingFace on first use (nothing is fetched at build time).
//
// The wrapper maps FluidAudio's StreamingEouAsrManager onto our STTService:
//   startStreaming -> create manager, loadModels(), wire partial + EOU callbacks
//   sendAudio      -> process(audioBuffer:) (drives chunked decode + partials)
//   stopStreaming  -> finish() (final transcript)
//
// API confirmed against FluidAudio v0.14.8 source
// (Sources/FluidAudio/ASR/Parakeet/Streaming/EOU/StreamingEouAsrManager.swift):
//   - actor StreamingEouAsrManager(chunkSize:eouDebounceMs:debugFeatures:)
//   - func loadModels(to:configuration:progressHandler:) async throws   // auto-download
//   - func setPartialCallback(_: @Sendable (String) -> Void)
//   - func setEouCallback(_: @Sendable (String) -> Void)
//   - func process(audioBuffer: AVAudioPCMBuffer) async throws -> String
//   - func finish() async throws -> String

import AVFoundation
import Foundation

#if canImport(FluidAudio)
import FluidAudio

public actor FluidAudioSTTService: STTService {

    public private(set) var metrics = STTMetrics(medianLatency: 0, p99Latency: 0, wordEmissionRate: 0)
    /// On-device: no per-hour cloud cost.
    public nonisolated let costPerHour: Decimal = 0
    public private(set) var isStreaming = false

    private var manager: StreamingEouAsrManager?
    private var continuation: AsyncStream<STTResult>.Continuation?
    private var streamStart: TimeInterval = 0

    /// Streaming chunk size. 160ms is the lowest-latency option (best for barge-in).
    private let chunkSize: StreamingChunkSize
    private let eouDebounceMs: Int

    public init(chunkSize: StreamingChunkSize = .ms160, eouDebounceMs: Int = 1280) {
        self.chunkSize = chunkSize
        self.eouDebounceMs = eouDebounceMs
    }

    public func startStreaming(audioFormat: sending AVAudioFormat) async throws -> AsyncStream<STTResult> {
        guard !isStreaming else { throw STTError.alreadyStreaming }

        let mgr = StreamingEouAsrManager(chunkSize: chunkSize, eouDebounceMs: eouDebounceMs)
        try await mgr.loadModels()   // downloads + loads Parakeet EOU on first use
        manager = mgr
        streamStart = Date().timeIntervalSince1970
        isStreaming = true

        let (stream, cont) = AsyncStream<STTResult>.makeStream()
        continuation = cont
        let start = streamStart

        await mgr.setPartialCallback { partial in
            cont.yield(STTResult(
                transcript: partial, isFinal: false, isEndOfUtterance: false,
                confidence: 1.0, latency: Date().timeIntervalSince1970 - start))
        }
        await mgr.setEouCallback { transcript in
            cont.yield(STTResult(
                transcript: transcript, isFinal: false, isEndOfUtterance: true,
                confidence: 1.0, latency: Date().timeIntervalSince1970 - start))
        }
        return stream
    }

    public func sendAudio(_ buffer: sending AVAudioPCMBuffer) async throws {
        guard let mgr = manager else { throw STTError.notStreaming }
        // Drives chunked decode; partial hypotheses arrive via the partial callback.
        _ = try await mgr.process(audioBuffer: buffer)
    }

    public func stopStreaming() async throws {
        guard let mgr = manager else { return }
        let final = try await mgr.finish()
        continuation?.yield(STTResult(
            transcript: final, isFinal: true, isEndOfUtterance: true,
            confidence: 1.0, latency: Date().timeIntervalSince1970 - streamStart))
        continuation?.finish()
        reset()
    }

    public func cancelStreaming() async {
        continuation?.finish()
        reset()
    }

    private func reset() {
        isStreaming = false
        manager = nil
        continuation = nil
    }
}
#endif
