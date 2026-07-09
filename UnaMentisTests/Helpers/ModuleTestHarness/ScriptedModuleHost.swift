// UnaMentis - Scripted Module Host (shared test harness)
// The reusable ModuleHost for module and conformance tests.
//
// Promotes and generalizes the two local test seams (ModuleProtocolTests.TestHost
// and QuizMatchEngineTests' inline context) into one harness every module test
// and the conformance suite share. It follows the "real over mock" doctrine
// (MODULE_SDK_SPEC.md section 9 says the SDK ships a mock host; here "mock" means
// scripted voice plus in-memory telemetry only, everything else is the real
// service):
//
//   - progress:   real FileProgressStoreService rooted at a unique temp dir, so
//                 namespacing and export/erase run against the real store.
//   - evaluation: real DefaultResponseEvaluationService (the KB algorithm lift).
//   - content:    real DefaultContentStoreService over an injectable imports root
//                 (fixture packs land here via importPack).
//   - voice:      a scripted VoiceSessionService vending one ScriptedVoiceSession.
//   - telemetry:  RecordingModuleTelemetryService (in-memory, inspectable).
//   - sessionRegistration: real DefaultSessionRegistrationService wired to the
//                 RecordingWatchControlPlane, so pause/stop can be DRIVEN by tests.
//
// The harness owns the temp dirs and cleans them up in `tearDown()`.

import Foundation
@testable import UnaMentis

/// A VoiceSessionService that always vends the same scripted session.
/// ALLOWED: in-memory host seam, not a mock of a paid external API.
struct ScriptedVoiceSessionService: VoiceSessionService {
    let session: ScriptedVoiceSession

    func acquire(config: VoicePipelineConfig) async throws -> any VoiceSession {
        session
    }
}

/// The reusable host bundle for module tests.
///
/// Construct with `ScriptedModuleHost.make()` (a MainActor static factory,
/// because session registration is MainActor-isolated), use `host` as the
/// `ModuleHost`, and call `tearDown()` when done to remove the temp directories.
/// The instance itself is not actor-isolated so tests on any actor can use it;
/// all stored services are Sendable.
final class ScriptedModuleHost: Sendable {
    /// The scripted voice session the host's `voice` service vends. Enqueue
    /// transcripts and hold speaks on this directly.
    let voiceSession: ScriptedVoiceSession

    /// The real, temp-rooted progress store (inspect attempts/proficiency here).
    let progressStore: FileProgressStoreService

    /// The real evaluation service.
    let evaluationService: DefaultResponseEvaluationService

    /// The real content store over the harness imports root.
    let contentStore: DefaultContentStoreService

    /// The recording telemetry sink (assert the required taxonomy here).
    let telemetryRecorder: RecordingModuleTelemetryService

    /// The recording watch control plane (drive pause/stop through this).
    let watchControlPlane: RecordingWatchControlPlane

    /// The recording error sink (assert reported session errors here).
    let errorSink: RecordingErrorSink

    /// The real session registration service wired to the recording plane.
    let sessionRegistrationService: DefaultSessionRegistrationService

    /// The ModuleHost to pass to a module's `initialize(host:)` and activities.
    let host: any ModuleHost

    private let progressRoot: URL
    private let importsRoot: URL

    private init(
        voiceSession: ScriptedVoiceSession,
        progressStore: FileProgressStoreService,
        evaluationService: DefaultResponseEvaluationService,
        contentStore: DefaultContentStoreService,
        telemetryRecorder: RecordingModuleTelemetryService,
        watchControlPlane: RecordingWatchControlPlane,
        errorSink: RecordingErrorSink,
        sessionRegistrationService: DefaultSessionRegistrationService,
        progressRoot: URL,
        importsRoot: URL
    ) {
        self.voiceSession = voiceSession
        self.progressStore = progressStore
        self.evaluationService = evaluationService
        self.contentStore = contentStore
        self.telemetryRecorder = telemetryRecorder
        self.watchControlPlane = watchControlPlane
        self.errorSink = errorSink
        self.sessionRegistrationService = sessionRegistrationService
        self.progressRoot = progressRoot
        self.importsRoot = importsRoot
        self.host = HarnessHost(
            voice: ScriptedVoiceSessionService(session: voiceSession),
            telemetry: telemetryRecorder,
            progress: progressStore,
            content: contentStore,
            evaluation: evaluationService,
            sessionRegistration: sessionRegistrationService
        )
    }

    /// Build a fresh harness with isolated temp directories. MainActor-isolated
    /// because the session-registration service and its watch plane are.
    @MainActor
    static func make() -> ScriptedModuleHost {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriptedModuleHost-\(UUID().uuidString)", isDirectory: true)
        let progressRoot = base.appendingPathComponent("progress", isDirectory: true)
        let importsRoot = base.appendingPathComponent("content", isDirectory: true)

        // Echo mode lets echo-style voice activities (e.g. the template module)
        // run headlessly: an unscripted listen returns the last spoken prompt.
        let voiceSession = ScriptedVoiceSession(echoMode: true)
        let telemetry = RecordingModuleTelemetryService()
        let watch = RecordingWatchControlPlane()
        let errorSink = RecordingErrorSink()
        let registration = DefaultSessionRegistrationService(
            watch: watch, errorSink: errorSink, telemetry: telemetry
        )

        return ScriptedModuleHost(
            voiceSession: voiceSession,
            progressStore: FileProgressStoreService(root: progressRoot),
            evaluationService: DefaultResponseEvaluationService(),
            contentStore: DefaultContentStoreService(importsRoot: importsRoot),
            telemetryRecorder: telemetry,
            watchControlPlane: watch,
            errorSink: errorSink,
            sessionRegistrationService: registration,
            progressRoot: progressRoot,
            importsRoot: importsRoot
        )
    }

    /// The QuizMatch host context view of this harness (module id namespaced),
    /// for engine tests that drive QuizMatchEngine directly.
    func quizMatchContext(moduleId: String) -> QuizMatchHostContext {
        QuizMatchHostContext(
            moduleId: moduleId,
            evaluation: evaluationService,
            progress: progressStore,
            telemetry: telemetryRecorder
        )
    }

    /// Remove the harness's temp directories. Call from `tearDown()`.
    func tearDown() {
        try? FileManager.default.removeItem(
            at: progressRoot.deletingLastPathComponent()
        )
    }
}

// MARK: - Host Bundle

/// A concrete ModuleHost carrying the harness's services. Mirrors
/// DefaultModuleHost's shape but with every service injected.
private struct HarnessHost: ModuleHost {
    let voice: any VoiceSessionService
    let telemetry: any ModuleTelemetryService
    let progress: any ProgressStoreService
    let content: any ContentStoreService
    let evaluation: any ResponseEvaluationService
    private let _sessionRegistration: any SessionRegistrationService

    init(
        voice: any VoiceSessionService,
        telemetry: any ModuleTelemetryService,
        progress: any ProgressStoreService,
        content: any ContentStoreService,
        evaluation: any ResponseEvaluationService,
        sessionRegistration: any SessionRegistrationService
    ) {
        self.voice = voice
        self.telemetry = telemetry
        self.progress = progress
        self.content = content
        self.evaluation = evaluation
        self._sessionRegistration = sessionRegistration
    }

    @MainActor var sessionRegistration: any SessionRegistrationService {
        _sessionRegistration
    }
}
