import XCTest

/// Smoke test of the home screen using sample data (the simulator has no Health data).
final class GradaUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHomeScreenAndCustomize() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-SampleData"]
        app.launch()

        // First launch on this simulator asks for starting goals.
        if app.navigationBars["Choose your goals"].waitForExistence(timeout: 5) {
            attachScreenshot("Goal setup")
            app.staticTexts["Balanced"].tap()
        }

        XCTAssertTrue(app.staticTexts["Health status"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["All in range"].waitForExistence(timeout: 5))
        attachScreenshot("Home top")

        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Last 30 days"].waitForExistence(timeout: 5))
        attachScreenshot("Home bottom")

        app.navigationBars.buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Customize"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Pinned"].exists)
        attachScreenshot("Customize")
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
