#!/bin/bash
# Creates symlink to shared models folder for local development.
# CI environments create placeholder files instead (see .github/workflows/ios.yml).
#
# Usage:
#   ./scripts/setup-models.sh
#   UNAMENTIS_MODELS_PATH=/custom/path ./scripts/setup-models.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
MODELS_DIR="${UNAMENTIS_MODELS_PATH:-/Users/ramerman/dev/unamentis-models}"

if [ ! -d "$MODELS_DIR" ]; then
    echo "Error: Models directory not found at $MODELS_DIR"
    echo "Either create it or set UNAMENTIS_MODELS_PATH to the correct location."
    exit 1
fi

# Create or update symlink
if [ -L "$PROJECT_ROOT/models" ]; then
    echo "Updating existing models symlink..."
    rm "$PROJECT_ROOT/models"
elif [ -d "$PROJECT_ROOT/models" ]; then
    echo "Warning: models/ is a real directory, not a symlink. Skipping."
    echo "Remove it manually if you want to use the shared models folder."
    exit 0
fi

ln -s "$MODELS_DIR" "$PROJECT_ROOT/models"
echo "Models symlink created: models -> $MODELS_DIR"

# Verify key files exist
if [ -f "$PROJECT_ROOT/models/Models/model.safetensors" ]; then
    echo "PocketTTS models found."
else
    echo "Warning: PocketTTS models not found in $MODELS_DIR/Models/"
fi
