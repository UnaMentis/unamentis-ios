# Multi-Voice Orchestration: Implementation Plan

**Status:** Proposed plan, pending review
**Source concept:** [MULTI_VOICE_ORCHESTRATION_CONCEPT.md](MULTI_VOICE_ORCHESTRATION_CONCEPT.md)
**Companion document:** [MULTI_VOICE_CONCEPT_EVALUATION.md](MULTI_VOICE_CONCEPT_EVALUATION.md)
**Date:** July 2026

This plan turns the concept paper into concrete work items against the current codebase. It follows the paper's four phases, front-loads staleness detection as the paper recommends, and prefers promoting existing dormant components over building parallel systems.

---

## 1. Design Decisions

Each decision lists the options considered and a recommendation. These should be settled before Phase 1 coding starts.

### D1. Where does the orchestrator live?

The paper's component map names an Orchestrator that owns routing, prefetch scheduling, staleness detection, and cache invalidation.

- **Option A: extend `SessionManager`.** Lowest ceremony, but `SessionManager` is already 1,778 lines, carries a legacy playback path, and mixes turn lifecycle with UI state publication.
- **Option B: new `TurnOrchestrator` actor** in `Core/Session/`, consulted by `SessionManager` at the two seams it already has (`generateAIResponse` and the barge-in commit path). `SessionManager` keeps the session state machine and UI publication; the orchestrator owns model selection, payload lifecycle, and buffer state.

**Recommendation: B.** It mirrors the existing division of labor between `SessionManager` and `AudioPlaybackOrchestrator`, keeps Swift 6 isolation boundaries clean, and makes the orchestrator unit-testable without a live session. Replicate the single-choke-point state transition style of `SessionManager.setState`.

### D2. How is tier routing activated?

- **Option A: consult `PatchPanelService` per turn.** `generateAIResponse` resolves a `RoutingDecision` for the task type (for example `.tutoringResponse`, `.acknowledgment`, `.intentClassification`) and the decision's endpoint chain is wrapped in a `FallbackLLMService`. Both components exist and are tested.
- **Option B: hardcode a two-tier split first** (fast narrator model plus frontier payload model), defer the patch panel.

**Recommendation: A, scoped.** Wire the patch panel for the small set of task types Phase 1 actually uses (narration, payload fetch, intent classification, acknowledgment). The endpoint registry needs a refresh regardless: `LLMEndpoint.defaultRegistry` currently lists model generations that should be updated at implementation time, and on-device endpoints are marked unavailable. Treat registry refresh as part of this work item.

### D3. Where are expert payloads generated?

- **Option A: client calls the frontier API directly.** Matches the current architecture; every LLM service already streams from the client. Payload structure enforced by prompt plus JSON parsing (or tool-use structured output for Anthropic/OpenAI).
- **Option B: server-side payload endpoint on the management server.** Centralizes prompt/schema versioning and lets the server cache payloads across users for shared curriculum topics, but adds a server dependency to the core loop and couples client releases to server releases.

**Recommendation: A for Phases 1-3, revisit B when curriculum-shared payload caching becomes attractive.** Keep the payload request builder in one type (`ExpertPayloadService`) so relocating generation server-side later is a transport change, not a redesign.

### D4. Payload schema shape

Define `ExpertPayload` as a versioned Codable in `Core/Session/Payload/`:

```swift
struct ExpertPayload: Codable, Sendable {
    let schemaVersion: Int
    let topicFingerprint: String       // ties to FOV context fingerprint
    let keyPoints: [PayloadChunk]
    let derivations: [PayloadChunk]
    let anticipatedQuestions: [AnticipatedQA]
    let counterpoints: [PayloadChunk]
    let analogies: [PayloadChunk]
    let coverage: [CoverageTag]        // semantic tags for staleness checks
}

struct PayloadChunk: Codable, Sendable, Identifiable {
    let id: String                     // provenance handle (see D7)
    let text: String
    let tags: [CoverageTag]
    let difficulty: ContentDepth?      // reuse existing depth enum
}
```

`AnticipatedQA` pairs a predicted learner question with the expert's answer chunk. `CoverageTag` is the unit of staleness bookkeeping: the buffer knows which tags have been consumed, and the staleness detector compares live conversation embedding against unconsumed tags. Reuse `ContentDepth` and the profile's representation preference (Phase 4) to bias what the payload prompt asks for.

### D5. How do multiple voices share the audio pipeline?

- **Option A: per-segment voice.** Extend `PlayableSegment` with an optional `voiceConfig: TTSVoiceConfig`. `AudioPlaybackOrchestrator.playSegment` configures the TTS actor before synthesis when the voice differs from the previous segment. For Pocket TTS a voice switch is a `voiceIndex` config change, not a model reload, so the cost is small; measure it and prefetch across voice boundaries.
- **Option B: one TTS service instance per voice.** Cleaner isolation, but doubles engine memory for Pocket TTS and complicates the orchestrator's prefetch cache.

**Recommendation: A.** Verify with a spike that Pocket TTS voice switching latency is acceptable between segments (expected: yes, it is config-level). Fall back to B only for providers where reconfiguration is expensive. Canned response banks become per-persona: `CannedResponseBank.populate` runs once per persona voice.

### D6. Persona contracts: format and location

- **Option A: Swift structs compiled in.**
- **Option B: versioned JSON/UMCF-style resource files** in `Resources/Personas/`, parsed into a `PersonaContract` type, selectable and eventually server-updatable.

**Recommendation: B.** The paper calls persona contracts versioned documents, and data files keep persona iteration out of app releases later. Schema:

```swift
struct PersonaContract: Codable, Sendable {
    let id: String
    let version: Int
    let displayName: String
    let role: PersonaRole              // narrator, bridge, expert
    let voiceId: String                // maps to KyutaiPocketVoice or clone reference
    let register: String               // vocabulary and tone specification (prompt fragment)
    let cadence: String                // pacing directives (prompt fragment)
    let roleBoundaries: [String]       // hard rules, e.g. bridge never fabricates
    let awareness: [String]            // ids of other personas it knows about
}
```

The narrating layer enforces the contract by building its system prompt from these fields. Wire this through the currently test-only `FOVContextManager.buildSystemPrompt` path so persona, depth, learner signals, and objectives compose in one place. Do not add persona state to `@AppStorage`; the settings layer already has a documented duplication problem.

### D7. No-fabrication enforcement mechanism

Convention is not enough. Every dialogue segment the planner emits carries a `provenance` field:

- `.expert(chunkID)`: text derived from a payload chunk. Only these may be attributed to the expert voice or quoted as the expert's position.
- `.bridge`: bridge's own words (translation, Socratic probing, meta-conversation).
- `.deferral`: bridge explicitly deferring ("good question, let me put that to him") which is also the fetch-masking beat.

The orchestrator rejects any expert-attributed segment without a valid chunk ID at enqueue time and logs it as an integrity violation to telemetry. This makes §6.3 of the paper a type-system property instead of a prompt hope. `ResponsePreGenerator` speculative starters must be marked `.bridge` and are never usable for expert content.

### D8. Learner profile storage

- **Option A: Core Data entities** via the existing `PersistenceController` (new `LearnerProfileEntry` entity: domain, subdomain, dimension, value, confidence, lastEvidenceAt, observationCount).
- **Option B: versioned JSON document** like the KB stores.

**Recommendation: A.** The profile is queried per turn (routing, prompt building) and updated incrementally from conversation events; Core Data already handles the app's per-topic mastery and migrations. The sparse matrix maps naturally to rows keyed by (domain, dimension). Track `vocabulary` and `comprehension` as separate dimensions from day one, per §7.1 of the paper. The user-facing editor reads the same store.

---

## 2. Phase 1: Single Narrator with Wedge

Goal: one voice, invisibly backed by a fast narrator model and a frontier payload model. Proves latency amortization and payload improvisation with minimal new surface.

| # | Work item | Builds on |
|---|---|---|
| 1.1 | `TurnOrchestrator` actor skeleton; `SessionManager.generateAIResponse` delegates model selection and streaming to it | `SessionManager`, existing turn seams |
| 1.2 | Patch panel on the turn path: resolve routing for narration, payload fetch, intent classification, acknowledgment; wrap endpoint chains in `FallbackLLMService`; refresh `LLMEndpoint.defaultRegistry` | `PatchPanelService`, `FallbackLLMService`, `RemoteLLMModel` |
| 1.3 | `ExpertPayload` schema v1 + `ExpertPayloadService` (frontier request builder, structured output parsing, one retry on schema violation) | `AnthropicLLMService` and peers |
| 1.4 | `CognitionBuffer` actor: holds active payloads, tracks consumed chunks/tags, exposes `answerable(from:)` for interruption checks, schedules prefetch of the next payload while the current one plays out | `ResponsePreGenerator` patterns, `AudioPreGenInvalidator` |
| 1.5 | Narrator prompting: wire `FOVContextManager.buildSystemPrompt` into the live path; add improvise-from-payload instructions (reorder, expand what lands, skip what does not, never recite) | `FOVContextManager`, `SessionManager+FOVContext` |
| 1.6 | Wedge integration: canned acknowledgment → narrator engagement from buffered material → deep result arrives in flight | `CannedResponseBank`, `playInstantFiller` |
| 1.7 | Telemetry: payload fetch latency, buffer hit rate on user utterances, narration-source mix (buffered versus live-fetch), amortization ratio (dialogue seconds funded per fetch second) | `TelemetryEngine`, `TTFAInstrumentation` |

Exit criteria: a session sustains multi-minute topic dialogue where median perceived response gap stays within current TTFA targets while the underlying frontier fetches take 10-30+ seconds; buffer hit rate on learner questions exceeds an agreed threshold (propose 70% to start).

## 3. Phase 2: Staleness Detection (front-loaded risk)

Goal: know when the buffered payload no longer covers the conversation, and refetch behind a natural beat instead of stretching stale material.

| # | Work item | Builds on |
|---|---|---|
| 2.1 | Coverage instrumentation: every narrator turn records which chunks/tags it drew on; unconsumed-coverage view per payload | `CognitionBuffer` |
| 2.2 | Semantic drift signal: embed recent learner utterances, compare against payload coverage tags via existing cosine similarity utilities | `Services/Embeddings`, `CurriculumModels` similarity helpers |
| 2.3 | Judgment signal: cheap-model check ("does the buffer cover where this is going?") routed as an `.intentClassification`-tier task | Patch panel tier routing |
| 2.4 | Hybrid staleness policy: drift score plus judgment vote plus consumption ratio, hysteresis to prevent thrash; on trigger, invalidate and refetch with the deferral beat masking latency | `ResponsePreGenerator` invalidation pattern |
| 2.5 | Goal file and harness: `.claude/goals/staleness.json` with gating metrics (stale-served rate, unnecessary-refetch rate, refetch-to-coverage latency), measured by a scripted conversation corpus, mirroring the barge-in harness approach | `Testing/BargeInHarness` pattern |

Exit criteria: on a drift-scripted corpus, stale material is served past the drift point in under an agreed fraction of turns, and refetch thrash stays under budget. Tune thresholds empirically; the paper is explicit that this is the hardest engineering, so timebox and iterate.

## 4. Phase 3: The Triad

Goal: audible bridge and expert voices in genuine dialogue, learner able to barge in on any of it. Evaluate against Phase 1, not assumed better.

| # | Work item | Builds on |
|---|---|---|
| 3.1 | `PersonaContract` loader + two shipped contracts (bridge, expert) with distinct Pocket voices; per-persona canned banks | D6, `KyutaiPocketVoice`, `CannedResponseBank` |
| 3.2 | Per-segment voice in the audio path: `PlayableSegment.voiceConfig`, orchestrator voice switching, prefetch across voice boundaries; spike Pocket TTS switch latency first | D5, `AudioPlaybackOrchestrator`, `PlayableSegment` |
| 3.3 | `TriadDialoguePlanner`: stages bridge/expert exchanges from payload content with timing direction (turn lengths, beats, who reacts to what), interleaving learner-directed Socratic probes | `CognitionBuffer`, persona contracts |
| 3.4 | Provenance enforcement at enqueue (D7) plus integrity telemetry | `TurnOrchestrator` |
| 3.5 | Barge-in against the buffer: on confirmed engagement, classifier consults `CognitionBuffer.answerable(from:)` first; buffered answers go to the bridge instantly, uncovered questions trigger the deferral beat and a real fetch | `BargeInClassifier`, `BargeInResponder`, `BargeInCoordinator` |
| 3.6 | Mode selection: triad as a per-activity mode alongside single-narrator (Pattern A remains the default for quick assistance surfaces) | `SessionConfig`, module system |
| 3.7 | Comparative evaluation: same learning tasks run under Phase 1 and Phase 3 configurations through the eval framework; measure comprehension outcomes, not just engagement | edu-voice-ai-eval, `TelemetryEngine` |

Exit criteria: triad sessions hold the same latency and barge-in gates as single-narrator; zero provenance violations in gated runs; evaluation shows the triad at least matching single-narrator outcomes before it becomes a promoted experience.

## 5. Phase 4: Dynamic Learner Profile

Goal: the sparse, contextual, confidence-weighted profile driving routing, prefetch fill, persona register, and Socratic calibration.

| # | Work item | Builds on |
|---|---|---|
| 4.1 | `LearnerProfileStore` (Core Data per D8): dimensions vocabulary, comprehension, representation preference, engagement style; keyed per domain/subdomain; confidence and evidence counts per entry | `PersistenceController`, existing `Topic.mastery` |
| 4.2 | Update pipeline: promote `LearnerSignals` and `ProductiveStruggleMetrics` events (clarification requests, barge-in questions, teachback results, questions not needed) into profile observations at session end and at checkpoints | `LearnerSignals`, `TeachbackResult`, `TurnOrchestrator` events |
| 4.3 | Hypothesis discipline: confidence decay over time, occasional above-level probes, re-testing prompts; adopt the dormant `RetrievalSchedule` (SM2/Leitner) for decay and re-test scheduling | `RetrievalSchedule`, `RetrievalConfig` |
| 4.4 | Bootstrap flow: short interview exchanges spread across the first week, orchestrated as ordinary session moments, never one intake session | Onboarding UI, session prompts |
| 4.5 | Profile consumers: payload prompt fill (analogies versus derivations), persona register per domain, patch panel routing context, Socratic question selection | `ExpertPayloadService`, `PersonaContract`, `PatchPanelService`, `TriadDialoguePlanner` |
| 4.6 | Inspectable editor: profile viewer/editor UI showing dimensions, confidence, and evidence, with user correction writing back at full confidence | `UI/Settings/`, mindful of the settings duplication audit |

Exit criteria: profile-driven payload fill measurably changes payload composition per learner; user edits round-trip; no ceiling effects in monitoring (flag any domain where modeled level and probe results diverge persistently).

---

## 6. Cross-Cutting Requirements

- **Concurrency:** all new components are actors following `UnaMentis/CLAUDE.md` rules; single choke-point state transitions; Sendable boundaries for everything crossing the orchestrator.
- **Testing:** Real-over-Mock applies. `MockLLMService` (a paid-API mock, allowed in `MockServices.swift` policy) drives deterministic payload and staleness tests; buffer, planner, provenance, and profile logic get real-implementation unit tests. Harness-based gating for staleness and triad latency mirrors the barge-in goal pattern. `/validate` before every completion claim.
- **Feature flags:** each phase ships behind a flag (`FeatureFlags` service) so Pattern A remains the stable default throughout.
- **Memory and degradation:** the stack must degrade to Tiers 0/2/3 when the on-device LLM is absent (device floor per the on-device audits). Track peak memory against the 600 MB advisory with two TTS voice configs and the buffer resident.
- **Hands-free:** triad and profile bootstrap interactions must be fully voice-operable per the hands-free-first spec; the profile editor is the one screen-first surface.
- **Docs:** update `docs/README.md` design section as phases land; persona contract schema and payload schema get their own reference docs once stabilized.

## 7. Sequencing and Sizing (rough)

| Phase | Dependency | Relative size |
|---|---|---|
| 1. Narrator + wedge | none | M-L: mostly promotion and integration of existing parts, plus payload schema |
| 2. Staleness | Phase 1 buffer | M, high uncertainty: timeboxed empirical tuning |
| 3. Triad | Phases 1-2 | L: planner and persona work is the novel build |
| 4. Profile | usable after Phase 1, full value after 3 | M: integration-heavy, low research risk |

Phases 2 and 4.1-4.2 can proceed in parallel after Phase 1, since the profile store has no dependency on staleness detection. The comparative evaluation in 3.7 is the decision gate for how hard to push the triad as the flagship experience.
