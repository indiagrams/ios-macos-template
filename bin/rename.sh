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

# ── Reset-hard rollback (REQ-7; HIGH-1 closure — replaces broken stash) ───
#
# Background: the prior plan iteration used `git stash push --include-untracked`
# to capture pre-state. On a clean working tree (which Gate 7 requires),
# `git stash` creates NO entry and SNAPSHOT_CREATED stays 0 → rollback
# was a no-op → mutations were never undone. Cross-AI HIGH-1.
#
# Fix: leverage Gate 7's clean-tree precondition. Pre-mutation HEAD ==
# working tree, so `git reset --hard HEAD` restores tracked-file
# modifications and `git mv` staging. Plus:
#
#   - rm -rf app/$APP_NAME.xcodeproj  (regenerated dir is gitignored;
#     `git clean -fd` without -x won't touch it)
#   - git clean -fd                    (removes new untracked files;
#     NEVER -fdx — forker's .env.local would be deleted)
#
# No git stash. No SNAPSHOT_REF. No snapshot_drop_on_success.
#
# iter-6 BLOCKER-iter5-1 closure: MUTATION_STARTED guard flag prevents
# the trap from firing destructive ops on a pre-mutation gate failure
# (e.g. dirty-tree gate fails → trap → reset --hard → DESTROYS the
# forker's uncommitted work). The flag is initialized to 0 here at
# file scope and flipped to 1 inside main() right before the first
# mutation call (apply_substitutions). rollback() early-outs unless
# the flag is set.

ROLLBACK_DONE=0
MUTATION_STARTED=0  # set to 1 in main() right before first mutation

rollback() {
  # Idempotent — only fires once even if both ERR and EXIT trip.
  [ "$ROLLBACK_DONE" = "1" ] && return 0
  ROLLBACK_DONE=1

  # iter-6 BLOCKER-iter5-1: pre-mutation early-out. If no mutations
  # were made, nothing to roll back — and running git reset --hard
  # HEAD on a forker's dirty working tree (e.g. when the clean-tree
  # gate failed and triggered the EXIT trap) would DESTROY the
  # forker's uncommitted work. main() flips MUTATION_STARTED=1
  # right before the first mutation call (apply_substitutions); any
  # failure BEFORE that point lands here as a no-op rollback.
  [ "$MUTATION_STARTED" = "1" ] || return 0

  printf '    ✗ rolling back to pre-rename state...\n' >&2

  # Step 1: remove the regenerated xcodeproj if T7 ran (it's gitignored,
  # so `git clean -fd` without -x won't touch it). APP_NAME may be
  # unset if rollback fires before arg parsing — guard.
  if [ -n "${APP_NAME:-}" ] && [ -d "app/$APP_NAME.xcodeproj" ]; then
    rm -rf "app/$APP_NAME.xcodeproj" 2>/dev/null || true
  fi

  # Step 2: git reset --hard restores tracked-file modifications +
  # git mv staging back to HEAD.
  if git reset --hard HEAD --quiet 2>/dev/null; then
    # Step 3: git clean -fd removes any NEW untracked files xcodegen
    # may have created alongside. NOT -fdx — forker's .env.local etc.
    # are precious. Pre-flight Gate 7 already required clean tree, so
    # there should be nothing else to clean except what THIS script
    # introduced.
    git clean -fd --quiet 2>/dev/null || true
    printf '    ✗ rolled back to pre-rename state.\n' >&2
  else
    printf '    ✗ git reset --hard HEAD failed; manual recovery required.\n' >&2
    printf '    ✗ inspect: git status; git log --oneline -5\n' >&2
  fi
}

# Trap on ERR + EXIT + signals (Ctrl-C = INT, kill = TERM)
# The traps remain armed for the entire mutation phase (T5/T6/T7); they
# are disarmed by main() on the success path via `trap - ERR EXIT INT TERM`.
trap 'rollback' ERR
trap 'rollback' INT TERM
trap 'rollback' EXIT

# ── Substitution-target enumeration (REQ-2; HIGH-2 + MEDIUM-1 closure) ───

# Why -nw -e P1 -e P2 (not -nE '(\b|^)P\b'):
# M2 P5 cross-AI HIGH-1 (Codex): the regex form silently false-passes
# in git grep — returns 0 hits when 14 are present. -nw is git-grep-
# native and reliable. Carry-forward.
#
# Why -F on com.example.helloapp / maintainers@indiagram.com /
# indiagrams/ios-macos-template (MEDIUM-1):
# Without -F, the literal `.` in these patterns is regex any-char.
# `git grep -nw -e com.example.helloapp` would match `comXexampleXhelloapp`
# (none exist in tree, but the principle is wrong). -F treats the
# pattern as fixed-string. -F + -w combine correctly in git grep.
#
# Why :!bin/rename.sh :!ci/test-rename.sh exclusions (HIGH-2):
# bin/rename.sh contains every substitution-surface literal in its
# print_usage block, error messages, sed patterns, etc. Without
# exclusion, the broad HelloApp -> APP_NAME sweep would rewrite the
# running script — corrupting future runs. Same for ci/test-rename.sh
# (contains HelloApp, com.example.helloapp, etc. in test fixtures).

# The shared pathspec exclusion list (used everywhere)
PATHSPEC_EXCLUSIONS=(
  ':!.planning'
  ':!LICENSE'
  ':!app/HelloApp.xcodeproj'
  ':!bin/rename.sh'
  ':!ci/test-rename.sh'
)

enumerate_targets() {
  git grep -nw \
    -e HelloApp \
    -F -e com.example.helloapp \
    -F -e maintainers@indiagram.com \
    -e '<year>' \
    -F -e 'indiagrams/ios-macos-template' \
    -- . "${PATHSPEC_EXCLUSIONS[@]}" \
    2>/dev/null \
    || true
}

enumerate_target_files() {
  enumerate_targets | awk -F: '{print $1}' | sort -u
}

# ── Substitutions (REQ-2, REQ-9; D-1; HIGH-6 placeholder + HIGH-7 escape) ─

# HIGH-7 closure: escape sed replacement metacharacters &, \, |.
# Input gates (T2 reject_special_chars) already reject newlines and '|'
# in DISPLAY_NAME/EMAIL/SLUG, so this helper handles the residual cases:
#   - '&'  → in sed replacement, '&' = entire match. Escape to '\&'.
#   - '\'  → backslash. Escape to '\\'.
#   - '|'  → already rejected at gate, but escape to '\|' as belt-suspenders.
# The order matters: backslash MUST be escaped first (otherwise its escape
# would re-escape the others).
sed_escape_replacement() {
  printf '%s' "$1" | sed -e 's/[\&|]/\\&/g'
}

# The DISPLAY_NAME placeholder (HIGH-6 closure). Chosen so it does NOT
# contain HelloApp, com.example.helloapp, maintainers@indiagram.com,
# <year>, indiagrams/ios-macos-template — none of the broad sweeps
# will mutate it. Verified zero hits in current tree.
DISPLAY_PLACEHOLDER='__GSD_DISPLAY_PLACEHOLDER__'

apply_substitutions() {
  local year escaped_email escaped_slug escaped_display
  year=$(date +%Y)
  escaped_email=$(sed_escape_replacement "$EMAIL")
  escaped_slug=$(sed_escape_replacement "$SLUG")
  escaped_display=$(sed_escape_replacement "$DISPLAY_NAME")

  # Step A: <year> -> current year (3 source sites; pre-xcodegen)
  step "Substituting <year> -> $year"
  git grep -lw -e '<year>' -- . "${PATHSPEC_EXCLUSIONS[@]}" 2>/dev/null \
    | while read -r f; do
        sed -i '' "s|<year>|$year|g" "$f"
        ok "<year> substituted in $f"
      done

  # Step B: com.example.helloapp -> $BUNDLE_ID
  # BUNDLE_ID is regex-validated to match ^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$
  # so cannot contain &, \, |, newline. No escape needed.
  step "Substituting com.example.helloapp -> $BUNDLE_ID"
  git grep -lw -F -e 'com.example.helloapp' -- . "${PATHSPEC_EXCLUSIONS[@]}" 2>/dev/null \
    | while read -r f; do
        sed -i '' "s|com\.example\.helloapp|$BUNDLE_ID|g" "$f"
        ok "bundle ID substituted in $f"
      done

  # Step C: maintainers@indiagram.com -> $EMAIL (escaped — HIGH-7)
  step "Substituting maintainers@indiagram.com -> $EMAIL"
  git grep -lw -F -e 'maintainers@indiagram.com' -- . "${PATHSPEC_EXCLUSIONS[@]}" 2>/dev/null \
    | while read -r f; do
        sed -i '' "s|maintainers@indiagram\.com|$escaped_email|g" "$f"
        ok "email substituted in $f"
      done

  # Step D: indiagrams/ios-macos-template -> $SLUG (escaped — HIGH-7)
  step "Substituting indiagrams/ios-macos-template -> $SLUG"
  git grep -lw -F -e 'indiagrams/ios-macos-template' -- . "${PATHSPEC_EXCLUSIONS[@]}" 2>/dev/null \
    | while read -r f; do
        sed -i '' "s|indiagrams/ios-macos-template|$escaped_slug|g" "$f"
        ok "GitHub slug substituted in $f"
      done

  # Step E_NEW: DISPLAY_NAME anchored sites -> placeholder (HIGH-6 closure)
  # The placeholder is a literal string with no regex metachars and
  # no HelloApp/com.example.helloapp/etc. literal substrings — it
  # passes through Step F (broad HelloApp -> APP_NAME sweep) untouched.
  step "Replacing DISPLAY_NAME sites with placeholder (HIGH-6)"

  if [ -f app/project.yml ]; then
    sed -i '' "s|CFBundleDisplayName: HelloApp|CFBundleDisplayName: $DISPLAY_PLACEHOLDER|g" app/project.yml
    ok "DISPLAY placeholder set in app/project.yml (2 CFBundleDisplayName sites)"
  fi

  if [ -f app/Shared/ContentView.swift ]; then
    sed -i '' "s|Text(\"HelloApp\")|Text(\"$DISPLAY_PLACEHOLDER\")|g" app/Shared/ContentView.swift
    ok "DISPLAY placeholder set in app/Shared/ContentView.swift"
  fi

  if [ -f app/UITests/AppStoreScreenshotTests.swift ]; then
    sed -i '' "s|staticTexts\[\"HelloApp\"\]|staticTexts[\"$DISPLAY_PLACEHOLDER\"]|g" app/UITests/AppStoreScreenshotTests.swift
    ok "DISPLAY placeholder set in app/UITests/AppStoreScreenshotTests.swift"
  fi

  if [ -f fastlane/metadata/en-US/name.txt ]; then
    sed -i '' "s|^HelloApp$|$DISPLAY_PLACEHOLDER|" fastlane/metadata/en-US/name.txt
    ok "DISPLAY placeholder set in fastlane/metadata/en-US/name.txt"
  fi

  # Step F: HelloApp -> $APP_NAME (broad sweep; placeholder unaffected
  # because __GSD_DISPLAY_PLACEHOLDER__ contains no HelloApp substring)
  # APP_NAME is regex-validated [A-Z][a-zA-Z0-9]*; no escape needed.
  step "Substituting HelloApp -> $APP_NAME (broad sweep)"
  git grep -lw -e 'HelloApp' -- . "${PATHSPEC_EXCLUSIONS[@]}" 2>/dev/null \
    | while read -r f; do
        sed -i '' "s|HelloApp|$APP_NAME|g" "$f"
        ok "HelloApp substituted in $f"
      done

  # HIGH-2 belt-and-suspenders assertion: bin/rename.sh and
  # ci/test-rename.sh MUST be bit-identical to pre-substitution.
  # Pathspec exclusion is the primary defense; this is the falsifiable
  # check that the defense worked.
  git diff --quiet -- bin/rename.sh ci/test-rename.sh 2>/dev/null \
    || fail "HIGH-2 violation: bin/rename.sh or ci/test-rename.sh modified by substitution sweep"
  ok "self-exclusion verified — bin/rename.sh + ci/test-rename.sh unchanged"

  # Step G_NEW: placeholder -> $DISPLAY_NAME (escaped — HIGH-7)
  step "Replacing placeholder with DISPLAY_NAME (HIGH-6)"
  git grep -lw -F -e "$DISPLAY_PLACEHOLDER" -- . "${PATHSPEC_EXCLUSIONS[@]}" 2>/dev/null \
    | while read -r f; do
        sed -i '' "s|$DISPLAY_PLACEHOLDER|$escaped_display|g" "$f"
        ok "DISPLAY_NAME substituted in $f"
      done

  # HIGH-6 verifiable assertion: zero placeholder matches post-Step-G.
  # If the placeholder remains anywhere, Step G failed to clean up.
  REMAINING=$(git grep -F -c -e "$DISPLAY_PLACEHOLDER" -- . "${PATHSPEC_EXCLUSIONS[@]}" 2>/dev/null \
              | awk -F: 'BEGIN{s=0} $2>0{s+=$2} END{print s}' || true)
  [ "${REMAINING:-0}" = "0" ] || \
    fail "HIGH-6 violation: $REMAINING placeholder match(es) remain after Step G"
  ok "placeholder fully replaced (0 remaining)"
}

# ── Idempotency + partial-rename detection (REQ-6, REQ-10; HIGH-3) ───────

# Returns 0 if fully renamed (caller should silent-exit-0).
# Returns 1 if partial-rename state (caller should fail unless --force).
# Returns 2 if pre-rename state (caller should proceed normally).
check_idempotency() {
  local target_xcodeproj="app/$APP_NAME.xcodeproj"
  local target_swift="app/Shared/$APP_NAME.swift"
  local target_ios_ent="app/iOS/$APP_NAME.entitlements"
  local target_macos_ent="app/macOS/$APP_NAME.entitlements"

  local source_swift="app/Shared/HelloApp.swift"
  local source_ios_ent="app/iOS/HelloApp.entitlements"
  local source_macos_ent="app/macOS/HelloApp.entitlements"

  local renamed=0
  [ -d "$target_xcodeproj" ] && renamed=$((renamed + 1))
  [ -f "$target_swift" ] && [ ! -f "$source_swift" ] && renamed=$((renamed + 1))
  [ -f "$target_ios_ent" ] && [ ! -f "$source_ios_ent" ] && renamed=$((renamed + 1))
  [ -f "$target_macos_ent" ] && [ ! -f "$source_macos_ent" ] && renamed=$((renamed + 1))

  local source_present=0
  [ -f "$source_swift" ] && source_present=$((source_present + 1))
  [ -f "$source_ios_ent" ] && source_present=$((source_present + 1))
  [ -f "$source_macos_ent" ] && source_present=$((source_present + 1))

  if [ "$renamed" -ge 3 ] && [ "$source_present" -eq 0 ]; then
    return 0  # idempotent no-op (full rename detected)
  fi

  if [ "$renamed" -eq 0 ] && [ "$source_present" -ge 3 ]; then
    return 2  # proceed with normal rename
  fi

  return 1
}

# ── File-path renames via git mv (REQ-3; D-1 mv-after-sed ordering) ──────

rename_file_paths() {
  step "Renaming file paths (3 git mv operations)"

  local pairs=(
    "app/Shared/HelloApp.swift:app/Shared/$APP_NAME.swift"
    "app/iOS/HelloApp.entitlements:app/iOS/$APP_NAME.entitlements"
    "app/macOS/HelloApp.entitlements:app/macOS/$APP_NAME.entitlements"
  )

  local pair src dst
  for pair in "${pairs[@]}"; do
    src="${pair%%:*}"
    dst="${pair##*:}"

    if [ ! -f "$src" ]; then
      fail "rename source missing: $src — repo state unexpected"
    fi

    if [ -e "$dst" ]; then
      fail "rename target already exists: $dst — refusing to overwrite"
    fi

    git mv "$src" "$dst"
    ok "$src -> $dst"
  done
}
