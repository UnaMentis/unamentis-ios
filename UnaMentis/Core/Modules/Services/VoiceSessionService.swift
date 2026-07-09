// UnaMentis - VoiceSession Host Service Contract
// MODULE_SDK_SPEC.md section 5.1, capability "voice.session/1"
//
// The single voice pipeline, exposed to modules as a host service. Modules
// never instantiate STT, TTS, VAD, or audio engines; they acquire a
// VoiceSession from the host, speak and listen through it, and release it.
//
// The production implementation (UnifiedVoiceSessionService) composes the
// app's existing unified pipeline: AudioEngine, AudioPlaybackOrchestrator,
// the canonical BargeInDetector, and the shared on-device STT/TTS providers.
// This file is the contract only; it has no audio dependencies of its own
// beyond the shared value types it reuses (VADResult, BargeInEvent,
// CachedSegmentAudio, VoiceCommand).

import Foundation

// MARK: - Service Protocol

/// The host-side factory for module voice sessions.
///
/// Acquisition is exclusive: the host arbitrates against core sessions and
/// other module sessions via `VoicePipelineOwnership`. Acquiring while the
/// pipeline is held throws `VoiceSessionError.pipelineBusy`.
public protocol VoiceSessionService: Sendable {
    /// Exclusively acquire the voice pipeline configured for this module
    /// session. Throws `VoiceSessionError.pipelineBusy` if a core session or
    /// another module session currently holds the pipeline.
    func acquire(config: VoicePipelineConfig) async throws -> any VoiceSession
}

// MARK: - Session Protocol

/// An exclusively held module voice session on the unified pipeline.
///
/// All methods are safe to call from any actor. `listen` supports Swift task
/// cancellation: cancelling the awaiting task stops capture and throws
/// `CancellationError`.
public protocol VoiceSession: AnyObject, Sendable {
    /// Voice events (barge-in, buzz, command recognition, VAD state, partial
    /// transcripts). Single consumer per session.
    var events: AsyncStream<VoiceEvent> { get }

    /// Speak one utterance and return when playback completes. Pre-rendered
    /// audio (server-pregenerated or previously cached) plays with zero
    /// synthesis latency; text is synthesized by the host's configured TTS.
    /// Synthesis failures are surfaced as thrown errors, never silence.
    func speak(_ utterance: Utterance) async throws

    /// Stop any in-progress `speak` immediately (e.g. a "skip" command).
    func stopSpeaking() async

    /// Warm the local synthesis cache for upcoming utterances (best effort).
    func prefetch(_ utterances: [Utterance]) async

    /// Capture one utterance from the learner and return its transcript.
    /// Endpointing follows the acquired `VoicePipelineConfig` (silence
    /// threshold, max utterance duration, answer timeout). Partial transcripts
    /// stream through `events` while listening.
    func listen(expecting expectation: ListenExpectation) async throws -> UtteranceResult

    /// Extend the unified command vocabulary for a module voice state.
    /// Recognition and confidence thresholds are host concerns; matches are
    /// delivered as `VoiceEvent.commandRecognized`.
    func registerCommands(_ vocabulary: CommandVocabulary, for state: ModuleVoiceState) async

    /// Tell the host which module voice state is active, so state-scoped
    /// command vocabularies apply. (Not in the spec draft; see RFC notes.)
    func setActiveVoiceState(_ state: ModuleVoiceState) async

    /// Play a short audio cue (earcon) with haptic, e.g. correct/incorrect.
    func playCue(_ cue: AudioCue) async

    /// Release the pipeline. The session is unusable afterwards; the host
    /// may hand the pipeline to a core session or another module.
    func release() async
}

// MARK: - Pipeline Configuration

/// Utterance endpointing policy: how the host decides a learner utterance is
/// complete. This turns per-module endpointing code (Knowledge Bowl's 1.5 s
/// silence rule) into configuration.
public struct EndpointingPolicy: Sendable, Equatable {
    /// Silence duration after detected speech that finalizes the utterance.
    public var silenceThreshold: TimeInterval

    /// Hard cap on a single utterance's duration, measured from first speech.
    public var maxUtteranceDuration: TimeInterval

    public init(silenceThreshold: TimeInterval = 1.5, maxUtteranceDuration: TimeInterval = 60) {
        self.silenceThreshold = silenceThreshold
        self.maxUtteranceDuration = maxUtteranceDuration
    }

    public static let `default` = EndpointingPolicy()
}

/// How barge-in behaves while the session is speaking.
public enum BargeInPolicy: String, Sendable {
    /// Detection disabled; narration is never interrupted.
    case off
    /// Detection runs and events are delivered, but the host does not stop
    /// playback; the module decides how to react (commands only).
    case commandOnly
    /// A confirmed barge-in stops playback and hands the floor to the user.
    case full
}

/// Buzz semantics for quiz engines. Accepted as configuration today; the
/// fast-path interrupt recognizer is not yet implemented (see RFC notes).
public enum BuzzMode: String, Sendable {
    case team
    case individual
    case recognitionRequired
}

/// Conference (team deliberation) timing. Accepted as configuration today;
/// milestone announcements remain module-driven (see RFC notes).
public struct ConferenceConfig: Sendable, Equatable {
    /// Total conference duration in seconds.
    public var duration: TimeInterval

    /// Seconds-remaining values at which the host announces milestones.
    public var milestoneSeconds: [Int]

    public init(duration: TimeInterval, milestoneSeconds: [Int] = [15, 10]) {
        self.duration = duration
        self.milestoneSeconds = milestoneSeconds
    }
}

/// Configuration for an acquired voice pipeline session.
public struct VoicePipelineConfig: Sendable {
    public var locale: Locale
    public var endpointing: EndpointingPolicy
    public var bargeIn: BargeInPolicy
    public var buzzMode: BuzzMode?
    public var answerTimeout: Duration?
    public var conference: ConferenceConfig?

    public init(
        locale: Locale = Locale(identifier: "en-US"),
        endpointing: EndpointingPolicy = .default,
        bargeIn: BargeInPolicy = .off,
        buzzMode: BuzzMode? = nil,
        answerTimeout: Duration? = nil,
        conference: ConferenceConfig? = nil
    ) {
        self.locale = locale
        self.endpointing = endpointing
        self.bargeIn = bargeIn
        self.buzzMode = buzzMode
        self.answerTimeout = answerTimeout
        self.conference = conference
    }
}

// MARK: - Utterances

/// Pre-rendered audio for an utterance (server-pregenerated question audio,
/// or previously synthesized and cached audio). Raw mono PCM float32, as
/// produced by the pre-generation pipeline.
public struct PreRenderedAudio: Sendable {
    public enum Source: Sendable {
        case data(Data)
        case file(URL)
    }

    public var source: Source
    public var sampleRate: Double
    public var channels: UInt32

    public init(source: Source, sampleRate: Double, channels: UInt32 = 1) {
        self.source = source
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// Resolve to the pipeline's cached-audio type, loading file sources.
    func toCachedSegmentAudio() throws -> CachedSegmentAudio {
        switch source {
        case .data(let data):
            return CachedSegmentAudio(audioData: data, sampleRate: sampleRate, channels: channels)
        case .file(let url):
            let data = try Data(contentsOf: url)
            return CachedSegmentAudio(audioData: data, sampleRate: sampleRate, channels: channels)
        }
    }
}

/// One thing the session speaks. Always carries text: it is the synthesis
/// input, the fallback when pre-rendered audio fails to load, and the
/// prefetch cache key.
public struct Utterance: Sendable {
    /// The text to synthesize (or the transcript of `preRendered`).
    public var text: String

    /// Request emphasized delivery. Best effort: the current on-device TTS
    /// providers accept plain text only, so this is recorded but not yet
    /// honored (see RFC notes on SSML support).
    public var emphasis: Bool

    /// Pre-rendered audio to play instead of synthesizing, when available.
    public var preRendered: PreRenderedAudio?

    public init(text: String, emphasis: Bool = false, preRendered: PreRenderedAudio? = nil) {
        self.text = text
        self.emphasis = emphasis
        self.preRendered = preRendered
    }

    /// Plain text utterance.
    public static func text(_ text: String) -> Utterance {
        Utterance(text: text)
    }

    /// Pre-rendered audio with its transcript as fallback text.
    public static func preRendered(_ audio: PreRenderedAudio, fallbackText: String) -> Utterance {
        Utterance(text: fallbackText, preRendered: audio)
    }
}

// MARK: - Listening

/// What kind of utterance the module expects. Today all expectations share
/// the configured endpointing; the hint is recorded for future tuning
/// (e.g. shorter thresholds for commands).
public enum ListenExpectation: String, Sendable {
    case freeform
    case answer
    case command
}

/// The outcome of one `listen` call.
public struct UtteranceResult: Sendable {
    /// Why listening ended.
    public enum EndReason: String, Sendable {
        /// The configured silence threshold elapsed after speech.
        case silence
        /// The utterance hit the configured maximum duration.
        case maxUtteranceDuration
        /// No speech arrived within the configured answer timeout.
        case timeout
        /// The STT provider finalized the utterance on its own.
        case sttFinalized
    }

    public let transcript: String
    public let confidence: Float
    public let endedBy: EndReason

    public init(transcript: String, confidence: Float, endedBy: EndReason) {
        self.transcript = transcript
        self.confidence = confidence
        self.endedBy = endedBy
    }
}

// MARK: - Commands

/// A module-defined voice state name used to scope command vocabularies
/// (e.g. "conference", "listening", "feedback").
public struct ModuleVoiceState: RawRepresentable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Additional commands a module registers on top of the unified vocabulary.
public struct CommandVocabulary: Sendable {
    public var commands: Set<VoiceCommand>

    public init(commands: Set<VoiceCommand>) {
        self.commands = commands
    }
}

// MARK: - Cues

/// Short audio cues (earcons) with haptic feedback.
public enum AudioCue: Sendable, Equatable {
    case correct
    case incorrect
    case commandRecognized
    case commandInvalid
    case countdownTick
    case attention
}

// MARK: - Events

/// Events surfaced by an acquired voice session.
public enum VoiceEvent: Sendable {
    /// Barge-in detection from the canonical BargeInDetector (tentative /
    /// confirmed / resumed), delivered while the session is speaking.
    case bargeIn(BargeInEvent)

    /// Buzz fast-path interrupt. Reserved: never emitted today because
    /// `BuzzMode` is configuration-only in this build (see RFC notes).
    case buzz(timestamp: TimeInterval)

    /// A registered (or unified) command was recognized in the transcript.
    case commandRecognized(VoiceCommand, confidence: Float)

    /// Voice-activity transitions while the pipeline is capturing.
    case vadState(isSpeech: Bool)

    /// Real-time partial transcript while listening.
    case partialTranscript(String)
}

// MARK: - Errors

/// Typed errors for voice session acquisition and use.
public enum VoiceSessionError: Error, LocalizedError, Equatable {
    /// The pipeline is exclusively held by a core session or another module.
    case pipelineBusy(holder: String)
    /// The shared audio engine could not be created or started.
    case audioEngineUnavailable
    /// The session was released; acquire a new one.
    case sessionReleased
    /// A `listen` call is already in progress on this session.
    case alreadyListening
    /// A `speak` call is already in progress on this session.
    case alreadySpeaking
    /// Synthesis or playback failed (bounded synthesis errors surface here,
    /// never as silent hangs).
    case synthesisFailed(String)

    public var errorDescription: String? {
        switch self {
        case .pipelineBusy(let holder):
            return "The voice pipeline is in use by \(holder)."
        case .audioEngineUnavailable:
            return "The audio engine is unavailable."
        case .sessionReleased:
            return "This voice session has been released."
        case .alreadyListening:
            return "The session is already listening."
        case .alreadySpeaking:
            return "The session is already speaking."
        case .synthesisFailed(let message):
            return "Speech synthesis failed: \(message)"
        }
    }
}
