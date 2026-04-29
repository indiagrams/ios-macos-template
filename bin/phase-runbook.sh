#!/usr/bin/env bash
# bin/phase-runbook.sh — print the canonical GSD per-phase / per-milestone checklist.
#
# Auto-ticks each step based on artifacts already in the phase directory, so
# running it mid-phase shows you exactly where you are. Output is markdown so
# you can paste it into a PR body or commit message.
#
# Usage:
#   bin/phase-runbook.sh <phase>                # phase checklist (auto-ticked)
#   bin/phase-runbook.sh <phase> --raw          # phase checklist, all unchecked
#   bin/phase-runbook.sh --milestone <M>        # milestone wrap-up checklist
#   bin/phase-runbook.sh <phase> --pr <num>     # also write checklist into PR <num>'s body
#
# Phase format: "1", "1.1", "01", "01.1" all work.
# Milestone format: "1", "M1" both work.
#
# Artifact-to-step mapping (auto-tick):
#   *-PLAN.md          → /gsd-plan-phase
#   *-REVIEWS.md       → /gsd-review
#   PLAN.md mtime > REVIEWS.md mtime → /gsd-plan-phase --reviews
#   *-SUMMARY.md       → /gsd-execute-phase
#   *-REVIEW.md        → /gsd-code-review
#   *-REVIEW-FIX.md    → /gsd-code-review-fix
#   *-VERIFICATION.md  → /gsd-verify-work
#   *-SECURITY.md      → /gsd-secure-phase
#   *-VALIDATION.md    → /gsd-validate-phase
#
# Notes:
#   - Idempotent — printing-only by default; --pr writes via `gh pr edit`.
#   - The script doesn't run any GSD command — it shows you what to run next.

set -euo pipefail

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# ── Args ──────────────────────────────────────────────────────────────────────

if [ $# -eq 0 ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,/^set -e/p' "$0" | sed 's/^# \{0,2\}//' | sed '$d'
  exit 0
fi

MODE="phase"
PHASE_ARG=""
MILESTONE_ARG=""
RAW=false
PR_NUM=""

while [ $# -gt 0 ]; do
  case "$1" in
    --milestone)
      MODE="milestone"
      shift
      MILESTONE_ARG="${1:-}"
      [ -z "$MILESTONE_ARG" ] && fail "--milestone needs a value (e.g. --milestone 1)"
      shift
      ;;
    --raw)     RAW=true; shift ;;
    --pr)
      shift
      PR_NUM="${1:-}"
      [ -z "$PR_NUM" ] && fail "--pr needs a PR number"
      shift
      ;;
    *)
      if [ -z "$PHASE_ARG" ] && [ "$MODE" = "phase" ]; then
        PHASE_ARG="$1"
      else
        fail "unknown arg: $1"
      fi
      shift
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Tick mark — `[x]` if condition true, `[ ]` otherwise.
tick() { [ "$1" = "true" ] && printf '[x]' || printf '[ ]'; }

# Resolve phase dir for a phase number. Tries `.planning/phases/<padded>-*`.
# Returns the first match or empty string.
resolve_phase_dir() {
  local phase="$1"
  local padded
  # Pad single-digit phases with leading zero; preserve "X.Y" forms.
  if [[ "$phase" =~ ^[0-9]+$ ]]; then
    padded=$(printf '%02d' "$phase")
  else
    padded="$phase"
  fi
  local match
  match=$(ls -d ".planning/phases/${padded}-"* 2>/dev/null | head -1 || true)
  echo "$match"
}

# Check if a phase artifact exists (e.g. SUMMARY, REVIEWS).
artifact_exists() {
  local phase_dir="$1" suffix="$2"
  [ -n "$phase_dir" ] || return 1
  ls "${phase_dir}"/*-"${suffix}".md >/dev/null 2>&1
}

# Compare PLAN.md mtime to REVIEWS.md — if PLAN is newer, --reviews step ran.
plan_newer_than_reviews() {
  local phase_dir="$1"
  local plan reviews
  plan=$(ls "${phase_dir}"/*-PLAN.md 2>/dev/null | head -1 || true)
  reviews=$(ls "${phase_dir}"/*-REVIEWS.md 2>/dev/null | head -1 || true)
  [ -n "$plan" ] && [ -n "$reviews" ] || return 1
  [ "$plan" -nt "$reviews" ]
}

# ── Phase checklist ───────────────────────────────────────────────────────────

print_phase_checklist() {
  local phase="$1"
  local phase_dir
  phase_dir=$(resolve_phase_dir "$phase")

  local has_plan=false has_reviews=false has_reviews_applied=false
  local has_summary=false has_review=false has_review_fix=false
  local has_verification=false has_security=false has_validation=false

  if ! $RAW && [ -n "$phase_dir" ]; then
    artifact_exists "$phase_dir" PLAN          && has_plan=true
    artifact_exists "$phase_dir" REVIEWS       && has_reviews=true
    plan_newer_than_reviews "$phase_dir"       && has_reviews_applied=true
    artifact_exists "$phase_dir" SUMMARY       && has_summary=true
    artifact_exists "$phase_dir" REVIEW        && has_review=true
    artifact_exists "$phase_dir" REVIEW-FIX    && has_review_fix=true
    artifact_exists "$phase_dir" VERIFICATION  && has_verification=true
    artifact_exists "$phase_dir" SECURITY      && has_security=true
    artifact_exists "$phase_dir" VALIDATION    && has_validation=true
  fi

  cat <<EOF
## GSD Phase ${phase} Checklist

Phase dir: \`${phase_dir:-not yet created}\`

### Plan
- $(tick $has_plan) \`/gsd-plan-phase ${phase}\` — produces PLAN.md
- $(tick $has_reviews) \`/gsd-review ${phase} --codex --gemini\` — produces REVIEWS.md
- $(tick $has_reviews_applied) \`/gsd-plan-phase ${phase} --reviews\` — incorporates REVIEWS.md feedback into PLAN.md

### Execute
- $(tick $has_summary) \`/gsd-execute-phase ${phase}\` — produces SUMMARY.md (atomic commits)

### Review the code
- $(tick $has_review) \`/gsd-code-review ${phase}\` — produces REVIEW.md (HIGH/MED/LOW findings)
- $(tick $has_review_fix) \`/gsd-code-review-fix ${phase} --auto\` — applies fixes (skip if REVIEW.md has 0 findings)

### Verify behaviorally
- $(tick $has_verification) \`/gsd-verify-work ${phase}\` — produces VERIFICATION.md (UAT)

### Security
- $(tick $has_security) \`/gsd-secure-phase ${phase}\` — produces SECURITY.md (threat-model verification)

### Tests
- $(tick "false") \`/gsd-add-tests ${phase}\` — file-driven test generation
- $(tick $has_validation) \`/gsd-validate-phase ${phase}\` — produces VALIDATION.md (requirement-driven gap audit)

---
*Auto-ticked from artifacts in \`${phase_dir:-(phase dir TBD)}\`. Re-run \`bin/phase-runbook.sh ${phase}\` to refresh.*
EOF
}

# ── Milestone wrap-up ─────────────────────────────────────────────────────────

print_milestone_checklist() {
  local milestone="$1"
  # Strip leading "M" if present
  milestone="${milestone#M}"
  milestone="${milestone#m}"

  cat <<EOF
## GSD Milestone M${milestone} Wrap-up Checklist

Run after every phase in M${milestone} is complete.

### Cross-phase audit
- [ ] \`/gsd-audit-uat\` — aggregate UAT/verification gaps across all phases
- [ ] \`/gsd-audit-fix --max 5 --severity high\` — auto-fix HIGH-severity findings (capped at 5)

### Document the milestone
- [ ] \`/gsd-milestone-summary ${milestone}\` — write milestone summary
- [ ] \`/gsd-extract_learnings\` — capture surprises (input to future projects)

### Close
- [ ] \`/gsd-complete-milestone ${milestone}\` — formally close in STATE.md

---
*Re-run \`bin/phase-runbook.sh --milestone ${milestone}\` to print again.*
EOF
}

# ── Optional: write into a PR body ────────────────────────────────────────────

write_to_pr() {
  local body="$1" pr="$2"
  command -v gh >/dev/null 2>&1 || fail "gh CLI not on PATH — install with brew install gh"
  step "Writing checklist into PR #${pr}"
  # Strip the existing checklist section if present, then append the new one.
  local current
  current=$(gh pr view "$pr" --json body --jq .body 2>/dev/null || echo "")
  # Remove any prior "## GSD ... Checklist" section through to the next ## or EOF.
  local cleaned
  cleaned=$(echo "$current" | awk '
    /^## GSD .* Checklist/ { skip=1; next }
    skip && /^## / { skip=0 }
    !skip
  ')
  # Trim trailing blank lines.
  cleaned=$(echo "$cleaned" | sed -e :a -e '/^\s*$/{$d;N;ba' -e '}')
  printf '%s\n\n%s\n' "$cleaned" "$body" | gh pr edit "$pr" --body-file -
  echo "    ✓ PR #${pr} body updated"
}

# ── Main ──────────────────────────────────────────────────────────────────────

if [ "$MODE" = "milestone" ]; then
  OUTPUT=$(print_milestone_checklist "$MILESTONE_ARG")
elif [ "$MODE" = "phase" ]; then
  [ -z "$PHASE_ARG" ] && fail "phase number required (e.g. bin/phase-runbook.sh 3.1)"
  OUTPUT=$(print_phase_checklist "$PHASE_ARG")
else
  fail "unreachable mode: $MODE"
fi

echo "$OUTPUT"

if [ -n "$PR_NUM" ]; then
  write_to_pr "$OUTPUT" "$PR_NUM"
fi
