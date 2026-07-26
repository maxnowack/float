#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-Release}"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
PROJECT_PATH="$ROOT_DIR/companion/Float.xcodeproj"
SCHEME="Float"
NOTARY_PROFILE="${FLOAT_NOTARY_PROFILE:-}"
SIGNING_IDENTITY="${FLOAT_CODE_SIGN_IDENTITY:-}"
NOTARIZED_RELEASE=0
TEMP_DIR=""

case "$CONFIGURATION" in
  Debug|Release)
    ;;
  *)
    echo "error: configuration must be Debug or Release (got: $CONFIGURATION)." >&2
    exit 1
    ;;
esac

if [[ -n "$NOTARY_PROFILE" || -n "$SIGNING_IDENTITY" ]]; then
  if [[ "$CONFIGURATION" != "Release" ]]; then
    echo "error: notarized packaging requires the Release configuration." >&2
    exit 1
  fi
  if [[ -z "$NOTARY_PROFILE" || -z "$SIGNING_IDENTITY" ]]; then
    echo "error: set both FLOAT_NOTARY_PROFILE and FLOAT_CODE_SIGN_IDENTITY for notarized packaging." >&2
    exit 1
  fi
  case "$SIGNING_IDENTITY" in
    "Developer ID Application:"*) ;;
    *)
      echo "error: FLOAT_CODE_SIGN_IDENTITY must be a Developer ID Application identity." >&2
      exit 1
      ;;
  esac
  NOTARIZED_RELEASE=1
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/float-release.XXXXXX")"
  trap 'rm -rf "$TEMP_DIR"' EXIT
fi

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
  local derived_data_path
  derived_data_path="$(derived_data_for_arch "$arch")"
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -sdk macosx \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$derived_data_path" \
    "ARCHS=$arch" \
    ONLY_ACTIVE_ARCH=NO \
    -showBuildSettings
}

derived_data_for_arch() {
  local arch="$1"
  echo "$ROOT_DIR/.xcodebuild/pack-${CONFIGURATION}-${arch}"
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

signing_team_identifier() {
  codesign -d --verbose=4 "$1" 2>&1 \
    | awk -F= '/^TeamIdentifier=/{ print $2; exit }'
}

verify_release_app() {
  local app_path="$1"
  local require_gatekeeper="$2"
  local signature_details
  local app_team
  local entitlement_dump="$TEMP_DIR/entitlements.plist"
  local forbidden_entitlement
  local required_entitlement

  codesign --verify --deep --strict --verbose=4 "$app_path"
  signature_details="$(codesign -d --verbose=4 "$app_path" 2>&1)"
  grep -Fq "Authority=$SIGNING_IDENTITY" <<<"$signature_details" \
    || {
      echo "error: app is not signed with the requested Developer ID Application identity: $app_path" >&2
      exit 1
    }
  grep -Eq 'flags=.*\\(runtime\\)' <<<"$signature_details" \
    || {
      echo "error: Hardened Runtime flag is missing: $app_path" >&2
      exit 1
    }

  app_team="$(signing_team_identifier "$app_path")"
  if [[ -z "$app_team" || "$app_team" == "not set" ]]; then
    echo "error: app signature has no Team Identifier: $app_path" >&2
    exit 1
  fi

  while IFS= read -r framework_path; do
    local framework_team
    codesign --verify --strict --verbose=4 "$framework_path"
    framework_team="$(signing_team_identifier "$framework_path")"
    if [[ "$framework_team" != "$app_team" ]]; then
      echo "error: embedded framework Team Identifier does not match app: $framework_path" >&2
      exit 1
    fi
  done < <(
    find "$app_path/Contents/Frameworks" \
      -type d -name '*.framework' -prune 2>/dev/null | sort
  )

  codesign -d --entitlements :- "$app_path" >"$entitlement_dump" 2>/dev/null
  for forbidden_entitlement in \
    com.apple.security.get-task-allow \
    com.apple.security.device.audio-input \
    com.apple.security.device.camera \
    com.apple.security.device.screen-capture \
    com.apple.security.accessibility \
    com.apple.security.automation.apple-events \
    com.apple.security.cs.disable-library-validation \
    com.apple.security.cs.allow-unsigned-executable-memory \
    com.apple.security.cs.disable-executable-page-protection \
    com.apple.security.cs.allow-dyld-environment-variables
  do
    if /usr/libexec/PlistBuddy \
      -c "Print :$forbidden_entitlement" "$entitlement_dump" \
      >/dev/null 2>&1
    then
      echo "error: forbidden release entitlement present: $forbidden_entitlement" >&2
      exit 1
    fi
  done

  for required_entitlement in \
    com.apple.security.app-sandbox \
    com.apple.security.network.client \
    com.apple.security.network.server
  do
    if [[ "$(
      /usr/libexec/PlistBuddy \
        -c "Print :$required_entitlement" "$entitlement_dump" 2>/dev/null
    )" != "true" ]]; then
      echo "error: required release entitlement missing: $required_entitlement" >&2
      exit 1
    fi
  done

  if [[ "$require_gatekeeper" == "1" ]]; then
    xcrun stapler validate "$app_path"
    spctl --assess --type execute --verbose=4 "$app_path"
  fi
}

for arch in arm64 x86_64; do
  FLOAT_DERIVED_DATA_PATH="$(derived_data_for_arch "$arch")" \
    "$ROOT_DIR/scripts/build-companion.sh" "$CONFIGURATION" "$arch"
done

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
  if [[ "$NOTARIZED_RELEASE" == "1" ]]; then
    NOTARY_UPLOAD="$TEMP_DIR/Float_companion_$(arch_label "$arch")_notary.zip"
    NOTARY_RESULT="$TEMP_DIR/Float_companion_$(arch_label "$arch")_notary.json"
    verify_release_app "$APP_PATH" 0
    ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARY_UPLOAD"
    xcrun notarytool submit \
      "$NOTARY_UPLOAD" \
      --keychain-profile "$NOTARY_PROFILE" \
      --wait \
      --output-format json >"$NOTARY_RESULT"
    if [[ "$(
      /usr/bin/plutil -extract status raw -o - "$NOTARY_RESULT" 2>/dev/null
    )" != "Accepted" ]]; then
      echo "error: Apple notarization did not return Accepted for architecture $arch." >&2
      cat "$NOTARY_RESULT" >&2
      exit 1
    fi
    xcrun stapler staple "$APP_PATH"
    verify_release_app "$APP_PATH" 1
  fi
  rm -f "$ARCHIVE_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
  echo "Packed companion app ($arch): $ARCHIVE_PATH"
done
