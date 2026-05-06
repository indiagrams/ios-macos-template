# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `docs/RELEASE-WITH-APPLE-NATIVE-TOOLS.md` — alternative release path using `xcodebuild` + `xcrun altool` + `xcrun notarytool` + App Store Connect API direct, for forkers who prefer to avoid the Ruby/fastlane dependency surface (#35)
- `docs/MIGRATING-TO-TUIST.md` — step-by-step migration guide for forkers who prefer Tuist (`Project.swift`) over XcodeGen (`project.yml`); template default remains XcodeGen (#34)
- `Tuist.swift` + `app/Project.swift` — Tuist 4 manifests committed alongside `app/project.yml`. XcodeGen remains the default; Tuist users can `cd app && tuist generate --no-open` and build directly. Forker-time selection arrives in a follow-up PR (Refs #38)
- `bin/switch-to-tuist.sh` — convert a fork from XcodeGen to Tuist via a single command. Idempotent + atomic-rollback (parity with `bin/rename.sh`'s contract). Edits Brewfile, Makefile, ci/local-check.sh, ci/local-release-check.sh, .github/workflows/pr.yml; removes `app/project.yml`. Exercised by `ci/test-switch-to-tuist.sh` and reused by the `bin/rename.sh --generator=tuist` flag in a follow-up PR. (Refs #38)
- `.github/workflows/release.yml` — opt-in weekly TestFlight cron + manual `workflow_dispatch` (with optional `dry_run` input). Schedule cron is COMMENTED OUT by default so existing forks don't get noisy red runs from missing GH Secrets — uncomment after configuring the 7 required secrets (documented inline). Validated end-to-end against `macos-15` runner by [`indiagrams/ios-macos-smoketest`](https://github.com/indiagrams/ios-macos-smoketest); contains every non-trivial CI fix discovered there (WWDR pre-install, runner default Xcode, Ruby 3.3 pin, ASC API key auth, etc.).
- `fastlane/Matchfile` — placeholder template for the [`fastlane match`](https://docs.fastlane.tools/actions/match/) flow that enables CI signing without an Apple ID logged in. Documents 7 required env vars, local first-run sequence, CI consumption pattern, annual rotation steps. Forks must replace the `CHANGE-ME-ORG/CHANGE-ME-REPO-certs.git` URL with their real private certs repo before running match.
- `fastlane/Fastfile` lanes for App ID + ASC bootstrap: `register_app_id` (idempotent App ID creation in Apple Developer Portal via Spaceship), `list_certs` (enumerate all certs), `revoke_cert` (Spaceship-based cert revocation by ASC ID), `bootstrap_asc` (verify Dev Portal App ID + ASC App record; fails fast with one-time-setup instructions because Apple's public ASC API forbids `POST /apps`).
- `bin/mint-installer-cert.rb` + `bin/import-installer-to-match.rb` — bootstrap helpers for the macOS App Store .pkg installer cert (Mac Installer Distribution — separate cert type from Apple Distribution; productbuild signs the .pkg installer wrapper with this). Bypass fastlane match's `cert` action which mis-routes mac_installer_distribution requests to the DISTRIBUTION limit bucket.
- `docs/CONTINUOUS-VALIDATION.md` — describes the smoketest-driven continuous validation pattern; lists the ten canonical CI failure modes the smoketest has surfaced (G1-G10: produce CLI auth, distribution cert limit, match V2 encryption on LibreSSL, Spaceship platform constants, ASC `POST /apps` forbidden, manual signing in CI, `timestamp.apple.com` blips, iOS 26 SDK requirement, Mac Installer Distribution cert plumbing, Swift 6 concurrency in screenshot tests). README + PRINCIPLES.md cross-link.
- PRINCIPLES.md principle #6 — "The release pipeline is continuously validated by a public downstream." Existing principles 6-24 renumbered to 7-25.

### Changed
- CI now runs both XcodeGen and Tuist generators on every PR (3 → 6 required checks). Existing XcodeGen jobs unchanged; new Tuist parity jobs (`app (Tuist iOS device)`, `app (Tuist iOS Simulator)`, `app (Tuist macOS)`) use `bin/switch-to-tuist.sh` to convert the fork before building. `bin/setup-github.sh` updated; existing forkers must re-run `make setup-github` once to pick up the new required checks. README + CONTRIBUTING + PRINCIPLES updated to reference 6 checks. (Refs #38)
- `bin/rename.sh --generator=tuist|xcodegen` flag lets forkers pick their project generator at fork time. Defaults to `xcodegen` (existing behavior preserved). `--generator=tuist` invokes `bin/switch-to-tuist.sh --force` after the rename's substitutions complete — fork ends up with `app/Project.swift` driving builds, `app/project.yml` deleted, Brewfile / Makefile / ci scripts / pr.yml all updated. Validated by `ci/test-rename.sh` (full e2e: rename → verify → make check) and `ci/test-rename-gates.sh` (validation gate forms). `bin/verify-rename.sh` adds a 6th sanity check that fails when neither manifest is present (project broken). `app/Project.swift`'s two `CFBundleDisplayName` lines now use the same placeholder anchoring as `app/project.yml` so the broad rename sweep doesn't conflate APP_NAME with DISPLAY_NAME. (Closes #38)
- `docs/MIGRATING-TO-TUIST.md` refactored as in-place generator-switch guide; primary path for new forkers is now `bin/rename.sh --generator=tuist`. Redundant 200-line reference `Project.swift` skeleton dropped (it lives at `app/Project.swift` on `main` since #39). Step 1 + Step 2 collapsed to pointers; Step 3 ancillary diffs retained as audit reference for what `bin/switch-to-tuist.sh` does. README "Why this template" / Quickstart / Renaming / Repo layout sections now document the `--generator` flag. (Refs #38)
- `ci/local-release-check.sh` is now CI-aware — when ASC API key env vars are set it threads `-authenticationKeyPath` to xcodebuild for non-interactive auth (avoids "No Accounts: Add a new account" on CI), supports manual signing via `RELEASE_IOS_PROFILE_NAME` / `RELEASE_MACOS_PROFILE_NAME` env vars (avoids "Cloud signing permission error" during exportArchive), threads `RELEASE_BUILD_NUMBER` into `CFBundleVersion` (required for repeat ASC uploads to the same `CFBundleShortVersionString`), patches `installerSigningCertificate` for .pkg signing, and retries `codesign`/`productbuild` calls on transient `timestamp.apple.com` blips. All purely additive — when env vars are absent, the original local-only flow runs unchanged.
- `fastlane/Fastfile` `release` lane is now match-aware — when `fastlane/Matchfile` exists, runs `match` readonly for iOS App Store + macOS App Store + Mac Installer Distribution, then threads match's emitted profile names to `ci/local-release-check.sh` via env vars. When Matchfile is absent (default), original automatic-signing behavior is preserved. Step counter went from 4 to 5 (extra "match sync" step).
- `before_all` block in `fastlane/Fastfile` runs `setup_ci` on CI runners (creates a temp keychain, switches match to readonly) and primes the ASC API token globally so any Spaceship call authenticates without 2FA.
- `ASC_API_KEY_BASE64` → `ASC_API_KEY_P8_BASE64` everywhere (Fastfile, `ci/bump-asc-version.{rb,sh}`, README). Matches GH Secret naming convention and clarifies the value is the .p8 contents base64-encoded, not some other format. Forks using the old name must update their `.env.local` and any GH Secrets.
- `app/UITests/AppStoreScreenshotTests.swift` annotated `@MainActor` to satisfy Swift 6 strict concurrency when calling fastlane snapshot's `setupSnapshot()` and `snapshot()` (both `@MainActor`). Latent build error that PR CI didn't catch because `app (iOS Simulator)` runs `xcodebuild build` not `test`. Same pattern already used in `app/MacOSUITests/AppStoreScreenshotTests.swift`.

## [1.0.0] - 2026-05-01

### Changed
- Visibility flipped from private to public on 2026-05-01 (M5 P3)

## [0.x] - 2026-04-30

### Added
- MIT license + Code of Conduct (Contributor Covenant 2.1) + SECURITY.md + CONTRIBUTING.md + PR/issue templates (M1, M2)
- `bin/rename.sh` — substitution script for forking the template (app name, bundle ID, display, email, repo slug) (M3 P1)
- `bin/verify-rename.sh` + paths-filtered CI workflow — one-command verdict that rename completed cleanly (M3 P3)
- `bin/setup-github.sh` — branch protection + auto-merge + squash-only configuration (M2)
- README `## Renaming the stub` — 5-command operationally-correct flow leading forkers from rename through publish-and-protect (M3 P4)
- README `## What you get` — iOS + macOS screenshots showing the HelloApp template stub (M4 P1)
- README `## Quickstart in 5 minutes` — 4-command on-ramp from `gh repo create --template` to green build (M4 P2)

## Versioning

This CHANGELOG tracks **template versions** — releases of the `ios-macos-template` repo itself, not the forker apps that consume it. Forker apps maintain their own CHANGELOG and version policy independently.

Pre-1.0 (`0.x`) is the development phase: breaking changes are allowed without bumping a major version. The `0.x` retrospective entry above summarizes what shipped during M1–M4 milestones; further pre-1.0 work lands under `[Unreleased]` until the public flip.

`v1.0.0` will be cut at the public-visibility flip (ROADMAP M5 P4) — first public release. From `v1.0.0` onward this project follows strict [Semantic Versioning](https://semver.org/spec/v2.0.0.html): `MAJOR.MINOR.PATCH` where MAJOR is incremented for breaking forker-facing changes (renamed `bin/` scripts, removed Make targets, restructured README sections that forkers cite), MINOR for new forker-facing features (new scripts, new sections), and PATCH for fixes that don't change the forker contract.

Forkers tracking template upgrades should read the CHANGELOG before pulling template changes into their fork. Template-fork creation always uses the default branch (`main`); to base a fork on a specific template version, use `git fetch` to pull a specific tag and rebase manually.

## Tagging

When cutting a release:

1. Move the `[Unreleased]` entries into a new `[X.Y.Z] - YYYY-MM-DD` section in `CHANGELOG.md` and commit.
2. Extract the new section to a release-notes file: `awk '/^## \[X\.Y\.Z\]/{flag=1; print; next} flag && /^## /{exit} flag' CHANGELOG.md > release-notes.md`.
3. Create an annotated tag with the release notes as its message, push, and create the GitHub release.

```bash
# After moving Unreleased → [X.Y.Z] in CHANGELOG.md, committing,
# and writing release-notes.md (the new section's body):
git tag -a vX.Y.Z --cleanup=verbatim -F release-notes.md   # annotated tag; --cleanup=verbatim preserves Markdown headings (default --cleanup=strip eats #-prefixed lines); -F reads notes from file
git push origin vX.Y.Z
gh release create vX.Y.Z --notes-from-tag --title "vX.Y.Z" --verify-tag
```
