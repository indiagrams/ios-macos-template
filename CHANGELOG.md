# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Local-mode cert handling overhaul. The biggest first-time-shipper friction.

**Real first-time-shipper validation against `my-cool-app` hit step 12 (`Local keychain has signing identities`) as a hard blocker. The doctor's remediation message offered only manual paths (Xcode → Settings → Accounts → Manage Certificates → +, or Apple Developer Portal → Certificates → CSR-upload — 7 manual steps).** Worse, even if a user knew about `fastlane cert`, `make all` (`doctor → bootstrap-fork → ship → verify`) would never reach `bootstrap-fork` because doctor exited 2 on the LocalKeychainCerts blocker. Local-mode `make all` was structurally broken for first-time-shippers with an empty keychain.

### Changed

- `bin/lib/bootstrap.rb` `LocalKeychainCerts` step — extensive rewrite. (1) Doctor message rewrites to lead with `fastlane cert --type X` per missing identity, point to new `make mint-local-certs` target, and surface the `PLATFORMS=ios` escape hatch when missing identities are macOS-only. (2) New `team_mismatched_identities` helper parses the trailing `(TEAMID)` from each `find-identity` line and compares against `FASTLANE_TEAM_ID`. Conservative — permissive on `Created via API` (ambiguous, can't verify team from `find-identity` alone). Catches the consultant-with-multi-teams case without false-positives. (3) Step's `do_it` now auto-mints missing/mismatched identities via the new `mint_local_certs` fastlane lane instead of failing loud. (#115)
- `bin/lib/bootstrap.rb` result protocol — new `[:pending, msg]` return shape. Doctor renders it like `:pending` (red ✗ + dim "will auto-fix on bootstrap-fork") plus the rich message dimmed below; `Runner.bootstrap` calls `do_it` on it. Distinct from `[:blocked, msg]` (still human-gated, still aborts at `bootstrap-fork` time). Exists to support steps whose remediation is programmatic but whose details a user might still want to see (LocalKeychainCerts is the first user). Without this, doctor would exit 2 on auto-fixable blockers and `make all` would never reach `bootstrap-fork` to fix them. (#115)
- README — no changes; the existing first-time-shipper flow (`make bootstrap` → `make init` → edit `.bootstrap.env` → `make all`) now works for forks with empty keychains because LocalKeychainCerts auto-mints during `make all`'s `bootstrap-fork` step. (#115)

### Added

- `make mint-local-certs` target (Makefile) — auto-mints any missing local-mode signing identities (Apple Distribution, Apple Development, 3rd Party Mac Developer Installer) into the user's login keychain. Idempotent — fastlane cert detects existing valid certs and reuses rather than minting duplicates. Same code path as `bootstrap-fork`'s LocalKeychainCerts step, but standalone for users who want to mint certs without running the full bootstrap-fork pipeline. (#115)
- `bin/mint-local-certs.rb` (new file) — Ruby wrapper that loads `.bootstrap.env`, computes missing/mismatched identities via the existing `LocalKeychainCerts` step, and calls `step.do_it`. (#115)
- `fastlane/Fastfile` `mint_local_certs` lane — takes `types:` as a comma-separated string (e.g. `types:apple_distribution,mac_installer_distribution`), reads ASC creds via the existing `asc_api_key` helper (env vars set by `Bootstrap.asc_env`), calls `cert(...)` per type with `team_id`, `api_key`, `keychain_path=login.keychain-db`, `output_path=Dir.tmpdir`. (#115)
- `.github/workflows/bootstrap-doctor-matrix.yml` paths filter — added `bin/mint-local-certs.rb` and `fastlane/Fastfile` so PR-triggered re-runs include cert-handling changes. (#115)

### Changed (earlier — #113)

- README "When to use this (vs alternatives)" section restructured. Added a leading sub-section "vs. Apple's own tooling (Xcode Distribute, Xcode Cloud)" with concrete trade-offs for each, a "where apple-shipkit lives in the gap" breakdown, and an explicit "you probably don't need this if…" framing. Demoted the existing 5-row template-comparison table to a "vs. other Swift project templates" sub-section (content unchanged). Preempts the most-asked Reddit comebacks. (#113)
## [1.3.0] - 2026-05-07

Audit-driven docs hardening, validation-driven bug fixes, and CI workflow refactor. Four themes:

  1. **First-time-shipper audit fixes** — read-only audit of the README + onboarding flow from a fresh first-time-iOS-developer's perspective surfaced 3 BLOCKERs (macOS Sonoma listed as min, but Xcode 26 needs Sequoia; `.bootstrap.env.example` defaulted to `RELEASE_MODE=ci` while the README walked users through `local`; example env block omitted 6 fields the actual file ships including `GH_ORG`/`GH_APP_REPO` from `REQUIRED_ALWAYS`) plus 4 HIGH-severity friction points. All verified against the codebase before fixing. (#106)
  2. **CI workflow consolidation** — `pr.yml`'s 6 platform jobs (xcodegen × {iOS device, iOS sim, macOS} + tuist × same) consolidated into a single matrix job. Halves the file (293 → 209 lines). Matrix is built dynamically from `.bootstrap.env`'s `PLATFORMS` field in the `config:` job, so iOS-only or macOS-only forks literally don't see the cells they don't need (preserving the runner-minutes savings static `if:` skipping wouldn't). Check names stay branch-protection-stable. Bonus: brew-speedup env vars (`HOMEBREW_NO_AUTO_UPDATE`, `HOMEBREW_NO_INSTALL_CLEANUP`, `HOMEBREW_NO_ANALYTICS`) on every macos-15 job. (#104)
  3. **Supply-chain hygiene** — every `actions/*` reference SHA-pinned with a `# v4.x.y` trailing comment. Tag pinning was already done for third-party `ruby/setup-ruby` (#96); this extends the pattern to first-party `actions/checkout` + `actions/upload-artifact`. Removes the tag-rewrite surface entirely. (#105)
  4. **Real first-time-shipper validation findings** — actually running the local-mode onboarding cold from a fresh clone surfaced two blocker-class bugs the static audit (#106) couldn't catch: `make doctor` crashed on a fresh fork with a Bundler::GemNotFound stack trace (no path to `bundle install` in the README's flow); and the `.bootstrap.env` parser kept inline `# comments` as part of values, corrupting every fillable field with comment text. Plus 5 HIGH/MEDIUM friction points. Fix shipped same-day, with regression tests added in #110 to pin both fixes against future drift. (#108, #110)

### Changed

- `.github/workflows/pr.yml` — six near-identical platform jobs consolidated into one matrix-driven `app:` job. Matrix is built dynamically from `PLATFORMS` in the `config:` job's `steps.matrix.outputs.matrix`, then consumed via `strategy.matrix: ${{ fromJson(needs.config.outputs.matrix) }}`. Check names (`app (iOS device)`, `app (Tuist macOS)`, etc.) preserved exactly via `name: "app (${{ matrix.display_name }})"` so existing branch-protection rules need no changes. Net: -179 / +95 lines. (#104)
- All `actions/*` references SHA-pinned. The 4 uses of `actions/checkout` (across `pr.yml`, `release.yml`, `bootstrap-doctor-matrix.yml`, `verify-rename.yml`) and the 1 use of `actions/upload-artifact` (in `release.yml`) all moved from rewritable tag refs to immutable commit SHAs (= v4.3.1 and v4.6.2 respectively, recorded as trailing `# vX.Y.Z` comments on each `uses:` line). Removes the tag-rewrite supply-chain surface entirely. (#105)
- `.bootstrap.env.example` — default `RELEASE_MODE` switched from `ci` to `local`. CI mode requires 7 GH Secrets + a private certs repo + a fine-grained PAT; local mode requires nothing beyond an Apple Developer account. The README always recommended starting with `local` for first-time shippers; the scaffolded default now matches. Comment header reordered to put `local` first. (#106)
- README — `macOS Sonoma (14) or newer` corrected to `macOS Sequoia (15) or newer` at the two callsites where it appeared. Xcode 26 doesn't run on Sonoma. (#106)
- README — Step 6 example `.bootstrap.env` block expanded to cover all fields a forker actually sees: `GH_ORG`/`GH_APP_REPO`/`GH_CERTS_REPO` annotated as auto-filled by `make init` from `git remote get-url origin`; `GH_PAT_FILE`/`MATCH_PASSWORD_FILE`/`KEYCHAIN_PASSWORD_FILE` shown with explicit `(CI mode only)` annotations. Closes the gap where the example pretended REQUIRED_ALWAYS fields didn't exist. (#106)
- README — Step 7 sample doctor output uses local-mode counts (11 total / 9 done / 2 advisory) since `.bootstrap.env.example` now defaults to local. Parenthetical added: "11 steps in local mode, 17 in ci mode — the count above will change accordingly." (#106)
- README — `RELEASE_MODE=ci` description corrected from "every time you push a tag" to "when you run `make ship` (which dispatches `release.yml` via `gh workflow run`)". The push-tag claim was false; bin/ship.rb has always used `workflow_dispatch`. (#106)
- README — PLATFORMS-switch guidance now mentions that `bin/setup-github.sh` must be re-run separately in CI mode (the required-CI-checks list is set on first bootstrap and isn't refreshed by `make bootstrap-fork`). (#106)
- README — ASC App-record creation promoted from a "common first-time failures" bullet to a prominent before-you-run callout at the top of Step 7. It's a one-time human prereq Apple requires (POST /apps is forbidden by their API) and it blocks every subsequent step; demoting it to a footnote was misleading. (#106)
- `bin/lib/bootstrap.rb` env parser — strips inline `\s#` comments from unquoted values (dotenv convention). The `.bootstrap.env.example` template ships every fillable field with an inline `# placeholder` comment; without this strip, a forker who fills the value before the `#` (the natural editing pattern) would have 30+ chars of comment text mashed onto their value, breaking every downstream Apple/GH probe. Quoted values retain any `#` inside; bare `#` in unquoted values (URL fragments etc.) preserved. (#108)
- `Makefile` — new `_check-bundle` guard target that all bundle-using targets (`doctor`, `bootstrap-fork`, `ship`, `verify`, `release-dryrun`) depend on. Fails fast with an actionable hint when ruby gems aren't installed yet, instead of crashing with a Bundler::GemNotFound stack trace. (#108)
- `Makefile` — top-of-file comment rewritten to spell out the canonical forker journey (`gh repo create` → `make bootstrap` → `make init` → edit `.bootstrap.env` → `make all`). Previous comment told first-timers to run `make bootstrap` then `bin/rename.sh` directly (legacy path that contradicts the README). (#108)
- `Makefile` — `make help` text for `bootstrap` and `bootstrap-fork` now explicitly distinguishes them. They are entirely different targets (dev-env setup vs fork-bootstrap pipeline) and the naming similarity was a trap. (#108)
- `.bootstrap.env.example` header — `make bootstrap` reference replaced with `make bootstrap-fork`. The header is scaffolded into every fork's `.bootstrap.env` so the wrong reference propagated to every fork. (#108)
- `bin/preflight.sh` 'Next steps' output — replaced legacy `bin/rename.sh` direct-call advice with the canonical `make bootstrap → make init → make all` flow. (#108)
- `bin/lib/bootstrap.rb` doctor output — `:blocked` items now render with `✗` (red) + bold `— needs fix` suffix, distinguishing from `:warn` (yellow ⚠ = advisory) and `:pending` (red ✗ + dim `— will run on bootstrap-fork`). The action-required tail enumerates the blockers by name + step number instead of saying 'resolve the ⚠ items above'. The advisory hint ('App-Store-review-only and don't block TestFlight') now prints regardless of blocker count, not only on the all-clear path. (#108)
- README Step 6 — now starts with `make bootstrap` (dev-env setup) before `make init`. Previously the README jumped straight to `make init` and the inevitable `make doctor` crash was the first thing a forker saw. (#108)
- `bin/lib/bootstrap.rb` env parser — strengthened to handle two edge cases the original #108 fix missed: (a) quoted value followed by trailing inline comment now correctly extracts the inner content (was: comment-strip ran first and mangled the inner `#`); (b) empty value followed by inline comment now resolves to the empty string (was: returned the comment text). Both edge cases caught by writing `test/parser_test.rb`'s aggressive fixture before merging the test wiring. (#110)
- `.github/workflows/bootstrap-doctor-matrix.yml` — workflow header rewritten to describe all three jobs (full-pipeline matrix + 2 hermetic regression tests) and what each proves vs doesn't. (#110)

### Added

- `test/parser_test.rb` — runnable-locally regression suite for `Bootstrap::Config.parse`. 9 cases pin the parser's contract: inline-comment stripping on unquoted values, `#` preservation inside quoted values, `#` preservation in URL fragments, empty values, tab-as-whitespace, etc. Wired into `bootstrap-doctor-matrix.yml`'s `parser-regression` job (ubuntu-latest, hermetic). (#110)
- `.github/workflows/bootstrap-doctor-matrix.yml` `parser-regression` job — runs `test/parser_test.rb` on every PR that touches the parser, the example file, or the test itself. Catches future regression of #108's BLOCKER 2. (#110)
- `.github/workflows/bootstrap-doctor-matrix.yml` `bundle-guard-regression` job — runs `make doctor` on a fresh macos-15 checkout WITHOUT `bundle install`, asserts the friendly-error path (`Ruby gems aren't installed yet` + both remediation hints + non-zero exit + no Ruby stack trace). Catches future regression of #108's BLOCKER 1. (#110)

### Performance

- macos-15 jobs (`swiftlint` + the `app` matrix) now run with `HOMEBREW_NO_AUTO_UPDATE=1`, `HOMEBREW_NO_INSTALL_CLEANUP=1`, `HOMEBREW_NO_ANALYTICS=1`. Skips the ~30s formula-DB refresh and ~5s post-install cleanup that brew runs on every install. Saves ~30-60s per macos-15 job; six jobs per PR run → ~3-6 min saved per PR. (#104)

## [1.2.0] - 2026-05-07

Audit-driven hardening release. Six themes:

  1. **Real CI signal** — PR jobs now run `xcodebuild test` (was `xcodebuild build`); UI tests + new unit-test targets actually exercised on every PR for both XcodeGen and Tuist generators. Closes a credibility gap where SCOPE.md claimed test scaffolding but CI never ran tests.
  2. **Reproducible CI** — `Gemfile` pins fastlane to `~> 2.224`, `Gemfile.lock` committed (was gitignored). The G11-class regression of "fastlane silently floats overnight" is now structurally prevented.
  3. **2026 Apple submission baseline** — `PrivacyInfo.xcprivacy` stub on both bundles, accessibility scaffolding in `ContentView.swift` (a11y labels, header trait, identifier), `Localizable.xcstrings` with the 3 starter strings, `SWIFT_VERSION 5.9 → 6.0`, `xcodeVersion → 26.0`. Forks ship Apple-2026-baseline-compliant out of the box.
  4. **Pipeline robustness** — `.p8` cleanup at_exit trap; `bootstrap_certs` fails fast on `CHANGE-ME-` placeholder Matchfile; `pilot_with_retry` 3-attempt exponential-backoff wrapper; Discord webhook on canary failure (optional `DISCORD_CANARY_WEBHOOK` secret); third-party `ruby/setup-ruby` SHA-pinned.
  5. **DX docs** — README "When to use this (vs alternatives)" table; `docs/ROLLBACK.md` (TestFlight/tag/bootstrap rollback paths); `docs/NO-CI.md` (RELEASE_MODE=local mode).
  6. **Bug fixes + cruft cleanup** — `bin/setup-github.sh`'s `$REPO_ROOT-under-set-u` bug (broke `make setup-github` on first run); `tuist` install in `bootstrap-doctor-matrix.yml` corrected to `--cask`; step count reconciled across 3 surfaces (was 14/15/17); stale `Renaming the stub` cross-refs replaced with `bin/rename.sh --help`; `.env.local.example` removed; duplicate screenshot script consolidated; `docs/SMOKE-TEST.md` + `docs/AUDIT.md` (pre-public-flip artifacts) deleted.

### Added

- `app/Tests/HelloAppTests.swift` + `app/MacOSTests/HelloAppMacOSTests.swift` — XCTest unit-test stubs. Wired into `HelloAppTests` + `HelloAppMacOSTests` targets in both `project.yml` (XcodeGen) and `Project.swift` (Tuist); both schemes' testActions include them. Forks adding new unit tests under those directories get them exercised by CI automatically. (#88)
- `app/Shared/PrivacyInfo.xcprivacy` — privacy manifest stub with the 4 required keys (`NSPrivacyTracking`, `NSPrivacyTrackingDomains`, `NSPrivacyCollectedDataTypes`, `NSPrivacyAccessedAPITypes`) declared as conservative defaults. Wired into both bundles via XcodeGen sources glob (auto-detected) and Tuist resources arrays (explicit, since Tuist 4.x doesn't auto-pick xcprivacy from globs). (#90)
- `app/Shared/Localizable.xcstrings` — Apple String Catalog with the 3 starter strings pre-keyed in English (`sourceLanguage: en`, `version: 1.0`). Forks adding languages just open the catalog in Xcode and add localizations. Wired into both bundles. (#92)
- `.swiftlint.yml` — starter-template ruleset committed at repo root. Excludes Tuist-generated `app/Derived/`, fastlane-shipped `SnapshotHelper.swift`, build outputs. Disables 4 default rules that fight infrastructure code (`comma`, `trailing_comma`, `identifier_name`, `non_optional_string_data_conversion`). `line_length` warn 140 / error 200. (#89)
- `.github/workflows/pr.yml` `swiftlint` job — runs `swiftlint --strict --reporter github-actions-logging` on every PR. Violations surface as inline annotations. Closes the SCOPE.md "linting is in scope" claim that was previously unbacked. (#89)
- `pilot_with_retry` helper in `fastlane/Fastfile` — 3-attempt exponential-backoff wrapper around fastlane's `pilot()`. Applied to both iOS .ipa and macOS .pkg uploads in the `release` lane. Mirrors `ci/local-release-check.sh`'s `with_timestamp_retry` pattern. (#94)
- `at_exit` cleanup of the decoded ASC API .p8 file in `asc_api_key` helper. Was chmod 0600 but never deleted on process exit. (#94)
- `bootstrap_certs` lane validates the Matchfile for the `CHANGE-ME-` placeholder before running match. Forkers who skip editing `Matchfile` now get an actionable error message instead of a cryptic git clone failure 30+ lines into match's output. (#94)
- Discord webhook step on `canary-trigger.yml` matrix cells — `if: failure()` POST to optional `DISCORD_CANARY_WEBHOOK` secret with smoketest run URL + trigger run URL + generator name. Step exits 0 silently when secret unset. (#95)
- `docs/ROLLBACK.md` — walkthrough for the 4 common rollback scenarios: TestFlight build expiry (web UI + `fastlane testflight_expire`), git tag deletion (local + remote), partial bootstrap-fork (idempotent re-run), full Apple-side reset (ASC App + bundle ID delete + match nuke caveats). (#97)
- `docs/NO-CI.md` — RELEASE_MODE=local setup guide for solo indie shippers who don't want GitHub Actions / GH Secrets / match overhead. Two paths to disable CI workflows; reversibility back to CI mode documented. (#97)
- README "When to use this (vs alternatives)" section — 5-row comparison table positioning apple-shipkit (release-engineering scaffolding) vs `ios-project-template`/`SwiftPlate` (UI architecture), `tuist scaffold` (project generator), RevenueCat Quickstart (subscription bundle), bare `gh repo create` (no template). Answers the most-asked reviewer question. (#97)

### Changed

- **CI runs `xcodebuild test` instead of `xcodebuild build`** on the 4 PR jobs that target simulators (iOS Simulator + macOS, both XcodeGen and Tuist parity). Test action exercises HelloAppUITests + the new HelloAppTests targets. Required-check names preserved → no branch protection update needed. The 2 device-build jobs (`generic/platform=iOS`) stay build-only since generic destinations can't run tests. (#87)
- **iOS Simulator destination resolves dynamically** via `xcrun simctl list devices available -j` + jq. Runner pool variability in macos-15 made hardcoded `name=iPhone 16 Plus,OS=latest` flake intermittently. Picks the first available iPhone simulator; fails loud if none present. (#91)
- **`Gemfile` pins fastlane to `~> 2.224`** (>= 2.224, < 3.0; resolves to 2.230.0 today, predates the G11 OpenSSL::PKey::ECError in 2.233.x). `Gemfile.lock` committed (was gitignored). CI's `bundler-cache: true` now keys on a real lockfile SHA. (#85)
- `SWIFT_VERSION` bumped from `5.9` → `6.0` in both XcodeGen + Tuist manifests' `baseSettings`. App + unit-test targets compile in Swift 6 strict-by-default mode. UI test targets pinned to 5.9 (SnapshotHelper.swift is fastlane-shipped and predates Swift 6's strict concurrency; `AppStoreScreenshotTests` is a MainActor-isolated XCTestCase override; the `setUpWithError`/`tearDownWithError` override pattern errors under Swift 6 (main-actor-isolated property mutated from nonisolated superclass override)). `xcodeVersion` 15.0 → 26.0 in `project.yml`. (#93)
- `app/Shared/HelloApp.swift` — `struct HelloAppApp: App` renamed to `struct HelloAppMain: App`. Apple's `main` entry-point attribute convention produces `<AppName>App` to avoid collision with the App protocol name; after `bin/rename.sh` runs, that becomes the awkward `MyAppApp`. `HelloAppMain` post-rename produces `MyAppMain` — unambiguous. (#92)
- `ContentView.swift` — accessibility scaffolding added: hammer Image marked `.accessibilityHidden(true)`, title gets `.accessibilityAddTraits(.isHeader)`, stub gets `.accessibilityIdentifier("HelloApp.stub")`. UI tests can now match the screen by id, surviving fork localization. (#92)
- `bin/take-readme-screenshots.sh` — gained `--platform-aware` flag. Previously two scripts (`bin/take-readme-screenshots.sh` + `ci/regen-readme-screenshots.sh`) with overlapping responsibilities; consolidated. Forker-default behavior unchanged. (#76)
- `.github/workflows/pr.yml` — `permissions: { contents: read }` block added at top (least-privilege GITHUB_TOKEN). (#86)
- `.github/workflows/bootstrap-doctor-matrix.yml` — `concurrency` block added (group keyed on `github.ref`); cron + dispatch + PR can no longer overlap and run 3× the 4-cell matrix simultaneously. (#86)
- README "Why this exists" section added (#78), tightened to ~110 words (#79), and dropped the `haven't shipped my own app yet` defensive hedge (#80) — first-time-shipper framing without inviting the very critique it was preempting.
- `ruby/setup-ruby@v1` SHA-pinned to `c4e5b1316158f92e3d49443a9d58b31d25ac0f8f` (= release v1.306.0). Third-party action; tag pinning is rewritable by the upstream maintainer. (#96)
- Step count reconciled to "19 step classes; CI mode runs 17 with default `PLATFORMS=ios,macos`; local mode runs 11" across `bin/lib/bootstrap.rb:5`, `docs/BOOTSTRAP.md:99`, and the README. Was previously 14 / 15 / 17 across three surfaces. (#83)

### Fixed

- `bin/setup-github.sh` referenced `$REPO_ROOT` on line 85+ but never defined it; under `set -u` (line 28) the script aborted with `REPO_ROOT: unbound variable` on first run. `make setup-github` failed silently for every fork using `.bootstrap.env`. Define `REPO_ROOT` immediately after `set -euo pipefail` using the standard `$(cd "$(dirname "$0")/.." && pwd)` pattern. (#81)
- `bootstrap-doctor-matrix.yml:91` was `brew install xcodegen tuist` — but `tuist` is a CASK everywhere else in the repo (Brewfile, pr.yml × 3 jobs, release.yml). Mismatch silently broke the tuist cells of the 4-cell matrix. Split to `brew install xcodegen && brew install --cask tuist`. (#82)
- Stale README cross-refs to a "Renaming the stub" section (removed during the v1.1 rewrite) lingered in `Makefile`, `app/Shared/ContentView.swift` (USER-VISIBLE in the starter app — every fork's first build showed a broken cross-ref), and `ci/bump-asc-version.rb`. Replaced with stable references to `bin/rename.sh --help`. (#84)

### Removed

- `.env.local.example` — superseded by `.bootstrap.env.example`. 13 file references migrated; CI scripts kept `.env.local` as backward-compat fallback. (#75)
- `ci/regen-readme-screenshots.sh` — duplicated `bin/take-readme-screenshots.sh`'s capabilities. Functionality merged into the keeper via `--platform-aware` flag. (#76)
- `docs/SMOKE-TEST.md` — manual disposable-fork runbook from before v1.0.0 public flip. Superseded by the live `indiagrams/ios-macos-smoketest` fork + `canary-trigger.yml` + `bootstrap-doctor-matrix.yml`. (#77)
- `docs/AUDIT.md` — pre-public-flip secret/identifier audit explicitly framed around M5 P3 (the public-flip milestone, completed 2026-05-01). The audit isn't run anymore. (#77)

## [1.1.0] - 2026-05-06

First minor release after the public flip. Major themes:

  1. **PLATFORMS option** — forkers can now ship iOS-only, macOS-only, or both via `.bootstrap.env`'s `PLATFORMS` field; pipeline (Fastfile, release.yml, pr.yml, setup-github.sh, doctor) all gate accordingly.
  2. **First-time-shipper friendly README** — full rewrite with vocabulary table, step-by-step Apple Developer enrollment, ASC API key setup, expected-output samples, troubleshooting table, and a Discord community link.
  3. **Continuously validated downstream architecture** — apple-shipkit dispatches release.yml on the smoketest weekly across both generators; bootstrap-doctor-matrix runs a 4-cell read-only doctor sweep; canary-trigger.yml threads `platforms=ios,macos` explicitly so the dispatch chain is exercised end-to-end.
  4. **Bidirectional generator switch** — `bin/switch-to-xcodegen.sh` is the inverse of the existing `bin/switch-to-tuist.sh`; restores `app/project.yml` from git history.
  5. **Repo renamed** `ios-macos-template` → `apple-shipkit`. GitHub auto-redirects old URLs forever; existing forks unaffected.

### Added

- `docs/RELEASE-WITH-APPLE-NATIVE-TOOLS.md` — alternative release path using `xcodebuild` + `xcrun altool` + `xcrun notarytool` + App Store Connect API direct, for forkers who prefer to avoid the Ruby/fastlane dependency surface (#35)
- `docs/MIGRATING-TO-TUIST.md` — step-by-step migration guide for forkers who prefer Tuist (`Project.swift`) over XcodeGen (`project.yml`); template default remains XcodeGen (#34)
- `Tuist.swift` + `app/Project.swift` — Tuist 4 manifests committed alongside `app/project.yml`. XcodeGen remains the default; Tuist users can `cd app && tuist generate --no-open` and build directly. Forker-time selection arrives in a follow-up PR (Refs #38)
- `bin/switch-to-tuist.sh` — convert a fork from XcodeGen to Tuist via a single command. Idempotent + atomic-rollback (parity with `bin/rename.sh`'s contract). Edits Brewfile, Makefile, ci/local-check.sh, ci/local-release-check.sh, .github/workflows/pr.yml; removes `app/project.yml`. Exercised by `ci/test-switch-to-tuist.sh` and reused by the `bin/rename.sh --generator=tuist` flag in a follow-up PR. (Refs #38)
- `.github/workflows/release.yml` — opt-in weekly TestFlight cron + manual `workflow_dispatch` (with optional `dry_run` input). Schedule cron is COMMENTED OUT by default so existing forks don't get noisy red runs from missing GH Secrets — uncomment after configuring the 7 required secrets (documented inline). Validated end-to-end against `macos-15` runner by [`indiagrams/ios-macos-smoketest`](https://github.com/indiagrams/ios-macos-smoketest); contains every non-trivial CI fix discovered there (WWDR pre-install, runner default Xcode, Ruby 3.3 pin, ASC API key auth, etc.).
- `fastlane/Matchfile` — placeholder template for the [`fastlane match`](https://docs.fastlane.tools/actions/match/) flow that enables CI signing without an Apple ID logged in. Documents 7 required env vars, local first-run sequence, CI consumption pattern, annual rotation steps. Forks must replace the `CHANGE-ME-ORG/CHANGE-ME-REPO-certs.git` URL with their real private certs repo before running match.
- `fastlane/Fastfile` lanes for App ID + ASC bootstrap: `register_app_id` (idempotent App ID creation in Apple Developer Portal via Spaceship), `list_certs` (enumerate all certs), `revoke_cert` (Spaceship-based cert revocation by ASC ID), `bootstrap_asc` (verify Dev Portal App ID + ASC App record; fails fast with one-time-setup instructions because Apple's public ASC API forbids `POST /apps`).
- `bin/mint-installer-cert.rb` + `bin/import-installer-to-match.rb` — bootstrap helpers for the macOS App Store .pkg installer cert (Mac Installer Distribution — separate cert type from Apple Distribution; productbuild signs the .pkg installer wrapper with this). Bypass fastlane match's `cert` action which mis-routes mac_installer_distribution requests to the DISTRIBUTION limit bucket.
- `docs/CONTINUOUS-VALIDATION.md` — describes the smoketest-driven continuous validation pattern; lists the canonical CI failure modes (G1–G12) the smoketest has surfaced. README + PRINCIPLES.md cross-link.
- PRINCIPLES.md principle #6 — "The release pipeline is continuously validated by a public downstream." Existing principles 6-24 renumbered to 7-25.
- `.bootstrap.env`-driven bootstrap pipeline — single config file (`make init` to scaffold) drives `make doctor`, `make bootstrap-fork`, `make ship`, `make verify`. 17-step idempotent pipeline implemented in `bin/lib/bootstrap.rb`. Each Step has `check` (no side effects) and `do_it`; runner filters by `MODES` (ci|local) and `PLATFORMS` (ios|macos). Closes the "manually follow 17 README steps" friction. (#52, #54, #55, #66, #67, #68)
- `PLATFORMS=ios|macos|ios,macos` field in `.bootstrap.env` — forkers pick which platforms their fork ships. Defaults to `ios,macos`. Affects: doctor (skips Mac-specific checks if iOS-only), `make ship` (only builds + uploads listed platforms), `pr.yml` (gates iOS/macOS jobs), `setup-github.sh` (derives required-checks list), `bin/rename.sh` (substitutes the SwiftUI stub subtitle), VerifyAscApp's ASC creation hint. Backward-compatible: unset/empty defaults to both. (#66, #67, #68, #72)
- `bin/switch-to-xcodegen.sh` — inverse of `bin/switch-to-tuist.sh`. Restores `app/project.yml` from git history (`--diff-filter=AM` to find the most recent commit whose tree contains the file, not the deletion commit) + reverses Brewfile / Makefile / ci/* / pr.yml mutations. Same atomic-rollback semantics + idempotency dispatch as the tuist direction. Tested via `ci/test-switch-to-xcodegen.sh`. (#69)
- `.github/workflows/canary-trigger.yml` — apple-shipkit-side dispatcher that fires Mondays 09:00 UTC and runs release.yml on `indiagrams/ios-macos-smoketest` for both generators (matrix: xcodegen + tuist) with explicit `platforms=ios,macos`. Inherits the dispatched run's conclusion so smoketest failures surface on apple-shipkit's Actions tab. Skips on forks via `if: github.repository == 'indiagrams/apple-shipkit'`. (#59, #60, #62, #70)
- `.github/workflows/bootstrap-doctor-matrix.yml` — 4-cell read-only matrix (xcodegen|tuist × ci|local) running `bin/doctor.rb` against an injected smoketest checkout. Fires Mondays 07:00 UTC + on PRs touching bootstrap code. Catches toolchain-level regressions before the canary's full ship. (#56, #60)
- `bin/refork-smoketest.sh` — full-E2E refork of the smoketest with `--generator` + `--release-mode` flags. Auto-runs rename, bootstrap, push, branch protection, scaffolds `.bootstrap.env`. Maintainer tool; not synced to the smoketest. (#50, #58)
- Discord community — invite at [discord.gg/sExv9eKdA](https://discord.gg/sExv9eKdA). README Community section + badge. (#65)
- `bin/take-readme-screenshots.sh --platform-aware` — captures platform-aware README hero PNGs (iOS shot with "iOS template" subtitle, macOS shot with "macOS template"). Forker default (no flag) captures the current source as-is. Subsumes the short-lived `ci/regen-readme-screenshots.sh` which was duplicate of this script. (#73)

### Changed

- CI now runs both XcodeGen and Tuist generators on every PR (3 → 6 required checks). Existing XcodeGen jobs unchanged; new Tuist parity jobs (`app (Tuist iOS device)`, `app (Tuist iOS Simulator)`, `app (Tuist macOS)`) use `bin/switch-to-tuist.sh` to convert the fork before building. `bin/setup-github.sh` updated; existing forkers must re-run `make setup-github` once to pick up the new required checks. README + CONTRIBUTING + PRINCIPLES updated to reference 6 checks. (Refs #38)
- `bin/rename.sh --generator=tuist|xcodegen` flag lets forkers pick their project generator at fork time. Defaults to `xcodegen` (existing behavior preserved). `--generator=tuist` invokes `bin/switch-to-tuist.sh --force` after the rename's substitutions complete — fork ends up with `app/Project.swift` driving builds, `app/project.yml` deleted, Brewfile / Makefile / ci scripts / pr.yml all updated. Validated by `ci/test-rename.sh` (full e2e: rename → verify → make check) and `ci/test-rename-gates.sh` (validation gate forms). `bin/verify-rename.sh` adds a 6th sanity check that fails when neither manifest is present (project broken). `app/Project.swift`'s two `CFBundleDisplayName` lines now use the same placeholder anchoring as `app/project.yml` so the broad rename sweep doesn't conflate APP_NAME with DISPLAY_NAME. (Closes #38)
- `docs/MIGRATING-TO-TUIST.md` refactored as in-place generator-switch guide; primary path for new forkers is now `bin/rename.sh --generator=tuist`. Redundant 200-line reference `Project.swift` skeleton dropped (it lives at `app/Project.swift` on `main` since #39). Step 1 + Step 2 collapsed to pointers; Step 3 ancillary diffs retained as audit reference for what `bin/switch-to-tuist.sh` does. README "Why this template" / Quickstart / Renaming / Repo layout sections now document the `--generator` flag. (Refs #38)
- `ci/local-release-check.sh` is now CI-aware — when ASC API key env vars are set it threads `-authenticationKeyPath` to xcodebuild for non-interactive auth (avoids "No Accounts: Add a new account" on CI), supports manual signing via `RELEASE_IOS_PROFILE_NAME` / `RELEASE_MACOS_PROFILE_NAME` env vars (avoids "Cloud signing permission error" during exportArchive), threads `RELEASE_BUILD_NUMBER` into `CFBundleVersion` (required for repeat ASC uploads to the same `CFBundleShortVersionString`), patches `installerSigningCertificate` for .pkg signing, and retries `codesign`/`productbuild` calls on transient `timestamp.apple.com` blips. All purely additive — when env vars are absent, the original local-only flow runs unchanged.
- `fastlane/Fastfile` `release` lane is now match-aware — when `fastlane/Matchfile` exists, runs `match` readonly for iOS App Store + macOS App Store + Mac Installer Distribution, then threads match's emitted profile names to `ci/local-release-check.sh` via env vars. When Matchfile is absent (default), original automatic-signing behavior is preserved.
- `before_all` block in `fastlane/Fastfile` runs `setup_ci` on CI runners (creates a temp keychain, switches match to readonly) and primes the ASC API token globally so any Spaceship call authenticates without 2FA.
- `ASC_API_KEY_BASE64` → `ASC_API_KEY_P8_BASE64` everywhere (Fastfile, `ci/bump-asc-version.{rb,sh}`, README). Matches GH Secret naming convention and clarifies the value is the .p8 contents base64-encoded, not some other format. Forks using the old name must update their `.env.local` and any GH Secrets.
- `app/UITests/AppStoreScreenshotTests.swift` annotated for main-actor isolation to satisfy Swift 6 strict concurrency when calling fastlane snapshot's `setupSnapshot()` and `snapshot()` (both main-actor-isolated). Latent build error that PR CI didn't catch because `app (iOS Simulator)` runs `xcodebuild build` not `test`.
- Repo renamed `ios-macos-template` → `apple-shipkit`. GitHub auto-redirects old URLs (forever). 16 tracked files updated (README, CONTRIBUTING, docs/, bin/preflight.sh, bin/refork-smoketest.sh, bin/rename.sh, bin/verify-rename.sh, ci/test-rename.sh, Tuist.swift, SECURITY.md, CHANGELOG.md). (#57)
- README rewritten for first-time shippers. Goal banner ("TestFlight in 30–60 min, $99/year, a Mac"), vocabulary table, step-by-step Apple Developer + Team ID + ASC API key setup, expected output samples, troubleshooting table, Community section. Existing technical content preserved as "Going deeper" + "Why these patterns". Mac requirement clarified — required even for iOS-only apps because Apple's tools only run on macOS. (#64, #73)
- README screenshots are platform-aware: iOS shot shows `iOS template` subtitle, macOS shot shows `macOS template`. Constrained widths (iOS 260px, macOS 500px) so the iPhone full-screen capture doesn't dominate the README viewport. (#71, #73)
- `bin/rename.sh` gains `--platforms=ios|macos|ios,macos` flag (mirrors `--generator` pattern). Substitutes `Text("iOS + macOS template")` in `app/Shared/ContentView.swift` to the platform-specific label at rename time. RenameStub threads the value from `.bootstrap.env`. (#72)
- `release.yml` gains `platforms` workflow_dispatch input. canary-trigger explicitly passes `platforms=ios,macos` (default) to exercise the full plumbing. (#67, #70)
- `release.yml` gains `generator` workflow_dispatch input — empty default, `tuist` triggers `bin/switch-to-tuist.sh` workspace mutation, `xcodegen` triggers `bin/switch-to-xcodegen.sh` (now possible). Lets canary dispatch the same release.yml for both generators against the same Apple identity without parallel branches. (#62, #69)
- `release.yml` (smoketest copy) byte-equivalent invariant established and tested — drift between upstream and downstream's `release.yml` is treated as a bug. (#61)
- `Fastfile` release lane gates iOS/macOS sections on `ENV['PLATFORMS']` (defaults `ios,macos`). Match calls, `local-release-check.sh` flags, .ipa/.pkg presence checks, pilot uploads — all `do_ios` / `do_macos` gated. (#67)
- `pr.yml` adds a `config` job that reads `.bootstrap.env`'s PLATFORMS and outputs `do_ios`/`do_macos`; the 6 platform-specific build jobs gate on these. iOS-only forks skip 2 macOS jobs (saving ~3-5 min/PR); macOS-only forks skip 4 iOS jobs. (#67)
- `bin/setup-github.sh` derives required-status-checks list from `.bootstrap.env` PLATFORMS at runtime (4 / 2 / 6 entries). (#67)
- `release.yml` selects highest available Xcode 26+ via `ls -d /Applications/Xcode_26*.app | sort -V | tail -1` (Apple enforces iOS 26 SDK for App Store uploads). (#47)
- Apple-shipkit-internal CI workflows (`bootstrap-doctor-matrix.yml`, `canary-trigger.yml`) skip cleanly on forks via `if: github.repository == 'indiagrams/apple-shipkit'`. (#60)

### Fixed

- `bin/switch-to-tuist.sh` invocation in release.yml's generator override now installs tuist eagerly (`brew install --cask tuist`) before invoking the script — the script's preflight needs tuist on PATH, and `make bootstrap` (which would install it via Brewfile) only runs later. Symmetric fix for `bin/switch-to-xcodegen.sh`. (#63)
- `fastlane/Fastfile` `asc_api_key` action uses `key_filepath:` instead of `key_content:` + `is_key_content_base64:`. Workaround for fastlane 2.233.x's OpenSSL `ECError` on `macos-15` runners with Ruby 3.3.11 + OpenSSL 3.6.x. Decodes the base64 .p8 to a mode-0600 tmpfile inside `before_all`. (#48)
- `.env.local.example`: renamed `ASC_API_KEY_BASE64` → `ASC_API_KEY_P8_BASE64` for consistency with GH Secret naming + clarity that the value is the .p8 contents. Forks using the old name update their `.env.local`. (#46)
- `bootstrap_certs` lane wraps the 3 raw `match` invocations from the README's signing setup so `before_all` runs once and the ASC API key is loaded for every call. Without this, raw `fastlane match` from the CLI dies with "Missing username, and running in non-interactive shell". (#49)

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

This CHANGELOG tracks **template versions** — releases of the `apple-shipkit` repo itself, not the forker apps that consume it. Forker apps maintain their own CHANGELOG and version policy independently.

Pre-1.0 (`0.x`) is the development phase: breaking changes are allowed without bumping a major version. The `0.x` retrospective entry above summarizes what shipped during M1–M4 milestones; further pre-1.0 work lands under `[Unreleased]` until the public flip.

`v1.0.0` was cut at the public-visibility flip (2026-05-01). From `v1.0.0` onward this project follows strict [Semantic Versioning](https://semver.org/spec/v2.0.0.html): `MAJOR.MINOR.PATCH` where MAJOR is incremented for breaking forker-facing changes (renamed `bin/` scripts, removed Make targets, restructured README sections that forkers cite), MINOR for new forker-facing features (new scripts, new sections), and PATCH for fixes that don't change the forker contract.

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
