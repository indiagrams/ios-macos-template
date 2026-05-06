#!/usr/bin/env bash
# Scaffold .bootstrap.env from .bootstrap.env.example, auto-filling GH_ORG +
# GH_APP_REPO from the current git remote so the forker doesn't have to retype
# their repo coordinates. Other fields are left blank for the forker to fill.
#
# Idempotent:
#   - if .bootstrap.env already exists, refuses to overwrite (use --force)
#   - if `git remote get-url origin` fails, GH_ORG/GH_APP_REPO are left blank
#     (forker fills manually)
#
# Usage:  bin/init-bootstrap-env.sh [--force]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/.bootstrap.env.example"
DST="$REPO_ROOT/.bootstrap.env"
FORCE=false

case "${1:-}" in
  --force) FORCE=true ;;
  "") ;;
  *) echo "usage: $0 [--force]" >&2; exit 64 ;;
esac

if [ ! -f "$SRC" ]; then
  echo "missing $SRC — are you in the template repo root?" >&2
  exit 1
fi

if [ -f "$DST" ] && [ "$FORCE" = false ]; then
  echo ".bootstrap.env already exists. Pass --force to overwrite." >&2
  exit 1
fi

cp "$SRC" "$DST"

# Auto-fill GH_ORG + GH_APP_REPO from `git remote get-url origin` if available.
remote=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)
if [ -n "$remote" ]; then
  # https://github.com/ORG/REPO.git or git@github.com:ORG/REPO.git
  slug=$(echo "$remote" | sed -nE 's|^(https://github\.com/\|git@github\.com:)([^/]+)/([^/]+)(\.git)?$|\2/\3|p' | sed 's/\.git$//')
  if [[ "$slug" == */* ]]; then
    org="${slug%%/*}"
    repo="${slug##*/}"
    # Use BSD sed compat (-i ''); runs on macOS only per template scope
    sed -i '' -e "s|^GH_ORG=.*|GH_ORG=$org|" \
              -e "s|^GH_APP_REPO=.*|GH_APP_REPO=$repo|" \
              -e "s|^GH_CERTS_REPO=.*|GH_CERTS_REPO=$repo-certs|" \
              "$DST"
    echo "Auto-filled GH_ORG=$org, GH_APP_REPO=$repo, GH_CERTS_REPO=$repo-certs from git remote."
  fi
fi

echo "Created $DST."
echo "Next: \$EDITOR .bootstrap.env  (fill APP_NAME, BUNDLE_ID, Apple credentials, RELEASE_MODE), then \`make doctor\`."
