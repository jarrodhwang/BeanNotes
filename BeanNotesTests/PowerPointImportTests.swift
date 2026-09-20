import Foundation
import PDFKit
import SwiftData
import Testing
import UIKit
import WebKit
@testable import BeanNotes

@MainActor
private final class PowerPointPreviewLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, in webView: WKWebView) async throws {
        webView.navigationDelegate = self
        defer { webView.navigationDelegate = nil }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<Void, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

@Suite(.serialized)
@MainActor
struct PowerPointImportTests {
    @Test(arguments: ["WidescreenFidelity", "PortraitFidelity", "LongFidelity"])
    func slidesPreserveGeometryTextImagesAndOriginal(name: String) async throws {
        let source = try #require(Bundle(for: PowerPointPreviewLoader.self).url(forResource: name, withExtension: "pptx"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LocalStorageService(rootURL: root)
        try storage.prepareDirectories()
        let schema = Schema([NotebookFolder.self, NoteDocument.self, NotePage.self, Attachment.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        defer { withExtendedLifetime(container) {} }
        let context = ModelContext(container)
        let folder = NotebookFolder(name: "Presentations")
        context.insert(folder)
        try context.save()
        let service = ImportExportService(storage: storage)
        let imported = try await service.importDocumentAsNote(from: source, into: folder)
        let count = name == "LongFidelity" ? 24 : 3
        let aspect = name == "PortraitFidelity" ? 0.75 : 16.0 / 9.0
        #expect(imported.pages.count == count)
        let original = try #require(imported.attachments.first { !$0.isLocked })
        #expect(original.kind == .presentation)
        #expect(original.originalFileName == source.lastPathComponent)
        #expect(try Data(contentsOf: service.originalFileURL(for: original)) == Data(contentsOf: source))
        let path = try #require(imported.pages.first?.lockedImageAttachments.first?.vectorSourceStoredFileName)
        let pdf = try #require(PDFDocument(url: storage.url(forRelativePath: path)))
        #expect(pdf.pageCount == count)
        for index in 0..<count {
            let page = try #require(pdf.page(at: index))
            let bounds = page.bounds(for: .mediaBox)
            #expect(abs(bounds.width / bounds.height - aspect) < 0.005)
            let marker = name == "LongFidelity" ? String(format: "Slide %02d", index + 1) : ["First", "Middle", "Final"][index]
            let text = (page.string ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            #expect(text.contains("\(marker) fidelity marker"))
            #expect(text.contains("\(marker) bottom edge marker"))
            #expect(text.contains("Text stays on the left."))
            #expect(text.contains("must remain visible."))
            #expect(text.contains("Rotated label"))
            let heading = try #require(pdf.findString("\(marker) fidelity marker", withOptions: []).first)
            #expect(heading.pages.first === page)
            let headingBounds = heading.bounds(for: page)
            #expect(headingBounds.minX / bounds.width > 0.025)
            #expect(headingBounds.maxY / bounds.height > 0.9)
            #expect(bounds.contains(headingBounds))
            let bottom = try #require(pdf.findString("\(marker) bottom edge marker", withOptions: []).first)
            #expect(bounds.contains(bottom.bounds(for: page)))
            #expect(bottom.bounds(for: page).maxY / bounds.height < 0.23)
            let rotated = try #require(pdf.findString("Rotated label", withOptions: []).first { $0.pages.first === page })
            #expect(rotated.bounds(for: page).height / rotated.bounds(for: page).width > 0.3)

            // These assertions inspect rendered pixels, not merely image records.
            // They catch cropped edges, missing pictures, wrong offsets and any
            // added paper margins even when all text remains in the PDF stream.
            let pixels = try renderPixels(page)
            for corner in [CGPoint(x: 0.012, y: 0.012), CGPoint(x: 0.986, y: 0.012),
                           CGPoint(x: 0.012, y: 0.986), CGPoint(x: 0.986, y: 0.986)] {
                #expect(pixels.matches(corner, rgb: (255, 0, 0)))
            }
            #expect(pixels.matches(CGPoint(x: 0.63, y: 0.44), rgb: (0, 180, 80)))
            #expect(pixels.matches(CGPoint(x: 0.83, y: 0.44), rgb: (30, 90, 230)))
            #expect(pixels.matches(CGPoint(x: 0.5, y: 0.2), rgb: (240, 244, 255)))
        }
        #expect(imported.pages.allSatisfy { abs($0.width / $0.height - aspect) < 0.005 })
        #expect(imported.pages.allSatisfy { $0.lockedImageAttachments.count == 1 })
    }

    @Test func unreadableSlideImageFailsInsteadOfSavingIncompletePages() async throws {
        let web = makeWebView()
        let loader = PowerPointPreviewLoader()
        try await loader.load("<div class='slide' style='width:320px;height:180px'><p>Visible text</p><img src='data:image/png;base64,invalid'></div>", in: web)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        do {
            try await PowerPointPageRenderer.render(web, to: output)
            Issue.record("An unreadable slide image must fail conversion.")
        } catch {
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }

    @Test func cancellationDuringSlideLoadingReturnsPromptlyWithoutPartialPDF() async throws {
        let web = makeWebView()
        let loader = PowerPointPreviewLoader()
        try await loader.load("<div class='slide' style='width:320px;height:180px'>Waiting for fonts</div>", in: web)
        _ = try await web.evaluateJavaScript("Object.defineProperty(document, 'fonts', {value: {ready: new Promise(() => {})}}); true;", in: nil, contentWorld: .defaultClient)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        let task = Task { try await PowerPointPageRenderer.render(web, to: output) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        task.cancel()
        do {
            try await task.value
            Issue.record("Slide loading must honor cancellation.")
        } catch is CancellationError {
            #expect(start.duration(to: .now) < .seconds(2))
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        return WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), configuration: configuration)
    }

    private struct Pixels {
        let data: [UInt8]
        let width: Int
        let height: Int

        func matches(_ point: CGPoint, rgb: (Int, Int, Int)) -> Bool {
            let x = min(width - 1, max(0, Int(point.x * CGFloat(width))))
            let y = min(height - 1, max(0, Int(point.y * CGFloat(height))))
            let offset = (y * width + x) * 4
            return abs(Int(data[offset]) - rgb.0) < 20
                && abs(Int(data[offset + 1]) - rgb.1) < 20
                && abs(Int(data[offset + 2]) - rgb.2) < 20
        }
    }

    private func renderPixels(_ page: PDFPage) throws -> Pixels {
        let bounds = page.bounds(for: .mediaBox)
        let width = 640, height = Int((640 * bounds.height / bounds.width).rounded())
        let pageRef = try #require(page.pageRef)
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
            context.cgContext.translateBy(x: 0, y: CGFloat(height))
            context.cgContext.scaleBy(x: CGFloat(width) / bounds.width, y: -CGFloat(height) / bounds.height)
            context.cgContext.drawPDFPage(pageRef)
        }
        let cgImage = try #require(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4, space: colorSpace,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Pixels(data: bytes, width: width, height: height)
    }
}
