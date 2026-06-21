// UnaMentis - Fallback LLM Service
// Runtime resilience wrapper for the LLM tier chain.
//
// Part of Provider Implementations.

import Foundation
import Logging

/// One tier in the fallback chain: a label plus a factory that builds the
/// service on demand (so a tier that cannot even be constructed, for example a
/// model that is not downloaded or a key that is missing, simply gets skipped).
public struct LLMFallbackTier: Sendable {
    public let label: String
    /// Model id valid for this tier's provider. When set, it overrides the
    /// config model for this tier only, so a fallback to a different provider
    /// never sends a model string meant for another one.
    public let model: String?
    public let make: @Sendable () async throws -> any LLMService

    public init(
        label: String,
        model: String? = nil,
        make: @escaping @Sendable () async throws -> any LLMService
    ) {
        self.label = label
        self.model = model
        self.make = make
    }
}

/// Wraps an ordered chain of LLM providers and degrades automatically so a beta
/// user is never left stranded and the app never crashes.
///
/// It conforms to LLMService itself, so the session sees ONE service and the
/// single voice/barge-in pipeline is preserved; the resilience lives underneath.
///
/// Fallback rule (safe, no garbled output): nothing is relayed to the caller
/// until a tier produces its first real content token. A tier is considered
/// failed, and the next one is tried, if it cannot be constructed, its
/// streamCompletion throws, or its stream finishes without ever producing
/// content (the shape that load failures, auth failures, and dropped
/// connections take, since the provider streams finish rather than throw).
/// Once a tier produces content it is committed to; a mid-stream drop yields a
/// partial answer rather than a crash. If every tier fails, a calm message is
/// emitted instead of an error dead-end.
public actor FallbackLLMService: LLMService {

    private let tiers: [LLMFallbackTier]
    private let logger = Logger(label: "com.unamentis.llm.fallback")

    /// Message shown when no tier can produce a response. Never a silent failure.
    private let allFailedMessage =
        "I'm having trouble reaching a language model right now. "
        + "Please check your connection, or pick a different model in Settings."

    public private(set) var metrics = LLMMetrics(
        medianTTFT: 0.3,
        p99TTFT: 0.8,
        totalInputTokens: 0,
        totalOutputTokens: 0
    )

    // The wrapper does not bill; the underlying providers track their own cost.
    public var costPerInputToken: Decimal { 0 }
    public var costPerOutputToken: Decimal { 0 }

    public init(tiers: [LLMFallbackTier]) {
        self.tiers = tiers
    }

    public func streamCompletion(
        messages: [LLMMessage],
        config: LLMConfig
    ) async throws -> AsyncStream<LLMToken> {
        let tiers = self.tiers
        let logger = self.logger
        let allFailedMessage = self.allFailedMessage

        return AsyncStream { outer in
            Task {
                for tier in tiers {
                    let service: any LLMService
                    do {
                        service = try await tier.make()
                    } catch {
                        logger.warning("Tier '\(tier.label)' could not be created: \(error.localizedDescription); trying next")
                        continue
                    }

                    var tierConfig = config
                    if let tierModel = tier.model { tierConfig.model = tierModel }

                    let inner: AsyncStream<LLMToken>
                    do {
                        inner = try await service.streamCompletion(messages: messages, config: tierConfig)
                    } catch {
                        logger.warning("Tier '\(tier.label)' failed to start: \(error.localizedDescription); trying next")
                        continue
                    }

                    var sawContent = false
                    for await token in inner {
                        if !token.content.isEmpty { sawContent = true }
                        // Relay only once content has begun, so a failed tier
                        // never leaks tokens before we commit to it.
                        if sawContent { outer.yield(token) }
                    }

                    if sawContent {
                        logger.info("Tier '\(tier.label)' served the response")
                        outer.finish()
                        return
                    }
                    logger.warning("Tier '\(tier.label)' produced no output; trying next")
                }

                logger.error("All LLM tiers failed; emitting graceful fallback message")
                outer.yield(LLMToken(content: allFailedMessage, isDone: false))
                outer.yield(LLMToken(content: "", isDone: true, stopReason: .endTurn))
                outer.finish()
            }
        }
    }
}
