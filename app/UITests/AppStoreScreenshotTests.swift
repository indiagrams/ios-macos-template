import XCTest

// Drives App Store screenshot capture via fastlane snapshot.
// Add per-screen snapshot() calls as your app grows.
//
// Output: fastlane/screenshots/en-US/<device>-<NN>-<name>.png

final class AppStoreScreenshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launch()
    }

    func testCaptureGoldenPath() {
        let app = XCUIApplication()
        // Wait for the home title to render.
        XCTAssertTrue(app.staticTexts["HelloApp"].waitForExistence(timeout: 10))
        snapshot("01-home")

        // Add more screens here as the app grows. Each snapshot() call writes
        // one PNG named <device>-NN-<name>.png into fastlane/screenshots/en-US/.
    }
}
