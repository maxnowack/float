#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-Release}"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
PROJECT_PATH="$ROOT_DIR/companion/Float.xcodeproj"
SCHEME="Float"

case "$CONFIGURATION" in
  Debug|Release)
    ;;
  *)
    echo "error: configuration must be Debug or Release (got: $CONFIGURATION)." >&2
    exit 1
    ;;
esac

arch_label() {
  case "$1" in
    arm64) echo "arm64" ;;
    x86_64) echo "x86_64" ;;
    *)
      echo "error: unsupported architecture '$1'" >&2
      exit 1
      ;;
  esac
}

build_settings_for_arch() {
  local arch="$1"
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -sdk macosx \
    -arch "$arch" \
    -showBuildSettings
}

target_build_dir_from_settings() {
  awk '
    /Build settings for action build and target Float:/ { in_target = 1; next }
    in_target && /TARGET_BUILD_DIR = / {
      sub(/^[^=]*= /, "", $0)
      print
      exit
    }
  '
}

full_product_name_from_settings() {
  awk '
    /Build settings for action build and target Float:/ { in_target = 1; next }
    in_target && /FULL_PRODUCT_NAME = / {
      sub(/^[^=]*= /, "", $0)
      print
      exit
    }
  '
}

"$ROOT_DIR/scripts/build-companion.sh" "$CONFIGURATION" arm64
"$ROOT_DIR/scripts/build-companion.sh" "$CONFIGURATION" x86_64

ARM64_SETTINGS="$(build_settings_for_arch arm64)"
TARGET_BUILD_DIR="$(
  target_build_dir_from_settings <<<"$ARM64_SETTINGS"
)"
FULL_PRODUCT_NAME="$(
  full_product_name_from_settings <<<"$ARM64_SETTINGS"
)"

if [[ -z "$TARGET_BUILD_DIR" || -z "$FULL_PRODUCT_NAME" ]]; then
  echo "error: failed to resolve companion build output path from Xcode settings." >&2
  exit 1
fi

INFO_PLIST="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME/Contents/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  echo "error: companion app Info.plist not found at $INFO_PLIST" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || echo "0.0.0")"

mkdir -p "$ARTIFACTS_DIR"

for arch in arm64 x86_64; do
  SETTINGS="$(build_settings_for_arch "$arch")"
  TARGET_BUILD_DIR="$(
    target_build_dir_from_settings <<<"$SETTINGS"
  )"
  FULL_PRODUCT_NAME="$(
    full_product_name_from_settings <<<"$SETTINGS"
  )"

  if [[ -z "$TARGET_BUILD_DIR" || -z "$FULL_PRODUCT_NAME" ]]; then
    echo "error: failed to resolve companion app path for architecture $arch." >&2
    exit 1
  fi

  APP_PATH="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"
  if [[ ! -d "$APP_PATH" ]]; then
    echo "error: companion app not found at $APP_PATH (architecture: $arch)" >&2
    exit 1
  fi

  ARCHIVE_PATH="$ARTIFACTS_DIR/Float_companion_v${VERSION}_macOS_$(arch_label "$arch").zip"
  rm -f "$ARCHIVE_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
  echo "Packed companion app ($arch): $ARCHIVE_PATH"
done
