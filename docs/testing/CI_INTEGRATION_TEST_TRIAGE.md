# CI Integration Test Triage

**Date:** 2026-06-21
**Why:** When CI started actually running tests (the runner had been running zero), the integration job surfaced failures. The goal is not to blanket-skip audio tests, it is to push CI as far as it can honestly go. A macOS CI image cannot exercise real hardware I/O (a physical mic capturing sound, a speaker playing it), but it absolutely can run audio *processing*: generate or replay audio buffers, push them through the real pipeline, and measure that the signal moves through as expected (levels, correlation, VAD/barge-in classification, resampling, format conversion). This document tracks what runs in CI, what cannot, and the plan to keep closing the gap.

## The key finding

The 6 failing integration tests do **not** need hardware I/O. Every one of them either generates an audio buffer or injects buffers into the engine in software. The single shared blocker is that they source their audio from **Pocket TTS**, whose model weights are empty placeholder files in CI (see `Create placeholder model files` in `ios.yml`). With no model, audio generation returns nothing and the tests fail.

## Triage of the failing tests

| Test (class) | What it needs | CI path |
|---|---|---|
| `testAudioGeneratorCreatesValidBuffer` (KBAudioTestHarnessTests) | Pocket TTS model to synthesize, then asserts 16kHz/mono/non-empty buffer | Enable via prerecorded speech fixture, or provide model |
| `testAudioGeneratorFromSource` (KBAudioTestHarnessTests) | Pocket TTS model | Same |
| `testEngagementSpeechThroughEngineAnswersAndResumes` (BargeInCoordinatorAudioPathTests) | A speech buffer to inject (currently from Pocket TTS); engine path is already CI-safe (buffer injection, no hardware) | Enable via prerecorded speech fixture |
| `testCommandSpeechThroughEngineTriggersAndExecutes` (BargeInCoordinatorAudioPathTests) | Same | Enable via prerecorded speech fixture |
| `testFullPipelineWithKyutaiPocketTTS` (KBAudioTestHarnessTests) | Pocket TTS **and** Apple Speech STT (already `XCTSkip`s when recognition is unavailable) | STT is genuinely unavailable in CI: skip the STT assertions, keep the audio-generation half |
| `testQuickTestConvenience` (KBAudioTestHarnessTests) | Pocket TTS + STT convenience wrapper | Same as above |

## What a macOS CI runner can and cannot do

- **Can:** generate synthetic audio (tones, noise, silence), replay prerecorded WAV fixtures, run resampling/format conversion, run VAD and barge-in classification on injected buffers, measure RMS/peak levels and cross-correlation, verify the pipeline produces the expected events. The `BargeInCorpus.syntheticNoise(...)` path already runs in CI today.
- **Cannot:** capture from a real microphone, play to a real speaker, or run Apple on-device Speech recognition (no model/entitlement on the runner). Tests whose *assertion* is "real STT transcribed this" cannot pass in CI and must skip that assertion there.

## Plan (incremental, "push as far as we can")

1. **Now:** make the integration job green honestly. For each test above, prefer enabling over skipping:
   - Replace Pocket-TTS-sourced audio with **committed prerecorded speech fixtures** (small 16kHz mono WAVs of the test utterances) fed through `.prerecordedBundle` / `.rawAudioData`. This exercises the real pipeline and signal flow with no model and no hardware.
   - Where a test's assertion genuinely requires STT (full-pipeline transcription), `XCTSkip` only that assertion in CI, with a reason, and keep the rest.
   - Any test that truly cannot run in CI gets `XCTSkip(... isRunningInCI ...)` with a one-line reason and a row in the "Skipped in CI" table below, never silently disabled.
2. **Next:** evaluate providing the real Pocket TTS model in CI (download + cache, the same pattern as `llama.xcframework`) so the TTS-generation path itself is tested on the runner. Pocket TTS is CoreML and runs on the simulator CPU.
3. **Later:** add explicit signal-quality assertions (RMS, correlation between injected and observed audio) so CI proves data integrity through the pipeline, not just "did not crash".

## Enabled in CI via fixtures (2026-06-21)

The two `BargeInCoordinatorAudioPathTests` speech tests now run in CI. They load a committed 16kHz mono speech fixture (`UnaMentisTests/Integration/Fixtures/speech-utterance.wav`) instead of generating audio with Pocket TTS. The transcript is already supplied by `MockTranscriptSTTService`, so the fixture's words do not matter, only that the Silero VAD detects real speech. The VAD uses its RMS fallback whenever the CoreML model is absent (as in CI), so the real `processAudioBuffer -> VAD -> BargeInCoordinator -> surface` pipeline is exercised with no model and no hardware. Verified locally under the same no-model condition CI runs in.

## Skipped in CI (must stay tracked)

| Test (class) | Reason it cannot run in CI | Condition to re-enable |
|------|----------------------------|------------------------|
| `testAudioGeneratorCreatesValidBuffer` (KBAudioTestHarnessTests) | Asserts Pocket TTS itself produces a valid 16kHz buffer; weights are placeholders in CI and a fixture cannot stand in for the generator under test | Provide the real Pocket TTS model in CI (plan step 2) |
| `testAudioGeneratorFromSource` (KBAudioTestHarnessTests) | Same: Pocket TTS generation is the thing under test | Provide Pocket TTS model in CI |
| `testFullPipelineWithKyutaiPocketTTS` (KBAudioTestHarnessTests) | Needs real Pocket TTS generation and on-device STT, neither available in CI | Pocket TTS model + a CI-viable STT |
| `testQuickTestConvenience` (KBAudioTestHarnessTests) | Same full TTS+STT pipeline | Pocket TTS model + a CI-viable STT |

Skips use `XCTSkipIf(ProcessInfo...["CI"] == "true", ...)`, so these run normally on a developer machine and on device, where the real model is present.
