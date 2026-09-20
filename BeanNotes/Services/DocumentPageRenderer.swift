import PDFKit
import UIKit
import WebKit

/// Converts printable documents into the same vector PDF pages used by PDF imports.
/// Each conversion owns its web view and temporary files; no browsing data is retained.
@MainActor
final class DocumentPageRenderer: NSObject, WKNavigationDelegate {
    nonisolated static let supportedExtensions: Set<String> = [
        "doc", "docx", "ppt", "pptx", "xls", "xlsx", "rtf", "html", "htm",
        "txt", "text", "md", "csv", "tsv", "json", "xml", "log"
    ]
    private static let plainTextExtensions: Set<String> = [
        "txt", "text", "md", "csv", "tsv", "json", "xml", "log"
    ]

    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?

    func render(_ sourceURL: URL, to outputURL: URL) async throws {
        try Task.checkCancellation()
        let ext = sourceURL.pathExtension.lowercased()
        if Self.plainTextExtensions.contains(ext) {
            let text = try await Task.detached(priority: .userInitiated) {
                var encoding = String.Encoding.utf8
                return try String(contentsOf: sourceURL, usedEncoding: &encoding)
            }.value
            let formatter = UISimpleTextPrintFormatter(text: text)
            formatter.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            formatter.color = .black
            try writePDF(formatter: formatter, to: outputURL)
            return
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let isSpreadsheet = ["xls", "xlsx"].contains(ext)
        if isSpreadsheet {
            // Only native Office input may enable the system preview's sheet
            // navigation scripts. HTML renamed to .xls must not execute scripts.
            let handle = try FileHandle(forReadingFrom: sourceURL)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 8) ?? Data()
            let hasOfficeSignature = ext == "xlsx"
                ? prefix.starts(with: [0x50, 0x4B, 0x03, 0x04])
                : prefix == Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
            guard hasOfficeSignature else { throw ImportExportError.unsupportedDocument }
        }
        configuration.defaultWebpagePreferences.allowsContentJavaScript = isSpreadsheet
        // Imported HTML must not run code or contact remote servers while being read.
        let rules = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "BeanNotes-OfflineDocumentImport",
            encodedContentRuleList: """
            [{"trigger":{"url-filter":"^[a-zA-Z][a-zA-Z0-9+.-]*:"},"action":{"type":"block"}},
             {"trigger":{"url-filter":"^file:"},"action":{"type":"ignore-previous-rules"}},
             {"trigger":{"url-filter":"^x-apple-ql-id:"},"action":{"type":"ignore-previous-rules"}},
             {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
             {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}}]
            """
        )
        if let rules { configuration.userContentController.add(rules) }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 792, height: 1_024), configuration: configuration)
        self.webView = webView
        webView.navigationDelegate = self
        webView.overrideUserInterfaceStyle = .light
        defer {
            timeoutTask?.cancel()
            timeoutTask = nil
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.removeFromSuperview()
            self.webView = nil
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                loadContinuation = continuation
                timeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    self?.finishLoading(.failure(LocalStorageError.storageOperationTimedOut("Document conversion")))
                }
                webView.loadFileURL(sourceURL, allowingReadAccessTo: sourceURL)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishLoading(.failure(CancellationError()))
            }
        }
        try Task.checkCancellation()
        if ["doc", "docx"].contains(ext) {
            // Apple's Office preview represents explicit Word page breaks as
            // form-feed characters. Web printing otherwise ignores those breaks
            // and includes the preview's artificial minimum canvas height.
            _ = try await webView.evaluateJavaScript(Self.wordPrintPreparation)
        }
        webView.layoutIfNeeded()
        if ["xls", "xlsx"].contains(ext), try await renderSpreadsheet(webView, to: outputURL) {
            return
        }
        try writePDF(
            formatter: webView.viewPrintFormatter(),
            to: outputURL,
            landscape: ["ppt", "pptx"].contains(ext)
        )
    }

    private func renderSpreadsheet(_ webView: WKWebView, to outputURL: URL) async throws -> Bool {
        // The native Office preview wraps sheets in a tabbed iframe. Printing
        // that wrapper once only captures the selected sheet. Read the preview's
        // own local URLs and print each sheet while remote resources stay blocked.
        let value = try await webView.evaluateJavaScript(#"""
        Array.from(document.querySelectorAll('.TabView')).map(tab => {
            const match = (tab.getAttribute('onclick') || '').match(/'(x-apple-ql-id:[^']+)'/);
            return match ? match[1] : '';
        });
        """#)
        guard let sheetURLs = value as? [String], !sheetURLs.isEmpty else { return false }
        guard sheetURLs.count <= 500, sheetURLs.allSatisfy({ $0.hasPrefix("x-apple-ql-id:") }) else {
            throw ImportExportError.unsupportedDocument
        }
        let combined = PDFDocument()
        let piecesDirectory = outputURL.deletingLastPathComponent().appendingPathComponent("sheets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: piecesDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: piecesDirectory) }
        for (sheetIndex, sheetURL) in sheetURLs.enumerated() {
            try Task.checkCancellation()
            _ = try await webView.callAsyncJavaScript(#"""
            const frame = document.querySelector('iframe');
            if (!frame) throw new Error('The spreadsheet preview is unavailable.');
            document.querySelectorAll('.TabView').forEach(tab => {
                tab.classList.toggle('selected', (tab.getAttribute('onclick') || '').includes(sheetURL));
            });
            await new Promise((resolve, reject) => {
                const timeout = setTimeout(() => reject(new Error('The sheet did not load.')), 30000);
                frame.onload = () => { clearTimeout(timeout); resolve(); };
                frame.onerror = () => { clearTimeout(timeout); reject(new Error('The sheet could not be read.')); };
                frame.src = sheetURL;
            });
            """#, arguments: ["sheetURL": sheetURL], in: nil, contentWorld: .defaultClient)
            try Task.checkCancellation()
            let temporary = piecesDirectory.appendingPathComponent("\(sheetIndex).pdf")
            try writePDF(formatter: webView.viewPrintFormatter(), to: temporary)
            guard let sheet = PDFDocument(url: temporary), sheet.pageCount > 0,
                  combined.pageCount + sheet.pageCount <= 2_000 else {
                throw ImportExportError.unsupportedDocument
            }
            for index in 0..<sheet.pageCount {
                guard let page = sheet.page(at: index)?.copy() as? PDFPage else {
                    throw ImportExportError.unsupportedDocument
                }
                combined.insert(page, at: combined.pageCount)
            }
        }
        guard combined.write(to: outputURL) else { throw ImportExportError.exportFailed }
        return true
    }

    private static let wordPrintPreparation = #"""
    (() => {
        const style = document.createElement('style');
        style.media = 'print';
        style.textContent = 'body > div { min-height: 0 !important; overflow: visible !important; }';
        document.head.appendChild(style);
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        const nodes = [];
        while (walker.nextNode()) {
            if (walker.currentNode.data.includes('\f')) nodes.push(walker.currentNode);
        }
        for (const node of nodes) {
            const paragraph = node.parentElement.closest('p');
            if (paragraph && paragraph.textContent.trim() === '') {
                paragraph.textContent = '';
                paragraph.style.cssText += ';break-after:page;page-break-after:always;height:0;margin:0;';
                continue;
            }
            const fragment = document.createDocumentFragment();
            node.data.split('\f').forEach((text, index) => {
                if (index) {
                    const pageBreak = document.createElement('span');
                    pageBreak.style.cssText = 'display:block;break-before:page;page-break-before:always;';
                    fragment.appendChild(pageBreak);
                }
                fragment.appendChild(document.createTextNode(text));
            });
            node.replaceWith(fragment);
        }
    })();
    """#

    private func writePDF(formatter: UIPrintFormatter, to outputURL: URL, landscape: Bool = false) throws {
        try Task.checkCancellation()
        let pageSize = landscape ? CGSize(width: 792, height: 612) : CGSize(width: 612, height: 792)
        let renderer = DocumentPrintPageRenderer(pageSize: pageSize)
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        let count = renderer.numberOfPages
        guard count > 0, count <= 2_000 else { throw ImportExportError.unsupportedDocument }
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: count))
        do {
            try UIGraphicsPDFRenderer(bounds: renderer.paperRect).writePDF(to: outputURL) { context in
                for index in 0..<count {
                    guard !Task.isCancelled else { return }
                    context.beginPage()
                    renderer.drawPage(at: index, in: renderer.paperRect)
                }
            }
            try Task.checkCancellation()
            guard let document = CGPDFDocument(outputURL as CFURL), document.numberOfPages == count else {
                throw ImportExportError.unsupportedDocument
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private func finishLoading(_ result: Result<Void, Error>) {
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishLoading(.failure(ImportExportError.unsupportedDocument))
    }
}

@MainActor
private final class DocumentPrintPageRenderer: UIPrintPageRenderer {
    private let bounds: CGRect

    init(pageSize: CGSize) {
        bounds = CGRect(origin: .zero, size: pageSize)
        super.init()
    }

    override var paperRect: CGRect { bounds }
    override var printableRect: CGRect { bounds.insetBy(dx: 30, dy: 30) }
}
