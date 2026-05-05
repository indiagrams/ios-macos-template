// app/Project.swift — Tuist 4 manifest for the HelloApp template stub.
//
// 1:1 equivalent of app/project.yml. Both ship on `main`; bin/rename.sh's
// `--generator=tuist|xcodegen` flag (see #38) selects which one a fresh
// fork keeps post-rename. CI runs both via .github/workflows/pr.yml's
// 6-job matrix so any drift between the two manifests fails fast.
//
// When editing this file, also update app/project.yml (and vice versa).
// The CI matrix is the source of truth — both must produce a
// build-green HelloApp.xcodeproj.

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
