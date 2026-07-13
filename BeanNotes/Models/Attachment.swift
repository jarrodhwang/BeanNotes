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
    var rendersBehindDrawing: Bool = false
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
        self.rendersBehindDrawing = rendersBehindDrawing ?? isLocked
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
