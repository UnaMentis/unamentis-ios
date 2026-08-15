// UnaMentis - Quiz Bowl Practice Session View Model
// Renders the generic QuizMatchEngine's events into published UI state for
// pyramidal tossup practice, and forwards user intents (buzz, submit, skip,
// next) to engine commands. Modeled closely on KBOralSessionViewModel's
// event-renderer pattern (MODULE_SDK_SPEC.md section 6.1).
//
// Quiz Bowl differs from Knowledge Bowl in one key interaction: the BUZZ. During
// narration the learner can buzz in, which stops the reading and opens the
// answer window. Power scoring needs the character index of the buzz, which the
// engine takes via buzz(atCharacterIndex:). We do not have a per-character TTS
// progress callback, so we APPROXIMATE the character index from the elapsed
// reading fraction: index = round(readingFraction * text.count). The fraction is
// measured off the wall clock against the tossup's estimated read duration
// (word count / speaking rate); a 10 Hz timer publishes it for the progress bar,
// but a buzz reads the clock directly, so an instant buzz is not reported as
// character 0. This is honest and documented: a real
// character-accurate buzz index needs a host TTS-progress signal (filed as a
// spec friction). The approximation is only used for power determination, never
// for correctness, and whether a power is on the table at all comes from the
// FORMAT DESCRIPTOR's scoring table, never from the item's power mark alone.
//
// The module owns the module-side concerns: voice pipeline acquisition,
// permissions, hands-free feedback, watch session registration, and metrics
// accumulation. It owns no audio, evaluation, storage, or telemetry.
//
// Writing style: no em dashes (see .claude/rules/writing-style.md).

import AVFoundation
import Foundation
import SwiftUI

// MARK: - Session State

/// The phase the practice UI renders.
enum QBPracticeState: Equatable {
    case notStarted
    case readingQuestion
    case awaitingAnswer
    case bonus
    case showingFeedback
    case completed
}

// MARK: - View Model

@MainActor
final class QBPracticeSessionViewModel: ObservableObject {
    // MARK: Published State

    @Published var state: QBPracticeState = .notStarted
    @Published var currentQuestionIndex = 0
    @Published var currentQuestionText = ""
    @Published var currentDomain = ""
    @Published var totalQuestions = 0

    /// Fraction of the current tossup that has been read (0...1), the buzz-index
    /// approximation source. Drives the reading progress bar too.
    @Published var readingFraction: Double = 0

    /// True while narration is in progress (buzzing is allowed).
    @Published var canBuzz = false

    /// True when the format grants powers AND the current reading position is
    /// before this tossup's power mark, so a correct buzz would earn a power.
    /// Used to color the buzz button.
    @Published var inPowerZone = false

    /// Points a correct, non-power answer earns in this format, read from the
    /// descriptor's scoring table. The UI never hardcodes point values: a
    /// format that pays something other than 10 must read correctly.
    @Published private(set) var correctPoints = 10

    /// Points a correct pre-power-mark buzz earns, or nil when the format
    /// grants no powers at all (ACF, IHBB Europe, UK Schools' Challenge all
    /// declare `scoring.power: null`).
    @Published private(set) var powerPoints: Int?

    /// Number of parts in this format's bonus, for the bonus screen's counter.
    @Published private(set) var bonusPartCount = 3

    @Published var isListening = false
    @Published var transcript = ""
    @Published var sttError: String?

    @Published var lastPointsAwarded = 0
    @Published var lastWasPower = false
    @Published var lastWasCorrect: Bool?
    @Published var lastCorrectAnswer: String?

    @Published var scores: [Int] = [0]

    // Bonus rendering.
    @Published var bonusPartText = ""
    @Published var bonusPartIndex = 0

    // MARK: Metrics

    /// Accumulated tossup outcomes and bonus totals for the live metrics panel.
    private(set) var tossupOutcomes: [QBTossupOutcome] = []
    private(set) var bonusTotals: [Int] = []
    @Published var metrics: QBMetrics = .empty

    /// The summary handed to the host when the session ended. Kept so the
    /// reported completion and duration are inspectable after teardown.
    private(set) var reportedSummary: ModuleSessionSummary?

    // MARK: Configuration

    let format: QBFormat
    private let host: any ModuleHost
    private let questions: [QBItem]

    // MARK: Services and Engine

    private var voice: (any VoiceSession)?
    private var engine: QuizMatchEngine?
    private var registeredSession: RegisteredSession?
    private let voiceFeedback = VoiceActivityFeedback()

    /// The format descriptor, loaded once in `prepare()` and reused by
    /// `start()`. Loading it a second time meant a second synchronous bundle
    /// read and decode on the MainActor for data that cannot change.
    private var descriptor: QuizMatchFormatDescriptor?

    // MARK: Tasks

    private var engineEventTask: Task<Void, Never>?
    private var voiceEventTask: Task<Void, Never>?
    private var readingTimerTask: Task<Void, Never>?

    private var hasFinished = false

    /// Whether teardown speaks the completion summary. A finished or explicitly
    /// ended match announces; backing out of the screen does not.
    private var announcesCompletion = true

    /// Wall-clock start of the match, for the registered session's summary.
    private var sessionStartedAt: Date?

    /// The engine's own measured match duration, when the match ended normally.
    private var engineMatchDuration: TimeInterval?

    /// Whether the current tossup carries a bonus, so a correct answer can skip
    /// the feedback screen and go straight to the bonus.
    private var currentQuestionHasBonus = false

    // MARK: Buzz Approximation

    /// The power-mark character index for the current tossup (nil if none).
    private var currentPowerMarkIndex: Int?
    /// The character length of the current tossup text.
    private var currentTextLength = 0
    /// Estimated total read duration of the current tossup, in seconds.
    private var currentReadDuration: TimeInterval = 1
    /// Wall-clock start of the current tossup's narration.
    private var readingStartedAt: Date?

    /// Words spoken per second used to estimate read duration. Matches
    /// KBQuestion's read-time estimate (about 150 wpm).
    private static let wordsPerSecond = 2.5

    // MARK: Init

    init(format: QBFormat, questions: [QBItem], host: any ModuleHost) {
        self.format = format
        self.questions = questions
        self.host = host
        self.totalQuestions = questions.count
    }

    deinit {
        // Safety net only. The engine, the registered watch session, and the
        // event pumps are torn down by `teardown()` (the view's onDisappear) or
        // by `finishSession()` on matchEnded: all three are MainActor state a
        // nonisolated deinit cannot reach. A leaked voice session, though,
        // holds the EXCLUSIVE pipeline away from every other module, so release
        // it here too rather than trusting the teardown path absolutely.
        let session = voice
        Task { await session?.release() }
    }

    // MARK: Derived

    var readingProgress: Double { readingFraction }

    /// True when this format can award a power at all. The descriptor's scoring
    /// table decides, NOT the item: every IHBB Europe tossup carries a power
    /// mark, but `ihbb-europe.json` declares `power: null`, so no buzz on any of
    /// them can ever pay more than the regular value.
    var formatGrantsPower: Bool { powerPoints != nil }

    /// Points a correct answer would earn for the buzz available right now.
    /// Drives the buzz button copy and its VoiceOver hint, so the promise the
    /// UI makes is the number the engine will actually score.
    var buzzPointValue: Int { inPowerZone ? (powerPoints ?? correctPoints) : correctPoints }

    /// The current answer window's approximate buzz character index, from the
    /// elapsed reading fraction. See the file header for the approximation.
    var approximateBuzzIndex: Int {
        guard let started = readingStartedAt else {
            return Self.buzzCharacterIndex(
                fraction: readingFraction, textLength: currentTextLength
            )
        }
        return Self.buzzCharacterIndex(
            elapsed: Date().timeIntervalSince(started),
            readDuration: currentReadDuration,
            textLength: currentTextLength
        )
    }

    /// The buzz character index for an elapsed reading time, as a pure function
    /// of the clock rather than of the last published timer tick.
    ///
    /// The 10 Hz timer that drives the progress bar left `readingFraction` at 0
    /// for the whole first 100 ms, so a buzz anywhere in that window reported
    /// character index 0: the maximally early buzz the engine can be told
    /// about, whatever the learner actually did. Reading the clock keeps the
    /// approximation continuous from the first instant.
    static func buzzCharacterIndex(
        elapsed: TimeInterval,
        readDuration: TimeInterval,
        textLength: Int
    ) -> Int {
        guard readDuration > 0 else { return 0 }
        let fraction = min(1.0, max(0, elapsed / readDuration))
        return buzzCharacterIndex(fraction: fraction, textLength: textLength)
    }

    static func buzzCharacterIndex(fraction: Double, textLength: Int) -> Int {
        Int((min(1.0, max(0, fraction)) * Double(textLength)).rounded())
    }

    // MARK: Lifecycle

    /// Acquire the exclusive voice session configured from the format descriptor
    /// and prewarm it. Call before starting.
    func prepare() async {
        guard voice == nil, !hasFinished else { return }
        do {
            let descriptor = try loadedDescriptor()
            voice = try await host.voice.acquire(config: descriptor.voicePipelineConfig())
            startVoiceEventMonitoring()
        } catch {
            sttError = error.localizedDescription
        }
    }

    /// Start the match: register the session, begin voice command feedback, and
    /// hand the voice session to the engine.
    func start() async {
        guard engine == nil, !hasFinished else { return }
        await prepare()

        // Register the watch session ONLY when a match is genuinely starting.
        // Registering after a failed acquire installed a watch command handler
        // for a session that never ran: the watch showed a phantom active
        // session, and the handler (only one exists app-wide) was taken from
        // whichever session legitimately held it.
        guard let voice, let descriptor else {
            if sttError == nil {
                sttError = "The voice pipeline is busy. Close the other activity and try again."
            }
            return
        }

        let engineQuestions = questions.map(QBQuestionMapper.engineQuestion(from:))
        let context = QuizMatchHostContext(
            moduleId: "quiz-bowl",
            evaluation: host.evaluation,
            progress: host.progress,
            telemetry: host.telemetry
        )
        let engine = QuizMatchEngine(
            descriptor: descriptor,
            options: QuizMatchSessionOptions(
                questionCount: engineQuestions.count,
                participantCount: 1,
                autoListen: false
            ),
            host: context,
            provider: { index in
                index < engineQuestions.count ? engineQuestions[index] : nil
            }
        )
        self.engine = engine
        self.scores = [0]
        self.sessionStartedAt = Date()
        beginRegisteredSession()
        voiceFeedback.announceActivityStarted("\(format.name) Practice")
        startEngineEventMonitoring(engine)
        await engine.start(voice: voice)
    }

    /// Load the format descriptor once and publish the scoring values the UI
    /// reads from it.
    private func loadedDescriptor() throws -> QuizMatchFormatDescriptor {
        if let descriptor { return descriptor }
        let loaded = try QuizMatchFormatDescriptor.load(named: format.id)
        descriptor = loaded
        correctPoints = loaded.scoring.correct
        // Powers exist only where the format both declares a power value and
        // reads pyramidal questions.
        powerPoints = loaded.questionForm == .pyramidal ? loaded.scoring.power : nil
        bonusPartCount = loaded.scoring.bonus?.partCount ?? bonusPartCount
        return loaded
    }

    // MARK: User Intents

    /// Buzz in during narration. Stops the reading and opens the answer window,
    /// passing the approximate character index for power determination.
    func buzz() async {
        guard canBuzz, let engine else { return }
        stopReadingTimer()
        canBuzz = false
        await engine.buzz(atCharacterIndex: approximateBuzzIndex)
    }

    /// Start capturing one spoken answer.
    func startListening() async {
        await engine?.startListening()
    }

    func stopListening() async {
        await engine?.stopListening()
    }

    /// Submit the captured (or typed) transcript.
    func submitAnswer() async {
        await engine?.submitAnswer(transcript)
    }

    /// Skip the current tossup without answering.
    func skip() async {
        await engine?.markSkipped()
    }

    /// Advance to the next tossup, or end the match after the last one.
    func next() async {
        transcript = ""
        lastWasCorrect = nil
        await engine?.next()
    }

    /// End the session now (the End button and the watch stop command).
    func end() async {
        await engine?.stop()
        finishSession()
    }

    /// Tear the session down on navigate-away. Stops the engine first (so it
    /// cannot narrate or capture on a session it is about to lose), then
    /// cancels the pumps, ends the registered watch session, and releases the
    /// exclusive voice pipeline. Silent: backing out is not a completed match.
    func teardown() async {
        guard !hasFinished else { return }
        announcesCompletion = false
        await engine?.stop()
        finishSession()
    }

    // MARK: Engine Event Rendering

    private func startEngineEventMonitoring(_ engine: QuizMatchEngine) {
        engineEventTask?.cancel()
        // Capture the STREAM, not the engine. The task outlives a cancel until
        // its next suspension point resolves, and an engine held strongly by
        // its own event pump is an engine that keeps narrating after the view
        // that owns it is gone.
        let events = engine.events
        engineEventTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { break }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: QuizMatchEvent) async {
        switch event {
        case .matchStarted(let total):
            totalQuestions = total

        case .questionPresented(let index, let question):
            currentQuestionIndex = index
            currentQuestionText = question.text
            currentDomain = question.domain ?? ""
            currentPowerMarkIndex = question.powerMarkIndex
            currentTextLength = question.text.count
            currentQuestionHasBonus = question.bonus != nil
            if index > 0 {
                voiceFeedback.announceNextQuestion(number: index + 1, total: totalQuestions)
            }
            state = .readingQuestion
            startReadingTimer(for: question)

        case .questionReadingFinished(let index, let interrupted):
            _ = index
            stopReadingTimer()
            canBuzz = false
            inPowerZone = false
            if !interrupted { readingFraction = 1.0 }

        case .speakFailed(let message):
            sttError = message
            registeredSession?.reportError(QBSessionError.narrationFailed(message))

        case .conferenceStarted, .conferenceTick, .conferenceMilestone,
             .conferenceCountdownTick, .conferenceEnded:
            // No conference in Quiz Bowl formats (buzz goes straight to the
            // answer window). These never fire for a QB descriptor.
            break

        case .answerWindowOpened:
            transcript = ""
            state = .awaitingAnswer
            // Auto-start capture so the learner can just speak (hands-free).
            await engine?.startListening()

        case .listeningStarted:
            sttError = nil
            isListening = true

        case .listeningStopped:
            isListening = false

        case .answerCaptured(let text):
            transcript = text
            isListening = false

        case .listenFailed(let message):
            isListening = false
            sttError = "Speech recognition unavailable. Please try on a physical device."
            registeredSession?.reportError(QBSessionError.listenFailed(message))

        case .evaluated(_, let judgment):
            recordTossup(judgment)

        case .answerSkipped:
            lastWasCorrect = false
            lastWasPower = false
            lastPointsAwarded = 0
            // The answer belongs to the tossup being skipped. Reading it off
            // the previous tossup's stored value showed, and announced, the
            // wrong answer on every skip after the first.
            lastCorrectAnswer = currentAnswerPrimary()
            state = .showingFeedback
            voiceFeedback.announceIncorrect(correctAnswer: lastCorrectAnswer)

        case .scoreChanged(let newScores):
            scores = newScores

        case .reboundOffered:
            // Solo practice: no rebound.
            break

        case .bonusStarted(_, let partCount):
            bonusPartCount = max(1, partCount)
            state = .bonus

        case .bonusPartPresented(let part, let text):
            bonusPartIndex = part
            bonusPartText = text

        case .bonusPartEvaluated:
            break

        case .bonusCompleted(let total):
            bonusTotals.append(total)
            recomputeMetrics()
            // The bonus is over, so the tossup's feedback screen is due now.
            // Without this the bonus screen (and its spinner) stayed up with no
            // way forward, because the engine reaches its own `.feedback` state
            // silently after a bonus.
            state = .showingFeedback

        case .paused, .resumed:
            break

        case .matchEnded(let summary):
            engineMatchDuration = summary.duration
            finishSession()
        }
    }

    /// Fold an engine judgment into the live metrics and feedback.
    private func recordTossup(_ judgment: QuizMatchJudgment) {
        lastPointsAwarded = judgment.pointsAwarded
        lastWasPower = judgment.wasPower
        lastWasCorrect = judgment.isCorrect
        lastCorrectAnswer = currentAnswerPrimary()

        let outcome = QBTossupOutcome(
            correct: judgment.isCorrect,
            wasPower: judgment.wasPower,
            wasNeg: judgment.pointsAwarded < 0,
            responseTimeMs: judgment.responseTimeMs
        )
        tossupOutcomes.append(outcome)
        recomputeMetrics()
        updateRegisteredProgress()

        if judgment.isCorrect {
            voiceFeedback.announceCorrect()
        } else {
            voiceFeedback.announceIncorrect(correctAnswer: lastCorrectAnswer)
        }
        // A correct answer on a bonus-bearing tossup goes STRAIGHT to the bonus.
        // Showing feedback here and letting `.bonusStarted` replace it one event
        // later put a full feedback screen on screen for a frame on every
        // bonus-bearing tossup, which is now nearly all of them.
        if !bonusFollows(judgment) {
            state = .showingFeedback
        }
    }

    /// Whether the engine will run a bonus for this judgment, so the feedback
    /// screen should be deferred until the bonus completes.
    private func bonusFollows(_ judgment: QuizMatchJudgment) -> Bool {
        judgment.isCorrect && currentQuestionHasBonus && descriptor?.scoring.bonus != nil
    }

    private func currentAnswerPrimary() -> String? {
        guard currentQuestionIndex < questions.count else { return nil }
        return questions[currentQuestionIndex].answer.primary
    }

    private func recomputeMetrics() {
        metrics = QBMetrics.compute(tossups: tossupOutcomes, bonusTotals: bonusTotals)
    }

    // MARK: Reading Timer (buzz-index approximation)

    private func startReadingTimer(for question: QuizMatchQuestion) {
        stopReadingTimer()
        readingFraction = 0
        canBuzz = true
        readingStartedAt = Date()
        let words = max(1, question.text.split(separator: " ").count)
        currentReadDuration = Double(words) / Self.wordsPerSecond
        updatePowerZone()

        readingTimerTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }
                guard let started = self.readingStartedAt else { continue }
                let elapsed = Date().timeIntervalSince(started)
                self.readingFraction = min(1.0, elapsed / self.currentReadDuration)
                self.updatePowerZone()
                if self.readingFraction >= 1.0 { return }
            }
        }
    }

    private func updatePowerZone() {
        // The DESCRIPTOR decides whether a power is on the table, not the item.
        // Every IHBB Europe tossup carries a power mark while ihbb-europe.json
        // declares no power value, so gating on the item alone lit the power
        // zone (and promised 15 points to VoiceOver) on tossups the engine
        // always scored at 10.
        guard formatGrantsPower, let powerMark = currentPowerMarkIndex, currentTextLength > 0 else {
            inPowerZone = false
            return
        }
        inPowerZone = approximateBuzzIndex < powerMark
    }

    private func stopReadingTimer() {
        readingTimerTask?.cancel()
        readingTimerTask = nil
    }

    // MARK: Voice Event Monitoring

    private func startVoiceEventMonitoring() {
        voiceEventTask?.cancel()
        guard let voice else { return }
        // Capture the stream, not the session, for the same reason the engine
        // pump does: a pump that outlives its cancel must not keep the
        // exclusive voice session alive.
        let events = voice.events
        voiceEventTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { break }
                if case .partialTranscript(let text) = event, self.isListening {
                    self.transcript = text
                }
            }
        }
    }

    // MARK: Session Registration (watch control plane, section 5.9)

    private func beginRegisteredSession() {
        guard registeredSession == nil else { return }
        let sessionDescriptor = ModuleSessionDescriptor(
            module: "quiz-bowl",
            title: "\(format.name) Practice",
            activityKind: ModuleActivityKind("tossup-practice"),
            controls: .voicePractice,
            totalUnits: questions.count
        )
        registeredSession = host.sessionRegistration.begin(
            sessionDescriptor,
            // The descriptor claims `.pause`, so pause has to actually pause.
            // Empty callbacks meant the watch's pause button reported success
            // and the tossup kept reading.
            onPause: { [weak self] in
                guard let self else { return }
                Task { await self.engine?.pause() }
            },
            onResume: { [weak self] in
                guard let self else { return }
                Task { await self.engine?.resume() }
            },
            onMute: nil,
            onStop: { [weak self] in
                guard let self else { return }
                Task { await self.end() }
            }
        )
    }

    private func updateRegisteredProgress() {
        registeredSession?.update(progress: ModuleSessionProgress(
            completedUnits: tossupOutcomes.count
        ))
    }

    // MARK: Teardown

    /// The one teardown path, idempotent. Reached from `matchEnded`, from the
    /// End button, and from the view's `onDisappear`.
    ///
    /// Order matters. The engine is dropped and its pump cancelled BEFORE the
    /// voice session is released, so nothing can speak or listen on a released
    /// session; the registered watch session is ended before the handle is
    /// dropped, so the watch does not keep showing a session that no longer
    /// exists and no command handler stays bound to it.
    private func finishSession() {
        guard !hasFinished else { return }
        hasFinished = true

        stopReadingTimer()
        engineEventTask?.cancel()
        engineEventTask = nil
        voiceEventTask?.cancel()
        voiceEventTask = nil
        // Drop the engine. The pump no longer holds it, so this is the last
        // strong reference the module has: it cannot narrate on after this.
        engine = nil

        isListening = false
        canBuzz = false
        inPowerZone = false
        state = .completed

        // A real duration: the engine's own measurement when the match ended
        // normally, else the wall clock since start. Reporting 0 made every
        // session summary claim it took no time at all.
        let duration = engineMatchDuration
            ?? sessionStartedAt.map { Date().timeIntervalSince($0) }
            ?? 0
        let summary = ModuleSessionSummary(
            completedUnits: tossupOutcomes.count,
            duration: duration
        )
        reportedSummary = summary
        registeredSession?.end(summary: summary)
        registeredSession = nil

        let voiceSession = voice
        voice = nil
        Task { await voiceSession?.release() }

        if announcesCompletion {
            let correct = metrics.tossupsCorrect
            voiceFeedback.announceActivityCompleted(
                "Practice complete. \(correct) of \(tossupOutcomes.count) correct."
            )
        }

        // Persist this session's outcomes into the format's running stats so the
        // dashboard reflects them next time. A session abandoned part way still
        // counts the tossups that were actually played.
        guard !tossupOutcomes.isEmpty || !bonusTotals.isEmpty else { return }
        let statsStore = QBStatsStore(progress: host.progress)
        let formatId = format.id
        let outcomes = tossupOutcomes
        let bonuses = bonusTotals
        Task {
            await statsStore.record(formatId: formatId, tossups: outcomes, bonusTotals: bonuses)
        }
    }
}

// MARK: - Session Errors

/// Module-side errors this session reports into the host error log (section 5.9).
enum QBSessionError: LocalizedError {
    case narrationFailed(String)
    case listenFailed(String)

    var errorDescription: String? {
        switch self {
        case .narrationFailed(let message):
            return "Tossup narration failed: \(message)"
        case .listenFailed(let message):
            return "Answer capture failed: \(message)"
        }
    }
}
