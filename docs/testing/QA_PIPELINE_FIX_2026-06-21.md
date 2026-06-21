# QA Pipeline Fix (iOS)

**Date:** 2026-06-21
**Why:** The multi-layer QA pipeline (local validation, pre-commit hooks, overlapping CI) is a core defense of this AI-driven project against hallucinations and regressions. An audit found that two of the three layers were passing vacuously, so the defense was not actually defending. This records what was broken and what was fixed.

---

## What was broken

The earlier `QA_COVERAGE_AUDIT_REPORT.md` described iOS as "80% coverage enforced, EXEMPLARY, risk LOW." That was not true in practice. Three compounding defects:

1. **The test runner ran zero tests.** `scripts/test-ci.sh` used `-only-testing:UnaMentisTests/Unit`, but `Unit` is a folder, not a test class, so the filter matched nothing. The suite "passed" by running 0 tests. (Fixed in the 2026-06-10 work: it now enumerates and skips the integration classes, running the ~1,465 unit tests.)

2. **Coverage extraction read the wrong target.** It measured the `UnaMentis Watch App` target (always 0%), and a 0% reading was treated as "skip enforcement," so the 80% gate never fired. (Fixed 2026-06-10: it reads the `UnaMentis.app` target and treats an indeterminate reading as a failure under enforcement.)

3. **The pre-commit hook swallowed the test exit code.** `.hooks/pre-commit` ran `... ./scripts/test-ci.sh 2>&1 | tail -20`. Without `pipefail`, the `if` saw `tail`'s exit code (always 0), so test and coverage failures were silently reported as "iOS coverage check passed (80%+ achieved)." This is why commits with failing tests went through locally. (Fixed 2026-06-21, this document.)

Net effect: the local pre-commit layer reported success regardless of test results, and CI had been green-by-running-nothing until the runner was fixed, after which it correctly went red on real failures (and is currently blocked separately by exhausted macOS Actions minutes; see below).

---

## What was fixed (2026-06-21)

### Three failing unit tests (real issues, not test-bending)

- **`VoiceCommandRecognizerTests.testCommandInLongerPhrase`** exposed a real nondeterminism bug: "ready" and the filler "ok" both matched at confidence 1.0, and `recognize()` iterated an unordered `Set` with a strictly-greater comparison, so the winner depended on hash order. Fixed `recognize()` to iterate in a deterministic order and, on a confidence tie, prefer the longer (more specific) matched phrase, so "ready" beats "ok".
- **`OnDeviceLLMModelManagerTests.testManagerMarkLoadedAndUnloaded`** exposed a real bug: `markLoaded()` set `.loaded`, but the `init`-time `checkModelAvailability()` task and `refreshStateFromFilesystem()` both overwrote it to `.notDownloaded` when the file probe failed, so a model loaded in memory was reported as not-downloaded. Fixed both to preserve an in-memory `.loaded` state.
- **`ResponseIntentTests.testClassify_questionMarkers_returnsEngagement`** used two examples ("How does that happen?", "Can you tell me more?") that collide with deliberately-added keywords ("how does" is a clarification keyword; "you tell me" is a socratic keyword). The classifier was intentionally retuned; the test examples were stale. Replaced them with non-colliding question forms ("How can that be?", "Can you give an example?").

### The pre-commit hook now actually gates

`.hooks/pre-commit` no longer pipes `test-ci.sh` to `tail` (which swallowed the exit code). It redirects to a log and checks the real exit code, so a test failure or a coverage shortfall now blocks the commit. The hook and CI both call `test-ci.sh` with the same `COVERAGE_THRESHOLD`, so the layers agree.

### Coverage ratchet locked in

Real measured `UnaMentis.app` line coverage is now **12.0%** (up from ~2.3%, as the new provider/fallback code gained tests). The threshold was raised from 2 to **10** in both CI (`.github/workflows/ios.yml`) and the pre-commit hook, set just below measured so the gain cannot silently regress. This is a ratchet, not the goal; raise it as coverage grows toward the long-term target. The "80%" figure in older docs was aspirational and never enforced.

### Verification

`ENFORCE_COVERAGE=true TEST_TYPE=unit COVERAGE_THRESHOLD=10 ./scripts/test-ci.sh` exits 0: tests pass, coverage 12.0% meets the gate. The three previously-failing classes pass.

---

## The three layers, now

| Layer | Mechanism | State |
|-------|-----------|-------|
| Local validation | `scripts/test-quick.sh` / `test-ci.sh` (`set -o pipefail`, propagates failure) | Working |
| Pre-commit hook | `.hooks/pre-commit` -> `test-ci.sh` (exit code now checked) | Fixed |
| CI | `.github/workflows/ios.yml` -> `test-ci.sh` (same threshold) | Green once runners run; see billing |

---

## Still needs a human

- **macOS Actions minutes / spending limit.** Since ~2026-05-31, iOS CI jobs die at provisioning (zero steps, no runner assigned) on the private repo's `macos-15` runners. This is a billing/minutes issue, not code. Check GitHub -> org `UnaMentis` -> Settings -> Billing -> Actions.
- **Optional cost reduction (recommended, not yet applied because it cannot be CI-verified without runners):** move the `Lint` and `Hook Bypass Detection` jobs from `macos-15` to `ubuntu-latest` (SwiftLint and SwiftFormat have Linux builds; the hook-audit is a bash script). macOS bills at 10x; this would cut macOS minutes roughly in half without losing coverage.
- **Coverage is genuinely low (12%).** The gate is now honest and ratcheting, but most of the app (SessionManager, SessionView, many services) remains untested. Growing coverage is real, ongoing work.
