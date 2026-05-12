# Screenshots

This document captures **screenshot-engineering practices** that go beyond what the template ships with — patterns every shipping fork should adopt as the app grows. The template gives you the canonical scaffolding for one screen × one language × two appearances; the practices below are what scales that to N screens × M languages × 2 appearances without flakiness.

## What the template ships

| Piece | Where | Why |
|---|---|---|
| `AppStoreScreenshotTests.swift` with `testLightMode` + `testDarkMode` | `app/UITests/` | Per-appearance test functions so fastlane sets simulator appearance **before** the app launches (no relaunch). Independently parallelizable, independently re-runnable, independent failure isolation. |
| `AccessibilityIdentifiers.swift` | `app/Shared/` (compiled into both main app + UITests targets) | Single source of truth for selectors. Views attach via `.accessibilityIdentifier(AccessibilityIdentifiers.<name>)`; tests query via `app.staticTexts[AccessibilityIdentifiers.<name>]`. Locale-proof and refactor-safe. |
| `XCUIDevice.shared.orientation = .portrait` in `setUpWithError()` | `AppStoreScreenshotTests.swift` | Forces portrait every run. Simulator orientation persists across runs; App Store Connect requires specific portrait pixel dimensions and rejects mis-rotated uploads. |
| `override_status_bar(true)` | `fastlane/Snapfile` | Pins simulator status bar to 9:41 / full battery / full wifi for clean App Store screenshots. Apple convention. |
| Quarantine-tolerant runner launch | `ci/take-screenshots.sh` | macOS UI test runner can carry `com.apple.quarantine` (xcodes-cli / `.xip`-installed Xcode propagates it). The script splits `xcodebuild test` into `build-for-testing` → xattr-strip + ad-hoc codesign → `test-without-building`. Transparent to users. |

Running `make screenshots` captures the matrix into `fastlane/screenshots/en-US/*.png` (PNG names embed the device + test function so light and dark live side-by-side):

```
fastlane/screenshots/en-US/
├── iPhone 16 Plus-01-home-light.png
├── iPhone 16 Plus-01-home-dark.png
├── iPad Pro (12.9-inch) (6th generation)-01-home-light.png
├── iPad Pro (12.9-inch) (6th generation)-01-home-dark.png
└── macos-01-home.png   ← captured via XCTAttachment + extract-mac-screenshots.sh
```

## Practices forks should adopt

### 1. Mock data based on real API responses

Live servers in UI tests are the #1 cause of flaky screenshot pipelines. Network timeouts, server errors, rate limiting, non-deterministic data, slow latency multiplied by devices × languages — every one of these breaks captures unpredictably.

**Inject stub services when running in UI test mode.** The app gets data from a "service" that happens to return hardcoded values; it never knows the difference:

```swift
// app/Testing/StubWeatherService.swift  (only compiled in test mode)

struct StubWeatherService: WeatherService {
    func currentWeather() async -> CurrentWeather {
        CurrentWeather(
            temperature: 27.0,
            humidity: 30,
            pressure: 1006.0,
            // ... deterministic values that look good in screenshots
        )
    }
}
```

**Base mocks on real data.** Don't invent values from scratch — they often look fake. Fetch a real API response once, save it as reference, then model your stubs after it. Your screenshots look authentic because the data **is** authentic, just frozen in time.

Wire-up: at app launch, detect a `-UITest` launch argument and swap the real service for the stub. The article at [buczel.com/blog/fastlane-screenshots-ios](https://buczel.com/blog/fastlane-screenshots-ios/) shows a full pattern with dependency injection.

### 2. Skip splash screens in UI test mode

Splash animations cost seconds × number of test runs × devices × languages × appearances. Detect UI test mode and skip:

```swift
// app/Views/SplashView.swift

struct SplashView: View {
    @State private var showContent = isUITestMode

    var body: some View {
        if showContent {
            ContentView()
        } else {
            splashAnimation
                .onAppear { /* normal splash timing */ }
        }
    }
}

private var isUITestMode: Bool {
    CommandLine.arguments.contains("-UITest")
}
```

Pass `-UITest` from your test:

```swift
override func setUpWithError() throws {
    app = XCUIApplication()
    app.launchArguments.append("-UITest")
    setupSnapshot(app)
}
```

### 3. Test one configuration first; verify by listing files

Before running the full matrix (2 devices × N languages × 2 appearances), verify everything works with one appearance and one language but **all devices**. Add a lightweight fastlane lane temporarily:

```ruby
desc "Test dark mode screenshots (en-US only, all devices)"
lane :screenshots_dark_test do
  capture_screenshots(
    only_testing: ["<APP_NAME>UITests/AppStoreScreenshotTests/testDarkMode"],
    languages: ["en-US"]  # Single language, all devices from Snapfile
  )
end
```

Then **check folder contents** rather than parsing test output:

```bash
ls -la fastlane/screenshots/en-US/

# Expected: ALL devices × ALL screenshots
# iPhone 16 Plus-01-home-dark.png
# iPad Pro (12.9-inch) (6th generation)-01-home-dark.png
```

If any expected file is missing, something broke. Fix it before running the full matrix.

### 4. Add identifiers to elements XCUITest can query

`.accessibilityIdentifier()` on a SwiftUI **container** (VStack, HStack, ZStack) doesn't surface independently — the container has no inherent accessibility role, so XCUITest's element queries skip it. Attach identifiers to the **discoverable** elements inside:

| SwiftUI element | XCUITest query category |
|---|---|
| `Text(...)` | `app.staticTexts[id]` |
| `Button(...)` | `app.buttons[id]` |
| `Image(...)` (with `.accessibilityLabel`) | `app.images[id]` |
| `TextField(...)` | `app.textFields[id]` |
| `Toggle(...)` | `app.switches[id]` |
| Tab views | `app.tabBars.buttons[id]` (iPhone) / `app.toolbars.buttons[id]` (iPad iOS 26+) |

`AccessibilityIdentifiers.swift` is the single source of truth — define a constant per identifier, attach it to the view, query it from the test. No localized-text matching, no string drift.

### 5. iOS 26 TabView quirk (forks with tab navigation)

On iOS 26 with Liquid Glass, TabView renders differently across devices:

- **iPad**: tabs render as toolbar buttons with working `.accessibilityIdentifier()`
- **iPhone**: tabs render as traditional tab bars where identifiers don't apply (you have to query by index)

The article at [buczel.com/blog/ios26-tabview-uitest-identifiers](https://buczel.com/blog/ios26-tabview-uitest-identifiers) walks through the workaround. The template doesn't use TabView, so this hasn't bitten anyone yet — but it will the moment a fork adds tab navigation.

## Upload caveats

`make screenshots` writes to `fastlane/screenshots/en-US/`. To upload:

```bash
ci/take-screenshots.sh --upload   # rerun + upload in one shot
# or:
bundle exec fastlane ios upload_screenshots
bundle exec fastlane mac upload_screenshots
```

Both upload lanes have `overwrite_screenshots: true` so prior screenshots in the same ASC slot get replaced. App Store Connect's **10-screenshot-per-device-class** limit applies: at 2 captures (light + dark) per screen, you have 5 screens of headroom per device class per language before hitting the cap.

If you see `Too many screenshots found for device APP_*` from precheck, it's ASC's slot count from previous runs. Either clear in the ASC web UI or trust `overwrite_screenshots: true` to displace them (which it does, despite the warning).

## Fastlane version

Modern device sizes (iPhone 17 Pro Max 1320×2868, iPad Pro 13" M5 2064×2752) require **fastlane ≥ 2.230.0**. The template's `Gemfile.lock` pins to a current version; `bundle update fastlane` if you ever see "invalid screen size" rejections from `deliver`.

## See also

- [`Snapfile`](../fastlane/Snapfile) — iOS device list + language list
- [`MacSnapfile`](../fastlane/MacSnapfile) — macOS scheme config
- [`AppStoreScreenshotTests.swift`](../app/UITests/AppStoreScreenshotTests.swift) — iOS test
- [`AccessibilityIdentifiers.swift`](../app/Shared/AccessibilityIdentifiers.swift) — selector definitions
- [`ci/take-screenshots.sh`](../ci/take-screenshots.sh) — driver script (handles quarantine + macOS path)
- [buczel.com/blog/fastlane-screenshots-ios](https://buczel.com/blog/fastlane-screenshots-ios/) — the article these patterns come from
