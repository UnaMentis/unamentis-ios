// UnaMentis - Aural Skills Drill Session
// The module's drill loop, factored as a plain async function over host
// services and a VoiceSession so the SAME code path runs from the SwiftUI
// session view, the audio-only surface, and the UM-Voice conformance harness
// (zero touch). This is the ExampleEchoModule pattern with the aural domain:
//
//   play prompt (host tone generation through the ONE pipeline)
//   -> listen for a spoken label
//   -> evaluate against the module's music profile
//   -> feedback (confirm, or name the answer, replay, coach with solfège)
//   -> record attempt + mastery + telemetry
//
// Repeat-on-request is honored both as the unified `repeatLast` command and
// as a plain spoken "repeat"/"again" transcript.

import Foundation

// MARK: - Skill Areas

/// The five drillable skill areas shown on the dashboard.
public enum AuralSkillArea: String, CaseIterable, Sendable, Identifiable {
    case intervals
    case chords
    case tonality
    case cadences
    case solfege

    public var id: String { rawValue }

    /// Display name for dashboard cards and summaries.
    public var displayName: String {
        switch self {
        case .intervals: return "Intervals"
        case .chords: return "Chords"
        case .tonality: return "Major and Minor"
        case .cadences: return "Cadences"
        case .solfege: return "Solfège"
        }
    }

    /// The unified-proficiency domain this area reports into.
    public var domain: StandardDomain {
        StandardDomain("music.\(rawValue)")
    }

    /// The item kinds belonging to this area.
    var itemKinds: Set<String> {
        switch self {
        case .intervals: return ["interval"]
        case .chords: return ["triad"]
        case .tonality: return ["tonality"]
        case .cadences: return ["cadence"]
        case .solfege: return ["solfege"]
        }
    }

    /// The area an item belongs to.
    static func area(for item: AuralItem) -> AuralSkillArea {
        allCases.first { $0.itemKinds.contains(item.kind) } ?? .intervals
    }

    /// The spoken question for this area's items.
    var spokenQuestion: String {
        switch self {
        case .intervals: return "What interval is this?"
        case .chords: return "What kind of triad is this?"
        case .tonality: return "Is this major or minor?"
        case .cadences: return "What cadence is this?"
        case .solfege: return "The key chord, then a note. Which solfège degree is it?"
        }
    }
}

// MARK: - Drill Control

/// Concurrency-safe control state shared by the command watcher, the drill
/// loop, and the UI (the replay button drives `requestRepeat`).
actor AuralDrillControl {
    private(set) var honored: Set<VoiceCommand> = []
    private var quit = false
    private var skip = false
    private var repeatRequested = false

    var quitRequested: Bool { quit }
    var skipRequested: Bool { skip }

    func honor(_ command: VoiceCommand) {
        honored.insert(command)
        switch command {
        case .quit: quit = true
        case .skip: skip = true
        case .repeatLast: repeatRequested = true
        default: break
        }
    }

    /// UI replay affordance: same path as the voice command.
    func requestRepeat() {
        honor(.repeatLast)
    }

    func consumeRepeat() -> Bool {
        let requested = repeatRequested
        repeatRequested = false
        return requested
    }

    func clearSkip() { skip = false }
}

// MARK: - UI Observer

/// Optional UI mirror of drill progress. Callbacks are MainActor closures so
/// a view model can bind published state directly; the conformance/headless
/// path passes nil so the loop stays UI-free.
public struct AuralDrillObserver: Sendable {
    public var onStatus: @MainActor @Sendable (String) -> Void
    public var onTranscript: @MainActor @Sendable (String) -> Void
    public var onFeedback: @MainActor @Sendable (String, Bool) -> Void
    public var onProgress: @MainActor @Sendable (Int, Int, Int) -> Void  // itemIndex, total, correct

    public init(
        onStatus: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onTranscript: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onFeedback: @escaping @MainActor @Sendable (String, Bool) -> Void = { _, _ in },
        onProgress: @escaping @MainActor @Sendable (Int, Int, Int) -> Void = { _, _, _ in }
    ) {
        self.onStatus = onStatus
        self.onTranscript = onTranscript
        self.onFeedback = onFeedback
        self.onProgress = onProgress
    }
}

// MARK: - Drill

/// The drill loop. A free enum (no state) so it is trivially testable and
/// shared by the view and the conformance path.
enum AuralDrill {
    /// The standard round length. The conformance script and tests override.
    static let defaultRoundLength = 10

    /// Mastery below this per-area threshold keeps the drill on easy items.
    static let easyMasteryThreshold: Double = 50

    static func run(
        moduleId: String,
        host: ModuleHost,
        session: any VoiceSession,
        area: AuralSkillArea?,
        rounds: Int,
        claimedCommands: Set<VoiceCommand>,
        control: AuralDrillControl = AuralDrillControl(),
        shuffle: Bool = true,
        overrideItems: [AuralItem]? = nil,
        observer: AuralDrillObserver? = nil
    ) async throws -> ConformanceRunResult {
        let activityKind = ModuleActivityKind("aural-drill")
        await host.telemetry.record(
            .activityStart(kind: activityKind, voiceInitiated: true),
            module: moduleId
        )

        // Watch for unified commands recognized by the host on the session's
        // event stream. Quit ends the round; skip drops the current item;
        // repeat replays the prompt.
        let commandTask = Task {
            for await event in session.events {
                if case .commandRecognized(let command, _) = event,
                   claimedCommands.contains(command) {
                    await control.honor(command)
                }
            }
        }
        // The watcher never outlives the drill, on any exit path: a spoken
        // prompt that throws must not leak it.
        defer { commandTask.cancel() }

        // The voice states the drill actually entered, recorded as it enters
        // them (first-seen order), never listed up front.
        var statesEntered: [ModuleVoiceState] = []
        func enter(_ name: String) -> ModuleVoiceState {
            let state = ModuleVoiceState(rawValue: name)
            if !statesEntered.contains(state) { statesEntered.append(state) }
            return state
        }

        // Completion is TRACKED, never assumed: the drill completes when it
        // reaches its summary, either by running its scheduled rounds or by
        // honoring a quit that ends it cleanly. A cancelled listen tears the
        // round down mid-flight, and that is not completion (section 9).
        var endedByCancellation = false

        await session.registerCommands(
            CommandVocabulary(commands: claimedCommands),
            for: ModuleVoiceState(rawValue: "listening")
        )

        // Select the round's items: mastery-aware difficulty, then order.
        let items: [AuralItem]
        if let overrideItems {
            items = overrideItems
        } else {
            let pool = try await selectPool(host: host, area: area, shuffle: shuffle)
            items = pool
        }
        guard !items.isEmpty else {
            throw AuralSkillsError.noItemsAvailable
        }

        var attempts = 0
        var correctCount = 0

        roundLoop: for round in 0..<max(1, rounds) {
            if await control.quitRequested { break }

            let item = items[round % items.count]
            let itemArea = AuralSkillArea.area(for: item)
            guard let tonePrompt = AuralPromptBuilder.prompt(for: item) else {
                continue
            }
            let toneUtterance: Utterance
            do {
                toneUtterance = try host.toneGeneration.utterance(
                    for: tonePrompt,
                    spokenFallback: "Here is the sound."
                )
            } catch {
                continue
            }

            // Prompt: ask, then play the synthesized sound through the
            // module's VoiceSession (the unified pipeline; RFC 0007).
            await observer?.onStatus("Listen closely.")
            await observer?.onProgress(round + 1, max(1, rounds), correctCount)
            await session.setActiveVoiceState(enter("prompting"))
            try await session.speak(.text(itemArea.spokenQuestion))
            try await session.speak(toneUtterance)

            // Listen, honoring repeat requests (spoken or command) by
            // replaying the prompt and listening again.
            let promptFinishedAt = Date()
            var heard: UtteranceResult?
            listenLoop: while true {
                if await control.quitRequested { break roundLoop }
                await observer?.onStatus("Your answer?")
                await session.setActiveVoiceState(enter("listening"))
                let result: UtteranceResult
                do {
                    result = try await session.listen(expecting: .answer)
                } catch is CancellationError {
                    endedByCancellation = true
                    break roundLoop
                }
                await observer?.onTranscript(result.transcript)

                if await control.quitRequested { break roundLoop }
                if await control.skipRequested {
                    await control.clearSkip()
                    await host.telemetry.record(
                        .attempt(outcome: .skipped, latencyMs: 0), module: moduleId
                    )
                    continue roundLoop
                }
                let repeatByCommand = await control.consumeRepeat()
                if repeatByCommand || isRepeatRequest(result.transcript) {
                    await observer?.onStatus("Playing it again.")
                    try await session.speak(toneUtterance)
                    continue listenLoop
                }
                heard = result
                break listenLoop
            }
            guard let heard else { continue }

            // Evaluate through the host service with the module's music
            // profile (eval.text-fuzzy/1).
            let spec = MusicEvaluation.spec(for: item)
            let evaluation = await host.evaluation.evaluate(
                LearnerResponse(text: heard.transcript), against: spec
            )
            let correct = evaluation.verdict == .correct
            let latencyMs = max(0, Int(Date().timeIntervalSince(promptFinishedAt) * 1000))

            // Feedback.
            await session.setActiveVoiceState(enter("feedback"))
            await session.playCue(correct ? .correct : .incorrect)
            if correct {
                correctCount += 1
                await observer?.onFeedback("Correct: \(item.answer.primary)", true)
                try await session.speak(.text("Correct. \(item.answer.primary)."))
            } else {
                await observer?.onFeedback("It was: \(item.answer.primary)", false)
                try await session.speak(.text("Not quite. That was \(item.answer.primary). Listen once more."))
                try await session.speak(toneUtterance)
                if let coaching = item.solfege?.coaching {
                    try await session.speak(.text(coaching))
                }
            }

            // Record: structured attempt, mastery observation, telemetry.
            await host.progress.store(AttemptRecord(
                module: moduleId,
                domain: itemArea.domain,
                itemId: item.id,
                response: heard.transcript,
                correct: correct,
                latencyMs: latencyMs
            ))
            await host.progress.reportMastery(MasteryObservation(
                module: moduleId,
                domain: itemArea.domain,
                signal: correct ? 100 : 0
            ))
            await host.telemetry.record(
                .attempt(outcome: correct ? .correct : .incorrect, latencyMs: latencyMs),
                module: moduleId
            )
            attempts += 1
        }

        // Spoken round summary, then activity-end telemetry.
        let summary = attempts > 0
            ? "Round complete. \(correctCount) out of \(attempts) correct."
            : "Round ended."
        await observer?.onStatus(summary)
        try? await session.speak(.text(summary))
        await host.telemetry.record(.activityEnd(kind: activityKind), module: moduleId)

        // Drain any buffered claimed command before tearing the watcher down
        // (same pattern as the template module).
        if !claimedCommands.isEmpty {
            for _ in 0..<50 where await control.honored.isEmpty {
                await Task.yield()
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        // The module does NOT release the session; the host owns it.
        return ConformanceRunResult(
            completed: !endedByCancellation,
            attemptsEvaluated: attempts,
            voiceStatesEntered: statesEntered,
            commandsHonored: await control.honored
        )
    }

    /// Select the drill pool: filter by area, then apply the simple mastery
    /// ladder (below 50% mastery drill easy items only, otherwise mix all
    /// difficulties), then order.
    static func selectPool(
        host: ModuleHost,
        area: AuralSkillArea?,
        shuffle: Bool
    ) async throws -> [AuralItem] {
        let allItems = try await AuralContentLoader.shared.items(host: host)
        var pool = allItems
        if let area {
            pool = pool.filter { area.itemKinds.contains($0.kind) }
        }
        guard !pool.isEmpty else { return [] }

        let masteryDomains = Set(pool.map { AuralSkillArea.area(for: $0).domain.rawValue })
        var lowMastery = false
        for domainName in masteryDomains {
            let proficiency = await host.progress.proficiency(for: StandardDomain(domainName))
            if proficiency.mastery < easyMasteryThreshold || proficiency.observationCount == 0 {
                lowMastery = true
                break
            }
        }
        if lowMastery {
            let minDifficulty = pool.map(\.difficulty).min() ?? 1
            pool = pool.filter { $0.difficulty == minDifficulty }
        }
        return shuffle ? pool.shuffled() : pool
    }

    /// Whether a transcript is a request to hear the prompt again.
    static func isRepeatRequest(_ transcript: String) -> Bool {
        let normalized = transcript.lowercased()
            .replacingOccurrences(of: "[.,!?]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let phrases: Set<String> = [
            "repeat", "again", "repeat it", "repeat that", "repeat please",
            "play it again", "play that again", "one more time", "say again",
            "hear it again", "replay", "can i hear it again", "play again"
        ]
        return phrases.contains(normalized)
    }
}

// MARK: - Errors

/// Typed Aural Skills module errors.
public enum AuralSkillsError: Error, LocalizedError, Equatable {
    /// No items matched the requested drill (content pack missing or empty).
    case noItemsAvailable
    /// The bundled starter pack resources are missing from the app bundle.
    case bundledPackMissing
    /// A pack template named a kind the generator does not know.
    case unknownTemplateKind(String)
    /// A pack template named an interval, quality, or degree that is not in
    /// the theory tables.
    case unknownTemplateValue(field: String, value: String)
    /// A template root the host tone generator cannot play.
    case unplayableRoot(String)
    /// The correctly spelled note would need an accidental the host tone
    /// parser cannot read back (see AuralTheory.maxEmittableAccidental).
    case unspellableNote(root: String, semitonesAbove: Int)

    public var errorDescription: String? {
        switch self {
        case .noItemsAvailable:
            return "No aural training items are available for this drill."
        case .bundledPackMissing:
            return "The bundled aural training pack is missing."
        case .unknownTemplateKind(let kind):
            return "The aural pack declares an unknown template kind '\(kind)'."
        case .unknownTemplateValue(let field, let value):
            return "The aural pack declares an unknown \(field) '\(value)'."
        case .unplayableRoot(let root):
            return "The aural pack declares a root note '\(root)' that cannot be played."
        case .unspellableNote(let root, let semitones):
            return "The note \(semitones) semitones above \(root) needs a double accidental, "
                + "which the tone generator cannot parse."
        }
    }
}
