// UnaMentis - Barge-In Coordinator
// ================================
//
// THE single barge-in pipeline that every narrating surface plugs into. The
// mandate: anywhere the app speaks to the user, the user can barge in, and the
// same gate decides what to do with the sound -> a known COMMAND, or a
// CONVERSATIONAL interruption answered by interactive AI. Reader, assistant,
// chat, learning all use this exact pipeline (the available commands may differ
// per surface). Modules opt in case-by-case (you don't barge in on an active
// quiz), simply by choosing whether to create a coordinator.
//
// One audio stream in, two outcomes out:
//   VAD detect (BargeInDetector) -> capture the utterance -> classify
//   (BargeInClassifier, via BargeInResponder) -> command? execute it.
//                                              -> conversation? answer it (LLM+TTS).
//
// The surface supplies its AudioEngine (VAD + transcript via attachSTT), its
// valid commands, its LLM/TTS, and a thin delegate for pause/resume/execute/play.

import AVFoundation
import Combine
import Foundation

@MainActor
public protocol BargeInSurface: AnyObject {
    /// Pause this surface's narration (a barge-in is starting).
    func bargeInPauseNarration() async
    /// Resume narration (false positive, or after the barge-in is handled).
    func bargeInResumeNarration() async
    /// Execute a recognized command on this surface.
    func bargeInExecute(command: VoiceCommand) async
    /// Play one response audio chunk through this surface's audio output.
    func bargeInPlay(chunk: TTSAudioChunk) async
}

@MainActor
public final class BargeInCoordinator {

    private enum Phase {
        case narrating          // armed; watching for a barge-in
        case capturing          // confirmed barge-in; collecting the user's utterance
        case responding         // executing a command / answering
    }

    private let audioEngine: AudioEngine
    private let llm: any LLMService
    private let tts: any TTSService
    private weak var surface: BargeInSurface?

    private let detector: BargeInDetector
    private let responder: BargeInResponder

    private var subscription: AnyCancellable?
    private var eventTask: Task<Void, Never>?
    private var phase: Phase = .narrating

    /// End-of-utterance: silence after the user has spoken since barge-in.
    private var hadSpeechSinceBargeIn = false
    private var silenceStart: Date?
    private let endOfUtteranceSilence: TimeInterval = 1.0
    private let speechThreshold: Float

    /// Backstop: if a captured engagement neither finishes nor resumes within this
    /// window (e.g. an empty transcript path or a hung LLM/TTS), force a resume so
    /// narration is never left stuck.
    private var engagementBackstop: Task<Void, Never>?
    private let maxEngagementSeconds: TimeInterval = 30

    public init(
        audioEngine: AudioEngine,
        llm: any LLMService,
        tts: any TTSService,
        validCommands: Set<VoiceCommand>,
        systemPrompt: @escaping @Sendable (String) -> String,
        detectorConfig: BargeInDetectorConfig = BargeInDetectorConfig(),
        surface: BargeInSurface
    ) {
        self.audioEngine = audioEngine
        self.llm = llm
        self.tts = tts
        self.surface = surface
        self.speechThreshold = detectorConfig.confidenceThreshold
        self.detector = BargeInDetector(config: detectorConfig)
        self.responder = BargeInResponder(validCommands: validCommands, systemPrompt: systemPrompt)
    }

    /// Begin monitoring. Call when narration starts.
    public func start() async {
        await responder.setDelegate(self)
        await detector.arm()
        eventTask?.cancel()
        let detector = self.detector
        eventTask = Task { [weak self] in
            for await event in detector.events {
                await self?.handle(event)
            }
        }
        subscription = audioEngine.audioStream
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (_, vadResult) in
                Task { @MainActor in await self?.onVAD(vadResult) }
            }
    }

    /// Stop monitoring and tear down. Call when narration ends.
    public func stop() async {
        subscription?.cancel()
        subscription = nil
        eventTask?.cancel()
        eventTask = nil
        engagementBackstop?.cancel()
        engagementBackstop = nil
        await detector.finish()
    }

    // MARK: VAD in

    private func onVAD(_ vad: VADResult) async {
        switch phase {
        case .narrating:
            await detector.process(vad)
        case .capturing:
            // The detector confirmed and is idle; end-of-utterance is driven by
            // the silence tracker from here.
            trackUtteranceEnd(vad)
        case .responding:
            break
        }
    }

    /// While capturing, end the utterance after a stretch of silence, then hand
    /// the transcript to the responder to classify + route.
    private func trackUtteranceEnd(_ vad: VADResult) {
        if vad.isSpeech && vad.confidence > speechThreshold {
            hadSpeechSinceBargeIn = true
            silenceStart = nil
            return
        }
        guard hadSpeechSinceBargeIn else { return }
        if silenceStart == nil { silenceStart = Date() }
        if let start = silenceStart, Date().timeIntervalSince(start) >= endOfUtteranceSilence {
            silenceStart = nil
            Task { await self.finishUtterance() }
        }
    }

    private func finishUtterance() async {
        guard phase == .capturing else { return }
        let transcript = await audioEngine.lastTranscript
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // We confirmed on sustained sound, but nothing intelligible was said
            // (noise, echo, or a changed mind). Do not engage; resume narration so
            // we never stick on a non-utterance.
            await resumeNarrating()
            return
        }
        phase = .responding
        // Classify + route: command -> bargeInExecute; conversational -> LLM + TTS.
        await responder.handle(transcript: trimmed, llm: llm, tts: tts)
    }

    // MARK: Detector events

    private func handle(_ event: BargeInEvent) async {
        switch event.kind {
        case .tentative:
            // INVARIANT: a tentative is evaluation only. Do NOT pause narration;
            // the detector is still deciding whether this sustains into a genuine
            // barge-in. Background noise that does not sustain never disrupts.
            break
        case .confirmed:
            // Sustained genuine speech: a real barge-in. Now pause and capture.
            guard phase == .narrating else { return }
            phase = .capturing
            hadSpeechSinceBargeIn = true   // confirmation already implies sustained speech
            silenceStart = nil
            startEngagementBackstop()
            await surface?.bargeInPauseNarration()
        case .resumed:
            // False positive during evaluation: nothing was paused, keep narrating.
            // (Defensive: resume if we somehow paused.)
            if phase != .narrating { await resumeNarrating() }
        }
    }

    /// Force a resume if an engagement runs too long without completing, so a hung
    /// response or an empty-transcript edge can never leave narration stuck.
    private func startEngagementBackstop() {
        engagementBackstop?.cancel()
        let seconds = maxEngagementSeconds
        engagementBackstop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.backstopResume()
        }
    }

    private func backstopResume() async {
        guard phase != .narrating else { return }
        await resumeNarrating()
    }

    private func resumeNarrating() async {
        engagementBackstop?.cancel()
        engagementBackstop = nil
        phase = .narrating
        hadSpeechSinceBargeIn = false
        silenceStart = nil
        await detector.arm()
        await surface?.bargeInResumeNarration()
    }
}

// MARK: - BargeInResponderDelegate (classify + route outcomes)

extension BargeInCoordinator: BargeInResponderDelegate {
    public func bargeInExecuteCommand(_ command: VoiceCommand) async {
        await surface?.bargeInExecute(command: command)
        await resumeNarrating()
    }
    public func bargeInWillRespond() async {
        // Already paused from the tentative; nothing extra to do.
    }
    public func bargeInPlay(_ chunk: TTSAudioChunk) async {
        await surface?.bargeInPlay(chunk: chunk)
    }
    public func bargeInDidRespond(responseText: String) async {
        await resumeNarrating()
    }
    public func bargeInFiller(forUtterance utterance: String) async -> TTSAudioChunk? {
        nil
    }
}
