// UnaMentis - Oral Exam Engine
// MODULE_SDK_SPEC.md section 6.2, engine "oral-exam/1"
//
// The generic, descriptor-driven oral examination state machine: timed
// preparation, timed presentation (long-form monologue capture), adaptive
// questioning grounded in the syllabus item and the learner's own words, and
// rubric feedback. One engine, many exam formats: Grand Oral, Maturita,
// Matura, and interview formats are data (OralExamFormatDescriptor), not code.
//
// Boundaries, deliberate (the QuizMatchEngine pattern):
// - ZERO knowledge of any specific module. Topics arrive as OralExamTopic
//   values; modules adapt their pack items to the engine, never the reverse.
// - UI-agnostic. The engine emits OralExamEvents on an AsyncStream (single
//   consumer) and exposes command methods; a module view model renders events
//   and forwards user intents (taps and voice commands).
// - The engine does not own the voice pipeline. The module acquires the
//   exclusive VoiceSession (with descriptor-derived long-form endpointing via
//   `OralExamFormatDescriptor.voicePipelineConfig`) and hands it to
//   `start(voice:)`; the module remains responsible for release. The engine
//   does not consume `voice.events` (single-consumer stream): partial
//   transcripts and recognized commands stay with the module, which calls
//   engine commands (endStage/skipQuestion/pause/stop).
// - Question generation and rubric scoring are delegated to the injected
//   ExaminerBrain; the engine computes delivery metrics itself from transcript
//   timing (OralExamDeliveryAnalyzer) because the module spec says the LLM
//   never produces them.
// - Progress and telemetry are emitted per answered examiner question through
//   the injected OralExamHostContext (AttemptRecord + module.attempt), plus
//   one rubric-driven mastery observation at feedback time. Note on attempt
//   semantics: an oral exchange has no correct/incorrect verdict, so an
//   answered question records `correct: true` (participation) and mastery
//   carries the actual quality signal (average rubric score). Spec 6.2 is
//   silent on attempt semantics for oral formats; flagged for the RFC process.
//
// Timer milestones follow the hands-free countdown pattern QuizMatchEngine
// established for conference timing (spoken milestones, then 5-1 ticks),
// extended upward (300/120/60 seconds) because exam stages run minutes, not
// seconds.

import Foundation
import OSLog

public actor OralExamEngine {
    // MARK: - Configuration

    private let descriptor: OralExamFormatDescriptor
    private let mode: OralExamSessionMode
    private let options: OralExamSessionOptions
    private let host: OralExamHostContext
    private let examiner: any ExaminerBrain
    private let topic: OralExamTopic

    /// The stages this session runs, derived from mode and descriptor.
    private let activeStages: [OralExamFormatDescriptor.Stage]

    // MARK: - Events

    /// The engine's event stream. Single consumer.
    public nonisolated let events: AsyncStream<OralExamEvent>
    private nonisolated let eventContinuation: AsyncStream<OralExamEvent>.Continuation

    // MARK: - State

    public private(set) var state: OralExamEngineState = .idle

    private var voice: (any VoiceSession)?
    private var sessionStartDate: Date?

    private var segments: [OralExamCapturedSegment] = []
    private var presentationTranscript = ""
    private var exchanges: [OralExamExchange] = []
    private var feedback: OralExamFeedback?

    private var stagesCompleted = 0
    private var questionsAsked = 0
    private var responsesCaptured = 0

    private enum StageEndCause { case timer, command, volleyComplete, failure }
    private var stageEndRequested = false
    private var stageEndCause: StageEndCause?
    private var skipRequested = false
    private var stopRequested = false
    private var isPaused = false
    private var hasEnded = false

    /// Consecutive failed or empty captures within the current stage. Reset per
    /// stage and on every successful capture; bounds the questioning loop so a
    /// dead audio route cannot spin examiner calls for the rest of the stage.
    private var consecutiveCaptureFailures = 0

    /// The module voice state last published to the host, so repeats are not
    /// re-sent.
    private var publishedVoiceState: ModuleVoiceState?

    /// Serializes voice-state publication, so phases reach the host in the
    /// order the engine entered them.
    private var voiceStateTask: Task<Void, Never>?

    private var sessionTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var listenTask: Task<UtteranceResult, Error>?
    private var rubricTask: Task<RubricFeedback, Error>?

    private let logger = Logger(subsystem: "com.unamentis", category: "OralExamEngine")

    // MARK: - Init

    public init(
        descriptor: OralExamFormatDescriptor,
        mode: OralExamSessionMode,
        options: OralExamSessionOptions,
        topic: OralExamTopic,
        host: OralExamHostContext,
        examiner: any ExaminerBrain
    ) {
        self.descriptor = descriptor
        self.mode = mode
        self.options = options
        self.topic = topic
        self.host = host
        self.examiner = examiner
        self.activeStages = Self.stages(for: mode, in: descriptor)

        var continuation: AsyncStream<OralExamEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.eventContinuation = continuation
    }

    /// The stages a session mode selects out of the descriptor.
    static func stages(
        for mode: OralExamSessionMode,
        in descriptor: OralExamFormatDescriptor
    ) -> [OralExamFormatDescriptor.Stage] {
        switch mode {
        case .fullSimulation:
            return descriptor.stages
        case .stagePractice(let kind):
            if let stage = descriptor.stage(ofKind: kind) { return [stage] }
            return []
        case .questionVolley:
            if let stage = descriptor.stage(ofKind: .questioning) { return [stage] }
            // A volley works even for formats without a questioning stage.
            return [.init(kind: .questioning, seconds: 600, style: "volley", followUpDepth: 2)]
        }
    }

    // MARK: - Commands

    /// Begin the session on an already-acquired voice session. The caller
    /// keeps ownership of the session and releases it after the session ends.
    /// A nil session runs the stage flow without narration or capture;
    /// capture stages end immediately with a surfaced `listenFailed`.
    public func start(voice: (any VoiceSession)?) {
        guard state == .idle, sessionTask == nil, !hasEnded else { return }
        self.voice = voice
        sessionTask = Task { await runSession() }
    }

    /// End the current stage early ("ready" during preparation, "done" after
    /// a presentation). No-op between stages.
    public func endStage() {
        requestStageEnd(cause: .command)
    }

    /// Drop the current examiner question without recording an attempt (the
    /// "skip" command). The engine moves on to the next root question.
    public func skipQuestion() {
        guard !hasEnded else { return }
        skipRequested = true
        listenTask?.cancel()
    }

    /// Pause the stage clock and any in-flight capture (watch control plane
    /// integration point).
    public func pause() {
        guard !isPaused, !hasEnded else { return }
        isPaused = true
        listenTask?.cancel()
        emit(.paused)
    }

    public func resume() {
        guard isPaused else { return }
        isPaused = false
        emit(.resumed)
    }

    /// End the session now. Emits the final summary and finishes the stream.
    /// The caller releases the voice session afterwards.
    public func stop() {
        guard !hasEnded else { return }
        stopRequested = true
        listenTask?.cancel()
        timerTask?.cancel()
        // A stop during rubric assembly must not wait out an LLM round trip:
        // without this the stream stayed open until the model answered, and
        // the session still emitted feedback and spoke a summary afterwards.
        rubricTask?.cancel()
        if sessionTask == nil {
            finishSession()
        }
    }

    // MARK: - Session Flow

    private func runSession() async {
        sessionStartDate = Date()
        emit(.sessionStarted(stageCount: activeStages.count))

        for (index, stage) in activeStages.enumerated() {
            guard !stopRequested else { break }
            await runStage(stage, index: index)
            if !stopRequested {
                stagesCompleted += 1
            }
        }

        if !stopRequested {
            await assembleFeedback()
        }
        finishSession()
    }

    private func runStage(_ stage: OralExamFormatDescriptor.Stage, index: Int) async {
        stageEndRequested = false
        stageEndCause = nil
        // A skip that arrived during a previous stage (say during preparation)
        // used to survive into this one and silently consume its first
        // question. Skips are scoped to the stage that received them.
        skipRequested = false
        consecutiveCaptureFailures = 0
        let seconds = stage.seconds * options.timeScale

        switch stage.kind {
        case .preparation:
            state = .preparing(stageIndex: index)
            setVoiceState(.preparing)
        case .presentation:
            state = .presenting(stageIndex: index)
            setVoiceState(.presenting)
        case .questioning:
            state = .questioning(stageIndex: index)
            setVoiceState(.questioning)
        }
        emit(.stageStarted(index: index, kind: stage.kind, seconds: seconds))
        startStageTimer(seconds: seconds)

        switch stage.kind {
        case .preparation:
            await speakPrompt(Self.preparationIntro(topic: topic, seconds: seconds), personaIndex: 0)
            await waitForStageEnd()
        case .presentation:
            await speakPrompt(Self.presentationIntro(topic: topic, stage: stage), personaIndex: 0)
            await runPresentationCapture(stageIndex: index)
        case .questioning:
            await runQuestioning(stage, stageIndex: index)
        }

        timerTask?.cancel()
        timerTask = nil
        let endedEarly = stageEndCause != .timer
        emit(.stageEnded(index: index, kind: stage.kind, endedEarly: endedEarly))
    }

    // MARK: - Stage Timer

    /// Spoken-milestone seconds (hands-free pattern, extended for long exam
    /// stages). Final-countdown ticks cover 5 through 1.
    static let milestoneSeconds: Set<Int> = [300, 120, 60, 30, 15, 10]

    private func startStageTimer(seconds: TimeInterval) {
        // A non-positive stage duration (a descriptor typo, or a timeScale that
        // rounds a stage away) used to create no timer at all, and nothing else
        // ever ended the stage: `waitForStageEnd` busy-polled forever, and a
        // fullSimulation questioning stage (maxRoots = Int.max) asked questions
        // forever while holding the exclusive voice pipeline. Treat it as a
        // stage whose clock has already expired.
        //
        // The alternative, rejecting `seconds <= 0` at descriptor decode, was
        // deliberately not chosen: it would fail an entire bundled format at
        // load time over one bad stage, turning a recoverable data defect into
        // a module that cannot start at all.
        guard seconds > 0 else {
            logger.warning("Stage duration \(seconds) is not positive; the stage completes immediately.")
            requestStageEnd(cause: .timer)
            return
        }
        timerTask = Task {
            let total = seconds
            let totalSeconds = Int(total.rounded())
            var announced: Set<Int> = []
            let tick = 0.1
            let sleepNanoseconds = UInt64(tick / options.clockRate * 1_000_000_000)

            // Deadline-based timing: `remaining` is read off the wall clock
            // (scaled by the session clock rate) rather than accumulated one
            // tick at a time, so a long stage clock cannot drift. The old
            // `remaining -= tick` loop overran by 1 to 5 percent, which is 12
            // to 60 seconds on a 1200 s Grand Oral preparation stage. Paused
            // time is pushed into the deadline, so a pause never consumes
            // stage time.
            var deadline = Date().addingTimeInterval(total / options.clockRate)
            var lastObserved = Date()
            // The highest integer second not yet walked.
            var lastSecond = totalSeconds + 1

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: sleepNanoseconds)
                if Task.isCancelled { return }

                let now = Date()
                if self.isPaused {
                    deadline = deadline.addingTimeInterval(now.timeIntervalSince(lastObserved))
                    lastObserved = now
                    continue
                }
                lastObserved = now

                let remaining = deadline.timeIntervalSince(now) * options.clockRate
                emit(.timerTick(remaining: max(0, remaining), progress: max(0, remaining / total)))

                // Walk EVERY integer second the clock passed on this tick. At
                // one tick per 0.1 stage-second that is exactly one value,
                // identical to the old loop; under a busy runtime (or a
                // heavily accelerated clock) it is what keeps a wall-clock
                // deadline from skipping a milestone the tick counter could
                // not skip. Announcement rules are unchanged.
                let secondsRemaining = Int(remaining.rounded())
                if secondsRemaining < lastSecond {
                    for value in stride(from: lastSecond - 1, through: max(secondsRemaining, 0), by: -1) {
                        guard value < totalSeconds, !announced.contains(value) else { continue }
                        if Self.milestoneSeconds.contains(value) {
                            announced.insert(value)
                            emit(.timerMilestone(secondsRemaining: value))
                        } else if value <= 5, value > 0 {
                            announced.insert(value)
                            emit(.timerCountdownTick(secondsRemaining: value))
                        }
                    }
                    lastSecond = secondsRemaining
                }

                if remaining <= 0 { break }
            }

            if !Task.isCancelled {
                self.requestStageEnd(cause: .timer)
            }
        }
    }

    private func requestStageEnd(cause: StageEndCause) {
        guard !stageEndRequested, !hasEnded else { return }
        stageEndRequested = true
        stageEndCause = cause
        listenTask?.cancel()
    }

    private func waitForStageEnd() async {
        while !stageEndRequested && !stopRequested {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func waitWhilePaused() async {
        while isPaused && !stopRequested {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Presentation Capture

    /// Long-form monologue capture: listen continuously, recording each
    /// utterance segment (with timing, for delivery metrics) until the stage
    /// clock expires or the learner ends the stage.
    private func runPresentationCapture(stageIndex: Int) async {
        guard voice != nil else {
            emit(.listenFailed(message: "Voice session unavailable"))
            requestStageEnd(cause: .failure)
            return
        }

        while !stageEndRequested && !stopRequested {
            // A pause that arrived while the engine was between segments
            // cancels nothing, so park HERE, immediately before capture, or the
            // mic opens while the UI says paused.
            await waitWhilePaused()
            guard !stageEndRequested, !stopRequested else { break }

            setVoiceState(.answering)
            emit(.listeningStarted(stageIndex: stageIndex))
            let segmentStart = elapsed()
            do {
                let result = try await capture(.freeform)
                let segment = OralExamCapturedSegment(
                    transcript: result.transcript,
                    start: segmentStart,
                    end: elapsed(),
                    endedBy: result.endedBy
                )
                if !result.transcript.isEmpty {
                    recordSegment(segment, stageIndex: stageIndex, isPresentation: true)
                }
            } catch is CancellationError {
                if isPaused && !stageEndRequested && !stopRequested {
                    await waitWhilePaused()
                    continue
                }
                break
            } catch {
                emit(.listenFailed(message: error.localizedDescription))
                requestStageEnd(cause: .failure)
                break
            }
        }
    }

    // MARK: - Questioning

    private func runQuestioning(_ stage: OralExamFormatDescriptor.Stage, stageIndex: Int) async {
        guard voice != nil else {
            emit(.listenFailed(message: "Voice session unavailable"))
            requestStageEnd(cause: .failure)
            return
        }

        await speakPrompt(Self.questioningIntro(stage: stage), personaIndex: 0)

        let followUps = max(0, stage.followUpDepth ?? 0)
        let maxRoots: Int
        if case .questionVolley(let roots) = mode {
            maxRoots = max(1, roots)
        } else {
            maxRoots = Int.max
        }

        var roots = 0
        rootLoop: while roots < maxRoots && !stageEndRequested && !stopRequested {
            let answered = await askAndCapture(depth: 0, stageIndex: stageIndex)
            roots += 1
            if answered, followUps > 0 {
                for depth in 1...followUps {
                    guard !stageEndRequested && !stopRequested else { break rootLoop }
                    guard await askAndCapture(depth: depth, stageIndex: stageIndex) else { break }
                }
            }
        }

        if roots >= maxRoots && !stageEndRequested {
            requestStageEnd(cause: .volleyComplete)
        }
    }

    /// Ask one examiner question (root or follow-up), capture the answer,
    /// record the exchange and the attempt. Returns true when an answer was
    /// captured and follow-ups may proceed.
    private func askAndCapture(depth: Int, stageIndex: Int) async -> Bool {
        guard !stageEndRequested, !stopRequested else { return false }
        if skipRequested {
            // A skip that arrived between questions consumes this question.
            skipRequested = false
            return false
        }

        let context = examinerContext(followUpDepth: depth)
        let question: ExaminerQuestion
        do {
            question = try await examiner.nextQuestion(context)
        } catch {
            emit(.examinerFailed(message: error.localizedDescription))
            requestStageEnd(cause: .failure)
            return false
        }

        questionsAsked += 1
        setVoiceState(.questioning)
        if depth == 0 {
            emit(.promptSpoken(text: question.text, personaIndex: question.personaIndex))
        } else {
            emit(.followUpAsked(question: question.text, depth: depth, personaIndex: question.personaIndex))
        }
        await speak(.text(question.text))

        let result: UtteranceResult
        // Reset per attempt: paused time must not count into the segment (which
        // would deflate words per minute) or into the recorded answer latency.
        // runPresentationCapture already recomputes its segment start after a
        // pause; this keeps the two consistent.
        var askStart = elapsed()
        captureLoop: while true {
            // A pause arriving while the examiner was thinking, while the
            // question was being spoken, or between stages cancels nothing, so
            // check HERE, immediately before opening the mic.
            await waitWhilePaused()
            guard !stageEndRequested, !stopRequested else { return false }
            if skipRequested {
                skipRequested = false
                return false
            }

            askStart = elapsed()
            setVoiceState(.answering)
            emit(.listeningStarted(stageIndex: stageIndex))
            do {
                result = try await capture(.freeform)
                break captureLoop
            } catch is CancellationError {
                if skipRequested {
                    skipRequested = false
                    return false
                }
                if isPaused && !stageEndRequested && !stopRequested {
                    continue captureLoop
                }
                return false
            } catch {
                // Unlike runPresentationCapture, this path used to return
                // without requesting stage end, so a dead audio route left the
                // questioning loop spinning examiner.nextQuestion (a live,
                // metered LLM call) plus speak plus listen for the rest of the
                // stage. Bound it.
                emit(.listenFailed(message: error.localizedDescription))
                return await noteCaptureFailure()
            }
        }

        let segment = OralExamCapturedSegment(
            transcript: result.transcript,
            start: askStart,
            end: elapsed(),
            endedBy: result.endedBy
        )
        // An empty transcript is a capture that produced nothing: counted and
        // backed off exactly like a failure, so silence cannot spin the loop.
        guard !result.transcript.isEmpty else { return await noteCaptureFailure() }
        consecutiveCaptureFailures = 0

        recordSegment(segment, stageIndex: stageIndex, isPresentation: false)
        exchanges.append(OralExamExchange(
            question: question.text,
            answer: result.transcript,
            followUpDepth: depth
        ))
        await recordAttempt(answer: result.transcript, latencyMs: Int((elapsed() - askStart) * 1000))
        return true
    }

    /// How many consecutive failed or empty captures a stage tolerates before
    /// the engine gives the stage up.
    static let maxConsecutiveCaptureFailures = 3

    /// Record one failed or empty capture, end the stage once they pile up, and
    /// otherwise back off. Always returns false: the question was not answered.
    private func noteCaptureFailure() async -> Bool {
        consecutiveCaptureFailures += 1
        guard consecutiveCaptureFailures < Self.maxConsecutiveCaptureFailures else {
            requestStageEnd(cause: .failure)
            return false
        }
        // Linear back-off, scaled by the session clock so accelerated headless
        // runs do not wait out real seconds.
        let seconds = 0.25 * Double(consecutiveCaptureFailures) / options.clockRate
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return false
    }

    // MARK: - Feedback

    private func assembleFeedback() async {
        guard responsesCaptured > 0, !stopRequested, !hasEnded else { return }
        state = .assemblingFeedback
        setVoiceState(.feedback)

        let metrics = OralExamDeliveryAnalyzer.metrics(
            from: segments,
            silenceThreshold: descriptor.responseSilenceSeconds
        )

        let context = examinerContext(followUpDepth: 0)
        do {
            let rubricFeedback = try await evaluateRubric(context: context, metrics: metrics)
            // stop() may have landed while the rubric call was in flight (an
            // LLM round trip). A stopped session must not emit feedback, write
            // mastery, or speak a summary over a session the caller is about
            // to release.
            guard !stopRequested, !hasEnded else { return }
            let assembled = OralExamFeedback(
                scores: rubricFeedback.scores,
                spokenSummary: rubricFeedback.spokenSummary,
                deliveryMetrics: metrics
            )
            feedback = assembled
            emit(.feedbackReady(assembled))

            // The rubric average is the mastery signal; per-question attempts
            // only record participation (see the header note).
            await host.progress.reportMastery(MasteryObservation(
                module: host.moduleId,
                domain: attemptDomain,
                signal: assembled.averageScore / 5.0 * 100.0
            ))

            if options.speakFeedbackSummary {
                await speak(.text(rubricFeedback.spokenSummary))
            }
        } catch is CancellationError {
            // stop() cancelled the rubric call; the session ends without
            // feedback rather than waiting the model out.
        } catch {
            guard !stopRequested, !hasEnded else { return }
            emit(.examinerFailed(message: error.localizedDescription))
        }
    }

    /// Run the rubric evaluation through a CANCELLABLE task so `stop()` can
    /// abort it. Called inline, exactly like `capture`.
    private func evaluateRubric(
        context: ExaminerContext,
        metrics: OralExamDeliveryMetrics
    ) async throws -> RubricFeedback {
        let task = Task { [examiner, descriptor] in
            try await examiner.evaluateRubric(
                context,
                rubric: descriptor.rubric,
                deliveryMetrics: metrics
            )
        }
        rubricTask = task
        defer { rubricTask = nil }
        return try await task.value
    }

    // MARK: - Session End

    private func finishSession() {
        guard !hasEnded else { return }
        hasEnded = true
        timerTask?.cancel()
        timerTask = nil
        listenTask?.cancel()
        listenTask = nil
        rubricTask?.cancel()
        rubricTask = nil
        state = .ended
        setVoiceState(.ended)

        let summary = OralExamSummary(
            stagesCompleted: stagesCompleted,
            questionsAsked: questionsAsked,
            responsesCaptured: responsesCaptured,
            duration: sessionStartDate.map { Date().timeIntervalSince($0) } ?? 0,
            feedback: feedback
        )
        emit(.sessionEnded(summary: summary))
        eventContinuation.finish()
    }

    // MARK: - Module Voice State

    /// The module voice states this engine drives. The host scopes its command
    /// vocabulary by the ACTIVE state, so an engine that never publishes one
    /// leaves that vocabulary inert in production: the session cannot tell
    /// which phase the activity is in, and state-valid command filtering cannot
    /// work. Names match QuizMatchEngine and DrillEngine for the phases the
    /// three share (`answering`, `feedback`, `ended`).
    enum VoicePhase: String {
        case preparing
        case presenting
        case questioning
        case answering
        case feedback
        case ended
    }

    /// Publish the active module voice state to the host (spec 5.1). Serialized
    /// through one task chain so phases arrive in the order the engine entered
    /// them, even when published from a synchronous path.
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

    // MARK: - Capture Plumbing

    private func capture(_ expectation: ListenExpectation) async throws -> UtteranceResult {
        guard let voice else { throw OralExamEngineError.voiceUnavailable }
        let task = Task { try await voice.listen(expecting: expectation) }
        listenTask = task
        defer { listenTask = nil }
        return try await task.value
    }

    private func recordSegment(
        _ segment: OralExamCapturedSegment,
        stageIndex: Int,
        isPresentation: Bool
    ) {
        segments.append(segment)
        responsesCaptured += 1
        if isPresentation {
            presentationTranscript = presentationTranscript.isEmpty
                ? segment.transcript
                : presentationTranscript + " " + segment.transcript
        }
        emit(.responseCaptured(
            stageIndex: stageIndex,
            transcript: segment.transcript,
            endedBy: segment.endedBy
        ))
    }

    // MARK: - Speech

    private func speakPrompt(_ text: String, personaIndex: Int) async {
        emit(.promptSpoken(text: text, personaIndex: personaIndex))
        await speak(.text(text))
    }

    private func speak(_ utterance: Utterance) async {
        do {
            try await voice?.speak(utterance)
        } catch is CancellationError {
            // Interrupted; the flow continues.
        } catch {
            logger.error("Oral exam narration failed: \(error.localizedDescription)")
            emit(.speakFailed(message: error.localizedDescription))
        }
    }

    // MARK: - Progress and Telemetry

    private var attemptDomain: StandardDomain {
        StandardDomain(topic.domain ?? "oral-exam")
    }

    /// The writes QuizMatchEngine makes per evaluated answer, adapted to oral
    /// semantics: an answered examiner question records participation
    /// (`correct: true`) plus the required module.attempt telemetry; quality
    /// flows through the rubric mastery observation at feedback time. Awaited
    /// inline (the stores are fast and local) so the attempt trail is complete
    /// the moment the session ends.
    private func recordAttempt(answer: String, latencyMs: Int) async {
        let record = AttemptRecord(
            module: host.moduleId,
            domain: attemptDomain,
            itemId: "\(topic.id)#q\(questionsAsked)",
            response: answer,
            correct: true,
            latencyMs: latencyMs
        )
        await host.progress.store(record)
        await host.telemetry.record(
            .attempt(outcome: .correct, latencyMs: latencyMs),
            module: host.moduleId
        )
    }

    // MARK: - Helpers

    private func examinerContext(followUpDepth: Int) -> ExaminerContext {
        ExaminerContext(
            topic: topic,
            language: descriptor.language,
            register: descriptor.examiner.register,
            personaCount: descriptor.examiner.personaCount,
            presentationTranscript: presentationTranscript,
            exchange: exchanges,
            followUpDepth: followUpDepth
        )
    }

    private func elapsed() -> TimeInterval {
        guard let sessionStartDate else { return 0 }
        return Date().timeIntervalSince(sessionStartDate)
    }

    private func emit(_ event: OralExamEvent) {
        eventContinuation.yield(event)
    }

    // MARK: - Stage Intros

    static func preparationIntro(topic: OralExamTopic, seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        let duration = minutes >= 1 ? "\(minutes) minute\(minutes == 1 ? "" : "s")" : "\(Int(seconds)) seconds"
        return "You have \(duration) to prepare your presentation on \(topic.title). "
            + "Say ready when you want to begin early."
    }

    static func presentationIntro(topic: OralExamTopic, stage: OralExamFormatDescriptor.Stage) -> String {
        var intro = "Begin your presentation on \(topic.title) when you are ready. "
            + "Say done when you have finished."
        if stage.notesAllowed == false {
            intro += " Notes are not allowed in this format."
        }
        return intro
    }

    static func questioningIntro(stage: OralExamFormatDescriptor.Stage) -> String {
        if stage.style == "jury" {
            return "The jury will now ask you questions."
        }
        return "Let's move to questions."
    }
}

/// Typed errors for oral exam engine internals.
public enum OralExamEngineError: Error, LocalizedError, Equatable {
    case voiceUnavailable

    public var errorDescription: String? {
        switch self {
        case .voiceUnavailable:
            return "The voice session is unavailable."
        }
    }
}
