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

# ── Globals (set by parse_args; consumed by gate functions + main) ───────
APP_NAME=""
BUNDLE_ID=""
DISPLAY_NAME=""
EMAIL=""
SLUG=""
DRY_RUN=0
FORCE=0

# ── Argument parsing (function; called by main in T7) ────────────────────
# MEDIUM-3 split-flag rejection: --email VAL / --slug VAL reject
# missing values AND values starting with '-'.
parse_args() {
  local POSITIONAL=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        print_usage; exit 0 ;;
      --dry-run)
        DRY_RUN=1; shift ;;
      --force)
        FORCE=1; shift ;;
      --email=*)
        EMAIL="${1#--email=}"; shift ;;
      --email)
        [ $# -ge 2 ] || fail "--email requires a value (e.g. --email=address@example.com)"
        case "$2" in -*) fail "--email value cannot start with '-' (got '$2')";; esac
        EMAIL="$2"; shift 2 ;;
      --slug=*)
        SLUG="${1#--slug=}"; shift ;;
      --slug)
        [ $# -ge 2 ] || fail "--slug requires a value (e.g. --slug=acme/myapp)"
        case "$2" in -*) fail "--slug value cannot start with '-' (got '$2')";; esac
        SLUG="$2"; shift 2 ;;
      -*)
        fail "unknown flag '$1' — run with -h for usage" ;;
      *)
        POSITIONAL+=("$1"); shift ;;
    esac
  done

  if [ "${#POSITIONAL[@]}" -lt 3 ]; then
    fail "missing required positional args — usage: bin/rename.sh APP_NAME BUNDLE_ID DISPLAY_NAME --email=EMAIL [--slug=OWNER/REPO]"
  fi
  APP_NAME="${POSITIONAL[0]}"
  BUNDLE_ID="${POSITIONAL[1]}"
  DISPLAY_NAME="${POSITIONAL[2]}"
}

# ── HIGH-7 input-gate helper (function; called by validate_args) ─────────
# The sed delimiter is `|` and BSD sed cannot handle multi-line
# replacements via single-line `s|...|...|` form. Reject these
# characters at the gate so downstream sed_escape_replacement only
# has to handle &, \, |.
reject_special_chars() {
  local label="$1" value="$2"
  case "$value" in
    *$'\n'*) fail "$label contains a newline — not supported (got: $(printf %q "$value"))" ;;
  esac
  case "$value" in
    *'|'*) fail "$label contains '|' — not supported (sed delimiter; got: $value)" ;;
  esac
}

# ── Args-validation gates 3, 4, 5, 5b, 5c (function; called by main) ─────
# Cheap regex + non-empty + special-char checks. Does NOT include
# gate 2 (xcodegen — file-system-touching), gates 7+8 (clean-tree +
# on-main — git-state-touching) — those are gate_xcodegen_present(),
# gate_clean_tree(), gate_on_main() defined in T7.
validate_args() {
  step "Pre-flight gates (args validation)"

  # Gate 3: APP_NAME is a valid Swift identifier
  [[ "$APP_NAME" =~ ^[A-Z][a-zA-Z0-9]*$ ]] || \
    fail "invalid APP_NAME '$APP_NAME' — must match ^[A-Z][a-zA-Z0-9]*$ (e.g. MyApp, no spaces)"
  ok "APP_NAME '$APP_NAME' is a valid Swift identifier"

  # Gate 4: BUNDLE_ID matches reverse-DNS pattern
  [[ "$BUNDLE_ID" =~ ^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$ ]] || \
    fail "invalid BUNDLE_ID '$BUNDLE_ID' — must match reverse-DNS lowercase (e.g. com.acme.myapp)"
  ok "BUNDLE_ID '$BUNDLE_ID' matches reverse-DNS pattern"

  # Gate 5: DISPLAY_NAME non-empty + HIGH-7 input rejection
  [ -n "$DISPLAY_NAME" ] || fail "DISPLAY_NAME is empty — pass a non-empty third positional arg (e.g. \"My App\")"
  reject_special_chars "DISPLAY_NAME" "$DISPLAY_NAME"
  ok "DISPLAY_NAME '$DISPLAY_NAME' is non-empty (no newline / '|')"

  # Gate 5b: --email required + HIGH-7 input rejection
  [ -n "$EMAIL" ] || fail "--email is required — pass --email=address@example.com"
  reject_special_chars "EMAIL" "$EMAIL"
  ok "--email '$EMAIL' provided (no newline / '|')"

  # Gate 5c: --slug auto-derive if omitted, then HIGH-7 + format check
  if [ -z "$SLUG" ]; then
    local ORIGIN
    ORIGIN=$(git config --get remote.origin.url 2>/dev/null || true)
    [ -n "$ORIGIN" ] || \
      fail "--slug not provided AND no origin remote — pass --slug=OWNER/REPO or set origin"
    SLUG=$(echo "$ORIGIN" \
      | sed -E -e 's#^git@github\.com:##' \
               -e 's#^https://github\.com/##' \
               -e 's#\.git$##')
    ok "--slug auto-derived from origin: '$SLUG'"
  else
    ok "--slug '$SLUG' explicit"
  fi
  reject_special_chars "SLUG" "$SLUG"
  [[ "$SLUG" =~ ^[^/]+/[^/]+$ ]] || \
    fail "invalid --slug '$SLUG' — expected OWNER/REPO (e.g. acme/myapp)"
  ok "SLUG format OK"
}
