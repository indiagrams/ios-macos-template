import XCTest

/// macOS App Store screenshot capture.
///
/// Run via: `ci/take-screenshots.sh --macos-only` (or `--upload` to push to ASC).
///
/// Each `attachScreenshot(...)` call attaches a PNG to the xcresult bundle.
/// `ci/extract-mac-screenshots.sh` extracts them into `fastlane/screenshots/en-US/`
/// where `fastlane mac upload_screenshots` (deliver) infers device type from
/// PNG dimensions.
///
/// fastlane snapshot is iOS-only — that's why this is a separate XCUITest path.
@MainActor
final class AppStoreScreenshotTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testScreenshot_01_Home() throws {
        app.launchArguments = ["UI_TESTING"]
        app.launch()
        // CRITICAL: activate() after launch() on macOS — without it the window
        // may launch behind others and XCUITest's window queries return nothing.
        app.activate()

        // Fall back to File → New Window if the headless runner loses the
        // initial window.
        if !app.windows.firstMatch.waitForExistence(timeout: 8) {
            let fileMenu = app.menuBarItems["File"]
            if fileMenu.waitForExistence(timeout: 3) {
                fileMenu.click()
                let newWindow = app.menuItems["New Window"]
                if newWindow.waitForExistence(timeout: 3) { newWindow.click() }
            }
        }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5),
                      "App window must be visible")

        // Let SwiftUI settle.
        Thread.sleep(forTimeInterval: 0.5)

        attachScreenshot(name: "macos-01-home")
    }

    /// Captures the foreground window and attaches it to the xcresult bundle.
    /// `app.windows.firstMatch.screenshot()` captures only the app's window —
    /// clean for App Store submission.
    private func attachScreenshot(name: String) {
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
