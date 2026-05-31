//
//  KBOnDeviceSTT.swift
//  UnaMentis
//
//  On-device speech-to-text adapter for Knowledge Bowl oral rounds.
//  Captures audio through the unified AudioEngine and transcribes via the
//  shared AppleSpeechSTTService provider. It owns no audio engine or input tap
//  of its own; capture flows through the single voice pipeline.
//

@preconcurrency import AVFoundation
import Combine
import Logging
import Speech

// MARK: - On-Device STT Adapter

/// Provides offline speech recognition for Knowledge Bowl by driving the shared
/// AppleSpeechSTTService with audio from the unified AudioEngine. Conforms to
/// STTService for integration with the provider abstraction layer.
public actor KBOnDeviceSTT: STTService {
    // MARK: - STTService Protocol Requirements

    public private(set) var metrics = STTMetrics(
        medianLatency: 0.15,  // Apple Speech is typically very fast
        p99Latency: 0.3,
        wordEmissionRate: 0
    )

    public var costPerHour: Decimal { Decimal(0) }  // On-device = free

    public private(set) var isStreaming: Bool = false

    // MARK: - Private State

    private let logger = Logger(label: "com.unamentis.kb.stt")
    private var provider: AppleSpeechSTTService?
    private var engine: AudioEngine?
    private var audioSubscription: AnyCancellable?
    private var relayTask: Task<Void, Never>?
    private var resultContinuation: AsyncStream<STTResult>.Continuation?

    // MARK: - Initialization

    public init() {
        logger.info("KBOnDeviceSTT initialized (unified pipeline adapter)")
    }

    // MARK: - Authorization

    /// Request speech recognition authorization.
    public static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await AppleSpeechSTTService.requestAuthorization()
    }

    /// Whether speech recognition is available on this device.
    public static var isAvailable: Bool {
        AppleSpeechSTTService.isAvailable
    }

    // MARK: - STTService Protocol

    public func startStreaming(audioFormat: sending AVAudioFormat) async throws -> AsyncStream<STTResult> {
        guard !isStreaming else {
            throw STTError.alreadyStreaming
        }

        // Acquire the shared, warm audio engine: a single capture pipeline.
        guard let engine = await AudioEngineCache.shared.getEngine() else {
            throw STTError.connectionFailed("Audio engine unavailable")
        }
        self.engine = engine

        // Use the engine's real input format. The passed-in format is a placeholder
        // because, unlike a raw capture path, this adapter does not own the input node.
        guard let format = await engine.format else {
            throw STTError.invalidAudioFormat
        }
        guard let formatCopy = AVAudioFormat(
            commonFormat: format.commonFormat,
            sampleRate: format.sampleRate,
            channels: format.channelCount,
            interleaved: format.isInterleaved
        ) else {
            throw STTError.invalidAudioFormat
        }

        let provider = AppleSpeechSTTService()
        self.provider = provider
        let providerStream = try await provider.startStreaming(audioFormat: formatCopy)
        isStreaming = true

        // Relay the provider's results to the caller.
        let (stream, continuation) = AsyncStream<STTResult>.makeStream()
        self.resultContinuation = continuation

        relayTask = Task { [weak self] in
            for await result in providerStream {
                continuation.yield(result)
                if result.isFinal {
                    continuation.finish()
                    break
                }
            }
            _ = self
        }

        // Feed unified-engine audio buffers into the provider (mirrors SessionManager).
        audioSubscription = engine.audioStream
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (buffer, _) in
                guard let self = self else { return }
                Task.detached {
                    await self.feed(buffer)
                }
            }

        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.cleanup() }
        }

        logger.info("KBOnDeviceSTT streaming started via unified engine")
        return stream
    }

    public func sendAudio(_ buffer: sending AVAudioPCMBuffer) async throws {
        guard isStreaming else {
            throw STTError.notStreaming
        }
        try await provider?.sendAudio(buffer)
    }

    public func stopStreaming() async throws {
        guard isStreaming else { return }
        logger.info("Stopping KBOnDeviceSTT stream")
        try? await provider?.stopStreaming()
        await cleanup()
    }

    public func cancelStreaming() async {
        logger.info("Cancelling KBOnDeviceSTT stream")
        await provider?.cancelStreaming()
        await cleanup()
    }

    // MARK: - Private Helpers

    private func feed(_ buffer: AVAudioPCMBuffer) async {
        guard isStreaming else { return }
        do {
            try await provider?.sendAudio(buffer)
        } catch {
            logger.error("Failed to send audio to STT: \(error.localizedDescription)")
        }
    }

    private func cleanup() async {
        audioSubscription?.cancel()
        audioSubscription = nil
        relayTask?.cancel()
        relayTask = nil
        resultContinuation?.finish()
        resultContinuation = nil
        provider = nil
        engine = nil
        isStreaming = false

        // Let the shared engine stay warm briefly, then release if unused.
        await AudioEngineCache.shared.scheduleRelease()
        logger.debug("KBOnDeviceSTT cleanup complete")
    }
}

// MARK: - Preview Support

#if DEBUG
extension KBOnDeviceSTT {
    /// Create an STT instance for previews.
    static func preview() -> KBOnDeviceSTT {
        KBOnDeviceSTT()
    }
}
#endif
