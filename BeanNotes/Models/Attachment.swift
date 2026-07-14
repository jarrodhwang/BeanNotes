//
//  Attachment.swift
//  BeanNotes
//

import CoreGraphics
import Foundation
import SwiftData
import UniformTypeIdentifiers

enum AttachmentKind: String, Codable, CaseIterable, Sendable {
    case pdf
    case image
    case docx
    case csv
    case presentation
    case other

    var displayName: String {
        switch self {
        case .pdf:
            "PDF"
        case .image:
            "Image"
        case .docx:
            "Word"
        case .csv:
            "CSV"
        case .presentation:
            "Slides"
        case .other:
            "File"
        }
    }
}

enum AttachmentEditingGeometry {
    static let minimumWidth: CGFloat = 120
    static let minimumHeight: CGFloat = 90

    private static let maximumInitialWidth: CGFloat = 420
    private static let minimumInitialLongEdge: CGFloat = 120
    private static let placementMargin: CGFloat = 24
    private static let placementStep: CGFloat = 24
    private static let placementCandidateCount = 8

    static func initialImageFrame(
        sourceSize: CGSize,
        pageSize: CGSize,
        occupiedFrames: [CGRect]
    ) -> CGRect {
        let pageSize = normalizedPageSize(pageSize)
        let sourceSize = normalizedSourceSize(sourceSize)
        let availableSize = CGSize(
            width: max(pageSize.width - placementMargin * 2, 1),
            height: max(pageSize.height - placementMargin * 2, 1)
        )

        let fittingScale = min(
            1,
            maximumInitialWidth / sourceSize.width,
            availableSize.width / sourceSize.width,
            availableSize.height / sourceSize.height
        )
        var fittedSize = CGSize(
            width: sourceSize.width * fittingScale,
            height: sourceSize.height * fittingScale
        )

        let fittedLongEdge = max(fittedSize.width, fittedSize.height)
        if fittedLongEdge < minimumInitialLongEdge {
            let enlargement = min(
                minimumInitialLongEdge / max(fittedLongEdge, 1),
                availableSize.width / max(fittedSize.width, 1),
                availableSize.height / max(fittedSize.height, 1)
            )
            fittedSize.width *= enlargement
            fittedSize.height *= enlargement
        }

        let minimumX = min(placementMargin, max(pageSize.width - fittedSize.width, 0))
        let minimumY = min(placementMargin, max(pageSize.height - fittedSize.height, 0))
        let maximumX = max(pageSize.width - placementMargin - fittedSize.width, minimumX)
        let maximumY = max(pageSize.height - placementMargin - fittedSize.height, minimumY)
        let baseX = min(max(CGFloat(Attachment.defaultX), minimumX), maximumX)
        let baseY = min(max(CGFloat(Attachment.defaultY), minimumY), maximumY)
        let startingCandidate = occupiedFrames.count % placementCandidateCount

        for candidateOffset in 0..<placementCandidateCount {
            let candidateIndex = (startingCandidate + candidateOffset) % placementCandidateCount
            let origin = CGPoint(
                x: min(baseX + CGFloat(candidateIndex) * placementStep, maximumX),
                y: min(baseY + CGFloat(candidateIndex) * placementStep, maximumY)
            )
            let candidate = CGRect(origin: origin, size: fittedSize)
            if !occupiedFrames.contains(where: { $0.intersects(candidate) }) {
                return candidate
            }
        }

        let fallbackIndex = occupiedFrames.count % placementCandidateCount
        return CGRect(
            x: min(baseX + CGFloat(fallbackIndex) * placementStep, maximumX),
            y: min(baseY + CGFloat(fallbackIndex) * placementStep, maximumY),
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    static func movedFrame(
        from startFrame: CGRect,
        translation: CGPoint,
        pageSize: CGSize
    ) -> CGRect {
        let startFrame = normalizedFrame(startFrame, pageSize: pageSize)
        let pageSize = normalizedPageSize(pageSize)
        let translationX = translation.x.isFinite ? translation.x : 0
        let translationY = translation.y.isFinite ? translation.y : 0
        let maximumX = max(pageSize.width - startFrame.width, 0)
        let maximumY = max(pageSize.height - startFrame.height, 0)

        return CGRect(
            x: min(max(startFrame.minX + translationX, 0), maximumX),
            y: min(max(startFrame.minY + translationY, 0), maximumY),
            width: startFrame.width,
            height: startFrame.height
        )
    }

    static func resizedFrame(
        from startFrame: CGRect,
        translation: CGPoint,
        pageSize: CGSize
    ) -> CGRect {
        let startFrame = normalizedFrame(startFrame, pageSize: pageSize)
        let pageSize = normalizedPageSize(pageSize)
        let translationX = translation.x.isFinite ? translation.x : 0
        let translationY = translation.y.isFinite ? translation.y : 0
        let widthScale = (startFrame.width + translationX) / max(startFrame.width, 1)
        let heightScale = (startFrame.height + translationY) / max(startFrame.height, 1)
        let proposedScale = abs(widthScale - 1) >= abs(heightScale - 1) ? widthScale : heightScale
        let maximumScale = min(
            max(pageSize.width - startFrame.minX, 1) / max(startFrame.width, 1),
            max(pageSize.height - startFrame.minY, 1) / max(startFrame.height, 1)
        )
        let requestedMinimumScale = max(
            minimumWidth / max(startFrame.width, 1),
            minimumHeight / max(startFrame.height, 1)
        )
        let minimumScale = min(requestedMinimumScale, maximumScale)
        let resolvedScale = min(max(proposedScale, minimumScale), maximumScale)

        return CGRect(
            origin: startFrame.origin,
            size: CGSize(
                width: startFrame.width * resolvedScale,
                height: startFrame.height * resolvedScale
            )
        )
    }

    private static func normalizedFrame(_ frame: CGRect, pageSize: CGSize) -> CGRect {
        Attachment.normalizedFrame(
            x: Double(frame.origin.x),
            y: Double(frame.origin.y),
            width: Double(frame.width),
            height: Double(frame.height),
            pageSize: normalizedPageSize(pageSize)
        )
    }

    private static func normalizedPageSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: size.width.isFinite && size.width > 0
                ? size.width
                : CGFloat(NotePage.defaultPageWidth),
            height: size.height.isFinite && size.height > 0
                ? size.height
                : CGFloat(NotePage.defaultPageHeight)
        )
    }

    private static func normalizedSourceSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: size.width.isFinite && size.width > 0 ? size.width : 1,
            height: size.height.isFinite && size.height > 0 ? size.height : 1
        )
    }
}

@Model
final class Attachment {
    static let defaultX: Double = 80
    static let defaultY: Double = 100
    static let defaultWidth: Double = 320
    static let defaultHeight: Double = 220
    static let minimumDimension: Double = 1

    var id: UUID
    var kindRaw: String
    var displayName: String
    var originalFileName: String
    var storedFileName: String
    var contentTypeIdentifier: String
    var fileExtension: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var isLocked: Bool = false
    // Keep newly migrated image records behind ink when the stored model predates this property.
    var rendersBehindDrawing: Bool = true
    var vectorSourceStoredFileName: String?
    var vectorSourcePageIndex: Int?
    var createdAt: Date
    var updatedAt: Date
    var page: NotePage?

    init(
        id: UUID = UUID(),
        kind: AttachmentKind,
        displayName: String,
        originalFileName: String,
        storedFileName: String,
        contentTypeIdentifier: String,
        fileExtension: String,
        x: Double = 80,
        y: Double = 100,
        width: Double = 320,
        height: Double = 220,
        isLocked: Bool = false,
        rendersBehindDrawing: Bool? = nil,
        vectorSourceStoredFileName: String? = nil,
        vectorSourcePageIndex: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        page: NotePage? = nil
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.displayName = displayName
        self.originalFileName = originalFileName
        self.storedFileName = storedFileName
        self.contentTypeIdentifier = contentTypeIdentifier
        self.fileExtension = fileExtension
        let frame = Self.normalizedFrame(
            x: x,
            y: y,
            width: width,
            height: height,
            pageSize: nil
        )
        self.x = Double(frame.origin.x)
        self.y = Double(frame.origin.y)
        self.width = Double(frame.width)
        self.height = Double(frame.height)
        self.isLocked = isLocked
        self.rendersBehindDrawing = rendersBehindDrawing ?? (kind == .image)
        self.vectorSourceStoredFileName = vectorSourceStoredFileName
        self.vectorSourcePageIndex = vectorSourcePageIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.page = page
    }

    var kind: AttachmentKind {
        get { AttachmentKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    var contentType: UTType {
        UTType(contentTypeIdentifier) ?? .data
    }

    var frame: CGRect {
        get {
            normalizedFrame(for: nil)
        }
        set {
            let frame = Self.normalizedFrame(
                x: Double(newValue.origin.x),
                y: Double(newValue.origin.y),
                width: Double(newValue.width),
                height: Double(newValue.height),
                pageSize: nil
            )
            x = Double(frame.origin.x)
            y = Double(frame.origin.y)
            width = Double(frame.width)
            height = Double(frame.height)
            touch()
        }
    }

    func touch(at date: Date = Date()) {
        updatedAt = date
        page?.touch(at: date)
    }

    func normalizedFrame(for pageSize: CGSize?) -> CGRect {
        Self.normalizedFrame(
            x: x,
            y: y,
            width: width,
            height: height,
            pageSize: pageSize
        )
    }

    static func normalizedFrame(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        pageSize: CGSize?
    ) -> CGRect {
        let maxWidth = pageDimensionLimit(pageSize?.width)
        let maxHeight = pageDimensionLimit(pageSize?.height)

        let resolvedWidth = normalizedDimension(width, fallback: defaultWidth, maximum: maxWidth)
        let resolvedHeight = normalizedDimension(height, fallback: defaultHeight, maximum: maxHeight)
        let resolvedX = normalizedCoordinate(x, fallback: defaultX, maximum: max(maxWidth - resolvedWidth, 0))
        let resolvedY = normalizedCoordinate(y, fallback: defaultY, maximum: max(maxHeight - resolvedHeight, 0))

        return CGRect(x: resolvedX, y: resolvedY, width: resolvedWidth, height: resolvedHeight)
    }

    private static func normalizedDimension(_ value: Double, fallback: Double, maximum: Double) -> Double {
        guard value.isFinite, value >= minimumDimension else {
            return min(max(fallback, minimumDimension), maximum)
        }

        return min(value, maximum)
    }

    private static func normalizedCoordinate(_ value: Double, fallback: Double, maximum: Double) -> Double {
        guard value.isFinite else {
            return min(max(fallback, 0), maximum)
        }

        return min(max(value, 0), maximum)
    }

    private static func pageDimensionLimit(_ dimension: CGFloat?) -> Double {
        guard let dimension else { return NotePage.maximumPageDimension }
        let value = Double(dimension)
        guard value.isFinite, value > 0 else { return NotePage.maximumPageDimension }
        return max(value, minimumDimension)
    }
}
