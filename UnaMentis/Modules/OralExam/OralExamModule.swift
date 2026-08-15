// UnaMentis - Oral Exam Studio Module
// ORAL_EXAM_STUDIO_MODULE_SPEC.md: rehearsal for real oral examinations.
//
// The learner performs a timed spoken exam simulation against an AI examiner
// that listens, asks adaptive follow-up questions grounded in the syllabus
// and in what the learner actually said, and delivers rubric-based feedback
// in spoken and visual form. This module is the first consumer of the
// oral-exam engine (MODULE_SDK_SPEC.md section 6.2) and drives its design.
//
// MVP scope (module spec Phase 1, English-first): stage practice, question
// volleys, and full simulation on the phone surface, with the Grand Oral
// descriptor running in English practice mode plus the generic practice viva.

import SwiftUI

public struct OralExamModule: ModuleProtocol {
    /// The single source of truth for this module's metadata (MODULE_SDK_SPEC.md
    /// section 3).
    public let manifest = ModuleManifest(
        specVersion: "0.1.0",
        // Slug ID per the RFC 0001 item 1 ruling (slug IDs are canonical for
        // first-party modules). Stable forever: it namespaces progress data.
        id: "oral-exam",
        name: "Oral Exam Studio",
        version: "0.1.0",
        engine: .oralExam,
        surfaces: [.phone],
        capabilities: [],
        requiresHostCapabilities: [
            "voice.session/1",
            "progress/1",
            "telemetry/1",
            "session.registration/1"
        ],
        // eval.llm-rubric/1 is optional: without a reachable LLM the module
        // degrades to the offline rule-based examiner (Tier 0 completeness).
        // content.oral-syllabus/1 is optional because the host ContentStore
        // has no bundled-pack registration seam yet; the bundled starter pack
        // loads module-side with the same verification (see OralSyllabus.swift).
        optionalHostCapabilities: [
            "eval.llm-rubric/1",
            "content.oral-syllabus/1"
        ],
        voiceCoverage: VoiceCoverage(declared: 1.0),
        serverTiers: [0],
        // en-US only, deliberately. The module's reason to exist is
        // native-language exam simulation (fr-FR first), but
        // VoicePipelineConfig.locale is accepted and NOT plumbed into STT
        // (RFC 0002 item 6), so declaring fr-FR here would claim a locale the
        // build cannot resolve, which UM-Core treats as dishonest. fr-FR
        // lights up with the multilingual pipeline spike; until then the
        // Grand Oral descriptor runs as English practice mode.
        locales: ["en-US"],
        contentPacks: ContentPacks(
            bundled: [OralSyllabusPack.packId],
            compatibleSchemas: ["oral-syllabus/1"]
        ),
        privacy: Privacy(
            // Presentation transcripts are the learner's study artifacts:
            // stored locally, exportable, deletable; audio is discarded after
            // transcription (module spec section 8).
            collectsAudio: true,
            storesTranscripts: true,
            sharesWithMentor: .optIn
        ),
        minPlatform: MinPlatform(ios: "18.0")
    )

    public let shortDescription = "Rehearse oral exams against an AI examiner with rubric feedback"
    public let longDescription = """
        Practice for oral examinations with exam-faithful timing: timed \
        preparation, a spoken presentation, and adaptive jury questioning \
        grounded in your own words. After each attempt you get per-dimension \
        rubric scores, one concrete improvement action each, and a spoken \
        summary. Feedback is a practice signal to guide rehearsal, never a \
        prediction of a real exam grade.
        """
    public let iconName = "person.wave.2"
    public let themeColor = Color.indigo

    public init() {}

    public func initialize(host: ModuleHost) async throws {
        await OralExamModuleRuntime.shared.setHost(host)
    }

    @MainActor
    public func makeRootView() -> AnyView {
        AnyView(OralExamDashboardView())
    }

    @MainActor
    public func makeDashboardView() -> AnyView {
        AnyView(OralExamDashboardSummary())
    }
}

// MARK: - Runtime Holder

/// Holds the injected host so views and the conformance path share one
/// service bundle (the ExampleEchoModule pattern). Falls back to the catalog
/// host when a view runs before initialize (previews).
actor OralExamModuleRuntime {
    static let shared = OralExamModuleRuntime()
    private var host: (any ModuleHost)?

    func setHost(_ host: any ModuleHost) {
        self.host = host
    }

    @MainActor
    static func currentHost() async -> any ModuleHost {
        if let host = await shared.host {
            return host
        }
        return ModuleCatalog.shared.host
    }
}
