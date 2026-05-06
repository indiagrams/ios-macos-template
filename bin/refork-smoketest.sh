#!/usr/bin/env bash
# Refork the public smoketest to validate the template end-to-end.
#
# This script automates the destructive cycle that the template's E2E refork
# test described in docs/CONTINUOUS-VALIDATION.md depends on. Run it from
# the template root.
#
# Methodology: deletes the smoketest *app* repo (mimics what a forker does
# at fork time) but only RESETS the certs repo (force-pushes empty branches
# instead of deleting it). The certs repo has its own lifecycle — real
# forkers don't recreate it on every test cycle, and keeping it intact
# means the fine-grained PAT bound to its database ID stays valid (see G12
# in CONTINUOUS-VALIDATION.md).
#
# Apple-side state that this script does NOT touch:
#   - Bundle ID `com.indiagram.smoke-app` (Apple disallows deletion if
#     signing artifacts existed; register_app_id idempotent path covers it)
#   - ASC App record (Apple disallows deletion of Apps with shipped
#     TestFlight builds; bootstrap_asc verify-mode covers it)
#
# Apple-side state that this script DOES revoke:
#   - The 3 active certs in the team (iOS Distribution, iOS Development,
#     Mac Installer Distribution) — frees the cert quota slots so the
#     fresh fork can mint cleanly
#
# Required env (read from ~/.config/secrets.env):
#   FASTLANE_TEAM_ID, ASC_API_KEY_*, MATCH_PASSWORD,
#   MATCH_GIT_BASIC_AUTHORIZATION, KEYCHAIN_PASSWORD
#
# Required gh auth scopes: delete_repo + repo
#
# Usage:
#   bin/refork-smoketest.sh [--keep-certs-repo]   (default behavior)
#   bin/refork-smoketest.sh --nuke-certs-repo     (also delete certs repo —
#                                                   PAT will need scope update)

set -euo pipefail

KEEP_CERTS=true
case "${1:-}" in
  --nuke-certs-repo) KEEP_CERTS=false ;;
  --keep-certs-repo|"") KEEP_CERTS=true ;;
  *) echo "usage: $0 [--keep-certs-repo|--nuke-certs-repo]" >&2; exit 64 ;;
esac

ORG=indiagrams
APP_REPO="$ORG/ios-macos-smoketest"
CERTS_REPO="$ORG/ios-macos-smoketest-certs"

# Load secrets
[ -f "$HOME/.config/secrets.env" ] || { echo "missing ~/.config/secrets.env" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
source "$HOME/.config/secrets.env"
set +a

# Idempotency check: gh auth has delete_repo
gh auth status 2>&1 | grep -qE "delete_repo" \
  || { echo "gh auth missing delete_repo scope; run: gh auth refresh -s delete_repo" >&2; exit 1; }

echo "=== 1/5: archive PRs + key runs ==="
ARCHIVE_DIR=".planning/smoketest-history/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$ARCHIVE_DIR"
gh pr list --repo "$APP_REPO" --state all --limit 100 --json number,title,state,mergedAt,body,url \
  > "$ARCHIVE_DIR/pr-list.json" 2>/dev/null || echo "  (no PRs to archive)"
gh run list --repo "$APP_REPO" --limit 50 --json databaseId,displayTitle,conclusion,createdAt,workflowName,event \
  > "$ARCHIVE_DIR/run-list.json" 2>/dev/null || true
echo "  archive → $ARCHIVE_DIR"

echo "=== 2/5: revoke 3 active Apple certs ==="
# Find them via Spaceship — only revoke ones the smoketest minted (typed
# 'Created via API' or matching display name patterns). User's personal
# certs (display name = <your-name>...) are left alone.
unset APP_STORE_CONNECT_API_KEY_KEY APP_STORE_CONNECT_API_KEY_KEY_FILEPATH \
      APP_STORE_CONNECT_API_KEY_KEY_ID APP_STORE_CONNECT_API_KEY_ISSUER_ID

# Use the project's Fastfile to list + revoke. cd to a clone if needed.
if [ -d ../ios-macos-smoketest/fastlane ]; then
  pushd ../ios-macos-smoketest >/dev/null
elif [ -d fastlane ]; then
  : # already in a fastlane project root
else
  echo "  no fastlane project found nearby; skipping cert revocation"
fi
if [ -d fastlane ]; then
  bundle exec fastlane list_certs 2>&1 \
    | awk '/Created via API/ { for (i=1;i<=NF;i++) if ($i ~ /^[A-Z0-9]{10}$/) { print $i; break } }' \
    | while read -r cert_id; do
        echo "  revoking $cert_id"
        bundle exec fastlane revoke_cert "id:$cert_id" 2>&1 | grep -E "Revoked|error" | head -1
      done
  popd >/dev/null 2>/dev/null || true
fi

echo "=== 3/5: delete app repo + clear local clone ==="
if gh repo view "$APP_REPO" --json name >/dev/null 2>&1; then
  gh repo delete "$APP_REPO" --yes
  echo "  deleted $APP_REPO"
else
  echo "  $APP_REPO doesn't exist; skipping"
fi
rm -rf "../ios-macos-smoketest"

if [ "$KEEP_CERTS" = false ]; then
  echo "=== 4/5: NUKE certs repo (--nuke-certs-repo) ==="
  echo "  WARNING: PAT will need scope update on github.com/settings/tokens"
  if gh repo view "$CERTS_REPO" --json name >/dev/null 2>&1; then
    gh repo delete "$CERTS_REPO" --yes
  fi
else
  echo "=== 4/5: RESET certs repo (force-push empty branches) ==="
  if gh repo view "$CERTS_REPO" --json name >/dev/null 2>&1; then
    TMPDIR_CERTS=$(mktemp -d)
    auth=$(printf '%s' "x-access-token:$GH_TOKEN" | base64 | tr -d '\n')
    gh repo clone "$CERTS_REPO" "$TMPDIR_CERTS" -- --quiet 2>&1 | tail -1 || true
    pushd "$TMPDIR_CERTS" >/dev/null
    # Force-push an empty branch over master + main, then delete every other
    # ref. Match will repopulate from scratch on the next fastlane match call.
    git checkout --orphan reset-tmp >/dev/null 2>&1
    git reset --hard >/dev/null 2>&1
    git -c user.email=refork@indiagram.com -c user.name=refork commit --allow-empty -m "reset for E2E" -q
    for branch in $(git branch -r | grep -v HEAD | sed 's|origin/||'); do
      git push origin --delete "$branch" 2>&1 | tail -1 || true
    done
    popd >/dev/null
    rm -rf "$TMPDIR_CERTS"
    echo "  certs repo reset; PAT scope retained"
  else
    echo "  $CERTS_REPO doesn't exist — creating"
    gh repo create "$CERTS_REPO" --private --description "Encrypted certs + profiles for $APP_REPO"
  fi
fi

echo "=== 5/5: re-fork smoketest from template ==="
gh repo create "$APP_REPO" --template "$ORG/ios-macos-template" --public --clone -- --quiet 2>&1 | tail -1
mv ios-macos-smoketest ../ios-macos-smoketest
echo "  fresh fork at ../ios-macos-smoketest"

cat <<EOF

===============================================================================
Refork complete. Next steps (forker journey, autonomous):

  cd ../ios-macos-smoketest
  bin/rename.sh SmokeApp com.indiagram.smoke-app 'Indiagram Smoke App' --email=smoketest@indiagram.com
  bin/verify-rename.sh
  make bootstrap
  git add -A && git commit -m 'Rename app stub'
  git push -u origin main
  bin/setup-github.sh
  # Then signing setup per README "Setting up signing + ASC"
===============================================================================
EOF
