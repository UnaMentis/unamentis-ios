// UnaMentis - Oral Exam Studio Conformance Drivability
// Adopts ConformanceDrivable so the module's question-volley activity can run
// headlessly through the UM-Voice conformance suite (MODULE_SDK_SPEC.md
// section 9).
//
// The headless run is the SAME engine path the session view model drives in
// production: a volley-mode OralExamEngine over the practice-viva stage shape,
// speaking through the host-owned VoiceSession and recording attempts through
// host progress/telemetry. The examiner is the deterministic rule-based brain
// (the module's offline Tier 0 floor), so conformance is hermetic: no LLM, no
// network, no bundle resources.
//
// The unified command vocabulary is honored exactly as in the live activity:
// quit ends the session, skip drops the current examiner question.

import Foundation

extension OralExamModule: ConformanceDrivable {
    /// The primary voice-first activity: rapid question volleys.
    public var primaryVoiceActivity: ModuleActivityKind {
        ModuleActivityKind("question-volley")
    }

    /// Quit ends the session; skip drops the current examiner question.
    public var claimedVoiceCommands: Set<VoiceCommand> {
        [.quit, .skip]
    }

    public func runPrimaryVoiceActivity(
        host: ModuleHost,
        session: any VoiceSession,
        script: ConformanceVoiceScript
    ) async throws -> ConformanceRunResult {
        let rounds = max(1, script.roundCount ?? 3)

        // A hermetic volley descriptor mirroring practice-viva's questioning
        // stage (Tier 0, offline: no bundle dependency in conformance).
        let descriptor = OralExamFormatDescriptor(
            formatId: "conformance-volley",
            language: "en-US",
            stages: [
                .init(kind: .questioning, seconds: 240, style: "conversation", followUpDepth: 1)
            ],
            rubric: ["structure", "clarity", "interaction"],
            examiner: .init(personaCount: 1, register: "encouraging"),
            evaluation: .init(tiers: ["llmRubric"], deliveryMetrics: ["pace", "fillerWords", "hesitations"]),
            listening: .init(responseSilenceSec: 2.0, maxUtteranceSec: 180)
        )

        // A deterministic topic (the same shape a pack item maps to).
        let topic = OralExamTopic(
            id: "conformance-topic",
            title: "the water cycle",
            summary: "Evaporation, condensation, precipitation, and collection move water "
                + "between oceans, atmosphere, and land in a continuous cycle.",
            exemplarQuestions: [
                "What drives evaporation in the water cycle?",
                "How does condensation form clouds?",
                "Why does precipitation vary by region?"
            ],
            rubricHints: ["Strong answers name the energy source and trace one full loop."],
            domain: "science"
        )

        let context = OralExamHostContext(
            moduleId: manifest.id,
            progress: host.progress,
            telemetry: host.telemetry
        )
        let engine = OralExamEngine(
            descriptor: descriptor,
            mode: .questionVolley(rootQuestions: rounds),
            // Feedback stays spoken (voice-first), and the clock is
            // accelerated so a stalled run cannot hang the suite behind a
            // four-minute stage timer.
            options: OralExamSessionOptions(clockRate: 50, speakFeedbackSummary: true),
            topic: topic,
            host: context,
            examiner: RuleBasedExaminerBrain()
        )

        // The activity telemetry pair is balanced on EVERY exit path: an
        // activityStart with no matching activityEnd would corrupt the section
        // 5.6 taxonomy the moment the run threw. `defer` cannot await, so the
        // end event is emitted on both the success and the failure path.
        await host.telemetry.record(
            .activityStart(kind: primaryVoiceActivity, voiceInitiated: true),
            module: manifest.id
        )
        do {
            let result = try await OralExamConformanceDriver.run(
                engine: engine,
                session: session,
                claimedCommands: claimedVoiceCommands
            )
            await host.telemetry.record(
                .activityEnd(kind: primaryVoiceActivity),
                module: manifest.id
            )
            return result
        } catch {
            await host.telemetry.record(
                .activityEnd(kind: primaryVoiceActivity),
                module: manifest.id
            )
            throw error
        }
    }
}

// MARK: - Headless Engine Driver

/// Steps an OralExamEngine session to completion by consuming its events and
/// honoring unified commands from the voice session. The headless equivalent
/// of the session view model's control loop (the ConformanceEngineDriver
/// pattern from Knowledge Bowl).
///
/// The result reports what the run OBSERVED: `completed` is true only when the
/// engine's terminal `.sessionEnded` event arrived, and the voice states are the
/// ones the observed transitions actually entered.
enum OralExamConformanceDriver {
    static func run(
        engine: OralExamEngine,
        session: any VoiceSession,
        claimedCommands: Set<VoiceCommand>
    ) async throws -> ConformanceRunResult {
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
        // cancellation), which is NOT the session running to its end. Only the
        // terminal `.sessionEnded` event means the activity completed (section 9).
        var reachedTerminalEvent = false

        await session.registerCommands(
            CommandVocabulary(commands: claimedCommands),
            for: ModuleVoiceState(rawValue: "answering")
        )

        // Route recognized unified commands to engine commands, recording what
        // was honored. Runs concurrently with the engine loop.
        let honoredBox = OralExamHonoredCommands()
        let commandTask = Task {
            for await event in session.events {
                if case .commandRecognized(let command, _) = event,
                   claimedCommands.contains(command) {
                    await honoredBox.insert(command)
                    switch command {
                    case .quit:
                        await engine.stop()
                    case .skip:
                        await engine.skipQuestion()
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

        // Start on the host-owned session (the module never releases it).
        await engine.start(voice: session)

        var attempts = 0
        loop: while let event = await iterator.next() {
            switch event {
            case .promptSpoken, .followUpAsked:
                enter("questioning")
            case .listeningStarted:
                enter("answering")
            case .responseCaptured(_, let transcript, _):
                if !transcript.isEmpty {
                    attempts += 1
                }
            case .feedbackReady:
                enter("feedback")
            case .sessionEnded:
                reachedTerminalEvent = true
                break loop
            default:
                break
            }
        }

        // Let the concurrent command watcher drain any buffered claimed
        // command (e.g. a quit injected up front by the suite) before
        // teardown. Bounded so an empty stream never hangs the run.
        if !claimedCommands.isEmpty {
            for _ in 0..<50 where await honoredBox.isEmpty {
                await Task.yield()
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        return ConformanceRunResult(
            completed: reachedTerminalEvent,
            attemptsEvaluated: attempts,
            voiceStatesEntered: statesEntered,
            commandsHonored: await honoredBox.snapshot()
        )
    }
}

/// Collects the unified commands the activity honored during a run.
private actor OralExamHonoredCommands {
    private var commands: Set<VoiceCommand> = []
    func insert(_ command: VoiceCommand) { commands.insert(command) }
    func snapshot() -> Set<VoiceCommand> { commands }
    var isEmpty: Bool { commands.isEmpty }
}
