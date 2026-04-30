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
