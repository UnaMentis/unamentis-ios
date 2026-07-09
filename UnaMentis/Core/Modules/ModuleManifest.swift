// UnaMentis - Module Manifest
// Codable declaration of a module's identity and requirements.
//
// The manifest is the single source of truth for a module's metadata. It
// matches MODULE_SDK_SPEC.md section 3. For compiled-in first-party modules
// the manifest lives in code (see KnowledgeBowlModule); for server-discovered
// modules the registry serves the same JSON shape.
//
// Design notes:
// - Fields tolerate unknown values where the spec says so (capabilities is an
//   open, namespaced set; unknown names are permitted and ignored).
// - Adding optional fields within a major spec version is non-breaking
//   (section 10.2, additive-only schemas).

import Foundation

// MARK: - Module Manifest

/// A module's compiled-in or server-served manifest.
///
/// Matches MODULE_SDK_SPEC.md section 3. This is the one place a module's
/// metadata lives; legacy display properties are derived from it.
public struct ModuleManifest: Codable, Hashable, Sendable {
    /// The manifest schema version this manifest was authored against.
    public let specVersion: String

    /// Globally unique, stable-forever module identifier. Namespaces progress
    /// data, so it must never change once shipped.
    public let id: String

    /// Human-readable display name.
    public let name: String

    /// Module version (semver).
    public let version: String

    /// Which engine this module is built on, or `custom`.
    public let engine: ModuleEngine

    /// Surfaces the module renders on.
    public let surfaces: [ModuleSurface]

    /// Open, namespaced set of module feature capabilities. Replaces the legacy
    /// boolean triple (team/speed/competition). Unknown names are permitted.
    public let capabilities: Set<String>

    /// Versioned host capabilities the module cannot run without. The host
    /// hides or gates modules whose required capabilities it lacks.
    public let requiresHostCapabilities: [String]

    /// Versioned host capabilities the module uses when present but degrades
    /// gracefully without.
    public let optionalHostCapabilities: [String]

    /// The module author's honest estimate of the share of the experience
    /// completable purely by voice (0.0 to 1.0).
    public let voiceCoverage: VoiceCoverage

    /// Which server tiers the module implements. Tier 0 is mandatory.
    public let serverTiers: [Int]

    /// Locales the module supports (BCP-47 tags).
    public let locales: [String]

    /// Content pack declarations.
    public let contentPacks: ContentPacks

    /// Declarative privacy facts consumed by consent flows and data export.
    public let privacy: Privacy

    /// Minimum platform versions.
    public let minPlatform: MinPlatform

    public init(
        specVersion: String,
        id: String,
        name: String,
        version: String,
        engine: ModuleEngine,
        surfaces: [ModuleSurface],
        capabilities: Set<String>,
        requiresHostCapabilities: [String],
        optionalHostCapabilities: [String],
        voiceCoverage: VoiceCoverage,
        serverTiers: [Int],
        locales: [String],
        contentPacks: ContentPacks,
        privacy: Privacy,
        minPlatform: MinPlatform
    ) {
        self.specVersion = specVersion
        self.id = id
        self.name = name
        self.version = version
        self.engine = engine
        self.surfaces = surfaces
        self.capabilities = capabilities
        self.requiresHostCapabilities = requiresHostCapabilities
        self.optionalHostCapabilities = optionalHostCapabilities
        self.voiceCoverage = voiceCoverage
        self.serverTiers = serverTiers
        self.locales = locales
        self.contentPacks = contentPacks
        self.privacy = privacy
        self.minPlatform = minPlatform
    }

    /// Whether the module renders on the given surface.
    public func supports(_ surface: ModuleSurface) -> Bool {
        surfaces.contains(surface)
    }
}

// MARK: - Engine

/// The reusable session machinery a module is built on.
///
/// Serialized with the spec's hyphenated names (`quiz-match`, `oral-exam`).
public enum ModuleEngine: String, Codable, Hashable, Sendable {
    case quizMatch = "quiz-match"
    case oralExam = "oral-exam"
    case drill = "drill"
    case custom = "custom"
}

// MARK: - Surface

/// A place a module renders.
public enum ModuleSurface: String, Codable, Hashable, Sendable {
    case phone
    case watch
    case audioOnly = "audio-only"
}

// MARK: - Voice Coverage

/// The declared share of the experience completable by voice.
public struct VoiceCoverage: Codable, Hashable, Sendable {
    /// Author's estimate, 0.0 to 1.0. Measured coverage comes from telemetry.
    public let declared: Double

    public init(declared: Double) {
        self.declared = declared
    }
}

// MARK: - Content Packs

/// A module's content pack declarations.
public struct ContentPacks: Codable, Hashable, Sendable {
    /// Pack IDs bundled in the app.
    public let bundled: [String]

    /// Item schema versions this module can consume (e.g. "canonical-question/1").
    public let compatibleSchemas: [String]

    public init(bundled: [String], compatibleSchemas: [String]) {
        self.bundled = bundled
        self.compatibleSchemas = compatibleSchemas
    }
}

// MARK: - Privacy

/// Minimum declarative privacy facts, consumed by consent flows.
public struct Privacy: Codable, Hashable, Sendable {
    /// How the module may share data with a mentor.
    public enum MentorSharing: String, Codable, Hashable, Sendable {
        case never
        case optIn = "opt-in"
        case always
    }

    public let collectsAudio: Bool
    public let storesTranscripts: Bool
    public let sharesWithMentor: MentorSharing

    public init(
        collectsAudio: Bool,
        storesTranscripts: Bool,
        sharesWithMentor: MentorSharing
    ) {
        self.collectsAudio = collectsAudio
        self.storesTranscripts = storesTranscripts
        self.sharesWithMentor = sharesWithMentor
    }
}

// MARK: - Minimum Platform

/// Minimum OS versions the module supports.
public struct MinPlatform: Codable, Hashable, Sendable {
    /// Minimum iOS version (e.g. "18.0"). Nil if the module does not ship on iOS.
    public let ios: String?

    /// Minimum Android API level as a string (e.g. "26"). Nil if not on Android.
    public let android: String?

    public init(ios: String? = nil, android: String? = nil) {
        self.ios = ios
        self.android = android
    }
}

// MARK: - Host Capabilities

/// The static registry of host capability strings this build actually provides.
///
/// Capability names are versioned (`name/majorVersion`) per MODULE_SDK_SPEC.md
/// sections 3 and 10.3. The host hides or gates modules whose
/// `requiresHostCapabilities` it does not provide ("requires app update").
///
/// This set is honest about the current build. Most of the section 5 services
/// (VoiceSession, ResponseEvaluation, ContentStore, ProgressStore, and the
/// rest) are not yet lifted into host services, so they are NOT advertised
/// here. They light up as the later migration phases wire them in. Advertising
/// a capability before the service exists would let a module launch into a gap.
public enum HostCapabilities {
    /// Capabilities this build provides today.
    ///
    /// - `voice.session/1`: the VoiceSession host service (section 5.1),
    ///   implemented by `UnifiedVoiceSessionService` on the unified audio
    ///   pipeline and exposed via `ModuleHost.voice` (Phase 2).
    /// - `flags/1`: feature flags and offline config exist in the app today
    ///   (UserDefaults-backed settings and DEBUG compilation conditions), which
    ///   is the substrate section 5.7 formalizes.
    /// - `content.canonical-question/1`: the app bundles and reads canonical KB
    ///   question content (kb-sample-questions.json), the schema section 5.3
    ///   names.
    ///
    /// Everything else in section 10.3 is deliberately absent until its host
    /// service ships. Keeping this set small and truthful is the point.
    public static let provided: Set<String> = [
        "voice.session/1",
        "flags/1",
        // Phase 3 host services (MODULE_SDK_SPEC.md sections 5.3, 5.4, 5.6, 5.9).
        // These are now advertised because the services actually ship in this
        // build: ContentStore, ProgressStore + unified proficiency, module
        // Telemetry, and SessionRegistration. "content.canonical-question/1" is
        // advertised per the RFC 0001 ruling only now that ContentStore exists.
        "content.canonical-question/1",
        "progress/1",
        "proficiency/1",
        "telemetry/1",
        "session.registration/1",
        // Phase 4 evaluators (MODULE_SDK_SPEC.md section 5.2). Advertised because
        // DefaultResponseEvaluationService implements and tests them (the KB
        // algorithmic validation lift). eval.semantic/1 stays absent: the KB
        // embeddings tier was never wired into a live call site, so there is
        // no implemented, testable tier to advertise (RFC 0001 rule).
        // pitchRhythm is reserved.
        "eval.text-exact/1",
        "eval.text-fuzzy/1",
        "eval.numeric/1",
        "eval.choice/1",
        // Oral Exam phase (MODULE_SDK_SPEC.md sections 5.2 and 6.2). llmRubric
        // is implemented and tested: DefaultResponseEvaluationService delegates
        // the tier to LLMRubricEvaluator, which rides the app's LLM routing
        // policy (scripted LLM in tests per the paid-API mock policy).
        "eval.llm-rubric/1",
        // Tone generation for symbolic music prompts (RFC 0007). Advertised
        // because DefaultToneGenerationService ships and is tested; playback
        // rides the existing pre-rendered audio route on the unified pipeline.
        "audio.tonegen/1"
    ]

    /// Whether this build provides every capability the manifest requires.
    ///
    /// Modules whose required capabilities are unmet are hidden by the catalog
    /// (section 3: "requires app update").
    public static func supports(_ manifest: ModuleManifest) -> Bool {
        manifest.requiresHostCapabilities.allSatisfy { provided.contains($0) }
    }
}
