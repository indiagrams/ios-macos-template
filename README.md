# ios-macos-template

[![CI](https://github.com/indiagrams/ios-macos-template/actions/workflows/pr.yml/badge.svg)](https://github.com/indiagrams/ios-macos-template/actions/workflows/pr.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org)

> **v1.0.0 released** — [release notes](https://github.com/indiagrams/ios-macos-template/releases/tag/v1.0.0). The "Use this template" button is live; fork it and ship.

Opinionated boilerplate for iOS + macOS apps.
Distilled from production iOS + macOS apps shipping on the App Store —
same XcodeGen layout, same fastlane release pipeline, same App Store
submission tooling.

## Why this template

- **Choose your project generator at fork time.** Both [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`app/project.yml`) and [Tuist](https://tuist.dev) (`app/Project.swift`) ship on `main`; pick which one drives your fork via `bin/rename.sh ... --generator=tuist|xcodegen` (default: `xcodegen`). No `.xcodeproj` is committed either way — it's regenerated from the manifest you keep. The CI matrix runs both generators on every template PR so they stay in lockstep.
- **Lefthook pre-push gate.** `ci/local-check.sh --fast` (an unsigned iOS
  device build) runs locally before every `git push`. CI on GitHub is a
  confirmation, not a discovery channel — broken builds don't reach `main`'s
  PR queue.
- **Signed releases run locally OR in CI.** The default flow keeps signing
  on your laptop (`fastlane release tag:vX.Y.Z` reads certs from your login
  Keychain) — easy first-run, no CI secrets to manage. The opt-in flow uses
  [`fastlane match`](https://docs.fastlane.tools/actions/match/) + a private
  certs repo to enable CI signing via a weekly TestFlight cron in
  [`.github/workflows/release.yml`](.github/workflows/release.yml). Same
  `fastlane/Fastfile` drives both — see "Setting up signing + ASC" below.
- **Continuously validated downstream.** A public smoketest fork
  ([`indiagrams/ios-macos-smoketest`](https://github.com/indiagrams/ios-macos-smoketest))
  runs the full release cron weekly to TestFlight against this template's
  signing pattern. Bugs in fastlane / match / Apple's signing infra surface
  there before they hit your fork. The `release.yml` and `bin/mint-installer-cert.rb`
  helpers in this template were validated end-to-end against `macos-15` in
  that fork before landing.

What you get out of the box:

- **Local checks** — `ci/local-check.sh --fast` runs an unsigned iOS device
  build (the primary CI signal) on every `git push` via lefthook.
- **GitHub Actions** — six jobs on every PR: 3 XcodeGen (iOS device, iOS Simulator, macOS) + 3 Tuist parity (same matrix, exercises `bin/switch-to-tuist.sh` before building).
  Branch protection on `main` blocks direct pushes.
- **Signed release pipeline** — `fastlane release tag:v0.1.0` builds signed
  `.ipa` + `.pkg`, uploads both to TestFlight, then pushes the git tag.
- **App Store submission** — `fastlane ios upload_metadata` + `fastlane mac
  upload_metadata` + `ci/take-screenshots.sh` + `ci/bump-asc-version.sh`.
- **Hand-crafted macOS icons** — `ci/gen-macos-icons.swift` generates the full
  10-size .icns from a 1024 source. The build's postCompileScript overwrites
  actool's broken 4-size output before code-signing.
- **Working stub** — `HelloApp` (iOS + macOS) boots, builds green, and
  drives screenshot capture for App Store submission.

## What you get

The template ships with a working `HelloApp` stub that builds green on both iOS and macOS — here's what it looks like out of the box:

![HelloApp template running on iOS Simulator — hammer icon, "HelloApp" title, and 'Rename me' instruction visible](docs/screenshots/ios-home.png)

![HelloApp template running natively on macOS — same hammer icon, title, and rename instruction](docs/screenshots/macos-home.png)

## Quickstart — fork to TestFlight in ~15 minutes

**Prereqs:** macOS with Xcode (the full app, not just Command Line Tools), Homebrew, `gh` authenticated, and an Apple Developer Program membership.

**Missing some?** Run `bin/preflight.sh` first — it checks every prereq and walks you through installing the missing ones:

```bash
git clone https://github.com/indiagrams/ios-macos-template.git /tmp/preflight \
  && bash /tmp/preflight/bin/preflight.sh \
  && rm -rf /tmp/preflight
```

Apple side: see [`docs/APPLE-PREREQS.md`](docs/APPLE-PREREQS.md) for Team ID, App Store Connect API key, and the one-time human ASC App record creation.

### The flow

```bash
# 1. Fork from template
gh repo create my-app --template indiagrams/ios-macos-template --public --clone && cd my-app

# 2. Scaffold .bootstrap.env (auto-fills GH_ORG/GH_APP_REPO from your origin remote)
make init

# 3. Edit .bootstrap.env — fill APP_NAME, BUNDLE_ID, Apple credentials,
#    and RELEASE_MODE (ci for GH workflow signing, local for laptop signing)
$EDITOR .bootstrap.env

# 4. Validate config + probe Apple/GH
make doctor

# 5. Run every programmatic step idempotently
make bootstrap-fork

# 6. Trigger a release. RELEASE_MODE=ci triggers .github/workflows/release.yml;
#    RELEASE_MODE=local runs `bundle exec fastlane release` on this machine.
make ship

# 7. Confirm TestFlight ingestion
make verify
```

`make doctor` is read-only — run it as often as you like. `make bootstrap-fork` is idempotent — re-run safely after partial failures. The only step that can require human action is creating the ASC App record (Apple disallows `POST /apps`); `make doctor` will tell you the exact form to fill in if it's missing.

Full walkthrough + config field reference: [`docs/BOOTSTRAP.md`](docs/BOOTSTRAP.md).

### Manual flow (if you don't want to use `make bootstrap-fork`)

The bootstrap is glue + idempotency over scripts that already exist; you can drive them yourself:

```bash
bin/rename.sh YourApp com.your-org.yourapp 'Your App' --email=you@example.com
bin/verify-rename.sh
make bootstrap   # toolchain only: brew + lefthook + xcodegen + bundler
git add -A && git commit -m "Rename app stub"
git push -u origin main
bin/setup-github.sh
```

Then "Setting up signing + ASC" below for the certs + secrets dance.

Prefer Tuist over XcodeGen? Re-run with `--generator=tuist` (e.g. `bin/rename.sh YourApp com.your-org.yourapp 'Your App' --email=you@example.com --generator=tuist`) and the flag invokes `bin/switch-to-tuist.sh` for you — `app/project.yml` is removed and Brewfile / Makefile / ci scripts / `.github/workflows/pr.yml` are flipped to drive `app/Project.swift` via `tuist generate`. Already renamed and want to switch later? Run `bin/switch-to-tuist.sh` standalone — see [`docs/MIGRATING-TO-TUIST.md`](docs/MIGRATING-TO-TUIST.md) for the in-place switch guide.

<details>
<summary>If you prefer manual sed</summary>

The stub uses these names:

| Token | Value |
|---|---|
| App name (scheme + product) | `HelloApp` |
| Bundle ID | `com.example.helloapp` |
| Team ID | `TEAM_ID_PLACEHOLDER` (overridden via `.env.local`) |
| Project file | `app/HelloApp.xcodeproj` |
| IPA | `build/HelloApp-{ver}.ipa` |
| pkg | `build/HelloApp-{ver}.pkg` |

To rename for your project, search-replace these tokens across the repo:

```bash
# Pick three strings:
#   APP_NAME    e.g. MyApp        (scheme + product)
#   BUNDLE_ID   e.g. com.example.myapp
#   DISPLAY     e.g. "My App"     (Bundle Display Name)

# 1. Strings in source/config files
grep -rl "HelloApp" --exclude-dir=.git --exclude="*.png" . \
  | xargs sed -i '' 's/HelloApp/MyApp/g'
grep -rl "com.example.helloapp" --exclude-dir=.git . \
  | xargs sed -i '' 's/com.example.helloapp/com.example.myapp/g'

# 2. File paths
mv app/iOS/HelloApp.entitlements        app/iOS/MyApp.entitlements
mv app/macOS/HelloApp.entitlements      app/macOS/MyApp.entitlements
mv app/Shared/HelloApp.swift            app/Shared/MyApp.swift

# 3. Regenerate Xcode project
make generate
```

</details>

### After rename: still-manual steps

These steps `bin/rename.sh` cannot automate — they need your real assets:

- Replace `app/iOS/Assets.xcassets/AppIcon.appiconset/Icon-1024.png` with your real 1024×1024 icon.
- Run `make icons` to regenerate the macOS iconset + `.icns` from the new 1024 source.
- Fill in `fastlane/metadata/en-US/*.txt` (replace TODO markers).
- Fill in `fastlane/metadata/review_information/*.txt`.
- Update `fastlane/metadata/copyright.txt`.

## Setting up signing + ASC

```bash
cp .env.local.example .env.local
# Fill in: FASTLANE_TEAM_ID, FASTLANE_APPLE_ID, ASC_API_KEY_*
```

Required Apple artifacts (one-time setup):

1. **Apple Distribution cert** in your login Keychain (developer.apple.com → Certificates → +).
2. **Mac Installer Distribution cert** in your login Keychain (for macOS .pkg signing).
3. **App Store Connect API key** with App Manager role (download the `.p8`,
   base64-encode into `ASC_API_KEY_P8_BASE64`).

The first time you run `fastlane release`, Xcode auto-creates the iOS + macOS
provisioning profiles via `-allowProvisioningUpdates`. Subsequent runs reuse them.

### Optional: enable CI signing via fastlane match

The default `fastlane release` flow signs from your laptop. To run the same
release pipeline weekly from GitHub Actions (catches code-signing rot
automatically), opt in to the match-driven pattern. The smoketest
([`indiagrams/ios-macos-smoketest`](https://github.com/indiagrams/ios-macos-smoketest))
exercises this every Monday against macos-15 — patterns + fixes there land
back in this template before they bite forkers.

One-time bootstrap:

1. **Create a private certs repo** (convention: `<your-org>/<your-repo>-certs`).
   Match stores AES-256-CBC-encrypted certs + profiles there. Both your
   laptop and CI consume readonly.
2. **Edit `fastlane/Matchfile`** — replace `CHANGE-ME-ORG/CHANGE-ME-REPO-certs.git`
   with your real URL.
3. **Generate `MATCH_PASSWORD`** (32+ char random). Store in
   `~/.config/secrets.env` (mode 0600) and as a GH Secret on your repo.
4. **Generate a fine-grained PAT** with `Contents` read+write access to the certs repo.
   Build `MATCH_GIT_BASIC_AUTHORIZATION = base64("<gh-user>:<PAT>")`. Store
   locally and as a GH Secret.
5. **Set 7 GH Secrets total** on your app repo:
   `MATCH_PASSWORD`, `MATCH_GIT_BASIC_AUTHORIZATION`, `ASC_API_KEY_ID`,
   `ASC_API_KEY_ISSUER_ID`, `ASC_API_KEY_P8_BASE64`, `KEYCHAIN_PASSWORD`,
   `FASTLANE_TEAM_ID`.
6. **Bootstrap certs** locally (one-time), pushing each to the certs repo:
   ```bash
   set -a; source ~/.config/secrets.env; set +a
   bundle exec fastlane register_app_id
   bundle exec fastlane bootstrap_certs              # iOS dist + macOS dist + iOS dev (3 match calls in one process)
   # macOS .pkg installer cert (separate cert type, see G1 in docs/CONTINUOUS-VALIDATION.md):
   bundle exec ruby bin/mint-installer-cert.rb
   export INSTALLER_CERT_ID=<id-printed-by-mint-script>
   bundle exec ruby bin/import-installer-to-match.rb
   ```

   `bootstrap_certs` wraps the 3 raw match calls in a single fastlane lane so
   `before_all` runs once and the ASC API key is loaded for every call.
   Running raw `fastlane match` from the CLI skips `before_all` and dies with
   "Missing username, and running in non-interactive shell".
7. **Create the ASC App record once** via [appstoreconnect.apple.com/apps](https://appstoreconnect.apple.com/apps)
   (Apple's public API does not allow `POST /apps`; one-time human step
   unblocks all future automated runs). Then run
   `bundle exec fastlane bootstrap_asc` to verify.
8. **Enable the cron** by uncommenting the `schedule:` block in
   `.github/workflows/release.yml`. Until then, only manual
   `workflow_dispatch` is enabled — useful for one-off dry runs (`dry_run: true`).

Once configured, the `release` lane in `fastlane/Fastfile` automatically
runs match readonly (gated on `File.exist?(fastlane/Matchfile)`) and threads
match's profile names to `ci/local-release-check.sh`, which switches
xcodebuild to manual signing. No further changes needed in CI vs local.

## Repo layout

```
.
├── .github/workflows/
│   ├── pr.yml                       # 6 jobs: 3 XcodeGen + 3 Tuist parity (iOS device, iOS Sim, macOS each)
│   └── release.yml                  # opt-in weekly TestFlight cron + manual workflow_dispatch (schedule commented out by default — see README "Optional: enable CI signing via fastlane match")
├── Tuist.swift                      # Tuist 4 config (Tuist alternative to XcodeGen — pick at fork time via --generator)
├── Brewfile                         # xcodegen + tuist, fastlane, lefthook, …
├── Makefile                         # bootstrap | check | generate | icons | screenshots | release-dryrun
├── lefthook.yml                     # pre-push → ci/local-check.sh --fast
├── Gemfile                          # fastlane via brew Ruby
├── ci/
│   ├── local-check.sh               # unsigned builds (CI parity)
│   ├── local-release-check.sh       # signed .ipa + .pkg + sandbox re-sign hack
│   ├── take-screenshots.sh          # iOS + macOS App Store screenshots
│   ├── extract-mac-screenshots.sh   # extract macOS PNGs from xcresult
│   ├── bump-asc-version.{rb,sh}     # bump ASC version + attach TestFlight build + re-upload metadata
│   ├── gen-macos-icons.swift        # 1024 PNG → 10-size .icns + iconset
│   ├── ExportOptions-iOS.plist      # signed iOS App Store export options
│   ├── ExportOptions-macOS-AppStore.plist
│   └── lib/
│       ├── resolve-dist-cert-sha.sh # cert SHA-1 disambiguation (shared library; SHA-pinned across consumer repos)
│       └── SHA256SUMS               # pinned hashes; CI fails if lib/ drifts
├── fastlane/
│   ├── Fastfile                     # release | take_screenshots | upload_screenshots | upload_metadata | submit_for_review
│   ├── Appfile                      # bundle ID + team
│   ├── Snapfile / MacSnapfile       # screenshot capture config
│   ├── Matchfile                    # fastlane match config — placeholder URL; replace before running match (see "Optional: enable CI signing")
│   └── metadata/                    # App Store listing copy + review info (TODO markers)
└── app/
    ├── project.yml                  # XcodeGen manifest — iOS + macOS targets + UITest targets
    ├── Project.swift                # Tuist 4 manifest — 1:1 equivalent of project.yml; pick one via bin/rename.sh --generator
    ├── Shared/                      # SwiftUI app code (cross-platform)
    ├── iOS/                         # iOS-only resources (entitlements, AppIcon)
    ├── macOS/                       # macOS-only resources (entitlements, AppIcon, .icns)
    ├── UITests/                     # iOS UITest target (drives fastlane snapshot)
    └── MacOSUITests/                # macOS UITest target (drives screenshot capture)
```

Prefer Tuist (`Project.swift`) over XcodeGen (`project.yml`)? Pass `--generator=tuist` to `bin/rename.sh` at fork time and the flag flips your fork to Tuist-driven (deletes `app/project.yml`, edits Brewfile / Makefile / ci scripts / pr.yml). Already renamed and want to switch later? See [`docs/MIGRATING-TO-TUIST.md`](docs/MIGRATING-TO-TUIST.md) — in-place switch guide for already-renamed forks.

## Common workflows

**Develop a feature**
```bash
git checkout -b feat/your-feature
# edit app/Shared/...
make check                      # iOS device build (~30s)
git push                        # lefthook runs local-check --fast first
gh pr create
```

**Cut a release**
```bash
set -a; source .env.local; set +a
fastlane release tag:v0.1.0
```

Prefer Apple-native tooling (no Ruby/fastlane)? See [`docs/RELEASE-WITH-APPLE-NATIVE-TOOLS.md`](docs/RELEASE-WITH-APPLE-NATIVE-TOOLS.md) — same archive/export flow, replaces fastlane with `xcrun altool` + `xcrun notarytool` + ASC API direct.

**Submit to App Review (one-shot, sync versions)**
```bash
ci/bump-asc-version.sh v0.1.0   # bump ASC version + attach TestFlight build + re-upload metadata
fastlane ios submit_for_review
fastlane mac submit_for_review
```

**Capture App Store screenshots**
```bash
make screenshots                # iOS + macOS, output to fastlane/screenshots/en-US/
fastlane ios upload_screenshots
fastlane mac upload_screenshots
```

**Run the GSD per-phase checklist (optional, for users following the [GSD](https://github.com/aimazon/get-shit-done) workflow)**
```bash
make phase-checklist N=3.1            # auto-ticks based on artifacts in .planning/phases/03.1-*/
make milestone-checklist M=1          # cross-phase wrap-up checklist
bin/phase-runbook.sh 3.1 --pr 42      # also paste into PR #42's body
```

The runbook prints the canonical 10-step phase loop (plan → review → execute → code-review → verify → secure → tests → validate) and auto-ticks each step based on artifacts already produced. Skip this whole block if you don't use GSD.

## Why these specific patterns

These are not invented — they're hard-won from real production iOS + macOS
shipping pipelines. Specific gotchas baked in:

- **iOS device build, not Simulator, as primary CI signal** — Simulator green
  with device red happens often (xcframework slice missing, entitlements
  pathway, real signing). Catch it on every push.
- **Cert SHA-1 pinning** (`ci/lib/resolve-dist-cert-sha.sh`) — `Apple
  Distribution: <name>` is ambiguous when one team has multiple distribution
  certs (multi-app machines). Pin via `security find-identity` + the cert in
  the .app's embedded provisioning profile.
- **macOS app-sandbox re-sign hack** — Xcode's Mac App Store profile strips
  `com.apple.security.app-sandbox`. TestFlight rejects with ITMS-90296. Fix:
  expand the .pkg, force-add sandbox to the .app's signature, repack with
  productbuild + Mac Installer Distribution cert.
- **PlistBuddy `Set :key bool true` is a silent no-op** — PlistBuddy ignores
  type hints on Set. Use `Set :key true` for existing keys, `Add :key bool true`
  for new ones.
- **`fastlane deliver` silently drops metadata fields** — when given just
  `metadata_path`, fields like `support_url` / `marketing_url` / `copyright` /
  `name` / `subtitle` / `privacy_url` are dropped by deliver's loader.
  Workaround: read every file ourselves and pass explicit hashes (see
  `do_upload_metadata` in `Fastfile`).
- **macOS screenshots must go directly into `en-US/` (not `en-US/Mac/`)** —
  deliver's loader globs `<lang>/*.png` and only expands `iMessage` /
  `appleTV` subdirectories. Anything in arbitrary subfolders (e.g. `Mac/`)
  is silently ignored.
- **fastlane snapshot is iOS-only** — macOS uses xcodebuild test +
  XCTAttachment + `extract-mac-screenshots.sh` to pull PNGs from the xcresult.
- **macOS icons need the postCompileScript overwrite** — actool emits a 4-size
  .icns regardless of catalog input. Replacing it with a hand-rolled 10-size
  version is the only reliable way to get sharp icons at every system size.

## GitHub configuration (one-shot)

After creating your repo and pushing the first commit, run:

```bash
make setup-github                                  # uses current repo's origin
# or:
bin/setup-github.sh acme/myapp                     # explicit target
```

This applies the following settings to your repo:

- **Branch protection on `main`**:
  - Require PR before merging (no direct pushes — even for repo admins)
  - Require 6 CI checks green: `app (iOS device)`, `app (iOS Simulator)`, `app (macOS)` (XcodeGen) + `app (Tuist iOS device)`, `app (Tuist iOS Simulator)`, `app (Tuist macOS)` (parity matrix)
  - Require checks to be up-to-date with `main` before merge (strict mode)
  - Enforce on admins (no bypass)
  - Require linear history
  - Require conversation resolution before merge
  - Block force-pushes + branch deletion
- **Repo merge style**: squash-only (no merge commits, no rebase merges)
- **Auto-delete head branches** after merge

The script is idempotent — safe to re-run when you change settings or the
PR job names. It uses `gh api` and needs `gh auth status` to show the
`admin:repo` scope.

If your CI job names diverge from the defaults (e.g. you renamed jobs in
`.github/workflows/pr.yml`), edit the `checks` array in `bin/setup-github.sh`
to match — the names must match the job `name:` attribute exactly.

## License

MIT — see [LICENSE](LICENSE).

See [CHANGELOG.md](CHANGELOG.md) for version history and the [Versioning](CHANGELOG.md#versioning) policy.
