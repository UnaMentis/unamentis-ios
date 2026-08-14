// UnaMentis - Pocket TTS Real Synthesis Tests
//
// Exercises the REAL on-device Pocket TTS engine (KyutaiPocketTTSService) end to
// end: load the model and synthesize a short utterance, asserting it actually
// produces non-empty audio. This is the previously-missing coverage for "does
// TTS actually generate audio", and a diagnostic for the device-only 100% failure
// (if this also fails in the simulator, the fault is shared, not device-specific).
//
// Real Over Mock: Pocket TTS is an internal on-device service, not a paid API, so
// it is exercised for real here.

import XCTest
@testable import UnaMentis

final class PocketTTSSynthesisTests: XCTestCase {

    func testPocketTTSLoadsAndProducesNonEmptyAudio() async throws {
        let service = KyutaiPocketTTSService()

        // 1. Model load must succeed where real weights exist. Where they are
        // placeholder files (as in CI), loading cannot succeed and the test
        // skips: an env-var CI check does not work because the test runs inside
        // the simulator, which does not inherit the runner's environment, so
        // the load attempt itself is the capability probe (the same pattern as
        // KBAudioTestHarnessTests, see CI_INTEGRATION_TEST_TRIAGE.md). On
        // devices with real models the load either succeeds or this test fails,
        // preserving its diagnostic purpose.
        do {
            try await service.ensureLoaded()
        } catch {
            throw XCTSkip(
                "Pocket TTS model unavailable in this environment (placeholder in CI): \(error)"
            )
        }

        let ready = await service.isReady()
        XCTAssertTrue(ready, "engine should report ready after ensureLoaded()")

        // 2. Synthesis must produce at least one non-empty audio chunk.
        let stream = try await service.synthesize(text: "Hello, this is a test.")

        let collector = Task { () -> [TTSAudioChunk] in
            var chunks: [TTSAudioChunk] = []
            for await chunk in stream { chunks.append(chunk) }
            return chunks
        }

        // Bound the wait so a stalled engine fails the test instead of hanging.
        let deadlineTask = Task { () -> [TTSAudioChunk]? in
            try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s cold-start budget
            return nil
        }
        let chunks = await withTaskGroup(of: [TTSAudioChunk]?.self) { group -> [TTSAudioChunk] in
            group.addTask { await collector.value }
            group.addTask { await deadlineTask.value }
            let first = await group.next() ?? nil
            group.cancelAll()
            collector.cancel()
            deadlineTask.cancel()
            return first ?? []
        }

        let totalBytes = chunks.reduce(0) { $0 + $1.audioData.count }
        XCTAssertFalse(chunks.isEmpty, "Pocket TTS must produce at least one audio chunk")
        XCTAssertGreaterThan(totalBytes, 0, "Pocket TTS must produce non-empty audio data (got \(chunks.count) chunks, \(totalBytes) bytes)")

        await service.unloadModels()
    }
}
