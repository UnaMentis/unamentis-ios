// UnaMentis - Quiz Bowl Module (Module A)
// A first-party learning module for Quiz Bowl competition preparation, built on
// the generic QuizMatchEngine (MODULE_SDK_SPEC.md section 6.1). Quiz Bowl is the
// pyramidal, individual-buzz academic quiz format: clues run hardest to easiest,
// an early correct buzz earns a power, a wrong interrupt negs, and correct
// tossups earn a 3-part bonus.
//
// The module is descriptor-driven: NAQT, ACF, IHBB Europe, and UK Schools'
// Challenge are DATA (format descriptors plus content packs), not code. The
// module owns its manifest, its content mapping (QBQuestionMapper), its UI
// (QBDashboardView / QBPracticeSessionView), and its conformance driving
// (QuizBowlModule+Conformance). It owns no audio, evaluation, storage, or
// telemetry: those come from the host.
//
// Writing style: no em dashes (see .claude/rules/writing-style.md).

import SwiftUI
import Logging

/// The Quiz Bowl training module.
public struct QuizBowlModule: ModuleProtocol {
    // -------------------------------------------------------------------------
    // MANIFEST (MODULE_SDK_SPEC.md section 3)
    // The single source of truth for identity, capabilities, surfaces, and host
    // requirements. Required host capabilities are exactly the services the
    // engine path drives: the voice pipeline, fuzzy text evaluation, progress,
    // telemetry, content, and session registration. Every one is advertised by
    // this build (HostCapabilities.provided), so the module is shippable.
    // -------------------------------------------------------------------------
    public let manifest = ModuleManifest(
        specVersion: "0.1.0",
        id: "quiz-bowl",
        name: "Quiz Bowl",
        version: "1.0.0",
        engine: .quizMatch,
        surfaces: [.phone],
        // No "sim.opponent". The practice session runs `participantCount: 1`
        // and the rebound branch is a documented no-op ("Solo practice: no
        // rebound"), so claiming opponent simulation would light up
        // `supportsCompetitionSim` for a feature that does not exist. The
        // capability comes back when opponent simulation is actually wired.
        capabilities: ["voice.buzz", "training.speed"],
        requiresHostCapabilities: [
            "voice.session/1",
            "eval.text-fuzzy/1",
            "progress/1",
            "telemetry/1",
            "content.canonical-question/1",
            "session.registration/1"
        ],
        optionalHostCapabilities: [],
        voiceCoverage: VoiceCoverage(declared: 0.95),
        serverTiers: [0],
        // en-US only, deliberately, matching OralExamModule's standard. The IHBB
        // Europe and UK Schools' Challenge packs are en-GB CONTENT, but
        // VoicePipelineConfig.locale is accepted and NOT plumbed into STT
        // (RFC 0002 item 6), so those packs run on an en-US pipeline. Declaring
        // en-GB would claim a locale this build cannot resolve, which UM-Core
        // treats as dishonest. en-GB returns with the multilingual pipeline
        // spike, at which point the pack manifest's locale is plumbed into
        // `voicePipelineConfig(locale:)`.
        locales: ["en-US"],
        contentPacks: ContentPacks(
            bundled: [
                "qb-starter-naqt",
                "ihbb-europe-starter",
                "uk-schools-challenge-starter"
            ],
            compatibleSchemas: ["qb-question/1"]
        ),
        privacy: Privacy(
            collectsAudio: true,
            storesTranscripts: false,
            sharesWithMentor: .optIn
        ),
        minPlatform: MinPlatform(ios: "18.0")
    )

    // Display copy the manifest does not carry.
    public let shortDescription = "Pyramidal quiz practice with powers, negs, and bonuses"
    public let longDescription = """
        Train for Quiz Bowl with pyramidal tossups, buzz-in timing, power \
        hunting, and 3-part bonuses. Practice NAQT and ACF formats plus the \
        European IHBB and UK Schools' Challenge. Track your power rate, neg \
        rate, points per bonus, and buzz speed.
        """
    public let iconName = "bolt.horizontal.circle.fill"
    public let themeColor = Color.orange

    private static let logger = Logger(label: "com.unamentis.modules.quizbowl")

    public init() {
        Self.logger.info("Quiz Bowl module initialized")
    }

    // -------------------------------------------------------------------------
    // LIFECYCLE (MODULE_SDK_SPEC.md section 4.1)
    // Stash the host so MainActor views can reach services. No long-lived
    // resources, so start/pause/resume/stop stay the protocol no-ops.
    // -------------------------------------------------------------------------
    public func initialize(host: ModuleHost) async throws {
        await QuizBowlRuntime.shared.setHost(host)
    }

    // -------------------------------------------------------------------------
    // PHONE SURFACE (MODULE_SDK_SPEC.md section 4.2)
    // -------------------------------------------------------------------------
    @MainActor
    public func makeRootView() -> AnyView {
        AnyView(QBDashboardView())
    }

    @MainActor
    public func makeDashboardView() -> AnyView {
        AnyView(QBDashboardSummary())
    }
}

// MARK: - Runtime Holder

/// Holds the injected host so the value-type module can reach services from its
/// MainActor views, mirroring the template's runtime holder. The production host
/// is also reachable via ModuleCatalog.shared.host; this holder captures the one
/// passed to initialize(host:) so the same instance (including a test harness) is
/// used consistently.
actor QuizBowlRuntime {
    static let shared = QuizBowlRuntime()
    private(set) var host: (any ModuleHost)?
    func setHost(_ host: any ModuleHost) { self.host = host }
}

// MARK: - Dashboard Summary Card

/// The compact card shown in the Learning tab's module list.
struct QBDashboardSummary: View {
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Quiz Bowl")
                    .font(.headline)
                Text("Pyramidal tossups, powers, and bonuses")
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
