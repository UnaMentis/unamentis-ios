---
name: measure-barge-in
description: Measure the barge-in pipeline (detection, latency, noise/echo rejection, command-vs-engagement) against the goal in .claude/goals/barge-in.json
---

# /measure-barge-in - Barge-In Pipeline Measurement

## Purpose

Turns the goal "a single reliable barge-in pipeline with latency in the target
range" into objective numbers and grades them against the criteria in
`.claude/goals/barge-in.json`. This is the measurement the goal feature checks.

**Critical rule:** the goal is NOT met until a `device` run passes. The simulator
run is a fast, repeatable proxy for regression; it cannot prove the goal because
it does not exercise the real microphone, speaker echo, or hardware latency.

## Usage

```
/measure-barge-in quick      # full seed, lenient grading (INCONCLUSIVE allowed) - fast feedback
/measure-barge-in full       # full seed, strict grading
/measure-barge-in baseline <name>   # save the current run as a baseline
/measure-barge-in compare <name>    # run, diffed against a saved baseline
```

All modes run the simulator INJECTION harness: generated audio is fed into the
real VAD + `BargeInDetector`. It measures detection, reaction latency, noise
rejection, and command-vs-engagement classification, but NOT the microphone,
speaker echo, or hardware latency. The goal's source of truth is a real-acoustic
DEVICE run (mic + speaker + echo) with the real streaming STT - a separate
workstream, not this script.

## Workflow

1. Run the backing script, which builds the app, runs the measurement test that
   drives `BargeInMeasurementHarness` over the corpus, and prints the result JSON:
   ```bash
   ./scripts/measure-barge-in.sh <mode> [name]
   ```
2. The script writes the raw result to `build/barge-in-results/<mode>-<ts>.json`
   and grades each criterion in `.claude/goals/barge-in.json`, printing a
   PASS / FAIL / INCONCLUSIVE / DEVICE-ONLY line per criterion.
3. Report the verdict and the per-criterion table. If any gating criterion FAILS,
   state which and by how much. Never call the goal met on a simulator run.

## What is measured where

| Criterion | simulator | device |
|-----------|-----------|--------|
| Barge-in reaction latency (median, p95) | proxy (real-time-paced injection) | true |
| Detection recall | yes (real VAD + detector) | true |
| Noise/echo false-positive rate | partial (sim VAD may be energy-based) | true |
| Command-vs-engagement macro F1 | yes (classifier on known text) | true (real STT transcript) |
| STT time-to-first-partial | device-only | true (real streaming STT) |

The harness uses no STT: on the simulator it classifies each TTS clip's known
text (isolating the classifier), and STT time-to-first-partial is measured on
device by the streaming-STT workstream. This keeps the harness off Apple Speech.

## Success Criteria

- **PASS:** every gating criterion meets its target with at least its
  `min_samples`. On `quick`, INCONCLUSIVE (too few samples) is allowed.
- **FAIL:** any gating criterion misses its target, or (on `full`/`device`) is
  INCONCLUSIVE for lack of samples.
- Exit code `0` = pass, `1` = fail, `2` = setup error (no simulator/device).

## When to Run

- After any change to the barge-in path (`BargeInDetector`, VAD config, thresholds).
- Before claiming the barge-in goal is met (requires a passing `device` run).
- As a regression gate when adopting a new STT or wiring barge-in into a new surface.

## Examples

```
User: /measure-barge-in quick
Claude: Barge-in measurement: mode=quick ...
  Barge-in goal: Single reliable barge-in + speech pipeline  (mode=simulator, tier=target)
  clips=4 positives=3 negatives=1 detected=3 falsePos=0 classified=3
  ------------------------------------------------------------------------
  PASS Barge-in reaction latency (median) (gate): 96.0 ms (target <= 300)
  PASS Detection recall (gate): 1.000  (target >= 0.95)  [INCONCLUSIVE if < min_samples]
  PASS Command-vs-engagement accuracy (gate): 1.000 (target >= 0.90)
  DEVICE-ONLY STT time-to-first-partial (gate): measured on device only
  ------------------------------------------------------------------------
  MEASUREMENT PASSED  (simulator proxy; device run is the goal's source of truth)
```

## Related

- Goal + targets: `.claude/goals/barge-in.json`
- Harness: `UnaMentis/Testing/BargeInHarness/`
- Detector (the single pipeline): `UnaMentis/Core/Audio/BargeInDetector.swift`
- Classifier: `UnaMentis/Core/Audio/BargeInClassifier.swift`
