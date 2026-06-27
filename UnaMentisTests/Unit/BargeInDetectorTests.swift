// UnaMentis - Barge-In Detector Tests
//
// Deterministic tests of the single detection state machine. No audio, no
// SessionManager: feed VADResults with controlled timestamps, read the events.
//
// These encode the product INVARIANT: ongoing narration is very hard to
// interrupt. A short noise/echo blip must NEVER confirm a barge-in; only
// SUSTAINED genuine speech confirms; brief inter-word gaps are tolerated; and the
// detector never gets stuck.

import XCTest
@testable import UnaMentis

final class BargeInDetectorTests: XCTestCase {

    private actor Collector {
        var events: [BargeInEvent] = []
        func add(_ e: BargeInEvent) { events.append(e) }
        func all() -> [BargeInEvent] { events }
        func count() -> Int { events.count }
    }

    private func makeCollector(_ detector: BargeInDetector) -> (Collector, Task<Void, Never>) {
        let collector = Collector()
        let task = Task {
            for await event in detector.events {
                await collector.add(event)
            }
        }
        return (collector, task)
    }

    /// Poll until `count` events arrive or the bounded wait elapses.
    private func wait(for collector: Collector, count: Int, maxPolls: Int = 300) async -> [BargeInEvent] {
        for _ in 0..<maxPolls {
            if await collector.count() >= count { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await collector.all()
    }

    /// Give any unexpected event time to (not) arrive.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 120_000_000) // 120ms
    }

    /// A speech frame at audio-time `t` (seconds). Timestamp drives the sustained
    /// and gap logic, so tests are deterministic regardless of wall-clock.
    private func speech(_ confidence: Float, at t: TimeInterval) -> VADResult {
        VADResult(isSpeech: true, confidence: confidence, timestamp: t)
    }
    private func silence(at t: TimeInterval) -> VADResult {
        VADResult(isSpeech: false, confidence: 0.0, timestamp: t)
    }

    // MARK: - Tentative (evaluation begins, narration is NOT disrupted)

    func testArmedSpeechEmitsTentative() async {
        let detector = BargeInDetector()
        let (collector, task) = makeCollector(detector)
        defer { task.cancel() }

        await detector.arm()
        await detector.process(speech(0.85, at: 0))

        let events = await wait(for: collector, count: 1)
        XCTAssertEqual(events.map(\.kind), [.tentative])
        XCTAssertEqual(events.first?.confidence, 0.85)
        let phase = await detector.phase
        XCTAssertEqual(phase, .tentative)
    }

    func testIdleIgnoresSpeech() async {
        let detector = BargeInDetector()
        let (collector, task) = makeCollector(detector)
        defer { task.cancel() }

        await detector.process(speech(0.95, at: 0)) // not armed
        await settle()
        let count = await collector.count()
        XCTAssertEqual(count, 0)
    }

    func testBelowThresholdIgnored() async {
        let detector = BargeInDetector(config: .init(confidenceThreshold: 0.7))
        let (collector, task) = makeCollector(detector)
        defer { task.cancel() }

        await detector.arm()
        await detector.process(speech(0.5, at: 0))
        await settle()
        let count = await collector.count()
        XCTAssertEqual(count, 0)
    }

    func testDisabledNeverTentative() async {
        let detector = BargeInDetector(config: .init(enabled: false))
        let (collector, task) = makeCollector(detector)
        defer { task.cancel() }

        await detector.arm()
        await detector.process(speech(0.95, at: 0))
        await settle()
        let count = await collector.count()
        XCTAssertEqual(count, 0)
    }

    // MARK: - The invariant: noise blip must NOT confirm

    func testShortNoiseBlipResumesAndNeverConfirms() async {
        // sustainedSpeechMs 700, maxGapMs 350. One speech frame then silence past
        // the gap = a blip that did not sustain. It must RESUME, never confirm.
        let detector = BargeInDetector(config: .init(sustainedSpeechMs: 700, maxGapMs: 350))
        let (collector, task) = makeCollector(detector)
        defer { task.cancel() }

        await detector.arm()
        await detector.process(speech(0.9, at: 0.0))     // tentative
        await detector.process(silence(at: 0.40))        // gap 400ms > 350 -> resumed
        await settle()

        let kinds = await collector.all().map(\.kind)
        XCTAssertEqual(kinds, [.tentative, .resumed], "a short blip must resume, never confirm")
        let phase = await detector.phase
        XCTAssertEqual(phase, .listening, "resume re-arms for a later genuine barge-in")
    }

    func testTwoChunksOfNoiseDoNotConfirm() async {
        // Two consecutive above-threshold frames used to confirm. With sustained
        // detection, two 256ms-style chunks (~512ms total) are still below
        // sustainedSpeechMs 700, so they must NOT confirm.
        let detector = BargeInDetector(config: .init(sustainedSpeechMs: 700, maxGapMs: 350))
        let (collector, task) = makeCollector(detector)
        defer { task.cancel() }

        await detector.arm()
        await detector.process(speech(0.9, at: 0.0))     // tentative
        await detector.process(speech(0.9, at: 0.256))   // 256ms < 700 -> no confirm
        await detector.process(silence(at: 0.7))         // gap from 0.256 = 444 > 350 -> resumed
        await settle()

        let kinds = await collector.all().map(\.kind)
        XCTAssertEqual(kinds, [.tentative, .resumed])
        XCTAssertFalse(kinds.contains(.confirmed), "two short noise chunks must not confirm")
    }

    // MARK: - Sustained genuine speech confirms

    func testSustainedSpeechConfirms() async {
        let detector = BargeInDetector(config: .init(sustainedSpeechMs: 700, maxGapMs: 350))
        let (collector, task) = makeCollector(detector)
        defer { task.cancel() }

        await detector.arm()
        await detector.process(speech(0.8, at: 0.0))   // tentative
        await detector.process(speech(0.85, at: 0.3))  // still < 700
        await detector.process(speech(0.9, at: 0.6))   // still < 700
        await detector.process(speech(0.9, at: 0.75))  // 750ms >= 700 -> confirmed

        let events = await wait(for: collector, count: 2)
        XCTAssertEqual(events.map(\.kind), [.tentative, .confirmed])
        let phase = await detector.phase
        XCTAssertEqual(phase, .idle, "confirmed disarms the detector")
    }

    func testBriefInterWordGapIsToleratedAndStillConfirms() async {
        // Real speech has gaps between words; a gap shorter than maxGapMs must not
        // reset the sustained accumulation.
        let detector = BargeInDetector(config: .init(sustainedSpeechMs: 700, maxGapMs: 350))
        let (collector, task) = makeCollector(detector)
        defer { task.cancel() }

        await detector.arm()
        await detector.process(speech(0.85, at: 0.0))   // tentative
        await detector.process(silence(at: 0.2))        // 200ms gap < 350 -> tolerated
        await detector.process(speech(0.85, at: 0.4))   // speech resumes
        await detector.process(speech(0.9, at: 0.75))   // 750ms from onset >= 700 -> confirmed

        let events = await wait(for: collector, count: 2)
        XCTAssertEqual(events.map(\.kind), [.tentative, .confirmed])
    }

    func testLowerSustainedThresholdConfirmsSooner() async {
        // The knob works: a small sustainedSpeechMs makes it easier to interrupt.
        let detector = BargeInDetector(config: .init(sustainedSpeechMs: 200, maxGapMs: 350))
        let (collector, task) = makeCollector(detector)
        defer { task.cancel() }

        await detector.arm()
        await detector.process(speech(0.9, at: 0.0))    // tentative
        await detector.process(speech(0.9, at: 0.256))  // 256ms >= 200 -> confirmed

        let events = await wait(for: collector, count: 2)
        XCTAssertEqual(events.map(\.kind), [.tentative, .confirmed])
    }

    // MARK: - Never stuck

    func testSafetyWindowResumesIfFramesStop() async {
        // If VAD frames stop arriving mid-tentative (so the frame-driven gap logic
        // never runs), the wall-clock safety backstop must resume.
        let detector = BargeInDetector(config: .init(sustainedSpeechMs: 5000, safetyWindowMs: 40))
        let (collector, task) = makeCollector(detector)
        defer { task.cancel() }

        await detector.arm()
        await detector.process(speech(0.9, at: 0.0))    // tentative, then no frames
        let events = await wait(for: collector, count: 2)
        XCTAssertEqual(events.map(\.kind), [.tentative, .resumed], "safety backstop resumes")
        let phase = await detector.phase
        XCTAssertEqual(phase, .listening)
    }

    func testDisarmCancelsSafetyTimer() async {
        let detector = BargeInDetector(config: .init(sustainedSpeechMs: 5000, safetyWindowMs: 40))
        let (collector, task) = makeCollector(detector)
        defer { task.cancel() }

        await detector.arm()
        await detector.process(speech(0.8, at: 0.0))  // tentative
        _ = await wait(for: collector, count: 1)
        await detector.disarm()                       // cancel before safety fires
        await settle()                                // > safetyWindowMs

        let kinds = await collector.all().map(\.kind)
        XCTAssertEqual(kinds, [.tentative], "no resume after disarm")
        let phase = await detector.phase
        XCTAssertEqual(phase, .idle)
    }

    func testAbortTentativeReturnsToListeningAndRetries() async {
        let detector = BargeInDetector()
        let (collector, task) = makeCollector(detector)
        defer { task.cancel() }

        await detector.arm()
        await detector.process(speech(0.8, at: 0.0))   // tentative
        _ = await wait(for: collector, count: 1)
        await detector.abortTentative()
        let phaseAfterAbort = await detector.phase
        XCTAssertEqual(phaseAfterAbort, .listening)

        await detector.process(speech(0.85, at: 1.0))  // retry -> tentative again
        let events = await wait(for: collector, count: 2)
        XCTAssertEqual(events.map(\.kind), [.tentative, .tentative])
    }
}
