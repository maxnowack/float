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
  2. Builds and packages extension + companion artifacts.
  3. Creates and pushes a new annotated git tag.
  4. Creates a GitHub release for that tag via gh CLI.
  5. Uploads packaged artifacts to that release.
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

CURRENT_COMMIT="$(git rev-parse --short HEAD)"
echo "Preparing release for commit: $CURRENT_COMMIT"
echo "Tag: $TAG"
echo "Remote: $REMOTE"
echo "Companion config: $COMPANION_CONFIGURATION"

if [[ "$SKIP_CONFIRM" -ne 1 ]]; then
  read -r -p "Continue? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) die "aborted" ;;
  esac
fi

# Avoid stale uploads from prior runs.
rm -f "$ROOT_DIR"/artifacts/chrome/*.zip "$ROOT_DIR"/artifacts/companion/*.zip 2>/dev/null || true

"$ROOT_DIR/scripts/pack-all.sh" "$COMPANION_CONFIGURATION"

ensure_clean_worktree

mapfile -t ARTIFACTS < <(
  find "$ROOT_DIR/artifacts/chrome" "$ROOT_DIR/artifacts/companion" -maxdepth 1 -type f -name '*.zip' 2>/dev/null | sort
)

if [[ "${#ARTIFACTS[@]}" -eq 0 ]]; then
  die "no packaged artifacts found under artifacts/chrome or artifacts/companion"
fi

echo "Artifacts:"
for artifact in "${ARTIFACTS[@]}"; do
  echo "  - $artifact"
done

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
