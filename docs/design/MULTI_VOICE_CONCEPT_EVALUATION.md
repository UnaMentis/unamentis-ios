# Multi-Voice Orchestration: Evaluation Against the UnaMentis iOS Codebase

**Status:** Evaluation and gap analysis
**Source concept:** [MULTI_VOICE_ORCHESTRATION_CONCEPT.md](MULTI_VOICE_ORCHESTRATION_CONCEPT.md)
**Companion document:** [MULTI_VOICE_IMPLEMENTATION_PLAN.md](MULTI_VOICE_IMPLEMENTATION_PLAN.md)
**Date:** July 2026

---

## 1. Executive Assessment

The concept paper proposes four interlocking ideas: the voice as the continuity layer across multiple models, two presentation patterns (invisible single narrator versus an audible triad of learner, bridge, and expert), latency amortization through staged dialogue over rich prefetched payloads, and a dynamic on-device learner profile that tunes every layer.

The core finding of this evaluation: **UnaMentis iOS already contains roughly two thirds of the enabling machinery, and several of the paper's central mechanisms exist in the codebase today as smaller-scale versions of the same idea.** The paper is less a new direction than a scaling up of principles the codebase has already committed to. That makes it an unusually low-risk, high-leverage concept for this project.

Three facts drive that conclusion:

1. **The wedge already exists at micro scale.** Every AI turn today plays an instant canned filler, then streams sentence-by-sentence TTS with prefetch while the LLM is still generating. The paper's latency amortization is this exact pattern stretched from masking a 1-2 second gap to amortizing a 30-second frontier fetch across minutes of dialogue.
2. **The routing layer is built but dormant.** `PatchPanelService` implements the paper's tier routing almost verbatim (23 task types, capability tiers from tiny to frontier, condition-based rules, fallback chains) and is instantiated at app start, but the live turn path never consults it. `FallbackLLMService` is implemented and tested but never constructed in production. `RemoteLLMModel.swift` describes itself as "the seam the planned multi-tier model router will grow from."
3. **The voice continuity premise is already true.** Pocket TTS runs on device with 8 distinct voices plus 5-second voice cloning, behind a single shared `AudioPlaybackOrchestrator` that every speaking surface uses. One controlled TTS pipeline serving multiple brains is not aspirational; it is the current architecture with one brain plugged in.

The genuinely new work is concentrated in four artifacts: a structured expert payload schema, a cognition buffer with staleness detection, a persona contract layer, and a unified learner profile store. None require research. The paper's own risk assessment (staleness detection is the hardest engineering) matches what the codebase inspection suggests.

**Recommendation:** adopt the concept, follow the paper's phasing, and implement it by promoting existing dormant components onto the live turn path rather than building parallel systems. The implementation plan details this.

---

## 2. Asset Map: Paper Concept to Existing Code

| Paper concept | Existing asset | State |
|---|---|---|
| Tier 0 canned responses (§4.1) | `CannedResponseBank` + `ResponseIntent` + `SessionManager.playInstantFiller` | **Built and live.** Pre-rendered through the session TTS voice, intent-indexed, served in under 10 ms, de-duplicates recent picks. |
| Tier 1 on-device model (§4.1) | `OnDeviceLLMService` (llama.cpp, GGUF), `OnDeviceLLMModelManager` model ladder (Gemma 3n E2B, Qwen3 1.7B/0.6B) | **Built, gated, not wired.** Behind `LLAMA_AVAILABLE`; requires 6 GB+ RAM; not selectable on the live session path. |
| Tier 2/3 hosted models (§4.1) | `AnthropicLLMService`, `OpenAILLMService`, `GoogleLLMService`, `SelfHostedLLMService`, all streaming | **Built and live**, but one service per session, chosen in `SessionView`. No per-turn tiering. |
| Invisible routing (§4.1) | `PatchPanelService` + `LLMTaskType` (23 types with `minimumCapabilityTier`) + `RoutingTable` + `RoutingCondition` (thermal, memory, battery, cost) | **Built, tested, dormant.** Instantiated in `AppState`, never consulted by `SessionManager`. |
| Graceful tier degradation (§9) | `FallbackLLMService` ordered tier chain | **Built and unit-tested, never constructed in production.** |
| One consistent voice (§3) | Pocket TTS (`KyutaiPocketTTSService`, on-device Rust/Candle, ~200 ms TTFB) as default; single shared `AudioPlaybackOrchestrator`; `AudioEngine` actor | **Built and live.** The whole app already speaks through one controlled pipeline. |
| Multiple distinct voices (§4.2) | `KyutaiPocketVoice`: 8 built-in voices, plus 5-second voice cloning via `setReferenceAudio` | **Built.** Voice is a per-session scalar today (`@AppStorage "ttsVoice"`); no per-segment voice switching. |
| Persona contracts (§5.3) | Nothing. Closest seams: `SessionConfig.systemPrompt`, `FOVContextManager.buildSystemPrompt` (pedagogically enriched builder, currently only exercised by tests), `BargeInResponder.SystemPromptBuilder` | **Gap.** No persona abstraction exists. |
| Rich payload + improvised unspooling (§6.1) | `ResponsePreGenerator`: speculatively pre-generates response starters for 5 predicted user intents during idle time, keyed to a context fingerprint, invalidated on topic shift | **Proto-version built and live.** It prefetches starters, not structured payloads, but the fingerprint/invalidate/match-on-intent loop is exactly the cognition buffer's control flow. |
| Cognition buffer with coverage metadata (§6.2, §8.1) | `AudioPlaybackOrchestrator` prefetch cache (audio layer), `AudioPreGenInvalidator`, `TTSPlaybackConfig` presets | **Audio-level analogue built.** No content-level buffer or coverage metadata. |
| Staleness detection (§6.4) | `ResponsePreGenerator` context-fingerprint invalidation; `ConfidenceMonitor`; embeddings + cosine similarity utilities in `Services/Embeddings` and `CurriculumModels` | **Ingredients exist, mechanism does not.** |
| Barge-in against the buffer (§6.2) | `BargeInDetector` (tentative/confirmed state machine, sustained-speech gating), `BargeInClassifier` (command versus engagement), `BargeInResponder`, `BargeInCoordinator`, measurement harness with gating criteria in `.claude/goals/barge-in.json` | **Built, live, instrumented.** Reaction latency target: median ≤ 300 ms. Interruptions do not yet consult any content buffer. |
| Learner profile, sparse and contextual (§7.1) | Fragmented: `LearnerSignals` (in-session only, prompt-injected), `Topic.mastery` + `TopicProgress.quizScores` (Core Data), `RetrievalSchedule` with working SM2 and Leitner implementations (defined, never persisted or driven), KB's separate `KBStatsManager` | **Pieces exist, no unified store.** Nothing carries confidence weights or per-domain dimensions. |
| Profile on device, inspectable (§7.4) | Core Data via `PersistenceController`, all local; no profile UI | **Posture already matches.** The app is already local-first for user data. |
| Learning-outcome evaluation (§9) | `TelemetryEngine` latency channels, `TTFAInstrumentation`, barge-in measurement harness, metrics upload to management server | **Latency evaluation strong; learning-outcome evaluation lives in edu-voice-ai-eval, outside this repo.** |

---

## 3. Where the Paper Lands on Existing Architecture

### 3.1 The continuity layer is the current design, formalized

The paper's core principle (§3) is that continuity lives in the TTS pipeline and persona, not in a single model. UnaMentis iOS already routes every speaking surface (session, reading list, Knowledge Bowl, announcements, barge-in responses) through the same `AudioPlaybackOrchestrator` and `AudioEngine`, with the same voice configuration. The canned filler bank is pre-rendered through the same TTS voice so Tier 0 is audibly indistinguishable from live synthesis. What is missing is only the linguistic half of the persona: a narrating layer that renders content from deeper models in one consistent style. Today, whichever model is selected speaks in its own style, which is exactly the failure mode §3 warns about; it just is not visible yet because only one model speaks per session.

### 3.2 Latency amortization: the codebase already believes in this

The existing turn pipeline is a three-stage wedge: instant canned filler, then streamed sentences into a prefetching playback queue, then speculative pre-generation of likely next-turn starters during user listening time. `ResponsePreGenerator` even implements the paper's harder ideas in miniature: prediction of likely user intents, context fingerprinting, and invalidation on topic shift. The conceptual step the paper adds is inversion of scale: instead of prefetching the first sentence of the next turn, prefetch a structured payload that funds minutes of dialogue, and treat the dialogue itself as the delivery mechanism. The plumbing habits (prefetch depth, cache eviction, invalidator hooks, buffering states) transfer directly.

### 3.3 The triad is the largest experience change, and the smallest infrastructure change

Making two voices talk to each other sounds like a new audio architecture. It is not, in this codebase. `PlayableSegment`s flow through one orchestrator; giving segments a per-voice configuration and letting Pocket TTS switch among its 8 voices (a config index change, not a model reload) turns the triad's audio layer into an incremental orchestrator feature. The real new work in the triad is dialogic: persona contracts, a turn planner that stages bridge/expert exchanges from payload content with timing direction, and the no-fabrication rule enforced structurally (the bridge can only attribute to the expert content that carries a payload provenance tag).

### 3.4 The learner profile has three orphaned ancestors

The codebase contains an ephemeral in-session signal tracker (`LearnerSignals`), a persisted per-topic mastery score, and a complete but unwired spaced-repetition engine. These are three partial answers to the same question the paper answers fully. The paper's contribution is the shape of the store: sparse, per-domain, confidence-weighted, hypothesis-not-verdict, user-inspectable. Adopting it would also give the orphaned spaced-repetition code its reason to exist (decay and re-testing, §7.3, is what `RetrievalSchedule` already computes).

---

## 4. Strategic Benefit

1. **A defensible differentiator.** The paper is right that the triad (live, barge-in-capable, learner-advocating multi-voice dialogue) does not exist in any shipping product. UnaMentis has the two hardest prerequisites already working on device: sub-second controlled TTS with multiple voices, and instrumented barge-in with a 300 ms reaction target. The distance from "NotebookLM theater" to "interactive triad" is mostly the distance UnaMentis has already covered.
2. **It resolves the project's central tension.** The stated performance target (sub-500 ms turn latency) and the stated product ambition (60-90+ minute deep learning sessions) pull against each other under naive per-turn architecture. Staged dialogue is the mechanism that lets both targets stand: rhythm from the fast layers, depth from amortized frontier calls.
3. **It gives dormant investments a payoff.** Patch panel, fallback chain, FOV context system, enriched Socratic prompt builder, spaced-repetition engine: significant already-paid engineering becomes load-bearing under this concept instead of remaining scaffolding.
4. **Privacy posture compounds.** The on-device learner profile matches the app's existing local-first data model and its on-device STT/TTS/LLM trajectory. A rich cognitive profile is only a trust liability if it is opaque or remote; the paper's inspectable-and-editable stance turns it into a feature.
5. **Hands-free-first alignment.** The bridge voice asking the learner's half-formed question is an accessibility win as much as a pedagogy win, and it fits the platform's hands-free mandate: the triad requires no screen interaction at all.

---

## 5. Gaps (the genuinely new builds)

| Gap | Description | Difficulty |
|---|---|---|
| Expert payload schema | Versioned structured format for frontier responses: key points, derivations, anticipated questions, counterpoints, analogies, coverage tags | Moderate. Schema design plus prompt/tool-use work. |
| Cognition buffer | Client-side payload store with coverage metadata, consumption tracking, prefetch scheduling | Moderate. Follows existing actor patterns. |
| Staleness detection | Hybrid semantic-distance heuristic plus cheap-model judgment; triggers refetch | **Hard. The paper is right to front-load it.** |
| Turn orchestrator on the live path | Consult patch panel per task type, wrap tiers in the fallback chain | Low. Activation of existing code. |
| Persona contracts | Codable per-voice specs (audio voice, register, role, awareness of other voices), enforced by the narrating layer | Moderate. New abstraction, clear seams exist. |
| Triad dialogue planner | Stages bridge/expert exchanges from payload with timing direction; no-fabrication enforcement | Hard. The novel experience work. |
| Learner profile store | Unified sparse per-domain store with confidence, decay, probes; editor UI; update pipeline from conversation events | Moderate. Mostly integration of existing fragments. |

## 6. Risks and Tensions Specific to This Codebase

- **`SessionManager` is already a 1,778-line god object** with a legacy playback path still inside it. Adding orchestration logic there directly would be the architectural mistake; the plan proposes a separate actor.
- **Memory budget.** On-device LLM (Tier 1) plus Pocket TTS plus VAD plus STT must stay within the 50 MB-growth-per-90-minutes target and the 600 MB advisory peak. Tier 1 may need to remain optional per device, as the paper's own hardware-floor risk anticipates. The architecture must degrade to Tiers 0/2/3 cleanly.
- **Settings sprawl.** Voice/persona settings would land in an area with a documented duplication problem (`SettingsViewModel` versus `VoiceSettingsViewModel`, diverged presets). Persona contracts should be data files, not more `@AppStorage` keys.
- **Integrity rule versus existing speculation.** `ResponsePreGenerator` speculatively drafts responses before the user speaks. That is fine for a single narrator speaking as itself, but under the triad it must never be used to draft expert-attributed content: §6.3's no-fabrication rule needs enforcement at the segment level (provenance tags), not by convention.
- **Evaluation gap.** Latency instrumentation is excellent; learning-outcome measurement is external. Phase 3's claim (triad teaches better than single narrator) is only testable with the eval framework in the loop.
- **Concurrency discipline.** Every new component must follow the established actor patterns (Swift 6 strict concurrency). The multi-model fan-out (narrator streaming while expert fetch runs while prefetch fills) is exactly where data races would breed; the existing single-choke-point state machine style of `SessionManager.setState` should be replicated in the new orchestrator.

## 7. Verdict

Adopt. The concept is a scaling-up of commitments this codebase has already made, the hardest prerequisites (controlled multi-voice TTS, instrumented barge-in, prefetch discipline) are already working, and the dormant routing layer suggests the team was already heading here. Follow the paper's four phases with staleness detection front-loaded, and measure Phase 3 against Phase 1 with real learning tasks before committing to the triad as the default experience.

See [MULTI_VOICE_IMPLEMENTATION_PLAN.md](MULTI_VOICE_IMPLEMENTATION_PLAN.md) for the concrete phasing, decision points, and component-level design.
