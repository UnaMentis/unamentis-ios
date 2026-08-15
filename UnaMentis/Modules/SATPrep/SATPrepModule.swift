// UnaMentis - SAT Prep Module (Module D)
// MODULE_SDK_SPEC.md section 6.4 (custom module) built on the DrillEngine
// (section 6.3). MVP scope: two voice-assisted skill drills, vocabulary in
// context and mental math, over bundled CC-BY-4.0 content packs. Out of MVP
// scope (SAT_MODULE.md): MST simulation, score prediction, psychology trainer.
//
// This is an honest voice-ASSISTED module, not voice-first: a vocabulary drill
// and mental math work well by voice, but most SAT prep (reading passages,
// graphs, grid-ins, the adaptive test itself) needs the eyes and the screen. The
// manifest declares voiceCoverage 0.35 and the dashboard says so plainly.
//
// The module owns no audio, evaluation, storage, or telemetry: it consumes those
// from the host (section 5) and drives the shared DrillEngine, exactly as the KB
// module drives QuizMatchEngine. The one host file it touches is the catalog
// registration line (ModuleCatalog.swift).

import SwiftUI

// MARK: - Module

/// The SAT Preparation module. A `custom`-engine module (it coordinates drills
/// rather than sitting on a single engine), voice-assisted, phone-only for the
/// MVP.
public struct SATPrepModule: ModuleProtocol {

    // -------------------------------------------------------------------------
    // MANIFEST (MODULE_SDK_SPEC.md section 3)
    // -------------------------------------------------------------------------
    public let manifest = ModuleManifest(
        specVersion: "0.1.0",
        // Stable-forever slug id: it namespaces this module's progress data.
        id: "sat-prep",
        name: "SAT Prep",
        version: "1.0.0",
        // Custom: the module coordinates DrillEngine sub-activities (section 6.4).
        engine: .custom,
        // Phone only for the MVP. No watch or audio-only surface yet: SAT prep is
        // screen-heavy, so an honest module does not over-claim hands-free.
        surfaces: [.phone],
        capabilities: [],
        // Host capabilities the drills cannot run without: speak/listen, exact,
        // fuzzy and numeric evaluation, progress, and telemetry. All ship in this
        // build. eval.text-exact/1 is declared because every verbal item's spec
        // names the textExact tier, and conventions items are judged at the
        // strict level where exact and the listed alternatives carry the ruling.
        requiresHostCapabilities: [
            "voice.session/1",
            "eval.text-exact/1",
            "eval.text-fuzzy/1",
            "eval.numeric/1",
            "progress/1",
            "telemetry/1"
        ],
        optionalHostCapabilities: [],
        // Honest estimate: about a third of SAT prep is completable by voice
        // (vocabulary and mental math); the rest needs the screen. "Voice-assisted"
        // in the gallery (< 0.6).
        voiceCoverage: VoiceCoverage(declared: 0.35),
        // Tier 0 (offline) only for the MVP; all content is bundled.
        serverTiers: [0],
        locales: ["en-US"],
        // Bundled CC-BY-4.0 packs, schema drill-items/1.
        contentPacks: ContentPacks(
            bundled: ["sat-vocab-context", "sat-math-mental"],
            compatibleSchemas: ["drill-items/1"]
        ),
        // The drills listen (collect audio) but keep no transcripts and share
        // nothing.
        privacy: Privacy(
            collectsAudio: true,
            storesTranscripts: false,
            sharesWithMentor: .never
        ),
        minPlatform: MinPlatform(ios: "18.0")
    )

    public let shortDescription = "Voice-assisted SAT drills: vocabulary in context and mental math."
    // The adaptation claim is deliberately precise: review ordering sorts by the
    // stored mastery of an item's DOMAIN (the granularity the shared proficiency
    // model keeps), and an unpracticed domain reads as zero, so the areas you
    // have practiced least genuinely lead. Claiming per-skill adaptation would
    // over-state what the scheduler does.
    public let longDescription = """
        Practice SAT vocabulary in context and mental math by voice or on screen. \
        This module is voice-assisted: about a third of SAT prep works great by \
        voice, and the rest needs your eyes. Drills lead with the areas you have \
        practiced least or scored lowest in.
        """
    public let iconName = "graduationcap"
    public let themeColor = Color.indigo

    public init() {}

    // -------------------------------------------------------------------------
    // LIFECYCLE (MODULE_SDK_SPEC.md section 4.1)
    // -------------------------------------------------------------------------
    public func initialize(host: ModuleHost) async throws {
        await SATPrepRuntime.shared.setHost(host)
    }

    public func stop() async {
        await SATPrepRuntime.shared.stopActiveSession()
    }

    // -------------------------------------------------------------------------
    // PHONE SURFACE (MODULE_SDK_SPEC.md section 4.2)
    // -------------------------------------------------------------------------
    @MainActor
    public func makeRootView() -> AnyView {
        AnyView(SATDashboardView())
    }

    @MainActor
    public func makeDashboardView() -> AnyView {
        AnyView(SATPrepDashboardCard())
    }
}

// MARK: - Runtime

/// Holds the injected host so the struct module (a value type) can reach services
/// from its MainActor views and its conformance driver. A single actor keeps host
/// access and the active session coordinator in one Sendable place.
actor SATPrepRuntime {
    static let shared = SATPrepRuntime()

    private(set) var host: (any ModuleHost)?

    /// The drill currently holding an engine and a voice session, if any.
    ///
    /// Weak on purpose: the SwiftUI surface owns the model's lifetime, and a
    /// dismissed drill must not be kept alive by this registration. A live
    /// registration is what makes `SATPrepModule.stop()` mean something.
    private weak var activeSession: DrillSessionModel?

    func setHost(_ host: any ModuleHost) {
        self.host = host
    }

    /// Register the drill that is now running. Replaces any previous
    /// registration (only one drill runs at a time; the voice pipeline is
    /// exclusive).
    func setActiveSession(_ session: DrillSessionModel) {
        activeSession = session
    }

    /// Deregister `session`, but only while it is still the registered one. A
    /// teardown that lands after a newer drill registered must not clear the
    /// newer drill's registration.
    func clearActiveSession(_ session: DrillSessionModel) {
        if activeSession === session { activeSession = nil }
    }

    /// Stop the drill in flight and release the voice session it holds.
    ///
    /// The model's `end()` runs the centralized teardown: engine stopped first,
    /// then the session released, then the telemetry activity closed.
    func stopActiveSession() async {
        guard let session = activeSession else { return }
        // Clear before awaiting: teardown calls back in to deregister, and a
        // second stop arriving meanwhile must not start a second unwind.
        activeSession = nil
        await session.end()
    }
}
