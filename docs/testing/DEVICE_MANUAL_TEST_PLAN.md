# Phase 2: on-device manual test plan

**Class:** living · **Runs on:** a real iPhone · **Executed by:** Richard, by hand

Entry point is [START_HERE.md](START_HERE.md). **Do not start this until phase 1
([SIMULATOR_VALIDATION_RUN.md](SIMULATOR_VALIDATION_RUN.md)) reports green**, and read its
status document in `docs/status/` first: it will name the two or three things most worth your
attention on this particular build, which may differ from the emphasis below.

Everything here is something a machine genuinely cannot answer. Nothing here duplicates what the
simulator already settled. Roughly 30 minutes, with a 10 minute path if that is all you have.

Each test says what to report back, because none of this has automated coverage and your
observation is the only signal that exists.

---

## Why the device is the only instrument that counts

Three of the riskiest behaviors in this app are invisible in a simulator:

- **The Pocket TTS fault is device-only.** The fault recorded in `7483a6d` lives in the device
  arm64 slice; the simulator slice passes. A green phase 1 rules out a second, different problem
  and tells you nothing about this one.
- **Memory and thermal pressure are real here.** The simulator has no jetsam. A model plus the
  audio stack over a long session is a device question.
- **Speech is a human judgment.** Whether a voice sounds right, whether a gap feels wrong,
  whether background noise falsely interrupts.

---

## Before you start

1. Install the build phase 1 validated. Do not build something newer without rerunning phase 1.
2. Have the phase 1 status document open, or at least its verdict.

**If phase 1 could not run**, the two things that silently invalidate everything below are the
`models` symlink and `llama.xcframework`. Both are repaired by `./scripts/setup-models.sh` and
`./scripts/fetch-llama-framework.sh`.

---

## Standing decisions

**Run on Qwen3-1.7B, the model already on the phone. Do not download Gemma 4 E2B.** The app
loads the best model whose file is actually present, so with only Qwen3-1.7B there it loads that
and never touches Gemma. Gemma 4 E2B has never run on real hardware, is a 3.11 GB download with
no resume support, has no memory guard, and has no fallback if it fails to load. Qwen3-1.7B is
Apache 2.0, from May 2025, and is the one configuration with a recorded end-to-end verification.

Expect one cosmetic oddity: Settings will still name Gemma 4 E2B and offer to download it,
because that screen keys off memory tier while the session keys off what is on disk. Ignore it.
Tracked as issue #8.

---

## The tests

### 1. Which engine is actually running (2 min)

There is no screen showing the Pocket TTS version, so the device log is the only source of
truth. Attach the phone and stream:

```
log stream --predicate 'subsystem == "com.unamentis" AND category == "KyutaiPocketTTS"'
```

Open **Settings → Voice → Pocket TTS settings** and watch for `Model version:` and
`Parameters:` during load.

**Report back:** the exact version and parameter count, or that no such line appeared. This is
how we confirm which engine build is really on the phone. (Surfacing this in the UI is a known
few-line improvement; if phase 1 did it, read it off the screen instead.)

### 2. Direct engine probe, the fastest verdict (2 min)

Same screen, **Test** section. Type a short sentence, tap **Test Voice**.

| Result | Meaning | Next |
|---|---|---|
| Audible, non-zero bytes | Engine healthy on device, and the device fault is resolved | Continue to 3 |
| Zero bytes or an error | The device arm64 fault is still present | Continue; the Apple fallback is now what you are testing, and see the warning below |
| Button disabled | Model never loaded, weights missing | Stop, the build is not set up correctly |

**Report back:** the exact result string, including byte count and synthesis time. This is the
single most valuable measurement in the whole plan.

**If this test fails, expect the fallback itself to misbehave.** The Apple TTS fallback added in
PR #14 has a known defect, found 2026-08-15 and not yet fixed: `AppleTTSService` speaks through
its own system synthesizer and hands the playback orchestrator a chunk containing no audio
bytes, which the orchestrator correctly treats as a synthesis failure. So the likely symptom is
**an Apple voice that speaks, followed by an error state after each segment, and barge-in that
cannot interrupt it** (stopping the audio engine does not stop the system synthesizer). That is
a known bug, not a new discovery, so note it and move on rather than chasing it.

### 3. On-device model loads and generates (5 min)

Start a session and speak one throwaway turn. Expect speech transcribed, a thinking state, then
a spoken answer.

Watch the **first turn**, where the language model cold-loads about 1.1 GB, and note that
**starting the session** is also slower than it used to be because the speech engine now loads
up front. That is what removes the dead air before the first answer, and it is a deliberate
trade we can reverse in two lines if it feels wrong.

If a red error repeats on every turn, the model failed to load. Stop and send the exact text.

**Report back:** session start time, first response versus second and third, whether the answer
was coherent and on topic, and whether the startup wait feels acceptable.

### 4. Queueing and audio delivery (10 min)

The long-standing problem area. Hold a conversation of at least five turns including one
deliberately long answer.

- **a. Text and audio sync.** Text is deliberately withheld until audio starts. Text with no
  audio is the known failure signature.
- **b. Gaps between sentences.** Each segment is fully buffered before any of it plays, so a
  slow segment stalls audibly.
- **c. Truncation or overlap.** Any sentence cut off, repeated, or overlapping the next.
- **d. Text hygiene.** Ask for something containing a URL, a list, or code. Nothing sanitizes
  session text before synthesis, so expect markup read literally.

**Report back:** what you heard for each, and roughly how often. For gaps, whether they fall
between sentences or mid-sentence, because those are different bugs.

### 5. Session versus Knowledge Bowl, which is the real A/B (3 min)

Corrected 2026-08-15. An earlier version of this plan said Knowledge Bowl falls back to Apple
TTS. **It does not.** That fallback lives in `KBVoiceCoordinator.swift`, which `project.yml`
excludes from the app target, so it has never been compiled. Knowledge Bowl actually runs
`KBOnDeviceTTS`, which logs a Pocket TTS load failure and carries on with the broken engine.

So the two surfaces now behave differently on purpose, and that difference is the diagnostic:

| If Pocket TTS is | The session does | Knowledge Bowl does |
|---|---|---|
| Working | Speaks in the Kyutai voice | Speaks in the Kyutai voice |
| Broken | Speaks in the Apple voice, probably with an error after each segment | **Stays silent** |

Speak a turn in a session, then open a Knowledge Bowl oral practice.

**Report back:** which voice each used, or which was silent. Session speaking while Knowledge
Bowl is silent is the clearest possible signal that the device fault is still present.

### 6. Barge-in against real speech (5 min)

Interrupt mid-answer, out loud. Expected: narration continues briefly while detection confirms,
pauses, **a short filler plays almost immediately**, the real answer streams, narration resumes.

The filler is the thing to watch: those clips are pre-rendered at launch with the active engine,
so a failed engine makes them vanish and every interruption opens with dead air.

Try a question, a command such as stop or skip, and a false trigger such as a cough or
background noise that should **not** interrupt.

**Report back:** whether a filler played and how fast, whether resume was sensible, and whether
anything falsely triggered.

### 7. Reader playback and grounded answers (5 min)

Open a document and press play. Check startup speed, the deliberate 600 ms pacing between
segments, and skip-back-10, which will re-synthesize rather than replay instantly.

Then **ask a question about what was just read**. Phase 1 checks that the context is assembled
correctly; only you can judge whether the spoken answer actually reflects the document and
arrives quickly enough to feel conversational.

**Report back:** startup delay, whether pacing sounded natural, and whether the answer was
genuinely grounded in the document.

### 8. Routing and interruptions (3 min)

While audio plays: unplug and replug headphones, connect the Bluetooth device you will actually
use, and have someone call you so you can decline. Handlers exist for all three and are
unverified on device.

**Report back:** whether audio recovered on its own, or needed a restart.

---

## If you only have ten minutes

Run **2, 3, and 5**. They answer whether the speech engine works on this phone, whether the
on-device model runs, and which voice you will actually be heard with. Everything else refines
a picture those three establish.

---

## What matters most

In priority order, because none of it has automated coverage:

1. **Whether Pocket TTS works on this phone** (tests 2 and 5). Everything about the audio
   experience follows from that one answer, and it is the question phase 1 structurally cannot
   reach.
2. **Whether the on-device model loads and generates on real hardware** (test 3), including
   whether the new startup wait is tolerable.
3. **The shape of the queueing problems** (test 4). Gaps and silent-text are different bugs.
4. **Whether reader answers are genuinely grounded** (test 7).

Rough notes are fine. Which things are broken matters far more than precise numbers.
