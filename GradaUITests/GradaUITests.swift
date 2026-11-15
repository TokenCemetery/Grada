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
        app.navigationBars.buttons["Done"].tap()

        app.tabBars.buttons["Journal"].tap()
        XCTAssertTrue(app.navigationBars["Journal"].waitForExistence(timeout: 5))
        let alcohol = app.buttons["Alcohol"]
        XCTAssertTrue(alcohol.waitForExistence(timeout: 5))
        // Marking shows the amount stepper; tapping again unmarks, leaving the simulator's journal as it was.
        let wasMarked = alcohol.isSelected
        alcohol.tap()
        if !wasMarked {
            XCTAssertTrue(app.staticTexts["1 drink"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Saved · 1 tag logged"].waitForExistence(timeout: 5))
            attachScreenshot("Journal")
            alcohol.tap()
        }
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
