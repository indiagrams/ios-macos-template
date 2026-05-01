# Smoke Test on a Disposable Fork

This runbook documents how to validate the full Quickstart-in-5-minutes flow end-to-end against a real, ephemeral GitHub repo. Use it before each major release (e.g., before flipping the template public, before tagging v1.0.0) to catch breakage that piecemeal CI doesn't cover.

The procedure was first run during M4 P4 (2026-04-30); see [`## Failure modes` → `Bundle install: phantom gem reference`](#bundle-install-phantom-gem-reference) for the defect that run discovered and the fix applied.

## Prerequisites

Before starting:

- **`gh` CLI** (`brew install gh`); authenticated via `gh auth login` with `repo` + `delete_repo` token scopes
- **Homebrew** (`brew --version` ≥ 4.x)
- **Xcode CLI** (`xcodebuild -version` returns valid output)
- **`git config user.name` + `user.email`** set (rename produces a commit; identity must be configured)
- **`is_template=true`** on the source repo (`gh api repos/indiagrams/ios-macos-template --jq '.is_template'` returns `true`). The template flag is set during M4 P4 and persists. M5 P3 will inherit it when flipping visibility public.
- **Working tree clean** in your local checkout; smoke-test clone goes into a sibling directory

## Procedure

The smoke test creates a real public repo (`indiagrams/ios-macos-smoke-test`), runs the full Quickstart flow against it, verifies branch protection, then deletes the repo. Total wall time on a warm dev machine: ~10-15 min.

```bash
# 1. From this repo's parent directory, create a smoke-test repo from the template.
cd ..
SMOKE_REPO="indiagrams/ios-macos-smoke-test"
SOURCE_REPO="indiagrams/ios-macos-template"
SMOKE_DIR_ABS="$(pwd)/$(basename "$SMOKE_REPO")"

gh repo create "$SMOKE_REPO" \
  --template "$SOURCE_REPO" \
  --public --clone

# 2. Settle for GitHub's async template-instantiation (~5s typical).
sleep 5

# 3. Re-checkout HEAD in case template files propagated post-clone.
( cd "$SMOKE_DIR_ABS" && git checkout HEAD -- . 2>/dev/null || true )

# 4. Defense-in-depth fallback if the working tree is still empty after settle.
if [ ! -d "$SMOKE_DIR_ABS/.git" ] || \
   [ -z "$(ls -A "$SMOKE_DIR_ABS" 2>/dev/null | grep -v '^\.git$' || true)" ]; then
  rm -rf "$SMOKE_DIR_ABS"
  sleep 3
  git clone "https://github.com/$SMOKE_REPO.git" "$SMOKE_DIR_ABS"
fi
cd "$SMOKE_DIR_ABS"

# 5. Substitute identity strings.
./bin/rename.sh SmokeApp com.example.smokeapp 'Smoke App' --email=smoketest@example.com

# 6. Verify the rename.
./bin/verify-rename.sh

# 7. Bootstrap dependencies (brew bundle + lefthook + xcodegen + bundler).
make bootstrap

# 8. Build green on iOS device (the primary signal).
make check

# 9. Push the renamed clone before configuring branch protection.
git push -u origin main

# 10. Configure branch protection + auto-merge + squash-only.
./bin/setup-github.sh

# 11. Verify branch protection landed (allow ~2s for GitHub API consistency).
sleep 2
gh api "repos/$SMOKE_REPO/branches/main/protection" \
  --jq '.required_status_checks.contexts[]' | sort
# Expected exactly:
#   app (iOS Simulator)
#   app (iOS device)
#   app (macOS)

# 12. Cleanup: delete the smoke-test repo + local clone.
cd ..
gh repo delete "$SMOKE_REPO" --yes
rm -rf "$SMOKE_DIR_ABS"
```

## Timings (M4 P4 first run, 2026-04-30)

The first M4 P4 attempt halted at step 7 (`make bootstrap`) due to a phantom gem in `Gemfile`. Steps that ran cleanly recorded the following timings:

| Step | Wall time | Notes |
|---|---|---|
| Pre-flight (gh + brew + xcode + auth + working-tree gates) | <1s | 9 fail-fast checks |
| Step 1 (`gh repo create --template ... --public --clone`) | ~3s | Returned immediately |
| Step 2-4 (settle + re-checkout + fallback guard) | 5s + ~1s | Settle is intentional |
| Step 5 (`bin/rename.sh`) | ~6s | Substitution across all identity surfaces |
| Step 6 (`bin/verify-rename.sh`) | <1s | Rename verification |
| Step 7a (`make bootstrap` partial: brew + lefthook + xcodegen) | ~52s | Warm Homebrew cache |
| Step 7b (`make bootstrap` continued: `bundle install`) | FAIL | See [Bundle install: phantom gem reference](#bundle-install-phantom-gem-reference) |

The runbook above incorporates the [Gemfile fix](#bundle-install-phantom-gem-reference) shipped in M4 P4's commit, so future runs against `main` post-M4-P4 should reach `make bootstrap` exit 0. Steps 8-12 are documented for completeness; their first end-to-end validation will be the next manual smoke-test run.

## Failure modes

### Bundle install: phantom gem reference

**First seen:** M4 P4 attempt 1, 2026-04-30.

**Symptom:** `make bootstrap` reaches `bundle install` and fails with:

```
Could not find gem 'fastlane-plugin-spaceship_logs' in rubygems repository https://rubygems.org/.
```

**Root cause:** The template's pre-M4-P4 `Gemfile` declared `gem "fastlane-plugin-spaceship_logs", require: false` (commented as "Used by ci/bump-asc-version.rb"). Two issues:

1. The gem **does not exist on RubyGems** (`curl https://rubygems.org/api/v1/gems/fastlane-plugin-spaceship_logs.json` returns 404). It was never published.
2. `ci/bump-asc-version.rb` only does `require 'spaceship'` (which is part of fastlane core), not `fastlane-plugin-spaceship_logs`. The Gemfile reference was a vestigial mistake.

**Fix (shipped in M4 P4):** Removed the phantom-gem line from `Gemfile`. Forkers cloning post-M4-P4 will get a clean `bundle install`.

**For pre-M4-P4 forks (rare):** delete the offending line manually:

```bash
sed -i.bak '/fastlane-plugin-spaceship_logs/d' Gemfile && rm Gemfile.bak
```

### Brief unprotected window between push and setup-github.sh

There is a small window between step 9 (`git push -u origin main`) and step 10 (`bin/setup-github.sh`) where `main` exists on the remote without branch-protection rules. This is unavoidable — branch protection requires the branch to exist first.

For an ephemeral smoke-test repo, the window is harmless. For production forks, run the full Quickstart in a single sitting and don't leave the repo in this state overnight (no PRs queued; no untrusted collaborators).

### Async template instantiation: empty working tree post-clone

Closed via M4 P4 HIGH-1.1 closure. The cause: `gh repo create --template --clone` returns when the local clone completes, but GitHub's backend may still be propagating template source files into the new repo. The `sleep 5` settle + `git checkout HEAD -- .` re-population pattern handles this. The fallback `git clone` retry is the belt-and-suspenders defense.

## Cleanup

If the smoke test fails mid-flow, the procedure includes a trap-on-EXIT that runs:

```bash
# delete the remote
gh repo delete "$SMOKE_REPO" --yes
# remove the local clone
rm -rf "$SMOKE_DIR_ABS"
# preserve transient logs (../bootstrap.log, ../check.log, ../setup-github.log,
# ../smoke-cleanup.log) for diagnosis if rc != 0
```

If the trap doesn't fire (e.g., kill -9), manually:

```bash
gh repo delete "indiagrams/ios-macos-smoke-test" --yes 2>/dev/null
rm -rf "../ios-macos-smoke-test"
rm -f ../bootstrap.log ../check.log ../setup-github.log ../smoke-cleanup.log
```

## Cross-org verification

The smoke test above validates the same-org template-fork path
(`indiagrams/ios-macos-template` → `indiagrams/ios-macos-smoke-test`).
The cross-org verification adds two coverage axes — a different org
(`prakashrj/`) and the no-arg auto-detect form of `bin/setup-github.sh` —
to confirm the script has no hardcoded org assumptions. Run this before
any major release that affects forker onboarding (e.g., before flipping
the template public).

### When to run

- Before flipping the template public (M5 P3): confirms any forker in any
  org can run `bin/setup-github.sh` against their fork.
- After non-trivial edits to `bin/setup-github.sh` (rename of CI check
  names; addition/removal of branch-protection fields; merge-mode tweaks).
- As a periodic regression check at major release boundaries.

### Procedure

```bash
# 0. Pre-flight: confirm both throwaway repos do not exist; gh has
#    repo + delete_repo + admin:repo_hook scopes; both orgs admin-accessible.
gh auth status
gh repo view indiagrams/ios-macos-smoke-test 2>&1 | grep -q 'Could not resolve'
gh repo view prakashrj/ios-macos-cross-org-test 2>&1 | grep -q 'Could not resolve'

# 1. Same-org: re-create indiagrams/ios-macos-smoke-test from template +
#    apply HIGH-1.1 settle pattern.
cd ..
INDIAGRAMS_DIR_ABS="$(pwd)/ios-macos-smoke-test"
gh repo create indiagrams/ios-macos-smoke-test \
  --template indiagrams/ios-macos-template \
  --public --clone
sleep 5
( cd "$INDIAGRAMS_DIR_ABS" && git checkout HEAD -- . 2>/dev/null || true )

# 2. Run setup-github.sh (explicit form, same-org). Verify protection.
cd ios-macos-template
bin/setup-github.sh indiagrams/ios-macos-smoke-test
sleep 2
gh api repos/indiagrams/ios-macos-smoke-test/branches/main/protection \
  --jq '.required_status_checks.contexts[]' | sort
# Expected exactly:
#   app (iOS Simulator)
#   app (iOS device)
#   app (macOS)

# 3. Idempotency: run setup-github.sh AGAIN. Capture full protection JSON
#    before + after; assert byte-identical.
PROTECTION_BEFORE=$(gh api repos/indiagrams/ios-macos-smoke-test/branches/main/protection --jq '.')
bin/setup-github.sh indiagrams/ios-macos-smoke-test
sleep 2
PROTECTION_AFTER=$(gh api repos/indiagrams/ios-macos-smoke-test/branches/main/protection --jq '.')
[ "$PROTECTION_BEFORE" = "$PROTECTION_AFTER" ] || echo "FAIL: protection drifted on re-run"

# 4. Cross-org: create prakashrj/ios-macos-cross-org-test with --add-readme
#    (creates main + initial README commit immediately; no template race).
cd ..
CROSS_ORG_DIR_ABS="$(pwd)/ios-macos-cross-org-test"
gh repo create prakashrj/ios-macos-cross-org-test \
  --public --clone --add-readme
sleep 2

# 5. Run setup-github.sh (explicit form, cross-org). Verify protection +
#    state-vector.
cd ios-macos-template
bin/setup-github.sh prakashrj/ios-macos-cross-org-test
sleep 2
gh api repos/prakashrj/ios-macos-cross-org-test/branches/main/protection \
  --jq '.required_status_checks.contexts[]' | sort
gh api repos/prakashrj/ios-macos-cross-org-test \
  --jq '[.allow_squash_merge, .allow_merge_commit, .allow_rebase_merge, .allow_auto_merge, .delete_branch_on_merge]'
# Expected: [true,false,false,true,true]

# 6. No-arg auto-detect form: run setup-github.sh from inside the
#    cross-org clone with no arguments.
cd "$CROSS_ORG_DIR_ABS"
"$(pwd)/../ios-macos-template/bin/setup-github.sh"   # no args
cd -

# 7. Cleanup (trap-on-EXIT in the orchestration; this is the manual form):
gh repo delete indiagrams/ios-macos-smoke-test --yes
gh repo delete prakashrj/ios-macos-cross-org-test --yes
rm -rf "$INDIAGRAMS_DIR_ABS" "$CROSS_ORG_DIR_ABS"
```

### Expected outcomes

- All 4 `bin/setup-github.sh` invocations exit 0 (1 same-org explicit +
  1 same-org idempotent re-run + 1 cross-org explicit + 1 cross-org no-arg).
- Both repos' `main` branch protection has exactly the 3 required CI
  check names: `app (iOS Simulator)`, `app (iOS device)`, `app (macOS)`.
- Both repos' merge-mode + auto-delete state-vector returns
  `[true,false,false,true,true]`.
- Idempotent re-run on `indiagrams/ios-macos-smoke-test` produces
  byte-identical protection JSON between the two invocations.
- Both throwaway repos return 404 from `gh repo view` post-cleanup.

### Cleanup

The orchestration runs a trap-on-EXIT chain that deletes both throwaway
repos and removes both local clones automatically (whether the run
succeeded or failed). On failure, the cleanup chain preserves the
invocation logs for diagnosis.

If the trap does not fire (e.g., `kill -9`), manually:

```bash
gh repo delete indiagrams/ios-macos-smoke-test --yes 2>/dev/null
gh repo delete prakashrj/ios-macos-cross-org-test --yes 2>/dev/null
rm -rf ../ios-macos-smoke-test ../ios-macos-cross-org-test
rm -f ../indiagrams-*.log ../prakashrj-*.log ../cleanup-*.log
```

### This run (2026-05-01)

The procedure was executed during M5 P2 against:

- `indiagrams/ios-macos-smoke-test` — created at 2026-05-01T03:06:18Z;
  re-created via template fork; deleted in cleanup
- `prakashrj/ios-macos-cross-org-test` — created at 2026-05-01T03:06:41Z;
  created via `--add-readme`; deleted in cleanup

Timings (wall time, all 4 setup-github invocations):

| Step | Wall time |
|---|---|
| `bin/setup-github.sh indiagrams/...` (explicit) | 0m1.555s |
| `bin/setup-github.sh indiagrams/...` (idempotent re-run) | 0m1.632s |
| `bin/setup-github.sh prakashrj/...` (explicit) | 0m1.332s |
| `bin/setup-github.sh` (no-arg, cross-org) | 0m1.271s |

Both repos reached protection-converged state on the first invocation;
idempotent re-run on the indiagrams repo produced byte-identical
protection JSON; the no-arg auto-detect form on the prakashrj clone
correctly resolved `prakashrj/ios-macos-cross-org-test` from origin.
`bin/setup-github.sh` has zero hardcoded `indiagrams`/`prakashrj`
references — confirmed via execute-time grep audit
(per REVIEWS MEDIUM-8 + gemini-LOW-1 closure).

## Re-running

The smoke test can be re-run anytime — typically before each major release:

- **Before flipping public (M5 P3):** confirms the template still works for forkers.
- **Before tagging v1.0.0 (M5 P4):** final integration check.
- **After major template surface changes:** if `bin/`, `Makefile`, `Brewfile`, or `app/project.yml` change non-trivially.
- **After Brewfile dependency updates:** to catch upstream Homebrew breakage.

Pre-conditions for re-run:
- The smoke-test repo (`indiagrams/ios-macos-smoke-test`) must NOT exist (404 from `gh repo view`). The procedure deletes it at end; if a previous run left it behind (cleanup didn't fire), delete manually first.
- `is_template=true` on source. Set during M4 P4; should persist.
- Working tree clean.

## See also

- M4 P3 (`CHANGELOG.md` + tagging strategy) — defines the release cadence the smoke test gates.
- M4 P2 (`README.md` "Quickstart in 5 minutes") — the canonical 4-command flow this smoke test validates end-to-end.
- M3 P4 AC-04-7 — the deferred manual smoke test M4 P4 closes out.
