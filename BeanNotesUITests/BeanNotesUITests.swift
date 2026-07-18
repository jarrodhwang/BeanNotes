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
        XCTAssertFalse(app.buttons["Rub Eraser eraser"].exists)
        XCTAssertFalse(app.buttons["Zoom in"].exists)
        XCTAssertFalse(app.buttons["Zoom out"].exists)
        XCTAssertFalse(app.buttons["Zoom resolution status"].exists)
        XCTAssertTrue(app.buttons["Focus drawing mode"].waitForExistence(timeout: 8))

        let exportButton = app.buttons["Export"]
        XCTAssertTrue(exportButton.waitForExistence(timeout: 8))
        exportButton.tap()

        XCTAssertTrue(app.navigationBars["Export"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["export.scope.currentPage"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["export.scope.allPages"].exists)
        XCTAssertTrue(app.buttons["export.advanced"].exists)

        app.buttons["export.scope.currentPage"].tap()
        XCTAssertTrue(app.navigationBars["Export Current Page"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["export.format.pdf"].exists)
        XCTAssertTrue(app.buttons["export.format.png"].exists)
        XCTAssertTrue(app.buttons["export.format.jpeg"].exists)
        XCTAssertTrue(app.buttons["export.destination.share"].exists)
        XCTAssertTrue(app.buttons["export.destination.files"].exists)

        app.buttons["export.destination.files"].tap()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 8))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Export Current Page"].waitForExistence(timeout: 8))

        app.navigationBars["Export Current Page"].buttons["Export"].tap()
        XCTAssertTrue(app.navigationBars["Export"].waitForExistence(timeout: 8))
        app.buttons["export.advanced"].tap()
        XCTAssertTrue(app.navigationBars["Advanced Export"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.segmentedControls["export.advanced.scope"].exists)
        XCTAssertTrue(app.buttons["export.destination.share"].exists)
        XCTAssertTrue(app.buttons["export.destination.files"].exists)
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
    func testContinuousCanvasLongPressUsesOnlyPageActions() throws {
        app.launch()

        let createNoteButton = app.buttons["Create note"]
        XCTAssertTrue(createNoteButton.waitForExistence(timeout: 8))
        createNoteButton.tap()

        let canvas = try hittablePageCanvas()
        visibleCenterCoordinate(on: canvas).doubleTap()
        XCTAssertFalse(app.menuItems["Select All"].waitForExistence(timeout: 1))
        XCTAssertFalse(app.menuItems["Insert Space"].exists)

        let longPressCanvas = try hittablePageCanvas()
        visibleCenterCoordinate(on: longPressCanvas).press(forDuration: 0.7)

        let addBelow = app.menuItems["Add Page Below"]
        XCTAssertTrue(addBelow.waitForExistence(timeout: 4))
        XCTAssertTrue(app.menuItems["Add Page Above"].exists)
        XCTAssertTrue(app.menuItems["Remove Page"].exists)
        XCTAssertFalse(app.menuItems["Select All"].exists)
        XCTAssertFalse(app.menuItems["Insert Space"].exists)

        addBelow.tap()
        XCTAssertTrue(app.staticTexts["Drawing space added"].waitForExistence(timeout: 4))
    }

    @MainActor
    func testPageNavigatorSelectsPagesAndDismissesOutside() throws {
        app.launch()

        let createNoteButton = app.buttons["Create note"]
        XCTAssertTrue(createNoteButton.waitForExistence(timeout: 8))
        createNoteButton.tap()

        let canvas = try hittablePageCanvas()
        visibleCenterCoordinate(on: canvas).press(forDuration: 0.7)

        let addBelow = app.menuItems["Add Page Below"]
        XCTAssertTrue(addBelow.waitForExistence(timeout: 4))
        addBelow.tap()
        XCTAssertTrue(app.staticTexts["Drawing space added"].waitForExistence(timeout: 4))

        let navigatorButton = app.buttons["Page navigator"]
        XCTAssertTrue(navigatorButton.waitForExistence(timeout: 4))
        navigatorButton.tap()

        let navigator = app.otherElements["editor.pageNavigator"]
        XCTAssertTrue(navigator.waitForExistence(timeout: 4))

        let displayModeButton = app.buttons["editor.pageNavigator.displayMode"]
        XCTAssertTrue(displayModeButton.waitForExistence(timeout: 4))
        XCTAssertEqual(displayModeButton.value as? String, "Preview list")
        displayModeButton.tap()
        XCTAssertEqual(displayModeButton.value as? String, "Compact list")

        let secondPage = app.buttons["editor.pageNavigator.page.2"]
        XCTAssertTrue(secondPage.waitForExistence(timeout: 4))
        secondPage.tap()
        XCTAssertEqual(secondPage.value as? String, "Selected")

        let firstPage = app.buttons["editor.pageNavigator.page.1"]
        XCTAssertTrue(firstPage.waitForExistence(timeout: 4))
        firstPage.tap()
        XCTAssertEqual(firstPage.value as? String, "Selected")

        let dismissArea = app.buttons["editor.pageNavigator.dismissArea"]
        XCTAssertTrue(dismissArea.waitForExistence(timeout: 4))
        dismissArea.tap()
        XCTAssertFalse(navigator.waitForExistence(timeout: 2))
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

        openSettings()

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

    @MainActor
    func testSettingsSectionsUseTopSelectorWithoutNavigationTitle() throws {
        app.launch()

        let startWritingButton = app.buttons["Start Writing"]
        if startWritingButton.waitForExistence(timeout: 2) {
            startWritingButton.tap()
        }

        openSettings()

        let sectionPicker = app.segmentedControls["settings.sectionPicker"]
        XCTAssertTrue(sectionPicker.waitForExistence(timeout: 8))
        XCTAssertFalse(app.navigationBars["Settings"].exists)

        let beanArtworkToggle = app.switches["settings.beanArtworkToggle"]
        XCTAssertTrue(beanArtworkToggle.waitForExistence(timeout: 8))
        XCTAssertLessThan(sectionPicker.frame.maxY, beanArtworkToggle.frame.minY)

        sectionPicker.buttons["Note Style"].tap()
        XCTAssertTrue(app.buttons["Template, Plain"].waitForExistence(timeout: 8))

        sectionPicker.buttons["Pencil Style"].tap()
        XCTAssertTrue(app.buttons["settings.paletteColorCountPicker"].waitForExistence(timeout: 8))

        sectionPicker.buttons["Backup"].tap()
        XCTAssertTrue(app.buttons["Refresh Usage"].waitForExistence(timeout: 8))
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

    @MainActor
    private func openSettings() {
        let settingsButton = app.buttons["Settings"]
        if !settingsButton.waitForExistence(timeout: 1) {
            let showSidebarButton = app.buttons["ToggleSidebar"]
            XCTAssertTrue(showSidebarButton.waitForExistence(timeout: 8))
            showSidebarButton.tap()
        }

        XCTAssertTrue(settingsButton.waitForExistence(timeout: 8))
        settingsButton.tap()
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
