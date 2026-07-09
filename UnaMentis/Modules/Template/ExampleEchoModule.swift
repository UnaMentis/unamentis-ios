// UnaMentis - Example Echo Module (module SDK template + tutorial)
// =============================================================================
// This file is the SMALLEST COMPLETE UnaMentis module. It exists to be read: a
// working, conformance-passing module you copy and adapt. Every contract
// touchpoint is annotated with the MODULE_SDK_SPEC.md section it satisfies. Start
// here, then read docs/ios/MODULE_AUTHORING.md for the surrounding process.
//
// What it does: an "echo drill". The app speaks a word, the learner echoes it,
// the host evaluates the echo with fuzzy matching, the module records the
// attempt, and after three rounds it speaks a summary. That is the entire
// voice-first loop a real module runs, minus the domain richness.
//
// It is registered GATED (DEBUG builds only, see ModuleCatalog) so it ships in no
// release. It is `engine: .custom`: it does not sit on QuizMatchEngine, so it
// shows the runtime contract at its most direct, driving host services itself.
// =============================================================================

import SwiftUI

// MARK: - Module

/// The template module. Conforms to `ModuleProtocol` (the app's evolving form of
/// the spec's `UnaMentisModule`, section 4.1) and to `ConformanceDrivable` so the
/// UM-Voice conformance suite can drive its voice activity headlessly.
public struct ExampleEchoModule: ModuleProtocol {

    // -------------------------------------------------------------------------
    // 1. MANIFEST (MODULE_SDK_SPEC.md section 3)
    //
    // The manifest is the single source of truth for a module's identity and
    // requirements. It is compiled in for first-party modules. The derived
    // display properties (id, name, version, capability booleans) come from it
    // via the ModuleProtocol extension, so metadata lives in exactly one place.
    // -------------------------------------------------------------------------
    public let manifest = ModuleManifest(
        // Reverse-DNS-ish, globally unique, STABLE FOREVER: it namespaces this
        // module's progress data (section 3, "id"). Never change it once shipped.
        specVersion: "0.1.0",
        id: "com.unamentis.template.echo",
        name: "Echo Drill (Template)",
        // Semver. Bump on releases; UM-Core checks this is MAJOR.MINOR.PATCH.
        version: "1.0.0",
        // This module builds nothing on a shared engine; it is `custom`
        // (section 6.4). Engine-based modules use .quizMatch/.oralExam/.drill.
        engine: .custom,
        // phone is required (section 8). This module is also fully hands-free, so
        // it declares audio-only: it commits its voice activity runs screen-locked
        // (section 8), a commitment UM-Voice certifies.
        surfaces: [.phone, .audioOnly],
        // Open, namespaced module-feature capabilities (section 3). This template
        // advertises none of the optional feature flags.
        capabilities: [],
        // Host capabilities this module CANNOT run without (section 3). The
        // catalog hides a module whose required capabilities the build lacks.
        // The echo drill needs to speak/listen, evaluate, record, and report
        // telemetry: those four host services, at the versions this build ships.
        requiresHostCapabilities: [
            "voice.session/1",
            "eval.text-fuzzy/1",
            "progress/1",
            "telemetry/1"
        ],
        // Capabilities used when present but degraded without. None here.
        optionalHostCapabilities: [],
        // Honest estimate of the share completable by voice (section 3). The echo
        // drill is 100% voice, so 1.0. UM-Core checks this is within 0...1.
        voiceCoverage: VoiceCoverage(declared: 1.0),
        // Server tiers implemented. Tier 0 (offline) is mandatory (section 3).
        // The echo drill is entirely offline.
        serverTiers: [0],
        // Locales the module resolves. At least one, nonempty (section 9).
        locales: ["en-US"],
        // Content pack declarations (section 3). The echo words are an inlined
        // fixed pack (see EchoPack); a real module lists its bundled pack ids and
        // the item schemas it consumes, and reads them through host.content.
        contentPacks: ContentPacks(bundled: [], compatibleSchemas: []),
        // Declarative privacy facts feeding consent UI (sections 3, 11). The
        // drill listens (collects audio) but keeps no transcripts and shares
        // nothing.
        privacy: Privacy(
            collectsAudio: true,
            storesTranscripts: false,
            sharesWithMentor: .never
        ),
        minPlatform: MinPlatform(ios: "18.0")
    )

    // Display copy the manifest does not carry. A real module localizes these.
    public let shortDescription = "A tiny voice-first echo drill: the SDK template."
    public let longDescription = """
        The smallest complete UnaMentis module. It speaks a word, listens for \
        your echo, evaluates it, and after three rounds gives a summary. Read \
        its source: it is the module SDK tutorial.
        """
    public let iconName = "waveform"
    public let themeColor = Color.teal

    public init() {}

    // -------------------------------------------------------------------------
    // 2. LIFECYCLE (MODULE_SDK_SPEC.md section 4.1)
    //
    // initialize is called once per app launch before any UI, receiving the host
    // service bundle. start/pause/resume/stop bracket the module surface being
    // active. Defaults are no-ops (see the ModuleProtocol extension); this module
    // has no long-lived resources, so it keeps the no-op start/pause/resume/stop
    // and only overrides initialize to stash the host it will drive.
    //
    // The host is captured through an actor-isolated holder because a struct
    // module value cannot store mutable state. A real module usually owns a
    // reference-type coordinator; the template keeps the surface minimal.
    // -------------------------------------------------------------------------
    public func initialize(host: ModuleHost) async throws {
        await EchoModuleRuntime.shared.setHost(host)
    }

    // -------------------------------------------------------------------------
    // 3. PHONE SURFACE (MODULE_SDK_SPEC.md section 4.2)
    //
    // The root view is the module's full experience; the dashboard view is the
    // compact card in the Learning tab. Both are AnyView factories. The template
    // ships a minimal SwiftUI root that starts the same voice activity the
    // conformance suite drives headlessly.
    // -------------------------------------------------------------------------
    @MainActor
    public func makeRootView() -> AnyView {
        AnyView(ExampleEchoRootView())
    }

    @MainActor
    public func makeDashboardView() -> AnyView {
        AnyView(ExampleEchoDashboard())
    }
}

// MARK: - 4. THE VOICE ACTIVITY (headless-drivable)

// The echo drill itself, factored out of the SwiftUI view so the SAME code path
// runs from the root view AND from the conformance harness (zero touch). This is
// the pattern every voice-first module follows: the activity is a plain async
// function over host services and a VoiceSession, and the UI is a thin shell that
// acquires the session and calls it.
extension ExampleEchoModule: ConformanceDrivable {
    /// The one voice-first activity this module exposes (section 5.6 taxonomy).
    public var primaryVoiceActivity: ModuleActivityKind { ModuleActivityKind("echo-drill") }

    /// The unified commands the drill honors (section 9). Quit ends the drill;
    /// skip drops the current word without recording an attempt.
    public var claimedVoiceCommands: Set<VoiceCommand> { [.quit, .skip] }

    /// Run the echo drill to completion driven ONLY by the supplied session.
    ///
    /// The host owns the session (acquire/release); this activity speaks,
    /// listens, evaluates, records, and returns. It never touches UI.
    public func runPrimaryVoiceActivity(
        host: ModuleHost,
        session: any VoiceSession,
        script: ConformanceVoiceScript
    ) async throws -> ConformanceRunResult {
        try await EchoDrill.run(
            moduleId: manifest.id,
            host: host,
            session: session,
            rounds: script.roundCount ?? EchoPack.words.count,
            claimedCommands: claimedVoiceCommands
        )
    }
}

/// The echo drill logic. A free enum so it is trivially testable and shared by
/// the view and the conformance path.
enum EchoDrill {
    static func run(
        moduleId: String,
        host: ModuleHost,
        session: any VoiceSession,
        rounds: Int,
        claimedCommands: Set<VoiceCommand>
    ) async throws -> ConformanceRunResult {
        // Announce activity start telemetry (section 5.6 required taxonomy). The
        // drill is voice-initiated when driven hands-free.
        await host.telemetry.record(
            .activityStart(kind: ModuleActivityKind("echo-drill"), voiceInitiated: true),
            module: moduleId
        )

        // Watch for unified commands the host recognizes on the session's event
        // stream (section 5.1). Quit stops the drill; skip drops the current word.
        let control = EchoDrillControl()
        let commandTask = Task {
            for await event in session.events {
                if case .commandRecognized(let command, _) = event,
                   claimedCommands.contains(command) {
                    await control.honor(command)
                }
            }
        }

        var attempts = 0
        let statesEntered: [ModuleVoiceState] = [
            ModuleVoiceState(rawValue: "prompting"),
            ModuleVoiceState(rawValue: "listening")
        ]

        // Register a per-state command vocabulary (section 5.1): while listening,
        // "skip" and "quit" are valid. The host filters state-valid commands.
        await session.registerCommands(
            CommandVocabulary(commands: claimedCommands),
            for: ModuleVoiceState(rawValue: "listening")
        )

        roundLoop: for round in 0..<max(1, rounds) {
            if await control.quitRequested { break }

            let word = EchoPack.words[round % EchoPack.words.count]

            // 4a. SPEAK the prompt through the host pipeline (section 5.1). The
            // module never synthesizes audio itself. The word is spoken as its own
            // final utterance so it is unambiguous what the learner should echo.
            await session.setActiveVoiceState(ModuleVoiceState(rawValue: "prompting"))
            try await session.speak(.text("Say this word back to me."))
            try await session.speak(.text(word))

            // 4b. LISTEN for the learner's echo (section 5.1). Endpointing follows
            // the host's acquired config. A cancelled listen (quit) throws.
            await session.setActiveVoiceState(ModuleVoiceState(rawValue: "listening"))
            let heard: UtteranceResult
            do {
                heard = try await session.listen(expecting: .answer)
            } catch is CancellationError {
                break roundLoop
            }

            if await control.skipRequested {
                await control.clearSkip()
                continue  // skip: no attempt recorded, matching drill semantics
            }

            // 4c. EVALUATE the echo via the host service using fuzzy text matching
            // (section 5.2, capability eval.text-fuzzy/1). The module supplies the
            // spec; the host owns the matching algorithm.
            let spec = EvaluationSpec(
                primaryAnswer: word,
                category: .text,
                strictness: StrictnessProfile(id: "template-standard", level: .standard),
                evaluatorTiers: [.textExact, .textFuzzy]
            )
            let result = await host.evaluation.evaluate(
                LearnerResponse(text: heard.transcript), against: spec
            )
            let correct = result.verdict == .correct

            // 4d. Play an earcon and RECORD the attempt (sections 5.1, 5.4, 5.6).
            await session.playCue(correct ? .correct : .incorrect)
            await host.progress.store(AttemptRecord(
                module: moduleId,
                domain: StandardDomain("vocabulary"),
                itemId: word,
                response: heard.transcript,
                correct: correct,
                latencyMs: 0
            ))
            await host.telemetry.record(
                .attempt(outcome: correct ? .correct : .incorrect, latencyMs: 0),
                module: moduleId
            )
            attempts += 1
        }

        // 4e. SUMMARY (spoken), then activity-end telemetry. This is the natural
        // completion the audio-only surface reaches with the screen locked.
        try? await session.speak(.text("Echo drill complete. You did \(attempts) rounds."))
        await host.telemetry.record(
            .activityEnd(kind: ModuleActivityKind("echo-drill")), module: moduleId
        )

        // Drain any buffered claimed command before tearing the watcher down.
        if !claimedCommands.isEmpty {
            for _ in 0..<50 where await control.honored.isEmpty {
                await Task.yield()
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        commandTask.cancel()

        // The module does NOT release the session: the host owns its lifecycle.
        return ConformanceRunResult(
            completed: true,
            attemptsEvaluated: attempts,
            voiceStatesEntered: statesEntered,
            commandsHonored: await control.honored
        )
    }
}

/// Concurrency-safe control state for the drill's command handling.
private actor EchoDrillControl {
    private(set) var honored: Set<VoiceCommand> = []
    private var quit = false
    private var skip = false

    var quitRequested: Bool { quit }
    var skipRequested: Bool { skip }

    func honor(_ command: VoiceCommand) {
        honored.insert(command)
        switch command {
        case .quit: quit = true
        case .skip: skip = true
        default: break
        }
    }

    func clearSkip() { skip = false }
}

// MARK: - 5. CONTENT (the "pack")

/// The echo drill's word list. A real module reads its content through
/// `host.content` (the ContentStore, section 5.3), which verifies pack integrity
/// and schema compatibility. The template inlines a fixed three-word pack so it
/// stays dependency-free and hermetic; treat this as the stand-in for a bundled
/// `content.drill-items/1` pack.
enum EchoPack {
    static let words = ["apple", "bridge", "compass"]
}

// MARK: - Runtime holder

/// Holds the injected host so the struct module (a value type) can reach services
/// from its MainActor views. A real module usually owns a reference-type session
/// coordinator instead; this keeps the template minimal.
actor EchoModuleRuntime {
    static let shared = EchoModuleRuntime()
    private(set) var host: (any ModuleHost)?
    func setHost(_ host: any ModuleHost) { self.host = host }
}

// MARK: - 6. MINIMAL SWIFTUI SURFACE

/// The module's root view. Intentionally tiny: it explains what the drill is and
/// offers a start affordance. Wiring the button to acquire a live VoiceSession
/// and call `EchoDrill.run` is the exercise left to a real module (the headless
/// conformance path already proves the activity logic).
struct ExampleEchoRootView: View {
    @State private var isRunning = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform")
                .font(.system(size: 56))
                .foregroundStyle(.teal)
                .accessibilityHidden(true)
            Text("Echo Drill")
                .font(.largeTitle.bold())
            Text("Say each word back after you hear it. Three rounds, then a summary.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button {
                isRunning = true
            } label: {
                Label("Start Drill", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)  // 44pt minimum touch target (style guide)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            .accessibilityLabel("Start echo drill")
        }
        .padding()
        .navigationTitle("Echo Drill")
    }
}

/// The compact dashboard card for the Learning tab.
struct ExampleEchoDashboard: View {
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Echo Drill")
                    .font(.headline)
                Text("Voice-first SDK template")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
}
