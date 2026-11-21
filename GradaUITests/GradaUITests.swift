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

        // First launch on this simulator asks for starting cards, then goals.
        if app.navigationBars["Choose your cards"].waitForExistence(timeout: 5) {
            attachScreenshot("Card setup")
            app.staticTexts["Health"].tap()
        }
        if app.navigationBars["Choose your goals"].waitForExistence(timeout: 5) {
            attachScreenshot("Goal setup")
            app.staticTexts["Balanced"].tap()
        }

        XCTAssertTrue(app.staticTexts["Health Status"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["All in range"].waitForExistence(timeout: 5))
        attachScreenshot("Home top")

        app.swipeUp()
        // The Last Workout card is titled by its sport, so look for its Duration stat.
        XCTAssertTrue(app.staticTexts["Duration"].waitForExistence(timeout: 5))
        attachScreenshot("Home bottom")

        app.navigationBars.buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Customize"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Pinned"].exists)
        attachScreenshot("Customize")
        app.navigationBars.buttons["Done"].tap()

        app.tabBars.buttons["Journal"].tap()
        XCTAssertTrue(app.navigationBars["Journal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Today"].exists)
        // The loaded reports push the tags below the fold, out of the lazy list, so wait for them and scroll (#185).
        let report = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sleep Score,")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 10))
        let alcohol = app.buttons["Alcohol"]
        for _ in 0..<5 where !alcohol.exists { app.swipeUp() }
        XCTAssertTrue(alcohol.waitForExistence(timeout: 5))
        // Marking shows the amount stepper; tapping again unmarks, leaving the simulator's journal as it was.
        let wasMarked = alcohol.isSelected
        alcohol.tap()
        let previousDay = app.buttons["Previous day"]
        if !wasMarked {
            // Saturdays' sample drinks make Alcohol a suggestion, which logs 2 rather than 1 (#185).
            let drinks = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ drinks?")).firstMatch
            XCTAssertTrue(drinks.waitForExistence(timeout: 5))
            attachScreenshot("Journal")
            for _ in 0..<5 where !previousDay.exists { app.swipeDown() }
            XCTAssertTrue(app.images["Saved"].waitForExistence(timeout: 5))
            for _ in 0..<5 where !alcohol.exists { app.swipeUp() }
            alcohol.tap()
        }

        for _ in 0..<5 where !previousDay.exists { app.swipeDown() }
        previousDay.tap()
        XCTAssertFalse(app.buttons["Today"].exists)
        attachScreenshot("Journal yesterday")
    }

    /// What App Review sees (#116): no sample data, Apple Health access denied, nothing in Health. Meant for a
    /// freshly erased simulator, where Apple Health asks for access on first launch.
    @MainActor
    func testFirstLaunchWithoutHealthData() throws {
        let app = XCUIApplication()
        // The Health sheet's buttons follow the language, so pin it.
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let dontAllow = app.buttons["Don’t Allow"]
        if dontAllow.waitForExistence(timeout: 10) {
            attachScreenshot("Health access")
            // A tap while the sheet is still sliding in can be lost, so tap until it's gone.
            for _ in 0..<3 where dontAllow.exists {
                dontAllow.tap()
                _ = dontAllow.waitForNonExistence(timeout: 3)
            }
            // Health confirms that categories can be turned on later.
            // Health's own view, so it isn't always reported as an alert, and it can take a while to appear.
            let ok = app.buttons["OK"]
            if ok.waitForExistence(timeout: 10) { ok.tap() }
        }
        if app.navigationBars["Choose your cards"].waitForExistence(timeout: 10) {
            attachScreenshot("Card setup")
            app.staticTexts["Health"].tap()
        }
        if app.navigationBars["Choose your goals"].waitForExistence(timeout: 10) {
            attachScreenshot("Goal setup")
            app.staticTexts["Balanced"].tap()
        }

        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))
        attachScreenshot("Home empty")
        for tab in ["Calendar", "Journal", "Settings"] {
            let button = app.tabBars.buttons[tab]
            button.tap()
            XCTAssertTrue(button.wait(for: \.isSelected, toEqual: true, timeout: 5), "\(tab) didn't open")
            attachScreenshot("\(tab) empty")
        }
        XCTAssertTrue(app.buttons["Privacy Policy"].exists || app.staticTexts["Privacy Policy"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Light/Dark shows only once Match System is off (#180).
    @MainActor
    func testAppearanceSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-SampleData", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        if app.navigationBars["Choose your cards"].waitForExistence(timeout: 5) {
            app.staticTexts["Health"].tap()
        }
        if app.navigationBars["Choose your goals"].waitForExistence(timeout: 5) {
            app.staticTexts["Balanced"].tap()
        }

        app.tabBars.buttons["Settings"].tap()
        app.buttons["Appearance"].tap()
        let matchSystem = app.switches["Match System"]
        XCTAssertTrue(matchSystem.waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Color-Blind Palette"].exists)
        // A run that stopped halfway can leave it off; start from the default.
        if matchSystem.value as? String == "0" { matchSystem.switches.firstMatch.tap() }
        XCTAssertFalse(app.buttons["Dark"].exists)
        attachScreenshot("Appearance")

        matchSystem.switches.firstMatch.tap()
        let dark = app.buttons["Dark"]
        XCTAssertTrue(dark.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Light"].exists)
        dark.tap()
        XCTAssertTrue(dark.isSelected)
        attachScreenshot("Appearance dark")

        // Leaves the simulator following the system again.
        matchSystem.switches.firstMatch.tap()
        XCTAssertTrue(dark.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
