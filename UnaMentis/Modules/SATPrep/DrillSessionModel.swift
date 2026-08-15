// UnaMentis - SAT Drill Session Model
// The MainActor view model that drives a live SAT drill: it acquires the host
// VoiceSession, builds and runs a DrillEngine, and renders the engine's event
// stream into observable UI state. This is the on-screen counterpart to the
// headless SATDrillDriver: same engine, same host services, same evaluation and
// recording, with a voice-first flow (speak the prompt, listen for the answer)
// plus an on-screen fallback (show the prompt, accept a typed answer via the
// engine's submitAnswer path, which is what math items use).
//
// The model owns the engine and the session lifecycle for the surface: it
// acquires the session on start and releases it on teardown (the host owns
// acquisition/release; the module is the acquirer here, so it releases). The
// DrillEngine never releases the session (section 5.1). While a round is live
// the model registers itself with SATPrepRuntime, so the module's `stop()`
// (section 4.1) can actually stop the drill that is running.

import Foundation
import OSLog
import SwiftUI

@MainActor
final class DrillSessionModel: ObservableObject {

    // MARK: - Observable State

    enum Phase: Equatable {
        case idle
        case loading
        case presenting
        case awaitingAnswer
        case feedback
        case completed
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentIndex = 0
    @Published private(set) var totalItems = 0
    @Published private(set) var promptText = ""
    @Published private(set) var displayText = ""
    @Published private(set) var isNumericItem = false
    @Published private(set) var lastCorrect: Bool?
    @Published private(set) var lastAnswerShown: String?
    @Published private(set) var streak = 0
    @Published private(set) var bestStreak = 0
    @Published private(set) var correctCount = 0
    @Published private(set) var answeredCount = 0
    @Published private(set) var isListening = false
    /// A transient audio-path notice (capture or narration trouble), surfaced
    /// next to the prompt rather than swallowed. Separate from
    /// `lastAnswerShown`, which is the item's answer key.
    @Published private(set) var statusMessage: String?
    /// The typed answer for the on-screen (non-voice) fallback path.
    @Published var typedAnswer = ""

    let kind: SATDrillKind

    // MARK: - Private

    private let host: any ModuleHost
    private let moduleId: String
    private var engine: DrillEngine?
    private var voiceSession: (any VoiceSession)?
    private var eventTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var items: [SATDrillItem] = []
    private var currentAnswerKey: String?
    /// Set once the activityStart event is recorded, so teardown can close the
    /// activityStart/activityEnd pair exactly once and never open-endedly.
    private var didRecordActivityStart = false
    /// Terminal flag for the surface. Teardown runs at most once, from whichever
    /// path gets there first (round end, the End button, a spoken quit, the view
    /// disappearing, or the module's own `stop()`).
    private var isTornDown = false

    private let logger = Logger(subsystem: "com.unamentis", category: "SATDrillSession")

    init(kind: SATDrillKind, host: any ModuleHost, moduleId: String) {
        self.kind = kind
        self.host = host
        self.moduleId = moduleId
    }

    // MARK: - Lifecycle

    /// Load content, order it per the descriptor policy, acquire the voice
    /// session, and start the round. Any failure surfaces on `phase`.
    func start() async {
        // A torn-down model never starts: teardown is terminal, so a round begun
        // after it would hold an engine and a session nothing could release.
        guard case .idle = phase, !isTornDown else { return }
        phase = .loading

        let descriptor: DrillFormatDescriptor
        let packItems: [SATDrillItem]
        do {
            descriptor = try SATPrepPackLoader.descriptor(for: kind)
            packItems = try SATPrepPackLoader.items(for: kind)
        } catch {
            // The learner sees the typed error's own description; the underlying
            // decode failure it carries goes to the log, never dropped.
            logger.error("SAT drill content failed to load: \(String(describing: error))")
            phase = .failed(error.localizedDescription)
            return
        }

        // Session shape: the first count shape, or the whole pack.
        let sessionCount = descriptor.sessionShapes.first { $0.kind == .count }?.value
            ?? packItems.count

        // Order per the descriptor's scheduling policy, reading current mastery
        // for review ordering, then take the session count.
        let ordered = await SATDrillScheduling.ordered(
            packItems, policy: descriptor.schedulingPolicy, progress: host.progress
        )
        items = Array(ordered.prefix(sessionCount))
        let drillItems = items.map { $0.drillItem() }
        totalItems = drillItems.count

        // Acquire the host voice session for a voice-first flow. If the pipeline
        // is busy, fall back to a screen-only round (nil session): prompts show on
        // screen and typed answers still drive the engine.
        let acquired = try? await host.voice.acquire(
            config: descriptor.voicePipelineConfig()
        )
        // A teardown can land while the acquire is in flight (a dismissal that
        // beats the first item). Hand the session straight back rather than
        // starting a round nothing is left to stop.
        guard !isTornDown else {
            await acquired?.release()
            return
        }
        voiceSession = acquired

        let context = DrillHostContext(
            moduleId: moduleId,
            evaluation: host.evaluation,
            progress: host.progress,
            telemetry: host.telemetry
        )
        // autoListen only when we have a session AND the item is voice-suited.
        // Verbal items auto-listen; numeric items favor the on-screen keypad, so
        // the model drives listening per item (see handleItemPresented).
        let engine = DrillEngine(
            descriptor: descriptor,
            options: DrillSessionOptions(activityKind: kind.activityKind, autoListen: false),
            host: context,
            provider: { drillItems }
        )
        self.engine = engine

        // Wire the subscriptions and the runtime registration BEFORE any further
        // suspension: from here on the module owns a live engine and a live
        // voice session, and every teardown path (including
        // `SATPrepModule.stop()`) must be able to reach both.
        subscribeToEngine(engine)
        subscribeToCommands()

        await host.telemetry.record(
            .activityStart(kind: kind.activityKind, voiceInitiated: acquired != nil),
            module: moduleId
        )
        didRecordActivityStart = true
        await SATPrepRuntime.shared.setActiveSession(self)
        await engine.start(voice: acquired)
    }

    /// Submit the current typed answer (on-screen fallback path).
    func submitTypedAnswer() async {
        let answer = typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, let engine else { return }
        typedAnswer = ""
        await engine.stopListening()
        await engine.submitAnswer(answer)
    }

    /// Begin capturing a spoken answer for the current item (voice path).
    func listen() {
        guard voiceSession != nil, let engine else { return }
        Task { await engine.startListening() }
    }

    /// Advance to the next item after feedback.
    func next() async {
        await engine?.next()
    }

    /// Skip the current item.
    func skip() async {
        await engine?.markSkipped()
    }

    /// End the round and release resources. One path, `teardown`, so the End
    /// button, a spoken quit, and the module's `stop()` all unwind identically.
    func end() async {
        await teardown()
    }

    /// Stop the engine, release the voice session, cancel subscriptions, close
    /// the telemetry activity, and unregister from the runtime.
    ///
    /// ORDER MATTERS: the engine is stopped BEFORE the session is released. A
    /// running engine still narrates and captures on that session, so releasing
    /// first hands the pipeline back while an engine nobody owns is still
    /// driving it. Idempotent: the first call wins and later ones (a round that
    /// ends while the view disappears, a stop that races the End button) do
    /// nothing.
    func teardown() async {
        guard !isTornDown else { return }
        isTornDown = true

        if let engine {
            self.engine = nil
            await engine.stop()
        }
        eventTask?.cancel()
        eventTask = nil
        commandTask?.cancel()
        commandTask = nil
        if let session = voiceSession {
            voiceSession = nil
            await session.release()
        }
        await SATPrepRuntime.shared.clearActiveSession(self)

        isListening = false
        // A stopped round is a finished round for the surface: show the summary
        // rather than leaving answer controls over a dead engine. A failed start
        // keeps its failure on screen, and a round that never began stays idle.
        switch phase {
        case .failed, .idle: break
        default: phase = .completed
        }

        // Close the activity exactly once, and only if it was ever opened. The
        // engine's `roundEnded` used to be the only path here, which left the
        // pair open whenever a quit or a dismissal beat the event.
        if didRecordActivityStart {
            didRecordActivityStart = false
            await host.telemetry.record(.activityEnd(kind: kind.activityKind), module: moduleId)
        }
    }

    // MARK: - Engine Event Rendering

    private func subscribeToEngine(_ engine: DrillEngine) {
        eventTask = Task { [weak self] in
            for await event in engine.events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: DrillEvent) async {
        switch event {
        case .roundStarted(let total):
            totalItems = total
            phase = total == 0 ? .completed : .presenting

        case .itemPresented(let index, let item):
            currentIndex = index
            promptText = item.prompt
            displayText = item.effectiveDisplayText
            isNumericItem = items.first { $0.id == item.id }?.isNumeric ?? false
            lastCorrect = nil
            lastAnswerShown = nil
            statusMessage = nil
            currentAnswerKey = items.first { $0.id == item.id }?.answer
            phase = .presenting

        case .answerWindowOpened:
            phase = .awaitingAnswer
            // Voice-first: auto-listen verbal items when we have a session.
            if voiceSession != nil, !isNumericItem {
                await engine?.startListening()
            }

        case .listening:
            isListening = true

        case .listeningStopped:
            isListening = false

        case .answerCaptured(let transcript):
            isListening = false
            // A captured spoken answer is submitted for evaluation.
            await engine?.submitAnswer(transcript)

        case .listenFailed(let message):
            isListening = false
            // Surface, do not swallow: the learner is told the microphone is out
            // and falls back to on-screen entry.
            logger.error("SAT drill capture failed: \(message)")
            statusMessage = String(localized: "Voice unavailable. Type your answer instead.")

        case .speakFailed(let message):
            logger.error("SAT drill narration failed: \(message)")
            statusMessage = String(localized: "Audio unavailable. The prompt is on screen.")

        case .evaluated(_, let judgment):
            answeredCount += 1
            if judgment.isCorrect { correctCount += 1 }
            lastCorrect = judgment.isCorrect
            lastAnswerShown = currentAnswerKey
            phase = .feedback

        case .itemSkipped:
            lastCorrect = nil
            lastAnswerShown = currentAnswerKey
            phase = .feedback

        case .streakChanged(let value):
            streak = value
            bestStreak = max(bestStreak, value)

        case .paused, .resumed:
            break

        case .roundEnded:
            // Teardown owns the phase, the activityEnd telemetry, and the
            // release, so the natural end and every early exit close the same
            // way.
            await teardown()
        }
    }

    // MARK: - Commands

    private func subscribeToCommands() {
        guard let session = voiceSession else { return }
        commandTask = Task { [weak self] in
            for await event in session.events {
                guard let self else { return }
                if case .commandRecognized(let command, _) = event {
                    switch command {
                    case .quit:
                        await self.end()
                    case .skip:
                        await self.skip()
                    case .next, .ready:
                        if case .feedback = self.phase { await self.next() }
                    default:
                        break
                    }
                }
            }
        }
    }
}
