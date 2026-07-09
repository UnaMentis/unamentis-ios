// UnaMentis - Module Host
// The host service bundle injected into modules.
//
// Per MODULE_SDK_SPEC.md section 5, `ModuleHost` is a protocol bundle that
// the host app injects into a module at `initialize(host:)`. It exposes the
// single voice pipeline (VoiceSession), response evaluation, content store,
// progress store, telemetry, flags, event hub, and session registration.
//
// Services land phase by phase (MODULE_SDK_SPEC.md section 13). Phase 2 added
// `voice` (VoiceSessionService). Phase 3 adds the next four: `telemetry`
// (section 5.6), `progress` (section 5.4), `content` (section 5.3), and
// `sessionRegistration` (section 5.9). The remaining section 5 services arrive
// in later phases; adding accessors here is additive and non-breaking per the
// versioning policy in section 10.

import Foundation

/// The host service bundle injected into a module at initialization.
///
/// See MODULE_SDK_SPEC.md section 5 for the full set of services this will
/// carry. Members are added phase by phase; each addition is deliberate and
/// non-breaking.
public protocol ModuleHost: Sendable {
    /// The single voice pipeline (MODULE_SDK_SPEC.md section 5.1, capability
    /// "voice.session/1"). Modules never instantiate STT, TTS, VAD, or audio
    /// engines; they acquire an exclusive VoiceSession here.
    var voice: any VoiceSessionService { get }

    /// App-global telemetry with a module dimension (MODULE_SDK_SPEC.md
    /// section 5.6, capability "telemetry/1"). Replaces per-module telemetry.
    var telemetry: any ModuleTelemetryService { get }

    /// Module-namespaced progress and the unified proficiency model
    /// (MODULE_SDK_SPEC.md section 5.4, capabilities "progress/1",
    /// "proficiency/1").
    var progress: any ProgressStoreService { get }

    /// Content packs: bundled, imported, and downloaded (MODULE_SDK_SPEC.md
    /// section 5.3, capability "content.canonical-question/1").
    var content: any ContentStoreService { get }

    /// Response evaluation: the platform generalization of KB's answer
    /// validation (MODULE_SDK_SPEC.md section 5.2, capabilities "eval.*").
    /// Modules evaluate learner responses against an EvaluationSpec here rather
    /// than owning their own matching logic.
    var evaluation: any ResponseEvaluationService { get }

    /// Registers module sessions as first-class app sessions (MODULE_SDK_SPEC.md
    /// section 5.9, capability "session.registration/1"): watch control plane,
    /// error-log visibility, and metrics coverage.
    @MainActor var sessionRegistration: any SessionRegistrationService { get }

    /// Host tone generation for symbolic music prompts (RFC 0007, capability
    /// "audio.tonegen/1"). Pure synthesis, no audio ownership: modules render
    /// prompts here and play the result through their VoiceSession via
    /// `Utterance.preRendered`, keeping playback on the ONE pipeline.
    var toneGeneration: any ToneGenerationService { get }
}

extension ModuleHost {
    /// Default tone generator. The service is stateless synthesis (RFC 0007),
    /// so a shared default makes the protocol addition purely additive for
    /// existing hosts (MODULE_SDK_SPEC.md section 10.2); hosts may override.
    public var toneGeneration: any ToneGenerationService {
        DefaultToneGenerationService.shared
    }
}

// MARK: - Shared Runtime

/// Process-wide singletons the module host and the app share.
///
/// The telemetry engine is shared so module events (`host.telemetry`) and core
/// session telemetry (`AppState.telemetry`) land in the ONE engine, which is
/// also what owns the session error-log drill-down module sessions feed into.
/// Constructed lazily and independent of AppState init order.
public enum ModuleHostRuntime {
    /// The single app-global telemetry engine.
    public static let telemetryEngine = TelemetryEngine()
}

// MARK: - Default Host

/// The production host bundle the catalog/app constructs and injects.
///
/// Carries the real platform services: `voice` on the unified pipeline,
/// `telemetry` and `sessionRegistration` on the shared TelemetryEngine,
/// `progress` file-backed and module-namespaced, `content` over the bundled
/// pack and the server download path.
public struct DefaultModuleHost: ModuleHost {
    public let voice: any VoiceSessionService
    public let telemetry: any ModuleTelemetryService
    public let progress: any ProgressStoreService
    public let content: any ContentStoreService
    public let evaluation: any ResponseEvaluationService

    private let _sessionRegistration: @MainActor () -> any SessionRegistrationService

    @MainActor public var sessionRegistration: any SessionRegistrationService {
        _sessionRegistration()
    }

    public init(
        voice: any VoiceSessionService = UnifiedVoiceSessionService.shared,
        telemetry: (any ModuleTelemetryService)? = nil,
        progress: (any ProgressStoreService)? = nil,
        content: (any ContentStoreService)? = nil,
        evaluation: (any ResponseEvaluationService)? = nil
    ) {
        let engine = ModuleHostRuntime.telemetryEngine
        self.voice = voice
        self.telemetry = telemetry ?? TelemetryEngineModuleTelemetryService(engine: engine)
        self.progress = progress ?? FileProgressStoreService()
        self.content = content ?? DefaultContentStoreService()
        self.evaluation = evaluation ?? DefaultResponseEvaluationService()

        let telemetryService = self.telemetry
        // Session registration is built on the MainActor (it touches the watch
        // control plane), so it is created lazily on first access there.
        self._sessionRegistration = {
            SessionRegistrationHolder.shared.service(
                telemetry: telemetryService,
                engine: engine
            )
        }
    }
}

/// Holds the single production `SessionRegistrationService`, built lazily on the
/// MainActor because the watch control-plane adapter is MainActor-isolated.
@MainActor
private final class SessionRegistrationHolder {
    static let shared = SessionRegistrationHolder()
    private var cached: (any SessionRegistrationService)?

    func service(
        telemetry: any ModuleTelemetryService,
        engine: TelemetryEngine
    ) -> any SessionRegistrationService {
        if let cached { return cached }
        let service = DefaultSessionRegistrationService(
            watch: WatchConnectivityControlPlane(),
            errorSink: TelemetryModuleSessionErrorSink(engine: engine),
            telemetry: telemetry
        )
        cached = service
        return service
    }
}
