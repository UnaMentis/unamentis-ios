# On-Device LLM Audit for the Beta (2026-05-31)

Fresh, web-researched and adversarially verified survey of small on-device LLMs for an engaging real-time barge-in conversation on a modern iPhone. This is the decision input for the on-device LLM the beta will showcase. Data was gathered on 2026-05-31 from dated primary sources (Hugging Face model cards, vendor blogs, and two independent iPhone 17 Pro benchmark posts). Treat the exact numbers as current-best, and run one on-device latency test before committing the final pick.

## Bottom line

The answer that was "not yet" a few months ago is now YES. A modern iPhone can run a small LLM fast enough for an engaging, interruptible spoken conversation, especially paired with our filler and acknowledge-then-refine trickery. Time-to-first-token (TTFT) on the best small models is 160 to 360 ms and streaming is 40 to 62 tokens per second, which starts a spoken reply sub-second after a barge-in and streams far faster than TTS consumes.

**Recommended for the beta: Qwen3-1.7B (Apache 2.0) via MLX-Swift, with thinking mode disabled, delivered as an on-demand download (about 1 GB at 4-bit).** It is the best balance of clean licensing, real-time latency, footprint, and conversational quality, and it runs on our iOS 18+ target on a proven App Store framework.

Pair it with two optional tiers:
- **Quality tier (capable devices, optional larger download): Google Gemma 4 E2B (Apache 2.0)**, the best quality-for-size with clean licensing, at about 2.6 GB.
- **Speed/low-RAM tier: Qwen3-0.6B (Apache 2.0)**, about 350 MB, 163 ms TTFT, as the instant first-responder.

License is the deciding axis. The single fastest model measured (Liquid LFM2.5-1.2B) is excellent but its LFM Open License v1.0 fails our hard requirement (it caps commercial use at under 10M USD revenue and is not MIT-redistributable), so it is out unless we relax that constraint.

## Verified candidate landscape

iPhone numbers below are measured on iPhone 17 Pro (A19 Pro) unless noted. A18 (iPhone 16) will be somewhat slower but still real-time at these sizes. TTFT is the metric that matters most for barge-in.

| Model | License | 4-bit on disk | iPhone TTFT / decode | Real-time fit | Verdict |
|-------|---------|---------------|----------------------|---------------|---------|
| Qwen3-1.7B | Apache 2.0 (clean) | ~0.98 GB (MLX) | 360 ms / ~40 tok/s | Strong (disable thinking) | Recommended primary |
| Qwen3-0.6B | Apache 2.0 (clean) | ~0.35 GB | 163 ms / 62 tok/s | Strong, smaller brain | Speed tier / first-responder |
| Gemma 4 E2B | Apache 2.0 (clean) | ~2.6 GB (LiteRT) to 3.1 GB (GGUF) | ~300 ms / 56 tok/s (LiteRT Metal) | Excellent, best quality | Quality tier (on-demand) |
| Liquid LFM2.5-1.2B | LFM Open License v1.0 | ~0.66 to 0.73 GB | 244 ms / ~60 tok/s | Excellent | OUT on license |
| Apple Foundation Models (~3B) | Apple OS, AUP applies | 0 (ships in OS) | streaming, latency unproven | Strong integration | iOS 26 bonus path only, AUP risk |
| Llama 3.2 1B | Llama community license | ~0.70 GB | 253 ms / 58 tok/s | Strong | Backup, license less clean |
| Ministral 3 3B (Dec 2025) | Apache 2.0 (clean) | ~2.15 GB | not measured | Medium, terse | Possible, larger, unproven latency |
| SmolLM3-3B | Apache 2.0 (clean) | ~1.9 GB | unverified | High risk | Not for the showcase |
| Kyutai Moshi (full-duplex) | CC-BY-4.0 | ~5 GB (7B) | native barge-in, ~250 ms | Too big on-device | Server-side or future |

## Why Qwen3-1.7B for the beta

- License: Apache 2.0, unambiguously fine for both a paid App Store app and our MIT open-source repo. This is the hard gate that eliminates the otherwise-faster LFM2.5.
- Latency: 360 ms TTFT and ~40 tok/s on A19 Pro. The model begins a spoken response well under our 500 ms target, and 40 tok/s vastly outruns what a single TTS voice consumes (roughly 8 to 12 tok/s), so audio never starves.
- Footprint: about 1 GB at 4-bit, small enough to bundle or download on demand and to co-reside with Kyutai Pocket TTS, STT, and the app.
- Quality: a solid 1.7B instruction-tuned model. Combined with our filler and refine-while-researching trickery, it is comfortably in engaging-conversation range for a tutor that does not need graduate-level reasoning.
- Runs on iOS 18+ via MLX-Swift, which already ships in App Store apps, so this is a proven path, not a research demo.

Mandatory configuration: Qwen3 is a hybrid-reasoning model with thinking mode ON by default. Left at default it emits a long hidden reasoning chain before any user-visible token, adding seconds of latency and breaking barge-in. We must disable it (no-think mode) so the first useful token streams immediately.

## Why the others place where they do

- Gemma 4 E2B (Google, released April 2, 2026) is the quality-for-size leader and, importantly, the first Gemma under Apache 2.0 (Gemma 3 and 3n used Google's custom terms that do not cleanly relicense under MIT). The catch is size: about 2.6 GB on disk via LiteRT, not the sub-1.5 GB some sources claimed, and the fast path is GPU/Metal which uses about 1.45 GB RAM. Best as an optional quality tier downloaded on capable devices. A real App Store app (Locally AI) already runs Gemma 4 on iPhone via MLX, which de-risks the path.
- Apple Foundation Models (the on-device ~3B in iOS 26) is the best integration story on paper: zero bundle, OS-optimized, free, streaming API. Three hard limits keep it as a bonus, not the primary engine: it requires iOS 26 and Apple Intelligence hardware (A17 Pro or newer), so our iOS 18+ beta cannot rely on it across devices; the deployed context window is only about 4,096 tokens, tight for 60 to 90 minute sessions; and its Acceptable Use Requirements appear to prohibit generating courseware, textbooks, and academic course materials, which needs legal review before we lean on it for tutoring. Use it opportunistically on supported devices, gated behind a capability check, never as the sole brain.
- Liquid LFM2.5-1.2B is the fastest purpose-built edge model and posts the best instruction-following in its class, but the LFM Open License v1.0 fails our hard requirement (commercial use only under 10M USD revenue, not MIT-redistributable). If we ever relax the MIT-weights requirement, revisit this immediately; it is otherwise the sweet spot.
- Kyutai Moshi is the only true open full-duplex speech-to-speech model and is architecturally ideal for barge-in, and Kyutai compatibility is a plus since we already use Kyutai Pocket TTS. But at 7B and about 5 GB it is too large to co-reside on-device with our stack for a long session. Treat it as a server-side or future option.

## Framework choice

Two independent iPhone 17 Pro benchmarks settle this. For our constraints (iOS 18+, real-time, RAM headroom for TTS and STT, easy Swift integration):

- Primary: MLX-Swift (Apple). Pure Swift, Metal-accelerated, simple SwiftPM integration, MIT-licensed framework, already shipping in App Store apps. 40 to 62 tok/s on the small models. Higher RAM than LiteRT but fine at these model sizes.
- Quality-tier alternative: LiteRT-LM (Google AI Edge) for Gemma 4 specifically. Lowest RAM and fastest decode for Gemma 4, Apache-licensed, with a new iOS Swift API. Newer and Google-maintained.
- Lowest-risk portable fallback: llama.cpp + GGUF. Works, most portable and quantization-flexible, but slower and heavier on iPhone.
- Core ML / Neural Engine: lowest power and frees CPU/GPU, but slowest decode. A future optimization, not the starting point.
- Do not build on MediaPipe iOS (deprecated in favor of LiteRT-LM) and do not assume Apple Foundation Models on iOS 18.

## How it fits our barge-in and trickery architecture

The measured latencies map cleanly onto a tiered, latency-hiding design:

1. On barge-in detection, immediately play a pre-recorded or pre-generated filler ("Let me think about that," "Good question, one moment"). Perceived latency goes to zero.
2. A fast small model (Qwen3-1.7B, or Qwen3-0.6B for the very first words) starts streaming the real answer within 160 to 360 ms. TTS begins speaking as the first tokens arrive.
3. Because decode (40 to 62 tok/s) far exceeds TTS consumption, the model stays ahead of the voice and can even pause to refine.
4. Optionally, a larger model (Gemma 4 E2B on capable devices) or the server refines in the background for follow-up depth, surfaced as a natural "here is a bit more" continuation.

This is exactly the engaging, responsive experience the beta wants, and the on-device model only needs to be coherent and engaging, which these models clear.

## Recommended integration path (proposed for D2)

1. Add MLX-Swift via SwiftPM in `project.yml` (and define the on-device build condition there, not just in `Package.swift`; this is the gap that makes the current `localMLX` default dead in the shipped build per the audit finding ARCH-5).
2. Implement `MLXLLMService` conforming to the existing `LLMService` protocol, with streaming output and thinking mode disabled, and wire it as the on-device default (the existing default key is literally `localMLX`).
3. Ship Qwen3-1.7B 4-bit as an on-demand download (about 1 GB) with SHA256 verification (ties into security finding SEC-5), with Apple TTS/Speech and the server LLM as graceful fallbacks when the model is absent.
4. Optionally add a Gemma 4 E2B quality tier as a larger optional download on capable devices, and a capability-gated Apple Foundation Models path on iOS 26.
5. Remove the unusable 1.9 GB Llama 3.2 3B gguf currently bundled.

## Honest caveats

- This is web-sourced as of 2026-05-31, past the assistant's training cutoff. The verification pass cross-checked dated primary sources, but confirm exact model availability, the precise license text, and a quick real-device latency measurement before locking the final pick.
- Most iPhone numbers are iPhone 17 Pro (A19 Pro). Expect somewhat lower throughput on A18 (iPhone 16), still real-time at these sizes; measure on the oldest supported device.
- The Apple Foundation Models Acceptable Use Requirements and the courseware restriction need a real legal read before any reliance for tutoring content.

## Implementation status (2026-06-10): on-device LLM is enabled and generating

The path that actually landed differs from the MLX-Swift recommendation above: the integration uses llama.cpp with a GGUF model, because the prebuilt official xcframework provided the fastest verified route to a working pipeline. What landed, all verified in the tree and in the simulator:

- **llama.cpp b7263 official prebuilt xcframework** at `UnaMentis/Frameworks/llama.xcframework`, linked and embedded via `project.yml`. The earlier StanfordBDHG SPM wrapper (llama.cpp from early 2024, predating `llama_sampler_init_greedy`) was removed.
- **`LLAMA_AVAILABLE` is defined in both Debug and Release** `SWIFT_ACTIVE_COMPILATION_CONDITIONS` (`project.yml`), so the on-device path compiles into release builds, not just dev builds.
- **`OnDeviceLLMService` is no longer excluded** from the target and conforms to the existing `LLMService` protocol.
- **Batch-overflow fix**: `llama_batch_init` is now sized from the prompt (`max(512, tokens.count)`) instead of a fixed 512, which overflowed the batch buffers once a conversation grew past 512 tokens (`OnDeviceLLMService.swift`).
- **Dead bundle resource removed**: the unusable 1.9 GB Llama 3.2 GGUF that was previously bundled is gone (item 5 of the integration path above).
- **Model: Ministral 3 3B** (`Ministral-3-3B-Instruct-2512-Q4_K_M.gguf`, ~2.15 GB, Apache 2.0), loaded from `Documents/models/LLM/` with bundle and dev-path fallbacks. **Verified generating end to end in the iPhone 17 Pro simulator via `OnDeviceLLMService`.**

The unit tests that asserted `LLAMA_AVAILABLE` is undefined (`GLMASRAudioProcessingTests`, `GLMASRUnifiedGGUFTests`) were updated on 2026-06-11 to assert the new reality.

### Known issues (open as of 2026-06-10)

1. **Load Model button is a stub.** `OnDeviceLLMSettingsView`'s Load Model action fakes the Loaded state; it does not actually load the model into memory.
2. **Conversation Test header shows the wrong model name.** It displays the settings model name (for example `qwen2.5:14b-instruct`) instead of the on-device model actually running.
3. **No shared service instance.** Each call site constructs a fresh `OnDeviceLLMService`, which means a roughly 2 GB model reload per construction. Needs a shared instance.
4. **No SHA256 verification on model downloads.** The audit's integration path called for hash verification (security finding SEC-5); it is not implemented yet.
5. **Onboarding age toggle unresponsive to synthetic taps.** During simulator verification the 13+ age attestation toggle did not respond to synthetic idb taps while the adjacent telemetry toggle did. Verify by hand on a real device; if it reproduces with a real finger it blocks onboarding.
