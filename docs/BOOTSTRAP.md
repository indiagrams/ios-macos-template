# Bootstrap your fork

Time-to-TestFlight: ~15 minutes once your `.bootstrap.env` is filled in.

This template ships a config-driven fork bootstrap. You fill out one file with
your identity + credentials, then `make bootstrap-fork` drives every
programmatic step (rename, push, branch protection, GH Secrets, ASC App
registration, icon swap, …) idempotently. The only manual steps are the ones
Apple and GitHub deliberately don't expose to APIs.

```bash
# 1. Fork from template
gh repo create my-app --template indiagrams/apple-shipkit --public --clone
cd my-app

# 2. One-time dev-env setup (brew + ruby gems + xcodegen + git hooks)
#    Required before `make doctor` / `make bootstrap-fork` / `make ship`
#    (those targets gate on `bundle check` and exit 1 with a hint if it
#    fails). 30-90 seconds depending on what's already installed.
make bootstrap

# 3. Scaffold .bootstrap.env from the example, auto-filling GH_ORG/GH_APP_REPO
#    from `git remote get-url origin`
make init

# 4. Edit .bootstrap.env — fill APP_NAME, BUNDLE_ID, Apple credentials,
#    RELEASE_MODE (ci or local). See "Config reference" below.
$EDITOR .bootstrap.env

# 5. Validate config + probe Apple/GH
make doctor

# 6. Run every programmatic step idempotently
make bootstrap-fork

# 7. Trigger a release (CI workflow if RELEASE_MODE=ci, fastlane locally if =local)
make ship

# 8. Confirm TestFlight ingestion
make verify
```

## Two release modes

`.bootstrap.env` has a `RELEASE_MODE` field. Choose one:

| | `ci` (default) | `local` |
|---|---|---|
| **Setup includes** | 5 GH Secrets, branch protection, ASC App verify | Login keychain identities check, branch protection, ASC App verify |
| **`make ship` does** | Triggers `.github/workflows/release.yml` on the app repo | Runs `bundle exec fastlane release tag:v<MARKETING>+<BUILD>` on this machine (marketing version read from project file; build number resolved from ASC) |
| **Signing material lives** | Minted fresh on the GitHub Actions runner per release run, then revoked at the end of the run (net cert delta = 0). Nothing is persisted between runs. | In your login keychain (Apple Distribution + Apple Development + 3rd Party Mac Developer Installer for macOS) |
| **Who can release** | Anyone with push to the app repo + a working `gh auth login` (the ASC API key is already in GH Secrets) | Only this laptop |
| **Best for** | Teams, weekly TestFlight cron, repeatable builds | Solo devs, fast iteration, no shared CI |
| **Cost to bootstrap** | ~5 min (5 secrets + branch protection + ASC App verify) | ~3 min (just verify keychain has the certs) |

Both modes drive the same `fastlane/Fastfile` release lane. The lane is
sigh-based in both modes — the only difference is *where the signing certs
come from*: local mode uses your `login.keychain-db`; CI mode mints fresh
certs at the start of each `release.yml` run and revokes them at the end
(`always()` step). There is no certs repo and no `fastlane match` involvement
in v1.6+.

You can switch modes later by editing `RELEASE_MODE` and re-running
`make bootstrap-fork`. Going `local → ci`: bootstrap sets the 5 GH Secrets
and configures branch protection. Going `ci → local`: bootstrap leaves the
GH Secrets in place (they're inert if `release.yml` is never triggered)
and CI just stops being invoked.
## Platforms

`.bootstrap.env` has a `PLATFORMS` field that gates which targets get built, signed, and uploaded. Three valid values:

| Value | Effect |
|---|---|
| `ios` | Ship iPhone/iPad only. `make doctor` skips the Mac Installer cert probe + the macOS .icns regeneration. `make ship` skips the macOS .pkg build + upload. PR CI runs 4 jobs (no `app (macOS)` / `app (Tuist macOS)`). Branch protection requires 4 checks. |
| `macos` | Ship Mac only. Skips iOS provisioning profile checks + iOS .ipa upload. PR CI runs 2 jobs. Branch protection requires 2 checks. |
| `ios,macos` | Default. Ships both, current behavior. |

Switchable later: change the value in `.bootstrap.env`, re-run `make bootstrap-fork`, and the relevant pieces of the pipeline (de)activate. No tree mutation; the unused-platform code stays in the repo, just inert. (If you want a *clean tree* with the unused platform's files deleted, that's a different choice — delete `app/iOS/` or `app/macOS/` manually + adjust the relevant scheme references; the template doesn't ship a one-shot strip script for this.)

Default: if `PLATFORMS` is unset or empty in `.bootstrap.env`, the bootstrap pipeline treats it as `ios,macos`. Forks created before this field existed (or forks that never edit it) preserve their existing both-platforms behavior.
## Config reference

`.bootstrap.env` is gitignored. Its values are mostly non-secret config
(team IDs, repo slugs, etc.) plus *paths* to mode-0600 files containing the
actual secret bytes. The dotenv itself is low-blast-radius.

| Field | What it is | Where to get it |
|---|---|---|
| `APP_NAME` | CamelCase scheme + product name. Becomes the Xcode target. | You decide |
| `BUNDLE_ID` | Reverse-DNS bundle id, used for both iOS + macOS apps | You decide |
| `DISPLAY_NAME` | `CFBundleDisplayName`, visible on home screen | You decide |
| `APP_EMAIL` | Maintainer email for Appfile, CHANGELOG, fastlane metadata | You decide |
| `GENERATOR` | `xcodegen` (default) or `tuist` | Pick whichever project format you want to drive your fork |
| `FASTLANE_TEAM_ID` | 10-char Apple Developer Team ID | <https://developer.apple.com/account/#/membership> |
| `RELEASE_MODE` | `ci` or `local`. See [Two release modes](#two-release-modes) above | You decide |
| `ASC_API_KEY_ID` | 10-char ASC API key ID | <https://appstoreconnect.apple.com/access/api> → Users and Access → Integrations → App Store Connect API |
| `ASC_API_KEY_ISSUER_ID` | UUID format issuer ID | Same page, shown above the keys table |
| `ASC_API_KEY_P8_PATH` | Path to the `.p8` file Apple gave you when you created the API key | Apple shows it once at creation time. If lost, generate a new key + revoke old |
| `GH_ORG` | GitHub user/org that owns the app repo | You decide |
| `GH_APP_REPO` | App repo name (already created via `gh repo create --template`; auto-filled by `make init` from origin remote) | The name you used in `gh repo create` |
| `KEYCHAIN_PASSWORD_FILE` *(ci-only)* | Path to a file containing the CI keychain password. Auto-generated as 32 random chars on first `make bootstrap-fork` if absent | Created on first `make bootstrap-fork` |
| `ICON_1024_PATH` (optional) | Path to your 1024×1024 PNG. If set, replaces the template hammer icon and runs `make icons` | Designer artifact |
| `ASC_APP_SKU` (optional) | Documentation hint for the manual ASC App creation step | Any unique string |
| `ASC_APP_NAME` (optional) | Documentation hint — defaults to `DISPLAY_NAME` | The human-readable name you want shown in the App Store |
| `PLATFORMS` (optional) | Subset of `ios,macos` that controls which targets ship. Defaults to both if unset. See [Platforms](#platforms) above | You decide |

CI mode no longer requires a separate fine-grained PAT or a private certs
repo. The `gh` CLI's auth (set up once via `gh auth login`) is what
`bootstrap-fork` uses to set GH Secrets and configure branch protection,
and `release.yml` uses the workflow-scoped `GITHUB_TOKEN` for everything it
needs.

## What `make bootstrap-fork` does

The pipeline has 15 step classes (single source of truth: `PIPELINE` in
`bin/lib/bootstrap.rb`). CI mode (`RELEASE_MODE=ci`) runs 14 with default
`PLATFORMS=ios,macos` (excludes `LocalKeychainCerts`, which is local-only);
local mode runs 14 (excludes `GHSecrets`, which is ci-only). Each step has
a `check` (no side effects) and a `do_it`. A step is skipped if its desired
state is already reached, so re-running after a partial failure picks up
where you left off.

Mode key: ⚪ both, 🅒 ci-only, 🅛 local-only, 🍎 macOS-only.

| # | Step | Mode | What changes |
|---|---|---|---|
| 1 | `CheckAppleCreds` | ⚪ | Validates `.p8` + key id + issuer id by probing ASC API |
| 2 | `CheckGHCreds` | ⚪ | CI mode: probes `gh auth status`. Local mode: no-op (gh CLI not used at ship time). |
| 3 | `RemoteMatches` | ⚪ | Verifies `git remote get-url origin` matches `GH_ORG/GH_APP_REPO` |
| 4 | `RenameStub` | ⚪ | Runs `bin/rename.sh` (HelloApp → APP_NAME) + `bin/verify-rename.sh` |
| 5 | `BrewBootstrap` | ⚪ | `make bootstrap` (brew bundle + lefthook + xcodegen/tuist + bundler) |
| 6 | `Icon1024` | ⚪ | If `ICON_1024_PATH` set, copies it to the iOS asset catalog (tree mutation lands before `InitialPush`) |
| 7 | `MakeIcons` | 🍎 | `make icons` — regenerates the macOS `.icns` from the 1024 PNG. Runs only when `PLATFORMS` includes `macos`. |
| 8 | `InitialPush` | ⚪ | First commit (rename + icons) pushed to `origin/main` |
| 9 | `BranchProtection` | ⚪ | `bin/setup-github.sh` (required checks: swiftlint + swiftformat + xcodegen iOS device/sim + macOS + tuist parity, squash-only, linear history) |
| 10 | `GHSecrets` | 🅒 | Generates `KEYCHAIN_PASSWORD` if absent, encodes the `.p8`, sets the 5 GH Secrets (`KEYCHAIN_PASSWORD`, `ASC_API_KEY_ID`, `ASC_API_KEY_ISSUER_ID`, `ASC_API_KEY_P8_BASE64`, `FASTLANE_TEAM_ID`) on the app repo |
| 11 | `RegisterAppId` | ⚪ | `fastlane register_app_id` (idempotent — Spaceship `BundleId.create` rescues `ALREADY_EXISTS`) |
| 12 | `VerifyAscApp` | ⚪ | Probes for the App record. **Fails loud with web-UI instructions if missing** — Apple disallows `POST /apps`, so this is the one human-gated step inside the pipeline |
| 13 | `LocalKeychainCerts` | 🅛 | Auto-mints any missing local-mode cert types (Apple Distribution, Apple Development, and — when shipping macOS — 3rd Party Mac Developer Installer) via `fastlane cert` into `login.keychain-db`. New in v1.4 — replaces the v1.3 hard-blocker requiring manual remediation. |
| 14 | `ScanMetadata` | ⚪ | Informational — counts present-vs-placeholder strings under `fastlane/metadata/` |
| 15 | `ScanScreenshots` | ⚪ | Informational — counts present screenshots under `fastlane/screenshots/` |

### CI mode at a glance (v1.6+)

`bootstrap-fork` in CI mode creates **0 certs repos**, generates **0 PATs**,
and mints **0 signing certs**. Its only ci-specific step is `GHSecrets`,
which sets 5 secrets on the app repo. All actual signing material is
minted fresh by `release.yml` at the start of every release run and
revoked at the end via the `always()` post-step (orphan ASC ids from
crashes are cleaned up by the next run's pre-step). Validated 2026-05-10
against `prakashrj/my-cool-app` (release `v2026.19.10` minted, signed,
uploaded, and certs revoked end-to-end).

## What you still have to do by hand

These can't be automated — Apple and GitHub deliberately don't expose them
to public APIs:

- **Enroll in the Apple Developer Program** ($99/yr; ~24-48 hr Apple review)
- **Create the App Store Connect API Key** (web UI; Apple shows the `.p8` once)
- **Create the App Store Connect App record** (Apple disallows `POST /apps`).
  The `VerifyAscApp` step of `make bootstrap-fork` fails loud with the
  exact form values to paste — re-run after creating, and the step turns ✓
- **Run `gh auth login`** once on the machine that will execute `make
  bootstrap-fork` and `make ship` (CI mode only — local mode never invokes
  the `gh` CLI at ship time)
- **Provide a 1024 icon and metadata text** (designer + product artifacts —
  see "After bootstrap" below)

## After bootstrap

`make ship` triggers `release.yml` and tails it until success. Tag pushed,
binaries uploaded, ASC ingestion in flight. Then `make verify` polls ASC
for the most recent build's processing state.

For App Store *review* (not just TestFlight), you still need:

- Replace `app/iOS/Assets.xcassets/AppIcon.appiconset/Icon-1024.png` and
  run `make icons` (or set `ICON_1024_PATH` and let bootstrap do it)
- Fill `fastlane/metadata/en-US/*.txt` (replace TODO markers in `name`,
  `subtitle`, `description`, `keywords`, `release_notes`, `marketing_url`,
  `privacy_url`, `support_url`)
- Fill `fastlane/metadata/review_information/*.txt` (`first_name`,
  `last_name`, `email_address`, `phone_number`, `notes`) — OR export
  `APP_REVIEW_FIRST_NAME`, `APP_REVIEW_LAST_NAME`, `APP_REVIEW_EMAIL`,
  `APP_REVIEW_PHONE`, `APP_REVIEW_NOTES` (env wins; tracked .txt is
  the file fallback). Export from your shell profile / `.envrc` / secrets
  manager to share across forks without duplicating per-clone.
- Demo account for apps with auth (App Review rejects login-walled
  submissions without one): export `APP_REVIEW_DEMO_USER` +
  `APP_REVIEW_DEMO_PASSWORD`. No-auth apps skip this.
- Update `fastlane/metadata/copyright.txt`
- Capture screenshots: `ci/take-screenshots.sh`
- Upload metadata + screenshots: `bundle exec fastlane ios upload_metadata` etc.

These aren't gates for TestFlight — TestFlight just needs the build. They're
gates for App Store review.

## Why is `.bootstrap.env` gitignored?

Even though most fields are non-secret (team ID, repo slugs), the file
references *paths* to your `.p8` API key and (for CI mode) the
auto-generated keychain password file. Anyone who gets the file gets a
roadmap to your secret bytes. Treat it the same way you treat
`~/.ssh/config` — not a catastrophic leak by itself, but enough to be
worth keeping out of source control.

## Troubleshooting

- **A step fails with a stack trace from `bundle exec ruby`** — the script
  uses fastlane's bundle for Spaceship + `cert` / `sigh`. Run `bundle
  install` first.
- **`CheckGHCreds` says `gh CLI is not authenticated`** — run `gh auth
  login` and re-try `make doctor`. CI mode requires this so `GHSecrets`
  and `BranchProtection` can talk to the app repo.
- **`VerifyAscApp` is blocked but I created the App** — ASC API
  is eventually consistent. Wait 30 seconds and re-run `make doctor`.
- **`LocalKeychainCerts` (local mode) or the release.yml mint step (CI
  mode) hits "Could not create another Distribution certificate, reached
  the maximum number of available Distribution certificates"** — Apple's
  per-team cert quotas (verified empirically May 2026 against team
  `A1B2C3D4E5`): Apple Distribution = 3, Apple Development ≥ 5, 3rd Party
  Mac Developer Installer = 2. Forkers shipping macOS commonly hit the
  installer cap (2) before the distribution cap (3). Revoke an unused one
  via `bundle exec fastlane revoke_cert id:<CERT_ID>` (singular) or
  `revoke_certs ids:A,B,C` (plural batch, idempotent), then re-run.
  In CI mode, orphan ids from crashed runs are auto-revoked by the
  pre-step of the next `release.yml` run; if a fork has been idle long
  enough for the cache to evict (>7 days), revoke manually via
  developer.apple.com/account/resources/certificates. See
  [docs/CONTINUOUS-VALIDATION.md](CONTINUOUS-VALIDATION.md) for the full
  ecosystem-constraints note.
- **`LocalKeychainCerts` hits "Could not find the newly generated
  certificate installed" on a populated login keychain** — see
  `docs/CONTINUOUS-VALIDATION.md` G11. The CI release.yml pipeline mints
  into a fresh runner-scoped keychain (immune to this). Locally, run
  `fastlane cert` against a fresh keychain.

## What `bin/lib/bootstrap.rb` is

The orchestrator. Pure Ruby, depends only on the gems already in this
template's `Gemfile` (fastlane + spaceship). Every step lives as a
separate class (`RenameStub`, `BrewBootstrap`, `LocalKeychainCerts`, …) so
adding new steps or skipping ones is a one-class change. `bin/doctor.rb`
and `bin/bootstrap-fork.rb` are thin wrappers on `Bootstrap::Runner`. The
canonical step order lives in the `PIPELINE` constant near the bottom of
the file — that's the ground truth the table above mirrors.
