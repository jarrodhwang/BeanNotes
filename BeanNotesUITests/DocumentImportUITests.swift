import XCTest

final class DocumentImportUITests: XCTestCase {
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
