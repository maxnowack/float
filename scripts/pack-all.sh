#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-Release}"

"$ROOT_DIR/scripts/pack-chrome.sh"
"$ROOT_DIR/scripts/pack-firefox.sh"
"$ROOT_DIR/scripts/pack-companion.sh" "$CONFIGURATION"
