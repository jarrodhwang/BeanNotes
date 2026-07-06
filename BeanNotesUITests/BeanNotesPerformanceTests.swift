//
//  BeanNotesPerformanceTests.swift
//  BeanNotesUITests
//

import XCTest

final class BeanNotesPerformanceTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments = [
                "--beannotes-ui-testing",
                "--beannotes-reset-storage",
                "--beannotes-skip-welcome"
            ]
            app.launch()
        }
    }
}
