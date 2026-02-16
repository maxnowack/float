#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHROME_DIR="$ROOT_DIR/chrome"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"

"$ROOT_DIR/scripts/build-chrome.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "error: node is required to read extension metadata for packaging." >&2
  exit 1
fi

pushd "$CHROME_DIR" >/dev/null

VERSION="$(node -p "require('./manifest.json').version")"
ARCHIVE_PATH="$ARTIFACTS_DIR/Float_chrome_extension_v${VERSION}.zip"

mkdir -p "$ARTIFACTS_DIR"
rm -f "$ARCHIVE_PATH"

if [[ ! -f manifest.json ]]; then
  echo "error: missing manifest.json in $CHROME_DIR" >&2
  exit 1
fi
if [[ ! -d dist ]]; then
  echo "error: missing dist/ in $CHROME_DIR" >&2
  exit 1
fi

INCLUDE_PATHS=(manifest.json dist)
if [[ -d icons ]]; then
  INCLUDE_PATHS+=(icons)
fi
if [[ -d _locales ]]; then
  INCLUDE_PATHS+=(_locales)
fi
if [[ -f LICENSE ]]; then
  INCLUDE_PATHS+=(LICENSE)
fi

zip -r -q "$ARCHIVE_PATH" "${INCLUDE_PATHS[@]}"

popd >/dev/null

echo "Packed Chrome extension: $ARCHIVE_PATH"
