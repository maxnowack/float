#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIREFOX_BUILD_DIR="$ROOT_DIR/build/firefox-extension"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"

"$ROOT_DIR/scripts/build-firefox.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "error: node is required to read extension metadata for packaging." >&2
  exit 1
fi

pushd "$FIREFOX_BUILD_DIR" >/dev/null

VERSION="$(node -p "require('./manifest.json').version")"
ARCHIVE_PATH="$ARTIFACTS_DIR/Float_firefox_extension_v${VERSION}.zip"

mkdir -p "$ARTIFACTS_DIR"
rm -f "$ARCHIVE_PATH"

if [[ ! -f manifest.json ]]; then
  echo "error: missing manifest.json in $FIREFOX_BUILD_DIR" >&2
  exit 1
fi
if [[ ! -d dist ]]; then
  echo "error: missing dist/ in $FIREFOX_BUILD_DIR" >&2
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

echo "Packed Firefox extension: $ARCHIVE_PATH"
