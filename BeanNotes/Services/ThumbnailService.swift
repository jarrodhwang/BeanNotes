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

enum AttachmentImageRenderingGeometry {
    nonisolated static func aspectFitRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width.isFinite,
              imageSize.height.isFinite,
              imageSize.width > 0,
              imageSize.height > 0,
              !bounds.isNull,
              !bounds.isEmpty else {
            return bounds
        }

        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: bounds.midX - fittedSize.width / 2,
            y: bounds.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
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
    var themeRaw: String
    var showsBeanArtwork: Bool
    var rendersPageBackground: Bool
    var imageAttachments: [NoteImageAttachmentRenderSnapshot]

    @MainActor
    init(page: NotePage) {
        let theme = BeanNotesTheme.currentFromDefaults()
        self.init(
            page: page,
            theme: theme,
            showsBeanArtwork: NoteBackground.showsArtwork(for: theme)
        )
    }

    @MainActor
    init(
        page: NotePage,
        theme: BeanNotesTheme,
        showsBeanArtwork: Bool? = nil,
        rendersPageBackground: Bool = true
    ) {
        let pageSize = page.pageSize
        self.id = page.id
        self.pageOrder = page.pageOrder
        self.drawingFileName = page.drawingFileName
        self.backgroundStyleRaw = page.backgroundStyleRaw
        self.backgroundColorHex = page.backgroundColorHex
        self.width = Double(pageSize.width)
        self.height = Double(pageSize.height)
        self.themeRaw = theme.rawValue
        self.showsBeanArtwork = showsBeanArtwork ?? NoteBackground.showsArtwork(for: theme)
        self.rendersPageBackground = rendersPageBackground
        self.imageAttachments = page.visualAttachments.map {
            NoteImageAttachmentRenderSnapshot(attachment: $0, pageSize: pageSize)
        }
    }

    nonisolated var pageSize: CGSize {
        CGSize(width: width, height: height)
    }

    nonisolated var theme: BeanNotesTheme {
        BeanNotesTheme(rawValue: themeRaw) ?? .standard
    }
}

struct ThumbnailService {
    nonisolated private final class CachedDrawingReference: @unchecked Sendable {
        let drawing: PKDrawing

        init(_ drawing: PKDrawing) {
            self.drawing = drawing
        }
    }

    nonisolated private static let thumbnailRenderVersion = 11
    nonisolated private static let defaultThumbnailMaxDimension: CGFloat = 360
    nonisolated private static let maximumThumbnailMaxDimension: CGFloat = 1_024
    nonisolated private static let defaultPageRenderScale: CGFloat = 1
    nonisolated private static let minimumPageRenderScale: CGFloat = 0.25
    nonisolated private static let maximumPageRenderPixelSize: CGFloat = 6_144
    // Exporting at the preferred 3× scale needs more than 8 MP for the default
    // page size. Keep the bounded renderer comfortably below an excessive memory
    // allocation while preserving print-quality output for normal pages.
    nonisolated private static let maximumPageRenderPixelCount: CGFloat = 16_000_000
    nonisolated private static let maximumAttachmentThumbnailPixelSize = 16_384
    nonisolated static let preferredCaptureRenderScale: CGFloat = 3

    var storage = LocalStorageService()
    var drawingStorage = DrawingStorageService()

    nonisolated static func thumbnailFileName(
        pageID: UUID,
        theme: BeanNotesTheme,
        showsBeanArtwork: Bool = false
    ) -> String {
        let artwork = showsBeanArtwork ? "bean-on" : "bean-off"
        return "\(pageID.uuidString)-\(theme.rawValue)-\(artwork)-v\(thumbnailRenderVersion).jpg"
    }

    nonisolated static func isCurrentThumbnailPath(
        _ relativePath: String,
        pageID: UUID,
        theme: BeanNotesTheme,
        showsBeanArtwork: Bool = false
    ) -> Bool {
        URL(fileURLWithPath: relativePath).lastPathComponent == thumbnailFileName(
            pageID: pageID,
            theme: theme,
            showsBeanArtwork: showsBeanArtwork
        )
    }

    func generateThumbnail(
        for page: NotePage,
        theme: BeanNotesTheme? = nil,
        showsBeanArtwork: Bool? = nil,
        maxDimension: CGFloat = 360
    ) throws -> URL {
        let resolvedTheme = theme ?? .currentFromDefaults()
        let resolvedShowsArtwork = showsBeanArtwork ?? NoteBackground.showsArtwork(for: resolvedTheme)
        let snapshot = NotePageRenderSnapshot(
            page: page,
            theme: resolvedTheme,
            showsBeanArtwork: resolvedShowsArtwork
        )
        let drawing = drawingStorage.loadDrawing(for: page)
        let thumbnail = Self.renderThumbnailImage(
            snapshot: snapshot,
            drawing: drawing,
            rootURL: storage.rootURL,
            maxDimension: maxDimension
        )
        let data = thumbnail.jpegData(compressionQuality: 0.82) ?? Data()
        let fileName = Self.thumbnailFileName(
            pageID: page.id,
            theme: resolvedTheme,
            showsBeanArtwork: snapshot.showsBeanArtwork
        )
        let stored = try storage.saveData(
            data,
            fileName: fileName,
            contentType: .jpeg,
            to: .thumbnails,
            replacingExisting: true
        )
        ImageMemoryCache.shared.removeImages(for: storage.url(forRelativePath: stored.relativePath))
        replaceThumbnailReference(for: page, with: stored.relativePath)
        return storage.url(forRelativePath: stored.relativePath)
    }

    func generateThumbnailInBackground(
        for page: NotePage,
        theme: BeanNotesTheme? = nil,
        showsBeanArtwork: Bool? = nil,
        maxDimension: CGFloat = 360
    ) async throws -> URL {
        let resolvedTheme = theme ?? .currentFromDefaults()
        let resolvedShowsArtwork = showsBeanArtwork ?? NoteBackground.showsArtwork(for: resolvedTheme)
        let snapshot = NotePageRenderSnapshot(
            page: page,
            theme: resolvedTheme,
            showsBeanArtwork: resolvedShowsArtwork
        )
        let rootURL = storage.rootURL
        let drawingFileName = page.drawingFileName
        let cachedDrawing = DrawingStorageService.cachedDrawing(
            fileName: drawingFileName,
            rootURL: rootURL
        ).map(CachedDrawingReference.init)
        let fileName = Self.thumbnailFileName(
            pageID: page.id,
            theme: resolvedTheme,
            showsBeanArtwork: snapshot.showsBeanArtwork
        )
        let data = try await Self.renderThumbnailData(
            snapshot: snapshot,
            drawingFileName: drawingFileName,
            cachedDrawing: cachedDrawing,
            rootURL: rootURL,
            maxDimension: maxDimension
        )
        try Task.checkCancellation()
        guard resolvedTheme == .currentFromDefaults(),
              resolvedShowsArtwork == NoteBackground.showsArtwork(for: resolvedTheme) else {
            throw CancellationError()
        }

        let stored = try storage.saveData(
            data,
            fileName: fileName,
            contentType: .jpeg,
            to: .thumbnails,
            replacingExisting: true
        )
        ImageMemoryCache.shared.removeImages(for: storage.url(forRelativePath: stored.relativePath))

        guard !Task.isCancelled,
              resolvedTheme == .currentFromDefaults(),
              resolvedShowsArtwork == NoteBackground.showsArtwork(for: resolvedTheme) else {
            if page.thumbnailFileName != stored.relativePath {
                try? storage.removeFile(relativePath: stored.relativePath)
            }
            throw CancellationError()
        }

        replaceThumbnailReference(for: page, with: stored.relativePath)
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

    func drawBackground(
        _ background: NoteBackground,
        theme: BeanNotesTheme = .standard,
        showsBeanArtwork: Bool = false,
        pageID: UUID? = nil,
        in rect: CGRect,
        context: CGContext
    ) {
        NoteBackgroundRenderer.draw(
            background: background,
            theme: theme,
            showsBeanArtwork: showsBeanArtwork,
            pageID: pageID,
            in: rect,
            context: context
        )
    }

    private func replaceThumbnailReference(for page: NotePage, with relativePath: String) {
        let previousPath = page.thumbnailFileName
        page.thumbnailFileName = relativePath

        guard let previousPath, previousPath != relativePath else { return }
        try? storage.removeFile(relativePath: previousPath)
    }

    nonisolated static func renderThumbnailImage(
        snapshot: NotePageRenderSnapshot,
        drawing: PKDrawing,
        rootURL: URL,
        maxDimension: CGFloat
    ) -> UIImage {
        let pageSize = snapshot.pageSize
        let longestSide = max(pageSize.width, pageSize.height)
        let targetMaxDimension = normalizedThumbnailMaxDimension(maxDimension)
        let scale = min(targetMaxDimension / max(longestSide, 1), 1)
        let thumbnailSize = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: thumbnailSize, format: format)
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = renderer.image { context in
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
        return image ?? UIImage()
    }

    nonisolated static func renderPageImage(
        snapshot: NotePageRenderSnapshot,
        drawing: PKDrawing,
        rootURL: URL,
        scale: CGFloat
    ) -> UIImage {
        renderPageImageResult(
            snapshot: snapshot,
            drawing: drawing,
            rootURL: rootURL,
            scale: scale,
            requiresImageAttachments: false
        ).image
    }

    nonisolated static func renderPageImageForExport(
        snapshot: NotePageRenderSnapshot,
        drawing: PKDrawing,
        rootURL: URL,
        scale: CGFloat,
        usesOpaqueBackground: Bool = true
    ) throws -> UIImage {
        let result = renderPageImageResult(
            snapshot: snapshot,
            drawing: drawing,
            rootURL: rootURL,
            scale: scale,
            requiresImageAttachments: true,
            usesOpaqueBackground: usesOpaqueBackground
        )
        guard result.didRenderRequiredContent else {
            throw ImportExportError.exportFailed
        }
        return result.image
    }

    /// Renders only the requested page region while preserving page-space geometry.
    /// This avoids screen-resolution screenshots and the memory cost of rasterizing an
    /// entire page when the user only needs a small selection.
    nonisolated static func renderPageCaptureImage(
        snapshot: NotePageRenderSnapshot,
        drawing: PKDrawing,
        rootURL: URL,
        selectionRect: CGRect,
        scale: CGFloat = preferredCaptureRenderScale
    ) -> UIImage? {
        let pageBounds = CGRect(origin: .zero, size: snapshot.pageSize)
        let captureRect = selectionRect.standardized.intersection(pageBounds)
        guard !captureRect.isNull,
              !captureRect.isEmpty,
              captureRect.width.isFinite,
              captureRect.height.isFinite else {
            return nil
        }

        let renderScale = normalizedPageRenderScale(scale, pageSize: captureRect.size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = renderScale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: captureRect.size, format: format)
        var image: UIImage?

        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = renderer.image { context in
                context.cgContext.translateBy(x: -captureRect.minX, y: -captureRect.minY)

                let background = NoteBackground.fromDefaults(
                    styleRaw: snapshot.backgroundStyleRaw,
                    colorHex: snapshot.backgroundColorHex
                )
                NoteBackgroundRenderer.draw(
                    background: background,
                    theme: snapshot.theme,
                    showsBeanArtwork: snapshot.showsBeanArtwork,
                    pageID: snapshot.id,
                    in: pageBounds,
                    context: context.cgContext
                )

                _ = drawImageAttachments(
                    snapshot.imageAttachments.filter {
                        $0.rendersBehindDrawing && $0.frame.intersects(captureRect)
                    },
                    rootURL: rootURL,
                    renderScale: renderScale,
                    requiresImageAttachments: false
                )
                drawing.image(from: captureRect, scale: renderScale).draw(in: captureRect)
                _ = drawImageAttachments(
                    snapshot.imageAttachments.filter {
                        !$0.rendersBehindDrawing && $0.frame.intersects(captureRect)
                    },
                    rootURL: rootURL,
                    renderScale: renderScale,
                    requiresImageAttachments: false
                )
            }
        }

        return image
    }

    nonisolated private static func renderPageImageResult(
        snapshot: NotePageRenderSnapshot,
        drawing: PKDrawing,
        rootURL: URL,
        scale: CGFloat,
        requiresImageAttachments: Bool,
        usesOpaqueBackground: Bool = true
    ) -> (image: UIImage, didRenderRequiredContent: Bool) {
        let size = snapshot.pageSize
        let scale = normalizedPageRenderScale(scale, pageSize: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = snapshot.rendersPageBackground || usesOpaqueBackground

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        var didRenderRequiredContent = false
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = renderer.image { _ in
                didRenderRequiredContent = drawPageContent(
                    snapshot: snapshot,
                    drawing: drawing,
                    rootURL: rootURL,
                    in: CGRect(origin: .zero, size: size),
                    renderScale: scale,
                    requiresImageAttachments: requiresImageAttachments,
                    fillsMissingBackground: usesOpaqueBackground
                )
            }
        }
        return (image ?? UIImage(), didRenderRequiredContent)
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

    nonisolated static func loadDrawingForExport(fileName: String, rootURL: URL) throws -> PKDrawing {
        let drawingURL = rootURL
            .appendingPathComponent(StorageDirectory.drawings.rawValue, isDirectory: true)
            .appendingPathComponent(fileName)

        guard FileManager.default.fileExists(atPath: drawingURL.path) else {
            return PKDrawing()
        }

        return try PKDrawing(data: Data(contentsOf: drawingURL))
    }

    nonisolated private static func renderThumbnailData(
        snapshot: NotePageRenderSnapshot,
        drawingFileName: String,
        cachedDrawing: CachedDrawingReference?,
        rootURL: URL,
        maxDimension: CGFloat
    ) async throws -> Data {
        let renderTask = Task.detached(priority: .utility) {
            try autoreleasepool {
                try Task.checkCancellation()
                // Capture live cached ink at request time so cache eviction cannot make
                // a preview lag behind its debounced disk save. Cache misses perform all
                // file I/O and decoding here on the detached utility task.
                let drawing = cachedDrawing?.drawing
                    ?? loadDrawing(
                        fileName: drawingFileName,
                        rootURL: rootURL
                    )
                try Task.checkCancellation()
                let thumbnail = renderThumbnailImage(
                    snapshot: snapshot,
                    drawing: drawing,
                    rootURL: rootURL,
                    maxDimension: maxDimension
                )
                try Task.checkCancellation()
                guard let data = thumbnail.jpegData(compressionQuality: 0.82) else {
                    throw ImportExportError.exportFailed
                }
                try Task.checkCancellation()
                return data
            }
        }

        return try await withTaskCancellationHandler {
            try await renderTask.value
        } onCancel: {
            renderTask.cancel()
        }
    }

    @discardableResult
    nonisolated private static func drawPageContent(
        snapshot: NotePageRenderSnapshot,
        drawing: PKDrawing,
        rootURL: URL,
        in rect: CGRect,
        renderScale: CGFloat,
        requiresImageAttachments: Bool = false,
        fillsMissingBackground: Bool = true
    ) -> Bool {
        guard let context = UIGraphicsGetCurrentContext() else { return false }

        if snapshot.rendersPageBackground {
            let background = NoteBackground.fromDefaults(
                styleRaw: snapshot.backgroundStyleRaw,
                colorHex: snapshot.backgroundColorHex
            )
            NoteBackgroundRenderer.draw(
                background: background,
                theme: snapshot.theme,
                showsBeanArtwork: snapshot.showsBeanArtwork,
                pageID: snapshot.id,
                in: rect,
                context: context
            )
        } else if fillsMissingBackground {
            context.setFillColor(UIColor.white.cgColor)
            context.fill(rect)
        }

        let didRenderRequiredBackgroundImages = drawImageAttachments(
            snapshot.imageAttachments.filter(\.rendersBehindDrawing),
            rootURL: rootURL,
            renderScale: renderScale,
            requiresImageAttachments: requiresImageAttachments
        )

        let drawingImage = drawing.image(from: rect, scale: renderScale)
        drawingImage.draw(in: rect)

        let didRenderRequiredForegroundImages = drawImageAttachments(
            snapshot.imageAttachments.filter { !$0.rendersBehindDrawing },
            rootURL: rootURL,
            renderScale: renderScale,
            requiresImageAttachments: requiresImageAttachments
        )

        return didRenderRequiredBackgroundImages && didRenderRequiredForegroundImages
    }

    @discardableResult
    nonisolated private static func drawImageAttachments(
        _ attachments: [NoteImageAttachmentRenderSnapshot],
        rootURL: URL,
        renderScale: CGFloat,
        requiresImageAttachments: Bool
    ) -> Bool {
        let storage = LocalStorageService(rootURL: rootURL)
        var didRenderRequiredImages = true

        for attachment in attachments.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let imageURL = try? storage.validatedURL(forRelativePath: attachment.storedFileName) else {
                if requiresImageAttachments {
                    didRenderRequiredImages = false
                }
                continue
            }
            let maxPixelSize = max(attachment.width, attachment.height) * max(renderScale, 0.25)
            guard let image = renderAttachmentImage(at: imageURL, maxPixelSize: maxPixelSize) else {
                if requiresImageAttachments {
                    didRenderRequiredImages = false
                }
                continue
            }
            image.draw(in: AttachmentImageRenderingGeometry.aspectFitRect(
                for: image.size,
                in: attachment.frame
            ))
        }

        return didRenderRequiredImages
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

    nonisolated private static func normalizedThumbnailMaxDimension(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return defaultThumbnailMaxDimension }
        return min(max(value, 1), maximumThumbnailMaxDimension)
    }

    nonisolated private static func normalizedPageRenderScale(_ value: CGFloat, pageSize: CGSize) -> CGFloat {
        guard value.isFinite, value > 0 else { return defaultPageRenderScale }

        let width = pageSize.width
        let height = pageSize.height
        let longestSide = max(width, height)
        guard width.isFinite,
              height.isFinite,
              width > 0,
              height > 0,
              longestSide.isFinite else {
            return min(max(value, minimumPageRenderScale), defaultPageRenderScale)
        }

        // Compositing a page briefly holds both the PencilKit raster and the finished page.
        // A side-only cap still allows square legacy pages to allocate hundreds of MB.
        let dimensionScale = maximumPageRenderPixelSize / longestSide
        let pixelCount = width * height
        var areaScale = sqrt(maximumPageRenderPixelCount / pixelCount)
        // UIGraphicsImageRenderer rounds each pixel edge up independently. Pull the
        // computed scale back until that rounding still fits within the area budget.
        let roundedPixelCount = ceil(width * areaScale) * ceil(height * areaScale)
        if roundedPixelCount > maximumPageRenderPixelCount {
            areaScale *= sqrt(maximumPageRenderPixelCount / roundedPixelCount)
        }
        let maximumScale = max(
            minimumPageRenderScale,
            min(dimensionScale, areaScale)
        )
        return min(max(value, minimumPageRenderScale), maximumScale)
    }

}
