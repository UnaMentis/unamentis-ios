// UnaMentis - Scripted Voice Session (shared test harness)
// A deterministic, in-memory VoiceSession for headless module and engine tests.
//
// Promoted from QuizMatchEngineTests' local copy so every module test drives the
// ONE voice pipeline seam. It is a host test double, not a mock of a paid
// external API: the production VoiceSession composes STT/TTS/VAD, but this
// version replaces the whole pipeline deterministically, exactly as the barge-in
// injection harness does (MODULE_SDK_SPEC.md section 9: "scripted VoiceSession
// with utterance/command injection").
//
// ALLOWED: in-memory host seam, not a mock of a paid external API.
//
// Behavior preserved from the QuizMatchEngine seam:
// - `speak` records text; `holdSpeaks(n)` holds the next n speak calls open
//   until `stopSpeaking` (so tests can buzz mid-narration) without deadlock.
// - `listen` returns queued transcripts, suspending until one arrives and
//   honoring task cancellation (submit/stop paths throw CancellationError).
//
// Added for conformance driving:
// - records played cues, registered command vocabularies, and active states;
// - can inject a recognized command event onto `events` (command honoring
//   checks) via `injectCommand`.

import Foundation
@testable import UnaMentis

/// A deterministic VoiceSession for headless module and engine tests.
/// ALLOWED: in-memory host seam, not a mock of a paid external API.
actor ScriptedVoiceSession: VoiceSession {
    nonisolated let events: AsyncStream<VoiceEvent>
    private let eventContinuation: AsyncStream<VoiceEvent>.Continuation

    private var transcriptQueue: [String] = []
    private var holdNextSpeaks = 0
    private var interruptRequested = false
    private var speakGate: CheckedContinuation<Void, Never>?

    /// When true, a `listen` with an empty transcript queue returns the most
    /// recently spoken text (the learner "echoing" the prompt) instead of
    /// blocking. This lets echo-style voice activities run headlessly without the
    /// app code needing to reach a test-only enqueue API. Explicit enqueued
    /// transcripts always take precedence. Off by default; the ScriptedModuleHost
    /// harness turns it on for its vended session.
    private var echoModeEnabled: Bool

    // Recording seams for assertions.
    private(set) var spokenTexts: [String] = []
    private(set) var playedCues: [AudioCue] = []
    private(set) var registeredStates: [ModuleVoiceState] = []
    private(set) var activeStates: [ModuleVoiceState] = []
    private(set) var stopSpeakingCount = 0
    private(set) var released = false

    init(echoMode: Bool = false) {
        self.echoModeEnabled = echoMode
        var continuation: AsyncStream<VoiceEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    // MARK: - Scripting

    /// Hold the next `count` speak calls open until `stopSpeaking` (a buzz).
    func holdSpeaks(_ count: Int) {
        holdNextSpeaks = count
    }

    /// Queue a transcript for the next `listen` call.
    func enqueueTranscript(_ transcript: String) {
        transcriptQueue.append(transcript)
    }

    /// Queue several transcripts in order.
    func enqueueTranscripts(_ transcripts: [String]) {
        transcriptQueue.append(contentsOf: transcripts)
    }

    /// Emit a recognized-command event to any consumer of `events`.
    func injectCommand(_ command: VoiceCommand, confidence: Float = 1.0) {
        eventContinuation.yield(.commandRecognized(command, confidence: confidence))
    }

    // MARK: - VoiceSession

    func speak(_ utterance: Utterance) async throws {
        spokenTexts.append(utterance.text)
        if holdNextSpeaks > 0 {
            holdNextSpeaks -= 1
            // A buzz that landed before this speak call started still
            // interrupts it (no deadlock on the gate).
            if interruptRequested {
                interruptRequested = false
                return
            }
            await withCheckedContinuation { (gate: CheckedContinuation<Void, Never>) in
                speakGate = gate
            }
        }
    }

    func stopSpeaking() async {
        stopSpeakingCount += 1
        if let gate = speakGate {
            speakGate = nil
            gate.resume()
        } else {
            interruptRequested = true
        }
    }

    func prefetch(_ utterances: [Utterance]) async {}

    func listen(expecting expectation: ListenExpectation) async throws -> UtteranceResult {
        // Explicit enqueued transcripts win. In echo mode, an empty queue returns
        // the last spoken text so echo-style activities complete without a
        // test-only enqueue API. Otherwise wait for a transcript, honoring task
        // cancellation (submit/stop paths throw CancellationError, as production).
        while transcriptQueue.isEmpty {
            if echoModeEnabled, let echo = spokenTexts.last {
                return UtteranceResult(transcript: echo, confidence: 1.0, endedBy: .silence)
            }
            try Task.checkCancellation()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let transcript = transcriptQueue.removeFirst()
        return UtteranceResult(transcript: transcript, confidence: 1.0, endedBy: .silence)
    }

    func registerCommands(_ vocabulary: CommandVocabulary, for state: ModuleVoiceState) async {
        registeredStates.append(state)
    }

    func setActiveVoiceState(_ state: ModuleVoiceState) async {
        activeStates.append(state)
    }

    func playCue(_ cue: AudioCue) async {
        playedCues.append(cue)
    }

    func release() async {
        released = true
        eventContinuation.finish()
    }
}
