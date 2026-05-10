# apple-shipkit

[![CI](https://github.com/indiagrams/apple-shipkit/actions/workflows/pr.yml/badge.svg)](https://github.com/indiagrams/apple-shipkit/actions/workflows/pr.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org)
[![Discord](https://img.shields.io/badge/Discord-join%20chat-5865F2?logo=discord&logoColor=white)](https://discord.gg/sExv9eKdA)
[![Weekly canary](https://github.com/indiagrams/apple-shipkit/actions/workflows/canary-trigger.yml/badge.svg)](https://github.com/indiagrams/apple-shipkit/actions/workflows/canary-trigger.yml)
[![Local-mode canary](https://github.com/indiagrams/apple-shipkit/actions/workflows/canary-local-mode.yml/badge.svg)](https://github.com/indiagrams/apple-shipkit/actions/workflows/canary-local-mode.yml)

> **Goal of this README:** if you've never shipped an iOS or Mac app before, by the end of it you will have one running on your phone (or Mac) via TestFlight. About 30–60 minutes of focused time, $99/year for Apple Developer Program, and a Mac to build on (Xcode and the rest of Apple's build tools only run on macOS — you need a Mac even for an iPhone-only app).

<p align="center">
  <img src="docs/screenshots/ios-home.png"   alt="HelloApp template running on iOS Simulator — hammer icon, 'HelloApp' title, and 'Rename me' instruction visible" width="260">
  &nbsp;&nbsp;
  <img src="docs/screenshots/macos-home.png" alt="HelloApp template running natively on macOS — same hammer icon, title, and rename instruction"                       width="500">
</p>

That's the starter app you'll customize into yours.

---

## Why this exists

I'm a first-time iOS developer. Before writing a feature of my actual app, I spent days researching what Apple requires to publish: signing certificates, GitHub Actions signing that mints fresh certs per release, ASC API keys, metadata specs, branch protection, and a dozen Apple-side gotchas that only surface in TestFlight.

I automated or documented every requirement I encountered. That's what this template is — the boring prep work, done.

A public canary fork ([`indiagrams/ios-macos-smoketest`](https://github.com/indiagrams/ios-macos-smoketest)) real-ships to TestFlight on two cadences: CI mode every Monday and local mode every Saturday, both on xcodegen and tuist generators, so Apple-side regressions surface upstream within a week. Catalog at [`docs/CONTINUOUS-VALIDATION.md`](docs/CONTINUOUS-VALIDATION.md).

---

## What you'll learn to do

By the end of this guide:

1. You'll have **forked this template** into your own GitHub repo.
2. You'll have **customized the starter app** to your name + bundle ID.
3. You'll have **shipped a signed build to TestFlight** — Apple's official "beta testing" service.
4. You'll be able to **install your app on your iPhone or Mac** through the TestFlight app.
5. You'll have a release pipeline that re-runs every time you say `make ship` — no more "I forgot how to release" months later.

You will **not** be on the App Store yet — that's a separate Apple review step (covered briefly at the end). TestFlight is the staging ground; everyone uses it before going public.

---

## Vocabulary you'll see (skim this once)

| Term | Plain English |
|---|---|
| **Apple Developer Program** | Apple's paid membership ($99/year). Required to ship apps anywhere outside your own computer. Sign up at [developer.apple.com](https://developer.apple.com). |
| **App Store Connect** (ASC) | The website where you manage your apps, builds, screenshots, and TestFlight testers. Lives at [appstoreconnect.apple.com](https://appstoreconnect.apple.com). |
| **TestFlight** | Apple's beta-testing service. You upload a build here, and you (or invited testers) install it on real devices via the TestFlight app. Free. |
| **Bundle ID** | A unique identifier for your app, in reverse-domain form (e.g. `com.yourname.coolapp`). Once chosen, it's hard to change — pick something you'll keep. |
| **Code signing** | Apple cryptographically signs every app so iPhones know it's "really from you." Setting this up is the most painful part of shipping; this template hides 90% of the pain. |
| **Certificate** (cert) | The cryptographic identity Apple gives you. Lives in your Mac's Keychain. Limited to 3 distribution certs per developer team. |
| **Provisioning profile** | A document Apple generates that ties your cert + your bundle ID + the device(s) it can run on. The release tool auto-creates these for you. |
| **Xcode** | Apple's app — the IDE used to build iOS/Mac apps. Free, but a 15+ GB download. |
| **fastlane** | An open-source tool that automates the dozens of clicks Apple's UI normally requires for a release. The template uses it. |
| **CI** (continuous integration) | "When you push code, GitHub runs your tests/builds automatically." This template uses GitHub Actions. |
| **Repo / fork** | A GitHub repository (a project's home). To "fork" is to make your own copy you can change without affecting the original. |

You don't need to memorize these — refer back as you hit each.

---

## What you need before you start

### Hardware
- **A Mac.** Any Mac running macOS Sequoia (15) or newer. **Required even for iOS-only apps** — Xcode 26, xcodebuild, fastlane, and the iOS Simulator only run on macOS. There is no supported way to build iOS or Mac apps on Windows or Linux.
- **(Optional) An iPhone or iPad** to install your app via TestFlight at the end. Not strictly required — TestFlight also works on Mac.

### Money
- **$99 USD/year** for the Apple Developer Program. This is non-negotiable — Apple controls who can ship apps. Pay it once, you're set for a year.
- That's it. The template, GitHub, fastlane, and TestFlight itself are all free.

### Time
- **30–60 minutes** of focused time for the first ship. Most of it is waiting (Xcode install, Apple verification, etc.).
- **5 minutes** for every subsequent release.

### Patience for one specific thing
- **Apple Developer enrollment** sometimes requires a real-name verification step that takes 24–48 hours. If this hits you, plan for a 2-day setup window. Most enrollments go through in minutes.

---

## Step 1 — Install the developer tools (~15 minutes)

These are one-time installs. If you've done iOS/Mac development before, you may have most already.

```bash
# 1. Xcode (Apple's IDE — required for building anything Apple)
#    Open the Mac App Store, search "Xcode", install. ~15 GB download.
#    After install, open Xcode once to accept the license.

# 2. Xcode Command Line Tools (the underlying build tools)
xcode-select --install   # opens a system installer dialog; click Install

# 3. Homebrew (macOS package manager — installs everything else)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 4. The GitHub CLI + git
brew install gh git

# 5. Authenticate gh (this opens your browser to log into GitHub)
gh auth login    # pick: GitHub.com → HTTPS → Yes (auth git) → browser
```

**Sanity check** — paste this and confirm each line shows a version number, not "command not found":

```bash
xcodebuild -version    # Xcode 26.x or higher
brew --version         # Homebrew 4.x or higher
gh --version           # gh version 2.x
git --version          # git version 2.x
```

If anything is missing, this template ships a one-shot checker — clone temporarily and run it:

```bash
git clone https://github.com/indiagrams/apple-shipkit.git /tmp/preflight \
  && bash /tmp/preflight/bin/preflight.sh \
  && rm -rf /tmp/preflight
```

It tells you exactly what's missing and how to install it.

---

## Step 2 — Sign up for Apple Developer Program ($99, ~5 minutes most cases)

1. Go to [developer.apple.com/programs/enroll](https://developer.apple.com/programs/enroll).
2. Sign in with the Apple ID you want to ship under. **This Apple ID is permanent** — apps you ship are tied to it. If you don't have one or want a separate "developer" Apple ID, create one first at [appleid.apple.com](https://appleid.apple.com).
3. Choose **Individual** (you, personally) or **Organization** (a registered LLC/Corp — needs a D-U-N-S number; skip unless you have one). Most highschoolers pick Individual.
4. Pay $99 USD via Apple Pay or credit card.
5. Wait for the confirmation email. Most accounts activate within minutes; a small percentage need 24–48 hours of human review.

Once active, you get access to two sites:
- **[developer.apple.com](https://developer.apple.com)** — for certificates, bundle IDs, devices.
- **[appstoreconnect.apple.com](https://appstoreconnect.apple.com)** — for TestFlight, App Store listings, screenshots.

Both use the same Apple ID.

---

## Step 3 — Find your Team ID (~2 minutes)

The Team ID is a 10-character string Apple uses to identify you. You'll need it shortly.

1. Go to [developer.apple.com/account](https://developer.apple.com/account).
2. Click **Membership details** (sidebar) — sometimes labeled **Membership**.
3. Find **Team ID**. Looks like `A1B2C3D4E5`. Copy it.

Save it somewhere — you'll paste it into a config file in Step 6.

---

## Step 4 — Create an App Store Connect API key (~5 minutes)

This is the credential that lets the release tool talk to App Store Connect on your behalf — so you don't have to log into Apple's website every time you ship.

1. Go to [appstoreconnect.apple.com/access/integrations/api](https://appstoreconnect.apple.com/access/integrations/api).
2. Click **+** to generate a key.
3. Name it `apple-shipkit` (any name works).
4. Access: **App Manager** (gives the key permission to upload builds + edit metadata).
5. Click **Generate**.
6. **Download the `.p8` file immediately** — Apple shows it ONCE. If you miss the download, you have to revoke the key and start over.
7. Note the **Key ID** (10 chars, like `ABC1234567`) and **Issuer ID** (UUID, like `12345678-abcd-...`).

Save the `.p8` file somewhere safe. A reasonable convention: `~/.config/secrets/AuthKey_<Key-ID>.p8` with `chmod 600`.

```bash
# Set up a tidy place for your secrets:
mkdir -p ~/.config/secrets
chmod 700 ~/.config/secrets
mv ~/Downloads/AuthKey_*.p8 ~/.config/secrets/
chmod 600 ~/.config/secrets/AuthKey_*.p8
```

---

## Step 5 — Fork this template (~1 minute)

```bash
# Pick a name for your repo (lowercase, hyphens):
gh repo create my-cool-app --template indiagrams/apple-shipkit --public --clone
cd my-cool-app
```

This creates `https://github.com/<your-username>/my-cool-app`, copies the template into it, and clones it locally.

> **Why public?** Public repos are free on GitHub. You can choose `--private` if you prefer; both work the same.

---

## Step 6 — Customize your app (~5 minutes)

The template ships with a starter app called **HelloApp**. Time to make it yours.

First, run the one-time dev-env setup. This installs the Ruby gems (fastlane et al.), Homebrew packages (xcodegen, lefthook, etc.), regenerates the Xcode project, and wires up the pre-push git hook. Takes ~30-90 seconds depending on what's already installed:

```bash
make bootstrap
```

Then scaffold a config file for the fork-bootstrap pipeline:

```bash
make init
```

This creates `.bootstrap.env` — open it in your editor and fill in the values:

```bash
$EDITOR .bootstrap.env
```

You'll see something like this. The fields marked `# fill in` are yours to set; the rest are sensible defaults or auto-filled by `make init` from your git remote:

```env
# What to call your app
APP_NAME=MyCoolApp                          # PascalCase, no spaces. Used as scheme + product name.
BUNDLE_ID=com.yourname.mycoolapp            # Reverse-domain. Must be globally unique.
DISPLAY_NAME='My Cool App'                  # The name iPhone users see under the icon.
APP_EMAIL=you@example.com                   # Your contact email. Required by App Store review.

# Pick your project generator (xcodegen is simpler; tuist is more flexible)
GENERATOR=xcodegen                          # xcodegen | tuist

# How releases run: ci = GitHub Actions builds + ships; local = your laptop ships
RELEASE_MODE=local                          # local is easier for first-time. Switch to ci later.

# Which platforms you ship: ios, macos, or both. Default 'ios,macos'.
PLATFORMS=ios,macos                         # 'ios' or 'macos' to ship just one

# Apple credentials (from Steps 3 + 4)
FASTLANE_TEAM_ID=A1B2C3D4E5                 # fill in — from Step 3
ASC_API_KEY_ID=ABC1234567                   # fill in — from Step 4 — Key ID
ASC_API_KEY_ISSUER_ID=12345678-abcd-...     # fill in — from Step 4 — Issuer ID
ASC_API_KEY_P8_PATH=~/.config/secrets/AuthKey_ABC1234567.p8  # fill in — from Step 4

# GitHub identity — auto-filled from `git remote get-url origin`. Override only
# if your fork lives somewhere other than github.com/<you>/<repo>.
GH_ORG=your-username                        # auto-filled by make init
GH_APP_REPO=my-cool-app                     # auto-filled by make init

# Optional design + ASC fields. Fill these in before running `make ship` for
# real (placeholder icon is fine for TestFlight; SKU/ASC name only matter once
# you've created the App Store Connect App record — see Step 7 below).
ICON_1024_PATH=                             # leave blank to use the placeholder hammer icon
ASC_APP_SKU=mycoolapp-001                   # any unique-to-you string
ASC_APP_NAME='My Cool App'                  # what shows on the App Store

# CI-mode only — leave blank for RELEASE_MODE=local. `make bootstrap-fork`
# generates a random 32-char password and writes it to this file if it
# doesn't exist yet, for when you switch to CI mode later. It locks the
# controlled keychain that release.yml mints fresh signing certs into
# per release run (then revokes them on workflow exit).
KEYCHAIN_PASSWORD_FILE=                     # ~/.config/secrets/keychain-password (CI mode only)
```

> **Pick BUNDLE_ID carefully.** It's the unique fingerprint of your app, and you can't change it later without losing your TestFlight history. If you own a domain, use it (`com.yourdomain.appname`). If you don't, `com.yourgithubusername.appname` is fine.

> **Why two modes?** `RELEASE_MODE=local` signs from your laptop using certs in your Keychain — easy first-run, no server config needed. `RELEASE_MODE=ci` runs the full pipeline on GitHub Actions when you run `make ship` (which dispatches `release.yml` via `gh workflow run`) — more setup, but it means anyone with repo write access can ship from any machine. Each CI release run mints its own short-lived signing certs into a controlled keychain and revokes them when the run ends, so there's no shared certs repo or PAT to manage. Start with `local`. You can switch later.

> **Bootstrapped before v1.6?** Older forks may still have `GH_CERTS_REPO`, `GH_PAT_FILE`, or `MATCH_PASSWORD_FILE` set in `.bootstrap.env`, plus `MATCH_PASSWORD` and `MATCH_GIT_BASIC_AUTHORIZATION` in their GH Secrets. They're harmless leftovers — the current pipeline ignores them. You can delete them at your leisure (or keep them; nothing reads them).

> **Why pick a platform subset?** If you're shipping an iPhone-only app and don't care about Mac, set `PLATFORMS=ios` — `make doctor` will stop probing for the Mac Installer cert, `make ship` skips the macOS .pkg build/upload, and CI on PRs runs fewer jobs (saving ~2-4 min/PR of macOS runner time). Same in reverse for `PLATFORMS=macos`. Switchable later: change the value, re-run `make bootstrap-fork`. **In CI mode, also re-run `bin/setup-github.sh`** — the required-checks list is set on first bootstrap and won't update automatically when you flip platforms.

---

## Step 7 — Verify everything is good (~30 seconds)

> **Before you run this:** Apple requires you to create the App Store Connect "App record" by hand once, before any tooling can upload a build. This is the one mandatory step the template can't automate (Apple's API forbids `POST /apps`).
>
> Go to [appstoreconnect.apple.com/apps](https://appstoreconnect.apple.com/apps), click **+ → New App**, fill in your **bundle ID** (matches `BUNDLE_ID` from Step 6) and **display name** (matches `DISPLAY_NAME`). Takes ~30 seconds. If you skip this, `make doctor` will fail at the `bootstrap_asc` step with a clear pointer back here.

```bash
make doctor
```

`make doctor` is read-only — it checks every prerequisite without changing anything. You'll see output like:

```
Bootstrap doctor
────────────────
  1. ✓ Required tools on PATH (xcodebuild, brew, fastlane, gh, …)
  2. ✓ Apple Developer credentials present
  3. ✓ App Store Connect API key valid
 ...
 11. ⚠ App Store screenshots
      No fastlane/screenshots/en-US/ — capture via `ci/take-screenshots.sh` before App Store review (not TestFlight).

Summary
───────
  ✓ 9 done    ⚠ 2 advisory

All bootstrap steps complete. Run `make ship` to trigger a release.
(Advisory items above are App-Store-review-only and don't block TestFlight.)
```

If you see `✗` (red) marks instead, doctor will tell you exactly what's missing and how to fix it.

> **Common first-time failures:**
> - Missing `.p8` file → re-check Step 4
> - Wrong Team ID → copy from Step 3 again
> - "ASC App record not found" → see the callout above; this is the manual ASC step.

When every step is `✓` or `⚠`, you're ready. (The pipeline runs 14 steps in both `local` and `ci` mode — the local-only and CI-only steps swap in and out, but the totals match.)

---

## Step 8 — Ship to TestFlight (~10 minutes)

```bash
make all
```

This runs the whole pipeline:

1. `make doctor` — re-verifies (idempotent)
2. `make bootstrap-fork` — sets up certs, registers the bundle ID, etc.
3. `make ship` — builds, signs, uploads, tags

You'll see ~5 minutes of build output. The release tool does roughly:

```
✓ Renaming HelloApp → MyCoolApp
✓ Generating Xcode project
✓ Provisioning iOS Distribution cert
✓ Provisioning Mac Installer Distribution cert
✓ Building iOS .ipa (5m)
✓ Building Mac .pkg (3m)
✓ Uploading both to TestFlight
✓ Tagging the commit v2026.20.1
✓ Pushing the tag
```

If anything goes red, the tool stops and prints a real error message — no swallowed failures. See "When something goes wrong" below.

After upload, Apple takes 5–15 minutes to **process** the build before it's testable. Run:

```bash
make verify
```

…to poll Apple until your build shows up as `state=VALID`. Output looks like:

```
Latest 4 builds for com.yourname.mycoolapp:
  ✓ 1 (2026.20.1)  state=VALID  uploaded=2026-05-13T15:23:01Z
  ⏳ 1 (2026.20.1)  state=PROCESSING  uploaded=2026-05-13T15:22:45Z

✅ Latest build 1 is processed and ready for TestFlight testers.
```

Both binaries `VALID` = you're done shipping. **You just shipped your first iOS + Mac app.**

---

## Step 9 — Install the app on your phone

1. Install the **TestFlight** app on your iPhone or iPad ([App Store link](https://apps.apple.com/app/testflight/id899247664)).
2. Sign in with the same Apple ID you used to enroll.
3. The TestFlight app shows your `My Cool App` under "Apps" because you're the developer.
4. Tap **Install**.
5. Open the app — it's running on your phone, signed by you, distributed by Apple.

For Mac: the same TestFlight app works on macOS Sequoia+ — install from the [Mac App Store](https://apps.apple.com/app/testflight/id899247664).

To invite friends to test: open [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → your app → TestFlight tab → add their Apple IDs as Internal Testers (immediate, no review) or External Testers (requires Apple to approve your build first, takes 24h).

---

## What now?

You have a working app + working release pipeline. From here:

| Goal | What to do |
|---|---|
| Change the app's behavior | Edit files in `app/Shared/` (SwiftUI code, cross-platform). Run `make check` to verify it still builds. |
| Ship a new version | `make ship` again — it handles versioning automatically (CalVer: `v2026.20.<run-number>`). |
| Replace the placeholder icon | Drop a 1024×1024 PNG into `app/iOS/Assets.xcassets/AppIcon.appiconset/Icon-1024.png`, run `make icons` to regenerate the macOS .icns, ship again. |
| Submit to the actual App Store | Capture screenshots (`make screenshots`), fill in `fastlane/metadata/en-US/*.txt`, then `fastlane ios submit_for_review`. See [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md) for the App Store submission section. |
| Move signing to GitHub Actions | Set `RELEASE_MODE=ci` in `.bootstrap.env`, follow the "Two release modes" section in [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md#two-release-modes). |

---

## When something goes wrong

Most first-time failures fall into a few buckets. Here's what to do:

| Symptom | Likely cause | Fix |
|---|---|---|
| `make doctor` exits 2 with "missing 5 GH Secrets" | You set `RELEASE_MODE=ci` before configuring GH secrets | Either set `RELEASE_MODE=local` for now, or follow [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md) to configure CI secrets |
| Signing fails with "Could not install WWDR certificate" during a CI release | Apple's intermediate cert isn't trusted on the runner before fresh certs are minted | The template's release.yml pre-installs WWDR before sigh provisions — see [docs/CONTINUOUS-VALIDATION.md G4](docs/CONTINUOUS-VALIDATION.md) |
| `altool` rejects with "ITMS-90296: app sandbox" on Mac | Xcode's Mac App Store profile strips `com.apple.security.app-sandbox` | The template's `local-release-check.sh` re-adds it automatically. If you see this, the script didn't run — file an issue with the full output |
| "Provisioning profile doesn't include the device" | You're trying to sideload, not TestFlight-distribute | TestFlight builds don't need device IDs in the profile. If you see this from `make ship`, your `RELEASE_MODE` may be misconfigured |
| `make doctor` says "ASC App record not found" | One-time human step — Apple's API forbids `POST /apps` | Go to [appstoreconnect.apple.com/apps](https://appstoreconnect.apple.com/apps), click + → New App, fill in your bundle ID + display name, then re-run `make doctor` |
| Apple rejects with "Account holder must accept Paid Apps Agreement" | Skip-able for free apps | If you're shipping a free app, no fix needed. If paid, log in to ASC → Agreements, Tax, and Banking → accept |
| Random `make ship` failure during CI mode | Check the latest entries in [docs/CONTINUOUS-VALIDATION.md](docs/CONTINUOUS-VALIDATION.md) — a 14-entry catalog of known shipping-pipeline gotchas |

If something isn't on this list, [open an issue](https://github.com/indiagrams/apple-shipkit/issues/new) with the full `make ship` output. The maintainers care; this template exists to absorb new gotchas as they're discovered.

---

## When to use this (vs alternatives)

apple-shipkit is **release-engineering scaffolding** — the path from
`Use this template` to a signed TestFlight build. It deliberately doesn't
pick a UI framework, networking stack, or persistence layer.

### vs. Apple's own tooling (Xcode Distribute, Xcode Cloud)

These are the most common "you don't need this template" comebacks, and they're correct for some use cases:

| You want… | Use | Why |
|---|---|---|
| Manual one-off ship from one Mac, no team, no CI | Xcode → Organizer → Distribute App | Built-in, zero setup, free. Trade-offs: interactive every ship, certs live only in your Keychain, no reproducibility (uses your Mac's current state), no audit trail, no CI on PRs. |
| Hosted CI inside Apple's ecosystem; comfortable with vendor lock-in | [Xcode Cloud](https://developer.apple.com/xcode-cloud/) | Apple's managed CI ($14.99/mo past 25-hour free tier). Workflows configured in Xcode UI, stored in `.xcodeproj`. Trade-offs: workflows aren't portable to other CIs, predefined `ci_*.sh` hooks limit shell flexibility, log debugging is black-box. |

apple-shipkit's value lives in the gap:

- **More than Xcode Distribute**: reproducible builds (Gemfile.lock + pinned Swift/Xcode), audit-tracked (git tags + workflow logs + CHANGELOG per ship), CI-driven (PRs build real apps; ship is `gh workflow run`, not a button), ephemeral CI signing (each release run mints its own short-lived certs into a controlled keychain on the runner and revokes them on exit, instead of trusting whatever's in any one developer's Keychain).
- **Different shape from Xcode Cloud**: portable GitHub Actions YAML you can take to GitLab / CircleCI / Buildkite, full bash + ruby + fastlane flexibility, no per-minute Apple billing, debug failures locally with `make ship` or `make release-dryrun`.

You probably **don't need** apple-shipkit if you're solo, ship one app, will always ship from one Mac, and never want to leave Xcode. You probably **do** if any of those is or will be untrue — especially if you've ever lost half a day to "why does signing work on my machine but not in CI".

### vs. other Swift project templates

Different tradeoff from other iOS starters:

| You want… | Use | Why |
|---|---|---|
| Pipeline (signing + CI + TestFlight + ASC submission) prewired | **apple-shipkit** | What this template focuses on. Fastlane (sigh) + GitHub Actions (mint-fresh CI signing) + canary continuous validation. |
| UI architecture + screens + sample data | [`ios-project-template`](https://github.com/messeb/ios-project-template), [`ios-mvp-template`](https://github.com/onl1ner/ios-mvp-template), or `SwiftPlate` | These ship app scaffolding (MVVM/MVP/Coordinator). You'd bring fastlane/CI yourself. |
| Generate a fresh project from a manifest | `tuist scaffold` | Generates project files. No signing, no CI, no release wiring. |
| Subscription bundle (RevenueCat + paywall + IAP) | [RevenueCat Quickstart](https://www.revenuecat.com/docs/getting-started/quickstart) | apple-shipkit is intentionally framework-agnostic; bring your own monetization. |
| Bare `gh repo create` from a Swift project you already have | _no template needed_ | apple-shipkit is for people who don't have the project yet, or who do but want fastlane + CI signing prewired. |

Mix-and-match is fine. Many people start with apple-shipkit for the release pipeline, then drop in a UI template's screens or a RevenueCat paywall on top.

---

## Going deeper (advanced)

Once you're past the first ship, these docs cover the rest:

- **[docs/BOOTSTRAP.md](docs/BOOTSTRAP.md)** — every field of `.bootstrap.env` explained; CI-mode setup; manual fallback if you want to drive the bootstrap by hand.
- **[docs/APPLE-PREREQS.md](docs/APPLE-PREREQS.md)** — Apple-side setup details, especially for the ASC App record.
- **[docs/CONTINUOUS-VALIDATION.md](docs/CONTINUOUS-VALIDATION.md)** — the 14-entry catalog of shipping-pipeline gotchas (G1–G14, covering both CI and local modes). Living document; updated whenever something new is caught by either canary.
- **[docs/MIGRATING-TO-TUIST.md](docs/MIGRATING-TO-TUIST.md)** — switching from XcodeGen to Tuist after fork.
- **[docs/RELEASE-WITH-APPLE-NATIVE-TOOLS.md](docs/RELEASE-WITH-APPLE-NATIVE-TOOLS.md)** — same archive/export flow without fastlane (uses `xcrun altool` + `notarytool` + ASC API directly).
- **[docs/PRINCIPLES.md](docs/PRINCIPLES.md)** — design decisions behind the template's structure.
- **[docs/ROLLBACK.md](docs/ROLLBACK.md)** — undoing a TestFlight build, a git tag, or a partial bootstrap-fork.
- **[docs/NO-CI.md](docs/NO-CI.md)** — running the template in local-only mode (no GitHub Actions, no GH Secrets).

---

## How releases work under the hood

If you want to know what `make ship` actually does, here's the 30-second version:

```
make ship
  ↓
bin/ship.rb (idempotency: skip if HEAD already tagged)
  ↓
RELEASE_MODE=local?  → bundle exec fastlane release tag:vYYYY.WW.HHMM
RELEASE_MODE=ci?     → gh workflow run release.yml (triggers GitHub Actions)
                          ↓
                       fastlane release tag:vYYYY.WW.<run-number>
                          ↓
                       1. mint fresh iOS + Mac signing certs via sigh into a
                          controlled keychain (revoked on workflow exit)
                       2. xcodebuild archive + export → .ipa (iOS) + .pkg (Mac)
                       3. altool upload → App Store Connect
                       4. git tag + push
```

Each step is its own fastlane lane in `fastlane/Fastfile`. Read the file — it's heavily commented.

---

## Continuous validation

[![Weekly canary (CI mode)](https://github.com/indiagrams/apple-shipkit/actions/workflows/canary-trigger.yml/badge.svg)](https://github.com/indiagrams/apple-shipkit/actions/workflows/canary-trigger.yml)
[![Weekly canary (local mode)](https://github.com/indiagrams/apple-shipkit/actions/workflows/canary-local-mode.yml/badge.svg)](https://github.com/indiagrams/apple-shipkit/actions/workflows/canary-local-mode.yml)

The two badges above reflect the most recent canary runs:

- **CI-mode canary** ([`canary-trigger.yml`](https://github.com/indiagrams/apple-shipkit/actions/workflows/canary-trigger.yml)) — exercises the CI-mode mint-fresh shipping path used by forks with `RELEASE_MODE=ci` (release.yml mints fresh certs per run, ships, then revokes them). Both `dispatch (xcodegen)` and `dispatch (tuist)` cells real-ship to TestFlight on the [smoketest fork](https://github.com/indiagrams/ios-macos-smoketest).
- **Local-mode canary** ([`canary-local-mode.yml`](https://github.com/indiagrams/apple-shipkit/actions/workflows/canary-local-mode.yml)) — exercises the local-mode sigh-based shipping path used by forks with `RELEASE_MODE=local` (the default). Mints throwaway certs in the same Apple team, ships to TestFlight, revokes the certs on `always()` so net team-cert delta per run is 0.

Either badge red → at least one cell failed. Click the badge to see which cell + why. Per-cell history (xcodegen vs tuist) lives in each workflow's run-by-run breakdown.

The validation infrastructure (all on the smoketest fork):
- **Mondays 07:00 UTC**: read-only doctor matrix (4 cells: xcodegen|tuist × ci|local) — covers bootstrap toolchain.
- **Mondays 09:00 UTC**: full release ship to TestFlight via `release.yml`, both generators in sequence — covers the CI-mode signing pipeline + Apple infrastructure.
- **Saturdays 11:30 UTC**: full release ship to TestFlight via `canary-local-mode.yml`, both generators sequentially — covers the local-mode signing pipeline (sigh-based profiles, fresh-cert minting, β cert SHA-1 pinning, controlled keychain).

Bugs in fastlane / sigh / Apple's signing infra surface there before they bite forkers — patches land in this template before they hit your repo.

If you fork this template and your build breaks unexpectedly, [check the smoketest's Actions tab](https://github.com/indiagrams/ios-macos-smoketest/actions) — it's probably broken there too (Monday morning for CI-mode regressions, Saturday morning for local-mode), and a fix is in flight.

---

## Repo layout (skim if curious)

```
.
├── .github/workflows/
│   ├── pr.yml                   # 6 build jobs on every PR (3 XcodeGen + 3 Tuist)
│   ├── release.yml              # signed release pipeline (workflow_dispatch + canary-driven)
│   ├── bootstrap-doctor-matrix.yml  # weekly doctor sweep across 4 cells
│   ├── canary-trigger.yml       # weekly CI-mode ship-validation (template-only; no-op on forks)
│   ├── canary-local-mode.yml    # weekly local-mode ship-validation (cron commented; forks opt in)
│   └── verify-rename.yml        # gate: rename script integrity
├── Brewfile                     # xcodegen + tuist + fastlane + lefthook
├── Makefile                     # init | doctor | bootstrap-fork | ship | verify | all
├── lefthook.yml                 # pre-push: ci/local-check.sh --fast
├── .bootstrap.env.example       # template config; copy to .bootstrap.env
├── bin/
│   ├── doctor.rb                # `make doctor` driver
│   ├── bootstrap-fork.rb        # `make bootstrap-fork` driver
│   ├── ship.rb                  # `make ship` driver (handles ci|local modes)
│   ├── verify-testflight.rb     # `make verify` driver
│   ├── lib/bootstrap.rb         # the orchestration framework
│   ├── rename.sh                # rename HelloApp → YourApp
│   ├── switch-to-tuist.sh       # one-way XcodeGen → Tuist switch
│   ├── setup-github.sh          # branch protection + squash-only + 7 required checks
│   ├── preflight.sh             # check developer-tool prerequisites
│   └── ...                      # several smaller helpers
├── ci/
│   ├── local-check.sh           # unsigned iOS device build (CI parity)
│   ├── local-release-check.sh   # signed .ipa + .pkg pipeline
│   ├── take-screenshots.sh      # iOS + macOS App Store screenshots
│   ├── gen-macos-icons.swift    # 1024 PNG → 10-size .icns + iconset
│   └── lib/                     # SHA-pinned shared library
├── fastlane/
│   ├── Fastfile                 # release | bootstrap_certs | upload_metadata | submit_for_review
│   ├── Appfile                  # bundle ID + team
│   ├── Snapfile / MacSnapfile   # screenshot capture config
│   └── metadata/                # App Store listing copy + review info
├── app/
│   ├── project.yml              # XcodeGen manifest (default generator)
│   ├── Project.swift            # Tuist manifest (alternative generator)
│   ├── Shared/                  # SwiftUI app code (cross-platform)
│   ├── iOS/                     # iOS-only resources
│   ├── macOS/                   # macOS-only resources
│   ├── UITests/                 # iOS UITest target (drives screenshots)
│   └── MacOSUITests/            # macOS UITest target
├── Tuist.swift                  # Tuist 4 workspace config
├── Gemfile                      # fastlane via brew Ruby
└── docs/                        # additional docs (see "Going deeper")
```

---

## Why these patterns (the gotchas already solved for you)

If you're curious why the template is structured the way it is, every choice came from a real production failure. The headline ones:

- **iOS device build, not Simulator, as primary CI signal.** Simulator green with device red happens often (xcframework slice missing, entitlements pathway, real signing). Catch on every push.
- **Cert SHA-1 pinning** (`ci/lib/resolve-dist-cert-sha.sh`). `Apple Distribution: <name>` is ambiguous when one team has multiple distribution certs. Pin via `security find-identity` + the cert in the .app's embedded provisioning profile.
- **macOS app-sandbox re-sign hack.** Xcode's Mac App Store profile strips `com.apple.security.app-sandbox`. TestFlight rejects with ITMS-90296. Fix: expand the .pkg, force-add sandbox to the .app's signature, repack with `productbuild` + Mac Installer Distribution cert.
- **PlistBuddy `Set :key bool true` is a silent no-op.** PlistBuddy ignores type hints on `Set`. Use `Set :key true` for existing keys, `Add :key bool true` for new ones.
- **`fastlane deliver` silently drops metadata fields** when given just `metadata_path`. Workaround: read every metadata file ourselves and pass explicit hashes (see `do_upload_metadata` in `Fastfile`).
- **macOS screenshots must go directly into `en-US/`** (not `en-US/Mac/`) — deliver's loader globs `<lang>/*.png` and only expands `iMessage` / `appleTV` subdirectories.
- **fastlane snapshot is iOS-only.** macOS uses `xcodebuild test` + `XCTAttachment` + `extract-mac-screenshots.sh` to pull PNGs from the xcresult.
- **macOS icons need a postCompileScript overwrite.** actool emits a 4-size .icns regardless of catalog input; `gen-macos-icons.swift` produces the full 10-size .icns the build then overwrites with.

Full catalog of CI-specific gotchas: [docs/CONTINUOUS-VALIDATION.md](docs/CONTINUOUS-VALIDATION.md).

---

## Community

Got stuck on Step 4? Apple rejected your build with a cryptic error code? Want to know if anyone else hit the same gotcha? **Come hang out in Discord.**

[![Discord](https://img.shields.io/badge/Discord-join%20chat-5865F2?logo=discord&logoColor=white)](https://discord.gg/sExv9eKdA)

- **Discord** — quick questions, "is this a known issue", showing off what you shipped: [discord.gg/sExv9eKdA](https://discord.gg/sExv9eKdA)
- **GitHub Issues** — actionable bugs in the template (failed `make doctor`, missing prereq check, broken script): [github.com/indiagrams/apple-shipkit/issues](https://github.com/indiagrams/apple-shipkit/issues)
- **GitHub Discussions** — design decisions, "should the template do X", longer threads: [github.com/indiagrams/apple-shipkit/discussions](https://github.com/indiagrams/apple-shipkit/discussions)

First-time shippers especially welcome. Most of the people in this template's lineage learned by getting stuck on the same things you're about to get stuck on.

---

## License

MIT — see [LICENSE](LICENSE).

See [CHANGELOG.md](CHANGELOG.md) for version history and the [Versioning](CHANGELOG.md#versioning) policy.
