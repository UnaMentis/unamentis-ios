#!/bin/bash
# Pre-commit check hook for Claude Code
#
# Lints and tests the repository the commit actually targets, not a fixed
# directory. In a multi-repo session a commit in one repo must never be blocked
# by an unrelated repo's lint or test state. The target repo is taken from an
# explicit directory in the command (a leading 'cd <dir>' or 'git -C <dir>'),
# falling back to CLAUDE_PROJECT_DIR.
#
# Returns exit code 2 to block, 0 to allow.

set -e

# Read stdin to get tool input
INPUT=$(cat)

# Extract the command from the JSON input
COMMAND=$(echo "$INPUT" | python3 -c "import json, sys; data=json.load(sys.stdin); print(data.get('tool_input', {}).get('command', ''))" 2>/dev/null || echo "")

# Only act on git commit commands
echo "$COMMAND" | grep -q "git commit" || exit 0

# Determine which repository the commit targets.
TARGET_DIR=$(printf '%s' "$COMMAND" | sed -nE 's/^[[:space:]]*cd[[:space:]]+"?([^"&|;]+)"?.*/\1/p' | head -1)
if [ -z "$TARGET_DIR" ]; then
    TARGET_DIR=$(printf '%s' "$COMMAND" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+"?([^"&|;[:space:]]+)"?.*/\1/p' | head -1)
fi
[ -z "$TARGET_DIR" ] && TARGET_DIR="$CLAUDE_PROJECT_DIR"
TARGET_DIR=$(printf '%s' "$TARGET_DIR" | sed -E 's/[[:space:]]+$//')
[ -z "$TARGET_DIR" ] && exit 0

cd "$TARGET_DIR" 2>/dev/null || exit 0
# Resolve to the git repo root so the scripts run at the right place.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -z "$REPO_ROOT" ] && exit 0
cd "$REPO_ROOT" 2>/dev/null || exit 0

echo "Running pre-commit checks in $REPO_ROOT ..." >&2

# On non-macOS platforms, skip checks that require Xcode/SwiftLint
export SKIP_LINT_IF_UNAVAILABLE=true
export SKIP_TESTS_IF_UNAVAILABLE=true

# Run lint check (only if this repo provides one)
if [ -x ./scripts/lint.sh ]; then
    if ! ./scripts/lint.sh >/dev/null 2>&1; then
        echo "BLOCKED: Lint violations in $REPO_ROOT. Run ./scripts/lint.sh to see issues." >&2
        exit 2
    fi
fi

# Run quick tests (only if this repo provides them)
if [ -x ./scripts/test-quick.sh ]; then
    if ! ./scripts/test-quick.sh >/dev/null 2>&1; then
        echo "BLOCKED: Unit tests failed in $REPO_ROOT. Run ./scripts/test-quick.sh to see failures." >&2
        exit 2
    fi
fi

echo "Pre-commit checks passed!" >&2
exit 0
