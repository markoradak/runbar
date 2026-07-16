#!/usr/bin/env bash
#
# Release helper — bump the app version, commit, tag, and push. Pushing a
# `v*` tag is what triggers `.github/workflows/release.yml`:
#   build (Release) → zip → generate signed Sparkle appcast →
#   publish to this repo's GitHub release.
#
# The app's SUFeedURL points at:
#   https://github.com/markoradak/runbar/releases/latest/download/appcast.xml
# so the published appcast is what makes installed apps update. That URL is
# baked into every shipped binary — if the repo ever moves, GitHub's redirect
# must keep serving it, so never recreate a repo at the old path.
#
# Usage:
#   scripts/release.sh patch           # 0.1.0 -> 0.1.1
#   scripts/release.sh minor           # 0.1.0 -> 0.2.0
#   scripts/release.sh major           # 0.1.0 -> 1.0.0
#   scripts/release.sh 0.4.2           # explicit X.Y.Z
#   scripts/release.sh patch --dry-run # show the plan, change nothing
#   scripts/release.sh patch --yes     # skip the confirmation prompt
#
# Keeps these in lockstep (Sparkle compares CFBundleVersion, users see
# CFBundleShortVersionString):
#   project.yml MARKETING_VERSION        (X.Y.Z, the display version)
#   project.yml CURRENT_PROJECT_VERSION  (monotonic build number, +1 per release)
#
set -euo pipefail

# ── Resolve repo root (this script lives in <root>/scripts) ──────────────────
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROJECT_YML="project.yml"

# ── Parse args ───────────────────────────────────────────────────────────────
BUMP=""
ASSUME_YES=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes)     ASSUME_YES=1 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed '/^!/d'
      exit 0
      ;;
    -*) echo "Unknown flag: $arg" >&2; exit 1 ;;
    *)  BUMP="$arg" ;;
  esac
done

if [ -z "$BUMP" ]; then
  echo "Usage: scripts/release.sh <patch|minor|major|X.Y.Z> [--dry-run] [--yes]" >&2
  exit 1
fi

# ── Read current version (project.yml is the source of truth) ────────────────
CURRENT="$(sed -n 's/^ *MARKETING_VERSION: *//p' "$PROJECT_YML" | head -1)"
BUILD_NUMBER="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *//p' "$PROJECT_YML" | head -1)"
if ! [[ "$CURRENT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: current version '$CURRENT' in $PROJECT_YML is not X.Y.Z" >&2
  exit 1
fi
if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Error: CURRENT_PROJECT_VERSION '$BUILD_NUMBER' in $PROJECT_YML is not an integer" >&2
  exit 1
fi
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"

# ── Compute the new version ──────────────────────────────────────────────────
case "$BUMP" in
  major) VERSION="$((MAJOR + 1)).0.0" ;;
  minor) VERSION="$MAJOR.$((MINOR + 1)).0" ;;
  patch) VERSION="$MAJOR.$MINOR.$((PATCH + 1))" ;;
  *)
    VERSION="$BUMP"
    if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "Error: '$BUMP' is not a keyword (patch/minor/major) or an X.Y.Z version" >&2
      exit 1
    fi
    ;;
esac
NEW_BUILD_NUMBER="$((BUILD_NUMBER + 1))"
TAG="v$VERSION"

echo "Release plan:"
echo "  $CURRENT (build $BUILD_NUMBER)  ->  $VERSION (build $NEW_BUILD_NUMBER)   (tag $TAG)"
echo "  triggers: build → signed appcast → publish to runbar-app/runbar-releases → updater"
echo ""

# ── Preflight ────────────────────────────────────────────────────────────────
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "Error: tag $TAG already exists locally." >&2
  exit 1
fi
if git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
  echo "Error: tag $TAG already exists on origin." >&2
  exit 1
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "[dry-run] Would bump $PROJECT_YML to $VERSION (build $NEW_BUILD_NUMBER),"
  echo "[dry-run] commit 'chore: release $TAG', tag $TAG, and push to origin. No changes made."
  exit 0
fi

# Working tree must be clean so the release commit contains ONLY the version bump.
if [ -n "$(git status --porcelain)" ]; then
  echo "Error: working tree is not clean. Commit or stash changes first." >&2
  git status --short >&2
  exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"

# ── Confirm (pushing a tag publishes a real update to installed apps) ────────
if [ "$ASSUME_YES" != "1" ]; then
  printf "Bump to %s, tag %s, and push to origin/%s? [y/N] " "$VERSION" "$TAG" "$BRANCH"
  read -r reply < /dev/tty || reply=""
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

# ── Apply the version bump (raw text replace → preserves formatting) ─────────
sed -i '' "s/^\( *MARKETING_VERSION:\) .*/\1 $VERSION/" "$PROJECT_YML"
sed -i '' "s/^\( *CURRENT_PROJECT_VERSION:\) .*/\1 $NEW_BUILD_NUMBER/" "$PROJECT_YML"
echo "  ✓ bumped $PROJECT_YML to $VERSION (build $NEW_BUILD_NUMBER)"

# ── Commit, tag, push ────────────────────────────────────────────────────────
git add "$PROJECT_YML"
git commit -m "chore: release $TAG"
echo "  ✓ committed"

git tag "$TAG"
echo "  ✓ tagged $TAG"

git push origin HEAD
git push origin "$TAG"
echo "  ✓ pushed $BRANCH + $TAG to origin"

echo ""
echo "Released $TAG. Track the build:"
echo "  https://github.com/markoradak/runbar/actions"
echo "After it finishes, verify the updater feed:"
echo "  curl -fsSL https://github.com/markoradak/runbar/releases/latest/download/appcast.xml"
