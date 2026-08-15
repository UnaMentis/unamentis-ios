// UnaMentis - Oral Exam Session View Model
// Renders OralExamEngine events into published UI state and forwards user
// intents (taps and voice commands) to engine commands. The KB oral session
// view model is the pattern: the engine owns the session state machine; this
// class owns the module-side concerns only: voice pipeline acquisition,
// examiner selection (LLM when reachable, rule-based offline floor otherwise),
// session registration (watch control plane, error log), and hands-free
// command handling.

import Foundation
import SwiftUI

// MARK: - Session Configuration

/// What the dashboard hands the session view.
public struct OralExamSessionConfig: Sendable {
    public let descriptor: OralExamFormatDescriptor
    public let topic: OralExamTopic
    public let mode: OralExamSessionMode

    /// Practice time scaling applied to stage durations (1.0 = exam-faithful).
    public let timeScale: Double

    public init(
        descriptor: OralExamFormatDescriptor,
        topic: OralExamTopic,
        mode: OralExamSessionMode,
        timeScale: Double = 1.0
    ) {
        self.descriptor = descriptor
        self.topic = topic
        self.mode = mode
        self.timeScale = timeScale
    }
}

// MARK: - View State

enum OralExamSessionViewState: Equatable {
    case notStarted
    case runningStage(kind: OralExamFormatDescriptor.Stage.Kind, index: Int)
    case assemblingFeedback
    case feedback
    case completed
}

// MARK: - View Model

@MainActor
final class OralExamSessionViewModel: ObservableObject {
    // MARK: Published State

    @Published var state: OralExamSessionViewState = .notStarted
    @Published var stageKind: OralExamFormatDescriptor.Stage.Kind?
    @Published var timerRemaining: TimeInterval = 0
    @Published var timerProgress: Double = 1.0
    @Published var stageSeconds: TimeInterval = 0
    @Published var milestoneAnnouncement: String = ""
    @Published var lastPrompt: String = ""
    @Published var isListening = false
    @Published var liveTranscript: String = ""
    @Published var capturedSegments: [String] = []
    @Published var feedback: OralExamFeedback?
    @Published var summary: OralExamSummary?
    @Published var errorMessage: String?
    @Published var showLiveTranscript = false
    @Published var isPreparingServices = false
    @Published var usingOfflineExaminer = false

    let config: OralExamSessionConfig

    // MARK: Private

    private var voice: (any VoiceSession)?
    private var engine: OralExamEngine?
    private var engineEventTask: Task<Void, Never>?
    private var voiceEventTask: Task<Void, Never>?
    private var registeredSession: RegisteredSession?
    private var hasFinished = false

    /// The LLM examiner when one is in use, so `usingOfflineExaminer` can be
    /// refreshed if it degrades to offline coaching mid-session. Nil when the
    /// rule-based brain was chosen up front.
    private var liveExaminer: LLMExaminerBrain?

    /// The in-flight start, if any. See `startSession()`.
    private var startTask: Task<Void, Never>?

    init(config: OralExamSessionConfig) {
        self.config = config
    }

    deinit {
        // Safety net: hand the exclusive pipeline back if the view is
        // dismissed mid-session.
        let session = voice
        Task { await session?.release() }
    }

    // MARK: - Session Control

    /// Start the session, once.
    ///
    /// `state` does not leave `.notStarted` until the engine's first event
    /// arrives, so `state` alone cannot guard this: a `.task` firing alongside
    /// a Start tap, or a view re-identify, would both pass the check and then
    /// interleave at the first `await`, acquiring the exclusive voice pipeline
    /// twice and running two engines against one registered session. The task
    /// handle is created and stored synchronously on the MainActor before any
    /// suspension, so a second caller joins the in-flight start instead of
    /// beginning another one. A start that fails before the engine exists
    /// clears the handle, so the still-visible Start button can retry.
    func startSession() async {
        if let startTask {
            await startTask.value
            return
        }
        guard state == .notStarted else { return }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStart()
        }
        startTask = task
        await task.value
        if engine == nil {
            startTask = nil
        }
    }

    private func performStart() async {
        isPreparingServices = true
        errorMessage = nil

        let host = await OralExamModuleRuntime.currentHost()

        // Acquire the exclusive host voice session with descriptor-derived
        // long-form endpointing. The module owns no STT/TTS/VAD.
        do {
            voice = try await host.voice.acquire(config: config.descriptor.voicePipelineConfig())
        } catch {
            errorMessage = error.localizedDescription
            isPreparingServices = false
            return
        }

        // Examiner selection: the LLM brain when the routing policy can reach
        // a model, the deterministic rule-based brain otherwise (offline
        // Tier 0 floor; the UI labels its feedback as offline coaching).
        // The LLM brain can also degrade to offline coaching at RUNTIME (a
        // provider outage, a rejected model id), so the label is refreshed from
        // the brain itself as the session runs rather than fixed here.
        let examiner: any ExaminerBrain
        if (try? await ModuleLLMResolver.resolve()) != nil {
            let llmExaminer = LLMExaminerBrain.production()
            examiner = llmExaminer
            liveExaminer = llmExaminer
            usingOfflineExaminer = false
        } else {
            examiner = RuleBasedExaminerBrain()
            liveExaminer = nil
            usingOfflineExaminer = true
        }

        beginRegisteredSession(host: host)
        await host.telemetry.record(.sessionStart, module: "oral-exam")

        let context = OralExamHostContext(
            moduleId: "oral-exam",
            progress: host.progress,
            telemetry: host.telemetry
        )
        let engine = OralExamEngine(
            descriptor: config.descriptor,
            mode: config.mode,
            options: OralExamSessionOptions(timeScale: config.timeScale),
            topic: config.topic,
            host: context,
            examiner: examiner
        )
        self.engine = engine
        startEngineEventMonitoring(engine)
        startVoiceEventMonitoring()

        isPreparingServices = false
        await engine.start(voice: voice)
    }

    func endStage() async {
        await engine?.endStage()
    }

    func skipQuestion() async {
        await engine?.skipQuestion()
    }

    func endSession() async {
        if let engine {
            await engine.stop()
        } else {
            finishSession()
        }
    }

    /// Speak the feedback summary again (the session still holds the pipeline
    /// while the feedback screen shows).
    func replaySummary() async {
        guard let summaryText = feedback?.spokenSummary, let voice else { return }
        try? await voice.speak(.text(summaryText))
    }

    // MARK: - Engine Events

    private func startEngineEventMonitoring(_ engine: OralExamEngine) {
        engineEventTask?.cancel()
        engineEventTask = Task { @MainActor [weak self] in
            for await event in engine.events {
                guard let self else { break }
                self.handle(event)
            }
        }
    }

    /// Re-reads whether the LLM examiner has fallen back to offline coaching,
    /// so the UI label stays truthful when a provider fails mid-session rather
    /// than only reflecting what was reachable at session start.
    private func refreshExaminerMode() {
        guard let liveExaminer else { return }
        Task { [weak self] in
            let degraded = await liveExaminer.hasDegradedToFallback
            guard let self, degraded, !self.usingOfflineExaminer else { return }
            self.usingOfflineExaminer = true
        }
    }

    private func handle(_ event: OralExamEvent) {
        switch event {
        case .sessionStarted:
            break

        case .stageStarted(let index, let kind, let seconds):
            stageKind = kind
            stageSeconds = seconds
            timerRemaining = seconds
            timerProgress = 1.0
            milestoneAnnouncement = ""
            capturedSegments = []
            state = .runningStage(kind: kind, index: index)

        case .timerTick(let remaining, let progress):
            timerRemaining = remaining
            timerProgress = progress

        case .timerMilestone(let secondsRemaining):
            milestoneAnnouncement = secondsRemaining >= 60
                ? "\(secondsRemaining / 60) minute\(secondsRemaining == 60 ? "" : "s") remaining"
                : "\(secondsRemaining) seconds remaining"

        case .timerCountdownTick(let secondsRemaining):
            milestoneAnnouncement = "\(secondsRemaining)"

        case .promptSpoken(let text, _):
            lastPrompt = text

        case .followUpAsked(let question, _, _):
            lastPrompt = question
            refreshExaminerMode()

        case .listeningStarted:
            isListening = true
            liveTranscript = ""

        case .responseCaptured(_, let transcript, _):
            isListening = false
            liveTranscript = ""
            capturedSegments.append(transcript)

        case .stageEnded:
            isListening = false

        case .feedbackReady(let assembled):
            feedback = assembled
            state = .feedback
            refreshExaminerMode()

        case .speakFailed(let message), .listenFailed(let message):
            errorMessage = message
            registeredSession?.reportError(OralExamSessionError.voiceFailed(message))

        case .examinerFailed(let message):
            errorMessage = message
            registeredSession?.reportError(OralExamSessionError.examinerFailed(message))

        case .paused, .resumed:
            break

        case .sessionEnded(let sessionSummary):
            summary = sessionSummary
            finishSession()
        }
    }

    /// Mirror live partial transcripts into the optional on-screen transcript.
    private func startVoiceEventMonitoring() {
        voiceEventTask?.cancel()
        guard let voice else { return }
        voiceEventTask = Task { @MainActor [weak self] in
            for await event in voice.events {
                guard let self else { break }
                if case .partialTranscript(let text) = event, self.isListening {
                    self.liveTranscript = text
                }
            }
        }
    }

    // MARK: - Session Registration (MODULE_SDK_SPEC.md section 5.9)

    private func beginRegisteredSession(host: any ModuleHost) {
        guard registeredSession == nil else { return }
        let descriptor = ModuleSessionDescriptor(
            module: "oral-exam",
            title: "Oral Exam: \(config.topic.title)",
            activityKind: ModuleActivityKind(activityKindName),
            controls: .voicePractice,
            totalUnits: totalUnits
        )
        registeredSession = host.sessionRegistration.begin(
            descriptor,
            onPause: { [weak self] in
                Task { await self?.engine?.pause() }
            },
            onResume: { [weak self] in
                Task { await self?.engine?.resume() }
            },
            onMute: nil,
            onStop: { [weak self] in
                Task { await self?.endSession() }
            }
        )
    }

    /// Progress units for the watch ring: root questions in a volley, stages
    /// otherwise (an open-ended oral session has no natural item count).
    private var totalUnits: Int {
        switch config.mode {
        case .questionVolley(let roots): return roots
        case .fullSimulation: return config.descriptor.stages.count
        case .stagePractice: return 1
        }
    }

    private var activityKindName: String {
        switch config.mode {
        case .fullSimulation: return "full-simulation"
        case .stagePractice(let kind): return "stage-practice-\(kind.rawValue)"
        case .questionVolley: return "question-volley"
        }
    }

    // MARK: - Teardown

    private func finishSession() {
        guard !hasFinished else { return }
        hasFinished = true

        engineEventTask?.cancel()
        voiceEventTask?.cancel()
        isListening = false

        // Keep the feedback screen up if feedback arrived; otherwise complete.
        if state != .feedback {
            state = .completed
        }

        registeredSession?.end(summary: ModuleSessionSummary(
            completedUnits: summary?.responsesCaptured ?? capturedSegments.count,
            duration: summary?.duration ?? 0
        ))
        registeredSession = nil

        let duration = summary?.duration ?? 0
        Task {
            let host = await OralExamModuleRuntime.currentHost()
            await host.telemetry.record(.sessionEnd(duration: duration), module: "oral-exam")
        }

        // Hand the exclusive pipeline back once the learner leaves the
        // feedback screen; replay needs it, so release happens on dismiss.
        if state == .completed {
            releaseVoice()
        }
    }

    /// Called by the view on dismiss so replay-on-feedback keeps working
    /// until the learner actually leaves.
    func releaseVoice() {
        let session = voice
        voice = nil
        Task { await session?.release() }
    }
}

// MARK: - Errors

/// Module-side errors reported into the host session error log.
enum OralExamSessionError: LocalizedError {
    case voiceFailed(String)
    case examinerFailed(String)

    var errorDescription: String? {
        switch self {
        case .voiceFailed(let message):
            return "Voice pipeline error: \(message)"
        case .examinerFailed(let message):
            return "Examiner error: \(message)"
        }
    }
}
