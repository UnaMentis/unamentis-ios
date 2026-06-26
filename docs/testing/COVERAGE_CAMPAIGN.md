# Coverage Campaign: the official cadence

**Date:** 2026-06-21
**Goal:** Genuine quality gating of the logic layer (Core / Services / ViewModels) via REAL, meaningful tests (Real Over Mock), green in CI. The 80% line-coverage figure is the floor we must clear, but it is **secondary to the intent**.

## Quality over the number (the controlling principle)

Coverage is a byproduct, not the objective. The objective is sincere quality gating: catching real regressions before they ship. A test only counts if it **validates a real outcome**, exercising a meaningful function and asserting the behavior that actually matters. It is trivially possible to write a pile of tests that execute lines but verify nothing (no assertions, tautologies, asserting on mocks, re-asserting language/library behavior, or "does not crash" where the real contract is the value produced). Those are worse than no test: they inflate the number and give false confidence.

Therefore, for every test written or revived in this campaign:
- It must assert the **correct behavior/value/error**, not merely that code ran.
- It must test a function/outcome **worth protecting**, not filler.
- Edge cases and failure paths matter more than happy-path line hits.
- Reviving a disabled test means making it genuinely correct again, never weakening assertions or stubbing it to pass.
- Every wave includes an adversarial quality pass that rejects shallow/tautological tests; rejected tests are removed, not counted.

If a module cannot be meaningfully tested to 80% with real assertions, we say so and fix the design or document why, rather than padding with hollow tests. A lower number of honest tests beats a higher number of hollow ones.

SwiftUI View bodies are excluded from the logic-layer denominator (they are ~60% of the app's lines and are covered separately by XCUITest of critical flows, see the final phase). The 80% bar is on testable logic.

---

## The cadence (mandatory, per wave)

Each wave is a measured batch (a handful of modules), and we do NOT start the next wave until the current one is fully landed and green:

1. **Author** real tests for the wave's modules (Real Over Mock: real internal implementations; only paid external APIs mocked via `MockServices.swift`).
2. **Integrate + fix up locally** until the unit suite **builds and is green** and the coverage gate passes. Nothing broken, nothing bent to pass. If a test cannot be made real and passing, drop it and note it.
3. **Measure** the new coverage and the delta.
4. **Commit** the wave (Claude commits on the standing go for this campaign; see below).
5. **Push** (human) and **confirm CI is green on GitHub**. The repo is public, so CI runs on free runners.
6. **Raise the coverage ratchet** (`COVERAGE_THRESHOLD` in `.github/workflows/ios.yml` and `.hooks/pre-commit`) to just below the new measured coverage, locking in the gain.
7. **Only then** start the next wave.

**The rule:** a wave is not done until it is committed, pushed, and green in CI. Healthy progress over raw percentage. This keeps each step digestible and prevents arriving at a high number sitting on a pile of failures.

### Commit mechanics for the campaign
Per the repo git policy (CLAUDE.md), Claude commits only on an explicit, real-time command and never pushes. There is no standing or blanket permission: each wave's commit needs its own go-ahead. Claude's role per wave is to drive the wave to local green, stage it, and present it ready; the human gives the commit word, then pushes and confirms CI. If a wave does not reach local green, it is not staged for commit, it is fixed or shrunk first.

### Wave sizing
Keep waves digestible so a failure is contained and CI verification is quick. Adapt: if a wave integrates cleanly, the next can be similar size; if it is messy, shrink it. The local green-gate (step 2) is the real protection against a mess, wave size is the secondary control.

---

## Progress

| Date | Overall | Logic-only | Ratchet | Notes |
|------|---------|------------|---------|-------|
| 2026-06-21 (start) | 12.0% | ~28% | 10 | QA pipeline repaired; gate honest |
| 2026-06-21 (wave 1) | 17.6% | 45% (Core 56% / Services 33%) | 10 | +5.6 overall / +17 logic; 36 real-test files; 5 real bugs fixed |
| 2026-06-24 (CI fixed) | 17.8% (app-scoped) | - | 15 | full CI green end-to-end; coverage scoped to app target; unit run ~6-11m (was hanging) |
| 2026-06-24 (wave 2) | 19.4% | - | 15 | 228 disabled KB/STT tests revived, quality-gated; 19 hollow dropped |
| 2026-06-25 (wave 3) | 20.6% | - | 15 | ~280 new tests: TTS/STT/ViewModels/Core remainder; quality-gated (2 weak tests strengthened) |
| 2026-06-25 (wave 4) | 20.8% local / 20.3% CI | - | 19 | Voice pipeline + context: SileroVADService 65.8% (fallback path; CoreML inference unreachable without bundled model), VADService types 91.9%, AudioSegmentCache 95.6%, ConfidenceMonitor 98.9%, BufferModels 97.8%. ~97 real tests; adversarial pass deleted 8 hollow/duplicate, strengthened 17, added 4 boundary tests |
| 2026-06-25 (wave 5) | 20.9% local / 20.5% CI | - | 20 | Audio config + context manager: AudioEngineConfig 100% (thermal isExceededBy truth table, bit-depth/format mapping, preset integrity, Codable), PlaybackOrchestratorConfig 100% (preset values + relationships, replaced a pre-existing stored-property echo), FOVContextManager 82.9% (buffer assembly, tier-driven turn cap, episodic trimming, buildSystemPrompt conditionals, compressEpisodicBuffer with mocked summarizer LLM). 46 real tests; adversarial pass deleted 7 hollow/subsumed, strengthened 8 (incl. converting a tautological thermal matrix to an independent truth table) |

Target: logic-only >= 80%. (Denominator is the whole UnaMentis.app target, ~114.7k executable lines including SwiftUI View bodies, so a fully-covered module moves the headline only a few tenths. Per-file coverage of the critical-path modules is the real signal.)

Deferred: the OpenAI/Anthropic LLM HTTP internals (request-body building, SSE/stream parsing, status-code error mapping) are inlined inside the URLSession streaming call, so honestly exercising them needs a URLProtocol-interception harness. That is a deliberate future wave (build the stub infra first), not something to rush a new pattern into. (Denominator is the whole UnaMentis.app target, 114,732 executable lines including SwiftUI View bodies, so a fully-covered module moves the headline only a few tenths. Per-file coverage of the critical-path modules is the real signal.)

## Wave plan (logic modules, highest ROI first)

- **Wave 1 (DONE, green):** Core/Config, Core/Tools, Core/Telemetry, Core/Session, Core/Curriculum, Core/ReadingList, Core/Context, Core/Discovery; Services/KnowledgeBowl, Services/Curriculum, Services/LLM, Services/ReadingPlayback.
- **Wave 2-3 (DONE, green):** Services/TTS and Services/STT (request building, response parsing, cost, error mapping, routing/health, with the paid-API boundary mocked), Core/Audio caches, Core/Persistence, the UI ViewModels (DebugConversationViewModel, ChatterboxSettingsViewModel, SessionViewModel, ReadingPlaybackViewModel, KB view models, settings view models), Intents, remaining Core/Services.
- **Wave 4 (DONE, green):** Voice pipeline first per the MVP prioritization. Services/VAD (SileroVADService fallback path + VAD protocol value types), Core/Audio/AudioSegmentCache, Core/Context (ConfidenceMonitor uncertainty detection, BufferModels budget/buffer rendering).
- **Wave 5 (DONE, green):** Core/Audio/AudioEngineConfig, Core/Audio/PlaybackOrchestratorConfig, Core/Context/FOVContextManager (the per-turn LLM context assembler).
- **Wave 6+ (prioritized order):** AI/models is next (Services/LLM, STT/TTS providers, Embeddings), but much of the provider logic (request building, stream parsing, error mapping) is inlined inside the URLSession call, so it needs a URLProtocol-interception harness built first; build that, then sweep the providers. Then server comms (Core/Discovery, Core/Routing, Core/Config), then observability/stability (Core/Logging, Core/Telemetry, Core/Device), then the basics (Curriculum, ReadingList, Todo, KnowledgeBowl, etc.).
  - Skipped as integration-only (NOT unit-testable without hardware/audio side effects, would only yield "did not crash"): Core/Audio/UnifiedAnnouncer, Services/Voice/VoiceActivityFeedback. Cover these via the audio integration suite, not unit tests. Services/ReadingPlayback/ReadingTTSCache is a trivial deprecated passthrough (skip).
- **Final phase (after logic >= 80%):** XCUITest for critical user flows (onboarding/consent gate, start a session, reading playback, a Knowledge Bowl round) so the UI layer has behavioral coverage without brittle View-body unit tests.

Each wave updates this doc's "Starting point" numbers as the ratchet climbs.
