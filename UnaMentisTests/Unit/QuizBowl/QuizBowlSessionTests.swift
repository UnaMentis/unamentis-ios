// UnaMentis - Quiz Bowl Practice Session Tests
// Covers the module-side session behavior the engine tests cannot see: what the
// UI is told, what the session promises the learner, and what it releases.
//
// - the power zone and the buzz button's point value come from the FORMAT
//   DESCRIPTOR, so a format that grants no power never offers one (IHBB Europe
//   ships a power mark on every item and declares `scoring.power: null`);
// - a session runs the descriptor's declared question count, shuffled;
// - navigate-away teardown stops the engine, ends the registered watch session,
//   and releases the exclusive voice pipeline;
// - a failed voice acquire registers no watch session at all;
// - a bonus-bearing tossup goes straight to the bonus and lands on feedback
//   when the bonus completes;
// - a skipped tossup reports its OWN answer;
// - the reported session summary carries a real duration.
//
// Real over mock: the whole thing runs on the shared ScriptedModuleHost harness
// (real evaluation, real file-backed progress store, real session registration
// over the recording watch plane), with only the voice pipeline scripted.

import Combine
import XCTest
@testable import UnaMentis

@MainActor
final class QuizBowlSessionTests: XCTestCase {
    private var harness: ScriptedModuleHost!

    override func setUp() {
        super.setUp()
        harness = ScriptedModuleHost.make()
    }

    override func tearDown() {
        harness?.tearDown()
        harness = nil
        super.tearDown()
    }

    // MARK: Helpers

    private func tossup(
        id: String,
        answer: String,
        powerMarkIndex: Int? = 120,
        bonus: QBBonusItem? = nil
    ) -> QBItem {
        QBItem(
            id: id,
            text: String(repeating: "pyramidal clue ", count: 20),
            answer: QBAnswer(primary: answer),
            domain: "history",
            powerMarkIndex: powerMarkIndex,
            bonus: bonus
        )
    }

    private func makeViewModel(
        format: QBFormat,
        items: [QBItem],
        host: (any ModuleHost)? = nil
    ) -> QBPracticeSessionViewModel {
        QBPracticeSessionViewModel(
            format: format, questions: items, host: host ?? harness.host
        )
    }

    /// Poll a MainActor condition until it holds or the timeout expires.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for: \(description)")
    }

    /// Poll an async condition until it holds or the timeout expires.
    private func waitUntilAsync(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for: \(description)")
    }

    // MARK: Power zone comes from the descriptor (defect 1)

    func testIHBBSession_neverOffersAPower_thoughEveryItemCarriesAPowerMark() async {
        let items = [tossup(id: "ihbb-1", answer: "vienna")]
        let viewModel = makeViewModel(format: .ihbbEurope, items: items)

        await harness.voiceSession.holdSpeaks(1)
        await viewModel.start()
        await waitUntil("IHBB tossup narration to begin") { viewModel.state == .readingQuestion }

        XCTAssertFalse(viewModel.formatGrantsPower,
                       "ihbb-europe.json declares scoring.power: null")
        XCTAssertFalse(viewModel.inPowerZone,
                       "A format with no power value can never be in a power zone, "
                       + "however early the buzz or however many power marks the pack carries")
        XCTAssertEqual(viewModel.buzzPointValue, 10,
                       "The buzz button must promise exactly what the engine will score")

        await harness.voiceSession.stopSpeaking()
        await viewModel.teardown()
    }

    func testNAQTSession_offersThePowerTheDescriptorDeclares() async {
        let items = [tossup(id: "naqt-1", answer: "vienna")]
        let viewModel = makeViewModel(format: .naqt, items: items)

        await harness.voiceSession.holdSpeaks(1)
        await viewModel.start()
        await waitUntil("NAQT tossup narration to begin") { viewModel.state == .readingQuestion }

        XCTAssertTrue(viewModel.formatGrantsPower, "qb-naqt.json declares a 15 point power")
        XCTAssertTrue(viewModel.inPowerZone, "A buzz at the start of the tossup is before the power mark")
        XCTAssertEqual(viewModel.buzzPointValue, 15)
        XCTAssertEqual(viewModel.correctPoints, 10)
        XCTAssertEqual(viewModel.powerPoints, 15)

        await harness.voiceSession.stopSpeaking()
        await viewModel.teardown()
    }

    func testPointValuesTrackEveryBundledDescriptor() async throws {
        for format in QBFormat.all {
            let descriptor = try QuizMatchFormatDescriptor.load(named: format.id)
            let viewModel = makeViewModel(format: format, items: [tossup(id: "t", answer: "a")])
            await viewModel.prepare()

            XCTAssertEqual(viewModel.correctPoints, descriptor.scoring.correct,
                           "\(format.id) correct value must come from the descriptor")
            let expectedPower = descriptor.questionForm == .pyramidal ? descriptor.scoring.power : nil
            XCTAssertEqual(viewModel.powerPoints, expectedPower,
                           "\(format.id) power value must come from the descriptor")
            XCTAssertEqual(viewModel.formatGrantsPower, expectedPower != nil)
        }
    }

    // MARK: Session length and shuffling (defect 5)

    func testSessionPlanner_runsTheDescriptorsDeclaredQuestionCount() throws {
        let pack = (0..<33).map { tossup(id: "q\($0)", answer: "a\($0)") }
        let naqt = try QuizMatchFormatDescriptor.load(named: "qb-naqt")
        XCTAssertEqual(naqt.oral?.questions, 24, "qb-naqt declares 24 tossups")

        let selected = QBSessionPlanner.selectItems(from: pack, descriptor: naqt, seed: 42)
        XCTAssertEqual(selected.count, 24,
                       "A NAQT session runs the 24 tossups the descriptor declares, not all 33 pack items")
        XCTAssertEqual(Set(selected.map(\.id)).count, 24, "Selection must not repeat items")
    }

    func testSessionPlanner_shufflesSoRepeatSessionsDiffer() {
        let pack = (0..<33).map { tossup(id: "q\($0)", answer: "a\($0)") }
        let first = QBSessionPlanner.selectItems(from: pack, questionCount: 24, seed: 1)
        let second = QBSessionPlanner.selectItems(from: pack, questionCount: 24, seed: 2)

        XCTAssertNotEqual(first.map(\.id), second.map(\.id),
                          "Two sessions over the same pack must not be the same session")
        XCTAssertNotEqual(first.map(\.id), pack.prefix(24).map(\.id),
                          "Selection must not be plain pack order")
    }

    func testSessionPlanner_isDeterministicForAGivenSeed() {
        let pack = (0..<33).map { tossup(id: "q\($0)", answer: "a\($0)") }
        let first = QBSessionPlanner.selectItems(from: pack, questionCount: 24, seed: 99)
        let second = QBSessionPlanner.selectItems(from: pack, questionCount: 24, seed: 99)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    func testSessionPlanner_packSmallerThanTheDeclaredCountRunsInFull() {
        let pack = (0..<5).map { tossup(id: "q\($0)", answer: "a\($0)") }
        let selected = QBSessionPlanner.selectItems(from: pack, questionCount: 24, seed: 3)
        XCTAssertEqual(selected.count, 5, "A short pack runs in full rather than repeating items")
    }

    func testEveryBundledFormat_sessionLengthMatchesItsDescriptor() async throws {
        let content = DefaultContentStoreService()
        for format in QBFormat.all {
            let descriptor = try QuizMatchFormatDescriptor.load(named: format.id)
            let items = try await QBContentProvider.loadItems(
                packId: format.packId, content: content, bundle: .main
            )
            let selected = QBSessionPlanner.selectItems(from: items, descriptor: descriptor)
            let declared = try XCTUnwrap(descriptor.oral?.questions)
            XCTAssertEqual(selected.count, min(declared, items.count),
                           "\(format.id) must run its declared \(declared) questions, not the pack's \(items.count)")
        }
    }

    // MARK: Teardown on navigate-away (defects 2, 3, 4)

    func testTeardown_endsTheWatchSession_releasesTheVoicePipeline_andSilencesTheEngine() async {
        let items = [
            tossup(id: "t1", answer: "vienna"),
            tossup(id: "t2", answer: "prague"),
            tossup(id: "t3", answer: "budapest")
        ]
        let viewModel = makeViewModel(format: .naqt, items: items)

        await viewModel.start()
        await waitUntil("the first answer window") { viewModel.state == .awaitingAnswer }
        XCTAssertFalse(harness.watchControlPlane.handlerCleared,
                       "A running session holds the watch command handler")
        let spokenBeforeTeardown = await harness.voiceSession.spokenTexts.count

        await viewModel.teardown()

        XCTAssertTrue(harness.watchControlPlane.handlerCleared,
                      "Backing out must end the registered session, not leave a handler bound to a dead one")
        XCTAssertEqual(harness.watchControlPlane.lastState?.isActive, false,
                       "The watch must not keep showing a phantom active session")
        await waitUntilAsync("the exclusive voice session to be released") {
            await self.harness.voiceSession.released
        }

        // The engine is gone: nothing narrates after teardown, and the commands
        // the UI could still fire are inert.
        await viewModel.next()
        await viewModel.buzz()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let spokenAfterTeardown = await harness.voiceSession.spokenTexts.count
        XCTAssertEqual(spokenAfterTeardown, spokenBeforeTeardown,
                       "A torn-down session must not keep reading tossups")
        XCTAssertEqual(viewModel.state, .completed)
    }

    func testTeardown_isIdempotentAcrossTheEndButtonAndOnDisappear() async {
        let viewModel = makeViewModel(format: .naqt, items: [tossup(id: "t1", answer: "vienna")])
        await viewModel.start()
        await waitUntil("the first answer window") { viewModel.state == .awaitingAnswer }

        await viewModel.end()
        await viewModel.teardown()
        await viewModel.teardown()

        XCTAssertEqual(viewModel.state, .completed)
        XCTAssertNotNil(viewModel.reportedSummary, "The host is told exactly once")
    }

    func testStart_withNoVoicePipeline_registersNoWatchSession() async {
        let viewModel = makeViewModel(
            format: .naqt,
            items: [tossup(id: "t1", answer: "vienna")],
            host: VoiceUnavailableHost(inner: harness.host)
        )

        await viewModel.start()

        XCTAssertNotNil(viewModel.sttError, "A pipeline that cannot be acquired is reported, never silent")
        XCTAssertEqual(viewModel.state, .notStarted)
        XCTAssertTrue(harness.watchControlPlane.syncedStates.isEmpty,
                      "A match that never started must not register a watch session")
        XCTAssertFalse(harness.watchControlPlane.handlerCleared)
    }

    // MARK: Bonus ordering (defect 7)

    func testBonusBearingTossup_goesStraightToTheBonusAndLandsOnFeedback() async {
        let bonus = QBBonusItem(
            leadIn: "Answer these about capitals.",
            parts: [
                .init(text: "Capital of Austria?", answer: QBAnswer(primary: "vienna")),
                .init(text: "Capital of Czechia?", answer: QBAnswer(primary: "prague")),
                .init(text: "Capital of Hungary?", answer: QBAnswer(primary: "budapest"))
            ]
        )
        let items = [tossup(id: "t1", answer: "vienna", bonus: bonus)]
        let viewModel = makeViewModel(format: .naqt, items: items)

        let recorder = StateRecorder()
        let cancellable = viewModel.$state.sink { state in
            MainActor.assumeIsolated { recorder.states.append(state) }
        }
        defer { cancellable.cancel() }

        await harness.voiceSession.enqueueTranscript("vienna")
        await viewModel.start()
        await waitUntil("the captured tossup answer") { viewModel.transcript == "vienna" }
        await viewModel.submitAnswer()

        await waitUntil("the bonus to run and finish") { viewModel.state == .showingFeedback }

        let beforeBonus = recorder.states.prefix { $0 != .bonus }
        XCTAssertFalse(beforeBonus.contains(.showingFeedback),
                       "A bonus-bearing tossup must not flash the feedback screen before the bonus")
        XCTAssertTrue(recorder.states.contains(.bonus), "The bonus screen must be reached")
        XCTAssertEqual(viewModel.state, .showingFeedback,
                       "A completed bonus returns to the tossup's feedback screen, "
                       + "otherwise the bonus screen stays up with no way forward")
        XCTAssertEqual(viewModel.bonusTotals.count, 1)

        await viewModel.teardown()
    }

    // MARK: Skip reports its own answer (defect 8a)

    func testSkippedTossup_reportsItsOwnAnswer_notThePreviousOne() async {
        let items = [
            tossup(id: "t1", answer: "vienna"),
            tossup(id: "t2", answer: "prague")
        ]
        let viewModel = makeViewModel(format: .naqt, items: items)

        await harness.voiceSession.enqueueTranscript("vienna")
        await viewModel.start()
        await waitUntil("the first captured answer") { viewModel.transcript == "vienna" }
        await viewModel.submitAnswer()
        await waitUntil("feedback on the first tossup") { viewModel.state == .showingFeedback }
        XCTAssertEqual(viewModel.lastCorrectAnswer, "vienna")

        await viewModel.next()
        await waitUntil("the second answer window") { viewModel.state == .awaitingAnswer }
        await viewModel.skip()
        await waitUntil("feedback on the skipped tossup") { viewModel.state == .showingFeedback }

        XCTAssertEqual(viewModel.lastCorrectAnswer, "prague",
                       "A skipped tossup shows and announces ITS answer, not the previous tossup's")
        XCTAssertEqual(viewModel.lastWasCorrect, false)
        XCTAssertEqual(viewModel.lastPointsAwarded, 0)

        await viewModel.teardown()
    }

    // MARK: Session summary duration (defect 8b)

    func testCompletedSession_reportsARealDuration() async {
        let viewModel = makeViewModel(format: .naqt, items: [tossup(id: "t1", answer: "vienna")])

        await harness.voiceSession.enqueueTranscript("vienna")
        await viewModel.start()
        await waitUntil("the captured answer") { viewModel.transcript == "vienna" }
        await viewModel.submitAnswer()
        await waitUntil("feedback") { viewModel.state == .showingFeedback }
        await viewModel.next()
        await waitUntil("the session to complete") { viewModel.state == .completed }

        let summary = viewModel.reportedSummary
        XCTAssertNotNil(summary)
        XCTAssertGreaterThan(summary?.duration ?? 0, 0,
                             "The summary handed to the host must carry the time the session took, not 0")
        XCTAssertEqual(summary?.completedUnits, 1)
    }

    // MARK: Buzz index approximation (defect 8c)

    func testBuzzCharacterIndex_tracksTheClockInsideTheFirstTimerTick() {
        // A 1000-character tossup read over 10 seconds. The progress timer ticks
        // at 10 Hz, so everything below 0.1 s used to report character 0.
        let atStart = QBPracticeSessionViewModel.buzzCharacterIndex(
            elapsed: 0, readDuration: 10, textLength: 1000
        )
        let halfATick = QBPracticeSessionViewModel.buzzCharacterIndex(
            elapsed: 0.05, readDuration: 10, textLength: 1000
        )
        let oneTick = QBPracticeSessionViewModel.buzzCharacterIndex(
            elapsed: 0.1, readDuration: 10, textLength: 1000
        )

        XCTAssertEqual(atStart, 0)
        XCTAssertEqual(halfATick, 5, "A buzz half a tick in has read about five characters")
        XCTAssertEqual(oneTick, 10)
        XCTAssertGreaterThan(halfATick, atStart,
                             "Buzzes inside the first tick must be distinguishable, "
                             + "not all reported as the maximally early character 0")
    }

    func testBuzzCharacterIndex_clampsToTheTossupText() {
        XCTAssertEqual(
            QBPracticeSessionViewModel.buzzCharacterIndex(
                elapsed: 99, readDuration: 10, textLength: 1000
            ),
            1000
        )
        XCTAssertEqual(
            QBPracticeSessionViewModel.buzzCharacterIndex(
                elapsed: -1, readDuration: 10, textLength: 1000
            ),
            0
        )
        XCTAssertEqual(
            QBPracticeSessionViewModel.buzzCharacterIndex(
                elapsed: 1, readDuration: 0, textLength: 1000
            ),
            0,
            "A zero read duration cannot be divided by; it reports the start of the text"
        )
    }
}

// MARK: - Test Seams

/// Records the practice states the view model published, in order.
@MainActor
private final class StateRecorder {
    var states: [QBPracticeState] = []
}

/// A host that lends every real harness service EXCEPT the voice pipeline,
/// standing in for "a core session or another module already holds it".
/// ALLOWED: in-memory host seam, not a mock of a paid external API.
private struct VoiceUnavailableHost: ModuleHost {
    let inner: any ModuleHost

    var voice: any VoiceSessionService { UnavailableVoiceSessionService() }
    var telemetry: any ModuleTelemetryService { inner.telemetry }
    var progress: any ProgressStoreService { inner.progress }
    var content: any ContentStoreService { inner.content }
    var evaluation: any ResponseEvaluationService { inner.evaluation }
    @MainActor var sessionRegistration: any SessionRegistrationService { inner.sessionRegistration }
}

/// A voice service that always refuses, as the real one does when the exclusive
/// pipeline is already held.
/// ALLOWED: in-memory host seam, not a mock of a paid external API.
private struct UnavailableVoiceSessionService: VoiceSessionService {
    struct PipelineBusy: LocalizedError {
        var errorDescription: String? { "The voice pipeline is in use." }
    }

    func acquire(config: VoicePipelineConfig) async throws -> any VoiceSession {
        throw PipelineBusy()
    }
}
