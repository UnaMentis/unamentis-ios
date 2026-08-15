// UnaMentis - SAT Prep Conformance Drivability
// Adopts ConformanceDrivable so the SAT vocabulary drill (the module's primary
// voice activity) can run headlessly through the UM-Voice conformance suite
// (MODULE_SDK_SPEC.md section 9).
//
// The headless run is the SAME DrillEngine path the drill view model drives in
// production: it loads the sat-vocab-drill descriptor, builds DrillItems from the
// bundled pack, orders them per the descriptor's review policy, hands the
// host-owned VoiceSession to DrillEngine.start(voice:), and steps the round by
// consuming engine events. No SwiftUI, no DrillSessionView. This proves the drill
// completes with zero touch events, spoken prompts and voice-captured answers
// throughout.
//
// The unified command vocabulary is honored exactly as in the live activity: a
// quit ends the round, a skip drops the current item. Commands arrive on the
// VoiceSession's `events` stream (the host recognizes them), consumed alongside
// the engine's events by the shared SATDrillDriver.

import Foundation

extension SATPrepModule: ConformanceDrivable {
    /// SAT's primary voice-first activity is the vocabulary drill.
    public var primaryVoiceActivity: ModuleActivityKind {
        ModuleActivityKind("vocab-drill")
    }

    /// The unified commands the drill claims. Quit ends the round; skip drops the
    /// current item.
    public var claimedVoiceCommands: Set<VoiceCommand> {
        [.quit, .skip]
    }

    public func runPrimaryVoiceActivity(
        host: ModuleHost,
        session: any VoiceSession,
        script: ConformanceVoiceScript
    ) async throws -> ConformanceRunResult {
        let rounds = max(1, script.roundCount ?? 3)

        // Load the real descriptor and pack (Tier 0, offline, bundled), then
        // order the items through the SAME scheduling path the live drill uses
        // (DrillSessionModel.orderedItems): mastery read per skill tag from the
        // host progress store, fed to DrillScheduling.order under the
        // descriptor's own policy. Conformance runs the real loader and the real
        // ordering, so a broken pack or a broken scheduling policy fails here
        // too. The only difference from live is the session count: the script's
        // round count stands in for the descriptor's session shape, so the run
        // stays short and deterministic.
        let descriptor = try SATPrepPackLoader.descriptor(for: .vocab)
        let packItems = try SATPrepPackLoader.items(for: .vocab)
        let orderedItems = await SATDrillScheduling.ordered(
            packItems, policy: descriptor.schedulingPolicy, progress: host.progress
        )
        let roundItems = Array(orderedItems.prefix(rounds))
        let drillItems = roundItems.map { $0.drillItem() }

        // The scripted answers the driver submits, one per item: the item's
        // canonical answer, so every scripted round evaluates correct.
        let answers = roundItems.map(\.answer)

        let context = DrillHostContext(
            moduleId: manifest.id,
            evaluation: host.evaluation,
            progress: host.progress,
            telemetry: host.telemetry
        )
        // autoListen off: the driver steps the round explicitly (the headless
        // equivalent of the drill view model's control loop), keeping control flow
        // deterministic. Each prompt is still spoken through the host VoiceSession,
        // and each answer evaluated through the host, exactly as live.
        let engine = DrillEngine(
            descriptor: descriptor,
            options: DrillSessionOptions(activityKind: primaryVoiceActivity, autoListen: false),
            host: context,
            provider: { drillItems }
        )

        return try await SATDrillDriver.run(
            engine: engine,
            session: session,
            answers: answers,
            claimedCommands: claimedVoiceCommands
        )
    }

}

// MARK: - Shared Drill Driver

/// Steps a DrillEngine to completion by consuming its events, submitting scripted
/// answers, and honoring unified commands from the voice session. This is the
/// headless equivalent of the drill view model's control loop, shared by SAT
/// conformance and available to any drill-based module's driver (mirrors KB's
/// ConformanceEngineDriver for QuizMatch).
///
/// The result reports what the run OBSERVED: `completed` is true only when the
/// engine's terminal `.roundEnded` event arrived, and the voice states are the
/// ones the observed transitions actually entered.
enum SATDrillDriver {
    static func run(
        engine: DrillEngine,
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
        // cancellation), which is NOT the round running to its end. Only the
        // terminal `.roundEnded` event means the activity completed (section 9).
        var reachedTerminalEvent = false

        // Watch for unified commands on the session's event stream and route them.
        // Quit ends the round; skip drops the current item. The engine no-ops
        // actions that do not apply to its current state, as the live activity
        // does. Runs concurrently with the engine loop, cancelled at the end.
        let honoredBox = SATHonoredCommands()
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

        // Start the round on the host-owned session (the module never releases it).
        await engine.start(voice: session)

        loop: while let event = await iterator.next() {
            switch event {
            case .roundStarted:
                break
            case .itemPresented:
                enter("presenting")
            case .answerWindowOpened:
                enter("answering")
                if !remainingAnswers.isEmpty {
                    let answer = remainingAnswers.removeFirst()
                    await engine.submitAnswer(answer)
                } else {
                    await engine.markSkipped()
                }
            case .listening:
                enter("listening")
            case .evaluated:
                enter("feedback")
                attempts += 1
                await engine.next()
            case .itemSkipped:
                await engine.next()
            case .roundEnded:
                reachedTerminalEvent = true
                break loop
            default:
                break
            }
        }

        // Let the concurrent command watcher drain a buffered claimed command
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

/// A tiny actor collecting the unified commands a run honored.
private actor SATHonoredCommands {
    private var commands: Set<VoiceCommand> = []
    func insert(_ command: VoiceCommand) { commands.insert(command) }
    func snapshot() -> Set<VoiceCommand> { commands }
    var isEmpty: Bool { commands.isEmpty }
}
