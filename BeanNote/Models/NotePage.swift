//
//  NotePage.swift
//  BeanNote
//

import Foundation
import SwiftData

@Model
final class NotePage {
    var id: UUID
    var pageOrder: Int
    var drawingFileName: String
    var thumbnailFileName: String?
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
        self.backgroundStyleRaw = background.style.rawValue
        self.backgroundColorHex = background.colorHex
        self.width = width
        self.height = height
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.note = note
        self.attachments = attachments
    }

    var pageSize: CGSize {
        CGSize(width: width, height: height)
    }

    var background: NoteBackground {
        get {
            NoteBackground(
                style: NoteBackgroundStyle(rawValue: backgroundStyleRaw) ?? .plain,
                colorHex: backgroundColorHex
            )
        }
        set {
            backgroundStyleRaw = newValue.style.rawValue
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
        note?.touch(at: date)
    }
}
