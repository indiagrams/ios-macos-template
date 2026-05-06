# Continuous Validation via a Downstream Smoketest

The signing pipeline in this template (`fastlane release` lane,
`ci/local-release-check.sh`, `.github/workflows/release.yml`) is exercised
**weekly** by a public reference fork:

> [`indiagrams/ios-macos-smoketest`](https://github.com/indiagrams/ios-macos-smoketest)

Every Monday 09:00 UTC the smoketest runs `fastlane release` end-to-end on a
fresh `macos-15` GitHub Actions runner, signs an iOS `.ipa` + macOS `.pkg`,
and uploads both to TestFlight. A red run there means the pipeline has broken
somewhere between fastlane, match, Apple's signing infrastructure, the ASC
API, and the macos-15 image — usually before any active fork hits the same
breakage in their own release window.

## Why a separate fork instead of CI on the template itself

CI on the template repo only exercises **build** — not signing, not upload,
not TestFlight ingestion. That's deliberate: the template ships without an
ASC API key, without a certs repo, without TestFlight access. A real release
pipeline needs all three. The smoketest provides them in a public,
inspectable form so:

- Forkers can read its `release.yml` actions tab to see real green runs (and
  the gotchas in failed runs).
- Patterns + fixes are discovered against a real Apple ecosystem, not a
  mocked one.
- The template's release.yml is provably executable — it's the same file
  shape the smoketest runs against.

## What's been validated end-to-end

The smoketest's phase 4 work (April-May 2026) discovered and fixed seven
distinct CI failure modes between "looks like it should work" and
"actually pushes a build to TestFlight":

| # | Failure mode | Fix landed in |
|---|---|---|
| G1 | Mac Installer Distribution cert not present (separate cert type from Apple Distribution; fastlane match's `cert` action mis-routes to DISTRIBUTION limit bucket) | `bin/mint-installer-cert.rb` + `bin/import-installer-to-match.rb` |
| G2 | `setup-ruby@v1` requires explicit `ruby-version` when no `.ruby-version` file is in tree | `release.yml` pins `ruby-version: '3.3'` |
| G3 | xcodebuild "No Accounts: Add a new account in Accounts settings" — `automatic` signing path tries to log into Apple ID | `ci/local-release-check.sh` passes `-authenticationKeyPath` + `-authenticationKeyID` + `-authenticationKeyIssuerID` to xcodebuild for API-key auth |
| G4 | fastlane match `Could not install WWDR certificate` after a 5-minute hang on macos-15 (known issue: [fastlane/fastlane#20960](https://github.com/fastlane/fastlane/issues/20960)) | `release.yml` pre-installs `AppleWWDRCAG6.cer` into the system keychain via curl + `security add-trusted-cert` |
| G5 | xcodebuild asset compilation fails with "No simulator runtime version available to use with iphonesimulator SDK version 22A3362" — `Xcode_16.app` = Xcode 16.0 with iOS 18.0 SDK but no matching iOS Simulator runtime on the runner | `release.yml` uses runner default Xcode (16.4) instead of pinning Xcode_16.app |
| G6 | exportArchive `Cloud signing permission error` + `No profiles for com.example.helloapp were found` — `signingStyle=automatic` ExportOptions plist triggers Apple's cloud-signing endpoint which can't auth with API key only | `ci/local-release-check.sh` patches ExportOptions plist to `signingStyle=manual` + `provisioningProfiles` dict using match's emitted profile names; `release` lane in Fastfile threads `RELEASE_IOS_PROFILE_NAME` / `RELEASE_MACOS_PROFILE_NAME` env vars to the script |
| G7 | codesign + productbuild fail with `The timestamp service is not available.` (transient `timestamp.apple.com` blip) | `ci/local-release-check.sh` adds `with_timestamp_retry` helper — wraps codesign / productbuild calls, retries up to 5 times with linear backoff (5/10/15/20s) on the specific timestamp-service-unavailable error |

The smoketest also surfaced two ecosystem-level constraints:

- **Apple does not expose `POST /apps`** in the public ASC API — fastlane
  `produce` falls back to Apple ID + 2FA login for app creation. We
  deliberately don't carry those secrets in CI; the
  `bootstrap_asc` lane in `fastlane/Fastfile` verifies-or-fails-loudly with
  one-time-setup instructions for creating the App via web UI.
- **Apple's iOS Distribution cert limit is 3/team**, not 2 as some docs
  suggest. The `revoke_cert` lane in `fastlane/Fastfile` (Spaceship-based)
  helps free a slot when match hits the limit.

## How to run the smoketest pattern in your own fork

See [README → Setting up signing + ASC → Optional: enable CI signing via fastlane match](../README.md#optional-enable-ci-signing-via-fastlane-match)
for the 8-step bootstrap. Once configured, the same `release.yml` runs
weekly against your fork.

## Relationship to `docs/SMOKE-TEST.md`

`docs/SMOKE-TEST.md` describes a **disposable, manual smoke test** — create
an ephemeral fork, run the Quickstart, verify, delete — done before each
template release. It validates the **fork-time UX** (clone → rename → build).

This document describes a **persistent, continuous smoke test** — a public
fork that exercises the **release pipeline** weekly. The two are
complementary; both gate template releases at different layers.
