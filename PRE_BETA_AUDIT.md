# UnaMentis iOS: Comprehensive Pre-Beta Audit

Date: 2026-05-30
Scope: the entire standalone `unamentis-ios` repository (367 Swift files), post monorepo extraction.
Status: internal working document (not for the public docs index).

## How this audit was run

This was a deep, multi-pass audit, not a skim:

1. The app was regenerated with XcodeGen and built for the iPhone 17 Pro simulator. Result: `** BUILD SUCCEEDED **`.
2. The enabled unit suite was executed (`test-ci.sh`, `TEST_TYPE=unit`). Result: tests pass, but coverage extraction reports 0.0 percent (the tooling is broken, see below).
3. The full compiler warning set from the real build was captured and categorized (168 unique warning locations).
4. A 70-agent analysis fanned out across six subsystem maps and seven audit dimensions (voice pipeline, code quality, security, documentation, tests, App Store readiness, architecture). Every critical, high, and medium finding was then re-derived by an independent skeptical verifier. 82 findings survived, 0 were refuted.

Counts after verification: 2 critical, 13 high, 27 medium, 35 low, 5 info.

## What the app actually is

UnaMentis iOS is a voice-first AI tutor built for extended (60 to 90 minute) hands-free spoken learning sessions, targeting sub-500ms turn latency. The user starts a session (by tap or by Siri) and has a natural, interruptible spoken conversation with an AI tutor, either freeform or guided by a curriculum. Around that core it layers: curriculum import and browsing (UMCF), a Knowledge Bowl competition-prep module, a reading-list TTS player, a to-do and learning-goals tracker, a flag-for-review system, session history with transcript export, an analytics and cost dashboard, provider configuration (cloud, self-hosted, on-device), a watchOS companion, and Siri App Intents.

The shipped tab layout is Learning (default) / Chat (the voice session) / Assistant (To-Do, Reading, Review) / History / More. It communicates with an optional self-hosted server over HTTP and has zero source dependency on server code.

The unified voice pipeline genuinely exists and is well built: `AudioEngine` (capture, playback, and the AVAudioSession owner), `AudioPlaybackOrchestrator` (segment, prefetch, and cache playback), the `STTService` / `TTSService` / `VADService` actor protocols, and `AudioEngineCache` (warm-engine pooling). The Reading List feature is the gold-standard reference: it consumes all of these correctly end to end. The many STT, TTS, and LLM provider backends are legitimate single-pipeline-many-backends design, not duplication.

## Bottom line

The app builds and the happy path works, but it is not ready for a TestFlight beta or an open-source release. There are two hard blockers, a cluster of high-priority correctness and quality issues concentrated in exactly the area you flagged (audio), and substantial repo hygiene debt that would embarrass a high-visibility open-source launch. None of it is fatal; most fixes are mechanical. The work is real but tractable.

---

## 1. The voice pipeline (your top concern): confirmed duplication

Your instinct was correct. There is a single, well-designed audio system, but new audio features repeatedly grew their own parallel pipeline instead of reusing it. The invariant is violated in at least eight runtime code paths. The provider set is fine; the duplication is exclusively in playback and capture bypasses.

The single most damaging pattern repeats across the app: a feature correctly resolves a TTS through the provider abstraction (`TTSProvider.resolveConfiguredService()`), then plays the result with a hand-rolled `AVAudioPlayer(data: chunk.audioData)` instead of routing through `AudioPlaybackOrchestrator` / `AudioEngine.playAudio`. For the documented DEFAULT on-device provider, Kyutai Pocket TTS, chunks are raw float32 PCM with no WAV or RIFF container ([KyutaiPocketTTSService.swift:34](UnaMentis/Services/TTS/KyutaiPocketTTSService.swift#L34)). `AVAudioPlayer(data:)` cannot infer a format from headerless PCM, so it throws and the audio is silently dropped.

Confirmed bypasses:

- **AUDIO-1 (high): Knowledge Bowl on-device TTS is a full parallel playback path.** [KBOnDeviceTTS.swift](UnaMentis/Services/KnowledgeBowl/KBOnDeviceTTS.swift) plays through a private `AVAudioPlayer` singleton, hand-rolls WAV headers, switches the AVAudioSession category mid-utterance ([:156](UnaMentis/Services/KnowledgeBowl/KBOnDeviceTTS.swift#L156) then [:305](UnaMentis/Services/KnowledgeBowl/KBOnDeviceTTS.swift#L305)), and writes a debug `kyutai_tts_output.wav` into the user-visible Documents directory on every utterance with cleanup deliberately disabled ([:313-344](UnaMentis/Services/KnowledgeBowl/KBOnDeviceTTS.swift#L313), comment "do NOT delete"). It is live in [KBOralSessionView.swift:681](UnaMentis/UI/KnowledgeBowl/KBOralSessionView.swift#L681), not the dead Modules tree.
- **AUDIO-2 (high): Knowledge Bowl on-device STT spins up its own capture stack.** [KBOnDeviceSTT.swift:111-176](UnaMentis/Services/KnowledgeBowl/KBOnDeviceSTT.swift#L111) creates its own `AVAudioEngine` plus `SFSpeechRecognizer` plus input tap, duplicating the existing `AppleSpeechSTTService`. The team's own harness already documents that it crashes in the Simulator ([KBAudioInjector.swift:89-91](UnaMentis/Testing/KBAudioTestHarness/KBAudioInjector.swift#L89)).
- **AUDIO-3 (high): barge-in spoken responses are silently dropped for the default provider.** [speakBargeInResponse](UnaMentis/UI/Session/SessionView.swift#L2917) uses `AVAudioPlayer(data:)` on raw-PCM Pocket TTS, so when a user interrupts the tutor to ask a question, the answer is never spoken. This breaks a flagship hands-free capability precisely during the most impressive interaction.
- **AUDIO-4 (high): Knowledge Bowl drill and rebound "read aloud" is broken the same way** ([KBDomainDrillView.swift:754](UnaMentis/UI/KnowledgeBowl/KBDomainDrillView.swift#L754), [KBReboundTrainingView.swift:929](UnaMentis/UI/KnowledgeBowl/KBReboundTrainingView.swift#L929)).
- **AUDIO-5 (medium): VoiceActivityFeedback announcements** play via `AVAudioPlayer(data:)` ([:279](UnaMentis/Services/Voice/VoiceActivityFeedback.swift#L279)); it falls back to Apple TTS on failure, so it degrades rather than going fully silent.
- **AUDIO-6 (low): lecture transition announcements in SessionView** use the same pattern.
- **AUDIO-7 (high): six conflicting AVAudioSession configurations.** `setCategory` is called from at least six independent sites with different category, mode, and option values (AudioEngine, SessionView, KBOnDeviceSTT, KBOnDeviceTTS, ChatterboxSettingsViewModel, VoiceCloningViews). AVAudioSession is process-global, so whichever runs last wins. Only `AudioEngine` installs interruption and route-change observers, so every bypass path loses resilience to phone calls and Bluetooth (dis)connects.
- **AUDIO-8 (medium): the SessionView direct-streaming path is a second full playback pipeline** ([playNextAudioSegment:3079](UnaMentis/UI/Session/SessionView.swift#L3079)) and runs a SECOND `AudioEngine` for barge-in VAD ([:2459](UnaMentis/UI/Session/SessionView.swift#L2459)) created directly instead of via `AudioEngineCache.shared`.

Recommended consolidation: make `AudioEngine` the sole owner of AVAudioSession, funnel all announcement, question, and barge-in audio through one shared `AudioPlaybackOrchestrator` fed by `AudioEngineCache`, and delete the KB STT/TTS bypasses in favor of the existing provider services. KBOnDeviceTTS and KBOnDeviceSTT should become thin adapters exactly like Reading List already is.

---

## 2. Critical blockers (must fix before any public step)

- **DOC-1 (critical): no LICENSE file.** [README.md:70](README.md#L70) links `[LICENSE](LICENSE)`, but no LICENSE exists anywhere in the repo. Without it the code is "all rights reserved" by default, which legally bars the advertised open-source distribution, GitHub shows "No license," and the README link 404s. Add a LICENSE matching the main repo before going public.
- **ASR-1 (critical): no privacy policy.** The app streams voice and transcripts to seven-plus third-party AI clouds (Deepgram, OpenAI, Anthropic, AssemblyAI, ElevenLabs, Groq, Brave). App Store Connect requires a Privacy Policy URL for every app, and external TestFlight beta requires one too. `APP_STORE_COMPLIANCE.md` itself marks it "Must create and host." This blocks the beta, not just the public launch.

---

## 3. High-priority issues

### Capability gaps (features that look wired but do not work)
- **ARCH-5 (high): the on-device LLM is dead in the real build.** `localMLX` is the SessionView default provider, but `LLAMA_AVAILABLE` is defined only in `Package.swift`, never in `project.yml`, and the App Store ships via XcodeGen plus xcodebuild. So every `#if LLAMA_AVAILABLE` call site compiles to the fallback, the marketed offline/private LLM never runs, and the 1.9GB gguf is bundled but unusable ([project.yml:62](project.yml#L62), [SessionView.swift:1574-1619](UnaMentis/UI/Session/SessionView.swift#L1574)). This is both a capability gap and a marketing-versus-reality integrity problem for a privacy-first pitch. Decide explicitly: integrate the xcframework and define the flag in project.yml, or change the default away from `localMLX` and drop the 1.9GB resource.
- The Review feature is a silent no-op (`ReinforcementManager.shared` is declared but never assigned; see TEST-8), web search always returns "not configured" (ARCH-7, the whole LLM tool-calling subsystem is dead), and the `openAIWhisper`, `groqWhisper`, and `playHT` provider cases are advertised in the UI but unwired.

### Test suite health (a fifth of the suite is dark)
- **TEST-1 (high): 17 of 86 test files (about 20 percent, roughly 453 tests, 6,888 lines) are excluded in `project.yml`,** and 15 of them target shipping code (Knowledge Bowl answer validation, question/match/rebound engines, regional config, n-gram and phonetic matchers, on-device KB STT/TTS, GLM-ASR STT). The disable reasons are real Swift 6 migration breakage, so re-enabling is mechanical but laborious.
- **TEST-2 (high): the Knowledge Bowl answer validator ships with about 74 tests disabled** (unit plus integration). This is the competition module's correctness core; a regression in fuzzy thresholds or normalization would silently produce unfair scoring. The fix is trivial (make the tests `async`), and asymmetric to the risk.
- **TEST-4 / TEST-5 (high): the core has zero meaningful coverage.** `SessionManager` (the 8-state turn loop, barge-in, start/stop) and the 3,482-line `SessionView` / `SessionViewModel` (direct-streaming pipeline, the real provider router, a second barge-in machine) have no tests. `SessionManagerTests` only checks init, enum values, and Codable.
- **TEST-6 (high): coverage is inverted.** The two DEAD routers (`PatchPanelService.resolveRouting`, `STTProviderRouter`) have about 42 tests, while the only session-persistence path (`persistSessionToStorage`) and the real provider switch have zero. Dead code is propping up false confidence.
- **TEST-8 (high): tests mask a shipping bug.** The Review tests manually set `ReinforcementManager.shared` to make the happy path pass, while another test codifies the production no-op as correct. The one-line production fix is to assign `.shared` at app init.

### Documentation governance
- **DOC-12 (high): no CONTRIBUTING, CODE_OF_CONDUCT, SECURITY.md, CHANGELOG, or hosted privacy policy in-repo** for a dual public release with a security-sensitive surface (API keys, mic audio, self-hosted networking). The README delegates two of these to the main repo, and one of those links is broken (DOC-2).

---

## 4. Build and test reality

- Build: succeeds.
- Unit tests: pass.
- **Coverage reporting is broken: it reports 0.0 percent** despite `-enableCodeCoverage YES`. The documented "80 percent enforcement" gate is non-functional. Fix the xcresult coverage extraction in `test-ci.sh` before trusting any coverage number.
- **168 unique compiler warnings** ship in the build. The actual bugs hiding among them:
  - **Cast that always fails** in three Curriculum files (`NSOrderedSet?` to `Set<Topic>`): [CurriculumDownloadManager.swift:296](UnaMentis/Services/Curriculum/CurriculumDownloadManager.swift#L296), [CurriculumService.swift:530](UnaMentis/Services/Curriculum/CurriculumService.swift#L530), [VisualAssetCache.swift:156](UnaMentis/Services/Curriculum/VisualAssetCache.swift#L156). These topic relationships never populate.
  - **Data races** in the core audio path: `sending` closure and value warnings in [AudioEngine.swift:610-623](UnaMentis/Core/Audio/AudioEngine.swift#L610) and [AppleTTSService.swift:109-134](UnaMentis/Services/TTS/AppleTTSService.swift#L109), plus a captured-var race in [SileroVADService.swift:220-224](UnaMentis/Services/VAD/SileroVADService.swift#L220).
  - **Dangling pointer**: [TelemetryEngine.swift:756](UnaMentis/Core/Telemetry/TelemetryEngine.swift#L756) initializes an `UnsafeMutablePointer<thread_act_t>` that results in a dangling pointer.
  - Non-Sendable `AVCaptureSession` captured in `@Sendable` closures in [QRCodeScannerView.swift](UnaMentis/UI/Settings/QRCodeScannerView.swift).
  - 108 `no 'async' operations occur within 'await'` warnings (churn smell), 16 unused values, deprecated `allowBluetooth` and `init(cString:)` usage.
- The project preaches a zero-tolerance "Tool Trust Doctrine," yet ships 168 warnings; `.swiftformat` is `--disable all` and `.swiftlint.yml` disables many rules. Lint enforcement is largely cosmetic today.

---

## 5. Security and privacy

Foundation is moderate-to-good: cloud API keys live in Keychain, no keys are ever written to UserDefaults, all cloud calls use HTTPS/WSS with keys in headers, there are no certificate-validation bypasses and no `NSAllowsArbitraryLoads`, no secrets are committed, and remote logging is correctly `#if DEBUG`-gated. Real gaps:

- **SEC-1 (data at rest): conversation transcripts persist to Core Data SQLite with no file-protection key and no data-protection entitlement.** Effectively unencrypted user content at rest.
- **SEC-2 (PII in logs): full user transcripts log at `.info` in release builds** ([SessionView.swift:2792, 2850](UnaMentis/UI/Session/SessionView.swift#L2792); [SessionManager.swift:808, 952](UnaMentis/Core/Session/SessionManager.swift#L808)). The release console handler ships `.info`. Demote to `.debug` or redact.
- **SEC-3 (plaintext telemetry): device name plus IDFV are uploaded over cleartext HTTP** to the metrics endpoint ([MetricsUploadService.swift:50, 69](UnaMentis/Core/Session/MetricsUploadService.swift#L50)). Use a random per-install UUID, drop the device name, and move to HTTPS.
- **SEC-4 (latent key read): `APIKeyManager.getKey()` falls back to reading keys from plaintext UserDefaults** ([:203](UnaMentis/Core/Config/APIKeyManager.swift#L203)). Nothing writes there today, so it is latent, but wrap it (and the env fallback) in `#if DEBUG`.
- **SEC-5 (supply chain): on-device model downloads are verified by file size only,** not checksum or signature ([OnDeviceLLMModelManager.swift:310](UnaMentis/Services/LLM/OnDeviceLLMModelManager.swift#L310)). Pin and verify a SHA256, fail closed.
- **SEC-6 (supply chain): SwiftReadability is pinned to `branch: main`** from a personal fork with no committed `Package.resolved` ([project.yml:43](project.yml#L43)). Pin a tag/revision and commit the resolved file for reproducible builds.

---

## 6. App Store readiness

Info.plist strings, entitlements, app icon, LaunchScreen, the main `PrivacyInfo.xcprivacy`, and the LiveKit SDK manifest are present and well-formed. Remaining gaps beyond ASR-1:

- **ASR-2 (medium): the privacy manifest is inaccurate.** It declares `SystemBootTime` (unused) and omits `DiskSpace` (used at [OnDeviceLLMSettingsView.swift:381](UnaMentis/UI/Settings/OnDeviceLLMSettingsView.swift#L381)). Apple's Privacy Report against the archive will flag the mismatch.
- **ASR-3 (medium): data collection is understated.** Device name plus IDFV over cleartext, third-party sharing undeclared, several types marked not Linked that should be reconsidered.
- **ASR-6 (medium): `NSSpeechRecognitionUsageDescription` says "voice commands"** while Apple Speech transcribes full conversations. Reword (fix the canonical source `project.yml:120`, since Info.plist is regenerated).
- **ASR-4 (low): `ITSAppUsesNonExemptEncryption` is not declared,** causing a manual export-compliance prompt on every TestFlight upload.
- **ASR-7 (medium): bundled trivia questions and reference artwork.** The questions are attributed per-item (public domain plus CC BY-SA 4.0), but a top-level content-licenses file is missing and several artwork JPGs lack recorded provenance.
- **ASR-5 (low): the Watch App target has no entitlements file and no privacy manifest.**
- The `validate-for-appstore.sh` and `appstore-validation.yml` scripts check file presence and plist lint but miss required-reason accuracy, the encryption declaration, third-party SDK manifests, watch-target completeness, and privacy-label consistency, so they can green-light a build App Review later rejects.

Bundle size: the app embeds roughly 1.9GB gguf plus roughly 229MB of PocketTTS models as resources. This vastly exceeds practical App Store and cellular limits and should move to on-demand download or be cut (and ties into ARCH-5).

---

## 7. Documentation and repo hygiene (post-split drift)

Structurally the shared-doc index resolves and scripts exist, but there is a cluster of accuracy gaps that would mislead a day-one contributor and undercut a high-visibility launch:

- **DOC-4 / DOC-5: contradictory environment docs.** Simulator name conflicts (root docs say iPhone 17 Pro, `UnaMentis/CLAUDE.md` and the mcp-setup skill say iPhone 16 Pro, CI prefers 16 Pro, `test-ci.sh` defaults to 17 Pro). README claims Xcode 15.2+ while the project needs an Xcode 26-class toolchain (watchOS 26 / iOS 18, machine runs Xcode 26.4).
- **DOC-3: README provider counts are all wrong** (STT, TTS, and LLM counts do not match the real provider set).
- **DOC-6 (medium): `unamentis-ios` is still a PRIVATE GitHub repo** while docs present `github.com/UnaMentis` links as public.
- **DOC-2, DOC-7, DOC-8: a broken CODE_OF_CONDUCT link, obsolete MCP tool names in AGENTS.md, and 8-plus broken intra-repo relative links** left over from the split.
- **DOC-13, DOC-14, DOC-15: the public docs index surfaces an internal review artifact, a personal scratch file (`docs/knowledgebowl/notes.md`), and a hardcoded developer-specific absolute path.**

---

## 8. Architecture and dead code

- **ARCH-1 (medium): delete the entire `UnaMentis/Modules/KnowledgeBowl` tree (10 files).** It is excluded from the build as "duplicates," but it is actually a divergent earlier design (two structurally different `KBQuestion` types). Only two test files reference it. It is a trap for contributors.
- **ARCH-2 (medium): the `ModuleProtocol` / `SpecializedModule` plugin facade is unused scaffolding;** `ModulesView` uses its own `BundledModule` struct and a hardcoded switch. Module metadata is modeled five-plus times.
- **ARCH-4, ARCH-6: false or stale build exclusions.** `SelfHostedSTTService` is excluded with a demonstrably false rationale (the duplicate types it claims do not exist), removing the self-hosted Whisper capability; `TestHooks.swift` is excluded for a genuine redeclaration.
- **ARCH-9 (medium): documented routing and plugin abstractions are aspirational** versus the flat UserDefaults switch that actually runs (duplicated across SessionView). Decide wire-or-delete for each.

---

## Recommended remediation plan

### Phase 0: unblock the beta (small, high-leverage)
1. Add a LICENSE file (DOC-1).
2. Write and host a privacy policy enumerating the third-party AI providers; add the URL to App Store Connect and link it in-app (ASR-1).
3. Declare `ITSAppUsesNonExemptEncryption` (ASR-4).
4. Fix the privacy manifest: drop `SystemBootTime`, add `DiskSpace` (ASR-2).
5. Fix the on-device LLM default: either define `LLAMA_AVAILABLE` in project.yml and integrate the xcframework, or change the SessionView default off `localMLX` and drop the 1.9GB resource (ARCH-5). This also addresses bundle size.

### Phase 1: the voice pipeline (your priority, and where the user-visible breakage is)
6. Route every TTS playback through `AudioPlaybackOrchestrator` / `AudioEngine.playAudio`: barge-in (AUDIO-3), KB drill/rebound (AUDIO-4), VoiceActivityFeedback (AUDIO-5), lecture transitions (AUDIO-6). This single change fixes the silent-audio bug on the default provider in four places.
7. Delete the KB on-device STT/TTS bypasses; use the existing provider services driven by the unified engine (AUDIO-1, AUDIO-2), and remove the Documents `.wav` write and emoji NSLog (CQ-1, CQ-4).
8. Make `AudioEngine` the sole AVAudioSession owner; remove the five other `setCategory` sites (AUDIO-7).
9. Fold the direct-streaming path into the orchestrator and source its engine from `AudioEngineCache` (AUDIO-8).

### Phase 2: correctness and confidence
10. Re-enable the disabled tests, starting with `KBAnswerValidator` (TEST-2), then the rest of the 15 shipping-code files (TEST-1).
11. Add tests for `SessionManager`, `persistSessionToStorage`, and the real provider switch (TEST-4, TEST-5, TEST-6).
12. Fix the coverage extraction so the 80 percent gate works (the 0.0 percent bug).
13. Fix the always-fails curriculum cast and the audio data-race / dangling-pointer warnings, then drive the 168 warnings toward zero and make lint enforcing.
14. Wire `ReinforcementManager.shared` at init so the Review feature works (TEST-8).

### Phase 3: hygiene and polish
15. Privacy and security: data-protection on the store (SEC-1), demote transcript logging (SEC-2), HTTPS plus random ID for telemetry (SEC-3), gate the UserDefaults key fallback (SEC-4), checksum model downloads (SEC-5), pin SwiftReadability and commit Package.resolved (SEC-6).
16. Delete dead code: the Modules tree (ARCH-1), the ModuleProtocol facade (ARCH-2), and decide wire-or-delete for the dead routers and web search (ARCH-7, ARCH-9).
17. Documentation: add CONTRIBUTING / CODE_OF_CONDUCT / SECURITY / CHANGELOG (DOC-12), fix provider counts and simulator/Xcode version drift (DOC-3, DOC-4, DOC-5), repair broken links, and clean the public docs index (DOC-13, DOC-14, DOC-15).
18. Replace the user-facing `voicelearn` / voicelearn.app branding (CQ-6), surface swallowed save errors (CQ-2, CQ-3), and either implement or disable the no-op Settings buttons (CQ-8).

## Appendix: finding index

82 findings, 0 refuted. IDs map to the dimension prefixes used above: AUDIO (14), CQ (10, code quality), SEC (10, security), DOC (15, documentation), TEST (14), ASR (10, App Store readiness), ARCH (9, architecture). Critical: DOC-1, ASR-1. High: AUDIO-1, AUDIO-2, AUDIO-3, AUDIO-4, AUDIO-7, ARCH-5, DOC-12, TEST-1, TEST-2, TEST-4, TEST-5, TEST-6, TEST-8.
