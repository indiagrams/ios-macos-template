# Migrating from XcodeGen to Tuist

A step-by-step recipe for forking this template and switching its project
generator from [XcodeGen](https://github.com/yonaskolb/XcodeGen) to
[Tuist](https://tuist.dev). One-way migration: applies once on your
fork, no parallel maintenance.

> **Status:** documentation only. The template's default project
> generator remains XcodeGen (`app/project.yml` → `xcodegen generate`
> → `app/HelloApp.xcodeproj`). This doc shows what to change in your
> fork if you'd rather drive the project file from `Project.swift`
> instead. Tracked in [#34](https://github.com/indiagrams/ios-macos-template/issues/34).
>
> The migration described here was **validated end-to-end against this
> repo at v1.0.0** — a throwaway clone, the steps below applied
> verbatim, and `make check` / `make check-sim` / `make check-macos` all
> green. Where Tuist behaves differently from XcodeGen in non-obvious
> ways, those gotchas are flagged inline.

## Why this exists

Two-of-two r/iOSProgramming commenters on the v1.0.0 launch post
independently mentioned a Tuist preference. Real audience signal worth
acting on. The trade-off is genuine and depends on team preference:

| Aspect | XcodeGen (current) | Tuist |
|---|---|---|
| Manifest format | YAML (`project.yml`) | Swift (`Project.swift`) |
| Toolchain footprint | Single ~10 MB Go binary | ~120 MB binary; richer feature set |
| Type-safety on the manifest | Schema-validated at generate time | Compiler-enforced |
| Caching | None | Built-in incremental cache (`tuist generate`) |
| Build-graph features | None — just generates an .xcodeproj | `tuist run`, `tuist test`, `tuist cache warm` |
| Module/dependency graph awareness | None | First-class — supports modular apps cleanly |
| Distribution | Homebrew core | Homebrew Cask / mise |
| Best for | Single-app projects; minimal-deps teams | Modular monorepos; teams that want a build-graph tool |

Neither is wrong. Pick whichever your team prefers. The template
defaults to XcodeGen because it imposes the lowest cognitive load on a
first-time forker; this doc is for forkers who'd rather migrate.

## What this doc covers

- 1:1 translation of `app/project.yml` → `app/Project.swift` plus
  top-level `Tuist.swift`
- Updates to: `Makefile`, `Brewfile`, `ci/local-check.sh`,
  `ci/local-release-check.sh`, `.github/workflows/pr.yml`, `.gitignore`,
  `bin/rename.sh`, `bin/verify-rename.sh`
- Caveats / gotchas surfaced during validation

## What this doc does not cover

- **Maintaining both XcodeGen and Tuist in lockstep.** Choose one. The
  doc's value is a clean cutover; the maintenance cost of keeping both
  manifest formats in sync isn't worth what it'd save.
- **Adopting Tuist's caching / build-graph features
  (`tuist cache warm`, `tuist run`, project-as-package).** Those are
  Tuist's actual differentiators — but they're independent of the
  XcodeGen-replacement story this doc covers. Once you've migrated, the
  Tuist docs at <https://docs.tuist.dev> are the right next read.
- **Workspaces with multiple projects.** This template has one project.
  If you're modularizing into multiple projects, see Tuist's
  [workspace guide](https://docs.tuist.dev/en/guides/develop/projects/structure)
  separately.

## Prerequisites

Tuist is **not on Homebrew core** — it ships via Homebrew Cask or
[mise](https://mise.jdx.dev/). Pick one:

```bash
# Option A — Homebrew Cask (simplest; matches the template's existing Brewfile pattern)
brew install --cask tuist

# Option B — mise (recommended by Tuist for teams who want a pinned version per project)
curl https://mise.run | sh
echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshrc
source ~/.zshrc
mise use -g tuist@latest
```

Verify:

```bash
tuist version    # NB: `tuist version` (no dashes), not `tuist --version` — Tuist 4 quirk
```

The migration was validated against Tuist **4.191.x**. Older versions
(pre-4.0) used a different `Project.swift` schema and the steps below
will not apply.

## Step 1 — Add `Tuist.swift` at repo root

Create `Tuist.swift` (one file, ~12 lines):

```swift
// Tuist.swift — top-level Tuist configuration.
import ProjectDescription

let config = Config(
    compatibleXcodeVersions: .all,    // .upToNextMajor("15.0") rejects Xcode 16+; use .all unless you want a hard pin
    swiftVersion: "5.9",
    generationOptions: .options(
        resolveDependenciesWithSystemScm: false,
        disablePackageVersionLocking: false
    )
)
```

> **Gotcha — old location.** Tuist <4.0 used `Tuist/Config.swift` (a
> subdirectory). Tuist 4 emits a deprecation warning for that path and
> wants `Tuist.swift` at the repo root. Use the new location.

## Step 2 — Replace `app/project.yml` with `app/Project.swift`

Delete `app/project.yml`. Add `app/Project.swift` (one file, ~210
lines, full skeleton in [§ Reference Project.swift](#reference-projectswift)
below):

```bash
rm app/project.yml
# write app/Project.swift — see reference at the bottom
```

Key translation points from `project.yml` → `Project.swift`:

| project.yml | Project.swift |
|---|---|
| `options.bundleIdPrefix: com.example` | Set per-target `bundleId:` (Tuist has no project-wide prefix concept) |
| `options.deploymentTarget.iOS: "17.0"` | `Target.target(deploymentTargets: .iOS("17.0"))` |
| `options.developmentLanguage: en` | `Project.options(developmentRegion: "en", defaultKnownRegions: ["en"])` |
| `options.defaultConfig: Release` | `Scheme.archiveAction(configuration: .release)` per scheme |
| `settings.base.SWIFT_VERSION: 5.9` | `Project(settings: .settings(base: ["SWIFT_VERSION": "5.9", ...]))` |
| target `info.path` + `info.properties` | `Target.target(infoPlist: .extendingDefault(with: [...]))` — auto-generates the .plist |
| target `sources: [path: ...]` | `Target.target(sources: ["Shared/**", "iOS/**"])` |
| `excludes: ["Resources"]` | `.glob("macOS/**", excluding: ["macOS/Resources/**"])` |
| `info.properties.CFBundleDisplayName: HelloApp` | `infoPlist: .extendingDefault(with: ["CFBundleDisplayName": "HelloApp", ...])` |
| `CODE_SIGN_ENTITLEMENTS: iOS/HelloApp.entitlements` | `entitlements: .file(path: "iOS/HelloApp.entitlements")` |
| target-level `settings.base` | `Target.target(settings: .settings(base: [...]))` (overrides project-level) |
| `dependencies: [target: HelloApp-iOS]` | `dependencies: [.target(name: "HelloApp-iOS")]` |
| `postCompileScripts:` | `scripts: [TargetScript.post(...)]` (see gotcha below) |
| `schemes.<name>.build.targets` | `Scheme.scheme(buildAction: .buildAction(targets: [...]))` |

> **Gotcha — UI test targets must NOT be in `buildAction.targets`.** In
> XcodeGen, `HelloAppUITests: [test]` declares the target builds for
> the test action only. The Tuist equivalent is **omitting** the UI
> test target from `BuildAction.targets` (only include the main app
> target there) and including it in `TestAction.targets`. If you put
> the UI test target in both, `xcodebuild build -scheme HelloApp-iOS`
> will compile the UI tests under iOS device's strict-concurrency
> setting and fail on `SnapshotHelper.swift`'s actor-isolation
> warnings — the very thing the per-target
> `SWIFT_STRICT_CONCURRENCY: minimal` override is supposed to prevent.
> Empirically validated.

> **Gotcha — `TargetScript.post` argument order.** Swift's compiler
> requires `name:` before `inputPaths:` / `outputPaths:` even though
> the Tuist docs sometimes show them after. Use:
> ```swift
> TargetScript.post(
>     script: "...",
>     name: "Overwrite actool's broken AppIcon.icns ...",   // before inputPaths/outputPaths
>     inputPaths: [...],
>     outputPaths: [...]
> )
> ```

> **Gotcha — post-build script placement differs from XcodeGen.**
> XcodeGen's `postCompileScripts` puts the Run Script phase *between*
> Sources and Resources. Tuist's `TargetScript.post(...)` puts it at
> the *end* of the buildPhases list (after Resources, Frameworks,
> Embed Frameworks) but *before* Code Sign. Both placements run before
> Code Sign, so the icon overwrite remains effective. Verify
> empirically: after a clean build, `shasum` the `.icns` in the built
> .app's `Contents/Resources/` against `app/macOS/Resources/AppIcon.icns`
> — they must match.

## Step 3 — Update ancillary scripts

The following files all reference `xcodegen generate`. Update them in
one pass:

### `Brewfile`

```diff
-brew "xcodegen"        # app/project.yml → HelloApp.xcodeproj
+cask "tuist"           # app/Project.swift → HelloApp.xcodeproj
```

(If you went the mise route in Step 0, add a `mise.toml` instead and
drop the Brewfile line entirely.)

### `Makefile`

```diff
 bootstrap:
 	brew bundle
 	lefthook install
-	cd app && xcodegen generate
+	cd app && tuist generate --no-open
 	bundle install
…
 generate:
-	cd app && xcodegen generate
+	cd app && tuist generate --no-open
```

### `ci/local-check.sh`

```diff
 ensure_xcodeproj() {
   require_cmd xcodebuild
-  require_cmd xcodegen
-  step "app: xcodegen generate"
-  ( cd app && xcodegen generate >/dev/null )
+  require_cmd tuist
+  step "app: tuist generate"
+  ( cd app && tuist generate --no-open >/dev/null )
 }
```

### `ci/local-release-check.sh`

```diff
-step "xcodegen generate"
-( cd app && xcodegen generate >/dev/null )
+step "tuist generate"
+( cd app && tuist generate --no-open >/dev/null )
```

### `.github/workflows/pr.yml`

All three jobs (`app-ios-device`, `app-ios-sim`, `app-macos`) repeat
the same install + generate steps. Replace each:

```diff
-      - name: install xcbeautify + xcodegen
-        run: brew install xcbeautify xcodegen
+      - name: install xcbeautify
+        run: brew install xcbeautify
+
+      - name: install tuist
+        run: brew install --cask tuist

-      - name: regenerate Xcode project
+      - name: regenerate Xcode project (Tuist)
         working-directory: app
-        run: xcodegen generate
+        run: tuist generate --no-open
```

> **Optional:** if you want to cache the Tuist binary across CI runs to
> shave the `brew install` minute, swap to
> [`actions/cache`](https://github.com/actions/cache) on
> `~/.cache/tuist` plus mise, or use the community
> [`tuist/setup-tuist`](https://github.com/tuist/setup-tuist) action.
> Not necessary at this template's size; flagged for completeness.

### `.gitignore`

Tuist generates a `Derived/` cache directory inside `app/` and an
`.xcworkspace` alongside the `.xcodeproj`. Add them:

```diff
 # XcodeGen-generated project (regenerated from project.yml)
+# Tuist-generated project (regenerated from app/Project.swift)
 app/HelloApp.xcodeproj
+app/HelloApp.xcworkspace
+app/Derived/
+.tuist/
```

(Keep the existing `app/HelloApp.xcodeproj` rule — Tuist still emits
the `.xcodeproj` for `xcodebuild` to consume.)

### `bin/rename.sh`

The rename script substitutes `HelloApp`, `com.example.helloapp`, and
the maintainer email across tracked files. After migration, those
strings now live in `app/Project.swift` (replacing `app/project.yml`).
The script's `git ls-files`-based grep already handles
this — no edit required *if* you ran the migration on a fresh fork
before any rename. **But:** if you migrate first, then rename, verify
with:

```bash
git grep "com.example.helloapp" app/Project.swift   # should show 4 hits before rename
bin/rename.sh YourApp com.your-org.yourapp 'Your App' --email=you@example.com
git grep "com.example.helloapp" app/Project.swift   # should be empty after rename
```

If `bin/rename.sh` misses any literal in `Project.swift` that it caught
in `project.yml` (sed pattern delimiter or escape edge case), file an
issue against your fork — the literal patterns in `bin/rename.sh:291`
are the source of truth and may need an update.

### `bin/verify-rename.sh`

Same logic — it greps tracked files for the four pre-rename literals.
Tuist puts those literals in `Project.swift`, which is tracked, which
the script already covers. No edit required.

## Step 4 — Validate end-to-end

The acceptance criterion for this migration (per
[issue #34](https://github.com/indiagrams/ios-macos-template/issues/34))
is "`make check` passing post-migration on a fresh fork." Run all
three signal paths:

```bash
# Sanity: the project regenerates cleanly
cd app && tuist generate --no-open && cd ..

# Three signal paths — all must be green
make check          # iOS device (primary)
make check-sim      # iOS Simulator (backup)
make check-macos    # macOS

# Confirm the macOS app got the hand-rolled .icns (not actool's broken 4-size)
shasum -a 256 \
  app/macOS/Resources/AppIcon.icns \
  ~/Library/Developer/Xcode/DerivedData/HelloApp-*/Build/Products/Debug/HelloApp_macOS.app/Contents/Resources/AppIcon.icns
# Both hashes must match.
```

If all three checks are green and the `shasum` lines match, the
migration is complete.

## Caveats

- **Tuist generates BOTH `HelloApp.xcodeproj` AND `HelloApp.xcworkspace`.**
  XcodeGen only generates the `.xcodeproj`. The existing build commands
  in `ci/local-check.sh` and `ci/local-release-check.sh` use
  `-project app/HelloApp.xcodeproj` — they keep working. If you ever
  open the project in Xcode, prefer the `.xcworkspace`.
- **Tuist version pinning.** Use `mise.toml` (mise) or commit a
  `.tuist-version`-style pin to ensure CI uses the same Tuist version
  as your local. The template's CI installs `--cask tuist` which
  always pulls latest; for stability across a long-lived fork, pin.
- **Product name suffix.** Tuist sanitizes `HelloApp-iOS` → `HelloApp_iOS`
  for `PRODUCT_NAME` and the .app bundle name. XcodeGen preserves the
  hyphen. If your release pipeline assumed `HelloApp-iOS.app`, you'll
  see `HelloApp_iOS.app`. The template's `fastlane/Fastfile` and
  `ci/local-release-check.sh` already write the final `.ipa` / `.pkg`
  with version-pattern names (`HelloApp-<version>.ipa`), which are
  derived independently of the bundle name — so the rename pipeline is
  unaffected.
- **`SWIFT_STRICT_CONCURRENCY: minimal` on the UI test target only.**
  This is the same override XcodeGen carries (per
  [`app/project.yml`](../app/project.yml) line 129). Tuist applies it
  identically when set as `Target.target(settings: .settings(base: [...]))`.
- **`compatibleXcodeVersions`.** Don't pin to a single major if you
  want forward compatibility — `.upToNextMajor("15.0")` rejects Xcode
  16+ at generate time. Use `.all` for a single-app template, or pin
  more strictly only if you have a CI-enforced reason.

## Verification (what "done" looks like)

After migrating on a fresh fork:

- [ ] `tuist generate --no-open` completes with no errors or warnings
      (deprecation warnings about old config locations should be gone).
- [ ] `make check` green.
- [ ] `make check-sim` green.
- [ ] `make check-macos` green.
- [ ] All three CI checks (`app (iOS device)`, `app (iOS Simulator)`,
      `app (macOS)`) green on the migration PR.
- [ ] The macOS app bundle's `.icns` matches `app/macOS/Resources/AppIcon.icns`
      by SHA-256 (post-build script ran correctly).
- [ ] `bin/rename.sh` followed by `bin/verify-rename.sh` exits 0 on a
      fresh test rename.
- [ ] Signed release flow: `fastlane release tag:v0.0.0 skip_upload:true skip_tag:true`
      produces signed `.ipa` + `.pkg` artifacts in `build/`. (Optional
      but recommended if you ship via fastlane.)

## Reference `Project.swift`

Drop this in at `app/Project.swift`. It's a 1:1 equivalent of
`app/project.yml` and was the exact file used to validate this
migration end-to-end.

```swift
import ProjectDescription

// MARK: - Shared settings

let baseSettings: SettingsDictionary = [
    "SWIFT_VERSION": "5.9",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "MARKETING_VERSION": "0.0.1",
    "CURRENT_PROJECT_VERSION": "1",
    "DEVELOPMENT_TEAM": "TEAM_ID_PLACEHOLDER",   // override via .env.local FASTLANE_TEAM_ID
    "CODE_SIGN_STYLE": "Automatic",
    "SWIFT_TREAT_WARNINGS_AS_ERRORS": "NO",
    "GCC_TREAT_WARNINGS_AS_ERRORS": "NO",
]

// MARK: - iOS app

let iosInfoPlist: [String: Plist.Value] = [
    "CFBundleDisplayName": "HelloApp",
    "CFBundleShortVersionString": "$(MARKETING_VERSION)",
    "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    "UILaunchScreen": .dictionary([:]),
    "UIApplicationSceneManifest": .dictionary([
        "UIApplicationSupportsMultipleScenes": false,
    ]),
    "UISupportedInterfaceOrientations": .array([
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ]),
    "UISupportedInterfaceOrientations~ipad": .array([
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationPortraitUpsideDown",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ]),
    "ITSAppUsesNonExemptEncryption": false,
]

let iosTarget = Target.target(
    name: "HelloApp-iOS",
    destinations: [.iPhone, .iPad],
    product: .app,
    bundleId: "com.example.helloapp",
    deploymentTargets: .iOS("17.0"),
    infoPlist: .extendingDefault(with: iosInfoPlist),
    sources: ["Shared/**", "iOS/**"],
    resources: [
        "iOS/Assets.xcassets",
    ],
    entitlements: .file(path: "iOS/HelloApp.entitlements"),
    settings: .settings(base: [
        "PRODUCT_BUNDLE_IDENTIFIER": "com.example.helloapp",
        "TARGETED_DEVICE_FAMILY": "1,2",
        "SUPPORTS_MACCATALYST": "NO",
        "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.utilities",
        "INFOPLIST_KEY_NSHumanReadableCopyright": "TODO Copyright © <year> <Your Org>. All rights reserved.",
    ])
)

// MARK: - macOS app

let macInfoPlist: [String: Plist.Value] = [
    "CFBundleDisplayName": "HelloApp",
    "CFBundleShortVersionString": "$(MARKETING_VERSION)",
    "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    "LSMinimumSystemVersion": "$(MACOSX_DEPLOYMENT_TARGET)",
    "LSApplicationCategoryType": "public.app-category.utilities",
    "NSHumanReadableCopyright": "TODO Copyright © <year> <Your Org>. All rights reserved.",
    "NSPrincipalClass": "NSApplication",
    // CFBundleIconName intentionally NOT set — its presence makes Sonoma+
    // prefer Assets.car AppIcon (which has actool's broken 4-size set).
    // The post-build script below installs the hand-rolled .icns instead.
    "CFBundleIconFile": "AppIcon",
    "ITSAppUsesNonExemptEncryption": false,
]

// Overwrites actool's broken 4-size .icns with the hand-rolled 10-size
// version. Tuist places `.post` scripts at the END of buildPhases (after
// Resources / Frameworks / Embed Frameworks) but before Code Sign — so
// the .icns gets overwritten *after* actool emits its broken version,
// and the signed bundle ships with the hand-rolled 10-size set.
let macIconScript: TargetScript = .post(
    script: """
    set -euo pipefail
    /bin/cp "$SCRIPT_INPUT_FILE_0" "$SCRIPT_OUTPUT_FILE_0"
    echo "Overwrote $SCRIPT_OUTPUT_FILE_0 with hand-rolled 10-size .icns"
    """,
    name: "Overwrite actool's broken AppIcon.icns with hand-rolled 10-size version",
    inputPaths: ["$(SRCROOT)/macOS/Resources/AppIcon.icns"],
    outputPaths: ["$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/AppIcon.icns"]
)

let macTarget = Target.target(
    name: "HelloApp-macOS",
    destinations: [.mac],
    product: .app,
    bundleId: "com.example.helloapp",
    deploymentTargets: .macOS("14.0"),
    infoPlist: .extendingDefault(with: macInfoPlist),
    sources: [
        "Shared/**",
        // macOS/Resources/ holds the hand-rolled AppIcon.icns + source 1024 PNG.
        // Excluded here because the post-build script copies the .icns into
        // the .app over actool's broken 4-size version.
        .glob("macOS/**", excluding: ["macOS/Resources/**"]),
    ],
    resources: [
        "macOS/Assets.xcassets",
    ],
    entitlements: .file(path: "macOS/HelloApp.entitlements"),
    scripts: [macIconScript],
    settings: .settings(base: [
        "PRODUCT_BUNDLE_IDENTIFIER": "com.example.helloapp",
        // Suppress actool's auto-injection of CFBundleIconName=AppIcon.
        // Empty value = actool emits Assets.car as before but does not set
        // the key, so macOS reads CFBundleIconFile → our hand-rolled .icns.
        "ASSETCATALOG_COMPILER_APPICON_NAME": "",
    ])
)

// MARK: - UI test targets

let iosUITestTarget = Target.target(
    name: "HelloAppUITests",
    destinations: [.iPhone, .iPad],
    product: .uiTests,
    bundleId: "com.example.helloapp.uitests",
    deploymentTargets: .iOS("17.0"),
    infoPlist: .default,
    sources: ["UITests/**"],
    dependencies: [.target(name: "HelloApp-iOS")],
    settings: .settings(base: [
        "TEST_TARGET_NAME": "HelloApp-iOS",
        // SnapshotHelper.swift uses raw NSURLConnection patterns that warn
        // under strict concurrency — relax for the test target only.
        "SWIFT_STRICT_CONCURRENCY": "minimal",
    ])
)

let macUITestTarget = Target.target(
    name: "HelloAppMacOSUITests",
    destinations: [.mac],
    product: .uiTests,
    bundleId: "com.example.helloapp.macuitests",
    deploymentTargets: .macOS("14.0"),
    infoPlist: .default,
    sources: ["MacOSUITests/**"],
    dependencies: [.target(name: "HelloApp-macOS")],
    settings: .settings(base: [
        "TEST_TARGET_NAME": "HelloApp-macOS",
    ])
)

// MARK: - Schemes

let iosScheme: Scheme = .scheme(
    name: "HelloApp-iOS",
    shared: true,
    // NB: only the main app target — UI tests live in testAction only.
    // Including HelloAppUITests here would compile it during plain
    // `xcodebuild build` and trip strict-concurrency errors that the
    // per-target SWIFT_STRICT_CONCURRENCY=minimal override can't suppress.
    buildAction: .buildAction(targets: ["HelloApp-iOS"]),
    testAction: .targets(
        ["HelloAppUITests"],
        configuration: .debug
    ),
    runAction: .runAction(configuration: .debug, executable: "HelloApp-iOS"),
    archiveAction: .archiveAction(configuration: .release)
)

let macScheme: Scheme = .scheme(
    name: "HelloApp-macOS",
    shared: true,
    buildAction: .buildAction(targets: ["HelloApp-macOS"]),
    testAction: .targets(
        ["HelloAppMacOSUITests"],
        configuration: .debug
    ),
    runAction: .runAction(configuration: .debug, executable: "HelloApp-macOS"),
    archiveAction: .archiveAction(configuration: .release)
)

// MARK: - Project

let project = Project(
    name: "HelloApp",
    options: .options(
        defaultKnownRegions: ["en"],
        developmentRegion: "en"
    ),
    settings: .settings(base: baseSettings, defaultSettings: .recommended),
    targets: [iosTarget, macTarget, iosUITestTarget, macUITestTarget],
    schemes: [iosScheme, macScheme]
)
```

## References

- [Tuist documentation](https://docs.tuist.dev)
- [`Project.swift` API reference](https://docs.tuist.dev/en/references/project-description/structs/project)
- [`Target.target(...)` API reference](https://docs.tuist.dev/en/references/project-description/structs/target)
- [Tuist 4 release notes](https://docs.tuist.dev/en/contributors/principles/changelog)
- [XcodeGen project.yml schema](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md) (for cross-reference during migration)
- This template — [`SCOPE.md`](../SCOPE.md), [`docs/PRINCIPLES.md`](PRINCIPLES.md), [`app/project.yml`](../app/project.yml) (the source you're migrating away from)
