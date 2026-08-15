// UnaMentis - Quiz Match Engine
// MODULE_SDK_SPEC.md section 6.1, engine "quiz-match/1"
//
// The generic, descriptor-driven quiz match state machine, extracted from
// Knowledge Bowl's oral practice flow (migration Phase 5). One engine, many
// formats: Knowledge Bowl's team-buzz short-form practice and Quiz Bowl's
// individual-buzz pyramidal tossup/bonus play are both expressed as data
// (QuizMatchFormatDescriptor), not code.
//
// Boundaries, deliberate:
// - ZERO knowledge of any specific module. Questions arrive through a
//   provider closure carrying host EvaluationSpecs; modules adapt to the
//   engine, never the reverse.
// - UI-agnostic. The engine emits QuizMatchEvents on an AsyncStream (single
//   consumer) and exposes command methods; a module view model renders
//   events and forwards user intents.
// - The engine does not own the voice pipeline. The module acquires the
//   exclusive VoiceSession (with descriptor-derived endpointing via
//   `QuizMatchFormatDescriptor.voicePipelineConfig`) and hands it to
//   `start(voice:)`; the module remains responsible for release. The engine
//   also does not consume `voice.events`: partial transcripts stay with the
//   module (single-consumer stream), and the buzz fast path is still a host
//   stub (RFC 0002 item 4), so buzzes arrive via the `buzz(atCharacterIndex:)`
//   command.
// - Progress and telemetry are emitted per evaluated answer through the
//   injected QuizMatchHostContext (AttemptRecord + mastery observation +
//   module.attempt), exactly the writes the KB view model previously made.
//   Session-level registration (watch control plane) stays with the module,
//   which calls pause/resume/stop here from its registered-session callbacks.
//
// Scope (Phase 5): the flow KB oral practice exercises today, plus the
// descriptor-driven mechanics the Quiz Bowl skeleton proves (pyramidal power
// scoring, interrupt negs, multi-part bonuses, a minimal rebound hook).
// Opponent simulation and written rounds are deliberately not absorbed yet.

import Foundation
import OSLog

public actor QuizMatchEngine {
    // MARK: - Configuration

    private let descriptor: QuizMatchFormatDescriptor
    private let options: QuizMatchSessionOptions
    private let host: QuizMatchHostContext
    private let provider: QuizMatchQuestionProvider

    // MARK: - Events

    /// The engine's event stream. Single consumer.
    public nonisolated let events: AsyncStream<QuizMatchEvent>
    private nonisolated let eventContinuation: AsyncStream<QuizMatchEvent>.Continuation

    // MARK: - State

    public private(set) var state: QuizMatchEngineState = .idle

    /// Whether the engine currently holds the microphone open for an answer.
    /// Exposed so consumers (and tests) can assert the capture invariant
    /// directly: exactly one live capture, and never a live capture after a
    /// stop, a pause, or a stopListening.
    public var isCapturing: Bool { isListening }

    private var voice: (any VoiceSession)?
    private var scores: [Int]
    private var currentIndex = 0
    private var currentQuestion: QuizMatchQuestion?
    private var matchStart: Date?
    private var correctCount = 0

    /// Question indices that received at least one submitted answer. The
    /// summary reports QUESTIONS answered, so a rebound question answered by
    /// two participants counts once, not twice against the question count.
    private var answeredQuestionIndices: Set<Int> = []

    /// When the answer window opened, for response-time measurement.
    private var answerWindowOpenedAt: Date?

    /// Set when a buzz interrupted narration: the character index of the
    /// buzz, for power determination. Cleared per question.
    private var interruptCharIndex: Int?

    /// Whether narration was cut short (skip or buzz) for the current question.
    private var readingInterrupted = false

    /// Participants who have already answered the current question (rebound
    /// bookkeeping).
    private var attemptedParticipants: Set<Int> = []
    private var currentParticipant = 0

    private var isPaused = false
    private var cycleTask: Task<Void, Never>?
    private var conferenceTask: Task<Void, Never>?
    private var listenTask: Task<Void, Never>?
    private var bonusCaptureTask: Task<UtteranceResult, Error>?
    private var isListening = false

    /// Monotonic capture generation. Every capture start bumps it, and a
    /// finishing capture may only touch the capture flags while its generation
    /// is still current. Cancelling a listen is ASYNCHRONOUS in the unified
    /// pipeline (the cancel handler spawns a Task), so a stale listen can
    /// outlive the listen that replaced it. Without the generation check a
    /// stale task either clears the flags for a newer live capture (orphaning
    /// the mic into the next question) or leaves `isListening` true so the
    /// rebounding participant's `startListening` is silently rejected and they
    /// are left with a dead mic and no error.
    private var captureGeneration = 0

    /// Set synchronously before the evaluation await and cleared on every path
    /// out of `submitAnswer`. Two submissions inside the evaluation window (a
    /// typed answer plus a finalizing utterance, or the same voice command
    /// fired twice off a growing partial transcript) would otherwise both
    /// score: doubled answered counts, two evaluated events, two attempt
    /// records for one question, and a doubled score delta.
    private var isEvaluating = false

    /// Terminal flag. `state == .ended` alone is not enough: every stretch of
    /// code that suspends across an await must be able to tell that the match
    /// ended underneath it BEFORE it assigns state or mutates a score, or a
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

    private let logger = Logger(subsystem: "com.unamentis", category: "QuizMatchEngine")

    // MARK: - Init

    public init(
        descriptor: QuizMatchFormatDescriptor,
        options: QuizMatchSessionOptions,
        host: QuizMatchHostContext,
        provider: @escaping QuizMatchQuestionProvider
    ) {
        self.descriptor = descriptor
        self.options = options
        self.host = host
        self.provider = provider
        self.scores = Array(repeating: 0, count: options.participantCount)

        var continuation: AsyncStream<QuizMatchEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.eventContinuation = continuation
    }

    // MARK: - Commands

    /// Begin the match on an already-acquired voice session. The caller keeps
    /// ownership of the session and releases it after `stop()`. A nil session
    /// runs the flow without narration or capture (the pipeline was busy or
    /// unavailable); capture attempts surface as `listenFailed`.
    public func start(voice: (any VoiceSession)?) {
        guard state == .idle, !hasEnded, cycleTask == nil else { return }
        self.voice = voice
        matchStart = Date()
        // Leave `.idle` SYNCHRONOUSLY. The cycle's first suspension point is
        // inside presentCurrentQuestion (the question provider), so a second
        // start() arriving before that await resolved would otherwise pass the
        // guard and run a second round concurrently on the same session.
        state = .readingQuestion(index: currentIndex)
        setVoiceState(.reading)
        emit(.matchStarted(totalQuestions: options.questionCount))
        cycleTask = Task { await presentCurrentQuestion() }
    }

    /// Skip the rest of the question narration (proceeds to conference or the
    /// answer window, per the descriptor).
    public func skipReading() async {
        guard case .readingQuestion = state else { return }
        readingInterrupted = true
        await voice?.stopSpeaking()
    }

    /// A buzz during narration (pyramidal formats). `atCharacterIndex` is how
    /// far narration had progressed, used against the power mark. Stops
    /// narration and opens the answer window directly (no conference).
    public func buzz(atCharacterIndex index: Int, participant: Int = 0) async {
        guard case .readingQuestion = state else { return }
        interruptCharIndex = index
        readingInterrupted = true
        currentParticipant = participant
        await voice?.stopSpeaking()
    }

    /// End conference early ("Ready to Answer").
    public func skipConference() {
        guard case .conference = state, !hasEnded else { return }
        conferenceTask?.cancel()
        conferenceTask = nil
        emit(.conferenceEnded(skipped: true))
        openAnswerWindow()
    }

    /// Start capturing one spoken answer. No-op unless the answer window is
    /// open, the match is running and unpaused, and the engine is not already
    /// listening.
    public func startListening() {
        guard !isEvaluating else { return }
        beginListening()
    }

    /// The capture-opening body, without the evaluation-in-flight guard, so the
    /// rebound path can open the next participant's mic from inside
    /// `submitAnswer`.
    private func beginListening() {
        guard !hasEnded, !isPaused else { return }
        guard case .awaitingAnswer(let index) = state, !isListening else { return }
        guard let voice else {
            emit(.listenFailed(message: "Voice session unavailable"))
            return
        }
        let generation = beginCapture()
        isListening = true
        setVoiceState(.listening)
        emit(.listeningStarted(index: index))
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
        bonusCaptureTask?.cancel()
        bonusCaptureTask = nil
        if wasListening, emitStopped {
            emit(.listeningStopped(index: currentIndex))
        }
        return wasListening
    }

    /// Park until the match resumes (or ends). Used before opening capture, so
    /// a pause that arrived while the engine was between capture points still
    /// keeps the microphone shut.
    private func waitWhilePaused() async {
        while isPaused && !hasEnded {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Module Voice State

    /// The module voice states this engine drives. The host scopes its command
    /// vocabulary by the ACTIVE state, so an engine that never publishes one
    /// leaves that vocabulary inert in production: the session cannot tell
    /// which phase the activity is in, and state-valid command filtering cannot
    /// work. Names match the phases a quiz-match run actually enters, and the
    /// drill engine uses the same words for the phases it shares.
    enum VoicePhase: String {
        case reading
        case conferring
        case answering
        case listening
        case bonus
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

    /// Submit an answer for evaluation. Covers both the spoken path (the
    /// consumer passes the captured transcript) and the text path.
    public func submitAnswer(_ text: String, participant: Int? = nil) async {
        guard !hasEnded, !isEvaluating else { return }
        guard case .awaitingAnswer(let index) = state, let question = currentQuestion else { return }
        // Claim the evaluation window SYNCHRONOUSLY, before the first await.
        // Two independent input paths (a typed answer and a finalizing
        // utterance; a voice command fired twice off a growing partial) both
        // pass the state guard otherwise, and both score.
        isEvaluating = true
        defer { isEvaluating = false }
        cancelCapture(emitStopped: true)

        let answeringParticipant = min(max(participant ?? currentParticipant, 0), scores.count - 1)
        let responseTime = answerWindowOpenedAt.map { Date().timeIntervalSince($0) } ?? 0
        let responseTimeMs = Int(responseTime * 1000)

        let result = await host.evaluation.evaluate(
            LearnerResponse(text: text),
            against: question.evaluation
        )
        // stop() may have landed while evaluation was in flight. Scoring now
        // would mutate scores and write an attempt AFTER the final summary,
        // and the later next() would start a question on a released session.
        guard !hasEnded else { return }
        let correct = result.verdict == .correct

        // Interrupt context: this answer came from a buzz before the question
        // finished. Powers and negs only apply to interrupts.
        let wasInterrupt = interruptCharIndex != nil
        // A tossup with NO power mark can never award power. The old
        // `?? .max` sentinel made every interrupt index compare less than the
        // missing mark, so every unpowered tossup in a powered format paid 15.
        let wasPower: Bool = {
            guard correct,
                  descriptor.questionForm == .pyramidal,
                  descriptor.scoring.power != nil,
                  let buzzIndex = interruptCharIndex,
                  let powerMarkIndex = question.powerMarkIndex else { return false }
            return buzzIndex < powerMarkIndex
        }()

        let points: Int
        if correct {
            points = wasPower ? (descriptor.scoring.power ?? descriptor.scoring.correct)
                              : descriptor.scoring.correct
        } else {
            points = wasInterrupt ? descriptor.scoring.incorrect : 0
        }

        scores[answeringParticipant] += points
        answeredQuestionIndices.insert(index)
        if correct { correctCount += 1 }
        attemptedParticipants.insert(answeringParticipant)

        let judgment = QuizMatchJudgment(
            evaluation: result,
            answerText: text,
            pointsAwarded: points,
            wasPower: wasPower,
            wasInterrupt: wasInterrupt,
            participant: answeringParticipant,
            responseTimeMs: responseTimeMs
        )
        emit(.evaluated(index: index, judgment: judgment))
        emit(.scoreChanged(scores: scores))
        recordAttempt(question: question, judgment: judgment)

        if correct {
            if descriptor.scoring.bonus != nil, let bonus = question.bonus {
                await runBonus(bonus, forQuestionAt: index, participant: answeringParticipant)
                guard !hasEnded else { return }
            }
            enterFeedback(index: index)
        } else if let next = nextReboundParticipant() {
            // Rebound hook: the question passes on. The interrupt context is
            // cleared (the rebounding side hears the full question).
            interruptCharIndex = nil
            currentParticipant = next
            emit(.reboundOffered(toParticipant: next))
            setVoiceState(.answering)
            answerWindowOpenedAt = Date()
            if options.autoListen {
                beginListening()
            }
        } else {
            enterFeedback(index: index)
        }
    }

    /// Skip the current question without an answer. No attempt is recorded,
    /// matching existing solo-practice semantics.
    public func markSkipped() {
        guard case .awaitingAnswer(let index) = state, !hasEnded, !isEvaluating else { return }
        cancelCapture(emitStopped: true)
        emit(.answerSkipped(index: index))
        enterFeedback(index: index)
    }

    /// Advance from feedback to the next question (or end the match). Returns
    /// once the next cycle is underway; narration proceeds asynchronously.
    public func next() {
        guard case .feedback = state, !hasEnded else { return }
        currentIndex += 1
        // Leave `.feedback` SYNCHRONOUSLY, before the cycle task's first await
        // (the question provider). A voice "next" and a button tap are
        // independent input paths: with the transition deferred, both passed
        // the guard, one question was skipped, and the next was presented
        // twice, the second speak throwing .alreadySpeaking.
        state = .readingQuestion(index: currentIndex)
        setVoiceState(.reading)
        cycleTask?.cancel()
        cycleTask = Task { await presentCurrentQuestion() }
    }

    /// Pause countdowns and capture (watch control plane integration point).
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
        // microphone. Reopen capture when the answer window is still the
        // engine's state.
        if options.autoListen, case .awaitingAnswer = state {
            startListening()
        }
    }

    /// End the match now. Emits the final summary and finishes the stream.
    /// The caller releases the voice session afterwards. Idempotent.
    public func stop() async {
        guard !hasEnded else { return }
        await endMatch()
    }

    // MARK: - Question Cycle

    private func presentCurrentQuestion() async {
        guard !hasEnded else { return }
        guard currentIndex < options.questionCount,
              let question = await provider(currentIndex) else {
            await endMatch()
            return
        }
        // The provider is an await: the match may have been stopped while it
        // was resolving. Presenting now would speak on a released session.
        guard !hasEnded else { return }

        currentQuestion = question
        interruptCharIndex = nil
        readingInterrupted = false
        attemptedParticipants = []
        currentParticipant = 0
        state = .readingQuestion(index: currentIndex)
        setVoiceState(.reading)
        emit(.questionPresented(index: currentIndex, question: question))

        await speak(questionUtterance(for: question))
        guard !hasEnded else { return }
        emit(.questionReadingFinished(index: currentIndex, interrupted: readingInterrupted))

        if interruptCharIndex != nil {
            // Buzz: straight to the answer window, no conference.
            openAnswerWindow()
        } else if let conference = descriptor.conference {
            runConference(conference)
        } else {
            openAnswerWindow()
        }
    }

    private func questionUtterance(for question: QuizMatchQuestion) -> Utterance {
        if let audio = question.preRenderedAudio {
            return .preRendered(audio, fallbackText: question.text)
        }
        return .text(question.text)
    }

    private func speak(_ utterance: Utterance) async {
        do {
            try await voice?.speak(utterance)
        } catch is CancellationError {
            // Interrupted by skip or buzz; the flow continues.
        } catch {
            logger.error("Narration failed: \(error.localizedDescription)")
            emit(.speakFailed(message: error.localizedDescription))
        }
    }

    // MARK: - Conference

    /// Descriptor-driven conference countdown, emitting the hands-free
    /// milestone pattern (spoken milestones at 30/15/10 seconds remaining,
    /// countdown ticks at 5 through 1). Mirrors the loop KB's oral view model
    /// ran, so consumers reproduce the exact same announcements.
    private func runConference(_ conference: QuizMatchFormatDescriptor.ConferenceRules) {
        state = .conference(index: currentIndex)
        setVoiceState(.conferring)
        emit(.conferenceStarted(seconds: conference.seconds))

        let total = conference.seconds
        guard total > 0 else {
            // A zero-length conference is over before it starts (what the old
            // `while remaining > 0` loop did, minus one scheduling hop).
            emit(.conferenceEnded(skipped: false))
            openAnswerWindow()
            return
        }

        conferenceTask = Task {
            var announced: Set<Int> = []
            // Deadline-based timing: `remaining` is read off the wall clock
            // rather than accumulated one tick at a time, so the conference
            // clock cannot drift (the old `remaining -= 0.1` loop overran by
            // 1 to 5 percent). Paused time is pushed into the deadline, so a
            // pause never consumes conference time.
            var deadline = Date().addingTimeInterval(total)
            var lastObserved = Date()
            // The highest integer second not yet walked. Starting one above
            // the total preserves the accumulating loop's first-tick
            // announcement (a 15 s conference announces its 15 s milestone on
            // the first tick, because 14.9 rounds to 15).
            var lastSecond = Int(total.rounded()) + 1

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }

                let now = Date()
                if self.isPaused {
                    deadline = deadline.addingTimeInterval(now.timeIntervalSince(lastObserved))
                    lastObserved = now
                    continue
                }
                lastObserved = now

                let remaining = deadline.timeIntervalSince(now)
                emit(.conferenceTick(remaining: max(0, remaining), progress: max(0, remaining / total)))

                // Walk EVERY integer second the clock passed on this tick. At
                // 10 Hz that is exactly one value, identical to the old loop;
                // under a busy runtime it is what keeps a wall-clock deadline
                // from skipping a milestone the tick counter could not skip.
                let secondsRemaining = Int(remaining.rounded())
                if secondsRemaining < lastSecond {
                    for value in stride(from: lastSecond - 1, through: max(secondsRemaining, 0), by: -1) {
                        guard !announced.contains(value) else { continue }
                        if [30, 15, 10].contains(value) {
                            announced.insert(value)
                            emit(.conferenceMilestone(secondsRemaining: value))
                        } else if value <= 5, value > 0 {
                            announced.insert(value)
                            emit(.conferenceCountdownTick(secondsRemaining: value))
                        }
                    }
                    lastSecond = secondsRemaining
                }

                if remaining <= 0 { break }
            }

            if !Task.isCancelled {
                self.conferenceTask = nil
                emit(.conferenceEnded(skipped: false))
                self.openAnswerWindow()
            }
        }
    }

    // MARK: - Answer Window

    private func openAnswerWindow() {
        guard !hasEnded else { return }
        state = .awaitingAnswer(index: currentIndex)
        setVoiceState(.answering)
        answerWindowOpenedAt = Date()
        emit(.answerWindowOpened(index: currentIndex))
        if options.autoListen {
            // A paused match opens the window but not the microphone;
            // `resume()` reopens capture.
            beginListening()
        }
    }

    /// The next participant eligible for a rebound, or nil when the question
    /// is dead (rebound disabled, solo play, or everyone has attempted).
    ///
    /// TODO(RFC 0005): `descriptor.buzz.lockout` is deliberately NOT consulted
    /// here. The engine always locks a participant out of a question they have
    /// already attempted. Honoring `lockout: false` (kb-colorado, UK Schools'
    /// Challenge) means a participant who answered wrong may take the question
    /// again, which with the current pass-in-slot-order rebound would offer
    /// the same participant the question forever. What "no lockout" means for
    /// rebound eligibility and termination is a format-rules decision, not an
    /// implementation detail, so it belongs in RFC 0005 (QuizMatch descriptor
    /// frictions) alongside the buzz fast path (RFC 0002 item 4) rather than
    /// being invented here.
    private func nextReboundParticipant() -> Int? {
        guard descriptor.rebound.enabled, options.participantCount > 1 else { return nil }
        switch descriptor.rebound.order {
        case .nextTeam, .open:
            // Phase 5 hook: pass in slot order. Format-specific buzz races
            // arrive with the buzz fast path (RFC 0002 item 4).
            return (0..<options.participantCount).first { !attemptedParticipants.contains($0) }
        }
    }

    // MARK: - Bonus

    private func runBonus(
        _ bonus: QuizMatchBonus,
        forQuestionAt index: Int,
        participant: Int
    ) async {
        guard let rules = descriptor.scoring.bonus, let question = currentQuestion else { return }
        let parts = Array(bonus.parts.prefix(rules.partCount))
        emit(.bonusStarted(index: index, partCount: parts.count))

        if let leadIn = bonus.leadIn {
            await speak(.text(leadIn))
        }

        var total = 0
        for (partIndex, part) in parts.enumerated() {
            guard !hasEnded else { return }
            // A pause between parts must not be followed straight into an open
            // mic; park here rather than opening capture behind a paused UI.
            await waitWhilePaused()
            guard !hasEnded else { return }
            state = .bonus(index: index, part: partIndex)
            setVoiceState(.bonus)
            await speak(.text(part.text))
            guard !hasEnded else { return }
            emit(.bonusPartPresented(part: partIndex, text: part.text))

            let partStart = Date()
            var transcript = ""
            if let voice {
                captureLoop: while true {
                    do {
                        transcript = try await captureBonusAnswer(using: voice).transcript
                        break captureLoop
                    } catch is CancellationError {
                        guard !hasEnded else { return }
                        if isPaused {
                            // Pause cancelled the capture: park, then reopen
                            // the same part's mic on resume.
                            await waitWhilePaused()
                            guard !hasEnded else { return }
                            continue captureLoop
                        }
                        // stopListening: judge what the consumer already has.
                        break captureLoop
                    } catch {
                        emit(.listenFailed(message: error.localizedDescription))
                        break captureLoop
                    }
                }
            }
            guard !hasEnded else { return }

            let result = await host.evaluation.evaluate(
                LearnerResponse(text: transcript),
                against: part.evaluation
            )
            guard !hasEnded else { return }
            let correct = result.verdict == .correct
            let points = correct ? rules.pointsPerPart : 0
            total += points
            scores[participant] += points
            emit(.bonusPartEvaluated(part: partIndex, correct: correct, points: points))
            recordBonusAttempt(
                question: question,
                part: partIndex,
                answerText: transcript,
                correct: correct,
                latencyMs: Int(Date().timeIntervalSince(partStart) * 1000)
            )
        }

        emit(.bonusCompleted(totalPoints: total))
        emit(.scoreChanged(scores: scores))
    }

    /// Capture one bonus answer through a CANCELLABLE task, so `pause()`,
    /// `stopListening()` and `stop()` can end it. Bonus capture used to call
    /// `voice.listen` directly, which nothing could cancel: the mic stayed live
    /// after a watch pause and the bonus kept scoring after the match ended.
    private func captureBonusAnswer(using voice: any VoiceSession) async throws -> UtteranceResult {
        let task = Task { try await voice.listen(expecting: .answer) }
        bonusCaptureTask = task
        defer { bonusCaptureTask = nil }
        return try await task.value
    }

    // MARK: - Progress and Telemetry

    /// The writes the KB view model previously made per attempt, now emitted
    /// by the engine for every format: a structured AttemptRecord, a mastery
    /// observation, and the required module.attempt telemetry event
    /// (MODULE_SDK_SPEC.md sections 5.4 and 5.6).
    private func recordAttempt(question: QuizMatchQuestion, judgment: QuizMatchJudgment) {
        storeAttempt(
            domain: question.domain,
            itemId: question.id,
            answerText: judgment.answerText,
            correct: judgment.isCorrect,
            latencyMs: judgment.responseTimeMs
        )
    }

    /// Bonus parts are answered attempts too. They used to bypass this path
    /// entirely, so bonus performance never reached the ProgressStore or the
    /// required module.attempt telemetry. The item id is namespaced under the
    /// parent question so the trail stays unambiguous.
    private func recordBonusAttempt(
        question: QuizMatchQuestion,
        part: Int,
        answerText: String,
        correct: Bool,
        latencyMs: Int
    ) {
        storeAttempt(
            domain: question.domain,
            itemId: "\(question.id)#bonus\(part)",
            answerText: answerText,
            correct: correct,
            latencyMs: latencyMs
        )
    }

    private func storeAttempt(
        domain rawDomain: String?,
        itemId: String,
        answerText: String,
        correct: Bool,
        latencyMs: Int
    ) {
        let domain = StandardDomain(rawDomain ?? "general")
        let record = AttemptRecord(
            module: host.moduleId,
            domain: domain,
            itemId: itemId,
            response: answerText,
            correct: correct,
            latencyMs: latencyMs
        )
        let observation = MasteryObservation(
            module: host.moduleId,
            domain: domain,
            signal: correct ? 100 : 0
        )
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
    /// terminal event so a consumer reading the ProgressStore on `matchEnded`
    /// sees a complete attempt trail instead of racing the writes.
    private func flushAttemptWrites() async {
        while let task = attemptWrites {
            await task.value
            // A write queued while we waited replaces the handle; loop until
            // the chain is genuinely drained.
            if attemptWrites == task { attemptWrites = nil }
        }
    }

    // MARK: - Match End

    /// Idempotent: the first call wins, later ones (a second stop, a stop that
    /// races the last question) do nothing.
    private func endMatch() async {
        guard !hasEnded else { return }
        hasEnded = true
        conferenceTask?.cancel()
        conferenceTask = nil
        cancelCapture(emitStopped: false)
        cycleTask?.cancel()
        cycleTask = nil
        state = .ended
        setVoiceState(.ended)

        // The attempt trail must be COMPLETE when the terminal event lands.
        // These writes used to be fire-and-forget, so a consumer (or the
        // conformance suite) reading attempts on `matchEnded` raced them and
        // had to poll.
        await flushAttemptWrites()

        let summary = QuizMatchSummary(
            scores: scores,
            answeredQuestions: answeredQuestionIndices.count,
            correctAnswers: correctCount,
            duration: matchStart.map { Date().timeIntervalSince($0) } ?? 0
        )
        emit(.matchEnded(summary: summary))
        eventContinuation.finish()
    }

    // MARK: - Emission

    private func emit(_ event: QuizMatchEvent) {
        eventContinuation.yield(event)
    }
}

// MARK: - Descriptor-Derived Pipeline Configuration

extension QuizMatchFormatDescriptor {
    /// The voice pipeline configuration this format calls for: endpointing
    /// and answer timeout from the oral rules, conference timing, and the
    /// buzz mode. The module passes this to `VoiceSessionService.acquire`.
    public func voicePipelineConfig(
        locale: Locale = Locale(identifier: "en-US"),
        bargeIn: BargeInPolicy = .off
    ) -> VoicePipelineConfig {
        let endpointing = EndpointingPolicy(
            silenceThreshold: oral?.answerSilenceSec ?? EndpointingPolicy.default.silenceThreshold,
            maxUtteranceDuration: oral?.maxUtteranceSec ?? EndpointingPolicy.default.maxUtteranceDuration
        )
        let buzzMode: BuzzMode? = {
            guard phases.contains(.oral) else { return nil }
            if buzz.recognitionRequired { return .recognitionRequired }
            switch buzz.mode {
            case .team: return .team
            case .individual: return .individual
            }
        }()
        return VoicePipelineConfig(
            locale: locale,
            endpointing: endpointing,
            bargeIn: bargeIn,
            buzzMode: buzzMode,
            answerTimeout: oral?.answerTimeoutSec.map { .seconds($0) },
            conference: conference.map {
                ConferenceConfig(duration: $0.seconds)
            }
        )
    }
}
