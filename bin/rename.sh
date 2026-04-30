#!/usr/bin/env bash
# bin/rename.sh — fork-rename script for the ios-macos-template.
#
# Substitutes 5 identity surfaces + 1 derived value, renames file paths,
# regenerates xcodeproj. Atomic (all-or-nothing via reset-hard rollback),
# idempotent (silent no-op on re-run with same args), pre-flight-gated.
#
# Usage:
#   bin/rename.sh APP_NAME BUNDLE_ID DISPLAY_NAME --email=EMAIL [--slug=OWNER/REPO] [--dry-run] [--force]
#   bin/rename.sh -h                                # print this usage
#   bin/rename.sh --help                            # alias for -h
#
# Required positional args:
#   APP_NAME       Swift identifier — capitalized, no spaces/dashes/dots/leading digits
#                  (regex: ^[A-Z][a-zA-Z0-9]*$; e.g. MyApp)
#   BUNDLE_ID      Reverse-DNS, lowercase, dot-separated; no underscores/uppercase
#                  (regex: ^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$; e.g. com.acme.myapp)
#   DISPLAY_NAME   Non-empty display name (Apple allows spaces/punctuation).
#                  MUST NOT contain newline or '|' (sed delimiter).
#
# Required flag:
#   --email=EMAIL  Maintainer/security contact email; substitutes
#                  maintainers@indiagram.com across CODE_OF_CONDUCT.md
#                  and SECURITY.md. MUST NOT contain newline or '|'.
#
# Optional flags:
#   --slug=OWNER/REPO   GitHub org/repo slug; substitutes
#                       indiagrams/ios-macos-template across README.md +
#                       CONTRIBUTING.md. If omitted, auto-derives from
#                       `git remote get-url origin`. MUST NOT contain
#                       newline or '|'.
#   --dry-run           Preview substitutions without applying.
#   --force             Override the on-main-branch gate AND the partial-
#                       rename detection gate. Other gates (args validation,
#                       xcodegen presence, sed escapes) still fire.
#
# Argument forms:
#   --email=VAL    (preferred, equal-sign form)
#   --email VAL    (split form — VAL must be non-empty and not start with '-')
#
# Pre-flight gate ORDER (canonical; cross-AI HIGH-3 + MEDIUM-2 fix):
#   1. Args parsing (split-flag values rejected if missing or '-'-prefixed)
#   2. xcodegen on PATH
#   3. APP_NAME matches ^[A-Z][a-zA-Z0-9]*$
#   4. BUNDLE_ID matches ^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$
#   5. DISPLAY_NAME non-empty AND no newline/'|'
#   5b. EMAIL non-empty AND no newline/'|'
#   5c. SLUG non-empty (auto-derived if absent) AND no newline/'|' AND OWNER/REPO format
#   6. Idempotency check (BEFORE clean-tree gate per HIGH-3) —
#      case 0 = silent exit 0 (already renamed)
#      case 1 = partial-rename fail (unless --force)
#      case 2 = proceed
#   7. Working tree is clean (git status --short empty — strict, includes
#      untracked files; this prevents data-loss via reset-hard)
#   8. Current branch is `main` (override via --force)
#
# Idempotency:
#   Re-running with SAME args after a successful first run detects
#   already-renamed state via structural file-path signal counting;
#   exits 0 silently. The check runs BEFORE the clean-tree gate so a
#   second invocation on a dirty post-first-rename tree still resolves
#   correctly.
#
# All-or-nothing (HIGH-1 reset-hard rollback — replaces broken git stash):
#   Pre-flight Gate 7 (clean tree) ensures HEAD == working tree pre-mutation.
#   Any failure in sed/mv/xcodegen steps triggers ERR/EXIT/INT/TERM trap
#   which executes:
#     1. rm -rf app/$APP_NAME.xcodeproj  (regenerated dir is gitignored)
#     2. git reset --hard HEAD --quiet   (restores tracked-file mods + git mv)
#     3. git clean -fd --quiet           (removes new untracked files; NOT -fdx)
#   Exits 1 with stderr "rolled back to pre-rename state."
#
# Constraints:
#   - bash 3.2+ (macOS default); no bash 4+ features
#   - BSD-portable sed (sed -i '', | delimiter, escaped dots)
#   - sed replacement values escaped via sed_escape_replacement (HIGH-7)
#   - No new external dependencies (git, bash, sed, mv, find, grep, xcodegen)

set -euo pipefail

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ✓ %s\n' "$*"; }
fail() { printf '    ✗ %s\n' "$*" >&2; exit 1; }

print_usage() {
  # Print every comment line from line 2 until just before the
  # `set -euo pipefail` body line. Pattern-anchored so the usage block
  # adapts as we extend it across T1-T8 incremental edits.
  sed -n '2,/^set -euo pipefail$/{ /^set -euo pipefail$/!p; }' "$0" | sed 's/^# \{0,1\}//'
}

# ── Argument parsing ──────────────────────────────────────────────────────
# Detect -h / --help BEFORE positional consumption so `bin/rename.sh -h`
# works without any other args (REQ-1, AC-2).
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      print_usage
      exit 0
      ;;
  esac
done

# The remaining arg parsing (positional + flags) lands in T2.
# T1 only delivers: shebang, helpers, print_usage, -h/--help detection.
# All other functionality is added incrementally in T2-T8.
