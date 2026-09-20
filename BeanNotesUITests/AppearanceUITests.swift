import XCTest

final class AppearanceUITests: XCTestCase {
    @MainActor
    func testDarkShareFormSavesAnImport() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--beannotes-ui-testing", "--beannotes-reset-storage", "--beannotes-skip-welcome",
            "-appTheme", "dark", "-beanNotesTheme", "bean"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["Create note"].waitForExistence(timeout: 10))
        capture(app, name: "Dark library")
        app.buttons["Create note"].tap()
        XCTAssertTrue(app.buttons["Export"].waitForExistence(timeout: 10))
        capture(app, name: "Dark editor with original paper")
        app.buttons["Export"].tap()
        app.buttons["export.scope.currentPage"].tap()
        app.buttons["export.destination.share"].tap()

        let shareAction = app.cells["Share to BeanNotes"]
        XCTAssertTrue(shareAction.waitForExistence(timeout: 20), app.debugDescription)
        if !shareAction.isHittable { app.swipeUp() }
        shareAction.tap()
        let title = app.textFields["Note title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), app.debugDescription)
        let add = app.buttons["Add to BeanNotes"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: add)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        XCTAssertTrue(add.isHittable, "The import action should stay visible without scrolling.")
        capture(app, name: "Dark share form")
        title.tap()
        title.typeText("Dark mode shared note")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(add.isHittable, "The keyboard must not cover the import action.")
        capture(app, name: "Share form with keyboard")
        app.keyboards.buttons["Done"].tap()
        let openApp = app.buttons["Open BeanNotes right away"]
        let form = app.scrollViews.containing(.textField, identifier: "Note title").firstMatch
        for _ in 0..<4 where !openApp.isHittable { form.swipeUp() }
        XCTAssertTrue(openApp.isHittable)
        openApp.tap()
        XCTAssertEqual(openApp.value as? String, "Unchecked")
        for _ in 0..<4 where !add.isHittable { form.swipeUp() }
        XCTAssertTrue(add.isHittable)
        add.tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 10))

        // A deferred share must survive relaunch and import exactly once.
        app.terminate()
        app.launchArguments.removeAll { $0 == "--beannotes-reset-storage" }
        app.launch()
        XCTAssertTrue(app.staticTexts["Dark mode shared note"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts.matching(identifier: "Dark mode shared note").count, 1)
        capture(app, name: "Imported shared note")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
