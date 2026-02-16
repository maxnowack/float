#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE="origin"
COMPANION_CONFIGURATION="Release"
TAG=""
TITLE=""
PRERELEASE=0
DRAFT=0
SKIP_CONFIRM=0

usage() {
  cat <<'EOF'
Usage:
  ./scripts/release.sh --tag <tag> [options]

Options:
  --tag <tag>                 Git tag to create (required), e.g. v0.2.0
  --title <title>             GitHub release title (default: tag value)
  --remote <remote>           Git remote to push tag to (default: origin)
  --config <Debug|Release>    Companion build configuration (default: Release)
  --prerelease                Mark GitHub release as prerelease
  --draft                     Create GitHub release as draft
  --yes                       Skip confirmation prompt
  -h, --help                  Show this help

What this script does:
  1. Verifies the working tree is clean.
  2. Bumps extension + companion versions from --tag and increments build number.
  3. Creates a version-bump commit.
  4. Builds and packages extension + companion artifacts.
  5. Creates and pushes a new annotated git tag.
  6. Creates a GitHub release for that tag via gh CLI.
  7. Uploads packaged artifacts to that release.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

need_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
}

ensure_clean_worktree() {
  git update-index -q --refresh || true
  if [[ -n "$(git status --porcelain)" ]]; then
    git status --short
    die "working tree is not clean"
  fi
}

version_from_tag() {
  local tag="$1"
  local version="${tag#v}"
  if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' "$version"
    return 0
  fi
  return 1
}

next_companion_build_number() {
  local current
  current="$(
    rg -N -m 1 --no-heading "CURRENT_PROJECT_VERSION = [0-9]+;" \
      "$ROOT_DIR/companion/Float.xcodeproj/project.pbxproj" \
      | sed -E 's/.*= ([0-9]+);/\1/'
  )"
  [[ "$current" =~ ^[0-9]+$ ]] || die "failed to read CURRENT_PROJECT_VERSION"
  printf '%s\n' "$((current + 1))"
}

bump_versions() {
  local version="$1"
  local build_number="$2"

  node -e '
const fs = require("fs");
const [manifestPath, packagePath, version] = process.argv.slice(1);
for (const path of [manifestPath, packagePath]) {
  const data = JSON.parse(fs.readFileSync(path, "utf8"));
  data.version = version;
  fs.writeFileSync(path, `${JSON.stringify(data, null, 2)}\n`);
}
' \
    "$ROOT_DIR/chrome/manifest.json" \
    "$ROOT_DIR/chrome/package.json" \
    "$version"

  perl -i -pe "s/MARKETING_VERSION = [0-9]+\\.[0-9]+\\.[0-9]+;/MARKETING_VERSION = $version;/g" \
    "$ROOT_DIR/companion/Float.xcodeproj/project.pbxproj"

  perl -i -pe "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $build_number;/g" \
    "$ROOT_DIR/companion/Float.xcodeproj/project.pbxproj"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      [[ $# -ge 2 ]] || die "--tag requires a value"
      TAG="$2"
      shift 2
      ;;
    --title)
      [[ $# -ge 2 ]] || die "--title requires a value"
      TITLE="$2"
      shift 2
      ;;
    --remote)
      [[ $# -ge 2 ]] || die "--remote requires a value"
      REMOTE="$2"
      shift 2
      ;;
    --config)
      [[ $# -ge 2 ]] || die "--config requires a value"
      COMPANION_CONFIGURATION="$2"
      shift 2
      ;;
    --prerelease)
      PRERELEASE=1
      shift
      ;;
    --draft)
      DRAFT=1
      shift
      ;;
    --yes)
      SKIP_CONFIRM=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$TAG" ]] || {
  usage
  die "--tag is required"
}

case "$COMPANION_CONFIGURATION" in
  Debug|Release) ;;
  *)
    die "--config must be Debug or Release (got: $COMPANION_CONFIGURATION)"
    ;;
esac

if [[ -z "$TITLE" ]]; then
  TITLE="$TAG"
fi

need_cmd git
need_cmd gh
need_cmd node
need_cmd perl
need_cmd rg

cd "$ROOT_DIR"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"
git rev-parse --verify HEAD >/dev/null 2>&1 || die "repository has no commits"
git remote get-url "$REMOTE" >/dev/null 2>&1 || die "git remote '$REMOTE' not found"
gh auth status >/dev/null 2>&1 || die "gh CLI is not authenticated (run: gh auth login)"

ensure_clean_worktree

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  die "tag already exists locally: $TAG"
fi

if git ls-remote --exit-code --tags "$REMOTE" "refs/tags/$TAG" >/dev/null 2>&1; then
  die "tag already exists on remote '$REMOTE': $TAG"
fi

VERSION="$(version_from_tag "$TAG")" || die "--tag must map to semver (e.g. v0.2.0 or 0.2.0)"
BUILD_NUMBER="$(next_companion_build_number)"
CURRENT_COMMIT="$(git rev-parse --short HEAD)"
echo "Preparing release for commit: $CURRENT_COMMIT"
echo "Tag: $TAG"
echo "Version: $VERSION"
echo "Companion build number: $BUILD_NUMBER"
echo "Remote: $REMOTE"
echo "Companion config: $COMPANION_CONFIGURATION"

if [[ "$SKIP_CONFIRM" -ne 1 ]]; then
  read -r -p "Continue? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) die "aborted" ;;
  esac
fi

bump_versions "$VERSION" "$BUILD_NUMBER"

git add \
  "$ROOT_DIR/chrome/manifest.json" \
  "$ROOT_DIR/chrome/package.json" \
  "$ROOT_DIR/companion/Float.xcodeproj/project.pbxproj"

if [[ -z "$(git diff --cached --name-only)" ]]; then
  die "version bump produced no changes"
fi

git commit -m "chore(release): bump version to $VERSION ($BUILD_NUMBER)"

# Avoid stale uploads from prior runs.
rm -f "$ROOT_DIR"/artifacts/*.zip 2>/dev/null || true

"$ROOT_DIR/scripts/pack-all.sh" "$COMPANION_CONFIGURATION"

mapfile -t ARTIFACTS < <(
  find "$ROOT_DIR/artifacts" -maxdepth 1 -type f -name '*.zip' 2>/dev/null | sort
)

if [[ "${#ARTIFACTS[@]}" -eq 0 ]]; then
  die "no packaged artifacts found under artifacts/"
fi

echo "Artifacts:"
for artifact in "${ARTIFACTS[@]}"; do
  echo "  - $artifact"
done

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" == "HEAD" ]]; then
  die "detached HEAD; cannot push version commit to remote branch"
fi

git push "$REMOTE" "refs/heads/$CURRENT_BRANCH"
git tag -a "$TAG" -m "Release $TAG"
git push "$REMOTE" "refs/tags/$TAG"

GH_RELEASE_ARGS=(
  release create "$TAG"
  --title "$TITLE"
  --generate-notes
)

if [[ "$PRERELEASE" -eq 1 ]]; then
  GH_RELEASE_ARGS+=(--prerelease)
fi

if [[ "$DRAFT" -eq 1 ]]; then
  GH_RELEASE_ARGS+=(--draft)
fi

GH_RELEASE_ARGS+=("${ARTIFACTS[@]}")

gh "${GH_RELEASE_ARGS[@]}"

echo "Release created successfully: $TAG"
