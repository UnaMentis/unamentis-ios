#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Running health check..."
echo ""

# Swift checks
echo "1. SwiftLint..."
swiftlint lint --strict
echo ""

echo "2. Swift quick tests..."
"$SCRIPT_DIR/test-quick.sh"
echo ""

echo "Health check passed!"
