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
