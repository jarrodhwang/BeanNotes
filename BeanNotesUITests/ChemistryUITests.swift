import XCTest

@MainActor
final class ChemistryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--beannotes-ui-testing", "--beannotes-reset-storage", "--beannotes-skip-welcome", "-focusFeatures.chemistryMBB.enabled", "YES"]
        app.launch()
        let create = app.buttons["Create note"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        XCTAssertTrue(app.buttons["penPalette.chemistry"].waitForExistence(timeout: 10))
    }

    func testExample3DCanBeExploredSavedAndReopened() throws {
        openChemistry("Chemical Structure")
        app.buttons["chemistry.example.water"].tap()
        app.segmentedControls["chemistry.viewMode"].buttons["3D model"].tap()
        let model = app.descendants(matching: .any)["chemistry.model3D"].firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 15))
        model.swipeLeft()
        attachScreenshot("Water ball and stick")
        app.buttons["Space filling"].tap()
        app.buttons["chemistry.reset3D"].tap()
        attachScreenshot("Water in native 3D")
        app.switches["chemistry.hydrogens"].tap()
        XCTAssertEqual(app.switches["chemistry.hydrogens"].value as? String, "0")
        app.buttons["Inspect atom"].tap()
        app.buttons["Oxygen · atom 1"].tap()
        XCTAssertTrue(app.staticTexts["Oxygen (O) · atom 1"].exists)
        app.buttons["chemistry.saveStructure"].tap()
        XCTAssertTrue(app.buttons["Page actions"].waitForExistence(timeout: 10))
        // Exercise persistence across an actual process restart.
        app.terminate()
        app.launchArguments.removeAll { $0 == "--beannotes-reset-storage" }
        app.launch()
        if !app.buttons["Page actions"].waitForExistence(timeout: 3) {
            let note = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Untitled")).firstMatch
            XCTAssertTrue(note.waitForExistence(timeout: 8))
            note.tap()
        }
        app.buttons["Page actions"].tap()
        app.buttons["Manage Attachments"].tap()
        let actions = app.buttons["Attachment actions"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 8))
        actions.tap()
        app.buttons["Edit Chemical Structure"].tap()
        XCTAssertTrue(app.segmentedControls["chemistry.viewMode"].waitForExistence(timeout: 8))
        app.segmentedControls["chemistry.viewMode"].buttons["3D model"].tap()
        XCTAssertTrue(model.waitForExistence(timeout: 10))
    }

    func testEditingInvalidates3DUndoRestoresIt() throws {
        openChemistry("Chemical Structure")
        app.buttons["chemistry.example.water"].tap()
        let canvas = app.descendants(matching: .any)["chemistry.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 8))
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        app.segmentedControls["chemistry.viewMode"].buttons["3D model"].tap()
        XCTAssertTrue(app.staticTexts["Choose an example for 3D"].waitForExistence(timeout: 8))
        let undo = app.buttons["chemistry.undo"]
        if !undo.isHittable { app.swipeUp() }
        undo.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chemistry.model3D"].firstMatch.waitForExistence(timeout: 10))
    }

    func testFormulaValidationCountsAndSave() throws {
        openChemistry("Molecular Formula")
        let input = app.textFields["chemistry.formulaInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        input.tap()
        input.typeText("H^2")
        XCTAssertFalse(app.buttons["chemistry.saveFormula"].isEnabled)
        input.typeText(XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue)
        input.typeText("Ca(OH)2")
        XCTAssertTrue(app.staticTexts["chemistry.atomCounts"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["chemistry.atomCounts"].label, "Ca: 1   ·   H: 2   ·   O: 2")
        XCTAssertTrue(app.buttons["chemistry.saveFormula"].isEnabled)
        attachScreenshot("Formula counts and guidance")
        app.buttons["chemistry.saveFormula"].tap()
        XCTAssertTrue(app.buttons["Page actions"].waitForExistence(timeout: 8))
    }

    private func openChemistry(_ title: String) {
        app.buttons["penPalette.chemistry"].tap()
        app.buttons[title].tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 8))
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
