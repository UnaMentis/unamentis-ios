# Module Architecture Analysis and Roadmap Proposal

**Date:** 2026-07-07
**Scope:** Analysis only. No implementation was performed.
**Inputs:** iOS codebase deep-dive, Android codebase review, main-repo spec review (docs/modules, client-spec, api-spec), pre-split history review of the primary repo (legacy client, Watch App, and the April 2026 repo split), and European quiz/exam market research (web-verified July 2026).

---

## 1. Executive Summary

The modules area today is one shipped module (Knowledge Bowl) sitting on top of three divergent, partially realized architectures: the iOS implementation, the Android implementation, and an idealized architecture described in the main-repo docs that neither client actually implements. There is no official module spec, no SDK, and a third party cannot add a module on iOS without editing core app files. History review of the primary repo (where the client lived until the April 2026 split) shows the original design was actually richer: a real module manifest with watch and voice capability flags, a module event hub, and a shared UniversalVoicePipeline were all designed pre-split and then lost in the current, thinner iOS implementation. The proposals below largely restore that design and formalize it. The Watch App, which shipped Knowledge Bowl drill modes and survives fully in this repo, must be treated as a first-class module surface in the spec.

The single most important structural insight from this analysis: **the true plug-and-play unit should be the content pack, not the code module.** Most planned modules (Quiz Bowl, Science Bowl, IHBB Europe, national oral exams) are format variations over a small number of generic engines. If we build (a) a formal module contract with a host-services API and (b) two or three parameterized engines driven by declarative content packs, then "adding a module for a new competition or exam" becomes authoring a JSON pack plus localization, not writing Swift.

On Europe: there is currently zero Europe-facing content, and the codebase has concrete blockers (English-only localization, hardcoded Knowledge Bowl strings). But the market research found a striking opportunity. Several major European exams are literally oral exams (France's Grand Oral, Italy's Maturità colloquio, Poland's Matura orals, Ireland's Leaving Cert Irish oral at 40% of the grade). For those, a voice-first AI app is not "a way to study for the exam," it matches the exam's actual modality. No competitor does long-form, curriculum-grounded, hands-free oral exam rehearsal on mobile. This should be the European flagship.

Recommended next modules, in order:

1. **Quiz Bowl engine shipped with IHBB Europe and UK Schools' Challenge content packs.** One build, two markets. This makes the first additional module simultaneously the first European module.
2. **Oral Exam Studio (AI examiner engine), France Grand Oral first.** The Europe flagship, 100% voice, and structurally different from quiz competitions.
3. **Aural Skills Trainer (ABRSM-style ear training).** The "very different" range-shower, 100% audio by nature, European-anchored.
4. **SAT Prep** (spec already complete) as the US revenue anchor, explicitly embracing partial voice coverage.

In parallel, build the **learner-model and mentorship layer** (honcho-rework-powered) as a core platform service with a Tutoring module UX on top, not as a pure module.

---

## 2. Current State: Three Architectures, One Module

### 2.1 iOS (this repo)

What exists:

- `UnaMentis/Core/Modules/ModuleProtocol.swift`: a protocol with static metadata (id, name, descriptions, icon, theme color), three quiz-specific capability booleans (`supportsTeamMode`, `supportsSpeedTraining`, `supportsCompetitionSim`), and two `@MainActor` view factories (`makeRootView()`, `makeDashboardView()`), plus a type-erased `SpecializedModule` wrapper.
- `UnaMentis/Core/Modules/ModuleService.swift`: server discovery and download (`GET /api/modules`, download of full question content as `DownloadedModule`).
- `UnaMentis/Core/Modules/ModuleRegistry.swift`: a UserDefaults-backed cache of downloaded module metadata. It is a registry of downloads, not of runnable module implementations.
- `UnaMentis/UI/Learning/ModulesView.swift`: the modules gallery (Installed / Downloaded / Available on Server sections) and the launcher.
- Knowledge Bowl itself: roughly 30 files across `UnaMentis/Modules/KnowledgeBowl/`, `UnaMentis/UI/KnowledgeBowl/`, and `Shared/KnowledgeBowl/`, with bundled questions in `Resources/kb-sample-questions.json`, optional server sync, server TTS audio cache, and its own stats persistence.

What is actually coupled:

1. **Module launch is a hardcoded switch on module ID** in `ModulesView.swift` (`moduleViewForId(_:)`, around line 108). The default case shows "Module Not Found."
2. **The bundled module list is a static array** (`BundledModule.all`, around line 33) that duplicates the metadata `KnowledgeBowlModule` already declares. `ModuleProtocol` and `SpecializedModule` are effectively decorative; nothing iterates registered implementations.
3. **Knowledge Bowl runs its own voice stack.** `KBVoiceCoordinator` (482 lines) instantiates its own STT service, TTS service, VAD, and a dedicated `AudioEngine`, and implements its own 1.5-second silence-based utterance completion. This is a second, parallel voice pipeline and directly conflicts with the project's unified voice-pipeline mandate. It also bypasses the single `BargeInDetector` work.
4. **KB creates its own `TelemetryEngine()` instance**, so module analytics are invisible to app-level analytics.
5. **Duplicate type locations.** KB models/views/services exist in more than one directory, with `project.yml` (lines 72-77) excluding subfolders to avoid build conflicts. This is unresolved structural debt.
6. **Localization is a Europe blocker.** Only `en.lproj` exists, and KB has hardcoded UI strings (tracked in the main repo at `docs/tasks/KB_LOCALIZATION_ISSUES.md`).

Verdict: a third party cannot add a module today without editing at minimum `ModulesView.swift` (twice) and possibly `project.yml`. The design assumed one embedded module plus future server-delivered content, and it shows.

### 2.2 Android (unamentis-android)

Android is meaningfully ahead architecturally:

- `core/module/ModuleProtocol.kt` defines a real lifecycle (`initialize/start/pause/resume/stop`) plus UI entry points (`getUIEntryPoint()`, `getConfigurationScreen()`, `getDashboardWidget()`).
- `core/module/ModuleRegistry.kt` manages both downloaded module metadata (Room-persisted) and runtime implementations.
- Modules register via Hilt multibinding (`@IntoSet`) collected at app startup, so adding a module means adding a DI module, not editing a switch statement.
- A SAT Prep placeholder ("Coming Soon" card) already exists in `ModulesSection.kt`.

Remaining Android gaps: the navigation enum (`TrainingModule`) is still hand-listed, capability flags are the same quiz-specific booleans, and there is no shared schema tooling with iOS (manual model parity).

### 2.3 Server (unamentis)

- `server/management/modules_api.py`: module registry (registry.json), `GET /api/modules`, `GET /api/modules/{id}`, `POST /api/modules/{id}/download`, feature-flag overrides.
- Full KB pack/question CRUD (`kb_packs_api.py`, migration `003_kb_questions_tables.sql`), bundling with dedup, import plugins, and a global TTS audio cache for pre-generated question audio.
- WebSocket team coordination is designed (KB Phase 3) but not fully deployed.

### 2.4 The paper architecture (docs/modules)

The main repo contains roughly 20,000 lines of module documentation, including four full module specs (Knowledge Bowl v1.3 implemented; Quiz Bowl v1.0 and Science Bowl v1.0 in planning; SAT v1.0.0 spec complete) and three architecture docs that matter here:

- `MASTER_TECHNICAL_IMPLEMENTATION.md`: all modules share core primitives: QuestionEngine (filtering/pagination), Transformer (canonical question to format-specific form), SessionManager (state machine), AnalyticsService.
- `ACADEMIC_COMPETITION_MODULAR_ARCHITECTURE.md`: a `ModuleManifest` schema with capabilities, optional cross-module dependencies, and question-pack versioning.
- `UNIFIED_PROFICIENCY_SYSTEM.md`: one cross-module learner proficiency model (domain mastery 0-100%) so performance in one module informs difficulty in another.

There is also a `CanonicalQuestion` model with `compatibleFormats` and `transformationHints`, designed so one physics question can render as a KB short-form oral question, a QB pyramidal tossup, or an SB multiple-choice with W/X/Y/Z labels.

**None of this is implemented on iOS.** The docs describe the right architecture; the clients each grew their own partial version. The task ahead is less invention than reconciliation: promote the paper architecture to an official versioned spec and make both clients conform.

### 2.5 Pre-split lineage: the original design was richer than what iOS runs today

The iOS client (including the Watch App) lived inside the primary repo until the split on 2026-04-12 (commit `fae45ed8` in unamentis, with 234 commits of iOS history preserved in unamentis-ios via git filter-repo). Reviewing that history shows the current iOS module system is a *simplification* of the original design, not the original design:

- The module system introduced on 2026-01-13 (commit `edb92a37`) defined a `CompetitionModule` protocol with a real **`ModuleManifest`** carrying capability flags including `supportsWatchOS`, `providesQuestions`, and `supportsVoiceInterface`, plus a **module event system** (questionCompleted, sessionCompleted, proficiencyUpdated) and a **`ModuleCommunicationHub`** for inter-module events.
- The docs from that era specify a **`UniversalVoicePipeline`**: shared STT/TTS with buzz detection and conference timing, configured per module via a `VoicePipelineConfig` (buzzMode, answerTimeout, allowInterruption, conferenceTime).

In other words, the manifest, host-provided voice pipeline, and event-driven registration proposed in section 3 are not new ideas; they restore and formalize what was already designed pre-split and then lost in the current, thinner `ModuleProtocol`. The KB spec's watchOS section (§8) and Phase 3 status also confirm the watch was a first-class module surface from the start.

The split itself was clean. Server-side module code and all module docs stayed in the primary repo; client code moved. The one loss worth noting: `docs/watch-testing/` (WATCH_APP_TESTING.md plus 17 screenshots) was deleted in the split commit and does not exist in either working tree today; it is recoverable via `git show fae45ed8^:docs/watch-testing/...` in the primary repo and should be restored into unamentis-ios docs.

### 2.6 The Watch App is an existing module surface

The Watch App is live in this repo (`UnaMentis Watch App/`) and already ships Knowledge Bowl watch experiences: `KBWatchMainView` (training menu), `KBWatchQuickSessionView` (10/25-question quick sessions), `KBWatchDomainDrillView`, and `KBWatchFlashCardsView`, on top of a WatchConnectivity bridge (`Shared/WatchModels/WatchSessionState.swift`, `SessionCommand.swift`) and `ExtendedRuntimeManager` for long sessions. Phase 1 (control plane: session state, mute/pause/stop) is implemented; Phase 2 (direct voice capture on the watch, standalone sessions) is designed in `docs/explorations/WATCH_APP_EXPLORATION.md` (primary repo, 765 lines) but not implemented.

Architecturally this matters in two ways:

1. **The KB watch views are wired the same hardcoded way as the phone views.** Any module contract that ignores the watch will immediately be violated by the one module we have.
2. **The watch is a strong strategic fit for several roadmap modules** (drill-style content especially: flash cards, aural skills intervals, vocabulary), and Phase 2 standalone voice would make the watch a legitimate hands-free-first device on its own.

Consequence for the spec (folded into section 3.2): the manifest regains the original `supportsWatchOS`-style capability, and the module contract includes an optional watch entry point (`makeWatchRootView()` or a watch scene registration) plus a declared subset of content interactions suitable for watch-optimized delivery.

### 2.7 Gap summary

| Dimension | Docs/spec | Server | Android | iOS |
|---|---|---|---|---|
| Module manifest | Specified | registry.json (partial) | Metadata in code | Metadata in code, duplicated |
| Runtime registration | Implied | N/A | DI multibinding (good) | Hardcoded switch (bad) |
| Lifecycle contract | Implied | N/A | Yes | No (view factories only) |
| Voice integration contract | Hands-free spec exists | TTS cache only | KB-local voice code | KB-local voice code (pipeline violation) |
| Canonical content + transformers | Fully specified | KB-only tables | KB-only models | KB-only models |
| Cross-module proficiency | Fully specified | No | No | No |
| Offline-first core | Specified and honored | Supports it | Yes | Yes |
| Watch surface | Specified (KB spec §8, exploration doc) | N/A | No | Shipped (KB drills), but hardcoded like the phone |
| Third party could add a module | Goal | N/A | Nearly (enum edit) | No |

---

## 3. Proposed Official Module Architecture

### 3.1 Principles (proposed as normative)

1. **On-device first, server optional.** Every module must be fully functional with no server. Server adds enrichment (content packs, TTS cache) and multi-user value (team sync, coach dashboards), never core function. Formalize as capability tiers:
   - Tier 0 (mandatory): complete offline single-user experience with bundled or downloaded content.
   - Tier 1 (optional): server content and service enrichment (packs, pre-generated audio, updated syllabi).
   - Tier 2 (optional): multi-user features (team coordination, coach/mentor dashboards, leaderboards).
2. **One voice pipeline.** Modules never own audio. They consume a host-provided voice session API (TTS, STT, VAD, barge-in, command grammar). This closes the KBVoiceCoordinator violation and means every module inherits barge-in, latency, and echo-rejection improvements for free.
3. **Hands-free first is a conformance requirement, not a suggestion.** The existing HANDS_FREE_FIRST_DESIGN mandates (unified command vocabulary, state-valid command filtering, milestone audio, accessibility parity) become a testable checklist in the SDK.
4. **Content packs are the primary extension unit.** Code modules should be engines; formats, regions, syllabi, and languages should be data.
5. **Spec first, two consumers.** The module spec is a platform-neutral document (JSON schemas for manifest and content) implemented by both iOS and Android. Android's registry/lifecycle design is the closer starting point.
6. **Declared voice coverage.** Every module manifest declares its expected voice-coverage share, and telemetry measures the real one (see section 6).

### 3.2 The contract: what a module provides

A versioned `ModuleManifest` (JSON, shared schema across platforms and server registry):

```json
{
  "specVersion": "1.0",
  "id": "com.unamentis.quizbowl",
  "name": "Quiz Bowl",
  "version": "1.0.0",
  "engine": "quiz-match",
  "capabilities": ["team-mode", "speed-training", "competition-sim", "oral-practice", "watch-drills"],
  "voiceCoverage": {"declared": 0.95},
  "serverTiers": [0, 1, 2],
  "surfaces": ["phone", "watch"],
  "locales": ["en-US", "en-GB"],
  "contentPacks": {"bundled": ["qb-starter-naqt"], "compatible": ["canonical-question/v1"]},
  "minPlatform": {"ios": "17.0", "android": "26"}
}
```

Notes: `capabilities` becomes an open string set (the current three booleans are quiz-specific and will not survive contact with SAT, oral exams, or tutoring). `engine` names which generic engine renders this module, or `custom` for fully bespoke modules.

Code-side, the module implements a lifecycle plus entry points (aligning iOS to Android's shape):

- `initialize(host: ModuleHost)`, `start/pause/resume/stop`
- `makeRootView()`, `makeDashboardWidget()`, `makeSettingsPane()`
- `makeWatchRootView()` (optional, present when the manifest declares the watch surface), plus a declaration of which of the module's interactions are watch-suitable so the host can route quick drills and session control appropriately
- `commandVocabulary(for state:)`: state-scoped voice commands registered with the host, extending the unified vocabulary rather than reimplementing recognition.

This restores the shape of the original pre-split `ModuleManifest` (which already had `supportsWatchOS`, `providesQuestions`, and `supportsVoiceInterface` flags and a module event system) rather than inventing a new one; see section 2.5.

### 3.3 The handoff: what the host provides (ModuleHost API)

This is the clear hand-off API the project currently lacks. One protocol bundle, injected at initialize:

| Service | Provides | Replaces today |
|---|---|---|
| `VoiceSession` | speak(text/ssml, prefetchable), listen-for-utterance with completion semantics, barge-in events, command recognition against registered vocabulary, audio ducking, per-module config (buzz mode, answer timeout, conference timing) | KBVoiceCoordinator's private STT/TTS/VAD/AudioEngine. This is the documented pre-split `UniversalVoicePipeline` + `VoicePipelineConfig` design, realized on today's unified pipeline |
| `ContentStore` | load bundled packs, query/download server packs, canonical-question queries with format transformation | KBQuestionService ad-hoc loading |
| `ProgressStore` | per-module namespaced persistence plus writes into the unified proficiency model (domain mastery) | KBStatsManager silo |
| `Telemetry` | app-global telemetry with module dimension | KB-local TelemetryEngine() |
| `Flags` | feature flags | direct FeatureFlagService calls |
| `LearnerModel` (later) | honcho-rework-backed understanding of the learner (velocity, misconceptions, confidence calibration) | nothing today |

Registration on iOS: replace the switch and static array with a single registration point (a `ModuleCatalog` array of `SpecializedModule` values, or a build-plugin-generated registry). iOS cannot load third-party executable code at runtime (App Store rules), so honesty matters in the spec: **on iOS, "plug-in" for code means source-level SPM packages compiled in with one-line registration; runtime plug-in-play is reserved for content packs.** That is the correct split anyway.

### 3.4 Generic engines over content packs

Analysis of the four existing specs shows they decompose cleanly:

- **QuizMatchEngine**: tossup/bonus flow, buzz semantics (team buzz, individual buzz, recognition-required), scoring rules (including negs and powers), conferring timers, opponent simulation, answer validation tiers. Knowledge Bowl, Quiz Bowl, Science Bowl, IHBB Europe, and UK Schools' Challenge are all *parameterizations* of this engine. A `FormatDescriptor` in the content pack captures the deltas (KB: team buzz, no negs, written round; QB: pyramidal, -5 negs, powers, 3-part bonuses; SB: recognition procedure, W/X/Y/Z MC, 4-part bonuses; Schools' Challenge: starter plus themed bonuses, lightning round).
- **OralExamEngine** (new): timed prepared-speech plus adaptive follow-up questioning against a rubric, examiner persona, structured feedback. Powers Grand Oral, Maturità colloquio, Matura orals, Leaving Cert orals, IB Individual Oral, Abitur mündliche Prüfung, language-cert speaking papers, and later interview prep.
- **DrillEngine**: spaced-repetition recall drills over any canonical-question pack (domain drills, speed drills, formula flashcards, vocabulary).
- SAT remains closer to a bespoke module (adaptive MST simulation, strategy coach) built on `DrillEngine` plus custom pieces.

With this split, "Science Bowl module" stops being a six-week build and becomes a format descriptor plus content packs plus a themed skin. The same applies to every European quiz competition.

### 3.5 SDK deliverables

1. **`UnaMentisModuleKit`** (SPM package; Kotlin twin on Android): `ModuleProtocol` v2, `ModuleHost` protocols, manifest and content-pack Codable models, the unified command-vocabulary types.
2. **Mock host + test harness**: run a module against a scripted voice session (extend the existing barge-in injection harness) so module tests never need a device or real audio.
3. **Template module** (`modules-template` example): a minimal working module demonstrating lifecycle, voice session use, content pack loading, and conformance tests.
4. **Conformance checklist, enforced by harness tests where possible**: Tier 0 offline completeness, hands-free command compliance, latency budgets, VoiceOver/Dynamic Type, localization (no hardcoded strings), declared vs measured voice coverage.
5. **The spec document**: `docs/modules/MODULE_SDK_SPEC.md` in the main repo, versioned, with the JSON schemas as the source of truth for all three codebases.

### 3.6 Migration path (ordered, incremental)

1. Extract `VoiceSession` from the existing unified pipeline; port KBVoiceCoordinator onto it (this is also the outstanding unified-pipeline debt).
2. Introduce `ModuleCatalog` registration; delete the switch and the duplicated `BundledModule.all` metadata.
3. Consolidate KB file layout (resolve the project.yml exclusions) and route KB telemetry/stats through host services.
4. Lift KB's match logic into QuizMatchEngine with KB as its first FormatDescriptor; build Quiz Bowl as the second consumer (which proves the engine).
5. Publish spec v1 and align Android (which needs the smaller jump).

---

## 4. Module Roadmap: Proposals

### 4.1 European market findings (July 2026, web-verified)

Quiz competitions with real structural analogs to Knowledge Bowl:

- **IHBB Europe** (International History Bee and Bowl plus Geography/Science Bees and Academic Bowl): pan-European, buzzer-based pyramidal tossups, team and coach structure, regional qualifiers feeding a European Championship (Berlin, May 2026), and publicly available past question sets. Essentially US quiz bowl exported to Europe, in English. Near-perfect reuse of our engine.
- **UK Schools' Challenge**: the national schools general-knowledge competition modeled on University Challenge, senior/intermediate/junior tiers, coach-led teams, starter-plus-bonus format.
- **Nordic broadcast quizzes** (Norway's Klassequizen, ~640 school teams; Sweden's Vi i femman since 1963): culturally beloved, better as training-hook content packs than partnerships.
- Mass-participation subject contests (Germany's Diercke Wissen with 310k+ participants, The Big Challenge English contest, Math Kangaroo) are content-pack candidates for DrillEngine.

Exams where the oral component makes voice the native modality:

| Rank | Exam | Why |
|---|---|---|
| 1 | **France: Grand Oral + oral de français** | The exam is a 20-minute jury presentation with follow-up questioning; ~540k candidates/year; single national syllabus; format confirmed stable through 2026; existing competitors (VocaCoach, Jury AI, Thotis IA) are thin single-moment web tools |
| 2 | **Italy: Maturità colloquio** | Hour-long dreaded multidisciplinary oral, ~500k candidates/year, essentially zero dedicated digital competition in Italian |
| 3 | **Language-cert speaking papers** (IELTS, Cambridge B2/C1, TOEFL, DELF/DALF, DELE, Goethe) | Largest paid prep market in Europe; TOEFL speaking is already performed into a microphone; crowded space (Speak at $1B valuation, ELSA, Praktika) but nobody does exam-format-faithful long sessions |
| 4 | **Poland: Matura orals** | Two compulsory orals; the official CKE question pool for the Polish oral is public, so content is nearly free; ~250-300k candidates/year; no meaningful competition |
| 5 | **Ireland: Leaving Cert orals** | Irish oral is 40% of the Higher Level grade with an acute practice-partner shortage; English-language market, state past papers free; small (~60k/year) but exceptional wedge economics |

Also strong: German Abitur oral (fragmented across 16 Länder), IB Individual Orals (small, affluent, uniform, pan-European; excellent early-adopter niche), Denmark's largely oral STX exams, UK GCSE/A-level language speaking exams.

Regulatory headlines for a minors-focused ed app in the EU: GDPR digital-consent age varies by country (13-16), voice recordings of minors are personal data (plan data minimization and per-country parental consent); the EU AI Act's Annex III high-risk education obligations were postponed to December 2027 by the May 2026 omnibus agreement, but Article 50 transparency (users must know they are talking to an AI) applies from August 2026. A self-study practice app that does not produce grades schools rely on arguably stays outside the high-risk bucket; marketing language should be careful here.

### 4.2 Recommended sequence for the next modules

**Module A (next): Quiz Bowl engine + European launch packs.**
Build the already-specced Quiz Bowl module, but build it as QuizMatchEngine + FormatDescriptors, and ship it with IHBB Europe and UK Schools' Challenge packs alongside NAQT/ACF. This satisfies "the first additional module should feed the European audience" without abandoning the existing Quiz Bowl spec investment; they are the same build. IHBB's public question archives and English-language format make this the cheapest credible European beachhead, with the Berlin European Championship as a natural community moment. Science Bowl then follows nearly free as a third FormatDescriptor whenever desired.

**Module B: Oral Exam Studio, France Grand Oral first.**
The European flagship and the strategic bet. One OralExamEngine (timed oral simulation, adaptive jury questioning, rubric feedback, examiner personas) localized per market: Grand Oral, then Maturità colloquio, Polish Matura, Leaving Cert Irish oral, IB Individual Oral. It is 100% voice, matches the exam's real modality, has no serious mobile competitor, and three to five markets share one engine. It also serves the "not just another quiz thing" requirement in substance, though it is still exam-shaped.

**Module C: Aural Skills Trainer (the range-shower).**
Ear training for music students: interval, chord, and cadence recognition, rhythm echo, melodic dictation, sight-singing assessment. This is the rare domain that is *inherently* 100% audio; the phone stays in the pocket by nature. It has a European institutional anchor: ABRSM and Trinity graded music exams (UK-based, taken worldwide) include a compulsory examiner-administered aural test at every grade, and dedicated prep is thin. It demonstrates that modules are not synonymous with quizzes, exercises the audio pipeline in genuinely new ways (pitch and rhythm analysis, tone generation), and reuses OralExamEngine's examiner pattern.

**Module D: SAT Prep.**
Spec is complete; US revenue anchor; Android already stubs it. Ship it with declared partial voice coverage (see section 6) rather than waiting for a 100%-voice story. A "voice-first study layer" (drills, strategy talk-throughs, error-analysis conversations, mental-math pacing) covering 30-40% of prep is worth shipping on its own, per external feedback already received.

**Platform track (parallel, not a module slot): Tutoring and Mentorship.**
Analysis below.

### 4.3 Tutoring/mentorship: core capability with a module face

The tutoring idea (a person formally taking on one or more students, face-to-face and remote, with AI-supported guidance) should not be built as a pure module, for three reasons:

1. Its heart is a **rich learner model** (knowledge state, learning velocity, misconceptions, confidence calibration). That model is exactly what the honcho-rework project provides, and every module benefits from it (KB difficulty selection, SAT psychology trainer, oral-exam feedback). It belongs in the core as the `LearnerModel` host service.
2. It is a **relationship and permission layer** (mentor/student links, progress sharing, session co-presence), which is account-level, cross-module infrastructure, and the natural Tier 2 server story (the same coach/team server value already planned for KB Phase 3).
3. Privacy and minor-protection constraints (deferred per direction, but decisive architecturally) attach to the platform layer, not to one module.

The recommended shape: core platform provides LearnerModel + Relationships; a **Mentorship module** provides the experience: a mentor dashboard ("Maria is stalling on stoichiometry; here is a 10-minute voice drill to run with her"), guided co-session mode for face-to-face tutoring (the AI as the tutor's instrument, not replacement), remote assignment and review, and AI-briefed handoffs between sessions. Every other module gains a "share with my mentor" affordance. This is also a genuine differentiator: nobody's learning app treats the human mentor as a first-class user of the AI.

### 4.4 Other out-of-the-box candidates evaluated (kept on the bench)

- **Reading fluency coach** (child reads aloud, app listens, measures fluency, coaches): inverts the interaction direction (app as listener), strong European primary-school fit, strong accessibility story. Bench only because early-reader STT and child-voice handling is a hard new capability.
- **Debate and rhetoric trainer** (rebuttal drills, extemporaneous speaking; European Youth Parliament, national debating leagues): excellent voice fit; overlaps heavily with OralExamEngine, so it is a future FormatDescriptor rather than a separate build.
- **Interview Studio** (Oxbridge admissions interviews, job interviews): same engine again; Oxbridge interview prep is a lucrative, voice-perfect UK niche.
- **Everyday certifications** (driving theory, Life in the UK test, Einbürgerungstest): huge adult European volumes, pure DrillEngine content packs; good later for demographic widening, but off-strategy for the school-age core right now.
- **Language speaking certifications** as a full module: biggest TAM but the most crowded, best-funded competitor set; enter later from a position of strength once OralExamEngine is proven on national exams.

---

## 5. Europe Readiness Prerequisites

These block or precede any European module and should be scheduled with Module A:

1. **Localization infrastructure**: adopt String Catalogs, fix KB's hardcoded strings (already filed in the main repo), and make locale a first-class dimension of content packs (a pack declares its locale; the app can hold packs in several languages).
2. **Multilingual voice stack audit**: Apple Speech STT covers fr/it/de/pl/es well; Pocket TTS language coverage beyond English must be verified before committing to Grand Oral (fallback: Apple TTS per locale, or server TTS cache with a multilingual voice). This needs a short spike with a written report.
3. **Consent and transparency**: per-country GDPR consent ages, parental-consent flow, and an "you are talking to an AI" disclosure to satisfy AI Act Article 50 from August 2026. Keep marketing clear of "grading/assessment relied on by schools" to stay outside Annex III high-risk.
4. **Content pipeline for non-US sources**: IHBB archives and the public Polish CKE oral question pool are the two lowest-cost imports; build importer plugins in the existing server importer framework.

---

## 6. Voice-Coverage Doctrine

The open question ("must a module be 50%+ voice?") should be resolved by declaration and measurement, not a hard floor:

1. **Declare.** Every manifest carries `voiceCoverage.declared` (KB ~0.65, Quiz Bowl ~0.95, Science Bowl ~1.0, Oral Exam Studio ~1.0, Aural Skills ~1.0, SAT ~0.35). The module gallery can surface this honestly ("Fully hands-free" / "Voice-first" / "Voice-assisted").
2. **Measure.** Telemetry computes the real share: fraction of session time and of state transitions completed by voice alone. Store the target in a measurable goal file (the same pattern as `.claude/goals/barge-in.json`) so drift is visible.
3. **Floor for the core loop, not the module.** The rule that matters is the existing hands-free mandate: any *activity* a module labels voice-first must be 100% completable by voice. Around that, partial-coverage modules like SAT are explicitly acceptable; external feedback already validates that 30-40% of SAT prep by voice is worth shipping. The doctrine is honesty plus a maximized voice-first core, not a percentage gate.

---

## 7. Consolidated Recommendations

Architecture (do first):

1. Write and adopt `MODULE_SDK_SPEC.md` v1 in the main repo: manifest schema, ModuleHost API, content-pack schema, conformance checklist. Reconcile with Android's ModuleProtocol (the closest existing implementation), the paper architecture docs, and the pre-split `ModuleManifest`/`UniversalVoicePipeline` design (section 2.5), which already anticipated most of this. **Update 2026-07-07: a full draft now exists at `unamentis/docs/modules/MODULE_SDK_SPEC.md` (v0.1.0-draft), substantially extending section 3 of this report: ResponseEvaluation as a host service, SessionRegistration (watch control plane and session logs for module sessions), Scheduler, EventHub, capability negotiation and an RFC-lite evolution process, content-pack licensing/integrity/import, conformance certification levels, and a seven-phase migration plan with exit criteria.**
2. Build `VoiceSession` on the unified pipeline and migrate KBVoiceCoordinator onto it, retiring KB's private AudioEngine/VAD/silence detection.
3. Replace the ModulesView switch and static array with catalog registration; route KB telemetry and stats through host services; resolve the duplicate-directory/project.yml debt. Include the watch: KB's watch views should launch through the same catalog, and the spec should carry the watch surface and capability from day one.
4. Extract QuizMatchEngine from KB with KB as FormatDescriptor #1; publish UnaMentisModuleKit with the mock-host test harness and a template module.
5. Recover `docs/watch-testing/` (WATCH_APP_TESTING.md and screenshots) from the split commit's parent in the primary repo (`git show fae45ed8^:docs/watch-testing/...`) and restore it into this repo's docs; it currently exists in neither working tree.

Roadmap (in order): Quiz Bowl + IHBB Europe/UK Schools' Challenge packs; Oral Exam Studio (Grand Oral first, then Maturità, Matura, Leaving Cert, IB); Aural Skills Trainer; SAT Prep with declared partial coverage. Platform track in parallel: LearnerModel (honcho rework) + Relationships in core, Mentorship module on top.

Europe prerequisites: localization infra and KB string fixes; multilingual TTS/STT spike (Pocket TTS coverage is the open question); GDPR/AI-Act consent and disclosure flows; IHBB and CKE content importers.

Doctrine: content packs are the plug-and-play unit; code modules are compiled-in SPM packages; every module offline-complete at Tier 0; voice coverage declared and measured, with a hard hands-free guarantee on voice-first activities rather than a module-level percentage floor.
