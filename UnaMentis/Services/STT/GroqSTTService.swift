// UnaMentis - Groq STT Service
// Speech-to-Text service using Groq's Whisper API
//
// Free tier: 14,400 requests/day
// Endpoint: https://api.groq.com/openai/v1/audio/transcriptions
//
// Part of Services/STT

import Foundation
import Logging
import AVFoundation

/// Groq Whisper STT service for cloud-based speech recognition
///
/// Uses Groq's ultra-fast Whisper implementation with:
/// - Up to 300x real-time speed
/// - Word-level timestamps
/// - Multiple model options (whisper-large-v3, whisper-large-v3-turbo)
public actor GroqSTTService: STTService {

    // MARK: - Properties

    private let logger = Logger(label: "com.unamentis.stt.groq")
    private let apiKey: String
    private let language: String
    private let model: String

    private static let baseURL = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

    /// Performance metrics
    public private(set) var metrics: STTMetrics = STTMetrics(
        medianLatency: 0.15,  // Groq is typically very fast
        p99Latency: 0.5,
        wordEmissionRate: 150
    )

    public var costPerHour: Decimal { 0 }  // Free tier
    public private(set) var isStreaming: Bool = false

    private var audioBuffer: Data = Data()
    private var continuation: AsyncStream<STTResult>.Continuation?
    private var streamStartTime: Date?
    private var latencyValues: [TimeInterval] = []

    // Audio batching settings
    private let minBatchSizeBytes = 32000  // ~1 second at 16kHz mono 16-bit
    private let maxBatchSizeBytes = 320000 // ~10 seconds

    // MARK: - Initialization

    /// Initialize with explicit configuration
    /// - Parameters:
    ///   - apiKey: Groq API key
    ///   - language: Language code (e.g., "en")
    ///   - model: Whisper model to use (default: whisper-large-v3-turbo for speed)
    public init(apiKey: String, language: String = "en", model: String = "whisper-large-v3-turbo") {
        self.apiKey = apiKey
        self.language = language
        self.model = model
        logger.info("GroqSTTService initialized with model: \(model)")
    }

    // MARK: - STTService Protocol

    public func startStreaming(audioFormat: sending AVAudioFormat) async throws -> AsyncStream<STTResult> {
        guard !isStreaming else {
            throw STTError.alreadyStreaming
        }

        isStreaming = true
        audioBuffer = Data()
        streamStartTime = Date()

        logger.debug("Started streaming transcription")

        return AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    public func sendAudio(_ buffer: sending AVAudioPCMBuffer) async throws {
        guard isStreaming else {
            throw STTError.notStreaming
        }

        // Convert buffer to raw PCM data (not WAV, we'll add header when sending)
        if let pcmData = extractPCMData(from: buffer) {
            audioBuffer.append(pcmData)
        }

        // Groq doesn't support true streaming, so we batch audio
        // Transcribe when we have enough audio (~1 second minimum)
        if audioBuffer.count >= minBatchSizeBytes {
            await transcribeBuffer()
        }
    }

    public func stopStreaming() async throws {
        guard isStreaming else {
            throw STTError.notStreaming
        }

        // Transcribe any remaining audio
        if !audioBuffer.isEmpty {
            await transcribeBuffer(isFinal: true)
        }

        continuation?.finish()
        continuation = nil
        isStreaming = false
        audioBuffer = Data()

        logger.debug("Stopped streaming transcription")
    }

    public func cancelStreaming() async {
        continuation?.finish()
        continuation = nil
        isStreaming = false
        audioBuffer = Data()

        logger.debug("Cancelled streaming transcription")
    }

    // MARK: - Private Methods

    private func transcribeBuffer(isFinal: Bool = false) async {
        guard !audioBuffer.isEmpty else { return }

        // Create WAV data from accumulated PCM
        let pcmData = audioBuffer
        audioBuffer = Data()  // Clear for next batch

        let wavData = createWAVData(from: pcmData)
        let startTime = Date()

        do {
            let result = try await transcribe(audioData: wavData)
            let latency = Date().timeIntervalSince(startTime)

            // Update metrics
            latencyValues.append(latency)
            updateMetrics()

            // Convert to STTResult
            let sttResult = STTResult(
                transcript: result.text,
                isFinal: isFinal,
                isEndOfUtterance: isFinal,
                confidence: 0.95,  // Groq doesn't return confidence
                timestamp: Date().timeIntervalSince1970,
                latency: latency,
                wordTimestamps: result.words.map { word in
                    WordTimestamp(
                        word: word.word,
                        startTime: word.startTime,
                        endTime: word.endTime,
                        confidence: word.confidence
                    )
                }
            )

            continuation?.yield(sttResult)

            logger.debug("Transcription complete: \"\(result.text.prefix(50))...\" (latency: \(String(format: "%.3f", latency))s)")

        } catch {
            logger.error("Transcription failed: \(error.localizedDescription)")
            // Don't throw, just log and continue - the stream should stay open
        }
    }

    private func transcribe(audioData: Data) async throws -> TranscriptionResult {
        let boundary = UUID().uuidString
        var request = URLRequest(url: Self.baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        // Build multipart body
        var body = Data()

        // Add audio file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        // Add model
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)

        // Add language
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(language)\r\n".data(using: .utf8)!)

        // Add response format for word timestamps
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("verbose_json\r\n".data(using: .utf8)!)

        // Add timestamp granularities for word-level timestamps
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"timestamp_granularities[]\"\r\n\r\n".data(using: .utf8)!)
        body.append("word\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw STTError.connectionFailed("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw STTError.authenticationFailed
        case 429:
            throw STTError.rateLimited
        default:
            // Try to parse error message from response
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw STTError.connectionFailed("HTTP \(httpResponse.statusCode): \(message)")
            }
            throw STTError.connectionFailed("HTTP \(httpResponse.statusCode)")
        }

        // Parse response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw STTError.connectionFailed("Invalid JSON response")
        }

        let text = json["text"] as? String ?? ""
        let duration = json["duration"] as? Double ?? 0

        // Parse word timestamps
        var words: [TranscribedWord] = []
        if let wordsArray = json["words"] as? [[String: Any]] {
            for wordInfo in wordsArray {
                if let word = wordInfo["word"] as? String,
                   let start = wordInfo["start"] as? Double,
                   let end = wordInfo["end"] as? Double {
                    words.append(TranscribedWord(
                        word: word.trimmingCharacters(in: .whitespaces),
                        startTime: start,
                        endTime: end,
                        confidence: 0.95
                    ))
                }
            }
        }

        return TranscriptionResult(
            text: text,
            words: words,
            language: json["language"] as? String ?? language,
            duration: duration,
            isFinal: true
        )
    }

    // MARK: - Audio Conversion

    /// Extract raw PCM Int16 data from an AVAudioPCMBuffer
    private func extractPCMData(from buffer: AVAudioPCMBuffer) -> Data? {
        // Try Int16 format first (most common for speech)
        if let channelData = buffer.int16ChannelData {
            let frameCount = Int(buffer.frameLength)
            let ptr = channelData[0]
            return Data(bytes: ptr, count: frameCount * 2)  // 2 bytes per Int16 sample
        }

        // Fall back to Float32 and convert
        if let floatData = buffer.floatChannelData {
            let frameCount = Int(buffer.frameLength)
            let ptr = floatData[0]

            var int16Data = Data(capacity: frameCount * 2)
            for i in 0..<frameCount {
                let sample = ptr[i]
                // Clamp and convert to Int16
                let clamped = max(-1.0, min(1.0, sample))
                let int16Value = Int16(clamped * Float(Int16.max))
                withUnsafeBytes(of: int16Value.littleEndian) { bytes in
                    int16Data.append(contentsOf: bytes)
                }
            }
            return int16Data
        }

        return nil
    }

    /// Create WAV file data from raw PCM Int16 data
    /// Assumes 16kHz mono 16-bit PCM
    private func createWAVData(from pcmData: Data) -> Data {
        let sampleRate: UInt32 = 16000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = bitsPerSample / 8
        let blockAlign = channels * bytesPerSample
        let byteRate = sampleRate * UInt32(blockAlign)

        let dataSize = UInt32(pcmData.count)
        let fileSize = dataSize + 36  // 44 byte header - 8 byte RIFF header

        var wavData = Data()

        // RIFF header
        wavData.append("RIFF".data(using: .ascii)!)
        wavData.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        wavData.append("WAVE".data(using: .ascii)!)

        // fmt subchunk
        wavData.append("fmt ".data(using: .ascii)!)
        wavData.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })  // Subchunk size
        wavData.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })   // Audio format (1 = PCM)
        wavData.append(withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })

        // data subchunk
        wavData.append("data".data(using: .ascii)!)
        wavData.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        wavData.append(pcmData)

        return wavData
    }

    private func updateMetrics() {
        guard !latencyValues.isEmpty else { return }

        // Calculate median
        let sorted = latencyValues.sorted()
        let median = sorted[sorted.count / 2]

        // Calculate P99
        let p99Index = min(sorted.count - 1, Int(Double(sorted.count) * 0.99))
        let p99 = sorted[p99Index]

        metrics = STTMetrics(
            medianLatency: median,
            p99Latency: p99,
            wordEmissionRate: 150  // Estimated
        )
    }
}

// MARK: - Factory Methods

extension GroqSTTService {

    /// Create service with API key from keychain
    public static func fromKeychain(language: String = "en") async -> GroqSTTService? {
        guard let apiKey = await APIKeyManager.shared.getKey(.groq) else {
            return nil
        }
        return GroqSTTService(apiKey: apiKey, language: language)
    }

    /// Create service for testing connectivity
    public static func forTesting(apiKey: String) -> GroqSTTService {
        GroqSTTService(apiKey: apiKey, language: "en", model: "whisper-large-v3-turbo")
    }
}
