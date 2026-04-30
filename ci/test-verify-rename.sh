#!/usr/bin/env bash
# ci/test-verify-rename.sh — integration self-test for bin/verify-rename.sh.
#
# Clones the live repo to a tmpdir, runs bin/rename.sh with test args,
# asserts bin/verify-rename.sh exits 0 silent (happy path), then mutates
# one tracked file to reintroduce a surface literal and asserts verify
# exits 1 with the byte-exact APP_NAME leak header. Restores the mutated
# file from a tmpdir snapshot (NOT via git checkout — see HIGH-Plan2-1
# below), then appends a marker to bin/rename.sh (a D-02 exclusion-list
# file) and asserts verify still exits 0 — the D-05 positive exclusion
# test that catches drift if the exclusion list ever expands or contracts.
#
# Cross-AI review closures (see 03-REVIEWS.md):
#   HIGH-Plan2-1 — restore README.md via `cp $TMPDIR/README.md.post-rename`
#                  snapshot, NOT a git-based file restore (resetting the
#                  file to HEAD). HEAD is pre-rename in the tmpdir because
#                  rename.sh leaves changes uncommitted; restoring to it
#                  would re-leak all 5 surface literals into README and
#                  invalidate the D-05 test that runs immediately after.
#   MEDIUM-Plan2-5 — assert the byte-exact mutate-and-fail header
#                  `APP_NAME leak (1 match for "HelloApp"):`. Asserting
#                  only fragments would mask a singular/plural regression
#                  in bin/verify-rename.sh's check_surface helper.
#
# Usage:
#   ci/test-verify-rename.sh                # run from repo root
#
# Exit 0 = green; non-zero = a verification assertion failed.
#
# Wall-clock budget: < 30 seconds on macos-15 (SPEC AC-3).

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

step "Pre-flight"
cd "$REPO_ROOT"
test -x bin/rename.sh         || fail "bin/rename.sh not executable in $REPO_ROOT"
test -x bin/verify-rename.sh  || fail "bin/verify-rename.sh not executable in $REPO_ROOT"
command -v git       >/dev/null || fail "git not on PATH"
command -v xcodegen  >/dev/null || fail "xcodegen not on PATH — run 'make bootstrap' first"
ok "tools present"

step "Clone to tmpdir"
TMPDIR="$(mktemp -d -t test-verify-rename-XXXXXX)"
ok "tmpdir: $TMPDIR"

git clone --no-hardlinks --quiet "$REPO_ROOT" "$TMPDIR"
ok "cloned $REPO_ROOT -> $TMPDIR"

cd "$TMPDIR"

git checkout --quiet -B main HEAD \
  || fail "failed to set main to current HEAD in clone"
test -x bin/rename.sh        || fail "post-checkout: bin/rename.sh missing"
test -x bin/verify-rename.sh || fail "post-checkout: bin/verify-rename.sh missing"
ok "on main branch in clone (force-set to cloned HEAD)"

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

step "Happy path: bin/verify-rename.sh exits 0 silent on freshly-renamed tree"

set +e
VERIFY_OUT=$(bin/verify-rename.sh 2>&1)
VERIFY_EXIT=$?
set -e

test "$VERIFY_EXIT" = "0" || \
  fail "happy path: verify exited $VERIFY_EXIT (expected 0); output:
$VERIFY_OUT"
test -z "$VERIFY_OUT" || \
  fail "happy path: verify produced output (expected empty); output:
$VERIFY_OUT"
ok "happy path: exit 0 + empty stdout/stderr"

step "Mutate-and-fail: snapshot README, reintroduce HelloApp, assert byte-exact header"

# Cross-AI HIGH-Plan2-1: snapshot README BEFORE mutation. The next test
# (D-05) needs README in its post-rename clean state. A git-checkout
# restore (i.e. resetting the file to HEAD) cannot reach that state
# because rename.sh leaves changes uncommitted in the tmpdir — that
# would restore to pre-rename, with all 5 surface literals re-leaked,
# invalidating the D-05 test entirely. Use a file snapshot via cp.
cp README.md "$TMPDIR/README.md.post-rename" \
  || fail "could not snapshot README.md to $TMPDIR/README.md.post-rename"
ok "README.md snapshotted to $TMPDIR/README.md.post-rename"

# Append the literal HelloApp to README.md. This is in the post-rename
# tmpdir, so any HelloApp marker is a leak (the rename swept the file
# to MyApp on the happy path). Single-line append → exactly 1 match
# → cross-AI MEDIUM-Plan2-5 byte-exact "(1 match for ...)" assertion.
echo 'HelloApp leak marker for test' >> README.md

set +e
VERIFY_OUT=$(bin/verify-rename.sh 2>&1)
VERIFY_EXIT=$?
set -e

test "$VERIFY_EXIT" -ne 0 || \
  fail "mutate-and-fail: verify exited 0 (expected non-zero); output:
$VERIFY_OUT"

# Cross-AI MEDIUM-Plan2-5: assert byte-exact APP_NAME leak header. The
# mutation introduces exactly 1 match → "1 match" (singular). If
# bin/verify-rename.sh regressed pluralization (e.g. printed "1 matches"),
# this assertion catches it.
echo "$VERIFY_OUT" | grep -qF 'APP_NAME leak (1 match for "HelloApp"):' || \
  fail "mutate-and-fail: stderr did not contain exact APP_NAME leak header; output:
$VERIFY_OUT"

echo "$VERIFY_OUT" | grep -qF "README.md" || \
  fail "mutate-and-fail: stderr did not mention README.md; output:
$VERIFY_OUT"
echo "$VERIFY_OUT" | grep -qF "Verify failed:" || \
  fail "mutate-and-fail: stderr did not contain 'Verify failed:' summary; output:
$VERIFY_OUT"

# stdout-empty assertion on the failure path (SPEC AC-1, AC-2).
# The combined-capture above (`2>&1`) merged stdout+stderr for content
# checks. Now capture stdout ALONE to confirm it is empty even on exit 1.
VERIFY_STDOUT=$(bin/verify-rename.sh 2>/dev/null || true)
test -z "$VERIFY_STDOUT" || fail "mutate-and-fail: stdout not empty on exit 1"
ok "mutate-and-fail: exit $VERIFY_EXIT + byte-exact APP_NAME header + README mention + summary + stdout empty"

# Cross-AI HIGH-Plan2-1: restore README from snapshot, NOT git checkout.
cp "$TMPDIR/README.md.post-rename" README.md \
  || fail "could not restore README.md from snapshot"
ok "README.md restored to post-rename state via snapshot (NOT git checkout)"

# Sanity: verify must be silent again on the restored tree (proves the
# snapshot/restore was complete and the next test starts from a clean
# post-rename state).
set +e
VERIFY_OUT=$(bin/verify-rename.sh 2>&1)
VERIFY_EXIT=$?
set -e
test "$VERIFY_EXIT" = "0" || \
  fail "post-restore sanity: verify exited $VERIFY_EXIT (expected 0); output:
$VERIFY_OUT"
test -z "$VERIFY_OUT" || \
  fail "post-restore sanity: verify produced output; output:
$VERIFY_OUT"
ok "post-restore sanity: tree is clean post-rename again"

step "D-05 positive exclusion: append marker to bin/rename.sh, assert verify silent"

# Append a unique marker to bin/rename.sh in the tmpdir. The marker
# contains the HelloApp literal but bin/rename.sh is in the D-02
# exclusion list, so verify must STILL exit 0.
echo '# HelloApp test marker' >> bin/rename.sh

set +e
VERIFY_OUT=$(bin/verify-rename.sh 2>&1)
VERIFY_EXIT=$?
set -e

test "$VERIFY_EXIT" = "0" || \
  fail "D-05: verify exited $VERIFY_EXIT (expected 0 because bin/rename.sh is in exclusion list); output:
$VERIFY_OUT"
test -z "$VERIFY_OUT" || \
  fail "D-05: verify produced output (expected empty silent); output:
$VERIFY_OUT"
ok "D-05 positive exclusion: verify silent on excluded-file marker"

step "ci/test-verify-rename.sh: all assertions passed"
ok "tmpdir cleanup will run via EXIT trap"
