#!/usr/bin/env bash
# bin/setup-github.sh — apply standard GitHub configuration (branch protection, squash, auto-merge) to a
# repo derived from this template.
#
# What it sets:
#   - Default branch: main
#   - Branch protection on main:
#       * Require PR before merging (no direct pushes)
#       * Require status checks (swiftlint + per-generator app cells —
#         xcodegen if app/project.yml is committed, tuist if app/Project.swift
#         is committed; both manifests = both check sets)
#       * Require status checks to be up-to-date before merge
#       * Enforce on admins (no bypass — same rules apply to repo owner)
#       * Require linear history
#   - Disable merge commits + rebase merges (squash-only)
#   - Auto-delete head branches after merge
#
# Usage:
#   bin/setup-github.sh                              # uses current repo's origin
#   bin/setup-github.sh owner/repo                   # explicit target
#
# Prerequisites:
#   - gh CLI authenticated with admin:repo scope (`gh auth status` shows it)
#   - You are the repo admin (or an org admin)
#
# Idempotent — safe to re-run; existing settings are overwritten with these.

set -euo pipefail

# Resolve repo root from this script's location (bin/setup-github.sh → repo root).
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ✓ %s\n' "$*"; }
fail() { printf '    ✗ %s\n' "$*" >&2; exit 1; }

# ── Resolve target repo ───────────────────────────────────────────────────────

if [ $# -ge 1 ]; then
  REPO="$1"
else
  # Try to read from the current repo's origin remote.
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    fail "not in a git repository — pass a repo as 'owner/name' or run from a clone"
  fi
  origin=$(git config --get remote.origin.url 2>/dev/null || true)
  [ -z "$origin" ] && fail "no origin remote — pass a repo as 'owner/name'"
  # Normalize: strip git@github.com: / https://github.com/ / .git
  REPO=$(echo "$origin" \
    | sed -E -e 's#^git@github\.com:##' \
             -e 's#^https://github\.com/##' \
             -e 's#\.git$##')
fi

if ! [[ "$REPO" =~ ^[^/]+/[^/]+$ ]]; then
  fail "invalid repo '$REPO' — expected owner/name (e.g. acme/myapp)"
fi

step "Target: $REPO"

# Sanity-check repo exists + we can reach it.
if ! gh api "repos/$REPO" --silent 2>/dev/null; then
  fail "cannot reach $REPO via gh API — check 'gh auth status' and that the repo exists"
fi
ok "repo reachable"

# ── 1. Repo settings: squash-only merge, auto-delete head branches ────────────

step "Repo settings"
gh api -X PATCH "repos/$REPO" \
  -F allow_squash_merge=true \
  -F allow_merge_commit=false \
  -F allow_rebase_merge=false \
  -F delete_branch_on_merge=true \
  -F allow_auto_merge=true \
  --silent
ok "squash-only merge, auto-delete head branches, auto-merge enabled"

# ── 2. Branch protection on main ──────────────────────────────────────────────

step "Branch protection on main"

# Derive the required-checks list from .bootstrap.env's PLATFORMS field.
# Defaults to 'ios,macos' if the file or field is absent. The PR workflow
# (.github/workflows/pr.yml) only runs the iOS jobs when do_ios=true and
# the macOS jobs when do_macos=true, so the required checks must match.
# Read .bootstrap.env once for both PLATFORMS (which CI checks are required)
# and RELEASE_MODE (whether enforce_admins blocks even-the-admin from pushing
# directly to main). CI mode = team-shared default → enforce_admins=true, no
# bypass even for admins. Local mode = solo first-time-shipper default →
# enforce_admins=false, admin can push directly when needed (PR-required +
# required-checks still gate normal flow; this just lets the solo dev escape
# the lock-out trap). Forkers can flip later by re-running this script.
PLATFORMS_VAL=""
RELEASE_MODE_VAL=""
if [ -f "$REPO_ROOT/.bootstrap.env" ]; then
  PLATFORMS_VAL=$(awk -F= '/^PLATFORMS[[:space:]]*=/ { gsub(/^[[:space:]"\047]+|[[:space:]"\047]+$/, "", $2); print $2; exit }' "$REPO_ROOT/.bootstrap.env")
  RELEASE_MODE_VAL=$(awk -F= '/^RELEASE_MODE[[:space:]]*=/ { gsub(/^[[:space:]"\047]+|[[:space:]"\047]+$/, "", $2); print $2; exit }' "$REPO_ROOT/.bootstrap.env")
fi
[ -z "$PLATFORMS_VAL" ] && PLATFORMS_VAL="ios,macos"
[ -z "$RELEASE_MODE_VAL" ] && RELEASE_MODE_VAL="ci"

# Detect committed generator manifests so the required-checks list matches
# what pr.yml's matrix builder actually emits. Single-generator forks (the
# typical end state — pick xcodegen OR tuist via bin/switch-to-{xcodegen,
# tuist}.sh) delete the other manifest, so requiring its check names would
# leave PRs permanently unmergeable (those checks never appear). The matrix
# builder in .github/workflows/pr.yml uses the same filesystem rule.
has_xcodegen=0; has_tuist=0
[ -f "$REPO_ROOT/app/project.yml" ]   && has_xcodegen=1
[ -f "$REPO_ROOT/app/Project.swift" ] && has_tuist=1
# Safety: if neither manifest is present (corrupt state), fall back to
# requiring both — same default the matrix builder uses, so pr.yml would
# still emit cells (failing loudly) and the names line up.
if [ "$has_xcodegen" -eq 0 ] && [ "$has_tuist" -eq 0 ]; then
  echo "  WARN: neither app/project.yml nor app/Project.swift present; defaulting required checks to both generator sets"
  has_xcodegen=1; has_tuist=1
fi

CHECKS=()
if echo "$PLATFORMS_VAL" | grep -qw 'ios'; then
  [ "$has_xcodegen" -eq 1 ] && CHECKS+=( "app (iOS device)" "app (iOS Simulator)" )
  [ "$has_tuist"    -eq 1 ] && CHECKS+=( "app (Tuist iOS device)" "app (Tuist iOS Simulator)" )
fi
if echo "$PLATFORMS_VAL" | grep -qw 'macos'; then
  [ "$has_xcodegen" -eq 1 ] && CHECKS+=( "app (macOS)" )
  [ "$has_tuist"    -eq 1 ] && CHECKS+=( "app (Tuist macOS)" )
fi

# `swiftlint` always runs (no platform gate) — append unconditionally so
# every fork's required-checks list includes it regardless of PLATFORMS.
CHECKS+=( "swiftlint" )

if [ ${#CHECKS[@]} -eq 0 ]; then
  echo "ERROR: PLATFORMS=$PLATFORMS_VAL produced no required checks. Must include 'ios', 'macos', or both." >&2
  exit 1
fi

echo "  → required CI checks (PLATFORMS=$PLATFORMS_VAL):"
for c in "${CHECKS[@]}"; do echo "    - $c"; done

# Mode-aware admin enforcement. CI mode defaults to true (team safety net).
# Local mode defaults to false so a solo first-time-shipper isn't locked out
# of pushing fixes to their own fork. PR-required + required-checks still
# gate the normal flow either way.
if [ "$RELEASE_MODE_VAL" = "local" ]; then
  ENFORCE_ADMINS_JSON="false"
  echo "  → enforce_admins=false (RELEASE_MODE=local — admin can push directly)"
else
  ENFORCE_ADMINS_JSON="true"
  echo "  → enforce_admins=true (RELEASE_MODE=$RELEASE_MODE_VAL — no admin bypass)"
fi

# Build the JSON checks array from $CHECKS. printf %s\\n + jq -Rs build the
# array — keeps it simple without arity-counting.
CHECKS_JSON=$(printf '%s\n' "${CHECKS[@]}" | jq -R '{context: .}' | jq -s '.')

PROTECTION_JSON=$(cat <<JSON
{
  "required_status_checks": {
    "strict": true,
    "checks": $CHECKS_JSON
  },
  "enforce_admins": $ENFORCE_ADMINS_JSON,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": true,
  "lock_branch": false,
  "allow_fork_syncing": false
}
JSON
)

# `--input -` reads JSON body from stdin. PUT replaces existing protection.
echo "$PROTECTION_JSON" | gh api -X PUT "repos/$REPO/branches/main/protection" \
  -H "Accept: application/vnd.github+json" \
  --input - --silent || {
  # If the branch doesn't exist yet (fresh repo with no commits on main),
  # PUT returns 404. Make this error clearer.
  fail "could not apply protection — does '$REPO' have a 'main' branch yet? Push at least one commit first."
}
ok "main: PR-required, ${#CHECKS[@]} CI checks ($(IFS=,; echo "${CHECKS[*]}"), strict), enforce on admins, linear history"

step "Done"
ok "$REPO is configured (PR-required, ${#CHECKS[@]} CI checks, squash-only, auto-merge)."
ok "Direct pushes to main are blocked. Open PRs and let CI run."
