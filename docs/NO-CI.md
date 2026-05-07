# Local-only mode (no GitHub Actions)

If your fork ships from your laptop, not from CI, you can disable the GitHub Actions release pipeline entirely.

## What changes in local-only mode

| | CI mode (default) | Local-only mode |
|---|---|---|
| Where you run `make ship` | GitHub Actions runner | Your Mac |
| Code signing | fastlane match against private certs repo | Local Keychain (Xcode "Automatically manage signing") |
| Required GH Secrets | 7 (ASC API key, match password, etc.) | 0 |
| Bootstrap pipeline length | 17 steps | 11 steps |
| Branch protection | 7 required CI checks | None (set yourself if you want) |

Local-only mode is appropriate for:

- **Solo indie shipping** — you trust your own laptop, no team workflow
- **Personal apps** — no need to gate merges on CI
- **Apps where match overhead exceeds benefit** — single dev, single machine, occasional ships

CI mode is the right default for everyone else (multi-dev, security-sensitive, or any case where local laptop drift would be a liability).

## How to enable local-only mode

### 1. Set RELEASE_MODE in `.bootstrap.env`

```bash
# .bootstrap.env
RELEASE_MODE=local
APP_NAME=YourApp
APP_BUNDLE_ID=com.yourorg.yourapp
FASTLANE_TEAM_ID=ABCD1234567
ASC_API_KEY_ID=...
ASC_API_KEY_ISSUER_ID=...
ASC_API_KEY_P8_PATH=~/.config/secrets/AuthKey_XXX.p8
ASC_APP_SKU=YOURAPP_SKU
ASC_APP_NAME=Your App Display Name
# CI-only fields (CERTS_REPO, MATCH_PASSWORD, etc.) — leave unset or omit
```

`make doctor` will detect `RELEASE_MODE=local` and skip the 6 CI-only steps (CreateCertsRepo, GHSecrets, BootstrapCerts, MintInstaller, EditMatchfile, etc.).

### 2. Disable the PR + release workflows

You have two options:

**A. Delete the workflows**

```bash
rm .github/workflows/pr.yml
rm .github/workflows/release.yml
git add .github/workflows
git commit -m "chore: remove CI workflows for local-only mode"
git push
```

You lose the PR-time build/test signal, but `make ship` still works locally because it shells into `ci/local-release-check.sh` directly (no Actions dependency).

**B. Keep them but turn off branch protection**

Branch protection requires the 6 CI checks to pass before merging. Without CI, those checks never run → PRs can never merge. Disable via:

```bash
gh api -X DELETE repos/$YOUR_ORG/$YOUR_REPO/branches/main/protection
```

Or in the GitHub web UI: Settings → Branches → main → Delete rule.

### 3. Skip `make setup-github`

`bin/setup-github.sh` configures the 7 required CI checks. In local-only mode, don't run it (or remove it from your `make all` target).

## What `make ship` does in local-only mode

The same `make ship` command works on your Mac as on CI. It:

1. Reads `.bootstrap.env`
2. Reads `RELEASE_MODE=local` → uses Xcode-managed signing instead of match
3. Runs `ci/local-release-check.sh` to archive + export iOS .ipa + macOS .pkg
4. Runs `fastlane pilot` to upload to TestFlight
5. Pushes a `vYYYY.WW.<run_number>` tag

`<run_number>` in local mode is sourced from a local counter (`fastlane/.local_run_number`) since there's no GitHub `${{ github.run_number }}` to use.

## Bootstrap.env minimum for local-only

The minimum to reach a green `make doctor` in local mode:

```bash
RELEASE_MODE=local
APP_NAME=YourApp
APP_BUNDLE_ID=com.yourorg.yourapp
FASTLANE_TEAM_ID=ABCD1234567
ASC_API_KEY_ID=...
ASC_API_KEY_ISSUER_ID=...
ASC_API_KEY_P8_PATH=~/.config/secrets/AuthKey_XXX.p8
ASC_APP_SKU=YOURAPP
ASC_APP_NAME=Your App Display Name
PLATFORMS=ios,macos
```

(Same as CI mode minus the certs/match fields.)

## When to switch back to CI mode

You'll want CI mode if any of these become true:

- A second human starts contributing
- You ship from multiple machines
- You want PR-time test signal
- You want the weekly canary pattern to validate Apple-side state

The switch is reversible: change `RELEASE_MODE=ci`, run `make bootstrap-fork` (the now-active CI-only steps will run), restore the workflows + branch protection.

## See also

- [`docs/BOOTSTRAP.md`](BOOTSTRAP.md) — full `.bootstrap.env` reference (RELEASE_MODE table at the top)
- [`bin/lib/bootstrap.rb`](../bin/lib/bootstrap.rb) — `Step::MODES` constant tells you which steps are CI-only / local-only / both
