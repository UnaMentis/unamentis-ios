# On-Device STT Audit for Real-Time Barge-In (2026-06-01)

Fresh, web-researched and adversarially verified survey of on-device speech-to-text for the decisive use case: real-time streaming barge-in on iPhone, with a premium tier and a fallback tier. Data gathered 2026-06-01 from dated primary sources (Hugging Face cards, vendor repos, the WhisperKit and Moonshine v2 papers, a April-2026 Microsoft Research streaming-ASR benchmark, and the FluidAudio repo). Treat exact numbers as current-best, and measure the finalists on a real device before locking the pick.

## Two hard truths first

1. The on-device GLM-ASR in the app has never run. `GLMASROnDeviceSTTService.swift` hardcodes `llamaAvailable = false`, comments "GLM-ASR decoder disabled - use Apple Speech fallback," forces `isDeviceSupported` to always return `false`, and leaves the mel-spectrogram and audio-embedding steps as TODOs. The default STT provider is also the self-hosted GLM-ASR, which without a server falls back to Apple Speech too. So for months, all on-device STT has actually been Apple Speech.

2. GLM-ASR-Nano is the wrong architecture for barge-in regardless. It is a batch, full-utterance encoder-decoder (Whisper encoder plus Llama decoder, run via a single generate()), not a streaming transducer. The "streaming" belongs to Zhipu's closed cloud API and even that buffers 1 to 1.5 seconds. The open weights have no low-latency partial-emit path. Accuracy is strong, but it cannot serve the low time-to-first-partial that barge-in needs.

So this is not "finish GLM-ASR." We should adopt a streaming-native on-device STT, in two tiers.

## Recommendation

Split the job, since one model does not do both well:

- Premium barge-in (high-end iPhones): FluidAudio with NVIDIA Parakeet. Use Parakeet Realtime EOU 120M for the always-on streaming front-end (true cache-aware streaming, native end-of-utterance/turn detection, ~160ms chunk) and Parakeet TDT 0.6B v3 as the high-accuracy multilingual finalizer (on the Neural Engine). FluidAudio is a mature Swift/CoreML/ANE SDK (v0.14.8, 2026-05-31), the single most iPhone-proven path in the field.
- Fallback barge-in (lower-end, license-clean): Moonshine v2 (English) or a sherpa-onnx streaming Zipformer. Both genuinely stream, are tiny, run on older devices, and are clearly better than Apple Speech. Moonshine v2 English code and weights are MIT; sherpa-onnx models are typically Apache, both clean for our MIT repo.
- Optional later: keep a high-accuracy full-utterance model (Parakeet TDT v3, or GLM-ASR-Nano if finished) for non-barge-in dictation. Not a priority.

None of these have rigorous published iPhone streaming-latency numbers, so the pick is provisional until measured on the device.

## Verified candidate landscape

| Model / path | Streaming? | iOS path | On-disk | License (commercial / MIT) | Tier | Barge-in verdict |
|---|---|---|---|---|---|---|
| Parakeet EOU 120M (FluidAudio) | Yes, native cache-aware + EOU | CoreML/ANE (FluidAudio Swift) | ~hundreds of MB | NVIDIA Open Model (commercial yes, attribution; not MIT) | premium/fallback front-end | Best-architected barge-in candidate; iPhone perf unmeasured |
| Parakeet TDT 0.6B v3 (FluidAudio) | No, batch finalizer | CoreML/ANE (FluidAudio) | ~481MB fp16 / ~336MB Int4 | CC-BY-4.0 (commercial yes; not MIT) | premium finalizer | Excellent accuracy multilingual finalizer, not a front-end |
| Nemotron Speech Streaming EN 0.6B | Yes, cache-aware | sherpa-onnx (ONNX) | ~628MB int8 | NVIDIA Open Model (commercial yes; not MIT) | premium | Crowned best real-time English streaming by an Apr-2026 MSR paper; iPhone unproven |
| Moonshine v2 Small (English) | Yes, 80ms lookahead | sherpa-onnx / ONNX / .ort | ~560MB F32 (int8 smaller) | MIT (English) | premium-ish / fallback | Purpose-built streaming; MIT; no iPhone latency yet |
| Moonshine v2 Tiny (English) | Yes | sherpa-onnx / ONNX | ~176MB F32 (int8 ~tens of MB) | MIT (English) | fallback | Strong tiny streaming fallback; MIT clean |
| sherpa-onnx streaming Zipformer | Yes, true chunked | ONNX Runtime on iOS | small | Apache-2.0 | fallback | Most credible MIT-clean genuine-streaming fallback; iPhone perf unverified |
| Kyutai STT 1B (en/fr) | Yes, 500ms delay + semantic VAD | MLX/custom | ~0.7-1.2GB quant | permissive | premium | Good barge-in fit, Kyutai-compatible; heavy, needs hardening |
| WhisperKit large-v3-turbo | Windowed (LocalAgreement) | CoreML/ANE (Argmax, MIT) | ~547-632MB | MIT | premium (A18/A19) | Whisper 30s-window is wrong for tight barge-in; premium accuracy only |
| GLM-ASR-Nano-2512 | No, batch | MLX 4-bit | ~1.28GB (4-bit) | Apache/MIT (discrepant) | full-utterance only | Strong accuracy, not streaming; not for barge-in |

## License reality

The best-architected barge-in models (the NVIDIA Parakeet family) ship under the NVIDIA Open Model License or CC-BY-4.0: both permit commercial App Store distribution but require attribution and are not MIT-relicensable. For our MIT open-source repo, that is fine if we treat the model as a downloaded asset that keeps its own license and NOTICE, the app source stays MIT, the weights are not relicensed. The cleanest fully-MIT options are Moonshine v2 (English) and sherpa-onnx Zipformer, which is why they make strong fallbacks.

## How this serves the audio architecture

The three audio use cases (barge-in everywhere, voice commands everywhere, accessibility separately) all depend on an always-on streaming recognizer that emits partial hypotheses and end-of-utterance signals. A streaming model with native EOU (Parakeet EOU 120M) or low finalization delay (Moonshine, Nemotron, Zipformer) is exactly the foundation for a single shared audio-interaction layer that every narrating surface (session, reader, Knowledge Bowl) plugs into. GLM-ASR's batch design cannot provide that.

## Caveats and required device validation

- No candidate has rigorous published iPhone streaming-latency (time-to-first-partial, finalization delay, real-time factor). The Moonshine numbers are Mac M3; the WhisperKit numbers are Mac M3 Max. Measure on the oldest supported iPhone before committing.
- The audit data is web-sourced as of 2026-06-01, past the assistant's training cutoff. Confirm exact repo IDs, file lists, sizes, and licenses before wiring.
- This is two model integrations plus a streaming pipeline, not a config change. Plan it as a real workstream.
