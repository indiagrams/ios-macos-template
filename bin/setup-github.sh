#!/usr/bin/env bash
# bin/setup-github.sh — apply standard GitHub configuration (branch protection, squash, auto-merge) to a
# repo derived from this template.
#
# What it sets:
#   - Default branch: main
#   - Branch protection on main:
#       * Require PR before merging (no direct pushes)
#       * Require 6 status checks: 3 XcodeGen (app (iOS device), app (iOS Simulator),
#         app (macOS)) + 3 Tuist parity (app (Tuist iOS device),
#         app (Tuist iOS Simulator), app (Tuist macOS))
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

# Use a heredoc JSON body — gh api -F doesn't gracefully nest the required_status_checks
# array of objects. Required check names must match the job 'name:' attributes
# in .github/workflows/pr.yml.
PROTECTION_JSON=$(cat <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "checks": [
      { "context": "app (iOS device)" },
      { "context": "app (iOS Simulator)" },
      { "context": "app (macOS)" },
      { "context": "app (Tuist iOS device)" },
      { "context": "app (Tuist iOS Simulator)" },
      { "context": "app (Tuist macOS)" }
    ]
  },
  "enforce_admins": true,
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
ok "main: PR-required, 6 CI checks (3 XcodeGen + 3 Tuist, strict), enforce on admins, linear history"

step "Done"
ok "$REPO is configured (PR-required, 6 CI checks, squash-only, auto-merge)."
ok "Direct pushes to main are blocked. Open PRs and let CI run."
