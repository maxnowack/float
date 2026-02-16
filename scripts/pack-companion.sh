#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-Release}"
ARTIFACTS_DIR="$ROOT_DIR/artifacts/companion"
PROJECT_PATH="$ROOT_DIR/companion/Float.xcodeproj"
SCHEME="Float"

"$ROOT_DIR/scripts/build-companion.sh" "$CONFIGURATION"

BUILD_SETTINGS="$(
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -sdk macosx \
    -showBuildSettings
)"

TARGET_BUILD_DIR="$(
  awk '
    /Build settings for action build and target Float:/ { in_target = 1; next }
    in_target && /TARGET_BUILD_DIR = / {
      sub(/^[^=]*= /, "", $0)
      print
      exit
    }
  ' <<<"$BUILD_SETTINGS"
)"

FULL_PRODUCT_NAME="$(
  awk '
    /Build settings for action build and target Float:/ { in_target = 1; next }
    in_target && /FULL_PRODUCT_NAME = / {
      sub(/^[^=]*= /, "", $0)
      print
      exit
    }
  ' <<<"$BUILD_SETTINGS"
)"

if [[ -z "$TARGET_BUILD_DIR" || -z "$FULL_PRODUCT_NAME" ]]; then
  echo "error: failed to resolve companion build output path from Xcode settings." >&2
  exit 1
fi

APP_PATH="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: companion app not found at $APP_PATH" >&2
  exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || echo "0.0.0")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST" 2>/dev/null || echo "0")"

mkdir -p "$ARTIFACTS_DIR"
ARCHIVE_PATH="$ARTIFACTS_DIR/Float-v${VERSION}-${BUILD_NUMBER}-${CONFIGURATION}.zip"
rm -f "$ARCHIVE_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"

echo "Packed companion app: $ARCHIVE_PATH"
