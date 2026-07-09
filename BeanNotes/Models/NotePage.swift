//
//  NotePage.swift
//  BeanNotes
//

import Foundation
import SwiftData

@Model
final class NotePage {
    static let defaultPageWidth: Double = 1024
    static let defaultPageHeight: Double = 1366
    static let minimumPageDimension: Double = 1
    static let maximumPageDimension: Double = 4096

    var id: UUID
    var pageOrder: Int
    var drawingFileName: String
    var thumbnailFileName: String?
    var searchableText: String = ""
    var searchIndexUpdatedAt: Date?
    var backgroundStyleRaw: String
    var backgroundColorHex: String
    var width: Double
    var height: Double
    var createdAt: Date
    var updatedAt: Date
    var note: NoteDocument?

    @Relationship(deleteRule: .cascade, inverse: \Attachment.page)
    var attachments: [Attachment]

    init(
        id: UUID = UUID(),
        pageOrder: Int,
        drawingFileName: String? = nil,
        thumbnailFileName: String? = nil,
        background: NoteBackground = .plain(),
        searchableText: String = "",
        searchIndexUpdatedAt: Date? = nil,
        width: Double = 1024,
        height: Double = 1366,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        note: NoteDocument? = nil,
        attachments: [Attachment] = []
    ) {
        self.id = id
        self.pageOrder = pageOrder
        self.drawingFileName = drawingFileName ?? "\(id.uuidString).drawing"
        self.thumbnailFileName = thumbnailFileName
        self.searchableText = searchableText
        self.searchIndexUpdatedAt = searchIndexUpdatedAt
        self.backgroundStyleRaw = background.storageStyleRaw
        self.backgroundColorHex = background.colorHex
        self.width = Self.normalizedPageDimension(width, fallback: Self.defaultPageWidth)
        self.height = Self.normalizedPageDimension(height, fallback: Self.defaultPageHeight)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.note = note
        self.attachments = attachments
    }

    var pageSize: CGSize {
        CGSize(width: normalizedWidth, height: normalizedHeight)
    }

    var normalizedWidth: Double {
        Self.normalizedPageDimension(width, fallback: Self.defaultPageWidth)
    }

    var normalizedHeight: Double {
        Self.normalizedPageDimension(height, fallback: Self.defaultPageHeight)
    }

    var background: NoteBackground {
        get {
            NoteBackground.fromDefaults(styleRaw: backgroundStyleRaw, colorHex: backgroundColorHex)
        }
        set {
            backgroundStyleRaw = newValue.storageStyleRaw
            backgroundColorHex = newValue.colorHex
            touch()
        }
    }

    var imageAttachments: [Attachment] {
        attachments
            .filter { $0.kind == .image }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var lockedImageAttachments: [Attachment] {
        imageAttachments.filter(\.isLocked)
    }

    var movableImageAttachments: [Attachment] {
        imageAttachments.filter { !$0.isLocked }
    }

    func touch(at date: Date = Date()) {
        updatedAt = date
        markSearchIndexStale()
        note?.touch(at: date)
    }

    func markSearchIndexStale() {
        searchIndexUpdatedAt = nil
        note?.markSearchIndexStale()
    }

    static func normalizedPageDimension(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite, value >= minimumPageDimension else { return fallback }
        return min(value, maximumPageDimension)
    }
}
