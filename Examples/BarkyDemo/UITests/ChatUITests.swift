import XCTest

final class ChatUITests: XCTestCase {
    func testPreloadedNotificationOpensAtLatestMessage() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.buttons["demo.prepareNotification"].tap()
        XCTAssertTrue(app.staticTexts["Notification conversation ready"].waitForExistence(timeout: 10))

        for presentation in ["demo.openUIKit", "demo.openChat"] {
            app.buttons[presentation].tap()
            let latest = app.staticTexts["Latest reply opened from a notification."]
            let visible = NSPredicate(format: "exists == true AND hittable == true")
            expectation(for: visible, evaluatedWith: latest)
            waitForExpectations(timeout: 5)
            app.buttons["barky.close"].tap()
        }
    }

    func testSendReplyAndReopenSameConversation() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.buttons["demo.openChat"].tap()
        let composer = app.textFields["barky.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("Hello from iOS")
        app.buttons["barky.send"].tap()
        XCTAssertTrue(app.staticTexts["Hello from iOS"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Thanks for trying Barky! This is a local demo reply."].waitForExistence(timeout: 10))
        app.buttons["barky.close"].tap()
        app.buttons["demo.openChat"].tap()
        XCTAssertTrue(app.staticTexts["Hello from iOS"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(identifier: "Hello from iOS").count, 1)
    }

    func testFailedSendCanBeRetried() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.buttons["demo.failNext"].tap()
        app.buttons["demo.openChat"].tap()
        let composer = app.textFields["barky.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap(); composer.typeText("Retry this message")
        app.buttons["barky.send"].tap()
        let retry = app.buttons["barky.retrySend"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        retry.tap()
        XCTAssertTrue(app.staticTexts["Thanks for trying Barky! This is a local demo reply."].waitForExistence(timeout: 10))
        XCTAssertFalse(retry.exists)
        XCTAssertEqual(app.staticTexts.matching(identifier: "Retry this message").count, 1)
    }

    func testUIKitPresentation() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["demo.openUIKit"].tap()
        XCTAssertTrue(app.staticTexts["Barky UIKit Demo"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["barky.composer"].exists)
        app.buttons["barky.close"].tap()
        XCTAssertTrue(app.buttons["demo.openUIKit"].waitForExistence(timeout: 5))
    }
}
