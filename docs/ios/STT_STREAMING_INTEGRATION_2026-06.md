# On-Device Streaming STT Integration (FluidAudio + Parakeet EOU)

Start of the STT-swap workstream: replace the disabled GLM-ASR / Apple-Speech path with a real on-device streaming recognizer. This is the foundation the whole audio architecture waits on, and the reader's voice path is blocked on it (see below).

## Decision

- **Premium / primary:** FluidAudio v0.14.8 (Apache-2.0), using the **Parakeet realtime EOU 120M** CoreML model on the Apple Neural Engine. True cache-aware streaming with a native end-of-utterance signal and 160/320/1280 ms chunk sizes. This is the most iPhone-proven Swift/CoreML/ANE path (see ON_DEVICE_STT_AUDIT_2026-06.md).
- **Fallback (later):** Moonshine v2 (MIT) or sherpa-onnx streaming Zipformer (Apache) for low-end devices / fully-MIT builds.

The pick is provisional until measured on a device (no candidate has rigorous published iPhone streaming-latency numbers).

## What is already in the repo

`UnaMentis/Services/STT/FluidAudioSTTService.swift` — the `STTService`-conforming adapter, gated on `#if canImport(FluidAudio)` so the app builds with or without the package. Its API usage was confirmed against the FluidAudio v0.14.8 source (`StreamingEouAsrManager.swift`):

| Our STTService | FluidAudio |
|----------------|------------|
| `startStreaming` | `StreamingEouAsrManager(chunkSize:eouDebounceMs:)` + `loadModels()` + `setPartialCallback` / `setEouCallback` |
| `sendAudio(buffer)` | `process(audioBuffer:)` (drives chunked decode; partials via callback) |
| `stopStreaming` | `finish()` (final transcript) |

Partials yield `STTResult(isFinal:false,isEndOfUtterance:false)`; EOU yields `isEndOfUtterance:true`; `finish()` yields `isFinal:true`.

## Status (done)

The FluidAudio package (v0.14.8) is added to `project.yml`, resolves, and the app **builds with it linked**. `FluidAudioSTTService` compiles against the real API (no drift), 44 tests pass. Done:

1. Package added; `xcodegen generate` + build succeed.
2. `STTProvider.parakeetEOU` + all switches (`identifier`, `costPerHour` 0, `requiresNetwork` false, `isOnDevice` true); `LatencyTestCoordinator` builds the service for it.
3. **Reader unblock:** `AudioEngine.attachSTT` feeds an STT and populates `lastTranscript` (opt-in; the session is untouched). `ReadingPlaybackViewModel` attaches it when voice monitoring starts. The reading-list voice path was inert because `lastTranscript` was never set; it now flows once the model is present.
4. **Prefetch:** `FluidAudioModelPrefetch.prefetchIfNeeded()` runs on launch (idempotent, background) so the first session doesn't block on a cold download.

## Remaining (device + product)

- **Device validation (the goal's source of truth):** run a session/reader on a real iPhone, confirm partials/EOU/final transcripts, then `/measure-barge-in device` for the real STT time-to-first-partial latency vs the < 500 ms target. `loadModels()` downloads ~hundreds of MB from HuggingFace on first use.
- Make `parakeetEOU` the default STT provider (provider selection / settings) once device-validated.
- Prefetch UX: gate on Wi-Fi / not-low-data-mode and add a progress UI for testers.
- Reader conversational barge-in: wire `BargeInDetector` + `BargeInResponder` into the reader now that transcripts flow.

## Device validation (the goal's source of truth)

1. Run a session and the reader, speak, and confirm partial hypotheses, EOU, and final transcripts arrive.
2. Run `/measure-barge-in device` to capture the real **STT time-to-first-partial** latency (the device-only gating criterion in `.claude/goals/barge-in.json`) and confirm it meets the < 500 ms target.
3. Sweep chunk size (160 vs 320 ms) for the latency/accuracy trade-off.

## Fallback tier (later)

Add Moonshine v2 (sherpa-onnx, MIT) as a second `STTService` for low-end devices and MIT-clean builds, selectable via `STTProvider`, with the same partial/EOU/final mapping.
