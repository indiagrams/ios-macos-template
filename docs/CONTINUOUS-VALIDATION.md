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

The smoketest's phase 4-7 work (April-May 2026) discovered and fixed fourteen
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
| G8 | altool upload rejects with `Validation failed (409) SDK version issue. This app was built with the iOS 18.5 SDK. All iOS and iPadOS apps must be built with the iOS 26 SDK or later, included in Xcode 26 or later`. Apple began enforcing iOS 26 SDK minimum for ASC uploads in 2026; macos-15 runner default is Xcode 16.4 (iOS 18.5 SDK) — too old | `release.yml` picks the highest-numbered `/Applications/Xcode_26*.app` on the runner and `xcode-select`s it; fail-loud listing of available Xcodes if no 26+ family is installed |
| G9 | macOS exportArchive errors `No signing certificate "Mac Installer Distribution" found`. The `.app` inside an MAS `.pkg` is signed with Apple Distribution; the `.pkg` wrapper itself needs a separate cert (Apple's "3rd Party Mac Developer Installer"). `fastlane match`'s `cert` action mis-routes `mac_installer_distribution` requests to the DISTRIBUTION limit bucket and reports phantom limits | Mint via Spaceship API directly (`bin/mint-installer-cert.rb`); push to certs repo via `Match::Importer.import_cert` (`bin/import-installer-to-match.rb`); add a 3rd `match mac_installer_distribution --readonly` call in the release lane; `plutil`-patch `installerSigningCertificate = '3rd Party Mac Developer Installer'` into the macOS ExportOptions plist |
| G10 | iOS UI tests fail to compile with `Call to main actor-isolated global function 'setupSnapshot(...)' in a synchronous nonisolated context`. Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`) + SnapshotHelper's `@MainActor` declarations + non-isolated test setUp/test methods. Latent in this template too — `pr.yml` runs `xcodebuild build`, not `test`, so the bug never surfaced through the main pipeline | Annotate the test class `@MainActor` (same pattern already used in `app/MacOSUITests/AppStoreScreenshotTests.swift`) |
| G11 | `app_store_connect_api_key` action raises `OpenSSL::PKey::ECError: invalid curve name` from `Spaceship::ConnectAPI::Token.create` when invoked through fastlane's lane manager on macos-15 + Ruby 3.3.11 + OpenSSL 3.6.x — even though the same `Token.create` call with identical args succeeds when invoked directly via `bundle exec ruby`. Hits both `key_content` + `is_key_content_base64: true` paths. Possibly a regression in fastlane 2.233.x's `gsub('\n', "\n")` + lane-context handling | Decode the .p8 to a tmpfile inside the `asc_api_key` helper, then call the action with `key_filepath:` instead of `key_content:` + `is_key_content_base64`. The file path code path bypasses the buggy gsub-then-base64-decode branch |
| G12 | `MATCH_GIT_BASIC_AUTHORIZATION` 404s on the certs repo after delete + recreate. Fine-grained GitHub PATs are pinned to a *repo's database ID*, not its name — when the certs repo is deleted and a new one with identical name is created, the new repo has a fresh ID and the existing PAT loses access. `fastlane match` then dies at the first clone with "Error cloning certificates git repo". This blocks the template's E2E refork test from running unattended (every cycle would require manual PAT scope updates via `github.com/settings/tokens`). | Don't delete the certs repo as part of the E2E loop. Reset its branches via force-push instead — the certs repo's lifecycle is logically separate from the app fork's. `bin/refork-smoketest.sh` does this by default. The repo's database ID is preserved, so the existing fine-grained PAT (correctly scoped to "Only select repositories" → certs repo) stays valid across E2E cycles. |
| G13 | xcodebuild archive fails with `Signing certificate is invalid. Signing certificate "Apple Distribution: <name>", serial number "...", is not valid for code signing. It may have been revoked or expired.` Even though `security find-identity -v` shows the cert as valid (it's not expired, has a private key). Cause: the cert is revoked at Apple's side but still locally cached. `find-identity -v` only filters expired certs, not revoked-at-Apple ones. xcodebuild's `CODE_SIGN_IDENTITY=Apple Distribution` substring-matches multiple certs; if any matching cert is revoked, the archive can fail when xcodebuild picks that one. | New `make clean-revoked-certs` target — queries ASC API for valid cert serials, diffs against local keychain certs, deletes the revoked locals after confirmation. Surgical user-state cleanup; doesn't touch the template's normal build path. Run once when you hit this; subsequent builds use only Apple-valid certs. (`bundle exec fastlane clean_revoked_certs dry_run:true` to preview.) |
| G14 | The local-mode shipping path (RELEASE_MODE=local) was 0% covered by automation through v1.4 — only validated via manual cold-fork tests at release time. Regressions in `setup_ci` mode-gating, `match`-skip gating, sigh-based App Store profile minting, β cert SHA-1 pinning (extracting `DeveloperCertificates[0]` from the .mobileprovision), ExportOptions plist patching for manual signing, and bash-3.2 `${arr[@]}`-under-`set -u` array safety would surface only when a forker tried to ship — typically weeks after the regressing commit landed. | New `.github/workflows/canary-local-mode.yml` — weekly mint→ship→verify→revoke loop in the same Apple team. Mints 3 throwaway certs (`apple_distribution` + `apple_development` + `mac_installer_distribution`), runs full local-mode `fastlane release` against TestFlight, revokes the 3 just-minted certs (`if: always()`). Net team-cert delta per run = 0; user's existing shipping certs untouched. Cache-tracked orphan recovery (`actions/cache@v5`) handles partial-failure scenarios — next run's pre-step revokes any ids the prior run's post-step missed. New `revoke_certs` (plural, idempotent) and `mint_canary_certs` (capture-ids) lanes in `fastlane/Fastfile` are the building blocks. |

The smoketest also surfaced two ecosystem-level constraints:

- **Apple does not expose `POST /apps`** in the public ASC API — fastlane
  `produce` falls back to Apple ID + 2FA login for app creation. We
  deliberately don't carry those secrets in CI; the
  `bootstrap_asc` lane in `fastlane/Fastfile` verifies-or-fails-loudly with
  one-time-setup instructions for creating the App via web UI.
- **Apple's per-team certificate caps** (verified empirically 2026-05-08
  against team `A26TJZ8QHQ`; community docs are stale or contradictory):
  `DISTRIBUTION` (Apple Distribution) cap = **3** / team;
  `DEVELOPMENT` (Apple Development) cap **≥ 5** / team;
  `MAC_INSTALLER_DISTRIBUTION` cap = **2** / team. At-cap mint without
  `--force` returns HTTP 409 — non-destructive; with `--force` revokes the
  oldest cert by creation date (could be your production cert — `fastlane
  cert` defaults to no `--force`, which is the safe default). The
  `revoke_cert` lane (singular, ad-hoc) and `revoke_certs` lane (plural,
  idempotent batch) in `fastlane/Fastfile` help free a slot or clean up
  canary cycles.

## How to run the smoketest pattern in your own fork

See [README → Setting up signing + ASC → Optional: enable CI signing via fastlane match](../README.md#optional-enable-ci-signing-via-fastlane-match)
for the 8-step bootstrap. Once configured, the same `release.yml` runs
weekly against your fork.
