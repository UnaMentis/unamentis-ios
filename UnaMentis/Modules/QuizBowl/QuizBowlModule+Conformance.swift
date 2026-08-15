// UnaMentis - Quiz Bowl Conformance Drivability
// Adopts ConformanceDrivable so Quiz Bowl's tossup practice runs headlessly
// through the UM-Voice conformance suite (MODULE_SDK_SPEC.md section 9).
//
// The headless run is the SAME engine path QBPracticeSessionView drives in
// production: it loads the NAQT format descriptor, maps a small deterministic
// set of QB items onto QuizMatchQuestions, hands the host-owned VoiceSession to
// QuizMatchEngine.start(voice:), and steps the match by consuming engine events
// via the shared ConformanceEngineDriver (the same driver KB uses). No SwiftUI,
// zero touch. This proves NAQT tossup practice completes hands-free.
//
// Quit ends the match; skip drops the current question. Commands arrive on the
// VoiceSession's events stream (the host recognizes them), which the driver
// consumes alongside the engine's events.
//
// Writing style: no em dashes (see .claude/rules/writing-style.md).

import Foundation

extension QuizBowlModule: ConformanceDrivable {
    /// Quiz Bowl's primary voice-first activity is NAQT tossup practice.
    public var primaryVoiceActivity: ModuleActivityKind {
        ModuleActivityKind("tossup-practice")
    }

    /// The unified commands Quiz Bowl tossup practice claims. Quit ends the
    /// session; skip drops the current tossup.
    public var claimedVoiceCommands: Set<VoiceCommand> {
        [.quit, .skip]
    }

    public func runPrimaryVoiceActivity(
        host: ModuleHost,
        session: any VoiceSession,
        script: ConformanceVoiceScript
    ) async throws -> ConformanceRunResult {
        let rounds = max(1, script.roundCount ?? 3)

        // NAQT format descriptor: pyramidal, individual buzz, 10/15/-5, bonuses.
        let descriptor = try QuizMatchFormatDescriptor.load(named: QBFormat.naqt.id)

        // A small deterministic tossup set (Tier 0, offline: no server, no pack
        // dependency, so conformance is hermetic). Answers are echoed back by the
        // harness session, so they double as the scripted responses.
        let sampleItems = QBConformanceContent.sampleTossups(count: rounds)
        let engineQuestions = sampleItems.map(QBQuestionMapper.engineQuestion(from:))

        let context = QuizMatchHostContext(
            moduleId: manifest.id,
            evaluation: host.evaluation,
            progress: host.progress,
            telemetry: host.telemetry
        )
        // autoListen off: the shared driver steps the match explicitly (the
        // headless equivalent of the practice view model's control loop). The
        // tossup is still spoken through the host session, and each answer is
        // evaluated through the host, exactly as in the live activity.
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

        // The scripted answers the driver submits, one per round (the primary
        // answers, which are correct).
        let answers = sampleItems.map(\.answer.primary)

        return try await ConformanceEngineDriver.run(
            engine: engine,
            session: session,
            answers: answers,
            claimedCommands: claimedVoiceCommands
        )
    }
}

// MARK: - Hermetic Conformance Content

/// A tiny, self-contained set of pyramidal tossups for headless conformance and
/// engine tests. Kept separate from the bundled packs so conformance never
/// depends on resource loading.
enum QBConformanceContent {
    static func sampleTossups(count: Int) -> [QBItem] {
        let seeds: [(id: String, answer: String, domain: String)] = [
            ("conf-t1", "chlorophyll", "science"),
            ("conf-t2", "shakespeare", "literature"),
            ("conf-t3", "napoleon", "history")
        ]
        return (0..<count).map { index in
            let seed = seeds[index % seeds.count]
            return QBItem(
                id: "\(seed.id)-\(index)",
                text: "This is pyramidal conformance tossup number \(index + 1). "
                    + "For 10 points, name the answer.",
                answer: QBAnswer(primary: seed.answer),
                domain: seed.domain,
                powerMarkIndex: 20
            )
        }
    }
}
