// UnaMentis - Knowledge Bowl Conformance Drivability
// Adopts ConformanceDrivable so KB's oral practice can run headlessly through the
// UM-Voice conformance suite (MODULE_SDK_SPEC.md section 9).
//
// The headless run is the SAME engine path the KB oral view model drives in
// production: it builds a Colorado quiz-match descriptor via KBQuizMatchAdapter,
// maps KB questions onto QuizMatchQuestions, hands the host-owned VoiceSession to
// QuizMatchEngine.start(voice:), and steps the match by consuming engine events.
// No SwiftUI, no KBOralSessionView. This proves the audio-only commitment
// (section 8): the oral activity completes with zero touch events.
//
// The unified command vocabulary is honored here exactly as it must be in the
// live activity: a quit ends the match, a skip marks the current question
// skipped. Commands arrive on the VoiceSession's `events` stream (the host
// recognizes them), which the driver consumes alongside the engine's events.

import Foundation

extension KnowledgeBowlModule: ConformanceDrivable {
    /// KB's primary voice-first activity is oral practice.
    public var primaryVoiceActivity: ModuleActivityKind {
        ModuleActivityKind("oral-practice")
    }

    /// The unified commands KB oral practice claims. Quit ends the session;
    /// skip drops the current question. (Ready/next/repeat are also used in the
    /// live UI but quit and skip are the ones UM-Voice asserts on.)
    public var claimedVoiceCommands: Set<VoiceCommand> {
        [.quit, .skip]
    }

    public func runPrimaryVoiceActivity(
        host: ModuleHost,
        session: any VoiceSession,
        script: ConformanceVoiceScript
    ) async throws -> ConformanceRunResult {
        let rounds = max(1, script.roundCount ?? 3)
        let config = KBRegionalConfig.forRegion(.colorado)
        let descriptor = KBQuizMatchAdapter.descriptor(for: config)

        // A small deterministic question set (Tier 0, offline: no server, no
        // bundled-pack dependency, so conformance is hermetic).
        let sampleAnswers = ["au", "mars", "shakespeare"]
        let kbQuestions = (0..<rounds).map { index -> KBQuestion in
            let answer = sampleAnswers[index % sampleAnswers.count]
            return KBQuestion(
                text: "Conformance question \(index + 1).",
                answer: KBAnswer(primary: answer, acceptable: nil, answerType: .text),
                domain: .science
            )
        }
        let engineQuestions = kbQuestions.map {
            KBQuizMatchAdapter.engineQuestion(from: $0, strictness: .standard)
        }

        let context = QuizMatchHostContext(
            moduleId: manifest.id,
            evaluation: host.evaluation,
            progress: host.progress,
            telemetry: host.telemetry
        )
        // autoListen is off: the driver steps the match explicitly (the headless
        // equivalent of the oral view model's control loop), which keeps the
        // control flow deterministic and free of any test-only session type. The
        // question is still spoken through the host VoiceSession, and each answer
        // is evaluated through the host, exactly as in the live activity.
        let engine = QuizMatchEngine(
            descriptor: descriptor,
            options: QuizMatchSessionOptions(
                questionCount: rounds, participantCount: 1, autoListen: false
            ),
            host: context,
            provider: { index in
                index < engineQuestions.count ? engineQuestions[index] : nil
            }
        )

        // The scripted answers the driver submits for evaluation, one per round.
        let answers = kbQuestions.map(\.answer.primary)

        return try await ConformanceEngineDriver.run(
            engine: engine,
            session: session,
            answers: answers,
            claimedCommands: claimedVoiceCommands
        )
    }
}

// MARK: - Shared Engine Driver

/// Steps a QuizMatchEngine to completion by consuming its events, submitting
/// scripted answers, and honoring unified commands from the voice session. This
/// is the headless equivalent of a module's oral view-model control loop, shared
/// by KB conformance and Quiz Bowl conformance (and available to any quiz-match
/// module's driver).
///
/// The result reports what the run OBSERVED: `completed` is true only when the
/// engine's terminal `.matchEnded` event arrived, and the voice states are the
/// ones the observed transitions actually entered.
enum ConformanceEngineDriver {
    static func run(
        engine: QuizMatchEngine,
        session: any VoiceSession,
        answers: [String],
        claimedCommands: Set<VoiceCommand>
    ) async throws -> ConformanceRunResult {
        var remainingAnswers = answers
        var attempts = 0

        // The voice states the run actually entered, recorded from the engine
        // transitions the driver observes (first-seen order), never listed up
        // front: a fabricated list would make the suite's state check vacuous.
        var statesEntered: [ModuleVoiceState] = []
        func enter(_ name: String) {
            let state = ModuleVoiceState(rawValue: name)
            if !statesEntered.contains(state) { statesEntered.append(state) }
        }

        // Completion is OBSERVED, never assumed. The loop below also exits when
        // the event stream simply finishes (engine error, early stop, task
        // cancellation), which is NOT the match running to its end. Only the
        // terminal `.matchEnded` event means the activity completed (section 9).
        var reachedTerminalEvent = false

        // Watch for unified commands on the session's event stream and route
        // them. Honoring a command means the activity recognized it and dispatched
        // its action (quit ends the match; skip drops the current question); the
        // engine no-ops actions that do not apply to its current state, exactly
        // as the live activity does. Runs concurrently with the engine loop, and
        // ends when the run cancels it.
        let honoredBox = HonoredCommands()
        let commandTask = Task {
            for await event in session.events {
                if case .commandRecognized(let command, _) = event,
                   claimedCommands.contains(command) {
                    await honoredBox.insert(command)
                    switch command {
                    case .quit:
                        await engine.stop()
                    case .skip:
                        await engine.markSkipped()
                    default:
                        break
                    }
                }
            }
        }
        // The watcher never outlives the run, on any exit path including a throw.
        defer { commandTask.cancel() }

        // Subscribe BEFORE starting: the iterator must exist before the engine
        // can emit, so no early event depends on the stream's buffering policy.
        var iterator = engine.events.makeAsyncIterator()

        // Start the match on the host-owned session (the module never releases it).
        await engine.start(voice: session)

        loop: while let event = await iterator.next() {
            switch event {
            case .matchStarted:
                break
            case .questionPresented:
                enter("reading")
            case .conferenceStarted:
                enter("conferring")
                await engine.skipConference()
            case .answerWindowOpened:
                enter("answering")
                if !remainingAnswers.isEmpty {
                    let answer = remainingAnswers.removeFirst()
                    await engine.submitAnswer(answer)
                } else {
                    await engine.markSkipped()
                }
            case .evaluated:
                enter("feedback")
                attempts += 1
                await engine.next()
            case .answerSkipped:
                await engine.next()
            case .matchEnded:
                reachedTerminalEvent = true
                break loop
            default:
                break
            }
        }

        // Let the concurrent command watcher drain any buffered claimed command
        // (e.g. a quit/skip injected up front by the conformance suite) before we
        // tear it down. Bounded so a genuinely empty stream never hangs the run.
        if !claimedCommands.isEmpty {
            for _ in 0..<50 where await honoredBox.isEmpty {
                await Task.yield()
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        let honored = await honoredBox.snapshot()

        return ConformanceRunResult(
            completed: reachedTerminalEvent,
            attemptsEvaluated: attempts,
            voiceStatesEntered: statesEntered,
            commandsHonored: honored
        )
    }
}

/// A tiny actor collecting the unified commands an activity honored during a run.
private actor HonoredCommands {
    private var commands: Set<VoiceCommand> = []
    func insert(_ command: VoiceCommand) { commands.insert(command) }
    func snapshot() -> Set<VoiceCommand> { commands }
    var isEmpty: Bool { commands.isEmpty }
}
