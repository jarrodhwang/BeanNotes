import PDFKit
import UIKit
import WebKit

/// Captures the local Office preview's slide canvases without printer margins or
/// pagination. Text, pictures, backgrounds and transforms stay in one coordinate
/// system, and the resulting PDF remains suitable for zooming and annotation.
@MainActor
enum PowerPointPageRenderer {
    static func render(
        _ webView: WKWebView, to outputURL: URL, presentation: PowerPointPackageMetadata? = nil
    ) async throws {
        try Task.checkCancellation()
        let value = try await PowerPointRenderOperation<Any>.run { completion in
            webView.evaluateJavaScript(prepareSlides, in: nil, in: .defaultClient, completionHandler: completion)
        }
        guard let slides = value as? [[String: Double]], !slides.isEmpty, slides.count <= 2_000,
              presentation == nil || presentation?.slides.count == slides.count else {
            throw ImportExportError.presentationConversionFailed
        }
        let sizes = try slides.map { slide -> CGSize in
            guard let width = slide["width"], let height = slide["height"],
                  width.isFinite, height.isFinite, width >= 1, height >= 1,
                  width <= 14_400, height <= 14_400 else {
                throw ImportExportError.presentationConversionFailed
            }
            return CGSize(width: width, height: height)
        }

        let combined = PDFDocument()
        do {
            for (index, size) in sizes.enumerated() {
                try Task.checkCancellation()
                // Match the viewport to the canvas so iOS's viewport scaling
                // cannot shrink a wide slide or crop a portrait presentation.
                webView.frame.size = size
                webView.layoutIfNeeded()
                let rotations: [[String: Any]] = (presentation?.slides[index] ?? []).map {
                    ["text": $0.text, "degrees": $0.degrees, "x": $0.x, "y": $0.y,
                     "width": $0.width, "height": $0.height]
                }
                let value = try await PowerPointRenderOperation<Any>.run { completion in
                    webView.callAsyncJavaScript(
                        readySlide, arguments: ["index": index, "rotations": rotations], in: nil,
                        in: .defaultClient, completionHandler: completion
                    )
                }
                try Task.checkCancellation()
                guard let bounds = value as? [String: Double],
                      let x = bounds["x"], let y = bounds["y"], x.isFinite, y.isFinite else {
                    throw ImportExportError.presentationConversionFailed
                }
                let configuration = WKPDFConfiguration()
                configuration.rect = CGRect(x: x, y: y, width: size.width, height: size.height)
                let data = try await PowerPointRenderOperation<Data>.run { completion in
                    webView.createPDF(configuration: configuration, completionHandler: completion)
                }
                try Task.checkCancellation()
                guard let document = PDFDocument(data: data), document.pageCount == 1,
                      let page = document.page(at: 0), let pageRef = page.pageRef else {
                    throw ImportExportError.presentationConversionFailed
                }
                if let presentation {
                    // Office previews round EMU dimensions down to pixels. Scale
                    // the captured vectors to the exact source slide dimensions.
                    let bounds = CGRect(x: 0, y: 0, width: presentation.width, height: presentation.height)
                    let pdf = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
                        context.beginPage()
                        context.cgContext.translateBy(x: 0, y: bounds.height)
                        context.cgContext.scaleBy(x: bounds.width / size.width, y: -bounds.height / size.height)
                        context.cgContext.drawPDFPage(pageRef)
                    }
                    guard let scaled = PDFDocument(data: pdf)?.page(at: 0) else {
                        throw ImportExportError.presentationConversionFailed
                    }
                    combined.insert(scaled, at: combined.pageCount)
                } else {
                    combined.insert(page, at: combined.pageCount)
                }
                await Task.yield()
            }
            try Task.checkCancellation()
            guard combined.pageCount == sizes.count, combined.write(to: outputURL) else {
                throw ImportExportError.exportFailed
            }
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private static let prepareSlides = #"""
    (() => {
        const slides = Array.from(document.querySelectorAll('div.slide'));
        if (!slides.length || slides.length > 2000) throw new Error('The slide preview is unavailable.');
        const sizes = slides.map(slide => {
            const style = getComputedStyle(slide);
            return {width: parseFloat(style.width), height: parseFloat(style.height)};
        });
        // The preview includes grey loading overlays and five-pixel gutters.
        // Those are viewer chrome, not part of the presentation's artwork.
        const style = document.createElement('style');
        style.textContent = `
            html, body { margin: 0 !important; padding: 0 !important; }
            div.loading-slide { display: none !important; }
            div.slide { margin: 0 !important; break-inside: auto !important; }
        `;
        document.head.appendChild(style);
        let viewport = document.querySelector('meta[name="viewport"]');
        if (viewport) viewport.content = 'width=device-width, initial-scale=1.0';
        return sizes;
    })();
    """#

    private static let readySlide = #"""
    const slide = document.querySelectorAll('div.slide')[index];
    if (!slide) throw new Error('The slide could not be read.');
    const normalise = text => text.replace(/\s+/g, ' ').trim();
    const size = {width: parseFloat(getComputedStyle(slide).width), height: parseFloat(getComputedStyle(slide).height)};
    const used = new Set();
    for (const rotation of rotations) {
        // The Office preview rotates the vector shape artwork but leaves the
        // separate searchable text wrapper horizontal. Match text and geometry
        // together so repeated labels do not acquire another shape's rotation.
        const candidates = Array.from(slide.querySelectorAll('div')).filter(element =>
            element.style.position === 'absolute' && !used.has(element) &&
            normalise(element.textContent) === normalise(rotation.text));
        const distance = element => {
            const style = getComputedStyle(element);
            return Math.abs(parseFloat(style.left) / size.width - rotation.x) +
                Math.abs(parseFloat(style.top) / size.height - rotation.y) +
                Math.abs(parseFloat(style.width) / size.width - rotation.width) +
                Math.abs(parseFloat(style.height) / size.height - rotation.height);
        };
        candidates.sort((a, b) => distance(a) - distance(b));
        const text = candidates[0];
        if (text && distance(text) < 0.02) {
            text.style.transform = `rotate(${rotation.degrees}deg)`;
            text.style.transformOrigin = '50% 50%';
            used.add(text);
        }
    }
    slide.scrollIntoView({block: 'start', inline: 'start'});
    let timeout;
    try {
        await Promise.race([
            (async () => {
                await document.fonts.ready;
                await Promise.all(Array.from(slide.querySelectorAll('img')).map(image => {
                    if (image.complete) {
                        if (!image.naturalWidth) throw new Error('A slide image could not be read.');
                        return;
                    }
                    return new Promise((resolve, reject) => {
                        image.addEventListener('load', resolve, {once: true});
                        image.addEventListener('error', () => reject(new Error('A slide image could not be read.')), {once: true});
                    });
                }));
            })(),
            new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error('The slide did not finish loading.')), 15000); })
        ]);
    } finally {
        clearTimeout(timeout);
    }
    // Let layout settle after fonts, images and the viewport have changed.
    // A converter has no visible window, so requestAnimationFrame may suspend.
    // Reading the bounds forces layout, and PDF capture commits the rendering.
    await new Promise(resolve => setTimeout(resolve, 0));
    const bounds = slide.getBoundingClientRect();
    return {x: bounds.left + window.scrollX, y: bounds.top + window.scrollY};
    """#
}

/// WebKit callbacks may never arrive after a process failure. A deadline and a
/// single completion gate keep cancellation responsive and discard late results.
@MainActor
private final class PowerPointRenderOperation<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var timeout: Task<Void, Never>?

    static func run(
        start: (_ completion: @escaping @MainActor @Sendable (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        let operation = PowerPointRenderOperation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                operation.continuation = continuation
                operation.timeout = Task { @MainActor [weak operation] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    operation?.finish(.failure(LocalStorageError.storageOperationTimedOut("Slide conversion")))
                }
                start { operation.finish($0) }
            }
        } onCancel: {
            Task { @MainActor in operation.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(with: result)
    }
}
