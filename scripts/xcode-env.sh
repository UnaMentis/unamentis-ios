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

# True when at least one iOS simulator runtime is installed. A machine can
# have Xcode yet no iOS runtimes (the platform is a separate multi-GB
# download); simulator tests cannot run there at all. The listing is captured
# into a variable first so no pipeline is involved: grep -q under pipefail can
# SIGPIPE the producer and report a false negative.
ios_simulator_runtimes_installed() {
    local runtimes
    runtimes=$(xcrun simctl list runtimes 2>/dev/null || true)
    [[ "$runtimes" == *"iOS"* ]]
}
