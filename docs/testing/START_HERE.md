# Start here

**Class:** living · **Audience:** a Claude Code session on the MacBook, and Richard

This is the gateway. If you have just pulled the repo and been told "read this and go", you are
in the right place. Read this page, then work the order below.

## Do this in order

1. **Read `../ios/VOICE_PIPELINE.md` and do the migration in it.** This comes before testing.
   The system is supposed to have exactly one voice pipeline and currently has 52 direct engine
   constructions across 12 files, including two separate provider switches inside
   `SessionView.swift` alone. Testing a pipeline that exists in five variants tells you almost
   nothing, because a fix in one place does not reach the others. Start with migration step 1,
   `SessionView`, which is 31 of the 52 and is the surface the demo uses.
   `./scripts/check-voice-pipeline.sh --list` shows the live list and lint enforces the ratchet.
2. **Then phase 1**, the simulator validation below.
3. **Then phase 2**, the on-device manual pass, which is Richard's.

If time forces a choice, do step 1 and step 3. A hand-verified device run against a unified
pipeline is worth more than a thorough simulator run against a fragmented one.

Validation runs in two phases, in order. **Phase 1 is machine work and no human should sit
through it. Phase 2 is human work and only a human with a real iPhone can do it.** Do not start
phase 2 until phase 1 reports green, because most phase 2 failures would just be phase 1
failures discovered slowly.

| Phase | Who runs it | Where | Plan |
|---|---|---|---|
| 1. Build and simulator validation | A Claude Code session, autonomously | MacBook, iOS Simulator | [SIMULATOR_VALIDATION_RUN.md](SIMULATOR_VALIDATION_RUN.md) |
| 2. On-device manual testing | Richard, by hand | A real iPhone | [DEVICE_MANUAL_TEST_PLAN.md](DEVICE_MANUAL_TEST_PLAN.md) |

## Know what you are testing before you start

As of 2026-08-15 there are **two versions of this app**, and validating the wrong one wastes the
whole run.

- **`main`** carries this week's work: curriculum reinforcement in context, model download
  integrity, reader foveation, and the session Apple TTS fallback.
- **`feature/module-sdk-foundation`** carries the Module SDK migration and five modules
  (Knowledge Bowl, Quiz Bowl, Oral Exam Studio, Aural Skills, SAT Prep). It is 6 commits ahead
  of main and **28 behind**, has no pull request, and **has never run CI even once**: the
  workflows fire only on pushes to `main` or `develop` and on pull requests, so roughly 34,000
  lines are unbuilt and untested by anything.

The merge between them is textually clean (one auto-mergeable file, `UnaMentisApp.swift`), but
the branch has never compiled against main's changes, so expect compile drift rather than merge
conflicts, most likely around `Services/LLM`.

**Decide first: does this validation pass cover the modules or not?**

- If the answer is no, test `main` as it stands and everything below applies unchanged.
- If yes, the branch needs a pull request so CI runs, then main merged into it, then a full
  build and `TEST_TYPE=all` before any of the phase 1 questions are worth asking. Treat that as
  its own piece of work, not a preamble to this one.

## Which machine can do what

This matters more than it sounds, and getting it wrong wastes hours.

- **The MacBook** is the build host. It has Xcode with the iOS platform and simulator runtimes,
  so it can build, run the test suite, and drive the simulator.
- **The Mac Studio cannot build or test iOS at all.** It has Xcode but no iOS platform and no
  simulator runtimes, so `xcodebuild` fails before it starts. A session there can read code,
  reason, write, and push, and CI is its only build and test gate. Do not plan simulator work
  from the Studio.

## What the simulator can and cannot answer

Phase 1 exists to clear everything a machine can clear. Be precise about its ceiling, because
a green simulator run is genuinely reassuring for some things and worth nothing for others.

**The simulator answers these:** does it build, does the unit suite pass, does the app launch
and navigate, does the on-device LLM load a GGUF and generate coherent text, does Pocket TTS
produce non-empty audio, does the reader produce foveated context, do the settings screens
behave.

**The simulator cannot answer these, and a green result here means nothing about them:**

- **Whether Pocket TTS works on a real phone.** The fault recorded in `7483a6d` is specific to
  the device arm64 slice, and the simulator slice passes while the device slice fails. This is
  the single most important thing to keep straight: **phase 1 passing its TTS checks does not
  predict phase 2**, it only rules out a second, different problem.
- **Real audio quality, timing, and routing.** Gaps between sentences, headphone and Bluetooth
  changes, and interruption by a phone call are all device behavior.
- **Memory and thermal reality.** The simulator runs on a Mac with tens of gigabytes and no
  jetsam, so it cannot tell you whether a model plus the audio stack survives a long session
  on a phone.
- **Metal GPU offload.** The simulator loads models with zero GPU layers, so on-device
  inference speed is unmeasured.
- **Real speech in and out.** Barge-in against a human voice, false triggers from background
  noise, and whether a voice sounds right are all human judgments.

## Should Richard test in the simulator?

No. Anything clickable in the simulator, a session on the MacBook can drive faster and inspect
more thoroughly, and none of the simulator-reachable questions need human judgment. Richard's
time is worth spending only on phase 2, where a real phone, real speech, and real ears are the
instrument.

## Where results go

Phase 1 writes its findings to `docs/status/`, dated, as a state document. Phase 2 findings
come back as notes from Richard and get folded into the same place. Anything that needs a
decision or outlives the session becomes a GitHub issue rather than a paragraph in a chat log.

## The standing rules that apply to both phases

- Never push, and commit only on an explicit instruction, unless the session has been armed
  for delivery (see `.claude/skills/ship/SKILL.md`).
- Done means the checks actually ran and passed, not that the code compiled.
- Tool findings are presumed real until analysis proves otherwise.
- Report failures with their output. A skipped check is named as skipped, never as a pass.
