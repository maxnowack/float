#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/companion/Float.xcodeproj"
SCHEME="Float"
CONFIGURATION="${1:-Release}"
ARCHITECTURE="${2:-}"

case "$CONFIGURATION" in
  Debug|Release)
    ;;
  *)
    echo "error: configuration must be Debug or Release (got: $CONFIGURATION)." >&2
    exit 1
    ;;
esac

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "error: missing project at $PROJECT_PATH" >&2
  exit 1
fi

XCODEBUILD_ARGS=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -sdk macosx
)

if [[ -n "$ARCHITECTURE" ]]; then
  case "$ARCHITECTURE" in
    arm64|x86_64) ;;
    *)
      echo "error: architecture must be arm64 or x86_64 (got: $ARCHITECTURE)." >&2
      exit 1
      ;;
  esac
  XCODEBUILD_ARGS+=(-arch "$ARCHITECTURE")
fi

xcodebuild "${XCODEBUILD_ARGS[@]}" build

BUILD_SETTINGS="$(
  xcodebuild "${XCODEBUILD_ARGS[@]}" -showBuildSettings
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
  echo "error: companion build completed but app not found at $APP_PATH" >&2
  exit 1
fi

if [[ -n "$ARCHITECTURE" ]]; then
  echo "Built companion app ($ARCHITECTURE): $APP_PATH"
else
  echo "Built companion app: $APP_PATH"
fi
