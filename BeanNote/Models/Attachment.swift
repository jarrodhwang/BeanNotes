//
//  Attachment.swift
//  BeanNote
//

import CoreGraphics
import Foundation
import SwiftData
import UniformTypeIdentifiers

enum AttachmentKind: String, Codable, CaseIterable {
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
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.isLocked = isLocked
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
            CGRect(x: x, y: y, width: width, height: height)
        }
        set {
            x = newValue.origin.x
            y = newValue.origin.y
            width = newValue.width
            height = newValue.height
            touch()
        }
    }

    func touch(at date: Date = Date()) {
        updatedAt = date
        page?.touch(at: date)
    }
}
