// UnaMentis - Google Gemini LLM Service
// Streaming LLM using Google Gemini (generativelanguage API)
//
// Part of Provider Implementations. Conforms to the shared LLMService
// protocol, so it flows through the same SessionManager and audio pipeline
// as every other provider. No parallel path.

import Foundation
import Logging

/// Google Gemini streaming LLM implementation.
///
/// Uses the generativelanguage streamGenerateContent endpoint with SSE.
/// Gemini differs from OpenAI/Anthropic in three ways handled here:
/// - roles are "user" and "model" (assistant maps to "model")
/// - the system prompt goes in a separate systemInstruction field
/// - the API key is a query parameter, not a header
public actor GoogleLLMService: LLMService {

    // MARK: - Properties

    private let logger = Logger(label: "com.unamentis.llm.google")
    private let apiKey: String
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    /// URLSession used for requests. Defaults to `.shared`; injectable so tests can
    /// drive the real request building and SSE parsing through a URLProtocol seam.
    private let session: URLSession

    /// Default model when config does not specify one.
    private var currentModel: String = "gemini-2.5-flash"

    public private(set) var metrics = LLMMetrics(
        medianTTFT: 0.3,
        p99TTFT: 0.6,
        totalInputTokens: 0,
        totalOutputTokens: 0
    )

    private var ttftValues: [TimeInterval] = []
    private var totalInputTokensCount: Int = 0
    private var totalOutputTokensCount: Int = 0

    /// Gemini 2.5 Flash pricing (approximate, text): input ~$0.30/1M, output ~$2.50/1M.
    /// Pro-class models cost more; this is a cost-tracking estimate like the other providers.
    public var costPerInputToken: Decimal {
        currentModel.contains("pro") ? Decimal(1.25) / 1_000_000 : Decimal(0.30) / 1_000_000
    }

    public var costPerOutputToken: Decimal {
        currentModel.contains("pro") ? Decimal(10.0) / 1_000_000 : Decimal(2.50) / 1_000_000
    }

    // MARK: - Initialization

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
        logger.info("GoogleLLMService initialized")
    }

    // MARK: - LLMService Protocol

    public func streamCompletion(
        messages: [LLMMessage],
        config: LLMConfig
    ) async throws -> AsyncStream<LLMToken> {
        currentModel = config.model.isEmpty ? currentModel : config.model
        let model = currentModel
        logger.info("Starting Gemini stream with model: \(model)")

        // Build contents (Gemini roles: user / model; system goes in systemInstruction)
        var contents: [[String: Any]] = []
        for message in messages where message.role != .system {
            let role = message.role == .user ? "user" : "model"
            contents.append([
                "role": role,
                "parts": [["text": message.content]]
            ])
        }

        let systemText = config.systemPrompt
            ?? messages.first(where: { $0.role == .system })?.content

        var generationConfig: [String: Any] = [
            "temperature": config.temperature,
            "maxOutputTokens": config.maxTokens
        ]
        if let topP = config.topP {
            generationConfig["topP"] = topP
        }
        if let stops = config.stopSequences, !stops.isEmpty {
            generationConfig["stopSequences"] = stops
        }

        var body: [String: Any] = [
            "contents": contents,
            "generationConfig": generationConfig
        ]
        if let systemText, !systemText.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemText]]]
        }

        // API key is a query parameter; alt=sse gives line-delimited SSE.
        guard let url = URL(string: "\(baseURL)/\(model):streamGenerateContent?alt=sse&key=\(apiKey)") else {
            throw LLMError.connectionFailed("Invalid Gemini URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let inputChars = contents.reduce(0) { acc, c in
            acc + (((c["parts"] as? [[String: String]])?.first?["text"]?.count) ?? 0)
        } + (systemText?.count ?? 0)
        totalInputTokensCount += inputChars / 4

        return AsyncStream { continuation in
            Task {
                do {
                    let startTime = Date()
                    let (bytes, response) = try await self.session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw LLMError.connectionFailed("Invalid response")
                    }
                    if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                        throw LLMError.authenticationFailed
                    }
                    if httpResponse.statusCode == 429 {
                        let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) }
                        throw LLMError.rateLimited(retryAfter: retryAfter)
                    }
                    guard httpResponse.statusCode == 200 else {
                        throw LLMError.connectionFailed("HTTP \(httpResponse.statusCode)")
                    }

                    var isFirst = true
                    var outputTokens = 0

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        if jsonStr == "[DONE]" { break }

                        guard let data = jsonStr.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let candidates = json["candidates"] as? [[String: Any]],
                              let first = candidates.first else {
                            continue
                        }

                        if let content = first["content"] as? [String: Any],
                           let parts = content["parts"] as? [[String: Any]] {
                            let text = parts.compactMap { $0["text"] as? String }.joined()
                            if !text.isEmpty {
                                if isFirst {
                                    self.ttftValues.append(Date().timeIntervalSince(startTime))
                                    isFirst = false
                                }
                                outputTokens += 1
                                continuation.yield(LLMToken(content: text, isDone: false))
                            }
                        }

                        if let finish = first["finishReason"] as? String, finish != "FINISH_REASON_UNSPECIFIED" {
                            let stop: StopReason = finish == "MAX_TOKENS" ? .maxTokens : .endTurn
                            continuation.yield(LLMToken(content: "", isDone: true, stopReason: stop, tokenCount: outputTokens))
                            self.totalOutputTokensCount += outputTokens
                            await self.updateMetrics()
                            continuation.finish()
                            return
                        }
                    }

                    continuation.yield(LLMToken(content: "", isDone: true, stopReason: .endTurn, tokenCount: outputTokens))
                    self.totalOutputTokensCount += outputTokens
                    await self.updateMetrics()
                    continuation.finish()
                } catch {
                    self.logger.error("Gemini stream failed: \(error.localizedDescription)")
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Private

    private func updateMetrics() {
        let sorted = ttftValues.sorted()
        let medianIndex = sorted.count / 2
        let p99Index = Int(Double(sorted.count) * 0.99)
        metrics = LLMMetrics(
            medianTTFT: sorted.isEmpty ? 0.3 : sorted[medianIndex],
            p99TTFT: sorted.isEmpty ? 0.6 : sorted[Swift.min(p99Index, Swift.max(0, sorted.count - 1))],
            totalInputTokens: totalInputTokensCount,
            totalOutputTokens: totalOutputTokensCount
        )
    }
}
