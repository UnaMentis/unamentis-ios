#!/bin/bash
# Enforces the single voice pipeline rule.
#
# THE RULE: application code never constructs a concrete speech engine. It asks
# the one resolver for a pipeline. See docs/ios/VOICE_PIPELINE.md.
#
# Direct construction is how the pipeline fragmented: each site that builds its
# own engine also invents its own failure policy, its own provider switch, and
# its own lifecycle. Five separate TTS resolution sites existed on 2026-08-15,
# each behaving differently when the engine failed.
#
# This is a RATCHET, not a snapshot. The baseline records how many direct
# constructions each file still has. A file may only ever get better:
#   - a new file constructing engines            -> FAIL
#   - an existing file's count going up          -> FAIL
#   - a count going down                         -> PASS, and asks you to update the baseline
# So the debt can only shrink, and no new debt can be added while it does.
#
# Usage:
#   ./scripts/check-voice-pipeline.sh            # enforce (CI and lint use this)
#   ./scripts/check-voice-pipeline.sh --update   # rewrite the baseline after a real reduction
#   ./scripts/check-voice-pipeline.sh --list     # show every current construction site

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BASELINE="$PROJECT_ROOT/.voice-pipeline-baseline"

cd "$PROJECT_ROOT"

# Concrete engines that only the resolver may build.
PATTERN='KyutaiPocketTTSService\(|AppleTTSService\(|ElevenLabsTTSService\(|DeepgramTTSService\(|SelfHostedTTSService\.|ChatterboxTTSService\.|AppleSpeechSTTService\(|GLMASROnDeviceSTTService\(|DeepgramSTTService\(|AssemblyAISTTService\(|SileroVADService\(|FluidAudioVADService\('

# Paths that legitimately construct engines: the implementations themselves and
# the resolver that owns the choice.
is_allowed_path() {
    case "$1" in
        UnaMentis/Services/TTS/*|UnaMentis/Services/STT/*|UnaMentis/Services/VAD/*) return 0 ;;
        UnaMentis/Services/Protocols/TTSService.swift) return 0 ;;
        UnaMentis/Services/Protocols/STTService.swift) return 0 ;;
        UnaMentis/Services/Protocols/VADService.swift) return 0 ;;
        UnaMentis/Core/Audio/VoicePipeline*.swift) return 0 ;;
        *) return 1 ;;
    esac
}

# Emit "count<TAB>path" for every offending file. A line carrying an explicit
# VOICE-PIPELINE-EXEMPT comment is deliberate and does not count.
current_counts() {
    grep -rEn "$PATTERN" --include="*.swift" UnaMentis/ 2>/dev/null \
        | grep -v "VOICE-PIPELINE-EXEMPT" \
        | cut -d: -f1 \
        | while read -r path; do is_allowed_path "$path" || echo "$path"; done \
        | sort | uniq -c | awk '{print $1"\t"$2}' | sort -k2
}

list_sites() {
    grep -rEn "$PATTERN" --include="*.swift" UnaMentis/ 2>/dev/null \
        | grep -v "VOICE-PIPELINE-EXEMPT" \
        | while IFS= read -r line; do
            path="${line%%:*}"
            is_allowed_path "$path" || echo "$line"
        done
}

if [ "${1:-}" = "--list" ]; then
    list_sites
    exit 0
fi

CURRENT="$(current_counts)"

if [ "${1:-}" = "--update" ]; then
    {
        echo "# Direct voice-engine construction outside the resolver."
        echo "# Format: <count><TAB><path>. This may only ever shrink."
        echo "# See docs/ios/VOICE_PIPELINE.md. Regenerate with:"
        echo "#   ./scripts/check-voice-pipeline.sh --update"
        echo "$CURRENT"
    } > "$BASELINE"
    echo "Baseline updated. Files still constructing engines directly:"
    echo "$CURRENT"
    exit 0
fi

if [ ! -f "$BASELINE" ]; then
    echo "Error: $BASELINE is missing. Create it with:"
    echo "  ./scripts/check-voice-pipeline.sh --update"
    exit 1
fi

BASE="$(grep -v '^#' "$BASELINE" | grep -v '^[[:space:]]*$' || true)"

FAILED=0
IMPROVED=0

# Anything new, or worse than baseline, fails.
while IFS=$'\t' read -r count path; do
    [ -z "${path:-}" ] && continue
    base_count="$(echo "$BASE" | awk -F'\t' -v p="$path" '$2==p {print $1}')"
    if [ -z "$base_count" ]; then
        echo "FAIL: $path constructs a voice engine directly and is not in the baseline."
        echo "      Ask the resolver for a pipeline instead. See docs/ios/VOICE_PIPELINE.md."
        FAILED=1
    elif [ "$count" -gt "$base_count" ]; then
        echo "FAIL: $path went from $base_count to $count direct constructions."
        echo "      The baseline may only shrink. See docs/ios/VOICE_PIPELINE.md."
        FAILED=1
    elif [ "$count" -lt "$base_count" ]; then
        echo "Improved: $path is down from $base_count to $count."
        IMPROVED=1
    fi
done <<< "$CURRENT"

# A file that left the list entirely is also an improvement.
while IFS=$'\t' read -r base_count path; do
    [ -z "${path:-}" ] && continue
    if ! echo "$CURRENT" | awk -F'\t' -v p="$path" '$2==p {found=1} END {exit !found}'; then
        echo "Improved: $path no longer constructs engines directly."
        IMPROVED=1
    fi
done <<< "$BASE"

if [ $FAILED -eq 1 ]; then
    echo ""
    echo "The single voice pipeline rule was violated."
    echo "Application code asks the resolver for a pipeline; it never builds an engine."
    echo "If a construction is genuinely unavoidable, annotate the line:"
    echo "    // VOICE-PIPELINE-EXEMPT: <reason>"
    exit 1
fi

if [ $IMPROVED -eq 1 ]; then
    echo ""
    echo "Debt went down. Lock it in:  ./scripts/check-voice-pipeline.sh --update"
fi

echo "Voice pipeline check passed."
