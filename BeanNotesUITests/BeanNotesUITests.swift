//
//  BeanNotesUITests.swift
//  BeanNotesUITests
//
//  Created by Jarrod on 2026-07-02.
//

import XCTest

final class BeanNotesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = makeCleanApp()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    @MainActor
    func testExample() throws {
        app.launch()
        XCTAssertTrue(app.buttons["Create note"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testCreateNewNoteOpensEditor() throws {
        app.launch()

        let createNoteButton = app.buttons["Create note"]
        XCTAssertTrue(createNoteButton.waitForExistence(timeout: 8))
        XCTAssertTrue(createNoteButton.isEnabled)

        createNoteButton.tap()

        XCTAssertTrue(app.buttons["Back to library"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.otherElements["Pen palette"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["1 point stroke"].exists)
        let penButton = app.buttons["Pen"]
        XCTAssertTrue(penButton.waitForExistence(timeout: 8))
        assertComfortableHitArea(for: penButton)
        tapNearTopLeadingCorner(of: penButton)
        XCTAssertTrue(app.buttons["1 point stroke"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["3 point stroke"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["5 point stroke"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["8 point stroke"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Custom pen thickness"].waitForExistence(timeout: 8))
        let blueSwatch = app.buttons["Blue Pen color"]
        XCTAssertTrue(blueSwatch.waitForExistence(timeout: 8))
        assertComfortableHitArea(for: blueSwatch)
        tapNearTopLeadingCorner(of: blueSwatch)
        let selectedBlueSwatch = app.colorWells["Edit Blue Pen color"]
        XCTAssertTrue(selectedBlueSwatch.waitForExistence(timeout: 8))
        assertComfortableHitArea(for: selectedBlueSwatch)
        XCTAssertFalse(app.buttons["Custom eraser size"].exists)
        app.buttons["Eraser"].tap()
        app.buttons["Eraser"].tap()
        XCTAssertTrue(app.buttons["eraser-size-0"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Custom eraser size"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Zoom in"].exists)
        XCTAssertFalse(app.buttons["Zoom out"].exists)
        XCTAssertFalse(app.buttons["Zoom resolution status"].exists)
        XCTAssertTrue(app.buttons["Focus drawing mode"].waitForExistence(timeout: 8))

        let exportButton = app.buttons["Export"]
        XCTAssertTrue(exportButton.waitForExistence(timeout: 8))
        exportButton.tap()

        XCTAssertTrue(app.navigationBars["Export"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testFocusDrawingModeHidesEditorChrome() throws {
        app.launch()

        let createNoteButton = app.buttons["Create note"]
        XCTAssertTrue(createNoteButton.waitForExistence(timeout: 8))
        createNoteButton.tap()

        let focusButton = app.buttons["Focus drawing mode"]
        XCTAssertTrue(focusButton.waitForExistence(timeout: 8))
        focusButton.tap()

        let exitFocusButton = app.buttons["Exit focus mode"]
        XCTAssertTrue(exitFocusButton.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Focus fit page"].exists)
        XCTAssertFalse(app.buttons["Zoom in"].exists)
        XCTAssertFalse(app.buttons["Zoom out"].exists)
        XCTAssertFalse(app.buttons["Back to library"].waitForExistence(timeout: 1))

        exitFocusButton.tap()

        XCTAssertTrue(app.buttons["Focus drawing mode"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Back to library"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testImagePasteControlsAreAvailableWithoutReadingClipboard() throws {
        app.launch()

        let createNoteButton = app.buttons["Create note"]
        XCTAssertTrue(createNoteButton.waitForExistence(timeout: 8))
        createNoteButton.tap()

        XCTAssertTrue(app.buttons["Paste image"].waitForExistence(timeout: 8))

        let addAttachmentButton = app.buttons["Add attachment"]
        XCTAssertTrue(addAttachmentButton.waitForExistence(timeout: 8))
        addAttachmentButton.tap()

        XCTAssertTrue(app.navigationBars["Add Attachment"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Paste Image"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testPageBackgroundEditorExposesPaperSizeAndPinnedApplyAllAction() throws {
        app.launch()

        let createNoteButton = app.buttons["Create note"]
        XCTAssertTrue(createNoteButton.waitForExistence(timeout: 8))
        createNoteButton.tap()

        let pageBackgroundButton = app.buttons["Page background"]
        XCTAssertTrue(pageBackgroundButton.waitForExistence(timeout: 8))
        pageBackgroundButton.tap()

        XCTAssertTrue(app.navigationBars["Background"].waitForExistence(timeout: 8))

        let paperSizePicker = app.descendants(matching: .any)["pageAppearance.paperSizePicker"]
        XCTAssertTrue(paperSizePicker.waitForExistence(timeout: 8))
        XCTAssertTrue(paperSizePicker.isHittable)

        let applyToAllPagesButton = app.buttons["pageAppearance.applyToAllPages"]
        XCTAssertTrue(applyToAllPagesButton.waitForExistence(timeout: 8))
        XCTAssertTrue(applyToAllPagesButton.isHittable)
    }

    @MainActor
    func testBottomPlusExtendsContinuousCanvas() throws {
        app.launch()

        let createNoteButton = app.buttons["Create note"]
        XCTAssertTrue(createNoteButton.waitForExistence(timeout: 8))
        createNoteButton.tap()

        let canvas = try hittablePageCanvas()
        let canvasPoint = visibleCenterCoordinate(on: canvas)

        canvasPoint.tap()
        XCTAssertFalse(app.menuItems["Select All"].waitForExistence(timeout: 1))
        XCTAssertFalse(app.menuItems["Insert Space"].exists)
        XCTAssertFalse(app.menuItems["Insert Tab"].exists)

        let addPage = app.buttons["editor.addPageFooter"]
        XCTAssertTrue(addPage.waitForExistence(timeout: 4))
        for _ in 0..<4 where !addPage.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(addPage.isHittable)
        XCTAssertEqual(app.buttons.matching(identifier: "editor.addPageFooter").count, 1)
        XCTAssertEqual(addPage.label, "Add drawing space")
        addPage.tap()
        XCTAssertTrue(app.staticTexts["Drawing space added"].waitForExistence(timeout: 4))

        let pageStatus = app.staticTexts["editor.pageStatus"]
        XCTAssertTrue(pageStatus.waitForExistence(timeout: 4))
        let continuousCanvasStatus = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Continuous canvas"),
            object: pageStatus
        )
        wait(for: [continuousCanvasStatus], timeout: 4)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "notePageCanvas").count, 1)
    }

    @MainActor
    func testTitleRemainsScreenSpaceWhilePageZooms() throws {
        app.launch()

        let createNoteButton = app.buttons["Create note"]
        XCTAssertTrue(createNoteButton.waitForExistence(timeout: 8))
        createNoteButton.tap()

        let titleButton = app.buttons["Edit note title"]
        XCTAssertTrue(titleButton.waitForExistence(timeout: 8))
        let initialFrame = titleButton.frame

        app.typeKey("+", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1)

        let frameAfterZoom = titleButton.frame
        XCTAssertEqual(frameAfterZoom.minX, initialFrame.minX, accuracy: 1)
        XCTAssertEqual(frameAfterZoom.minY, initialFrame.minY, accuracy: 1)
        XCTAssertEqual(frameAfterZoom.width, initialFrame.width, accuracy: 1)
        XCTAssertEqual(frameAfterZoom.height, initialFrame.height, accuracy: 1)
    }

    @MainActor
    func testWelcomeAppearsOnFirstRun() throws {
        app = makeCleanApp(skipWelcome: false)
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome to BeanNotes"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["A familiar face"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Cozy paper surfaces"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Folder welcomes"].waitForExistence(timeout: 8))

        let startWritingButton = app.buttons["Start Writing"]
        XCTAssertTrue(startWritingButton.waitForExistence(timeout: 8))
        startWritingButton.tap()

        XCTAssertTrue(app.buttons["Create note"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testBeanArtworkToggleDoesNotChangeNotePaper() throws {
        app.launch()

        let startWritingButton = app.buttons["Start Writing"]
        if startWritingButton.waitForExistence(timeout: 2) {
            startWritingButton.tap()
        }

        let settingsButton = app.buttons["Settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 8))
        settingsButton.tap()

        let beanArtworkToggle = app.switches["settings.beanArtworkToggle"]
        XCTAssertTrue(beanArtworkToggle.waitForExistence(timeout: 8))
        XCTAssertTrue(app.switches["settings.beanInterruptToggle"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Use Theme Paper for New Notes"].exists)
        XCTAssertFalse(app.buttons["Apply Theme Icon"].exists)
        XCTAssertFalse(app.buttons["Use Theme Paper Background"].exists)
        XCTAssertEqual(beanArtworkToggle.value as? String, "0")

        beanArtworkToggle.tap()

        XCTAssertTrue(beanArtworkToggle.exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    private func makeCleanApp(skipWelcome: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--beannotes-ui-testing",
            "--beannotes-reset-storage"
        ]

        if skipWelcome {
            app.launchArguments.append("--beannotes-skip-welcome")
        }

        return app
    }

    private func tapNearTopLeadingCorner(of element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.12)).tap()
    }

    private func hittablePageCanvas(pageNumber: Int? = nil) throws -> XCUIElement {
        var canvases = app.descendants(matching: .any).matching(identifier: "notePageCanvas")
        if let pageNumber {
            canvases = canvases.matching(
                NSPredicate(format: "label == %@", "Page \(pageNumber) canvas")
            )
        }
        XCTAssertTrue(canvases.firstMatch.waitForExistence(timeout: 8))

        var bestCanvas: XCUIElement?
        var largestVisibleArea: CGFloat = 0
        for index in 0..<canvases.count {
            let canvas = canvases.element(boundBy: index)
            let visibleFrame = canvas.frame.intersection(app.frame)
            let visibleArea = visibleFrame.width * visibleFrame.height
            if canvas.isHittable, visibleArea > largestVisibleArea {
                bestCanvas = canvas
                largestVisibleArea = visibleArea
            }
        }

        if let bestCanvas {
            return bestCanvas
        }

        throw XCTSkip("No materialized note page canvas was hittable")
    }

    private func visibleCenterCoordinate(on element: XCUIElement) -> XCUICoordinate {
        let frame = element.frame
        let visibleFrame = frame.intersection(app.frame)
        let normalizedOffset = CGVector(
            dx: (visibleFrame.midX - frame.minX) / frame.width,
            dy: (visibleFrame.midY - frame.minY) / frame.height
        )
        return element.coordinate(withNormalizedOffset: normalizedOffset)
    }

    private func assertComfortableHitArea(for element: XCUIElement) {
        XCTAssertGreaterThanOrEqual(element.frame.width, 44)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44)
    }
}
