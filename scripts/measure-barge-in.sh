#!/usr/bin/env bash
#
# measure-barge-in.sh - Run the barge-in measurement harness and grade it
# against the goal criteria in .claude/goals/barge-in.json.
#
# Usage:
#   scripts/measure-barge-in.sh quick           # full seed, lenient grading (INCONCLUSIVE allowed)
#   scripts/measure-barge-in.sh full            # full seed, strict grading
#   scripts/measure-barge-in.sh baseline <name> # full run, also saved as a baseline
#   scripts/measure-barge-in.sh compare <name>  # full run, diffed against a saved baseline
#
# Env:
#   SIMULATOR  Simulator name (default "iPhone 17 Pro")
#
# This runs the INJECTION harness on the simulator: it feeds generated audio into
# the real VAD + BargeInDetector and grades detection, reaction latency, noise
# rejection, and command-vs-engagement classification. It does NOT exercise the
# microphone, speaker echo, or hardware latency. The goal's source of truth is a
# real-acoustic DEVICE run (mic + speaker + echo) plus the real streaming STT;
# that is a separate workstream (see .claude/goals/barge-in.json authority).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GOAL_FILE="$PROJECT_DIR/.claude/goals/barge-in.json"
RESULTS_DIR="$PROJECT_DIR/build/barge-in-results"
BASELINE_DIR="$PROJECT_DIR/.claude/baselines/barge-in"
LATEST="$RESULTS_DIR/latest.json"
SIMULATOR="${SIMULATOR:-iPhone 17 Pro}"

MODE="${1:-quick}"
BASELINE_NAME="${2:-default}"
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'

STRICT=1
case "$MODE" in
  quick) STRICT=0 ;;
  full|baseline|compare) STRICT=1 ;;
  device)
    echo "${YELLOW}device mode is not implemented here.${NC}"
    echo "This script measures the simulator INJECTION proxy. The goal's source of"
    echo "truth is a real-acoustic device run (mic + speaker + echo) with the real"
    echo "streaming STT - a separate workstream. See .claude/goals/barge-in.json."
    exit 2 ;;
  *)
    echo "Unknown mode: $MODE"; echo "Use: quick | full | baseline <name> | compare <name>"; exit 2 ;;
esac

mkdir -p "$RESULTS_DIR"
rm -f "$LATEST"

SIM_ID="$(xcrun simctl list devices available 2>/dev/null | grep "$SIMULATOR (" | head -1 | grep -oE '[0-9A-F-]{36}' | head -1 || true)"
if [[ -n "$SIM_ID" ]]; then DESTINATION="platform=iOS Simulator,id=$SIM_ID"; else DESTINATION="platform=iOS Simulator,name=$SIMULATOR"; fi
echo "Barge-in measurement: mode=$MODE destination=$DESTINATION"

# Run the emit test, which writes the result JSON to $LATEST (path derived from
# its own source file via #filePath; env vars do not reach the simulator test).
LOG="$(mktemp)"; trap 'rm -f "$LOG"' EXIT
set +e
xcodebuild test \
  -project "$PROJECT_DIR/UnaMentis.xcodeproj" -scheme UnaMentis \
  -destination "$DESTINATION" \
  -only-testing:UnaMentisTests/BargeInMeasurementTests/testEmitMeasurementJSON \
  CODE_SIGNING_ALLOWED=NO SWIFT_STRICT_CONCURRENCY=complete \
  >"$LOG" 2>&1
RC=$?
set -e
if [[ ! -f "$LATEST" ]]; then
  echo "${RED}No measurement JSON produced (xcodebuild rc=$RC). Test output tail:${NC}"
  tail -25 "$LOG"
  exit 1
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
cp "$LATEST" "$RESULTS_DIR/$MODE-$TS.json"
echo "Wrote $RESULTS_DIR/$MODE-$TS.json"

if [[ "$MODE" == "baseline" ]]; then
  mkdir -p "$BASELINE_DIR"; cp "$LATEST" "$BASELINE_DIR/$BASELINE_NAME.json"
  echo "Saved baseline '$BASELINE_NAME'"
fi
BASELINE_JSON=""
if [[ "$MODE" == "compare" && -f "$BASELINE_DIR/$BASELINE_NAME.json" ]]; then
  BASELINE_JSON="$(cat "$BASELINE_DIR/$BASELINE_NAME.json")"
fi

RESULT_JSON="$(cat "$LATEST")" GOAL_FILE="$GOAL_FILE" STRICT="$STRICT" \
BASELINE_JSON="$BASELINE_JSON" RED="$RED" GREEN="$GREEN" YELLOW="$YELLOW" NC="$NC" \
python3 - <<'PY'
import json, os, sys

result = json.loads(os.environ["RESULT_JSON"])
goal = json.load(open(os.environ["GOAL_FILE"]))
strict = os.environ.get("STRICT") == "1"
RED, GREEN, YELLOW, NC = (os.environ[k] for k in ("RED","GREEN","YELLOW","NC"))
baseline = os.environ.get("BASELINE_JSON") or ""
baseline = json.loads(baseline) if baseline.strip() else None

m = result["metrics"]
FIELD = {
  "barge_in_reaction_latency_ms_median": ("reactionMsMedian", "detectedCount"),
  "barge_in_reaction_latency_ms_p95": ("reactionMsP95", "detectedCount"),
  "stt_time_to_first_partial_ms_median": ("sttFirstPartialMsMedian", "firstPartialSamples"),
  "detection_recall": ("detectionRecall", "positiveSamples"),
  "noise_echo_false_positive_rate": ("falsePositiveRate", "negativeSamples"),
  "command_vs_engagement_macro_f1": ("commandVsEngagementMacroF1", "classifiedSamples"),
}
def measured(crit):
    cid = crit["id"]
    if cid == "peak_memory_mb": return result.get("peakMemoryMB")
    if cid == "thermal_state": return result.get("thermalState")
    f = FIELD.get(cid, (None,None))[0]
    return m.get(f) if f else None
def samples(crit):
    sf = FIELD.get(crit["id"], (None,None))[1]
    return m.get(sf) if sf else None
def cmp_ok(op, v, t): return v <= t if op == "<=" else v >= t

THERMAL = {"nominal":0,"fair":1,"serious":2,"critical":3}
print(f"\n  Barge-in goal: {goal['title']}  (mode={result['mode']}, tier={goal['tier']})")
print(f"  clips={result['clipCount']} positives={m['positiveSamples']} negatives={m['negativeSamples']} "
      f"detected={m['detectedCount']} falsePos={m['falsePositiveCount']} classified={m['classifiedSamples']}")
print("  " + "-"*72)

fail = False
for crit in goal["criteria"]:
    val = measured(crit); op = crit["comparison"]; target = crit["target"]
    gating = crit.get("gating", False); n = samples(crit); min_n = crit.get("min_samples")
    label = crit["label"]; unit = crit.get("unit",""); tag = "(gate)" if gating else "(advisory)"

    if crit.get("requires") == "device" and result["mode"] != "device":
        print(f"  {YELLOW}DEVICE-ONLY{NC} {label} {tag}: measured on device only (target {op} {target})")
        continue
    if crit["id"] == "thermal_state":
        ok = THERMAL.get(str(val),9) <= THERMAL.get(str(target),1)
        print(f"  {(GREEN+'PASS'+NC) if ok else (YELLOW+'WARN'+NC)} {label} {tag}: {val} (target {op} {target})"); continue
    if val is None:
        print(f"  {YELLOW}INCONCLUSIVE{NC} {label} {tag}: no data")
        if gating and strict: fail = True
        continue
    if min_n is not None and (n is None or n < min_n):
        print(f"  {YELLOW}INCONCLUSIVE{NC} {label} {tag}: {val:.3f} but only {n}/{min_n} samples")
        if gating and strict: fail = True
        continue

    ok = cmp_ok(op, val, target)
    if gating:
        verdict = (GREEN+"PASS"+NC) if ok else (RED+"FAIL"+NC)
        if not ok: fail = True
    else:
        verdict = (GREEN+"ok"+NC) if ok else (YELLOW+"WARN"+NC)
    shown = f"{val:.3f}" if isinstance(val,float) else str(val)
    delta = ""
    if baseline is not None:
        bf = FIELD.get(crit["id"], (None,None))[0]
        bval = baseline["metrics"].get(bf) if bf else None
        if isinstance(bval,(int,float)) and isinstance(val,(int,float)):
            delta = f"  (baseline {bval:.3f}, Δ {val-bval:+.3f})"
    print(f"  {verdict} {label} {tag}: {shown} {unit} (target {op} {target}){delta}")

print("  " + "-"*72)
if fail:
    print(f"  {RED}MEASUREMENT FAILED{NC} - a gating criterion missed or is INCONCLUSIVE"
          + ("" if strict else " (quick: INCONCLUSIVE allowed)"))
    sys.exit(1)
print(f"  {GREEN}MEASUREMENT PASSED{NC}  {YELLOW}(simulator injection proxy; the goal's source of truth is a real-acoustic device run){NC}")
PY
