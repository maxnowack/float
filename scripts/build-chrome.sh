#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHROME_DIR="$ROOT_DIR/chrome"

if ! command -v yarn >/dev/null 2>&1; then
  echo "error: yarn is required to build the Chrome extension." >&2
  exit 1
fi

pushd "$CHROME_DIR" >/dev/null
yarn build
popd >/dev/null

echo "Built Chrome extension: $CHROME_DIR/dist"
