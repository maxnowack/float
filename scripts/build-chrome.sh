#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTENSION_DIR="$ROOT_DIR/extension"
TARGET_DIR="$ROOT_DIR/build/chrome-extension"

if ! command -v yarn >/dev/null 2>&1; then
  echo "error: yarn is required to build the Chrome extension." >&2
  exit 1
fi

if [[ ! -d "$EXTENSION_DIR" ]]; then
  echo "error: missing extension directory at $EXTENSION_DIR" >&2
  exit 1
fi
if [[ ! -f "$EXTENSION_DIR/manifest.chrome.json" ]]; then
  echo "error: missing manifest.chrome.json at $EXTENSION_DIR/manifest.chrome.json" >&2
  exit 1
fi

rm -rf "$TARGET_DIR"
mkdir -p "$TARGET_DIR"

pushd "$EXTENSION_DIR" >/dev/null
yarn build:chrome
popd >/dev/null

cp -R "$EXTENSION_DIR/dist" "$TARGET_DIR/dist"
cp -R "$EXTENSION_DIR/icons" "$TARGET_DIR/icons"
cp "$EXTENSION_DIR/popup.html" "$TARGET_DIR/popup.html"
cp "$EXTENSION_DIR/popup.css" "$TARGET_DIR/popup.css"

if [[ ! -f "$TARGET_DIR/manifest.json" ]]; then
  echo "error: failed to generate chrome manifest at $TARGET_DIR/manifest.json" >&2
  exit 1
fi

echo "Built Chrome extension: $TARGET_DIR"
