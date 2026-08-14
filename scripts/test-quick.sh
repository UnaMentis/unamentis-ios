#!/bin/bash
#
# test-quick.sh - Run unit tests quickly (no coverage enforcement)
#
# This is a convenience wrapper around test-ci.sh for local development.
# For CI-identical behavior, use test-ci.sh directly.
#

set -e
set -o pipefail
echo "Running quick tests..."

# Check if xcodebuild is available (macOS only)
if ! command -v xcodebuild &> /dev/null; then
    echo "WARNING: xcodebuild not available (requires macOS)"
    if [ "${SKIP_TESTS_IF_UNAVAILABLE:-false}" = "true" ]; then
        echo "SKIP_TESTS_IF_UNAVAILABLE=true, skipping tests"
        exit 0
    else
        echo "Install Xcode or set SKIP_TESTS_IF_UNAVAILABLE=true to skip"
        exit 1
    fi
fi

# Simulator tests need a full Xcode developer directory. On machines where
# xcode-select points at the Command Line Tools, resolve DEVELOPER_DIR to the
# installed Xcode without changing machine state. No-op on CI.
if [ -z "${DEVELOPER_DIR:-}" ]; then
    ACTIVE_DEV_DIR=$(xcode-select -p 2>/dev/null || true)
    if [[ "$ACTIVE_DEV_DIR" != *"Xcode.app"* ]] && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    fi
fi

# A machine can have Xcode yet no iOS simulator runtimes installed (the
# platform is a separate multi-GB download). Tests cannot run there at all,
# which is unavailability, not failure. Honor the skip flag in that case so
# pre-commit hooks fall through to CI as the test gate.
if ! xcrun simctl list runtimes 2>/dev/null | grep -q "iOS"; then
    echo "WARNING: no iOS simulator runtimes installed"
    if [ "${SKIP_TESTS_IF_UNAVAILABLE:-false}" = "true" ]; then
        echo "SKIP_TESTS_IF_UNAVAILABLE=true, skipping tests (CI runs them)"
        exit 0
    else
        echo "Install the iOS platform via Xcode Settings > Components, or set SKIP_TESTS_IF_UNAVAILABLE=true"
        exit 1
    fi
fi

# Resolve simulator to UUID for reliable destination matching
SIM_NAME="${SIMULATOR:-iPhone 17 Pro}"
SIM_UDID=$(xcrun simctl list devices available 2>/dev/null \
    | grep "$SIM_NAME" | head -1 \
    | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}')

if [ -n "$SIM_UDID" ]; then
    SIM_DEST="platform=iOS Simulator,id=$SIM_UDID"
else
    SIM_DEST="platform=iOS Simulator,name=$SIM_NAME"
fi

# Integration test classes to skip so this run covers unit tests only.
# xcodebuild test identifiers are TestBundle/TestClass with no folder
# component, so "-only-testing:UnaMentisTests/Unit" matches nothing and
# silently runs ZERO tests. Skipping each integration class is the reliable
# way to run the unit suite. Keep this list in sync with the XCTestCase
# classes under UnaMentisTests/Integration/ (some are currently excluded
# from the target in project.yml; listing them here is harmless and keeps
# the list valid when they are re-enabled).
INTEGRATION_TEST_CLASSES=(
    AudioPipelineIntegrationTests
    BargeInCoordinatorAudioPathTests
    BargeInMeasurementTests
    GLMASRIntegrationTests
    KBAnswerValidationIntegrationTests
    KBAudioTestHarnessTests
    KBSessionIntegrationTests
    LiveInferenceFullPathTests
    ThermalManagementIntegrationTests
    VoiceSessionIntegrationTests
)

SKIP_ARGS=()
for test_class in "${INTEGRATION_TEST_CLASSES[@]}"; do
    SKIP_ARGS+=("-skip-testing:UnaMentisTests/$test_class")
done

# Common xcodebuild arguments
XCODEBUILD_ARGS=(
    test
    -project UnaMentis.xcodeproj
    -scheme UnaMentis
    -destination "$SIM_DEST"
    "${SKIP_ARGS[@]}"
    CODE_SIGNING_ALLOWED=NO
)

# Run tests with or without xcbeautify
if command -v xcbeautify &> /dev/null; then
    xcodebuild "${XCODEBUILD_ARGS[@]}" | xcbeautify
else
    echo "Note: xcbeautify not installed, using raw xcodebuild output"
    xcodebuild "${XCODEBUILD_ARGS[@]}"
fi

echo "Quick tests passed"
