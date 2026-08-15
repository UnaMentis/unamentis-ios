# Phase 1: build and simulator validation

**Class:** living · **Runs on:** the MacBook · **Executed by:** a Claude Code session, autonomously

Entry point is [START_HERE.md](START_HERE.md); read it first for what the simulator can and
cannot prove. Richard does not sit through this run. When it finishes, he needs one short
verdict and a state document, not a transcript.

Work through the stages in order. Each stage says what must be true before moving on. **A stage
that cannot complete is a finding, not a reason to skip ahead.** Record it and continue only
where the remaining stages are still meaningful.

---

## Stage 0: environment

Everything below is worthless if the inputs are wrong, and both of these fail quietly.

```bash
./scripts/setup-models.sh            # Pocket TTS weights symlink
./scripts/fetch-llama-framework.sh   # llama.xcframework, gitignored, needed to link
xcodegen generate
```

Then verify rather than assume:

- `ls -lL models/Models/` lists `model.safetensors`, `tokenizer.model`, and `voices/`. A
  dangling symlink here makes every later TTS result a false negative.
- `UnaMentis/Frameworks/llama.xcframework/Info.plist` exists.
- `xcrun simctl list runtimes` shows at least one available iOS runtime.

**Report:** whether either script had to repair something, since that tells us how a fresh pull
behaves for the next person.

---

## Stage 1: the automated gate

```bash
./scripts/lint.sh
./scripts/test-ci.sh                 # TEST_TYPE=unit by default
```

Both must pass. If tests fail, fix the cause or record precisely why it cannot be fixed. Do not
weaken an assertion to make it pass; a test that never ran before and fails on first execution
is telling you something real, which happened twice during the 2026-08-14 delivery.

Then the integration lane, which is where the interesting failures live:

```bash
TEST_TYPE=integration ./scripts/test-ci.sh
```

Several integration classes skip themselves when a capability is missing. **Count the skips and
name them.** A suite that reports success while silently skipping the Pocket TTS tests has told
you nothing about Pocket TTS.

**Report:** pass or fail per lane, the test count, and every skipped class with its reason.

---

## Stage 2: launch and navigate

Use the XcodeBuildMCP and ios-simulator MCP servers as described in
[AI_SIMULATOR_TESTING.md](AI_SIMULATOR_TESTING.md), which covers setup, tools, and the
round-trip debugging loop. Build, install, and launch on the simulator, with log capture running.

Then walk the app: main session screen, reading list, Knowledge Bowl entry, and Settings
including the On-Device LLM and Pocket TTS screens. Screenshot each.

**Report:** anything that fails to render, hangs, or logs an error during a clean launch.

---

## Stage 3: the questions worth answering here

These are the reason phase 1 exists. Answer each one with evidence, not impression.

### 3.1 Which on-device model resolves, and does it generate?

The ladder picks the best model whose file is present, so the simulator's answer depends on what
is in its container. Determine which model `OnDeviceLLMService.bestAvailableModel()` selects,
then drive a session turn and confirm the model produces coherent, on-topic text rather than
falling through to a cloud provider.

Note that the simulator loads with zero GPU layers, so **timings here are not predictive of
device speed.** Record them anyway as a floor, and label them as simulator numbers.

**Answer:** which model, whether it loaded, whether it generated, and the observed latency with
that caveat attached.

### 3.2 Does Pocket TTS produce audio in the simulator?

Exercise the real engine, not a mock. The `PocketTTSSynthesisTests` integration class does
exactly this and skips itself when weights are placeholders, so a skip here means stage 0 was
not actually satisfied.

Capture the engine's own log lines, which carry the version:

```
log stream --predicate 'subsystem == "com.unamentis" AND category == "KyutaiPocketTTS"'
```

**Answer:** the reported model version and parameter count, whether synthesis produced non-empty
audio, and the cold start time. **State explicitly in the report that this says nothing about
the device**, so nobody reads a green result as device readiness.

### 3.3 Does the Apple TTS fallback actually engage?

Added in PR #14 and never exercised. Force a Pocket TTS failure (for example by pointing the
model path somewhere invalid, or temporarily moving the weights) and confirm the session still
speaks through Apple TTS instead of going silent, and that the barge-in filler bank still
populates.

**Answer:** whether the fallback engaged, and what the user-visible behavior was.

### 3.4 Does the reader produce foveated context?

Shipped 2026-08-14 in PR #7 and completely unexercised. Import a document long enough to produce
many sections, let summary pre-generation run, then confirm: a summary sidecar is written, the
outline and the earlier and upcoming bands appear in the assembled context, and a barge-in
question during reading is answered from document content rather than generically.

**Answer:** whether summaries generated, whether the assembled context contains the expected
bands, and whether the answer was grounded.

### 3.5 Does back-pocket curriculum material reach the prompt?

Shipped the same day in PR #5. Import a curriculum whose UMCF carries `alternativeExplanations`
and `misconceptions`, then confirm they appear in the working context and that the spoken
correction is preferred over the written one.

**Answer:** present or absent, with the rendered section quoted.

---

## Stage 4: improve the harness

Richard has asked that every pass leave testing better than it found it. Spend real effort here,
and prefer fixing a cause over documenting a workaround.

Known candidates, all verified as of 2026-08-15:

- **`test-ci.sh` keeps a hand-maintained list of integration classes** that must mirror
  `UnaMentisTests/Integration/`. It has drifted twice. Deriving it from the filesystem removes
  the whole class of failure. Tracked as issue #10.
- **A skipped test run reports PASSED** to the hook log, so `hook-audit.sh` cannot tell a real
  pass from a skip. Also issue #10.
- **`preWarm()` is never called**, and the session and barge-in paths each load their own copy
  of the Pocket TTS weights. Issue #15.
- **There is no in-app display of the Pocket TTS version.** It exists in the bindings and is only
  logged. Surfacing it in the Pocket TTS settings screen is a few lines and would make phase 2
  far easier, since the log is currently the only way to know which engine is running.

Anything you fix goes through the normal route: lint, tests, PR, CI green.

**Report:** what you improved, and what you found but deliberately left alone.

---

## Deliverable

Write `docs/status/YYYY-MM-DD-simulator-validation.md` as a state document containing:

1. **A verdict in the first three lines.** Is this build worth putting on a phone, yes or no.
2. Stage results, with the automated gate's numbers.
3. An answer to each question in stage 3, with its evidence and its caveat.
4. What phase 2 should focus on, given what phase 1 could not settle. This directly shapes
   Richard's manual pass, so be specific: name the tests in
   [DEVICE_MANUAL_TEST_PLAN.md](DEVICE_MANUAL_TEST_PLAN.md) that matter most given what you saw.
5. Anything you changed in the harness.

Then tell Richard, in a short message: the verdict, the two or three things he most needs to
check on device, and anything that would waste his time if he hit it unprepared.
