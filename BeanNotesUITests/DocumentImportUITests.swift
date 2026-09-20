import XCTest

final class DocumentImportUITests: XCTestCase {
    @MainActor
    func testFailedImportDoesNotPreventTheNextImport() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalid = directory.appendingPathComponent("Unreadable.pdf")
        let valid = directory.appendingPathComponent("Recovered Import.txt")
        try Data("This is not a PDF".utf8).write(to: invalid)
        try Data("Import remains usable after a failure.".utf8).write(to: valid)
        let app = XCUIApplication()
        app.launchArguments = ["--beannotes-ui-testing", "--beannotes-reset-storage", "--beannotes-skip-welcome"]
        app.launch()
        XCTAssertTrue(app.buttons["Create note"].waitForExistence(timeout: 10))
        app.open(invalid)
        XCTAssertTrue(app.alerts["BeanNotes"].waitForExistence(timeout: 20))
        app.alerts["BeanNotes"].buttons["OK"].tap()
        app.open(valid)
        XCTAssertTrue(app.buttons["Back to library"].waitForExistence(timeout: 30), app.debugDescription)
        app.buttons["Back to library"].tap()
        XCTAssertTrue(app.staticTexts["Recovered Import"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Unreadable"].exists)
    }

    @MainActor
    func testFilesPickerCanBeCancelledAndOpenedAgain() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--beannotes-ui-testing", "--beannotes-reset-storage", "--beannotes-skip-welcome"]
        app.launch()
        XCTAssertTrue(app.buttons["Create note"].waitForExistence(timeout: 10))
        app.buttons["Create note"].tap()
        XCTAssertTrue(app.buttons["Add attachment"].waitForExistence(timeout: 10))
        app.buttons["Add attachment"].tap()
        for _ in 0..<2 {
            XCTAssertTrue(app.navigationBars["Add Attachment"].waitForExistence(timeout: 10))
            app.buttons["Files"].tap()
            let cancel = app.buttons["documentImport.cancel"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 15), app.debugDescription)
            XCTAssertTrue(cancel.isHittable)
            cancel.tap()
        }
        XCTAssertTrue(app.navigationBars["Add Attachment"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Back to library"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testOpenInDocumentShowsImportedNote() throws {
        continueAfterFailure = false
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("Original Document Name.txt")
        try Data("An imported document should open directly in the editor.".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let app = XCUIApplication()
        app.launchArguments = ["--beannotes-ui-testing", "--beannotes-reset-storage", "--beannotes-skip-welcome"]
        app.open(source)
        XCTAssertTrue(app.buttons["Back to library"].waitForExistence(timeout: 25))
        XCTAssertTrue(app.buttons["Edit note title"].exists)
        app.buttons["Back to library"].tap()
        XCTAssertTrue(app.staticTexts["Original Document Name"].waitForExistence(timeout: 10))
    }
}
