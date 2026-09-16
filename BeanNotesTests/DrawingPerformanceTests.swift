import PDFKit
import PencilKit
import SwiftUI
import XCTest
@testable import BeanNotes

/// Synthetic workload timings. Physical Apple Pencil latency still needs a device run.
@MainActor
final class DrawingPerformanceTests: XCTestCase {
    func testPDFPageSetupPerformance() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesPDFPerformance-\(UUID()).pdf")
        defer {
            DrawingCanvasView.NativePDFPageView.removeAllCachedDocuments()
            try? FileManager.default.removeItem(at: url)
        }
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        try UIGraphicsPDFRenderer(bounds: bounds).writePDF(to: url) { context in
            for index in 0..<200 {
                context.beginPage()
                ("Page \(index + 1)" as NSString).draw(
                    at: CGPoint(x: 40, y: 40),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 18)]
                )
            }
        }

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            DrawingCanvasView.NativePDFPageView.removeAllCachedDocuments()
            for pageIndex in [0, 49, 99, 149, 199] {
                autoreleasepool {
                    let view = DrawingCanvasView.NativePDFPageView(frame: bounds)
                    XCTAssertTrue(view.configure(url: url, pageIndex: pageIndex))
                    view.layoutIfNeeded()
                    view.releaseDocument()
                }
            }
        }
    }

    func testConnectedDocumentStrokeCommitPerformance() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesInkPerformance-\(UUID())", isDirectory: true)
        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let pages = (0..<200).map { NotePage(pageOrder: $0, width: 612, height: 792) }
        let parent = DrawingCanvasView(
            pages: pages,
            selectedPageID: .constant(pages[100].id),
            toolState: DrawingToolState(),
            paletteMode: .custom,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            strokeZoomBehavior: .pageWidth,
            pageFlowMode: .seamless,
            doubleTapAction: .switchToEraser,
            saveNowSignal: 0, fitToPageSignal: 0, zoomInSignal: 0,
            zoomOutSignal: 0, zoomToScaleSignal: 0, zoomTargetScale: 1,
            undoSignal: 0, redoSignal: 0, toolShortcutSignal: 0,
            drawingStorage: drawingStorage,
            attachmentChanged: {}, deleteAttachment: { _ in },
            drawingChanged: { _ in }, addPageRequested: {}
        )
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let container = DrawingCanvasView.CanvasContainerView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 800)
        )
        coordinator.containerView = container
        container.configure(
            pages: pages, selectedPageID: pages[100].id, pageFlowMode: .seamless,
            inputMode: .pencilOnly, renderQuality: .balanced,
            drawingStorage: drawingStorage, coordinator: coordinator
        )
        defer {
            container.cancelPendingRenderingWork()
            container.releaseAllMaterializedPages(flushDrawingsBeforeRelease: false)
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }
        let strokes = (0..<100).map { index in
            let points = [CGFloat(60), 100].enumerated().map { offset, x in
                PKStrokePoint(
                    location: CGPoint(x: x, y: 792 * 100 + 60 + CGFloat(index)),
                    timeOffset: Double(offset) * 0.01,
                    size: CGSize(width: 2, height: 2), opacity: 1,
                    force: 1, azimuth: 0, altitude: .pi / 2
                )
            }
            return PKStroke(
                ink: PKInk(.pen, color: .black),
                path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: Double(index)))
            )
        }
        let drawings = (0...strokes.count).map { PKDrawing(strokes: Array(strokes.prefix($0))) }
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            for index in strokes.indices {
                let changed = container.changedContinuousPageIDs(
                    from: drawings[index], to: drawings[index + 1],
                    allowsSingleStrokeFastPath: true
                )
                XCTAssertEqual(changed, [pages[100].id])
            }
            _ = container.changedContinuousPageIDs(
                from: drawings.last!, to: PKDrawing(), allowsSingleStrokeFastPath: false
            )
        }
    }
}
