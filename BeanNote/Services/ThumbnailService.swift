//
//  ThumbnailService.swift
//  BeanNote
//

import PencilKit
import UIKit
import UniformTypeIdentifiers

struct ThumbnailService {
    var storage = LocalStorageService()
    var drawingStorage = DrawingStorageService()

    func generateThumbnail(for page: NotePage, maxDimension: CGFloat = 360) throws -> URL {
        let drawing = drawingStorage.loadDrawing(for: page)
        let image = renderPageImage(page: page, drawing: drawing, scale: 1)

        let longestSide = max(image.size.width, image.size.height)
        let scale = min(maxDimension / longestSide, 1)
        let thumbnailSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: thumbnailSize, format: format)
        let thumbnail = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: thumbnailSize))
        }

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

    func renderPageImage(page: NotePage, drawing: PKDrawing, scale: CGFloat) -> UIImage {
        let size = page.pageSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            drawBackground(page.background, in: CGRect(origin: .zero, size: size), context: context.cgContext)

            for attachment in page.imageAttachments {
                let imageURL = storage.url(forRelativePath: attachment.storedFileName)
                guard let image = UIImage(contentsOfFile: imageURL.path) else { continue }
                image.draw(in: attachment.frame)
            }

            let drawingImage = drawing.image(from: CGRect(origin: .zero, size: size), scale: scale)
            drawingImage.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func drawBackground(_ background: NoteBackground, in rect: CGRect, context: CGContext) {
        UIColor(hex: background.colorHex).setFill()
        context.fill(rect)

        let lineColor = UIColor.secondaryLabel.withAlphaComponent(0.24)
        lineColor.setStroke()
        context.setLineWidth(1)

        switch background.style {
        case .plain:
            return
        case .grid:
            drawGrid(in: rect, spacing: 32, context: context)
        case .dotted:
            drawDots(in: rect, spacing: 28, context: context)
        case .lined:
            drawLines(in: rect, spacing: 36, context: context)
        }
    }

    private func drawGrid(in rect: CGRect, spacing: CGFloat, context: CGContext) {
        var x = rect.minX
        while x <= rect.maxX {
            context.move(to: CGPoint(x: x, y: rect.minY))
            context.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += spacing
        }

        var y = rect.minY
        while y <= rect.maxY {
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += spacing
        }
        context.strokePath()
    }

    private func drawLines(in rect: CGRect, spacing: CGFloat, context: CGContext) {
        var y = rect.minY + spacing
        while y <= rect.maxY {
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += spacing
        }
        context.strokePath()
    }

    private func drawDots(in rect: CGRect, spacing: CGFloat, context: CGContext) {
        let dotColor = UIColor.secondaryLabel.withAlphaComponent(0.34)
        dotColor.setFill()

        var x = rect.minX + spacing
        while x <= rect.maxX {
            var y = rect.minY + spacing
            while y <= rect.maxY {
                context.fillEllipse(in: CGRect(x: x - 1.2, y: y - 1.2, width: 2.4, height: 2.4))
                y += spacing
            }
            x += spacing
        }
    }
}
