#!/usr/bin/env bash
# ci/test-rename.sh — end-to-end integration test for bin/rename.sh.
#
# Clones the live repo to a tmpdir, runs bin/rename.sh with test args,
# asserts the substitution surfaces are all scrubbed, exercises
# idempotent re-run and the AC-19 forced-failure rollback, and runs
# 'make check' in the tmpdir to confirm the renamed app builds green.
#
# Usage:
#   ci/test-rename.sh                # run from repo root
#
# Exit 0 = green; non-zero = a substitution / build failed.
#
# Iter-4 cross-AI fixes:
#   - HIGH-2: check_zero includes :!bin/rename.sh :!ci/test-rename.sh
#     so post-rename grep doesn't false-positive on the running scripts'
#     literal references
#   - HIGH-4: idempotency uses standard `set +e; OUT=$(...); EXIT=$?;
#     set -e` exit-capture (NOT `OUT=$(... || true); EXIT=$?` which
#     always returns 0 from command substitution)
#   - HIGH-5: idempotency asserts STATUS_BEFORE == STATUS_AFTER
#     (script doesn't commit so post-rename tree is dirty by design;
#     comparing pre/post status detects whether the second run produced
#     ANY new changes — that's the falsifiable idempotency signal)
#   - MEDIUM-1: check_zero uses git grep -F for fixed-literal patterns

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR=""

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ✓ %s\n' "$*"; }
fail() { printf '    ✗ %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then
    rm -rf "$TMPDIR"
  fi
}
trap 'cleanup' EXIT INT TERM

# ── Pre-flight ────────────────────────────────────────────────────────────

step "Pre-flight"
cd "$REPO_ROOT"
test -x bin/rename.sh || fail "bin/rename.sh not executable in $REPO_ROOT"
command -v git >/dev/null || fail "git not on PATH"
command -v make >/dev/null || fail "make not on PATH"
command -v xcodegen >/dev/null || fail "xcodegen not on PATH — run 'make bootstrap' first"
ok "tools present"

# ── Clone to tmpdir ───────────────────────────────────────────────────────

step "Clone to tmpdir"
TMPDIR="$(mktemp -d -t test-rename-XXXXXX)"
ok "tmpdir: $TMPDIR"

git clone --no-hardlinks --quiet "$REPO_ROOT" "$TMPDIR"
ok "cloned $REPO_ROOT -> $TMPDIR"

cd "$TMPDIR"

# Force-set main to cloned HEAD so bin/rename.sh's on-main pre-flight
# gate passes AND both shell scripts (bin/rename.sh + ci/test-rename.sh)
# remain present.
git checkout --quiet -B main HEAD || \
  fail "failed to set main to current HEAD in clone"
test -x bin/rename.sh || \
  fail "post-checkout: bin/rename.sh missing or not executable in clone"
ok "on main branch in clone (force-set to cloned HEAD)"

# ── Run bin/rename.sh in the tmpdir ───────────────────────────────────────

step "Run bin/rename.sh in tmpdir"
TEST_APP="MyApp"
TEST_BUNDLE="com.test.myapp"
TEST_DISPLAY="My Test App"
TEST_EMAIL="test@example.com"
TEST_SLUG="test/myapp"

bin/rename.sh "$TEST_APP" "$TEST_BUNDLE" "$TEST_DISPLAY" \
  --email="$TEST_EMAIL" --slug="$TEST_SLUG" \
  || fail "bin/rename.sh failed in tmpdir"
ok "rename complete"

# ── Post-rename grep assertions ───────────────────────────────────────────

step "Post-rename assertions"

# HIGH-2 closure: include :!bin/rename.sh and :!ci/test-rename.sh in
# exclusions so post-rename grep doesn't false-positive on the running
# scripts' literal references (e.g. error messages mentioning HelloApp).
# MEDIUM-1: -F applied to fixed-literal patterns containing '.'
#
# Signature: check_zero PATTERN [F]
#   F  → use git grep -F (fixed-string)
check_zero() {
  local pat="$1"
  local fflag="${2:-}"
  local hits
  if [ "$fflag" = "F" ]; then
    hits=$(git grep -cw -F -e "$pat" -- . \
            ':!.planning' ':!LICENSE' ':!app/HelloApp.xcodeproj' \
            ':!bin/rename.sh' ':!ci/test-rename.sh' 2>/dev/null \
            | awk -F: 'BEGIN{s=0} $2>0{s+=$2} END{print s}' || true)
  else
    hits=$(git grep -cw -e "$pat" -- . \
            ':!.planning' ':!LICENSE' ':!app/HelloApp.xcodeproj' \
            ':!bin/rename.sh' ':!ci/test-rename.sh' 2>/dev/null \
            | awk -F: 'BEGIN{s=0} $2>0{s+=$2} END{print s}' || true)
  fi
  test "$hits" = "0" || fail "post-rename: '$pat' still has $hits matches"
  ok "'$pat' == 0 matches"
}

check_zero "HelloApp"
check_zero "com.example.helloapp" F
check_zero "maintainers@indiagram.com" F
check_zero "<year>"
check_zero "indiagrams/ios-macos-template" F

# Positive assertions: new identifiers present
test "$(git grep -cw -e "$TEST_APP" -- . ':!.planning' ':!LICENSE' \
      ':!bin/rename.sh' ':!ci/test-rename.sh' 2>/dev/null \
      | awk -F: 'BEGIN{s=0} $2>0{s+=$2} END{print s}' || true)" -gt 0 \
  || fail "post-rename: '$TEST_APP' not present"
ok "'$TEST_APP' has matches"

test "$(git grep -cw -F -e "$TEST_BUNDLE" -- . ':!.planning' ':!LICENSE' \
      ':!bin/rename.sh' ':!ci/test-rename.sh' 2>/dev/null \
      | awk -F: 'BEGIN{s=0} $2>0{s+=$2} END{print s}' || true)" -gt 0 \
  || fail "post-rename: '$TEST_BUNDLE' not present"
ok "'$TEST_BUNDLE' has matches"

# File-path renames complete
test -f "app/Shared/$TEST_APP.swift" || fail "app/Shared/$TEST_APP.swift missing"
test -f "app/iOS/$TEST_APP.entitlements" || fail "app/iOS/$TEST_APP.entitlements missing"
test -f "app/macOS/$TEST_APP.entitlements" || fail "app/macOS/$TEST_APP.entitlements missing"
test ! -f "app/Shared/HelloApp.swift" || fail "old app/Shared/HelloApp.swift still present"
test ! -f "app/iOS/HelloApp.entitlements" || fail "old app/iOS/HelloApp.entitlements still present"
test ! -f "app/macOS/HelloApp.entitlements" || fail "old app/macOS/HelloApp.entitlements still present"
ok "file-path renames complete"

# xcodegen regenerated
test -d "app/$TEST_APP.xcodeproj" || fail "app/$TEST_APP.xcodeproj missing"
test ! -d "app/HelloApp.xcodeproj" || fail "old app/HelloApp.xcodeproj still present"
test -f "app/$TEST_APP.xcodeproj/project.pbxproj" || fail "project.pbxproj missing"
grep -q "$TEST_BUNDLE" "app/$TEST_APP.xcodeproj/project.pbxproj" || \
  fail "PRODUCT_BUNDLE_IDENTIFIER '$TEST_BUNDLE' missing from pbxproj"
ok "xcodegen regen complete"

# LICENSE Copyright preserved
grep -q "^Copyright (c) 2026 Indiagram LLC" LICENSE || \
  fail "LICENSE Copyright (c) 2026 Indiagram LLC was modified — MIT requirement violated"
ok "LICENSE Copyright preserved"

# <year> -> current year
test "$(grep -c "$(date +%Y)" fastlane/metadata/copyright.txt)" -gt 0 || \
  fail "current year ($(date +%Y)) not present in fastlane/metadata/copyright.txt"
ok "<year> -> $(date +%Y) substituted"

# ── Idempotency: re-run with same args (HIGH-3 + HIGH-4 + HIGH-5) ─────────
#
# HIGH-3 closure: check_idempotency in bin/rename.sh now runs BEFORE
# the clean-tree gate, so a second invocation on a dirty post-first-
# rename tree returns case 0 = silent exit 0.
#
# HIGH-4 closure: standard exit-capture pattern. The PRIOR plan used
# `OUT=$(cmd 2>&1 || true); EXIT=$?` which ALWAYS sets $? to 0 because
# `|| true` is INSIDE the command substitution — a failing rename
# would have been silently reported as success. Standard pattern:
#
#   set +e
#   OUT=$(cmd 2>&1)
#   EXIT=$?
#   set -e
#
# HIGH-5 closure: assert STATUS_BEFORE == STATUS_AFTER instead of
# asserting clean tree. The script doesn't commit, so post-first-rename
# the tree is dirty (sed mods + git mv staging uncommitted). A truly
# idempotent re-run produces NO new changes — STATUS_BEFORE (sorted
# git status --short) must equal STATUS_AFTER (sorted).

step "Idempotency check (re-run with same args)"

STATUS_BEFORE=$(git status --short | sort)

set +e
OUT=$(bin/rename.sh "$TEST_APP" "$TEST_BUNDLE" "$TEST_DISPLAY" \
        --email="$TEST_EMAIL" --slug="$TEST_SLUG" 2>&1)
EXIT=$?
set -e

STATUS_AFTER=$(git status --short | sort)

test "$EXIT" = "0" || fail "second rename exit $EXIT (expected 0 for idempotent silent no-op); output: $OUT"
test "$STATUS_BEFORE" = "$STATUS_AFTER" || fail "second rename modified the tree (idempotency violated):
BEFORE:
$STATUS_BEFORE
AFTER:
$STATUS_AFTER"
ok "second rename was silent no-op (exit 0; status unchanged)"

# ── make check: build green on the renamed app ────────────────────────────

step "make check (build the renamed app)"
bash -euo pipefail <<'BASH'
set +e
make check 2>&1 | tee .test-rename-make-check.log
EXIT=${PIPESTATUS[0]}
set -e
test "$EXIT" -eq 0 || { echo "ERROR: make check failed with exit $EXIT"; exit 1; }
BASH
ok "make check exit 0"

# ── Forced-failure rollback exercise (SPEC AC-19; HIGH-1 reset-hard) ──────
#
# Per SPEC AC-19: forced failure (chmod -w on target file) triggers
# rollback; `git status --short` empty after script exit 1.
#
# HIGH-1 update: rollback now uses reset-hard mechanism (NOT git stash);
# the contract is unchanged from the test's perspective — pre-rename
# state is restored, working tree is clean.

step "Forced-failure rollback exercise (SPEC AC-19; HIGH-1 reset-hard)"

# Reset clone to pre-rename state.
git reset --hard --quiet HEAD
git clean -fdx --quiet  # -x is fine here because TMPDIR is fully owned by us

test -f app/Shared/HelloApp.swift || \
  fail "AC-19 setup: expected app/Shared/HelloApp.swift to be present pre-rename after reset"
test -x bin/rename.sh || \
  fail "AC-19 setup: bin/rename.sh missing or not executable after reset"

# Force a failure on a substitution target by removing write permission.
chmod 000 app/Shared/HelloApp.swift

set +e
bin/rename.sh "$TEST_APP" "$TEST_BUNDLE" "$TEST_DISPLAY" \
  --email="$TEST_EMAIL" --slug="$TEST_SLUG" >/dev/null 2>&1
RENAME_EXIT=$?
set -e

# Restore permissions BEFORE the assertions
chmod 644 app/Shared/HelloApp.swift 2>/dev/null || true

# AC-19 (a): non-zero exit
test "$RENAME_EXIT" -ne 0 || \
  fail "AC-19: expected non-zero exit on forced failure, got $RENAME_EXIT"
ok "AC-19 (a): forced-failure rename returned non-zero ($RENAME_EXIT)"

# AC-19 (b): `git status --short` empty after rollback
DIRTY=$(git status --short | wc -l | tr -d ' ')
test "$DIRTY" = "0" || \
  fail "AC-19 (b): working tree not clean after rollback (got $DIRTY entries):
$(git status --short)"
ok "AC-19 (b): working tree clean after rollback"

# AC-19 (c): pre-rename files restored
test -f app/Shared/HelloApp.swift || \
  fail "AC-19 (c): app/Shared/HelloApp.swift missing after rollback"
test -f app/iOS/HelloApp.entitlements || \
  fail "AC-19 (c): app/iOS/HelloApp.entitlements missing after rollback"
test -f app/macOS/HelloApp.entitlements || \
  fail "AC-19 (c): app/macOS/HelloApp.entitlements missing after rollback"
ok "AC-19 (c): pre-rename file paths restored"

step "AC-19 forced-failure rollback exercise: PASSED"

# ── Done ──────────────────────────────────────────────────────────────────

step "ci/test-rename.sh: all assertions passed"
ok "tmpdir cleanup will run via EXIT trap"
