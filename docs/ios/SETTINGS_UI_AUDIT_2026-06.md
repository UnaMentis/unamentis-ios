# Settings & Configuration UI Audit + Reorganization Proposal (2026-06-06)

A full audit of the iOS app's settings and configuration UI, with a concrete reorganization
proposal. The goal is a healthy, non-duplicated, well-organized settings surface that keeps
every "nerd knob" we use to test, tweak, and experiment, while giving real users a clean
top-level experience. Findings were verified directly against the source on 2026-06-06.

Decisions already made by the project owner for this proposal:

1. The API key / API providers section must move off the top of Settings into a separate area.
2. Relocated developer knobs live in a **Developer** section that is **tap-to-reveal in all builds**
   (visible on a beta device, but collapsed/hidden until deliberately revealed).
3. This document is the agreed deliverable. Implementation is phased and starts only after review.

---

## 1. Current navigation map

```
TabView
├── Learning
├── Chat ─────────► SessionView ──(gear)──► VoiceSettingsView (sheet, in-session)
├── Assistant
├── History
└── More (NavigationStack)
     ├── Analytics ──► AnalyticsView
     └── Settings ───► SettingsView  (declares its OWN NavigationStack → nested)
                         ├── API Providers            ◄── to be moved out
                         │     ├── per-provider → APIProviderDetailView → APIKeyEditSheet
                         │     └── Session Cost Estimates → SessionCostOverviewView
                         ├── Voice ──► VoiceSettingsView
                         │              ├── Chatterbox Settings → ChatterboxSettingsView
                         │              └── Playback Tuning → TTSPlaybackTuningView
                         ├── Accessibility (1 toggle)
                         ├── On-Device AI ──► OnDeviceLLMSettingsView
                         ├── Self-Hosted Server (inline toggle / IP / status / refresh)
                         │     └── Advanced Server Config → ServerSettingsView → QR / Discovery / Manual
                         ├── Debug & Testing
                         │     ├── Subsystem Diagnostics → DiagnosticsView
                         │     ├── Device Health Monitor → DeviceMetricsView
                         │     ├── Audio Pipeline Test → AudioTestView        (FAKE)
                         │     ├── Provider Connectivity → ProviderTestView   (FAKE)
                         │     ├── TTS Playback Tuning → TTSPlaybackTuningView (also under Voice)
                         │     ├── Conversation Test → DebugConversationTestView (#if DEBUG)
                         │     ├── Debug Mode / Verbose Logging / Remote Logging toggles
                         │     └── Load / Delete Sample Curriculum
                         ├── Help (3 entries)
                         └── About
```

Settings is two taps deep under "More," and the first thing presented is a wall of API key rows.

---

## 2. Inventory

16 settings/config files, roughly 7,100 lines. The two hubs dominate:

| File | Lines | Notes |
|---|---|---|
| `UI/Settings/SettingsView.swift` | 2,221 | Holds 6 screens + 4 view models (Settings, Diagnostics, AudioTest, ProviderTest, TTSPlaybackTuning, SettingsHelpSheet). |
| `UI/Settings/VoiceSettingsView.swift` | 761 | The consolidated voice panel. Also the in-session settings sheet. |
| `UI/Settings/ServerSettingsView.swift` | 730 | Self-hosted server discovery, QR, multi-server, health. |
| `UI/Settings/APIProviderDetailView.swift` | 661 | Per-provider detail, pricing, key entry. Holds `SessionCostOverviewView`. |
| `UI/Settings/KyutaiPocketSettingsView.swift` | 623 | Pocket TTS on-device model + knobs. |
| `UI/Settings/HelpView.swift` | 594 | In-app help. Holds `VoiceCommandsHelpView`. |
| `UI/Settings/ChatterboxSettingsView.swift` | 473 | Chatterbox TTS knobs. |
| `UI/Settings/OnDeviceLLMSettingsView.swift` | 468 | On-device LLM download/manage. |
| `UI/Settings/DiscoveryProgressView.swift` | 439 | Server discovery progress UI. |
| `UI/Settings/ChatterboxSettingsViewModel.swift` | 428 | |
| `UI/Settings/VoiceCloningViews.swift` | 421 | Audio file picker + recorder, shared by Chatterbox + Pocket. |
| `UI/Settings/KyutaiPocketSettingsViewModel.swift` | 350 | |
| `UI/Settings/QRCodeScannerView.swift` | 353 | |
| `UI/Settings/OnDeviceSpeechStatusView.swift` | 83 | Parakeet STT status, embedded in VoiceSettingsView. |

Persistence spans roughly 60 distinct UserDefaults/@AppStorage keys, Keychain (9 API key types
via `APIKeyManager`), and `ServerConfigManager` (JSON serialized into UserDefaults). Provider
selections (`sttProvider` / `llmProvider` / `ttsProvider`) are stored as their raw display-name
strings, not as stable identifiers.

Non-settings-folder screens that also expose configuration or developer behavior:

- `UI/Debug/DeviceMetricsView.swift`: real-time CPU/memory/thermal. Ships in release (no DEBUG gate).
- `UI/Debug/DebugConversationTestView.swift` + ViewModel: text-based conversation tester, `#if DEBUG`.
- `UI/Analytics/AnalyticsView.swift`: telemetry dashboard, user-facing.
- `UI/Learning/LearningView.swift:105-109`: in DEBUG, force-enables the specialized-modules feature flag.
- `UI/Learning/ModulesView.swift:467-494`: in DEBUG, allows launching modules without download.
- `UI/KnowledgeBowl/KBQuickstartSettingsView.swift` and `KBDashboardView` (KB settings): module-local config, leave as-is.

---

## 3. Problems found

### 3a. Broken, fake, or placeholder (highest priority: these mislead)

| Issue | Location | Impact |
|---|---|---|
| "Audio Pipeline Test" is entirely simulated. `startRecording()` emits `Float.random` levels, `playRecording()` is empty, `testTTS()` only sleeps 2s. | `SettingsView.swift:1547-1594` | A diagnostic that always passes without touching the real pipeline. Worse than having none. |
| "Provider Connectivity" test is fake. Each `test*()` checks only key presence, then sleeps and returns a hardcoded latency (e.g. `success(latency: 0.15)`). No network call. | `SettingsView.swift:1714-1773` | Reports a green latency for providers that may be unreachable. |
| On-Device LLM load/unload are stubs. A `// TODO: Integrate with OnDeviceLLMService` flips UI state without loading or unloading. | `OnDeviceLLMSettingsView.swift` (~line 431) | The Load/Unload buttons do nothing real. |
| Nested `NavigationStack`. `MoreTabView` wraps content in a `NavigationStack`, then pushes `SettingsView`, which declares its own. | `UnaMentisApp.swift:960` + `SettingsView.swift:18` | Double nav bars, inconsistent titles, fragile deep links. |

### 3b. Duplication (the central structural problem)

- **Two view models manage identical settings.** `SettingsViewModel` and `VoiceSettingsViewModel`
  both declare the same 15 `@AppStorage` keys (sampleRate, vadThreshold, bargeInThreshold,
  temperature, maxTokens, speakingRate, ttsVoice, the chatterbox keys, selfHostedEnabled, and the
  provider trio), and both re-implement `availableModels`, `voiceDisplayName`, `defaultTTSVoices`,
  `discoveredVoices`, and `applyPreset`. Verified: exactly 15 keys appear twice across the two files.
- **The two `applyPreset` implementations have silently diverged**, so the same-named preset does
  different things depending on the screen:
  - `costOptimized`: `SettingsViewModel` sets `llmProvider = .openAI, llmModel = "gpt-4o-mini"`
    (`SettingsView.swift:900`); `VoiceSettingsViewModel` sets
    `sttProvider = .glmASRNano, llmProvider = .localMLX, ttsProvider = .appleTTS`
    (`VoiceSettingsView.swift:730`).
  - `selfHosted`: one flips `selfHostedEnabled = true`, the other does not.
- **`SettingsViewModel.applyPreset` and its `Preset` enum are dead code.** Verified no caller; the
  preset UI lives only in VoiceSettingsView. `SettingsView.swift:870-918`.
- **TTS Playback Tuning is reachable from two places** (under Voice and under Debug & Testing).
- **Three overlapping help systems for settings**: `HelpView`'s "Settings Guide," the separate
  `SettingsHelpSheet` (`SettingsView.swift:2034`), and inline `InfoButton` + `HelpContent.Settings.*`.
  They restate the same content and will drift.
- **Server config is split in two**: the inline Self-Hosted section in SettingsView (toggle, IP,
  refresh, connection status) and the full `ServerSettingsView` (discovery, QR, multi-server).
- **`DeviceMetricsView` overlaps `DiagnosticsView`'s "System" section** (both report thermal/memory).

### 3c. Correctness smells

- **Chatterbox reads a different server key.** Its test synthesis uses `selfHostedServerIP`
  (defaulting to `"localhost"`) at `ChatterboxSettingsViewModel.swift:244` and `:303`, while the rest
  of the app uses `primaryServerIP`. Chatterbox tests against localhost regardless of the configured
  server.
- **Provider persistence by display string.** `sttProvider` and friends are saved as their
  human-readable `rawValue` (for example `"Apple Speech (On-Device)"`). Renaming a label silently
  orphans every user's saved choice. `DiagnosticsView` then re-parses these with `.contains("GLM")`
  and `.contains("On-Device")` string matching (`SettingsView.swift:1157-1299`).
- **Default STT is server-based while self-hosting is off by default.** Both view models default
  `sttProvider = .glmASRNano` (Self-Hosted) while `selfHostedEnabled = false`. Per the on-device STT
  decision, the sensible default is the on-device path (Parakeet/Apple), not an unconfigured server.

### 3d. Organization

- Settings is two taps deep, and the API-key wall is the first screen.
- "Debug & Testing" mixes genuine dev tools, fake tests, server-logging config, and a content seeder,
  all flat in one section, all shipping in release builds. Only "Conversation Test" is `#if DEBUG`.
- On-device model management is scattered across three screens: LLM in `OnDeviceLLMSettingsView`,
  STT/Parakeet in `OnDeviceSpeechStatusView` (embedded in Voice), Pocket TTS in
  `KyutaiPocketSettingsView`. There is no single "models" hub.

---

## 4. Proposed structure

Two principles: a clean user-facing surface for the few things real users touch, and a clearly
fenced **Developer** area holding every nerd knob so we can keep testing and experimenting without
clutter. Nothing useful is deleted, it is organized and gated. The Developer section is
**tap-to-reveal in all builds** (for example, tap the version row several times to reveal it), so it
stays usable on beta devices but is invisible by default.

### Target Settings tree

```
Settings  (single NavigationStack owned by the tab; SettingsView no longer declares its own)
│
├── ⭐ VOICE & AI                          the one screen that matters day to day
│     └── VoiceSettingsView (unchanged content: presets, audio, VAD, STT, LLM, TTS, playback).
│          Also the in-session sheet. Single source of truth.
│
├── ON-DEVICE MODELS                       unify the 3 scattered model screens
│     ├── Language Model      (OnDeviceLLMSettingsView)
│     ├── Speech Recognition  (OnDeviceSpeechStatusView, promoted to a full screen)
│     └── Pocket TTS          (KyutaiPocketSettingsView)
│
├── ACCESSIBILITY                          navigation announcements + future a11y
│
├── HELP                                   collapse 3 help systems into 1 (HelpView)
│
├── ABOUT                                  version (tap target to reveal Developer), docs, privacy
│
└── 🔧 DEVELOPER   (tap-to-reveal; footer: "Tools for testing and experimenting")
      ├── API Providers & Keys ───► the section MOVED OUT of the top level
      │      ├── per-provider → APIProviderDetailView → key entry
      │      └── Session Cost Estimates
      ├── Self-Hosted Server ──────► ServerSettingsView (fold the inline section in here)
      ├── Diagnostics ─────────────► DiagnosticsView (absorbs DeviceMetricsView system metrics)
      ├── Conversation Test  (DEBUG)
      ├── Logging  (Remote Logging + log server IP + Debug/Verbose toggles, grouped)
      └── Sample Data  (Load / Delete Sample Curriculum)
```

### API token section (the explicit ask)

Move the entire "API Providers" section off the top of Settings into **Developer ▸ API Providers &
Keys**. Real users on the default on-device or self-hosted path never need a cloud key, so it should
not be the first thing they see. Keep `APIProviderDetailView` and the cost estimator exactly as they
are. Only the entry point moves.

### Nerd knobs that stay (relocated under Developer)

Keep all of these, because they are how we test and experiment: the full Voice & AI panel with
presets, every Chatterbox and Pocket TTS knob (emotion, cfg weight, seed, neural-engine toggle,
consistency steps), TTS Playback Tuning, Diagnostics, Conversation Test, server discovery/QR, logging
configuration, sample-curriculum seeding, and cost estimates.

### Fix or cut

| Action | Item | Why |
|---|---|---|
| Cut | `AudioTestView` + `AudioTestViewModel` | Fully simulated. Remove the entry now; rebuild as a real test later if wanted. |
| Cut | `ProviderTestView` + `ProviderTestViewModel` | Fake latencies. Diagnostics already does real `/health` checks. |
| Cut | `SettingsViewModel.applyPreset` + `Preset` enum | Confirmed dead code. |
| Merge | The two settings view models | One shared store owns the 15 shared keys. Kills the divergence bug. |
| Merge | `DeviceMetricsView` into `DiagnosticsView` | One health screen. |
| Merge | `SettingsHelpSheet` into `HelpView` | One help system. |
| Fix | Chatterbox `selfHostedServerIP` → `primaryServerIP` | Use the one configured server. |
| Fix | Nested `NavigationStack` | SettingsView should not declare its own when pushed. |
| Fix | Provider persistence by display string | Store a stable `id`, not the label (phased, with a migration). |
| Fix | Default STT provider | Default to the on-device path, not an unconfigured server. |
| Gate | The Developer section | Tap-to-reveal in all builds, so beta users do not wander in. |

---

## 5. Phasing

1. **Phase 1 (structure, low risk).** Add the tap-to-reveal Developer section and move API Providers,
   Self-Hosted, Diagnostics, Logging, and Sample Data into it. Fix the nested NavigationStack. Cut the
   two fake test views and the dead `applyPreset`. Pure reorganization, no behavior change to the
   voice path.
2. **Phase 2 (de-dup).** Collapse the two settings view models into one shared store. Merge
   DeviceMetrics into Diagnostics and SettingsHelpSheet into HelpView.
3. **Phase 3 (correctness).** Fix the Chatterbox server key, the STT default, and (with a migration)
   move provider persistence to stable ids. Build the "On-Device Models" hub.

Outcome: every nerd knob preserved, the misleading fake tests removed, and a four-item top-level
surface (Voice & AI, On-Device Models, Accessibility, Help/About) replacing the API-key wall.

---

## 6. Verified evidence index

- Nested NavigationStack: `UnaMentisApp.swift:960` (MoreTabView) wraps and pushes
  `SettingsView.swift:18` which declares its own `NavigationStack`.
- Fake audio test: `SettingsView.swift:1547-1594` (`AudioTestViewModel`).
- Fake provider test: `SettingsView.swift:1714-1773` (`ProviderTestViewModel`).
- Dead preset code: `SettingsView.swift:870-918`; only callers of `applyPreset` are the unrelated
  `TTSPlaybackTuningViewModel`, `ChatterboxSettingsViewModel`, `KyutaiPocketSettingsViewModel`, and
  `VoiceSettingsViewModel`.
- 15 duplicated `@AppStorage` keys across `SettingsView.swift` and `VoiceSettingsView.swift`.
- Diverged presets: `SettingsView.swift:874-918` vs `VoiceSettingsView.swift:704-748`.
- Chatterbox legacy server key: `ChatterboxSettingsViewModel.swift:244` and `:303`.
- VoiceSettingsView is presented from `SettingsView.swift:52` (push) and
  `SessionView.swift:244` (in-session sheet).
- API Providers section at the top of Settings: `SettingsView.swift:20-47`.
