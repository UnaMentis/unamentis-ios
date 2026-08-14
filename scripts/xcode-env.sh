#!/bin/bash
# Shared toolchain environment resolution, sourced by the local scripts that
# shell out to SwiftLint or xcodebuild (lint.sh, test-quick.sh, test-ci.sh,
# health-check.sh).
#
# SwiftLint's SourceKit backend and xcodebuild both need a full Xcode developer
# directory. On machines where xcode-select points at the Command Line Tools,
# SwiftLint crashes (Trace/BPT trap) and the failure reads as lint violations.
# Resolve DEVELOPER_DIR to the installed Xcode in that case, without changing
# the machine's xcode-select state.
#
# The fallback engages only when the active directory is the Command Line
# Tools, so a deliberately selected non-default Xcode (Xcode-beta.app or a
# versioned install) is respected. No-op on CI, which selects Xcode already.

if [ -z "${DEVELOPER_DIR:-}" ]; then
    ACTIVE_DEV_DIR=$(xcode-select -p 2>/dev/null || true)
    case "$ACTIVE_DEV_DIR" in
        *CommandLineTools*)
            if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
                export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
            fi
            ;;
    esac
fi

# True when at least one AVAILABLE iOS simulator runtime is installed. A
# machine can have Xcode yet no iOS runtimes (the platform is a separate
# multi-GB download), and a runtime can be listed yet unavailable; simulator
# tests cannot run in either case. The JSON listing's isAvailable flag is the
# authoritative signal. The JSON is captured into a variable first so no
# pipeline is involved under pipefail.
ios_simulator_runtimes_installed() {
    local runtimes_json
    runtimes_json=$(xcrun simctl list -j runtimes 2>/dev/null || true)
    [ -n "$runtimes_json" ] || return 1
    printf '%s' "$runtimes_json" | python3 -c '
import json, sys
try:
    runtimes = json.load(sys.stdin).get("runtimes", [])
except Exception:
    sys.exit(1)
ios_available = any(
    r.get("isAvailable") and (r.get("platform") == "iOS" or str(r.get("name", "")).startswith("iOS"))
    for r in runtimes
)
sys.exit(0 if ios_available else 1)
'
}
