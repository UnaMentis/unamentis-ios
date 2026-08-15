// UnaMentis - Drill Engine
// MODULE_SDK_SPEC.md section 6.3, engine "drill/1"
//
// The generic, descriptor-driven rapid-practice state machine. One engine, many
// formats: SAT vocabulary and mental-math drills are both expressed as data
// (DrillFormatDescriptor) plus a content pack, not code. This engine is also the
// intended substrate for Aural Skills and future flash-card packs (section 6.3
// calls drill "the primary watch engine"), so it is deliberately kept lean and
// content-agnostic.
//
// Boundaries, deliberate (mirroring QuizMatchEngine's contract, section 6.1):
// - ZERO knowledge of any specific module. Items arrive through a provider
//   closure carrying host EvaluationSpecs; modules adapt to the engine, never
//   the reverse. The provider also owns SCHEDULING: the module orders items per
//   the descriptor policy (free = pack order/shuffled, review = ascending
//   mastery, via DrillScheduling below) before handing the list over, so the
//   engine reads no ProgressStore itself and stays trivially testable.
// - UI-agnostic. The engine emits DrillEvents on an AsyncStream (single
//   consumer) and exposes command methods; a module view model renders events
//   and forwards user intents (spoken or typed).
// - The engine does not own the voice pipeline. The module acquires the
//   exclusive VoiceSession (with descriptor-derived endpointing via
//   `DrillFormatDescriptor.voicePipelineConfig`) and hands it to `start(voice:)`;
//   the module remains responsible for release.
// - Progress and telemetry are emitted per evaluated answer through the injected
//   DrillHostContext (AttemptRecord + mastery observation + module.attempt),
//   exactly the writes the SDK spec requires (sections 5.4 and 5.6).
// - Answer capture supports BOTH the spoken path (listen, then submit the
//   transcript) and a text path (submitAnswer directly), so a non-voice UI (the
//   on-screen math keypad) drives the same evaluation and recording code.

import Foundation
import OSLog

public actor DrillEngine {
    // MARK: - Configuration

    private let descriptor: DrillFormatDescriptor
    private let options: DrillSessionOptions
    private let host: DrillHostContext
    private let provider: DrillItemProvider

    // MARK: - Events

    /// The engine's event stream. Single consumer.
    public nonisolated let events: AsyncStream<DrillEvent>
    private nonisolated let eventContinuation: AsyncStream<DrillEvent>.Continuation

    // MARK: - State

    public private(set) var state: DrillEngineState = .idle

    /// Whether the engine currently holds the microphone open for an answer.
    /// Exposed so consumers (and tests) can assert the capture invariant
    /// directly: exactly one live capture, and never a live capture after a
    /// stop, a pause, or a stopListening.
    public var isCapturing: Bool { isListening }

    private var voice: (any VoiceSession)?
    private var items: [DrillItem] = []
    private var currentIndex = 0

    private var roundStart: Date?
    private var promptEndedAt: Date?
    private var answeredCount = 0
    private var correctCount = 0
    private var streak = 0
    private var bestStreak = 0

    private var isPaused = false
    private var cycleTask: Task<Void, Never>?
    private var listenTask: Task<Void, Never>?
    private var isListening = false

    /// Monotonic capture generation. Every capture start bumps it, and a
    /// finishing capture may only touch the capture flags while its generation
    /// is still current. Cancelling a listen is ASYNCHRONOUS in the unified
    /// pipeline (the cancel handler spawns a Task), so a stale listen can
    /// outlive the listen that replaced it. Without the generation check a
    /// stale task either clears the flags for a newer live capture (orphaning
    /// the mic into the next item) or leaves `isListening` true so the next
    /// `startListening` is silently rejected and the learner gets a dead mic
    /// with no error.
    private var captureGeneration = 0

    /// Set synchronously before the evaluation await and cleared on every path
    /// out of `submitAnswer`. A typed answer plus a finalizing utterance both
    /// pass the state guard otherwise, and both score: doubled answered count,
    /// two evaluated events, two attempt records for one item, doubled streak
    /// and mastery.
    private var isEvaluating = false

    /// Terminal flag. `state == .ended` alone is not enough: every stretch of
    /// code that suspends across an await must be able to tell that the round
    /// ended underneath it BEFORE it assigns state or mutates a counter, or a
    /// stopped engine resurrects itself after the final summary.
    private var hasEnded = false

    /// The module voice state last published to the host, so repeats are not
    /// re-sent.
    private var publishedVoiceState: ModuleVoiceState?

    /// Serializes voice-state publication. The synchronous command methods
    /// cannot await, and unordered unstructured tasks would let the host see
    /// phases out of order.
    private var voiceStateTask: Task<Void, Never>?

    /// Chained attempt writes. Chaining keeps them ordered without adding a
    /// suspension point to `submitAnswer` (which would let a consumer's
    /// `next()` interleave before the feedback transition), and gives the
    /// terminal path something explicit to flush.
    private var attemptWrites: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.unamentis", category: "DrillEngine")

    // MARK: - Init

    public init(
        descriptor: DrillFormatDescriptor,
        options: DrillSessionOptions,
        host: DrillHostContext,
        provider: @escaping DrillItemProvider
    ) {
        self.descriptor = descriptor
        self.options = options
        self.host = host
        self.provider = provider

        var continuation: AsyncStream<DrillEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.eventContinuation = continuation
    }

    // MARK: - Commands

    /// Begin the round on an already-acquired voice session. The caller keeps
    /// ownership of the session and releases it after `stop()`. A nil session
    /// runs the flow without narration or capture (the pipeline was busy or
    /// unavailable); capture attempts surface as `listenFailed`, and a text UI
    /// still drives `submitAnswer`.
    public func start(voice: (any VoiceSession)?) {
        guard state == .idle, !hasEnded, cycleTask == nil else { return }
        self.voice = voice
        roundStart = Date()
        // Leave `.idle` SYNCHRONOUSLY. The round's first suspension point is
        // inside beginRound (the item provider), so a second start() arriving
        // before that await resolved would otherwise pass the guard and run a
        // second round concurrently on the same session.
        state = .presenting(index: currentIndex)
        setVoiceState(.presenting)
        cycleTask = Task { await beginRound() }
    }

    /// Start capturing one spoken answer. No-op unless an answer window is open,
    /// the round is running and unpaused, and the engine is not already
    /// listening.
    public func startListening() {
        guard !hasEnded, !isPaused, !isEvaluating else { return }
        guard case .awaitingAnswer(let index) = state, !isListening else { return }
        guard let voice else {
            emit(.listenFailed(message: "Voice session unavailable"))
            return
        }
        let generation = beginCapture()
        isListening = true
        setVoiceState(.listening)
        emit(.listening(index: index))
        listenTask = Task {
            do {
                let result = try await voice.listen(expecting: .answer)
                guard self.claimCapture(generation) else { return }
                emit(.answerCaptured(transcript: result.transcript))
            } catch is CancellationError {
                guard self.claimCapture(generation) else { return }
                emit(.listeningStopped(index: index))
            } catch {
                guard self.claimCapture(generation) else { return }
                emit(.listenFailed(message: error.localizedDescription))
            }
        }
    }

    /// Stop capturing without submitting (the consumer keeps any partial
    /// transcript it observed). Authoritative: the capture flags are cleared
    /// synchronously, because waiting for the cancelled task to notice would
    /// leave `isListening` true and get the next `startListening` rejected.
    public func stopListening() {
        cancelCapture(emitStopped: true)
    }

    // MARK: - Capture Ownership

    /// Take ownership of capture for a new listen, orphaning any in-flight one.
    private func beginCapture() -> Int {
        captureGeneration += 1
        return captureGeneration
    }

    /// True when `generation` is still the live capture. Clears the capture
    /// flags when it is; a stale generation touches nothing and emits nothing.
    private func claimCapture(_ generation: Int) -> Bool {
        guard generation == captureGeneration else { return false }
        isListening = false
        listenTask = nil
        return true
    }

    /// End any live capture now: cancel the task, clear the flags
    /// synchronously, and orphan the cancelled task's completion so it cannot
    /// clobber a capture started immediately afterwards.
    @discardableResult
    private func cancelCapture(emitStopped: Bool) -> Bool {
        let wasListening = isListening
        captureGeneration += 1
        isListening = false
        listenTask?.cancel()
        listenTask = nil
        if wasListening, emitStopped {
            emit(.listeningStopped(index: currentIndex))
        }
        return wasListening
    }

    // MARK: - Module Voice State

    /// The module voice states this engine drives. The host scopes its command
    /// vocabulary by the ACTIVE state, so an engine that never publishes one
    /// leaves that vocabulary inert in production: the session cannot tell
    /// which phase the activity is in, and state-valid command filtering cannot
    /// work. Names match QuizMatchEngine's for the phases the two share.
    enum VoicePhase: String {
        case presenting
        case answering
        case listening
        case feedback
        case ended
    }

    /// Publish the active module voice state to the host (spec 5.1). Serialized
    /// through one task chain so phases arrive in the order the engine entered
    /// them, even when published from a synchronous command method.
    private func setVoiceState(_ phase: VoicePhase) {
        let state = ModuleVoiceState(rawValue: phase.rawValue)
        guard let voice, state != publishedVoiceState else { return }
        publishedVoiceState = state
        let previous = voiceStateTask
        voiceStateTask = Task {
            await previous?.value
            await voice.setActiveVoiceState(state)
        }
    }

    /// Enter the feedback phase for `index` (state plus published voice state,
    /// which must never drift apart).
    private func enterFeedback(index: Int) {
        state = .feedback(index: index)
        setVoiceState(.feedback)
    }

    /// Submit an answer for evaluation. Covers both the spoken path (the consumer
    /// passes the captured transcript) and the text path (a typed answer from the
    /// on-screen keypad).
    public func submitAnswer(_ text: String) async {
        guard !hasEnded, !isEvaluating else { return }
        guard case .awaitingAnswer(let index) = state, index < items.count else { return }
        // Claim the evaluation window SYNCHRONOUSLY, before the first await: a
        // typed answer and a finalizing utterance are independent input paths
        // and both otherwise pass the state guard.
        isEvaluating = true
        defer { isEvaluating = false }
        cancelCapture(emitStopped: true)
        let item = items[index]

        let responseTime = promptEndedAt.map { Date().timeIntervalSince($0) } ?? 0
        let responseTimeMs = Int(responseTime * 1000)

        let result = await host.evaluation.evaluate(
            LearnerResponse(text: text),
            against: item.evaluation
        )
        // stop() may have landed while evaluation was in flight. Scoring now
        // would mutate counters and write an attempt AFTER the final summary,
        // and the later next() would present an item on a released session.
        guard !hasEnded else { return }
        let correct = result.verdict == .correct

        answeredCount += 1
        if correct {
            correctCount += 1
            streak += 1
            bestStreak = max(bestStreak, streak)
        } else {
            streak = 0
        }

        let judgment = DrillJudgment(
            evaluation: result,
            answerText: text,
            responseTimeMs: responseTimeMs,
            streak: streak
        )
        emit(.evaluated(index: index, judgment: judgment))
        emit(.streakChanged(streak: streak))
        recordAttempt(item: item, judgment: judgment)

        enterFeedback(index: index)
    }

    /// Skip the current item without an answer. No attempt is recorded (matching
    /// drill semantics), and the streak resets, since a skip breaks the run.
    public func markSkipped() {
        guard case .awaitingAnswer(let index) = state, !hasEnded, !isEvaluating else { return }
        cancelCapture(emitStopped: true)
        streak = 0
        emit(.itemSkipped(index: index))
        emit(.streakChanged(streak: 0))
        enterFeedback(index: index)
    }

    /// Advance from feedback to the next item (or end the round). Returns once
    /// the next cycle is underway; narration proceeds asynchronously.
    public func next() {
        guard case .feedback = state, !hasEnded else { return }
        currentIndex += 1
        // Leave `.feedback` SYNCHRONOUSLY, before the cycle task's first await.
        // Drill happens to be safe today only because presentCurrentItem sets
        // the state before its first suspension point; hardening it here means
        // a future await added ahead of that cannot reintroduce the
        // double-advance QuizMatch had (voice "next" plus a button tap).
        state = .presenting(index: currentIndex)
        setVoiceState(.presenting)
        cycleTask?.cancel()
        cycleTask = Task { await presentCurrentItem() }
    }

    /// Pause capture (watch control plane integration point).
    public func pause() {
        guard !isPaused, !hasEnded else { return }
        isPaused = true
        cancelCapture(emitStopped: true)
        emit(.paused)
    }

    public func resume() {
        guard isPaused, !hasEnded else { return }
        isPaused = false
        emit(.resumed)
        // Pause closed the mic; a resume that only announced itself left a
        // hands-free learner staring at an open answer window with no
        // microphone. Reopen capture when the answer window is still open.
        if options.autoListen, case .awaitingAnswer = state {
            startListening()
        }
    }

    /// End the round now. Emits the final summary and finishes the stream. The
    /// caller releases the voice session afterwards. Idempotent.
    public func stop() async {
        guard !hasEnded else { return }
        await endRound()
    }

    // MARK: - Item Cycle

    private func beginRound() async {
        items = await provider()
        // The provider is an await: the round may have been stopped while it
        // was resolving.
        guard !hasEnded else { return }
        emit(.roundStarted(totalItems: items.count))
        await presentCurrentItem()
    }

    private func presentCurrentItem() async {
        guard !hasEnded else { return }
        guard currentIndex < items.count else {
            await endRound()
            return
        }

        let item = items[currentIndex]
        state = .presenting(index: currentIndex)
        setVoiceState(.presenting)
        emit(.itemPresented(index: currentIndex, item: item))

        await speak(promptUtterance(for: item))
        guard !hasEnded else { return }
        promptEndedAt = Date()
        openAnswerWindow()
    }

    private func promptUtterance(for item: DrillItem) -> Utterance {
        if let audio = item.preRenderedAudio {
            return .preRendered(audio, fallbackText: item.prompt)
        }
        return .text(item.prompt)
    }

    private func speak(_ utterance: Utterance) async {
        do {
            try await voice?.speak(utterance)
        } catch is CancellationError {
            // Interrupted; the flow continues.
        } catch {
            logger.error("Prompt narration failed: \(error.localizedDescription)")
            emit(.speakFailed(message: error.localizedDescription))
        }
    }

    // MARK: - Answer Window

    private func openAnswerWindow() {
        guard !hasEnded else { return }
        state = .awaitingAnswer(index: currentIndex)
        setVoiceState(.answering)
        emit(.answerWindowOpened(index: currentIndex))
        if options.autoListen {
            // A paused round opens the window but not the microphone;
            // `resume()` reopens capture.
            startListening()
        }
    }

    // MARK: - Progress and Telemetry

    /// The per-attempt writes the SDK requires: a structured AttemptRecord, a
    /// mastery observation (keyed by the item's skill tag so review ordering
    /// improves over time), and the required module.attempt telemetry event
    /// (MODULE_SDK_SPEC.md sections 5.4 and 5.6).
    private func recordAttempt(item: DrillItem, judgment: DrillJudgment) {
        let domain = StandardDomain(item.effectiveDomain)
        let record = AttemptRecord(
            module: host.moduleId,
            domain: domain,
            itemId: item.id,
            response: judgment.answerText,
            correct: judgment.isCorrect,
            latencyMs: judgment.responseTimeMs
        )
        let observation = MasteryObservation(
            module: host.moduleId,
            domain: domain,
            signal: judgment.isCorrect ? 100 : 0
        )
        let correct = judgment.isCorrect
        let latencyMs = judgment.responseTimeMs
        // Chained, not fire-and-forget: writes land in the order the answers
        // were judged, and `flushAttemptWrites` can wait them out before the
        // terminal event.
        let previous = attemptWrites
        attemptWrites = Task { [host] in
            await previous?.value
            await host.progress.store(record)
            await host.progress.reportMastery(observation)
            await host.telemetry.record(
                .attempt(outcome: correct ? .correct : .incorrect, latencyMs: latencyMs),
                module: host.moduleId
            )
        }
    }

    /// Wait until every queued attempt write has landed. Awaited before the
    /// terminal event so a consumer reading the ProgressStore on `roundEnded`
    /// sees a complete attempt trail instead of racing the writes.
    private func flushAttemptWrites() async {
        while let task = attemptWrites {
            await task.value
            // A write queued while we waited replaces the handle; loop until
            // the chain is genuinely drained.
            if attemptWrites == task { attemptWrites = nil }
        }
    }

    // MARK: - Round End

    /// Idempotent: the first call wins, later ones (a second stop, a stop that
    /// races the last item) do nothing.
    private func endRound() async {
        guard !hasEnded else { return }
        hasEnded = true
        cancelCapture(emitStopped: false)
        cycleTask?.cancel()
        cycleTask = nil
        state = .ended
        setVoiceState(.ended)

        // The attempt trail must be COMPLETE when the terminal event lands.
        // These writes used to be fire-and-forget, so a consumer (or the
        // conformance suite) reading attempts on `roundEnded` raced them and
        // had to poll.
        await flushAttemptWrites()

        let summary = DrillSummary(
            answeredItems: answeredCount,
            correctAnswers: correctCount,
            bestStreak: bestStreak,
            duration: roundStart.map { Date().timeIntervalSince($0) } ?? 0
        )
        emit(.roundEnded(summary: summary))
        eventContinuation.finish()
    }

    // MARK: - Emission

    private func emit(_ event: DrillEvent) {
        eventContinuation.yield(event)
    }
}

// MARK: - Scheduling

/// Item ordering for a drill session, applied by the MODULE before it hands the
/// list to the engine (the engine stays free of persistence). The two policies
/// the descriptor names (spec 6.3): `free` is pack order, optionally shuffled;
/// `review` sorts by ascending stored mastery for each item's skill tag, so the
/// weakest skills come first. A pure enum so it is trivially testable.
public enum DrillScheduling {
    /// Order `items` per `policy`. For `.review`, `masteryForTag` supplies the
    /// current 0...100 mastery of a skill tag (the module reads it from the
    /// ProgressStore's unified proficiency model). Ties, and the `.free` policy,
    /// preserve the input order unless `shuffle` is set.
    public static func order(
        _ items: [DrillItem],
        policy: DrillFormatDescriptor.SchedulingPolicy,
        masteryForTag: (String) -> Double,
        shuffle: Bool = false
    ) -> [DrillItem] {
        switch policy {
        case .free:
            return shuffle ? items.shuffled() : items
        case .review:
            // Stable sort by ascending mastery: enumerate to break ties by the
            // original position, so equal-mastery items keep pack order.
            return items.enumerated()
                .sorted { lhs, rhs in
                    let lm = masteryForTag(lhs.element.skillTag)
                    let rm = masteryForTag(rhs.element.skillTag)
                    if lm == rm { return lhs.offset < rhs.offset }
                    return lm < rm
                }
                .map(\.element)
        }
    }
}
