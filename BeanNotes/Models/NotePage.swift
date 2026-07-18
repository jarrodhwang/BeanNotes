//
//  NotePage.swift
//  BeanNotes
//

import CoreGraphics
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

    var standardPaperSize: PaperSize? {
        PaperSize.matching(pageSize)
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
            .filter { $0.kind == .image && $0.isVisibleInCurrentDocumentVersion }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var lockedImageAttachments: [Attachment] {
        imageAttachments.filter(\.isLocked)
    }

    /// The smallest canvas that can display every PDF-backed page image at its stored size.
    var minimumPDFContentSize: CGSize? {
        let vectorPDFPageImages = imageAttachments.filter { attachment in
            attachment.vectorSourceStoredFileName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
        }
        let legacyPDFPageCandidates = imageAttachments.filter { attachment in
            attachment.rendersBehindDrawing
                && attachment.originalFileName.lowercased().contains("-page-")
                && !vectorPDFPageImages.contains(where: { $0.id == attachment.id })
        }
        let containsOriginalPDF = !legacyPDFPageCandidates.isEmpty
            && note?.pages.lazy.flatMap(\.attachments).contains(where: { $0.kind == .pdf }) == true
        let pdfPageImages = containsOriginalPDF
            ? vectorPDFPageImages + legacyPDFPageCandidates
            : vectorPDFPageImages

        guard !pdfPageImages.isEmpty else { return nil }

        return CGSize(
            width: pdfPageImages.map { $0.normalizedFrame(for: nil).width }.max()
                ?? Self.minimumPageDimension,
            height: pdfPageImages.map { $0.normalizedFrame(for: nil).height }.max()
                ?? Self.minimumPageDimension
        )
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

    func makeFollowingPage() -> NotePage {
        NotePage(
            pageOrder: pageOrder + 1,
            background: background,
            width: normalizedWidth,
            height: normalizedHeight
        )
    }

    func pageSizeFittingPDFContent(_ proposedSize: CGSize) -> CGSize {
        let normalizedSize = CustomPaperSize.dimensions(
            width: proposedSize.width,
            height: proposedSize.height
        )
        guard let minimumPDFContentSize else { return normalizedSize }

        return CGSize(
            width: max(normalizedSize.width, minimumPDFContentSize.width),
            height: max(normalizedSize.height, minimumPDFContentSize.height)
        )
    }

    static func normalizedPageDimension(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite, value >= minimumPageDimension else { return fallback }
        return min(value, maximumPageDimension)
    }
}
