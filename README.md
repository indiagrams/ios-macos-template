# ios-macos-template

[![CI](https://github.com/indiagrams/ios-macos-template/actions/workflows/pr.yml/badge.svg)](https://github.com/indiagrams/ios-macos-template/actions/workflows/pr.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org)

Boilerplate for iOS + macOS apps in the Indiagrams house style.
Distilled from production iOS + macOS apps shipping under the indiagrams
org — same XcodeGen layout, same fastlane release pipeline, same App Store
submission tooling.

## Why this template

- **XcodeGen-driven project file.** No `.xcodeproj` committed. The project
  source-of-truth is `app/project.yml`; `xcodegen generate` materializes the
  Xcode bundle. Diffs stay clean and merge conflicts on the project file
  disappear.
- **Lefthook pre-push gate.** `ci/local-check.sh --fast` (an unsigned iOS
  device build) runs locally before every `git push`. CI on GitHub is a
  confirmation, not a discovery channel — broken builds don't reach `main`'s
  PR queue.
- **Signed fastlane releases run locally, not in CI.** Apple cert
  provisioning in GitHub Actions is hard, project-specific, and fragile.
  `fastlane release tag:vX.Y.Z` runs from your laptop with the certs already
  in your login Keychain. The pattern is documented (see "Setting up signing
  + ASC" below); the CI burden is not adopted.

What you get out of the box:

- **Local checks** — `ci/local-check.sh --fast` runs an unsigned iOS device
  build (the primary CI signal) on every `git push` via lefthook.
- **GitHub Actions** — three jobs on every PR: iOS device, iOS Simulator, macOS.
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

## Quickstart

```bash
git clone https://github.com/indiagrams/ios-macos-template.git my-app
cd my-app
make bootstrap          # brew bundle, lefthook install, xcodegen, bundle install
make check              # iOS device build (primary signal)
make check-macos        # macOS build
open app/HelloApp.xcodeproj
```

## Renaming the stub

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

You'll also want to:
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
   base64-encode into `ASC_API_KEY_BASE64`).

The first time you run `fastlane release`, Xcode auto-creates the iOS + macOS
provisioning profiles via `-allowProvisioningUpdates`. Subsequent runs reuse them.

## Repo layout

```
.
├── .github/workflows/pr.yml         # 3 jobs: iOS device, iOS Sim, macOS
├── Brewfile                         # xcodegen, fastlane, lefthook, …
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
│       ├── resolve-dist-cert-sha.sh # cert SHA-1 disambiguation (shared across indiagrams projects)
│       └── SHA256SUMS               # pinned hashes; CI fails if lib/ drifts
├── fastlane/
│   ├── Fastfile                     # release | take_screenshots | upload_screenshots | upload_metadata | submit_for_review
│   ├── Appfile                      # bundle ID + team
│   ├── Snapfile / MacSnapfile       # screenshot capture config
│   └── metadata/                    # App Store listing copy + review info (TODO markers)
└── app/
    ├── project.yml                  # XcodeGen — iOS + macOS targets + UITest targets
    ├── Shared/                      # SwiftUI app code (cross-platform)
    ├── iOS/                         # iOS-only resources (entitlements, AppIcon)
    ├── macOS/                       # macOS-only resources (entitlements, AppIcon, .icns)
    ├── UITests/                     # iOS UITest target (drives fastlane snapshot)
    └── MacOSUITests/                # macOS UITest target (drives screenshot capture)
```

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
bin/setup-github.sh indiagrams/myapp               # explicit target
```

This applies the Indiagrams house-style settings to your repo:

- **Branch protection on `main`**:
  - Require PR before merging (no direct pushes — even for repo admins)
  - Require 3 CI checks green: `app (iOS device)`, `app (iOS Simulator)`, `app (macOS)`
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
