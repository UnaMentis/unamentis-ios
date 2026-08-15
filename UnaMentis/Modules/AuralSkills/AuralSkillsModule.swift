// UnaMentis - Aural Skills Trainer Module (Module C)
// Music ear training per AURAL_SKILLS_MODULE_SPEC.md: interval recognition,
// triad quality, major/minor discrimination, cadence recognition, and
// scale-degree solfège, drilled entirely by voice. Prompts are synthesized
// symbolically through the host tone generator (RFC 0007, audio.tonegen/1)
// and played through the module's VoiceSession on the unified pipeline.
//
// Phase 1 (MVP) scope: spoken-label responses only. Sung responses and rhythm
// echo arrive with eval.pitch-rhythm/1 (module spec section 5, capability
// candidate 2), which stays reserved.

import SwiftUI

// MARK: - Module

/// The Aural Skills Trainer module.
public struct AuralSkillsModule: ModuleProtocol {

    /// Manifest (MODULE_SDK_SPEC.md section 3).
    ///
    /// Engine note: this module is `.custom` for now. Its drill loop is a
    /// natural DrillEngine fit, but the shared DrillEngine (spec section 6.3)
    /// has not been extracted yet; adopting it is deliberate future work once
    /// the engine exists, so the module does not invent a private engine
    /// abstraction in the meantime.
    public let manifest = ModuleManifest(
        specVersion: "0.1.0",
        id: "aural-skills",
        name: "Aural Skills",
        version: "1.0.0",
        engine: .custom,
        surfaces: [.phone],
        capabilities: [],
        requiresHostCapabilities: [
            "voice.session/1",
            "eval.text-fuzzy/1",
            "audio.tonegen/1"
        ],
        // Progress and telemetry are consumed when present (this build ships
        // both); the drill degrades to non-persistent practice without them.
        optionalHostCapabilities: [
            "progress/1",
            "telemetry/1"
        ],
        voiceCoverage: VoiceCoverage(declared: 1.0),
        serverTiers: [0],
        locales: ["en-US"],
        contentPacks: ContentPacks(
            bundled: [AuralContentLoader.packId],
            compatibleSchemas: [AuralContentLoader.schema]
        ),
        privacy: Privacy(
            collectsAudio: true,
            storesTranscripts: false,
            sharesWithMentor: .never
        ),
        minPlatform: MinPlatform(ios: "18.0")
    )

    public let shortDescription = "Ear training by voice: intervals, chords, cadences, and solfège."
    public let longDescription = """
        Train your musical ear hands-free. The app plays synthesized intervals, \
        triads, and cadences; you name what you hear. Wrong answers get a replay \
        and movable-do solfège coaching. Aligned with ABRSM-style aural tests \
        while teaching listening as a universal skill.
        """
    public let iconName = "music.quarternote.3"
    public let themeColor = Color.indigo

    public init() {}

    public func initialize(host: ModuleHost) async throws {
        await AuralSkillsRuntime.shared.setHost(host)
    }

    @MainActor
    public func makeRootView() -> AnyView {
        AnyView(AuralSkillsDashboardView())
    }

    @MainActor
    public func makeDashboardView() -> AnyView {
        AnyView(AuralSkillsDashboardCard())
    }
}

// MARK: - Conformance Driving (UM-Voice)

extension AuralSkillsModule: ConformanceDrivable {
    /// The primary voice-first activity: the interval drill.
    public var primaryVoiceActivity: ModuleActivityKind { ModuleActivityKind("aural-drill") }

    /// Unified commands the drill honors. Quit ends the round, skip drops the
    /// current item, repeat replays the prompt.
    public var claimedVoiceCommands: Set<VoiceCommand> { [.quit, .skip, .repeatLast] }

    /// Run the interval drill to completion driven ONLY by the supplied
    /// session. Tone generation runs for real (pure synthesis, headless);
    /// playback goes wherever the session sends it (the scripted session in
    /// conformance, the unified pipeline in production).
    public func runPrimaryVoiceActivity(
        host: ModuleHost,
        session: any VoiceSession,
        script: ConformanceVoiceScript
    ) async throws -> ConformanceRunResult {
        try await AuralDrill.run(
            moduleId: manifest.id,
            host: host,
            session: session,
            area: .intervals,
            rounds: script.roundCount ?? AuralDrill.defaultRoundLength,
            claimedCommands: claimedVoiceCommands
        )
    }
}

// MARK: - Runtime holder

/// Holds the injected host so the struct module (a value type) can reach
/// services from its MainActor views.
///
/// The views go through `currentHost()` rather than reaching for
/// `ModuleCatalog.shared.host` themselves, so the drill uses the SAME service
/// bundle the host injected at `initialize(host:)`. The catalog is only the
/// fallback for a view that renders before initialize (previews).
actor AuralSkillsRuntime {
    static let shared = AuralSkillsRuntime()
    private(set) var host: (any ModuleHost)?

    func setHost(_ host: any ModuleHost) { self.host = host }

    @MainActor
    static func currentHost() async -> any ModuleHost {
        if let host = await shared.host {
            return host
        }
        return ModuleCatalog.shared.host
    }
}
