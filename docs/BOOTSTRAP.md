# Bootstrap your fork

Time-to-TestFlight: ~15 minutes once your `.bootstrap.env` is filled in.

This template ships a config-driven fork bootstrap. You fill out one file with
your identity + credentials, then `make bootstrap-fork` drives every
programmatic step (rename, push, branch protection, GH Secrets, certs repo,
match, installer cert, icon swap, …) idempotently. The only manual steps are
the ones Apple and GitHub deliberately don't expose to APIs.

```bash
# 1. Fork from template
gh repo create my-app --template indiagrams/ios-macos-template --public --clone
cd my-app

# 2. Fill in .bootstrap.env (see "Config reference" below)
cp .bootstrap.env.example .bootstrap.env
$EDITOR .bootstrap.env

# 3. Validate — see what's done, what's pending, what's blocked
make doctor

# 4. Run the bootstrap (idempotent — re-run safely)
make bootstrap-fork

# 5. Trigger the release pipeline
make ship          # tails the workflow run until success

# 6. Confirm TestFlight ingestion
make verify
```

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
| `ASC_API_KEY_ID` | 10-char ASC API key ID | <https://appstoreconnect.apple.com/access/api> → Users and Access → Integrations → App Store Connect API |
| `ASC_API_KEY_ISSUER_ID` | UUID format issuer ID | Same page, shown above the keys table |
| `ASC_API_KEY_P8_PATH` | Path to the `.p8` file Apple gave you when you created the API key | Apple shows it once at creation time. If lost, generate a new key + revoke old |
| `GH_ORG` | GitHub user/org that owns both repos | You decide |
| `GH_APP_REPO` | App repo name (you already created this via `gh repo create --template`) | Already done if you ran the quickstart |
| `GH_CERTS_REPO` | Private certs repo name (created by `make bootstrap-fork` if absent) | Convention: `<app-repo>-certs` |
| `GH_PAT_FILE` | Path to a file containing a fine-grained PAT scoped to `GH_CERTS_REPO` (Contents: read+write) | <https://github.com/settings/tokens?type=beta>. See [PAT scope tradeoff](#pat-scope-tradeoff) below |
| `MATCH_PASSWORD_FILE` | Path to a file containing the certs-repo encryption password. Auto-generated as 32 random chars if absent | Created on first `make bootstrap-fork` |
| `KEYCHAIN_PASSWORD_FILE` | Path to a file containing the CI keychain password. Auto-generated if absent | Created on first `make bootstrap-fork` |
| `ICON_1024_PATH` (optional) | Path to your 1024×1024 PNG. If set, replaces the template hammer icon and runs `make icons` | Designer artifact |
| `ASC_APP_SKU` (optional) | Documentation hint for the manual ASC App creation step | Any unique string |
| `ASC_APP_NAME` (optional) | Documentation hint — defaults to `DISPLAY_NAME` | The human-readable name you want shown in the App Store |

## What `make bootstrap-fork` does

15 steps, in order. Each step has a `check` (no side effects) and a `do_it`.
A step is skipped if its desired state is already reached, so re-running after
a partial failure picks up where you left off.

| # | Step | What changes |
|---|---|---|
| 1 | Apple credentials | Validates `.p8` + key id + issuer id by probing ASC API |
| 2 | GitHub credentials | Validates PAT can see `GH_CERTS_REPO` |
| 3 | Rename HelloApp → APP_NAME | Runs `bin/rename.sh` + `bin/verify-rename.sh` |
| 4 | Wire fastlane/Matchfile | Substitutes `git_url` to point at your certs repo |
| 5 | Toolchain | `make bootstrap` (brew bundle + lefthook + xcodegen/tuist + bundler) |
| 6 | Initial commit + push | First commit (rename + Matchfile) pushed to `origin/main` |
| 7 | Branch protection | `bin/setup-github.sh` (6 required checks, squash-only, linear history) |
| 8 | Private certs repo | `gh repo create --private` if absent |
| 9 | 7 GH Secrets | Generates `MATCH_PASSWORD` + `KEYCHAIN_PASSWORD` if absent, encodes the PAT + p8, sets all 7 secrets |
| 10 | Bundle ID registration | `fastlane register_app_id` (idempotent — Spaceship `BundleId.create` rescues `ALREADY_EXISTS`) |
| 11 | Verify ASC App | Probes for the App record. **Fails loud with web-UI instructions if missing** — Apple disallows `POST /apps`, so this is the one human-gated step inside the pipeline |
| 12 | Mint certs (iOS dist + dev + macOS dist) | `fastlane bootstrap_certs` (3 match calls in one process) |
| 13 | Mac Installer Distribution cert | `bin/mint-installer-cert.rb` + `bin/import-installer-to-match.rb` |
| 14 | (optional) Replace 1024 icon | If `ICON_1024_PATH` set, copies it to the iOS asset catalog |
| 15 | (optional) Regenerate macOS icns | `make icons` — only if step 14 ran |

## What you still have to do by hand

These can't be automated — Apple and GitHub deliberately don't expose them
to public APIs:

- **Enroll in the Apple Developer Program** ($99/yr; ~24-48 hr Apple review)
- **Create the App Store Connect API Key** (web UI; Apple shows the `.p8` once)
- **Create the App Store Connect App record** (Apple disallows `POST /apps`).
  Step 11 of `make bootstrap-fork` fails loud with the exact form values to
  paste — re-run after creating, and step 11 turns ✓
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
- **Step 11 (Verify ASC App) is blocked but I created the App** — ASC API
  is eventually consistent. Wait 30 seconds and re-run `make doctor`.
- **Step 12 (match) hits "Could not create another Distribution certificate,
  reached the maximum number of available Distribution certificates"** —
  Apple's distribution cert quota is 3/team. Revoke an unused one via
  `bundle exec fastlane revoke_cert id:<CERT_ID>` (run `make doctor` after,
  the cert step will retry).
- **Step 12 hits "Could not find the newly generated certificate installed"
  on a populated login keychain** — see `docs/CONTINUOUS-VALIDATION.md` G11.
  The bootstrap pipeline sets `CERT_KEYCHAIN_PATH` to a temp keychain to
  avoid this; if you still hit it, run match against a fresh keychain.

## What `bin/lib/bootstrap.rb` is

The orchestrator. Pure Ruby, ~700 lines, depends only on the gems already
in this template's `Gemfile` (fastlane + spaceship). Every step lives as a
separate class (`RenameStub`, `BrewBootstrap`, `BootstrapCerts`, …) so
adding new steps or skipping ones is a one-class change. `bin/doctor.rb`
and `bin/bootstrap-fork.rb` are thin wrappers on `Bootstrap::Runner`.
