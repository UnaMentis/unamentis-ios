// UnaMentis - Oral Exam Engine Tests
//
// Drives OralExamEngine headlessly through the shared harness
// (ScriptedModuleHost + ScriptedVoiceSession), verifying the spec 6.2
// contract:
// - stage state transitions (stageStarted/stageEnded) for stage practice
// - question volleys: root plus grounded follow-up questions, ended by the
//   volley count
// - milestone timer events follow the hands-free countdown pattern
// - responses are captured and the required module.attempt telemetry plus
//   AttemptRecords are emitted
// - rubric feedback is assembled (feedbackReady) and the summary spoken
// - a skip command drops the current question
//
// Real over mock: progress is the real FileProgressStoreService on a temp
// root, telemetry the recording service, voice the scripted session. The
// examiner is the deterministic RuleBasedExaminerBrain (offline Tier 0 floor),
// so runs are hermetic with no LLM or network.

import XCTest
@testable import UnaMentis

final class OralExamEngineTests: XCTestCase {

    private var harness: ScriptedModuleHost!

    @MainActor
    override func setUp() async throws {
        harness = ScriptedModuleHost.make()
    }

    override func tearDown() {
        harness?.tearDown()
        harness = nil
        super.tearDown()
    }

    private func context(moduleId: String = "oral-exam-test") -> OralExamHostContext {
        OralExamHostContext(
            moduleId: moduleId,
            progress: harness.progressStore,
            telemetry: harness.telemetryRecorder
        )
    }

    private func topic() -> OralExamTopic {
        OralExamTopic(
            id: "t-water",
            title: "the water cycle",
            summary: "Evaporation, condensation, precipitation, collection.",
            exemplarQuestions: [
                "What drives evaporation?",
                "How do clouds form?",
                "Why does rainfall vary by region?"
            ],
            rubricHints: ["Name the energy source."],
            domain: "science"
        )
    }

    /// Await the next event matching the predicate, bounded in TIME so a wedged
    /// engine fails fast with a clear message instead of hanging the suite.
    ///
    /// An event cap bounds nothing on its own: `AsyncStream.Iterator.next()`
    /// suspends until the next event arrives, so an engine that stops emitting
    /// never reaches the cap and the test hangs forever. The iteration therefore
    /// runs in a child task that a watchdog cancels at the deadline (AsyncStream
    /// ends iteration when its consuming task is cancelled), and the failure
    /// names the event that never arrived.
    @discardableResult
    private func waitFor(
        _ iterator: inout AsyncStream<OralExamEvent>.Iterator,
        _ description: String = "a matching event",
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line,
        where predicate: @escaping @Sendable (OralExamEvent) -> Bool
    ) async throws -> OralExamEvent {
        let box = OralExamEventIteratorBox(iterator)
        let started = Date()
        let consumer = Task { await box.firstEvent(matching: predicate) }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            consumer.cancel()
        }
        let found = await consumer.value
        watchdog.cancel()
        iterator = box.takeIterator()

        guard let found else {
            let elapsed = Date().timeIntervalSince(started)
            let reason = elapsed >= timeout
                ? "timed out after \(Int(elapsed))s"
                : "the engine's event stream ended after \(String(format: "%.2f", elapsed))s"
            XCTFail("Never saw \(description): \(reason).", file: file, line: line)
            throw EventNotSeen(description: description)
        }
        return found
    }

    /// Thrown when a bounded wait gives up, so the test stops at the failure
    /// instead of asserting on events that never arrived.
    private struct EventNotSeen: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - Stage Practice: Presentation

    func testStagePractice_presentationCapturesAndAssemblesFeedback() async throws {
        let voice = ScriptedVoiceSession()
        // Enough long-form segments for a measurable pace, then the loop parks
        // and the accelerated stage clock ends the stage.
        await voice.enqueueTranscripts([
            Array(repeating: "word", count: 40).joined(separator: " "),
            Array(repeating: "word", count: 40).joined(separator: " ")
        ])

        let descriptor = OralExamFormatDescriptor(
            formatId: "test-presentation",
            language: "en-US",
            stages: [.init(kind: .presentation, seconds: 2, notesAllowed: false)],
            rubric: ["clarity", "delivery"],
            examiner: .init(personaCount: 1, register: "encouraging"),
            evaluation: .init(tiers: ["llmRubric"], deliveryMetrics: ["pace", "fillerWords", "hesitations"]),
            listening: .init(responseSilenceSec: 2.0, maxUtteranceSec: 180)
        )
        let engine = OralExamEngine(
            descriptor: descriptor,
            mode: .stagePractice(.presentation),
            options: OralExamSessionOptions(clockRate: 50, speakFeedbackSummary: true),
            topic: topic(),
            host: context(),
            examiner: RuleBasedExaminerBrain()
        )
        var events = engine.events.makeAsyncIterator()

        await engine.start(voice: voice)

        _ = try await waitFor(&events) {
            if case .stageStarted(0, .presentation, _) = $0 { return true }; return false
        }
        _ = try await waitFor(&events) {
            if case .responseCaptured = $0 { return true }; return false
        }
        _ = try await waitFor(&events) {
            if case .stageEnded(0, .presentation, _) = $0 { return true }; return false
        }
        guard case .feedbackReady(let feedback) = try await waitFor(&events, where: {
            if case .feedbackReady = $0 { return true }; return false
        }) else { return XCTFail("Expected feedbackReady") }

        XCTAssertEqual(feedback.scores.map(\.dimension), ["clarity", "delivery"])
        XCTAssertGreaterThan(feedback.deliveryMetrics.wordCount, 0)

        guard case .sessionEnded(let summary) = try await waitFor(&events, where: {
            if case .sessionEnded = $0 { return true }; return false
        }) else { return XCTFail("Expected sessionEnded") }
        XCTAssertEqual(summary.stagesCompleted, 1)
        XCTAssertGreaterThan(summary.responsesCaptured, 0)
        XCTAssertNotNil(summary.feedback)

        // The feedback summary was spoken through the session.
        let spoken = await voice.spokenTexts
        XCTAssertTrue(spoken.contains(feedback.spokenSummary))
    }

    // MARK: - Question Volleys

    func testQuestionVolley_rootPlusGroundedFollowUpThenEnds() async throws {
        let voice = ScriptedVoiceSession()
        // Two roots, each with one follow-up (depth 1): four answers.
        await voice.enqueueTranscripts([
            "Evaporation is driven by the sun heating the ocean surface.",
            "The sun provides the energy for that process.",
            "Rainfall varies because of geography and temperature.",
            "Mountains force air upward which cools and condenses it."
        ])

        let descriptor = OralExamFormatDescriptor(
            formatId: "test-volley",
            language: "en-US",
            stages: [.init(kind: .questioning, seconds: 600, style: "conversation", followUpDepth: 1)],
            rubric: ["structure", "interaction"],
            examiner: .init(personaCount: 1, register: "encouraging"),
            evaluation: .init(tiers: ["llmRubric"], deliveryMetrics: ["pace"]),
            listening: .init(responseSilenceSec: 2.0, maxUtteranceSec: 180)
        )
        let engine = OralExamEngine(
            descriptor: descriptor,
            mode: .questionVolley(rootQuestions: 2),
            options: OralExamSessionOptions(clockRate: 50, speakFeedbackSummary: false),
            topic: topic(),
            host: context(),
            examiner: RuleBasedExaminerBrain()
        )
        var events = engine.events.makeAsyncIterator()

        await engine.start(voice: voice)

        // A grounded follow-up is asked, quoting the learner's own words.
        guard case .followUpAsked(let question, 1, _) = try await waitFor(&events, where: {
            if case .followUpAsked = $0 { return true }; return false
        }) else { return XCTFail("Expected a grounded follow-up") }
        XCTAssertTrue(
            question.contains("Evaporation") || question.contains("water cycle"),
            "Follow-up must ground in the learner's words or the topic, not be generic"
        )

        guard case .sessionEnded(let summary) = try await waitFor(&events, where: {
            if case .sessionEnded = $0 { return true }; return false
        }) else { return XCTFail("Expected sessionEnded") }

        // Two roots plus two follow-ups asked; four responses captured.
        XCTAssertEqual(summary.questionsAsked, 4)
        XCTAssertEqual(summary.responsesCaptured, 4)

        // Attempts and telemetry were emitted, one per answered question.
        let attempts = await harness.progressStore.exportAll(for: "oral-exam-test").attempts
        XCTAssertEqual(attempts.count, 4)
        let telemetry = await harness.telemetryRecorder.attemptCount(module: "oral-exam-test")
        XCTAssertEqual(telemetry, 4)
    }

    // MARK: - Milestones

    func testTimer_emitsMilestoneAndCountdownEvents() async throws {
        let voice = ScriptedVoiceSession()
        // A preparation stage has no capture; the accelerated clock drives
        // milestone and countdown events through 5-1.
        let descriptor = OralExamFormatDescriptor(
            formatId: "test-prep",
            language: "en-US",
            stages: [.init(kind: .preparation, seconds: 12)],
            rubric: ["clarity"],
            examiner: .init(personaCount: 1, register: "formal"),
            evaluation: .init(tiers: ["llmRubric"], deliveryMetrics: [])
        )
        let engine = OralExamEngine(
            descriptor: descriptor,
            mode: .stagePractice(.preparation),
            options: OralExamSessionOptions(clockRate: 40, speakFeedbackSummary: false),
            topic: topic(),
            host: context(),
            examiner: RuleBasedExaminerBrain()
        )
        var events = engine.events.makeAsyncIterator()

        await engine.start(voice: voice)

        // 10 second milestone (a milestoneSeconds value below the 12s total).
        _ = try await waitFor(&events) {
            if case .timerMilestone(10) = $0 { return true }; return false
        }
        // A final-countdown tick (5 through 1).
        _ = try await waitFor(&events) {
            if case .timerCountdownTick(let seconds) = $0 { return seconds <= 5 }; return false
        }
        _ = try await waitFor(&events) {
            if case .stageEnded(0, .preparation, false) = $0 { return true }; return false
        }
    }

    // MARK: - Skip

    func testSkipQuestion_dropsCurrentQuestion() async throws {
        let voice = ScriptedVoiceSession()
        let descriptor = OralExamFormatDescriptor(
            formatId: "test-skip",
            language: "en-US",
            stages: [.init(kind: .questioning, seconds: 600, style: "conversation", followUpDepth: 0)],
            rubric: ["clarity"],
            examiner: .init(personaCount: 1, register: "encouraging"),
            evaluation: .init(tiers: ["llmRubric"], deliveryMetrics: []),
            listening: .init(responseSilenceSec: 2.0, maxUtteranceSec: 180)
        )
        let engine = OralExamEngine(
            descriptor: descriptor,
            mode: .questionVolley(rootQuestions: 1),
            options: OralExamSessionOptions(clockRate: 50, speakFeedbackSummary: false),
            topic: topic(),
            host: context(),
            examiner: RuleBasedExaminerBrain()
        )
        var events = engine.events.makeAsyncIterator()

        await engine.start(voice: voice)
        // Wait for the engine to be listening, then skip (cancels the listen).
        _ = try await waitFor(&events) {
            if case .listeningStarted = $0 { return true }; return false
        }
        await engine.skipQuestion()

        // The single root was skipped (volley count reached), so the session
        // ends with no captured response.
        guard case .sessionEnded(let summary) = try await waitFor(&events, where: {
            if case .sessionEnded = $0 { return true }; return false
        }) else { return XCTFail("Expected sessionEnded") }
        XCTAssertEqual(summary.responsesCaptured, 0)
    }

    // MARK: - Regression: Stage and Capture Robustness
    //
    // Each test below pins one verified defect that could hold the exclusive
    // voice pipeline open indefinitely or open the microphone behind a paused
    // UI. They poll a drained event log with a real timeout, so a wedged engine
    // FAILS instead of hanging the suite.

    /// A stage whose duration is not positive used to create no timer at all,
    /// so nothing ever ended the stage: `waitForStageEnd` busy-polled forever.
    func testZeroSecondStage_completesImmediatelyInsteadOfHangingTheSession() async throws {
        let voice = ScriptedVoiceSession()
        let descriptor = OralExamFormatDescriptor(
            formatId: "test-zero-prep",
            language: "en-US",
            stages: [.init(kind: .preparation, seconds: 0)],
            rubric: ["clarity"],
            examiner: .init(personaCount: 1, register: "formal"),
            evaluation: .init(tiers: ["llmRubric"], deliveryMetrics: [])
        )
        let engine = OralExamEngine(
            descriptor: descriptor,
            mode: .stagePractice(.preparation),
            options: OralExamSessionOptions(speakFeedbackSummary: false),
            topic: topic(),
            host: context(),
            examiner: RuleBasedExaminerBrain()
        )
        let (log, drain) = drainEvents(engine.events)
        defer { drain.cancel() }

        await engine.start(voice: voice)
        assertTrueAsync(
            await waitForEvents(in: log) { events in
                events.contains { if case .sessionEnded = $0 { return true }; return false }
            },
            "A zero-second stage must complete, not wedge waitForStageEnd forever"
        )
    }

    /// The same defect on a questioning stage was worse: `maxRoots` is
    /// `Int.max` in fullSimulation, so the engine asked questions forever while
    /// holding the exclusive voice pipeline.
    func testZeroSecondQuestioningStage_asksNoQuestionsAndEnds() async throws {
        let voice = ScriptedVoiceSession()
        let descriptor = OralExamFormatDescriptor(
            formatId: "test-zero-questioning",
            language: "en-US",
            stages: [.init(kind: .questioning, seconds: 0, style: "conversation", followUpDepth: 0)],
            rubric: ["clarity"],
            examiner: .init(personaCount: 1, register: "encouraging"),
            evaluation: .init(tiers: ["llmRubric"], deliveryMetrics: []),
            listening: .init(responseSilenceSec: 2.0, maxUtteranceSec: 180)
        )
        let engine = OralExamEngine(
            descriptor: descriptor,
            mode: .fullSimulation,
            options: OralExamSessionOptions(speakFeedbackSummary: false),
            topic: topic(),
            host: context(),
            examiner: RuleBasedExaminerBrain()
        )
        let (log, drain) = drainEvents(engine.events)
        defer { drain.cancel() }

        await engine.start(voice: voice)
        assertTrueAsync(
            await waitForEvents(in: log) { events in
                events.contains { if case .sessionEnded = $0 { return true }; return false }
            },
            "A zero-second questioning stage must ask nothing, not loop forever"
        )
        let summaries = await log.snapshot().compactMap { event -> OralExamSummary? in
            if case .sessionEnded(let summary) = event { return summary }
            return nil
        }
        XCTAssertEqual(summaries.first?.questionsAsked, 0)
    }

    /// A dead audio route used to spin the questioning stage: `askAndCapture`
    /// returned false WITHOUT requesting stage end, so the loop re-ran
    /// examiner.nextQuestion (a live, metered LLM call) plus speak plus listen
    /// as fast as the brain responded, for the rest of the stage.
    func testQuestioning_boundsConsecutiveCaptureFailures() async throws {
        let voice = FailingCaptureVoiceSession()
        let descriptor = OralExamFormatDescriptor(
            formatId: "test-capture-failures",
            language: "en-US",
            stages: [.init(kind: .questioning, seconds: 600, style: "conversation", followUpDepth: 0)],
            rubric: ["clarity"],
            examiner: .init(personaCount: 1, register: "encouraging"),
            evaluation: .init(tiers: ["llmRubric"], deliveryMetrics: []),
            listening: .init(responseSilenceSec: 2.0, maxUtteranceSec: 180)
        )
        let engine = OralExamEngine(
            descriptor: descriptor,
            mode: .fullSimulation,
            // A 600 s stage at 50x is 12 s of wall clock: far longer than the
            // bounded run needs, so a session that ends quickly proves the
            // bound, not the stage timer.
            options: OralExamSessionOptions(clockRate: 50, speakFeedbackSummary: false),
            topic: topic(),
            host: context(),
            examiner: RuleBasedExaminerBrain()
        )
        let (log, drain) = drainEvents(engine.events)
        defer { drain.cancel() }

        await engine.start(voice: voice)
        assertTrueAsync(
            await waitForEvents(in: log, timeout: 5) { events in
                events.contains { if case .sessionEnded = $0 { return true }; return false }
            },
            "Consecutive capture failures must end the stage, not run out its clock"
        )

        let attempts = await voice.listenAttempts
        XCTAssertEqual(
            attempts, OralExamEngine.maxConsecutiveCaptureFailures,
            "Capture must stop after the failure bound"
        )
        let summaries = await log.snapshot().compactMap { event -> OralExamSummary? in
            if case .sessionEnded(let summary) = event { return summary }
            return nil
        }
        XCTAssertEqual(
            summaries.first?.questionsAsked, OralExamEngine.maxConsecutiveCaptureFailures,
            "One examiner call per bounded attempt, and no more"
        )
        XCTAssertEqual(summaries.first?.responsesCaptured, 0)
    }

    /// A pause that arrives while the examiner is thinking cancels nothing, so
    /// the flow used to walk straight into `capture()` and open the microphone
    /// while the UI said paused.
    func testPause_whileTheExaminerIsThinking_keepsTheMicrophoneShut() async throws {
        let gate = EngineTestGate()
        let voice = ScriptedVoiceSession()
        let descriptor = OralExamFormatDescriptor(
            formatId: "test-pause-before-capture",
            language: "en-US",
            stages: [.init(kind: .questioning, seconds: 600, style: "conversation", followUpDepth: 0)],
            rubric: ["clarity"],
            examiner: .init(personaCount: 1, register: "encouraging"),
            evaluation: .init(tiers: ["llmRubric"], deliveryMetrics: []),
            listening: .init(responseSilenceSec: 2.0, maxUtteranceSec: 180)
        )
        let engine = OralExamEngine(
            descriptor: descriptor,
            mode: .questionVolley(rootQuestions: 1),
            // Real-time clock: the 600 s stage cannot expire during the test,
            // so only the pause can be responsible for a shut microphone.
            options: OralExamSessionOptions(speakFeedbackSummary: false),
            topic: topic(),
            host: context(),
            examiner: GatedExaminerBrain(questionGate: gate)
        )
        let (log, drain) = drainEvents(engine.events)
        defer { drain.cancel() }

        await engine.start(voice: voice)
        assertTrueAsync(
            await waitUntil { await gate.waiterCount >= 1 },
            "The examiner must be mid-thought when the pause lands"
        )
        await engine.pause()
        await gate.open()

        try? await Task.sleep(nanoseconds: 300_000_000)
        let whilePaused = await log.snapshot()
        XCTAssertFalse(
            whilePaused.contains { if case .listeningStarted = $0 { return true }; return false },
            "A pause must be honored before capture opens, not only on the cancellation path"
        )

        await engine.resume()
        assertTrueAsync(
            await waitForEvents(in: log) { events in
                events.contains { if case .listeningStarted = $0 { return true }; return false }
            },
            "Resume must reopen capture"
        )

        await engine.stop()
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .sessionEnded = $0 { return true }; return false }
        })
    }

    /// A stop during rubric assembly used to emit feedback, write mastery and
    /// speak a summary anyway, and the event stream stayed open until the LLM
    /// returned.
    func testStop_duringRubricAssembly_emitsNoFeedbackAndEndsPromptly() async throws {
        let gate = EngineTestGate()
        let voice = ScriptedVoiceSession()
        await voice.enqueueTranscripts([
            Array(repeating: "word", count: 40).joined(separator: " "),
            Array(repeating: "word", count: 40).joined(separator: " ")
        ])

        let descriptor = OralExamFormatDescriptor(
            formatId: "test-stop-during-rubric",
            language: "en-US",
            stages: [.init(kind: .presentation, seconds: 2, notesAllowed: false)],
            rubric: ["clarity", "delivery"],
            examiner: .init(personaCount: 1, register: "encouraging"),
            evaluation: .init(tiers: ["llmRubric"], deliveryMetrics: ["pace"]),
            listening: .init(responseSilenceSec: 2.0, maxUtteranceSec: 180)
        )
        let engine = OralExamEngine(
            descriptor: descriptor,
            mode: .stagePractice(.presentation),
            options: OralExamSessionOptions(clockRate: 20, speakFeedbackSummary: true),
            topic: topic(),
            host: context(),
            examiner: GatedExaminerBrain(rubricGate: gate)
        )
        let (log, drain) = drainEvents(engine.events)
        defer { drain.cancel() }

        await engine.start(voice: voice)
        assertTrueAsync(
            await waitUntil { await gate.waiterCount >= 1 },
            "Rubric assembly must be in flight when the stop lands"
        )

        await engine.stop()
        assertTrueAsync(
            await waitForEvents(in: log) { events in
                events.contains { if case .sessionEnded = $0 { return true }; return false }
            },
            "stop() must abort the rubric call instead of waiting the model out"
        )
        await gate.open()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let events = await log.snapshot()
        XCTAssertFalse(
            events.contains { if case .feedbackReady = $0 { return true }; return false },
            "A stopped session must not emit feedback"
        )
        let summaries = events.compactMap { event -> OralExamSummary? in
            if case .sessionEnded(let summary) = event { return summary }
            return nil
        }
        XCTAssertNil(summaries.first?.feedback)
        let spoken = await voice.spokenTexts
        XCTAssertFalse(
            spoken.contains { $0.contains("Offline coaching summary") },
            "A stopped session must not speak a feedback summary"
        )
    }

    /// The host scopes its command vocabulary by the ACTIVE module voice state.
    /// No engine ever set one, so that vocabulary was inert in production: the
    /// session never learned which stage or phase the exam was in.
    func testEngine_publishesModuleVoiceStatesToTheSession() async throws {
        let voice = ScriptedVoiceSession()
        await voice.enqueueTranscripts([
            "Evaporation is driven by the sun heating the ocean surface.",
            "The sun provides the energy for that process."
        ])
        let descriptor = OralExamFormatDescriptor(
            formatId: "test-voice-states",
            language: "en-US",
            stages: [.init(kind: .questioning, seconds: 600, style: "conversation", followUpDepth: 0)],
            rubric: ["clarity"],
            examiner: .init(personaCount: 1, register: "encouraging"),
            evaluation: .init(tiers: ["llmRubric"], deliveryMetrics: []),
            listening: .init(responseSilenceSec: 2.0, maxUtteranceSec: 180)
        )
        let engine = OralExamEngine(
            descriptor: descriptor,
            mode: .questionVolley(rootQuestions: 1),
            options: OralExamSessionOptions(clockRate: 50, speakFeedbackSummary: false),
            topic: topic(),
            host: context(),
            examiner: RuleBasedExaminerBrain()
        )
        let (log, drain) = drainEvents(engine.events)
        defer { drain.cancel() }

        await engine.start(voice: voice)
        assertTrueAsync(await waitForEvents(in: log) { events in
            events.contains { if case .sessionEnded = $0 { return true }; return false }
        })

        let expected: Set<String> = ["questioning", "answering", "feedback", "ended"]
        assertTrueAsync(
            await waitUntil {
                let states = await voice.activeStates
                return Set(states.map(\.rawValue)).isSuperset(of: expected)
            },
            "The engine must drive the host's module voice state through every phase"
        )
    }

    // MARK: - Stop

    func testStop_endsSessionPromptly() async throws {
        let voice = ScriptedVoiceSession()
        let descriptor = OralExamFormatDescriptor(
            formatId: "test-stop",
            language: "en-US",
            stages: [.init(kind: .preparation, seconds: 600)],
            rubric: ["clarity"],
            examiner: .init(personaCount: 1, register: "formal"),
            evaluation: .init(tiers: ["llmRubric"], deliveryMetrics: [])
        )
        let engine = OralExamEngine(
            descriptor: descriptor,
            mode: .stagePractice(.preparation),
            options: OralExamSessionOptions(speakFeedbackSummary: false),
            topic: topic(),
            host: context(),
            examiner: RuleBasedExaminerBrain()
        )
        var events = engine.events.makeAsyncIterator()

        await engine.start(voice: voice)
        _ = try await waitFor(&events) {
            if case .stageStarted = $0 { return true }; return false
        }
        await engine.stop()
        _ = try await waitFor(&events) {
            if case .sessionEnded = $0 { return true }; return false
        }
    }
}

// MARK: - Bounded Wait Support

/// Carries an `AsyncStream` iterator into a child task so a wait can be bounded
/// in time. `AsyncStream.Iterator` is deliberately not Sendable, and this box
/// does not make it concurrent: exactly one task consumes it at a time (the
/// waiting test hands it over, then takes it back once that task has finished),
/// which is what makes the unchecked conformance sound here.
private final class OralExamEventIteratorBox: @unchecked Sendable {
    private var iterator: AsyncStream<OralExamEvent>.Iterator

    init(_ iterator: AsyncStream<OralExamEvent>.Iterator) {
        self.iterator = iterator
    }

    /// The first event matching `predicate`, or nil when the stream ends or the
    /// consuming task is cancelled (the watchdog's deadline).
    func firstEvent(
        matching predicate: @Sendable (OralExamEvent) -> Bool
    ) async -> OralExamEvent? {
        while let event = await iterator.next() {
            if predicate(event) { return event }
        }
        return nil
    }

    /// Hand the iterator back once the consuming task has finished, so the next
    /// wait resumes exactly where this one stopped.
    func takeIterator() -> AsyncStream<OralExamEvent>.Iterator {
        iterator
    }
}

// MARK: - Oral Exam Test Seams

/// A VoiceSession whose capture always fails: a dead audio route. Speech still
/// succeeds, so the engine reaches capture exactly as it would in the field.
/// ALLOWED: in-memory host seam, not a mock of a paid external API.
actor FailingCaptureVoiceSession: VoiceSession {
    nonisolated let events: AsyncStream<VoiceEvent>
    private let eventContinuation: AsyncStream<VoiceEvent>.Continuation

    /// How many times the engine tried to open the microphone.
    private(set) var listenAttempts = 0

    init() {
        var continuation: AsyncStream<VoiceEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    func speak(_ utterance: Utterance) async throws {}
    func stopSpeaking() async {}
    func prefetch(_ utterances: [Utterance]) async {}

    func listen(expecting expectation: ListenExpectation) async throws -> UtteranceResult {
        listenAttempts += 1
        throw CaptureRouteError.unavailable
    }

    func registerCommands(_ vocabulary: CommandVocabulary, for state: ModuleVoiceState) async {}
    func setActiveVoiceState(_ state: ModuleVoiceState) async {}
    func playCue(_ cue: AudioCue) async {}

    func release() async {
        eventContinuation.finish()
    }
}

/// The failure a dead audio route surfaces (deliberately not a CancellationError,
/// which the engine treats as a pause or a skip).
enum CaptureRouteError: Error {
    case unavailable
}

/// The deterministic rule-based brain, parked on gates, so a test can hold the
/// engine at the exact moment the examiner is thinking (no capture in flight) or
/// inside rubric assembly.
/// ALLOWED: in-memory host seam, not a mock of a paid external API (the
/// production brain is LLM-backed; this one never leaves the process).
struct GatedExaminerBrain: ExaminerBrain {
    let questionGate: EngineTestGate?
    let rubricGate: EngineTestGate?

    private let real = RuleBasedExaminerBrain()

    init(questionGate: EngineTestGate? = nil, rubricGate: EngineTestGate? = nil) {
        self.questionGate = questionGate
        self.rubricGate = rubricGate
    }

    func nextQuestion(_ context: ExaminerContext) async throws -> ExaminerQuestion {
        if let questionGate {
            await questionGate.wait()
            try Task.checkCancellation()
        }
        return try await real.nextQuestion(context)
    }

    func evaluateRubric(
        _ context: ExaminerContext,
        rubric: [String],
        deliveryMetrics: OralExamDeliveryMetrics
    ) async throws -> RubricFeedback {
        if let rubricGate {
            await rubricGate.wait()
            try Task.checkCancellation()
        }
        return try await real.evaluateRubric(
            context, rubric: rubric, deliveryMetrics: deliveryMetrics
        )
    }
}
