#!/usr/bin/env bash
# bin/verify-rename.sh — forker self-check for the ios-macos-template rename.
#
# Greps tracked files for the 4 original-template identity literals
# (APP_NAME, BUNDLE_ID, EMAIL, SLUG) and exits 0 silent if none remain,
# or 1 with a per-surface stderr report if any leak. Use after running
# bin/rename.sh on a fresh fork to confirm no Indiagrams strings
# survived the substitution.
#
# Usage:
#   bin/verify-rename.sh                # zero args; reads tracked files only
#
# Exit codes:
#   0 — all 4 surfaces clean (no matches in tracked files)
#   1 — any leak; per-surface stderr report + trailing summary
#
# Surfaces synced with bin/rename.sh:291. If rename.sh adds a surface,
# update both. (D-03 cross-reference.)
#
# DISPLAY_NAME shares 'HelloApp' literal with APP_NAME pre-rename;
# covered transitively by APP_NAME_ORIG (D-11).
#
# Self-reference exclusion (D-01, D-02):
#   The 5 :!path pathspecs below are the only files that retain
#   original-string literals post-rename by design (rename script + this
#   script + 3 test files). Hardcoded as :!pathspecs inside each
#   `git grep` call — no external ignore file, no constants array.
#
# Design note: 4 separate grep calls (one per surface) instead of one
# `git grep -e P1 -e P2 -e P3 -e P4`. Trade: 4 syscalls for trivial
# per-surface block assembly (D-09 grouped-by-surface stderr report).
# Single-call shape was rejected because classifying each match line
# by which `-e` pattern hit it requires error-prone post-hoc regex
# matching. See .planning/phases/03-verify-rename/03-01-PLAN.md
# <design_resolution> for the full rationale.
#
# Cross-AI review closures (see 03-REVIEWS.md):
#   HIGH-3   — git grep status-aware capture: distinguish exit 0 (matches)
#              from exit 1 (no matches) from exit ≥2 (real failure).
#              `|| true` would mask wrong-dir / not-in-git / bad-pathspec
#              into a silent exit 0 false-pass.
#   MEDIUM-1 — cd to REPO_ROOT before grepping; git rev-parse work-tree
#              gate so subdir / not-in-git invocations don't truncate scope.
#   MEDIUM-2 — pluralize correctly: "1 match" vs "N matches".
#   MEDIUM-3 — git grep -I to skip binaries (no "Binary file X matches").
#
# Constraints (parity with bin/rename.sh):
#   - bash 3.2+ (macOS default); no bash 4+ features
#   - git grep -I -F (binary-skip + fixed-literal); no regex on patterns
#   - tracked files only (git grep default; binaries auto-excluded by -I)
#   - no new external dependencies (git, bash, grep, sed)

set -euo pipefail

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ✓ %s\n' "$*"; }
fail() { printf '    ✗ %s\n' "$*" >&2; exit 1; }

# ── Repo-root normalization (cross-AI MEDIUM-1) ────────────────────────
# Forker may invoke this script from any subdir. `git grep -- .` only
# searches from the current cwd, so without a cd to repo root, scope
# silently truncates. Resolve the script's own dir, climb one level.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || fail "could not cd to repo root ($REPO_ROOT)"

# ── Working-tree gate (cross-AI HIGH-3 supplement) ─────────────────────
# Status-aware grep capture below distinguishes git grep's "no match"
# exit 1 from any other failure. But if we're not in a git work-tree
# at all, every `git grep` call returns exit 128 — fail loud here
# rather than confuse the user with a cascade of cryptic errors.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
  fail "bin/verify-rename.sh must run inside a git working tree"

# ── Surface literals (synced with bin/rename.sh:291; D-03) ──────────────
# 4 variables, NOT 5: DISPLAY_NAME shares 'HelloApp' with APP_NAME
# pre-rename, so it merges into APP_NAME_ORIG (D-11).
APP_NAME_ORIG="HelloApp"
BUNDLE_ID_ORIG="com.example.helloapp"
EMAIL_ORIG="maintainers@indiagram.com"
SLUG_ORIG="indiagrams/ios-macos-template"
YEAR_ORIG="<year>"

# check_surface LABEL LITERAL
# Greps tracked files for LITERAL excluding the 5 self-reference paths.
# On match: writes the D-09 block to stderr (header + indented matches).
# Always writes a single integer (the match count) to stdout.
# Returns 0 always (caller decides via the count, not the exit code).
#
# Co-location note (D-01): the 5 :!path exclusions are written inline
# here ONCE. The function body IS the single auditable source of truth
# for the exclusion list — calling this helper 4 times does not
# duplicate the audit surface, it reuses it.
#
# Cross-AI HIGH-3: do NOT use the always-true command-substitution
# fallback form. That masks ALL git grep failures (wrong-dir /
# not-in-git / bad pathspec collapse to silent exit 0 false pass).
# Use status-aware capture: accept exit 0 (matches) and exit 1 (no
# matches), fail on anything else.
#
# Cross-AI MEDIUM-3: -I flag skips binary files. Without it, a binary
# blob byte-coincidentally containing the literal prints
# `Binary file X matches` — not file:line:content, breaks D-09.
#
# Cross-AI MEDIUM-2: pluralize "1 match" vs "N matches" per D-09 example.
check_surface() {
  local label="$1" literal="$2"
  local matches status count noun

  set +e
  matches=$(git grep -I -F -n -e "$literal" -- . \
              ':!bin/rename.sh' \
              ':!bin/verify-rename.sh' \
              ':!ci/test-rename.sh' \
              ':!ci/test-rename-gates.sh' \
              ':!ci/test-verify-rename.sh')
  status=$?
  set -e

  case "$status" in
    0) ;;                                   # matches present — fall through
    1) echo "0"; return 0 ;;                # no matches — clean
    *) fail "git grep failed (exit $status) while checking $label" ;;
  esac

  # Status 0: at least one match. Count lines (POSIX `grep -c '^'`).
  count=$(printf '%s\n' "$matches" | grep -c '^')

  # Cross-AI MEDIUM-2: singular vs plural noun.
  noun="matches"
  [ "$count" = "1" ] && noun="match"

  # D-09 block to stderr.
  printf '%s leak (%d %s for "%s"):\n' "$label" "$count" "$noun" "$literal" >&2
  printf '%s\n' "$matches" | sed 's/^/  /' >&2
  printf '\n' >&2

  echo "$count"
}

# ── Main: 5 surface checks + summary on failure ───────────────────────
APP_NAME_HITS=$(check_surface "APP_NAME" "$APP_NAME_ORIG")
BUNDLE_ID_HITS=$(check_surface "BUNDLE_ID" "$BUNDLE_ID_ORIG")
EMAIL_HITS=$(check_surface "EMAIL" "$EMAIL_ORIG")
SLUG_HITS=$(check_surface "SLUG" "$SLUG_ORIG")
YEAR_HITS=$(check_surface "YEAR" "$YEAR_ORIG")

TOTAL=$((APP_NAME_HITS + BUNDLE_ID_HITS + EMAIL_HITS + SLUG_HITS + YEAR_HITS))

# Count surfaces with non-zero matches.
SURFACES_LEAKED=0
[ "$APP_NAME_HITS"  -gt 0 ] && SURFACES_LEAKED=$((SURFACES_LEAKED + 1))
[ "$BUNDLE_ID_HITS" -gt 0 ] && SURFACES_LEAKED=$((SURFACES_LEAKED + 1))
[ "$EMAIL_HITS"     -gt 0 ] && SURFACES_LEAKED=$((SURFACES_LEAKED + 1))
[ "$SLUG_HITS"      -gt 0 ] && SURFACES_LEAKED=$((SURFACES_LEAKED + 1))
[ "$YEAR_HITS"      -gt 0 ] && SURFACES_LEAKED=$((SURFACES_LEAKED + 1))

if [ "$TOTAL" -gt 0 ]; then
  printf 'Verify failed: %d total matches across %d surfaces.\n' \
    "$TOTAL" "$SURFACES_LEAKED" >&2
  exit 1
fi

# All clean: silent exit 0 (per SPEC AC-1).
exit 0
