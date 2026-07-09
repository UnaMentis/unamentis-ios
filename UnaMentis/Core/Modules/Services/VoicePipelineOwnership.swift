// UnaMentis - Voice Pipeline Ownership
// The single arbiter for exclusive voice pipeline access.
//
// The app has ONE voice pipeline (the unified-voice-pipeline mandate). This
// actor is the mechanism that keeps it exclusive: a core tutoring session and
// a module voice session may never capture or play concurrently. Core
// sessions claim `.coreSession` in SessionManager.startSession and release in
// stopSession; module sessions claim `.module` through
// UnifiedVoiceSessionService.acquire and release via VoiceSession.release.
//
// Claiming while another holder is active throws
// VoiceSessionError.pipelineBusy, so conflicts surface as typed errors at the
// acquisition point instead of as two audio stacks fighting over the mic.

import Foundation

// MARK: - Holder

/// Who currently holds the exclusive voice pipeline.
public enum VoicePipelineHolder: Equatable, Sendable, CustomStringConvertible {
    /// The core tutoring session (SessionManager).
    case coreSession
    /// A module voice session, identified per acquisition.
    case module(sessionID: UUID)

    public var description: String {
        switch self {
        case .coreSession:
            return "the core session"
        case .module:
            return "a module voice session"
        }
    }
}

// MARK: - Ownership Actor

/// Serializes claim/release of the single voice pipeline.
///
/// Claims are idempotent per holder; releases only clear the pipeline when
/// the releasing holder actually owns it, so a stale release can never free
/// someone else's claim.
public actor VoicePipelineOwnership {
    /// The app-wide arbiter. Tests construct their own instances.
    public static let shared = VoicePipelineOwnership()

    /// The current holder, or nil when the pipeline is free.
    public private(set) var holder: VoicePipelineHolder?

    public init() {}

    /// Claim the pipeline for `requester`.
    /// - Throws: `VoiceSessionError.pipelineBusy` when a different holder owns it.
    public func claim(_ requester: VoicePipelineHolder) throws {
        if let holder, holder != requester {
            throw VoiceSessionError.pipelineBusy(holder: holder.description)
        }
        holder = requester
    }

    /// Release the pipeline if (and only if) `owner` holds it.
    public func release(_ owner: VoicePipelineHolder) {
        if holder == owner {
            holder = nil
        }
    }
}
