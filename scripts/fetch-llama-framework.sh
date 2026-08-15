#!/bin/bash
# Fetches the prebuilt llama.xcframework the on-device LLM links against.
#
# The framework is large and gitignored, so a fresh clone cannot build until it
# is present: OnDeviceLLMService does `import llama` unconditionally and
# project.yml embeds it. CI fetches it inline; this is the local equivalent so a
# fresh pull on a dev machine does not fail with a confusing link error.
#
# Idempotent: exits early when a valid framework is already in place.
#
# Usage:
#   ./scripts/fetch-llama-framework.sh
#   LLAMA_BUILD=b9821 ./scripts/fetch-llama-framework.sh   # override the pinned build

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Keep in sync with .github/workflows/unit-tests.yml and integration.yml, which
# pin the same build. b9821 is the first build carrying the gemma4 architecture.
LLAMA_BUILD="${LLAMA_BUILD:-b9821}"

FRAMEWORK_DIR="$PROJECT_ROOT/UnaMentis/Frameworks"
FRAMEWORK="$FRAMEWORK_DIR/llama.xcframework"
URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_BUILD}/llama-${LLAMA_BUILD}-xcframework.zip"

if [ -d "$FRAMEWORK" ] && [ -f "$FRAMEWORK/Info.plist" ]; then
    echo "llama.xcframework already present at $FRAMEWORK"
    exit 0
fi

echo "Fetching llama.xcframework $LLAMA_BUILD ..."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! curl -fsSL -o "$TMP/llama.zip" "$URL"; then
    echo "Error: download failed from $URL"
    echo "Check the build tag, or set LLAMA_BUILD to one that exists."
    exit 1
fi

unzip -q "$TMP/llama.zip" -d "$TMP/unzipped"

EXTRACTED="$(find "$TMP/unzipped" -name llama.xcframework -type d -maxdepth 3 | head -1)"
if [ -z "$EXTRACTED" ]; then
    echo "Error: the archive did not contain llama.xcframework"
    exit 1
fi

mkdir -p "$FRAMEWORK_DIR"
rm -rf "$FRAMEWORK"
mv "$EXTRACTED" "$FRAMEWORK"

# Verify rather than assume: a partial extraction here becomes a confusing
# link failure much later.
if [ ! -f "$FRAMEWORK/Info.plist" ]; then
    echo "Error: installed framework is missing Info.plist"
    exit 1
fi

echo "Installed llama.xcframework $LLAMA_BUILD at $FRAMEWORK"
