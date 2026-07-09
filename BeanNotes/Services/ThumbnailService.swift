//
//  ThumbnailService.swift
//  BeanNotes
//

import ImageIO
import PencilKit
import UIKit
import UniformTypeIdentifiers

struct NoteImageAttachmentRenderSnapshot: Sendable {
    var storedFileName: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var createdAt: Date
    var rendersBehindDrawing: Bool

    @MainActor
    init(attachment: Attachment, pageSize: CGSize?) {
        let frame = attachment.normalizedFrame(for: pageSize)
        self.storedFileName = attachment.storedFileName
        self.x = Double(frame.origin.x)
        self.y = Double(frame.origin.y)
        self.width = Double(frame.width)
        self.height = Double(frame.height)
        self.createdAt = attachment.createdAt
        self.rendersBehindDrawing = attachment.rendersBehindDrawing
    }

    nonisolated var frame: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct NotePageRenderSnapshot: Sendable {
    var id: UUID
    var pageOrder: Int
    var drawingFileName: String
    var backgroundStyleRaw: String
    var backgroundColorHex: String
    var width: Double
    var height: Double
    var imageAttachments: [NoteImageAttachmentRenderSnapshot]

    @MainActor
    init(page: NotePage) {
        let pageSize = page.pageSize
        self.id = page.id
        self.pageOrder = page.pageOrder
        self.drawingFileName = page.drawingFileName
        self.backgroundStyleRaw = page.backgroundStyleRaw
        self.backgroundColorHex = page.backgroundColorHex
        self.width = Double(pageSize.width)
        self.height = Double(pageSize.height)
        self.imageAttachments = page.imageAttachments.map {
            NoteImageAttachmentRenderSnapshot(attachment: $0, pageSize: pageSize)
        }
    }

    nonisolated var pageSize: CGSize {
        CGSize(width: width, height: height)
    }
}

struct ThumbnailService {
    nonisolated private static let maximumAttachmentThumbnailPixelSize = 16_384

    var storage = LocalStorageService()
    var drawingStorage = DrawingStorageService()

    func generateThumbnail(for page: NotePage, maxDimension: CGFloat = 360) throws -> URL {
        let drawing = drawingStorage.loadDrawing(for: page)
        let thumbnail = renderThumbnailImage(page: page, drawing: drawing, maxDimension: maxDimension)
        let data = thumbnail.jpegData(compressionQuality: 0.82) ?? Data()
        let fileName = "\(page.id.uuidString).jpg"
        let stored = try storage.saveData(
            data,
            fileName: fileName,
            contentType: .jpeg,
            to: .thumbnails,
            replacingExisting: true
        )
        page.thumbnailFileName = stored.relativePath
        return storage.url(forRelativePath: stored.relativePath)
    }

    func generateThumbnailInBackground(for page: NotePage, maxDimension: CGFloat = 360) async throws -> URL {
        let snapshot = NotePageRenderSnapshot(page: page)
        let rootURL = storage.rootURL
        let fileName = "\(page.id.uuidString).jpg"
        let stored = try await Self.writeThumbnail(
            snapshot: snapshot,
            rootURL: rootURL,
            fileName: fileName,
            maxDimension: maxDimension
        )

        page.thumbnailFileName = stored.relativePath
        return storage.url(forRelativePath: stored.relativePath)
    }

    func renderThumbnailImage(page: NotePage, drawing: PKDrawing, maxDimension: CGFloat) -> UIImage {
        Self.renderThumbnailImage(
            snapshot: NotePageRenderSnapshot(page: page),
            drawing: drawing,
            rootURL: storage.rootURL,
            maxDimension: maxDimension
        )
    }

    func renderPageImage(page: NotePage, drawing: PKDrawing, scale: CGFloat) -> UIImage {
        Self.renderPageImage(
            snapshot: NotePageRenderSnapshot(page: page),
            drawing: drawing,
            rootURL: storage.rootURL,
            scale: scale
        )
    }

    func drawBackground(_ background: NoteBackground, in rect: CGRect, context: CGContext) {
        NoteBackgroundRenderer.draw(background: background, in: rect, context: context)
    }

    nonisolated static func renderThumbnailImage(
        snapshot: NotePageRenderSnapshot,
        drawing: PKDrawing,
        rootURL: URL,
        maxDimension: CGFloat
    ) -> UIImage {
        let pageSize = snapshot.pageSize
        let longestSide = max(pageSize.width, pageSize.height)
        let scale = min(maxDimension / max(longestSide, 1), 1)
        let thumbnailSize = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: thumbnailSize, format: format)
        return renderer.image { context in
            context.cgContext.saveGState()
            context.cgContext.scaleBy(x: scale, y: scale)
            drawPageContent(
                snapshot: snapshot,
                drawing: drawing,
                rootURL: rootURL,
                in: CGRect(origin: .zero, size: pageSize),
                renderScale: scale
            )
            context.cgContext.restoreGState()
        }
    }

    nonisolated static func renderPageImage(
        snapshot: NotePageRenderSnapshot,
        drawing: PKDrawing,
        rootURL: URL,
        scale: CGFloat
    ) -> UIImage {
        let size = snapshot.pageSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            drawPageContent(
                snapshot: snapshot,
                drawing: drawing,
                rootURL: rootURL,
                in: CGRect(origin: .zero, size: size),
                renderScale: scale
            )
        }
    }

    nonisolated static func loadDrawing(fileName: String, rootURL: URL) -> PKDrawing {
        let drawingURL = rootURL
            .appendingPathComponent(StorageDirectory.drawings.rawValue, isDirectory: true)
            .appendingPathComponent(fileName)

        do {
            guard FileManager.default.fileExists(atPath: drawingURL.path) else {
                return PKDrawing()
            }

            return try PKDrawing(data: Data(contentsOf: drawingURL))
        } catch {
            return PKDrawing()
        }
    }

    nonisolated private static func writeThumbnail(
        snapshot: NotePageRenderSnapshot,
        rootURL: URL,
        fileName: String,
        maxDimension: CGFloat
    ) async throws -> StoredFile {
        try await Task.detached(priority: .utility) {
            try autoreleasepool {
                let drawing = loadDrawing(fileName: snapshot.drawingFileName, rootURL: rootURL)
                let thumbnail = renderThumbnailImage(
                    snapshot: snapshot,
                    drawing: drawing,
                    rootURL: rootURL,
                    maxDimension: maxDimension
                )
                guard let data = thumbnail.jpegData(compressionQuality: 0.82) else {
                    throw ImportExportError.exportFailed
                }

                let storage = LocalStorageService(rootURL: rootURL)
                return try storage.saveData(
                    data,
                    fileName: fileName,
                    contentType: .jpeg,
                    to: .thumbnails,
                    replacingExisting: true
                )
            }
        }.value
    }

    nonisolated private static func drawPageContent(
        snapshot: NotePageRenderSnapshot,
        drawing: PKDrawing,
        rootURL: URL,
        in rect: CGRect,
        renderScale: CGFloat
    ) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        let background = NoteBackground.fromDefaults(
            styleRaw: snapshot.backgroundStyleRaw,
            colorHex: snapshot.backgroundColorHex
        )
        NoteBackgroundRenderer.draw(background: background, in: rect, context: context)

        drawImageAttachments(
            snapshot.imageAttachments.filter(\.rendersBehindDrawing),
            rootURL: rootURL,
            renderScale: renderScale
        )

        let drawingImage = drawing.image(from: rect, scale: renderScale)
        drawingImage.draw(in: rect)

        drawImageAttachments(
            snapshot.imageAttachments.filter { !$0.rendersBehindDrawing },
            rootURL: rootURL,
            renderScale: renderScale
        )
    }

    nonisolated private static func drawImageAttachments(
        _ attachments: [NoteImageAttachmentRenderSnapshot],
        rootURL: URL,
        renderScale: CGFloat
    ) {
        let storage = LocalStorageService(rootURL: rootURL)

        for attachment in attachments.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let imageURL = try? storage.validatedURL(forRelativePath: attachment.storedFileName) else {
                continue
            }
            let maxPixelSize = max(attachment.width, attachment.height) * max(renderScale, 0.25)
            guard let image = renderAttachmentImage(at: imageURL, maxPixelSize: maxPixelSize) else { continue }
            image.draw(in: attachment.frame)
        }
    }

    nonisolated static func renderAttachmentImage(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let options = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary

        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
            return nil
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: normalizedThumbnailPixelSize(maxPixelSize)
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    nonisolated private static func normalizedThumbnailPixelSize(_ value: CGFloat) -> Int {
        guard value.isFinite, value > 0 else { return 1 }
        return max(1, Int(min(value.rounded(), CGFloat(maximumAttachmentThumbnailPixelSize))))
    }

}
