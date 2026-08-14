#!/bin/bash
# Post-edit Swift lint hook for Claude Code
# Lints Swift files after editing
# Returns exit code 2 to report error, 0 on success

set -e

# Read stdin to get tool input
INPUT=$(cat)

# Extract the file path from the JSON input
FILE_PATH=$(echo "$INPUT" | python3 -c "import json, sys; data=json.load(sys.stdin); print(data.get('tool_input', {}).get('file_path', ''))" 2>/dev/null || echo "")

# Only check Swift files
if [[ "$FILE_PATH" == *.swift ]]; then
    cd "$CLAUDE_PROJECT_DIR" || exit 0

    # Check if swiftlint is available
    if ! command -v swiftlint &> /dev/null; then
        exit 0
    fi

    # SwiftLint's SourceKit backend crashes (Trace/BPT trap) when xcode-select
    # points at the Command Line Tools, and the crash reads as violations.
    # Resolve DEVELOPER_DIR to the installed Xcode in that case. The repo's
    # scripts share this logic via scripts/xcode-env.sh; the hook inlines it
    # because it must work from any target repo state.
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

    # Run swiftlint on the specific file (positional arg, not --path which is deprecated)
    if ! swiftlint lint "$FILE_PATH" --quiet --strict 2>/dev/null; then
        echo "SwiftLint violations in $FILE_PATH. Fix before committing." >&2
        exit 2
    fi
fi

exit 0
