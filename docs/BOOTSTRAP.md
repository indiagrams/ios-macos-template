# Bootstrap your fork

Time-to-TestFlight: ~15 minutes once your `.bootstrap.env` is filled in.

This template ships a config-driven fork bootstrap. You fill out one file with
your identity + credentials, then `make bootstrap-fork` drives every
programmatic step (rename, push, branch protection, GH Secrets, certs repo,
match, installer cert, icon swap, …) idempotently. The only manual steps are
the ones Apple and GitHub deliberately don't expose to APIs.

```bash
# 1. Fork from template
gh repo create my-app --template indiagrams/apple-shipkit --public --clone
cd my-app

# 2. Scaffold .bootstrap.env from the example, auto-filling GH_ORG/GH_APP_REPO
#    from `git remote get-url origin`
make init

# 3. Edit .bootstrap.env — fill APP_NAME, BUNDLE_ID, Apple credentials,
#    RELEASE_MODE (ci or local). See "Config reference" below.
$EDITOR .bootstrap.env

# 4. Validate config + probe Apple/GH
make doctor

# 5. Run every programmatic step idempotently
make bootstrap-fork

# 6. Trigger a release (CI workflow if RELEASE_MODE=ci, fastlane locally if =local)
make ship

# 7. Confirm TestFlight ingestion
make verify
```

## Two release modes

`.bootstrap.env` has a `RELEASE_MODE` field. Choose one:

| | `ci` (default) | `local` |
|---|---|---|
| **Setup includes** | Private certs repo, fastlane match, 7 GH Secrets, branch protection, ASC App | Login keychain identities check, branch protection, ASC App |
| **`make ship` does** | Triggers `.github/workflows/release.yml` on the app repo | Runs `bundle exec fastlane release tag:vYYYY.WW.HHMM` on this machine |
| **Signing material lives** | Encrypted in the certs repo; CI decrypts via `MATCH_PASSWORD` | In your login keychain (Apple Distribution + Apple Development + 3rd Party Mac Developer Installer) |
| **Who can release** | Anyone with `GH_PAT_FILE` (and ASC API key) | Only this laptop |
| **Best for** | Teams, weekly TestFlight cron, repeatable builds | Solo devs, fast iteration, no shared CI |
| **Cost to bootstrap** | ~10 min (PAT + certs repo + 7 secrets + match) | ~3 min (just verify keychain has the certs) |

The same `fastlane/Fastfile` drives both — the release lane gates the `match` calls on `File.exist?(fastlane/Matchfile)`, so a `local`-mode fork that never touches Matchfile uses local Keychain signing automatically.

You can switch modes later by editing `RELEASE_MODE` and re-running `make bootstrap-fork`. Going `local → ci`: bootstrap will set up the certs repo + secrets. Going `ci → local`: bootstrap won't tear down the existing certs repo (you'd remove that manually); CI just stops running.


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
| `GH_ORG` | GitHub user/org that owns both repos | You decide |
| `GH_APP_REPO` | App repo name (already created via `gh repo create --template`; auto-filled by `make init` from origin remote) | The name you used in `gh repo create` |
| `GH_CERTS_REPO` *(ci-only)* | Private certs repo name (created by `make bootstrap-fork` if absent) | Convention: `<app-repo>-certs` |
| `GH_PAT_FILE` *(ci-only)* | Path to a file containing a fine-grained PAT scoped to `GH_CERTS_REPO` (Contents: read+write) | <https://github.com/settings/tokens?type=beta>. See [PAT scope tradeoff](#pat-scope-tradeoff) below |
| `MATCH_PASSWORD_FILE` *(ci-only)* | Path to a file containing the certs-repo encryption password. Auto-generated as 32 random chars if absent | Created on first `make bootstrap-fork` |
| `KEYCHAIN_PASSWORD_FILE` *(ci-only)* | Path to a file containing the CI keychain password. Auto-generated if absent | Created on first `make bootstrap-fork` |
| `ICON_1024_PATH` (optional) | Path to your 1024×1024 PNG. If set, replaces the template hammer icon and runs `make icons` | Designer artifact |
| `ASC_APP_SKU` (optional) | Documentation hint for the manual ASC App creation step | Any unique string |
| `ASC_APP_NAME` (optional) | Documentation hint — defaults to `DISPLAY_NAME` | The human-readable name you want shown in the App Store |
| `PLATFORMS` (optional) | Subset of `ios,macos` that controls which targets ship. Defaults to both if unset. See [Platforms](#platforms) above | You decide |

## What `make bootstrap-fork` does

The pipeline has 19 step classes. CI mode (`RELEASE_MODE=ci`) runs 18 with
default `PLATFORMS=ios,macos` (excludes `LocalKeychainCerts`); local mode
(`RELEASE_MODE=local`, the default) runs 14 (excludes the 5 ci-only steps:
`EditMatchfile`, `CreateCertsRepo`, `GHSecrets`, `BootstrapCerts`,
`MintInstaller`). Each step has a `check` (no side effects) and a `do_it`.
A step is skipped if its desired state is already reached, so re-running
after a partial failure picks up where you left off.

Mode key: ⚪ both, 🅒 ci-only, 🅛 local-only.

| # | Step | Mode | What changes |
|---|---|---|---|
| 1 | Apple credentials (`CheckAppleCreds`) | ⚪ | Validates `.p8` + key id + issuer id by probing ASC API |
| 2 | GitHub credentials (`CheckGHCreds`) | ⚪ | Validates PAT can see `GH_CERTS_REPO` (CI mode) or `git remote get-url origin` (local mode) |
| 3 | Origin remote present (`RemoteMatches`) | ⚪ | Verifies `git remote` is configured to the fork |
| 4 | Rename HelloApp → APP_NAME (`RenameStub`) | ⚪ | Runs `bin/rename.sh` + `bin/verify-rename.sh` |
| 5 | Wire fastlane/Matchfile (`EditMatchfile`) | 🅒 | Substitutes `git_url` to point at your certs repo |
| 6 | Toolchain (`BrewBootstrap`) | ⚪ | `make bootstrap` (brew bundle + lefthook + xcodegen/tuist + bundler) |
| 7 | (optional) Replace 1024 icon (`Icon1024`) | ⚪ | If `ICON_1024_PATH` set, copies it to the iOS asset catalog |
| 8 | (optional) Regenerate macOS icns (`MakeIcons`) | ⚪ | `make icons` — only if step 7 ran |
| 9 | Initial commit + push (`InitialPush`) | ⚪ | First commit (rename + Matchfile + icons) pushed to `origin/main` |
| 10 | Branch protection (`BranchProtection`) | ⚪ | `bin/setup-github.sh` (7 required checks: swiftlint + xcodegen iOS device/sim + macOS + tuist parity, squash-only, linear history) |
| 11 | Private certs repo (`CreateCertsRepo`) | 🅒 | `gh repo create --private` if absent |
| 12 | 7 GH Secrets (`GHSecrets`) | 🅒 | Generates `MATCH_PASSWORD` + `KEYCHAIN_PASSWORD` if absent, encodes the PAT + p8, sets all 7 secrets |
| 13 | Bundle ID registration (`RegisterAppId`) | ⚪ | `fastlane register_app_id` (idempotent — Spaceship `BundleId.create` rescues `ALREADY_EXISTS`) |
| 14 | Verify ASC App (`VerifyAscApp`) | ⚪ | Probes for the App record. **Fails loud with web-UI instructions if missing** — Apple disallows `POST /apps`, so this is the one human-gated step inside the pipeline |
| 15 | Mint match certs iOS dist + dev + macOS dist (`BootstrapCerts`) | 🅒 | `fastlane bootstrap_certs` (3 match calls in one process) |
| 16 | Mac Installer Distribution cert (`MintInstaller`) | 🅒 (macOS only) | `bin/mint-installer-cert.rb` + `bin/import-installer-to-match.rb` |
| 17 | Local keychain has signing identities (`LocalKeychainCerts`) | 🅛 | Auto-mints any missing local-mode cert types (Apple Distribution, Apple Development, 3rd Party Mac Developer Installer) via `fastlane cert` into `login.keychain-db`. New in v1.4 — replaces the v1.3 hard-blocker requiring manual remediation |
| 18 | Scan metadata (`ScanMetadata`) | ⚪ | Informational — counts present-vs-placeholder strings under `fastlane/metadata/` |
| 19 | Scan screenshots (`ScanScreenshots`) | ⚪ | Informational — counts present screenshots under `fastlane/screenshots/` |

## What you still have to do by hand

These can't be automated — Apple and GitHub deliberately don't expose them
to public APIs:

- **Enroll in the Apple Developer Program** ($99/yr; ~24-48 hr Apple review)
- **Create the App Store Connect API Key** (web UI; Apple shows the `.p8` once)
- **Create the App Store Connect App record** (Apple disallows `POST /apps`).
  The `VerifyAscApp` step of `make bootstrap-fork` fails loud with the
  exact form values to paste — re-run after creating, and the step turns ✓
- **Generate a fine-grained PAT** for the certs repo (web UI)
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
  `last_name`, `email_address`, `phone_number`, `notes`)
- Update `fastlane/metadata/copyright.txt`
- Capture screenshots: `ci/take-screenshots.sh`
- Upload metadata + screenshots: `bundle exec fastlane ios upload_metadata` etc.

These aren't gates for TestFlight — TestFlight just needs the build. They're
gates for App Store review.

## PAT scope tradeoff

The fine-grained PAT can be scoped two ways:

- **"Only select repositories" → just your certs repo** (most secure default).
  Caveat: fine-grained PATs are pinned to a specific repo's *database ID*. If
  you ever delete + recreate the certs repo, the PAT 404s on the new repo
  even though the name is identical, and you have to update the PAT scope on
  github.com/settings/tokens. See `docs/CONTINUOUS-VALIDATION.md` G12 and
  `bin/refork-smoketest.sh` for the recreation-resilient approach.

- **"All repositories"** — defense in depth, survives recreation. Same narrow
  Contents permission, but bound to your user/org rather than a specific
  repo's database ID.

Either is fine; the first is the most secure default and what `.bootstrap.env`
expects.

## Why is `.bootstrap.env` gitignored?

Even though most fields are non-secret (team ID, repo slugs), the file
references *paths* to your `.p8` API key and your fine-grained PAT. Anyone who
gets the file gets a roadmap to your secret bytes. Treat it the same way you
treat `~/.ssh/config` — not a catastrophic leak by itself, but enough to be
worth keeping out of source control.

## Troubleshooting

- **Step N fails with a stack trace from `bundle exec ruby`** — the script
  uses fastlane's bundle for Spaceship + match. Run `bundle install` first.
- **`make doctor` says PAT 404s on certs repo, but I just created it** —
  fine-grained PATs are pinned to repo database IDs. If you recreated the
  certs repo, edit the PAT's repo list at github.com/settings/tokens.
- **`VerifyAscApp` is blocked but I created the App** — ASC API
  is eventually consistent. Wait 30 seconds and re-run `make doctor`.
- **`BootstrapCerts` (CI mode) or `MintInstaller` (CI mode) or `LocalKeychainCerts` (local mode) hits "Could not create another Distribution certificate,
  reached the maximum number of available Distribution certificates"** —
  Apple's per-team cert quotas (verified empirically May 2026 against team
  `A26TJZ8QHQ`): Apple Distribution = 3, Apple Development ≥ 5, 3rd Party
  Mac Developer Installer = 2. Forkers shipping macOS commonly hit the
  installer cap (2) before the distribution cap (3). Revoke an unused one
  via `bundle exec fastlane revoke_cert id:<CERT_ID>` (singular) or
  `revoke_certs ids:A,B,C` (plural batch, idempotent), then re-run
  `make doctor`. See [docs/CONTINUOUS-VALIDATION.md](CONTINUOUS-VALIDATION.md)
  for the full ecosystem-constraints note.
- **`BootstrapCerts` / `LocalKeychainCerts` hits "Could not find the newly generated certificate installed"
  on a populated login keychain** — see `docs/CONTINUOUS-VALIDATION.md` G11.
  The bootstrap pipeline sets `CERT_KEYCHAIN_PATH` to a temp keychain to
  avoid this; if you still hit it, run match against a fresh keychain.

## What `bin/lib/bootstrap.rb` is

The orchestrator. Pure Ruby, ~700 lines, depends only on the gems already
in this template's `Gemfile` (fastlane + spaceship). Every step lives as a
separate class (`RenameStub`, `BrewBootstrap`, `BootstrapCerts`, …) so
adding new steps or skipping ones is a one-class change. `bin/doctor.rb`
and `bin/bootstrap-fork.rb` are thin wrappers on `Bootstrap::Runner`.
