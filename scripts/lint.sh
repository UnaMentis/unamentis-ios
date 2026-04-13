#!/bin/bash
set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "Running lint checks..."

FAILED=0

# Swift (SwiftLint)
echo ""
echo "1. SwiftLint (Swift)..."
if command -v swiftlint &> /dev/null; then
    if swiftlint lint --strict; then
        echo -e "${GREEN}SwiftLint passed${NC}"
    else
        echo -e "${RED}SwiftLint failed${NC}"
        FAILED=1
    fi
else
    echo -e "${YELLOW}WARNING: SwiftLint not installed${NC}"
    if [ "${SKIP_LINT_IF_UNAVAILABLE:-false}" = "true" ]; then
        echo "SKIP_LINT_IF_UNAVAILABLE=true, skipping SwiftLint"
    else
        echo "Install SwiftLint with: brew install swiftlint"
        FAILED=1
    fi
fi

# Swift (SwiftFormat --lint)
echo ""
echo "2. SwiftFormat (Swift)..."
if command -v swiftformat &> /dev/null; then
    if swiftformat --lint . 2>&1; then
        echo -e "${GREEN}SwiftFormat passed${NC}"
    else
        echo -e "${RED}SwiftFormat found formatting issues${NC}"
        FAILED=1
    fi
else
    echo -e "${YELLOW}WARNING: SwiftFormat not installed${NC}"
    if [ "${SKIP_LINT_IF_UNAVAILABLE:-false}" = "true" ]; then
        echo "SKIP_LINT_IF_UNAVAILABLE=true, skipping SwiftFormat"
    else
        echo "Install SwiftFormat with: brew install swiftformat"
        FAILED=1
    fi
fi

echo ""
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All lint checks passed!${NC}"
    exit 0
else
    echo -e "${RED}Some lint checks failed${NC}"
    exit 1
fi
