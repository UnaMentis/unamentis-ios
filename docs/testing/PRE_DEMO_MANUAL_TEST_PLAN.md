# Pre-demo manual test plan

**Class:** state · **Date:** 2026-08-15 · **For:** the 2026-08-16 demo on the iPhone 17 Pro

Ordered fail-fast: each stage tells you whether the next one is worth running. Roughly 30
minutes if things are healthy, and the first three tests find most problems.

Every test says what to report back, because several of these have no automated coverage and
your observation is the only signal.

---

## The two decisions already made for you

**1. The demo runs on Qwen3-1.7B, the model already on your phone. Do not download Gemma 4
E2B.**

The app picks the best model whose file is actually present
(`OnDeviceLLMService.bestAvailableModel`), so with only Qwen3-1.7B on disk it loads
Qwen3-1.7B and never touches Gemma. Gemma 4 E2B has never run on real hardware, is a 3.11 GB
download with no resume support (backgrounding restarts it from zero), has no memory guard,
and if it fails to load there is no fallback: you would get a technical error toast on every
single turn. That is not a demo risk worth taking overnight. Qwen3-1.7B is Apache 2.0, from
May 2025, and is the one configuration with a recorded end-to-end verification.

**Cosmetic consequence to expect:** Settings will still show "Gemma 4 E2B" as the model for
this device and offer to download it, because the Settings screen keys off RAM tier while the
session keys off what is on disk. Ignore it. That mismatch is filed as issue #8.

**2. Pocket TTS may be silent on device.** Commit `7483a6d` (2026-06-29) diagnosed a
device-arm64 runtime fault inside the prebuilt engine, and the binary has not been rebuilt
since 2026-01-28. PR #14 adds an Apple TTS fallback to the session so a demo is never
voiceless, but confirming which engine you are actually hearing is the single most important
thing this plan establishes.

---

## Pre-flight (on the MacBook, before building)

1. `git pull` on `main` (includes PR #14 once merged).
2. Confirm `models/Models` resolves and contains real weights, not a dangling symlink:
   `ls -lL models/Models/` should list `model.safetensors`, `tokenizer.model`, and `voices/`.
   **If the symlink dangles, Pocket TTS cannot load and every audio test below is a false
   negative.** Fix with `./scripts/setup-models.sh`.
3. Confirm `UnaMentis/Frameworks/llama.xcframework` exists. It is gitignored and there is no
   local fetch script, so a clean checkout will fail to build. If missing:
   ```
   curl -fsSL -o /tmp/llama.zip https://github.com/ggml-org/llama.cpp/releases/download/b9821/llama-b9821-xcframework.zip
   unzip -q /tmp/llama.zip -d /tmp/llama && cp -R /tmp/llama/build-apple/llama.xcframework UnaMentis/Frameworks/
   ```
4. `xcodegen generate`, then build and install to the phone.

**Report back:** whether the symlink and framework were already correct, or you had to fix
them.

---

## Test 1: Which TTS engine is actually running (2 min)

The app has no UI showing the Pocket TTS version, so the log is the only source of truth.

Attach the phone and stream:
```
log stream --predicate 'subsystem == "com.unamentis" AND category == "KyutaiPocketTTS"'
```

Open **Settings → Voice → Pocket TTS settings**. Look for `Model version:` and `Parameters:`
lines emitted during load.

**Report back:** the exact version and parameter count printed, or that no such line appeared.
This is how we confirm you are on the current Pocket TTS build rather than the January one.

---

## Test 2: Direct Pocket TTS probe, the fastest possible verdict (2 min)

**Settings → Voice → Pocket TTS settings → Test section.** Type a short sentence, tap
**Test Voice**.

| Result | Meaning | What to do |
|---|---|---|
| Audible speech, non-zero bytes, time reported | Engine is healthy on device | Continue to test 3 |
| Zero bytes, or an error | The engine is the January build with the device fault | Continue anyway; PR #14's Apple fallback is now the thing under test |
| Button disabled | Model never loaded (weights missing) | Stop, revisit pre-flight step 2 |

**Report back:** the exact result string, including byte count and synthesis time.

---

## Test 3: On-device model loads and generates (5 min)

Start a normal learning session and speak one throwaway turn.

Watch for, in order: your speech transcribed, a brief thinking state, then a spoken response.

**Specifically observe the first turn**, which is where the model cold-loads (roughly 1.1 GB).
Expect a longer pause before the first response than on subsequent turns. If PR #14 is in your
build, TTS is already warm, so this pause is the LLM only.

**Report back:**
- Roughly how long the first response took versus the second and third.
- Whether the response text was coherent and on topic (this tells us Qwen3-1.7B is genuinely
  generating rather than falling through to a cloud provider).
- Anything in Settings → On-Device LLM showing what it thinks is loaded.

If instead you see a red error toast repeating on every turn, the model failed to load; stop
and tell me the exact error text.

---

## Test 4: TTS queueing and audio delivery in a session (10 min)

This is the "continuing issues" area, so it gets the most attention. Have a conversation of at
least five turns, with at least one deliberately long answer (ask for a detailed explanation).

Watch for these specific things:

**a. Text and audio synchronization.** Text is deliberately withheld until audio starts
(`SessionView` sets the message and highlight at playback start). So:
- Text appears and audio starts together: correct.
- **Text appears with no audio**: TTS failed while the pipeline thought it succeeded. This is
  the June symptom. Note whether an error state flashed.
- Audio starts noticeably before or after its text: a sync regression worth knowing about.

**b. Gaps between sentences.** A long answer is split into sentences and synthesized ahead
(prefetch depth 2 in sessions). Listen for unnatural pauses mid-answer. The orchestrator
buffers each whole segment before playing any of it, so a slow segment stalls audibly even
though streaming was available.

**c. Truncation or overlap.** Does any sentence get cut off, repeat, or overlap the next?

**d. Text hygiene.** Ask something that will make the model produce a URL, a markdown list, or
a code snippet. Nothing sanitizes session text before synthesis (`TextCleaner` is only wired
into Knowledge Bowl import), so it will likely read punctuation and markup literally.

**Report back:** for each of a through d, what you actually heard, and roughly how often. If
gaps occur, note whether they are between sentences or mid-sentence.

---

## Test 5: The A/B that identifies which engine you are hearing (3 min)

Knowledge Bowl has always fallen back to Apple TTS on a Pocket TTS failure. The session now
does too (PR #14). So compare voices directly:

1. Speak a turn in a normal session, note the voice.
2. Open a Knowledge Bowl oral practice, note the voice.

**If both sound like the same Apple system voice**, Pocket TTS is failing on device and you are
hearing the fallback in both places. **If they sound different**, or both sound like the Kyutai
voice, Pocket TTS is alive.

**Report back:** same voice or different, and your best description of each.

---

## Test 6: Barge-in (5 min)

While the AI is speaking a long answer, interrupt it out loud with a question.

Expected sequence: narration keeps going for a moment while detection confirms, narration
pauses, **a short filler phrase plays almost immediately**, then the real answer streams, then
narration resumes.

**The filler is the thing to watch.** Filler clips are pre-rendered at launch using the active
TTS service. If Pocket TTS failed at launch and PR #14 is not in your build, the bank stays
empty and fillers vanish silently, leaving multi-second dead air on every interruption.

Try three interruptions:
- A question ("wait, what does that mean?")
- A command ("stop" or "skip")
- A false trigger: cough, or let background noise play, and confirm it does **not** interrupt.

**Report back:** whether a filler played and how quickly, whether the resume picked up sensibly,
and whether anything falsely triggered.

---

## Test 7: Reading list playback (5 min)

Open a document in the reading list and press play.

- **Startup**: the first chunks are pre-generated at import, so play should be near-instant. If
  you see "Preparing audio..." for a long time, pre-generation did not happen.
- **Inter-segment pacing**: this path deliberately inserts 600 ms between segments. Confirm it
  sounds like natural paragraph pacing, not stalling.
- **Skip back 10**: press it. Expect re-synthesis rather than instant replay; the prefetch
  cache promotion path is dead code, so nothing is retained behind. Note how long it takes.
- **Barge-in during reading**: ask a question about what was just read and see whether the
  answer is actually grounded in the document. This exercises the foveated context that shipped
  in PR #7 tonight, and it is completely unexercised by anyone so far.

**Report back:** startup delay, whether pacing sounded right, skip-back behavior, and above all
whether the barge-in answer used real document content.

---

## Test 8: Interruptions and audio routing (3 min)

While audio is playing:
1. Plug in or unplug headphones.
2. Connect Bluetooth if you will use it in the demo.
3. Have someone call you, decline, and see whether audio resumes.

There are handlers for all three, but they are unverified on this build.

**Report back:** whether audio recovered in each case or needed a restart.

---

## If you only have ten minutes

Tests 1, 2, 3, and 5. Those establish: which engine, whether it works, whether the on-device
model runs, and which voice you will actually demo with.

---

## What I most need from you

In priority order, because these have no automated coverage and I cannot test any of them from
this machine:

1. **Which TTS engine you are hearing** (tests 1, 2, 5). Everything about the audio experience
   depends on this answer.
2. **Whether the on-device model loads and generates** (test 3). This is the demo's headline and
   it has never been verified on hardware.
3. **The shape of the TTS queueing problems** (test 4). "Gaps between sentences" and "text with
   no audio" are very different bugs and I need to know which you are seeing.
4. **Whether reader barge-in answers use document content** (test 7). Brand new code from
   tonight, entirely unexercised.

Rough notes are fine. What matters is which of these are broken, not precise measurements.
