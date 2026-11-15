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

        XCTAssertTrue(app.staticTexts["Health Status"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["All in range"].waitForExistence(timeout: 5))
        attachScreenshot("Home top")

        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Workouts Calendar"].waitForExistence(timeout: 5))
        attachScreenshot("Home bottom")

        app.navigationBars.buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Customize"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Pinned"].exists)
        attachScreenshot("Customize")
        app.navigationBars.buttons["Done"].tap()

        app.tabBars.buttons["Journal"].tap()
        XCTAssertTrue(app.navigationBars["Journal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Today"].exists)
        let alcohol = app.buttons["Alcohol"]
        XCTAssertTrue(alcohol.waitForExistence(timeout: 5))
        // Marking shows the amount stepper; tapping again unmarks, leaving the simulator's journal as it was.
        let wasMarked = alcohol.isSelected
        alcohol.tap()
        if !wasMarked {
            XCTAssertTrue(app.staticTexts["1 drink"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.images["Saved"].waitForExistence(timeout: 5))
            attachScreenshot("Journal")
            alcohol.tap()
        }

        app.buttons["Previous day"].tap()
        XCTAssertFalse(app.buttons["Today"].exists)
        attachScreenshot("Journal yesterday")
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
