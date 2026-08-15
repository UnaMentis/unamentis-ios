// UnaMentis - Oral Exam Session View Model Tests
// Covers the module-side session concerns the engine does not own, starting
// with the one that costs the most when it is wrong: session start must be
// non-re-entrant.
//
// `state` cannot guard the start on its own, because it stays `.notStarted`
// until the engine's first event arrives. A `.task` firing alongside a Start
// tap (or a view re-identify) would both pass a state check and then interleave
// at the first `await`, acquiring the ONE exclusive voice pipeline twice and
// running two engines against a single registered session.

import XCTest
@testable import UnaMentis

@MainActor
final class OralExamSessionViewModelTests: XCTestCase {

    private var harness: ScriptedModuleHost!

    override func setUp() {
        super.setUp()
        harness = ScriptedModuleHost.make()
    }

    override func tearDown() async throws {
        // Leave the process-wide module runtime as the app expects to find it.
        await OralExamModuleRuntime.shared.setHost(ModuleCatalog.shared.host)
        harness?.tearDown()
        harness = nil
    }

    // MARK: - Fixtures

    /// A hermetic descriptor mirroring the practice-viva questioning stage, so
    /// these tests never depend on bundle resources.
    private func descriptor() -> OralExamFormatDescriptor {
        OralExamFormatDescriptor(
            formatId: "reentrancy-viva",
            language: "en-US",
            stages: [
                .init(kind: .questioning, seconds: 60, style: "conversation", followUpDepth: 1)
            ],
            rubric: ["structure", "clarity"],
            examiner: .init(personaCount: 1, register: "encouraging"),
            evaluation: .init(tiers: ["llmRubric"], deliveryMetrics: ["pace"]),
            listening: .init(responseSilenceSec: 2.0, maxUtteranceSec: 60)
        )
    }

    private func config() -> OralExamSessionConfig {
        OralExamSessionConfig(
            descriptor: descriptor(),
            topic: OralExamTopic(
                id: "reentrancy-topic",
                title: "the water cycle",
                summary: "Water moves between oceans, atmosphere, and land in a continuous cycle.",
                exemplarQuestions: ["What drives evaporation?"],
                rubricHints: ["Trace one full loop."],
                domain: "science"
            ),
            mode: .questionVolley(rootQuestions: 1)
        )
    }

    /// Install a host whose voice service counts and refuses acquisitions, so
    /// a start cannot get past the pipeline step and no engine, examiner, or
    /// LLM routing is reached.
    private func installCountingVoiceHost() async -> CountingVoiceSessionService {
        let voice = CountingVoiceSessionService()
        let host = OralExamTestHost(
            voice: voice,
            telemetry: harness.host.telemetry,
            progress: harness.host.progress,
            content: harness.host.content,
            evaluation: harness.host.evaluation,
            sessionRegistration: harness.sessionRegistrationService
        )
        await OralExamModuleRuntime.shared.setHost(host)
        return voice
    }

    // MARK: - Re-entrancy

    func testConcurrentStartsAcquireThePipelineOnce() async throws {
        let voice = await installCountingVoiceHost()

        let model = OralExamSessionViewModel(config: config())

        // The `.task` and the Start tap, arriving together.
        async let first: Void = model.startSession()
        async let second: Void = model.startSession()
        _ = await (first, second)

        let acquisitions = await voice.acquisitions
        XCTAssertEqual(
            acquisitions, 1,
            "Two concurrent starts must acquire the exclusive voice pipeline exactly once"
        )
        XCTAssertNotNil(model.errorMessage, "The refused acquisition must surface")
        XCTAssertFalse(model.isPreparingServices)
        XCTAssertEqual(model.state, .notStarted)
    }

    func testStartThatFailedBeforeTheEngineExistedStaysRetryable() async throws {
        let voice = await installCountingVoiceHost()

        let model = OralExamSessionViewModel(config: config())

        await model.startSession()
        await model.startSession()

        let acquisitions = await voice.acquisitions
        XCTAssertEqual(
            acquisitions, 2,
            "The guard must not wedge the session shut after a failed acquisition: "
                + "the start screen still shows an enabled Start button"
        )
    }
}

// MARK: - Test Seams

/// Counts pipeline acquisitions and refuses them, holding each acquisition open
/// long enough that a concurrent second start must meet the view model's guard
/// while the first is still in flight.
///
/// Not a mock of a paid external API: the voice pipeline is the host's own
/// service, scripted here exactly as ScriptedVoiceSessionService scripts it.
private actor CountingVoiceSessionService: VoiceSessionService {
    private(set) var acquisitions = 0

    func acquire(config: VoicePipelineConfig) async throws -> any VoiceSession {
        acquisitions += 1
        try? await Task.sleep(for: .milliseconds(50))
        throw VoiceSessionError.pipelineBusy(holder: "test")
    }
}

/// The harness services with the voice service substituted.
private struct OralExamTestHost: ModuleHost {
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
