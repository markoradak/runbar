#!/usr/bin/env bash
#
# One-shot migration to the runbar-app org. Run this AFTER creating the org
# in the GitHub UI (https://github.com/account/organizations/new — orgs
# cannot be created via API).
#
# It will:
#   1. Transfer markoradak/runbar → runbar-app/runbar
#   2. Point this checkout's origin at the new location
#   3. Create the public runbar-app/runbar-releases repo (Sparkle feed host)
#   4. Upload the SPARKLE_PRIVATE_KEY secret for the release workflow
#   5. Print the one manual step left (RELEASES_TOKEN PAT)
#
set -euo pipefail

ORG="runbar-app"
SOURCE_REPO="markoradak/runbar"
RELEASES_REPO="$ORG/runbar-releases"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ── 1. Org must exist ─────────────────────────────────────────────────────────
if ! gh api "orgs/$ORG" >/dev/null 2>&1; then
  echo "Error: org '$ORG' not found. Create it first:" >&2
  echo "  https://github.com/account/organizations/new (free plan is fine)" >&2
  exit 1
fi
echo "  ✓ org $ORG exists"

# ── 2. Transfer the source repo ───────────────────────────────────────────────
if gh repo view "$ORG/runbar" >/dev/null 2>&1; then
  echo "  ✓ $ORG/runbar already exists (transfer done previously)"
else
  gh api "repos/$SOURCE_REPO/transfer" -f new_owner="$ORG" >/dev/null
  echo "  ✓ transferred $SOURCE_REPO → $ORG/runbar"
fi

# ── 3. Point origin at the new location ──────────────────────────────────────
git remote set-url origin "git@github.com:$ORG/runbar.git"
echo "  ✓ origin → git@github.com:$ORG/runbar.git"

# ── 4. Create the public releases repo ───────────────────────────────────────
if gh repo view "$RELEASES_REPO" >/dev/null 2>&1; then
  echo "  ✓ $RELEASES_REPO already exists"
else
  gh repo create "$RELEASES_REPO" --public \
    --description "Runbar releases and Sparkle appcast"
  echo "  ✓ created $RELEASES_REPO (public)"
fi

# ── 5. Upload the Sparkle private key secret ─────────────────────────────────
SPARKLE_BIN="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -type d -name bin -path '*Runbar*' -path '*parkle*' 2>/dev/null | head -1)"
if [ -z "$SPARKLE_BIN" ]; then
  echo "  ! Sparkle tools not found in DerivedData — build the app once, then run:" >&2
  echo "    <sparkle-bin>/generate_keys -x /dev/stdout | gh secret set SPARKLE_PRIVATE_KEY --repo $ORG/runbar" >&2
else
  "$SPARKLE_BIN/generate_keys" -x /dev/stdout | gh secret set SPARKLE_PRIVATE_KEY --repo "$ORG/runbar"
  echo "  ✓ set SPARKLE_PRIVATE_KEY secret on $ORG/runbar"
fi

# ── 6. Remaining manual step ─────────────────────────────────────────────────
echo ""
echo "One manual step left — the release workflow needs a token that can write"
echo "to $RELEASES_REPO (GITHUB_TOKEN cannot cross repos):"
echo "  1. Create a fine-grained PAT: https://github.com/settings/personal-access-tokens/new"
echo "     Resource owner: $ORG · Repository: runbar-releases · Permission: Contents (read/write)"
echo "  2. gh secret set RELEASES_TOKEN --repo $ORG/runbar"
echo ""
echo "Then release with: scripts/release.sh patch"
