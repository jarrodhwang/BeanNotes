//
//  ImportExportService.swift
//  BeanNote
//

import Foundation
import PDFKit
import PencilKit
import QuickLookThumbnailing
import SwiftData
import UIKit
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf
    case png
    case jpeg

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pdf:
            "PDF"
        case .png:
            "PNG"
        case .jpeg:
            "JPEG"
        }
    }

    var fileExtension: String {
        switch self {
        case .pdf:
            "pdf"
        case .png:
            "png"
        case .jpeg:
            "jpg"
        }
    }
}

struct ImportedDocumentPages {
    var pages: [NotePage]
    var attachments: [Attachment]

    var firstPage: NotePage? {
        pages.sorted { $0.pageOrder < $1.pageOrder }.first
    }
}

struct ImportedDocumentNote {
    var note: NoteDocument
    var pages: [NotePage]
    var attachments: [Attachment]
}

enum ImportExportError: LocalizedError {
    case unsupportedImageData
    case unsupportedDocument
    case originalFileMissing
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedImageData:
            "BeanNote could not read that image."
        case .unsupportedDocument:
            "BeanNote could not import that document as note pages."
        case .originalFileMissing:
            "The original attachment file is missing from local storage."
        case .exportFailed:
            "BeanNote could not create the export."
        }
    }
}

@MainActor
struct ImportExportService {
    static let wordDocument = UTType(filenameExtension: "docx") ?? .data
    static let legacyWordDocument = UTType(filenameExtension: "doc") ?? .data
    static let powerpoint = UTType(filenameExtension: "ppt") ?? .data
    static let powerpointXML = UTType(filenameExtension: "pptx") ?? .data
    static let commaSeparatedText = UTType(filenameExtension: "csv") ?? .commaSeparatedText

    static let supportedContentTypes: [UTType] = [
        .pdf,
        .png,
        .jpeg,
        wordDocument,
        legacyWordDocument,
        commaSeparatedText,
        powerpoint,
        powerpointXML
    ]

    var storage = LocalStorageService()
    var drawingStorage = DrawingStorageService()
    var thumbnailService = ThumbnailService()

    func importsAsAnnotatableDocument(_ sourceURL: URL) -> Bool {
        let contentType = UTType(filenameExtension: sourceURL.pathExtension) ?? .data
        let kind = attachmentKind(for: contentType, fileExtension: sourceURL.pathExtension)
        return kind == .pdf || kind == .docx
    }

    func importDocumentAsNote(from sourceURL: URL, into folder: NotebookFolder) async throws -> ImportedDocumentNote {
        let note = NoteDocument(title: sourceURL.deletingPathExtension().lastPathComponent)
        let imported = try await importDocumentPages(from: sourceURL, into: note, startingAt: 0)

        note.folder = folder
        folder.notes.append(note)
        folder.updatedAt = Date()

        return ImportedDocumentNote(
            note: note,
            pages: imported.pages,
            attachments: imported.attachments
        )
    }

    func importDocumentPages(
        from sourceURL: URL,
        into note: NoteDocument,
        startingAt startOrder: Int
    ) async throws -> ImportedDocumentPages {
        let contentType = UTType(filenameExtension: sourceURL.pathExtension) ?? .data
        let kind = attachmentKind(for: contentType, fileExtension: sourceURL.pathExtension)

        switch kind {
        case .pdf:
            return try importPDFPages(from: sourceURL, into: note, startingAt: startOrder)
        case .docx:
            return try await importPreviewableDocumentPage(from: sourceURL, kind: kind, into: note, pageOrder: startOrder)
        default:
            throw ImportExportError.unsupportedDocument
        }
    }

    func importFile(from sourceURL: URL, into page: NotePage) throws -> Attachment {
        let contentType = UTType(filenameExtension: sourceURL.pathExtension) ?? .data
        let stored = try storage.copyFile(from: sourceURL, to: .imports)
        let kind = attachmentKind(for: contentType, fileExtension: sourceURL.pathExtension)

        var width: Double = 320
        var height: Double = 220

        if kind == .image,
           let image = UIImage(contentsOfFile: storage.url(forRelativePath: stored.relativePath).path) {
            let maxWidth: Double = 420
            let ratio = image.size.height / max(image.size.width, 1)
            width = min(Double(image.size.width), maxWidth)
            height = max(120, width * Double(ratio))
        }

        let attachment = Attachment(
            kind: kind,
            displayName: sourceURL.deletingPathExtension().lastPathComponent,
            originalFileName: sourceURL.lastPathComponent,
            storedFileName: stored.relativePath,
            contentTypeIdentifier: stored.contentTypeIdentifier,
            fileExtension: sourceURL.pathExtension,
            width: width,
            height: height,
            page: page
        )

        page.attachments.append(attachment)
        page.touch()
        return attachment
    }

    func importImage(_ image: UIImage, named fileName: String = "Pasted Image", into page: NotePage) throws -> Attachment {
        guard let data = image.pngData() else {
            throw ImportExportError.unsupportedImageData
        }

        let baseName = fileName.sanitizedFileName
        let preferredName = baseName.hasSuffix(".png") ? baseName : "\(baseName).png"
        let stored = try storage.saveData(data, preferredName: preferredName, contentType: .png, to: .imports)
        let width = min(Double(image.size.width), 420)
        let ratio = image.size.height / max(image.size.width, 1)
        let height = max(120, width * Double(ratio))

        let attachment = Attachment(
            kind: .image,
            displayName: URL(fileURLWithPath: preferredName).deletingPathExtension().lastPathComponent,
            originalFileName: preferredName,
            storedFileName: stored.relativePath,
            contentTypeIdentifier: UTType.png.identifier,
            fileExtension: "png",
            width: width,
            height: height,
            page: page
        )

        page.attachments.append(attachment)
        page.touch()
        return attachment
    }

    func exportPage(_ page: NotePage, format: ExportFormat) throws -> URL {
        let drawing = drawingStorage.loadDrawing(for: page)
        let image = thumbnailService.renderPageImage(page: page, drawing: drawing, scale: 2)
        let title = page.note?.title.sanitizedFileName ?? "BeanNote"
        let fileName = "\(title)-Page-\(page.pageOrder + 1).\(format.fileExtension)"
        let exportDirectory = try storage.directoryURL(for: .exports)
        let exportURL = exportDirectory.appendingPathComponent(storage.uniqueFileName(fileName))

        switch format {
        case .png:
            guard let data = image.pngData() else { throw ImportExportError.exportFailed }
            try data.write(to: exportURL, options: [.atomic])
        case .jpeg:
            guard let data = image.jpegData(compressionQuality: 0.9) else { throw ImportExportError.exportFailed }
            try data.write(to: exportURL, options: [.atomic])
        case .pdf:
            try writePDF(image: image, page: page, to: exportURL)
        }

        return exportURL
    }

    func originalFileURL(for attachment: Attachment) throws -> URL {
        let url = storage.url(forRelativePath: attachment.storedFileName)
        guard storage.fileManager.fileExists(atPath: url.path) else {
            throw ImportExportError.originalFileMissing
        }
        return url
    }

    func absorbSharedInbox(into modelContext: ModelContext) throws {
        guard let inboxURL = LocalStorageService.sharedInboxURL(fileManager: storage.fileManager) else {
            return
        }

        try storage.fileManager.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        let sharedFiles = try storage.fileManager.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: nil
        )
        .filter { !$0.hasDirectoryPath }

        guard !sharedFiles.isEmpty else { return }

        let inboxFolder = try ensureInboxFolder(in: modelContext)

        for fileURL in sharedFiles {
            let noteTitle = fileURL.deletingPathExtension().lastPathComponent
            let note = NoteDocument(title: noteTitle, folder: inboxFolder)
            let page = NotePage(pageOrder: 0, note: note)
            note.pages.append(page)
            inboxFolder.notes.append(note)

            modelContext.insert(note)
            modelContext.insert(page)

            let attachment = try importFile(from: fileURL, into: page)
            modelContext.insert(attachment)
            try? storage.fileManager.removeItem(at: fileURL)
        }

        try modelContext.save()
    }

    private func ensureInboxFolder(in modelContext: ModelContext) throws -> NotebookFolder {
        let folders = try modelContext.fetch(FetchDescriptor<NotebookFolder>())

        if let inbox = folders.first(where: { $0.name == "Inbox" }) {
            return inbox
        }

        let inbox = NotebookFolder(name: "Inbox", colorHex: "#E5B94E")
        modelContext.insert(inbox)
        return inbox
    }

    private func attachmentKind(for contentType: UTType, fileExtension: String) -> AttachmentKind {
        let ext = fileExtension.lowercased()

        if contentType.conforms(to: .pdf) || ext == "pdf" {
            return .pdf
        }

        if contentType.conforms(to: .image) || ["png", "jpg", "jpeg"].contains(ext) {
            return .image
        }

        if ["doc", "docx"].contains(ext) {
            return .docx
        }

        if ext == "csv" {
            return .csv
        }

        if ["ppt", "pptx"].contains(ext) {
            return .presentation
        }

        return .other
    }

    private func importPDFPages(
        from sourceURL: URL,
        into note: NoteDocument,
        startingAt startOrder: Int
    ) throws -> ImportedDocumentPages {
        let isScoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard let document = PDFDocument(url: sourceURL), document.pageCount > 0 else {
            throw ImportExportError.unsupportedDocument
        }

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let originalStored = try storage.copyFile(from: sourceURL, to: .imports)
        var importedPages: [NotePage] = []
        var importedAttachments: [Attachment] = []

        for index in 0..<document.pageCount {
            guard let pdfPage = document.page(at: index) else { continue }

            let pageSize = normalizedPDFPageSize(for: pdfPage.bounds(for: .mediaBox).size)
            let pageImage = renderPDFPage(pdfPage, size: pageSize)
            guard let imageData = pageImage.jpegData(compressionQuality: 0.92) else {
                throw ImportExportError.exportFailed
            }

            let storedImage = try storage.saveData(
                imageData,
                preferredName: "\(baseName)-page-\(index + 1).jpg",
                contentType: .jpeg,
                to: .imports
            )
            let notePage = NotePage(
                pageOrder: startOrder + index,
                background: .plain(),
                width: Double(pageSize.width),
                height: Double(pageSize.height),
                note: note
            )
            let pageImageAttachment = Attachment(
                kind: .image,
                displayName: "\(baseName) Page \(index + 1)",
                originalFileName: "\(baseName)-page-\(index + 1).jpg",
                storedFileName: storedImage.relativePath,
                contentTypeIdentifier: UTType.jpeg.identifier,
                fileExtension: "jpg",
                x: 0,
                y: 0,
                width: Double(pageSize.width),
                height: Double(pageSize.height),
                isLocked: true,
                page: notePage
            )

            notePage.attachments.append(pageImageAttachment)
            note.pages.append(notePage)
            importedPages.append(notePage)
            importedAttachments.append(pageImageAttachment)
        }

        guard let firstPage = importedPages.first else {
            throw ImportExportError.unsupportedDocument
        }

        let originalAttachment = Attachment(
            kind: .pdf,
            displayName: baseName,
            originalFileName: sourceURL.lastPathComponent,
            storedFileName: originalStored.relativePath,
            contentTypeIdentifier: originalStored.contentTypeIdentifier,
            fileExtension: sourceURL.pathExtension,
            page: firstPage
        )
        firstPage.attachments.append(originalAttachment)
        importedAttachments.append(originalAttachment)
        note.touch()

        return ImportedDocumentPages(pages: importedPages, attachments: importedAttachments)
    }

    private func importPreviewableDocumentPage(
        from sourceURL: URL,
        kind: AttachmentKind,
        into note: NoteDocument,
        pageOrder: Int
    ) async throws -> ImportedDocumentPages {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let pageSize = CGSize(width: 1024, height: 1366)
        let originalStored = try storage.copyFile(from: sourceURL, to: .imports)
        let originalURL = storage.url(forRelativePath: originalStored.relativePath)
        let previewThumbnail = try? await quickLookThumbnail(for: originalURL, size: pageSize)
        let previewImage = makeDocumentPreviewPage(
            thumbnail: previewThumbnail,
            title: baseName,
            fileExtension: sourceURL.pathExtension,
            pageSize: pageSize
        )

        guard let imageData = previewImage.jpegData(compressionQuality: 0.9) else {
            throw ImportExportError.exportFailed
        }

        let storedPreview = try storage.saveData(
            imageData,
            preferredName: "\(baseName)-preview.jpg",
            contentType: .jpeg,
            to: .imports
        )
        let page = NotePage(
            pageOrder: pageOrder,
            background: .plain(),
            width: Double(pageSize.width),
            height: Double(pageSize.height),
            note: note
        )
        let previewAttachment = Attachment(
            kind: .image,
            displayName: "\(baseName) Preview",
            originalFileName: "\(baseName)-preview.jpg",
            storedFileName: storedPreview.relativePath,
            contentTypeIdentifier: UTType.jpeg.identifier,
            fileExtension: "jpg",
            x: 0,
            y: 0,
            width: Double(pageSize.width),
            height: Double(pageSize.height),
            isLocked: true,
            page: page
        )
        let originalAttachment = Attachment(
            kind: kind,
            displayName: baseName,
            originalFileName: sourceURL.lastPathComponent,
            storedFileName: originalStored.relativePath,
            contentTypeIdentifier: originalStored.contentTypeIdentifier,
            fileExtension: sourceURL.pathExtension,
            page: page
        )

        page.attachments.append(previewAttachment)
        page.attachments.append(originalAttachment)
        note.pages.append(page)
        note.touch()

        return ImportedDocumentPages(
            pages: [page],
            attachments: [previewAttachment, originalAttachment]
        )
    }

    private func writePDF(image: UIImage, page: NotePage, to exportURL: URL) throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: page.pageSize))

        try renderer.writePDF(to: exportURL) { context in
            context.beginPage()
            image.draw(in: CGRect(origin: .zero, size: page.pageSize))
        }
    }

    private func normalizedPDFPageSize(for sourceSize: CGSize) -> CGSize {
        let width = max(sourceSize.width, 1)
        let height = max(sourceSize.height, 1)
        let longSide = max(width, height)
        let scale = 1366 / longSide

        return CGSize(
            width: (width * scale).rounded(),
            height: (height * scale).rounded()
        )
    }

    private func renderPDFPage(_ page: PDFPage, size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let pageBounds = page.bounds(for: .mediaBox)
            let scale = min(size.width / pageBounds.width, size.height / pageBounds.height)
            let scaledSize = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)
            let origin = CGPoint(
                x: (size.width - scaledSize.width) / 2,
                y: (size.height - scaledSize.height) / 2
            )

            context.cgContext.saveGState()
            context.cgContext.translateBy(x: origin.x, y: origin.y + scaledSize.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            context.cgContext.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
            page.draw(with: .mediaBox, to: context.cgContext)
            context.cgContext.restoreGState()
        }
    }

    private func quickLookThumbnail(for url: URL, size: CGSize) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: size,
                scale: UIScreen.main.scale,
                representationTypes: .all
            )

            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, error in
                if let thumbnail {
                    continuation.resume(returning: thumbnail.uiImage)
                } else {
                    continuation.resume(throwing: error ?? ImportExportError.unsupportedDocument)
                }
            }
        }
    }

    private func makeDocumentPreviewPage(
        thumbnail: UIImage?,
        title: String,
        fileExtension: String,
        pageSize: CGSize
    ) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: pageSize)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pageSize))

            if let thumbnail {
                let maxPreviewRect = CGRect(x: 92, y: 120, width: pageSize.width - 184, height: pageSize.height - 360)
                let fittedRect = aspectFitRect(for: thumbnail.size, in: maxPreviewRect)
                thumbnail.draw(in: fittedRect)
            }

            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 52, weight: .bold),
                .foregroundColor: UIColor.label
            ]
            let detailAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 26, weight: .medium),
                .foregroundColor: UIColor.secondaryLabel
            ]
            let titleRect = CGRect(x: 80, y: pageSize.height - 220, width: pageSize.width - 160, height: 72)
            let detailRect = CGRect(x: 80, y: pageSize.height - 138, width: pageSize.width - 160, height: 48)

            title.draw(in: titleRect, withAttributes: titleAttributes)
            fileExtension.uppercased().draw(in: detailRect, withAttributes: detailAttributes)
        }
    }

    private func aspectFitRect(for imageSize: CGSize, in rect: CGRect) -> CGRect {
        let scale = min(rect.width / max(imageSize.width, 1), rect.height / max(imageSize.height, 1))
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)

        return CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
