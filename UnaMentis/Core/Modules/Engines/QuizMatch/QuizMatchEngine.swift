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

    private var voice: (any VoiceSession)?
    private var scores: [Int]
    private var currentIndex = 0
    private var currentQuestion: QuizMatchQuestion?
    private var matchStart: Date?
    private var answeredCount = 0
    private var correctCount = 0

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
    private var isListening = false

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
        guard state == .idle else { return }
        self.voice = voice
        matchStart = Date()
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
        guard case .conference = state else { return }
        conferenceTask?.cancel()
        conferenceTask = nil
        emit(.conferenceEnded(skipped: true))
        openAnswerWindow()
    }

    /// Start capturing one spoken answer. No-op unless the answer window is
    /// open and the engine is not already listening.
    public func startListening() {
        guard case .awaitingAnswer(let index) = state, !isListening else { return }
        guard let voice else {
            emit(.listenFailed(message: "Voice session unavailable"))
            return
        }
        isListening = true
        emit(.listeningStarted(index: index))
        listenTask = Task {
            do {
                let result = try await voice.listen(expecting: .answer)
                self.isListening = false
                emit(.answerCaptured(transcript: result.transcript))
            } catch is CancellationError {
                self.isListening = false
                emit(.listeningStopped(index: index))
            } catch {
                self.isListening = false
                emit(.listenFailed(message: error.localizedDescription))
            }
            self.listenTask = nil
        }
    }

    /// Stop capturing without submitting (the consumer keeps any partial
    /// transcript it observed).
    public func stopListening() {
        listenTask?.cancel()
    }

    /// Submit an answer for evaluation. Covers both the spoken path (the
    /// consumer passes the captured transcript) and the text path.
    public func submitAnswer(_ text: String, participant: Int? = nil) async {
        guard case .awaitingAnswer(let index) = state, let question = currentQuestion else { return }
        listenTask?.cancel()

        let answeringParticipant = min(max(participant ?? currentParticipant, 0), scores.count - 1)
        let responseTime = answerWindowOpenedAt.map { Date().timeIntervalSince($0) } ?? 0
        let responseTimeMs = Int(responseTime * 1000)

        let result = await host.evaluation.evaluate(
            LearnerResponse(text: text),
            against: question.evaluation
        )
        let correct = result.verdict == .correct

        // Interrupt context: this answer came from a buzz before the question
        // finished. Powers and negs only apply to interrupts.
        let wasInterrupt = interruptCharIndex != nil
        let wasPower = correct
            && descriptor.questionForm == .pyramidal
            && descriptor.scoring.power != nil
            && wasInterrupt
            && (interruptCharIndex ?? .max) < (question.powerMarkIndex ?? .max)

        let points: Int
        if correct {
            points = wasPower ? (descriptor.scoring.power ?? descriptor.scoring.correct)
                              : descriptor.scoring.correct
        } else {
            points = wasInterrupt ? descriptor.scoring.incorrect : 0
        }

        scores[answeringParticipant] += points
        answeredCount += 1
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
            }
            state = .feedback(index: index)
        } else if let next = nextReboundParticipant() {
            // Rebound hook: the question passes on. The interrupt context is
            // cleared (the rebounding side hears the full question).
            interruptCharIndex = nil
            currentParticipant = next
            emit(.reboundOffered(toParticipant: next))
            answerWindowOpenedAt = Date()
            if options.autoListen {
                startListening()
            }
        } else {
            state = .feedback(index: index)
        }
    }

    /// Skip the current question without an answer. No attempt is recorded,
    /// matching existing solo-practice semantics.
    public func markSkipped() {
        guard case .awaitingAnswer(let index) = state else { return }
        listenTask?.cancel()
        emit(.answerSkipped(index: index))
        state = .feedback(index: index)
    }

    /// Advance from feedback to the next question (or end the match). Returns
    /// once the next cycle is underway; narration proceeds asynchronously.
    public func next() {
        guard case .feedback = state else { return }
        currentIndex += 1
        cycleTask = Task { await presentCurrentQuestion() }
    }

    /// Pause countdowns and capture (watch control plane integration point).
    public func pause() {
        guard !isPaused, state != .ended else { return }
        isPaused = true
        listenTask?.cancel()
        emit(.paused)
    }

    public func resume() {
        guard isPaused else { return }
        isPaused = false
        emit(.resumed)
    }

    /// End the match now. Emits the final summary and finishes the stream.
    /// The caller releases the voice session afterwards.
    public func stop() {
        guard state != .ended else { return }
        endMatch()
    }

    // MARK: - Question Cycle

    private func presentCurrentQuestion() async {
        guard state != .ended else { return }
        guard currentIndex < options.questionCount,
              let question = await provider(currentIndex) else {
            endMatch()
            return
        }

        currentQuestion = question
        interruptCharIndex = nil
        readingInterrupted = false
        attemptedParticipants = []
        currentParticipant = 0
        state = .readingQuestion(index: currentIndex)
        emit(.questionPresented(index: currentIndex, question: question))

        await speak(questionUtterance(for: question))
        guard state != .ended else { return }
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
        emit(.conferenceStarted(seconds: conference.seconds))

        conferenceTask = Task {
            let total = conference.seconds
            var remaining = total
            var announced: Set<Int> = []

            while remaining > 0 && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }
                if self.isPaused { continue }

                remaining -= 0.1
                emit(.conferenceTick(remaining: max(0, remaining), progress: max(0, remaining / total)))

                let secondsRemaining = Int(remaining.rounded())
                if [30, 15, 10].contains(secondsRemaining), !announced.contains(secondsRemaining) {
                    announced.insert(secondsRemaining)
                    emit(.conferenceMilestone(secondsRemaining: secondsRemaining))
                } else if secondsRemaining <= 5, secondsRemaining > 0, !announced.contains(secondsRemaining) {
                    announced.insert(secondsRemaining)
                    emit(.conferenceCountdownTick(secondsRemaining: secondsRemaining))
                }
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
        guard state != .ended else { return }
        state = .awaitingAnswer(index: currentIndex)
        answerWindowOpenedAt = Date()
        emit(.answerWindowOpened(index: currentIndex))
        if options.autoListen {
            startListening()
        }
    }

    /// The next participant eligible for a rebound, or nil when the question
    /// is dead (rebound disabled, solo play, or everyone has attempted).
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
        guard let rules = descriptor.scoring.bonus else { return }
        let parts = Array(bonus.parts.prefix(rules.partCount))
        emit(.bonusStarted(index: index, partCount: parts.count))

        if let leadIn = bonus.leadIn {
            await speak(.text(leadIn))
        }

        var total = 0
        for (partIndex, part) in parts.enumerated() {
            guard state != .ended else { return }
            state = .bonus(index: index, part: partIndex)
            await speak(.text(part.text))
            emit(.bonusPartPresented(part: partIndex, text: part.text))

            var transcript = ""
            if let voice {
                do {
                    transcript = try await voice.listen(expecting: .answer).transcript
                } catch {
                    emit(.listenFailed(message: error.localizedDescription))
                }
            }

            let result = await host.evaluation.evaluate(
                LearnerResponse(text: transcript),
                against: part.evaluation
            )
            let correct = result.verdict == .correct
            let points = correct ? rules.pointsPerPart : 0
            total += points
            scores[participant] += points
            emit(.bonusPartEvaluated(part: partIndex, correct: correct, points: points))
        }

        emit(.bonusCompleted(totalPoints: total))
        emit(.scoreChanged(scores: scores))
    }

    // MARK: - Progress and Telemetry

    /// The writes the KB view model previously made per attempt, now emitted
    /// by the engine for every format: a structured AttemptRecord, a mastery
    /// observation, and the required module.attempt telemetry event
    /// (MODULE_SDK_SPEC.md sections 5.4 and 5.6).
    private func recordAttempt(question: QuizMatchQuestion, judgment: QuizMatchJudgment) {
        let domain = StandardDomain(question.domain ?? "general")
        let record = AttemptRecord(
            module: host.moduleId,
            domain: domain,
            itemId: question.id,
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
        Task { [host] in
            await host.progress.store(record)
            await host.progress.reportMastery(observation)
            await host.telemetry.record(
                .attempt(outcome: correct ? .correct : .incorrect, latencyMs: latencyMs),
                module: host.moduleId
            )
        }
    }

    // MARK: - Match End

    private func endMatch() {
        conferenceTask?.cancel()
        conferenceTask = nil
        listenTask?.cancel()
        listenTask = nil
        cycleTask?.cancel()
        cycleTask = nil
        state = .ended

        let summary = QuizMatchSummary(
            scores: scores,
            answeredQuestions: answeredCount,
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
