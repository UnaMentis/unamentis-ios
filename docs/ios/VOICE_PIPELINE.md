# The one voice pipeline

**Class:** living · **Status:** the rule is binding now; the code is partway there

High-quality speech in and high-quality speech out is the product. Everything else sits on top
of it. So there is exactly one voice pipeline, and every surface uses it: core sessions,
modules, the reader, Knowledge Bowl, announcements, barge-in, and anything added later.

Not a copy tuned for one surface. Not a second one for tests. One mature, consistent, best of
breed pipeline that everything shares, so that when it is polished every surface gets the
polish, and when it breaks it breaks in one place that one fix repairs.

## The rules

1. **Application code never constructs a speech engine.** No
   `KyutaiPocketTTSService(...)`, no `AppleTTSService()`, no STT or VAD service, anywhere
   outside the resolver and the implementations themselves. Ask for a pipeline.
2. **No automatic substitution.** An engine that cannot load is a stop-and-fix failure surfaced
   to the user, never quietly swapped for a lesser voice. A fallback is only worth having when
   the degraded state is one we would ship, and a system voice is not. Substituting one turns a
   total failure into something that looks like it half works, so the user gets a bad experience
   and nobody gets a bug report.
3. **A new surface does not get a new pipeline.** New modules and features consume the existing
   one.

Enforced by `./scripts/check-voice-pipeline.sh`, which runs inside `./scripts/lint.sh` and
therefore in CI. It is a ratchet: existing debt lives in `.voice-pipeline-baseline` and may only
shrink. A new construction site, or an existing file getting worse, fails the build. A genuinely
unavoidable case is annotated `// VOICE-PIPELINE-EXEMPT: <reason>` on the line.

## How this happened

Worth recording plainly, because the shape recurs.

The intended single resolver already exists and has for some time:
`TTSProvider.resolveConfiguredService()` in `UnaMentis/Services/Protocols/TTSService.swift`.
`AudioTTSCache` even documents it as the thing that ensures every module resolves consistently.

Only three consumers ever called it: `AudioTTSCache`, `UnifiedAnnouncer`, and
`ReadingAudioPreGenerator`. The actual voice paths each hand-rolled their own provider switch
instead. Nobody set out to duplicate anything. Each site was written by someone solving a local
problem who did not know the resolver existed, and once two existed, the third looked normal.

The cost was not theoretical. By 2026-08-15 there were five independent TTS resolution sites,
each with a different answer to "what happens when the engine fails":

- the core session substituted Apple TTS (added, wrongly, in PR #14)
- barge-in substituted Apple TTS through a second switch in the same file
- Knowledge Bowl logged the failure and carried on with a broken engine, so it went silent
- the canonical resolver silently returned Pocket TTS for any cloud provider, and never
  attempted a load at all, so it could not detect a broken engine
- a fifth, in `KBVoiceCoordinator`, was excluded from the build entirely and so was dead code
  that still looked authoritative to anyone reading it

A sixth arrived with the Module SDK branch's `UnifiedVoiceSessionService`.

Three of those were written believing they were the only one.

## The debt, as measured

Run `./scripts/check-voice-pipeline.sh --list` for the live list. As of 2026-08-15, 52 direct
constructions across 12 files:

| File | Count | Notes |
|---|---:|---|
| `UI/Session/SessionView.swift` | 31 | Two full provider switches, main session and barge-in |
| `Modules/KnowledgeBowl/Services/KBVoiceCoordinator.swift` | 5 | Dead code, excluded by `project.yml` |
| `Services/KnowledgeBowl/KBOnDeviceTTS.swift` | 3 | Knowledge Bowl's own switch |
| `Core/Audio/UnifiedAnnouncer.swift` | 2 | Hardcodes Apple TTS for announcements |
| `UI/Debug/DebugConversationViewModel.swift` | 2 | Hardcodes Apple TTS, so it never tests the real engine |
| `Testing/LatencyHarness/LatencyTestCoordinator.swift` | 2 | Harness, deliberate |
| `Testing/KBAudioTestHarness/KBAudioGenerator.swift` | 2 | Harness, deliberate |
| `Services/KnowledgeBowl/KBOnDeviceSTT.swift` | 1 | |
| `Testing/KBAudioTestHarness/KBAudioInjector.swift` | 1 | Harness, deliberate |
| `Testing/BargeInHarness/BargeInMeasurementHarness.swift` | 1 | Harness, deliberate |
| `UI/Settings/KyutaiPocketSettingsViewModel.swift` | 1 | Engine-specific settings screen |
| `UI/Settings/ChatterboxSettingsViewModel.swift` | 1 | Engine-specific settings screen |

Two of these are legitimate and will end up exempt rather than migrated: the engine-specific
settings screens exist precisely to configure and test one named engine. The test harnesses are
a judgment call, since a harness that needs to compare engines has a real reason to name them.

## The target

One resolver owns the decision and the policy:

- it reads the user's configured provider once
- it loads the engine eagerly, so a broken engine is discovered at acquisition rather than
  mid-sentence
- it returns nothing on failure, and never substitutes
- callers surface that failure to the user and stop, rather than continuing degraded

The Module SDK branch has the better shape for the consumer side: modules call
`host.voice.acquire(config:)` and receive an opaque session with `speak`, `listen`, and
`stopSpeaking`, and its header states the rule directly, that modules never instantiate STT,
TTS, VAD, or audio engines. That contract should become the way every surface consumes voice,
not just modules, with `VoicePipelineOwnership` arbitrating exclusive access.

The gap is that the branch's `UnifiedVoiceSessionService.resolveConfiguredTTS()` currently
carries the same Apple TTS substitution that rule 2 forbids. It needs the same removal main
just took before that branch lands, or the policy will hold on main and quietly break the moment
modules arrive.

## Migration order

Ordered by risk removed per unit of work.

1. **`SessionView`, both switches.** 31 of the 52, and it is the surface the demo uses. Replace
   both hand-rolled switches with one resolver call. Delete the second switch entirely rather
   than porting it: barge-in and the session should not be able to disagree about which engine
   is in use.
2. **Make the resolver honest.** `resolveConfiguredService()` must stop silently returning
   Pocket TTS for cloud providers, must attempt the load, and must be able to return nothing.
   Everything else depends on this being true.
3. **`KBOnDeviceTTS` and `KBOnDeviceSTT`.** Knowledge Bowl consumes the resolver. On the Module
   SDK branch this happens naturally, since KB becomes a module.
4. **Delete `KBVoiceCoordinator`.** Dead, excluded, and misleading. The SDK branch already
   deletes it.
5. **`UnifiedAnnouncer` and `DebugConversationViewModel`.** Both hardcode Apple TTS. The debug
   one matters more than it looks: it is the screen used to test conversation without voice
   input, and it currently cannot exercise the real engine at all.
6. **Exempt the settings screens and harnesses** with a stated reason, so the remaining count is
   real debt rather than noise.

Every step lowers the baseline. Lock each one in with
`./scripts/check-voice-pipeline.sh --update`.

## If you are adding a feature

Ask the resolver. If what you need is not expressible through it, that is a gap in the pipeline
to fix once, in the pipeline, where every surface benefits. It is never a reason to build a
second one.
