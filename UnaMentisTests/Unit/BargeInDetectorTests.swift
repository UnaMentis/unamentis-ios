// UnaMentis - Barge-In Detector Tests
// Deterministic tests of the single detection state machine. No audio, no
// SessionManager: feed VAD results, read the emitted events.

import XCTest
@testable import UnaMentis

final class BargeInDetectorTests: XCTestCase {

    /// Collects events off the detector's stream for assertions.
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

    /// Poll until `count` events arrive or the bounded wait elapses (~max*5ms).
    private func wait(for collector: Collector, count: Int, maxPolls: Int = 200) async -> [BargeInEvent] {
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

    private func speech(_ confidence: Float) -> VADResult {
        VADResult(isSpeech: true, confidence: confidence)
    }
    private func silence() -> VADResult {
        VADResult(isSpeech: false, confidence: 0.0)
    }

    // MARK: - Tentative

    func testArmedSpeechEmitsTentative() async {
        let detector = BargeInDetector()
        let (collector, task) = makeCollector(detector)
        defer { task.cancel() }

        await detector.arm()
        await detector.process(speech(0.85))

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

        // Not armed.
        await detector.process(speech(0.95))
        await settle()
        let count = await collector.count()
        XCTAssertEqual(count, 0)
    }

    func testBelowThresholdIgnored() async {
        let detector = BargeInDetector(config: .init(confidenceThreshold: 0.7))
        let (collector, task) = makeCollector(detector)
        defer { task.cancel() }

        await detector.arm()
        await detector.process(speech(0.5))
        await settle()
        let count = await collector.count()
        XCTAssertEqual(count, 0)
    }

    func testDisabledNeverTentative() async {
        let detector = BargeInDetector(config: .init(enabled: false))
        let (collector, task) = makeCollector(detector)
        defer { task.cancel() }

        await detector.arm()
        await detector.process(speech(0.95))
        await settle()
        let count = await collector.count()
        XCTAssertEqual(count, 0)
    }

    // MARK: - Confirm

    func testContinuedSpeechConfirms() async {
        let detector = BargeInDetector()
        let (collector, task) = makeCollector(detector)
        defer { task.cancel() }

        await detector.arm()
        await detector.process(speech(0.8))  // tentative
        await detector.process(speech(0.9))  // continued -> confirmed

        let events = await wait(for: collector, count: 2)
        XCTAssertEqual(events.map(\.kind), [.tentative, .confirmed])
        let phase = await detector.phase
        XCTAssertEqual(phase, .idle, "confirmed disarms the detector")
        // Timestamps are monotonic onset->confirm.
        if events.count == 2 {
            XCTAssertGreaterThanOrEqual(events[1].machTime, events[0].machTime)
        }
    }

    // MARK: - Resume (false positive timeout)

    func testTimeoutResumesWhenNoContinuedSpeech() async {
        let detector = BargeInDetector(config: .init(confirmationMs: 40))
        let (collector, task) = makeCollector(detector)
        defer { task.cancel() }

        await detector.arm()
        await detector.process(speech(0.8))  // tentative; no continued speech follows

        let events = await wait(for: collector, count: 2)
        XCTAssertEqual(events.map(\.kind), [.tentative, .resumed])
        let phase = await detector.phase
        XCTAssertEqual(phase, .listening, "resume re-arms for a later barge-in")
    }

    func testDisarmCancelsConfirmationTimer() async {
        let detector = BargeInDetector(config: .init(confirmationMs: 40))
        let (collector, task) = makeCollector(detector)
        defer { task.cancel() }

        await detector.arm()
        await detector.process(speech(0.8))  // tentative
        _ = await wait(for: collector, count: 1)
        await detector.disarm()               // cancel timer before it fires

        await settle()                        // > confirmationMs
        let kinds = await collector.all().map(\.kind)
        XCTAssertEqual(kinds, [.tentative], "no resume should fire after disarm")
        let phase = await detector.phase
        XCTAssertEqual(phase, .idle)
    }

    // MARK: - Abort (failed pause retry)

    func testAbortTentativeReturnsToListeningAndRetries() async {
        let detector = BargeInDetector()
        let (collector, task) = makeCollector(detector)
        defer { task.cancel() }

        await detector.arm()
        await detector.process(speech(0.8))   // tentative
        _ = await wait(for: collector, count: 1)
        await detector.abortTentative()        // consumer could not pause
        let phaseAfterAbort = await detector.phase
        XCTAssertEqual(phaseAfterAbort, .listening)

        await detector.process(speech(0.85))  // retry -> tentative again
        let events = await wait(for: collector, count: 2)
        XCTAssertEqual(events.map(\.kind), [.tentative, .tentative])
    }
}
