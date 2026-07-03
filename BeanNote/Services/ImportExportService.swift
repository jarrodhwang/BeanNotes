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

struct SharedFolderSummary: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var colorHex: String
}

private struct SharedFolderIndex: Codable {
    var folders: [SharedFolderSummary]
}

private enum SharedImportMode: String, Codable {
    case notePages
    case attachments
}

private struct SharedImportRequest: Codable {
    var id: UUID
    var title: String
    var folderID: UUID?
    var importMode: SharedImportMode
    var files: [String]
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
        .image,
        .png,
        .jpeg,
        wordDocument,
        legacyWordDocument,
        commaSeparatedText,
        powerpoint,
        powerpointXML,
        .plainText,
        .data
    ]

    var storage = LocalStorageService()
    var drawingStorage = DrawingStorageService()
    var thumbnailService = ThumbnailService()

    func importsAsAnnotatableDocument(_ sourceURL: URL) -> Bool {
        let contentType = UTType(filenameExtension: sourceURL.pathExtension) ?? .data
        let kind = attachmentKind(for: contentType, fileExtension: sourceURL.pathExtension)
        return kind == .pdf || kind == .docx || kind == .presentation
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

    func importImageAsNote(_ image: UIImage, named displayName: String, into folder: NotebookFolder) throws -> ImportedDocumentNote {
        let title = URL(fileURLWithPath: displayName).deletingPathExtension().lastPathComponent
        let note = NoteDocument(title: title.isEmpty ? "Photo" : title)
        let imported = try importImagePage(
            image,
            sourceData: nil,
            originalFileName: displayName,
            displayName: note.title,
            into: note,
            pageOrder: 0
        )

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
        case .image:
            return try importImageDocumentPage(from: sourceURL, into: note, pageOrder: startOrder)
        case .docx, .csv, .presentation, .other:
            return try await importPreviewableDocumentPage(from: sourceURL, kind: kind, into: note, pageOrder: startOrder)
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

    func exportNote(_ note: NoteDocument, format: ExportFormat) throws -> [URL] {
        let pages = note.sortedPages
        guard !pages.isEmpty else { throw ImportExportError.exportFailed }

        switch format {
        case .pdf:
            let title = note.title.sanitizedFileName
            let exportDirectory = try storage.directoryURL(for: .exports)
            let exportURL = exportDirectory.appendingPathComponent(storage.uniqueFileName("\(title).pdf"))
            try writePDF(pages: pages, title: title, to: exportURL)
            return [exportURL]
        case .png, .jpeg:
            return try pages.map { try exportPage($0, format: format) }
        }
    }

    func originalFileURL(for attachment: Attachment) throws -> URL {
        let url = storage.url(forRelativePath: attachment.storedFileName)
        guard storage.fileManager.fileExists(atPath: url.path) else {
            throw ImportExportError.originalFileMissing
        }
        return url
    }

    func writeSharedFolderIndex(folders: [NotebookFolder]) throws {
        guard let indexURL = LocalStorageService.sharedFolderIndexURL(fileManager: storage.fileManager) else {
            return
        }

        let index = SharedFolderIndex(
            folders: folders
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map {
                    SharedFolderSummary(
                        id: $0.id,
                        name: $0.name,
                        colorHex: $0.colorHex
                    )
                }
        )
        let data = try JSONEncoder().encode(index)
        try storage.fileManager.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: indexURL, options: [.atomic])
    }

    func absorbSharedInbox(into modelContext: ModelContext) async throws {
        guard let inboxURL = LocalStorageService.sharedInboxURL(fileManager: storage.fileManager) else {
            return
        }

        try storage.fileManager.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        var didImport = try await absorbSharedImportRequests(from: inboxURL, into: modelContext)
        let sharedFiles = try storage.fileManager.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: nil
        )
        .filter { !$0.hasDirectoryPath }
        .filter { $0.pathExtension.lowercased() != "json" }

        guard !sharedFiles.isEmpty else {
            if didImport {
                try modelContext.save()
            }
            return
        }

        let inboxFolder = try ensureInboxFolder(in: modelContext)

        for fileURL in sharedFiles {
            let imported = try await importDocumentAsNote(from: fileURL, into: inboxFolder)
            modelContext.insert(imported.note)

            for page in imported.pages {
                modelContext.insert(page)
            }

            for attachment in imported.attachments {
                modelContext.insert(attachment)
            }

            try? storage.fileManager.removeItem(at: fileURL)
            didImport = true
        }

        if didImport {
            try modelContext.save()
        }
    }

    private func absorbSharedImportRequests(from inboxURL: URL, into modelContext: ModelContext) async throws -> Bool {
        let requestsURL = inboxURL.appendingPathComponent("Requests", isDirectory: true)
        guard storage.fileManager.fileExists(atPath: requestsURL.path) else { return false }

        let requestDirectories = try storage.fileManager.contentsOfDirectory(
            at: requestsURL,
            includingPropertiesForKeys: nil
        )
        .filter(\.hasDirectoryPath)

        var didImport = false

        for requestDirectory in requestDirectories {
            let requestURL = requestDirectory.appendingPathComponent("request.json")
            guard storage.fileManager.fileExists(atPath: requestURL.path) else { continue }

            let request = try JSONDecoder().decode(
                SharedImportRequest.self,
                from: try Data(contentsOf: requestURL)
            )
            let fileURLs = request.files
                .map { requestDirectory.appendingPathComponent($0) }
                .filter { storage.fileManager.fileExists(atPath: $0.path) }

            guard !fileURLs.isEmpty else {
                try? storage.fileManager.removeItem(at: requestDirectory)
                continue
            }

            let folder = try folder(for: request.folderID, in: modelContext)
            try await importSharedRequest(request, fileURLs: fileURLs, into: folder, modelContext: modelContext)
            try? storage.fileManager.removeItem(at: requestDirectory)
            didImport = true
        }

        return didImport
    }

    private func importSharedRequest(
        _ request: SharedImportRequest,
        fileURLs: [URL],
        into folder: NotebookFolder,
        modelContext: ModelContext
    ) async throws {
        let noteTitle = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = fileURLs.first?.deletingPathExtension().lastPathComponent ?? "Shared Import"
        let note = NoteDocument(title: noteTitle.isEmpty ? fallbackTitle : noteTitle, folder: folder)
        folder.notes.append(note)
        modelContext.insert(note)

        switch request.importMode {
        case .notePages:
            try await importSharedFilesAsPages(fileURLs, into: note, modelContext: modelContext)
        case .attachments:
            try importSharedFilesAsAttachments(fileURLs, into: note, modelContext: modelContext)
        }

        if note.pages.isEmpty {
            let page = NotePage(pageOrder: 0, note: note)
            note.pages.append(page)
            modelContext.insert(page)
        }

        note.touch()
    }

    private func importSharedFilesAsPages(
        _ fileURLs: [URL],
        into note: NoteDocument,
        modelContext: ModelContext
    ) async throws {
        var attachmentPage: NotePage?

        for fileURL in fileURLs {
            do {
                let nextOrder = (note.pages.map(\.pageOrder).max() ?? -1) + 1
                let imported = try await importDocumentPages(from: fileURL, into: note, startingAt: nextOrder)

                for page in imported.pages {
                    modelContext.insert(page)
                }

                for attachment in imported.attachments {
                    modelContext.insert(attachment)
                }
            } catch {
                let page = attachmentPage ?? {
                    let page = NotePage(pageOrder: (note.pages.map(\.pageOrder).max() ?? -1) + 1, note: note)
                    note.pages.append(page)
                    modelContext.insert(page)
                    attachmentPage = page
                    return page
                }()
                let attachment = try importFile(from: fileURL, into: page)
                modelContext.insert(attachment)
            }
        }
    }

    private func importSharedFilesAsAttachments(
        _ fileURLs: [URL],
        into note: NoteDocument,
        modelContext: ModelContext
    ) throws {
        let page = NotePage(pageOrder: 0, note: note)
        note.pages.append(page)
        modelContext.insert(page)

        for fileURL in fileURLs {
            let attachment = try importFile(from: fileURL, into: page)
            modelContext.insert(attachment)
        }
    }

    private func folder(for folderID: UUID?, in modelContext: ModelContext) throws -> NotebookFolder {
        let folders = try modelContext.fetch(FetchDescriptor<NotebookFolder>())

        if let folderID,
           let folder = folders.first(where: { $0.id == folderID }) {
            return folder
        }

        return try ensureInboxFolder(in: modelContext)
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

        if contentType.conforms(to: .image) || ["png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp"].contains(ext) {
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

    private func importImageDocumentPage(
        from sourceURL: URL,
        into note: NoteDocument,
        pageOrder: Int
    ) throws -> ImportedDocumentPages {
        let storedImage = try storage.copyFile(from: sourceURL, to: .imports)
        let storedURL = storage.url(forRelativePath: storedImage.relativePath)

        guard let image = UIImage(contentsOfFile: storedURL.path) else {
            throw ImportExportError.unsupportedImageData
        }

        return try makeLockedImagePage(
            image,
            storedImage: storedImage,
            originalFileName: sourceURL.lastPathComponent,
            displayName: sourceURL.deletingPathExtension().lastPathComponent,
            into: note,
            pageOrder: pageOrder
        )
    }

    private func importImagePage(
        _ image: UIImage,
        sourceData: Data?,
        originalFileName: String,
        displayName: String,
        into note: NoteDocument,
        pageOrder: Int
    ) throws -> ImportedDocumentPages {
        let encoded = try encodedImageData(for: image, fallbackData: sourceData)
        let sanitizedOriginal = originalFileName.sanitizedFileName
        let baseName = URL(fileURLWithPath: sanitizedOriginal).deletingPathExtension().lastPathComponent
        let storedImage = try storage.saveData(
            encoded.data,
            preferredName: "\(baseName).\(encoded.fileExtension)",
            contentType: encoded.contentType,
            to: .imports
        )

        return try makeLockedImagePage(
            image,
            storedImage: storedImage,
            originalFileName: sanitizedOriginal,
            displayName: displayName,
            into: note,
            pageOrder: pageOrder
        )
    }

    private func makeLockedImagePage(
        _ image: UIImage,
        storedImage: StoredFile,
        originalFileName: String,
        displayName: String,
        into note: NoteDocument,
        pageOrder: Int
    ) throws -> ImportedDocumentPages {
        let pageSize = normalizedImagePageSize(for: image.size)
        let page = NotePage(
            pageOrder: pageOrder,
            background: .plain(),
            width: Double(pageSize.width),
            height: Double(pageSize.height),
            note: note
        )
        let imageAttachment = Attachment(
            kind: .image,
            displayName: displayName.isEmpty ? "Image" : displayName,
            originalFileName: originalFileName,
            storedFileName: storedImage.relativePath,
            contentTypeIdentifier: storedImage.contentTypeIdentifier,
            fileExtension: URL(fileURLWithPath: storedImage.fileName).pathExtension,
            x: 0,
            y: 0,
            width: Double(pageSize.width),
            height: Double(pageSize.height),
            isLocked: true,
            page: page
        )

        page.attachments.append(imageAttachment)
        note.pages.append(page)
        note.touch()

        return ImportedDocumentPages(pages: [page], attachments: [imageAttachment])
    }

    private func writePDF(image: UIImage, page: NotePage, to exportURL: URL) throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: page.pageSize))

        try renderer.writePDF(to: exportURL) { context in
            context.beginPage()
            image.draw(in: CGRect(origin: .zero, size: page.pageSize))
        }
    }

    private func writePDF(pages: [NotePage], title: String, to exportURL: URL) throws {
        let firstSize = pages.first?.pageSize ?? CGSize(width: 1024, height: 1366)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: firstSize))

        try renderer.writePDF(to: exportURL) { context in
            for page in pages {
                let pageBounds = CGRect(origin: .zero, size: page.pageSize)
                context.beginPage(withBounds: pageBounds, pageInfo: [
                    kCGPDFContextCreator as String: "BeanNote",
                    kCGPDFContextTitle as String: title
                ])

                let drawing = drawingStorage.loadDrawing(for: page)
                let image = thumbnailService.renderPageImage(page: page, drawing: drawing, scale: 2)
                image.draw(in: pageBounds)
            }
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

    private func normalizedImagePageSize(for sourceSize: CGSize) -> CGSize {
        let width = max(sourceSize.width, 1)
        let height = max(sourceSize.height, 1)
        let longSide = max(width, height)
        let targetLongSide: CGFloat = longSide < 720 ? 1024 : 1366
        let scale = targetLongSide / longSide

        return CGSize(
            width: max(1, (width * scale).rounded()),
            height: max(1, (height * scale).rounded())
        )
    }

    private func encodedImageData(
        for image: UIImage,
        fallbackData: Data?
    ) throws -> (data: Data, contentType: UTType, fileExtension: String) {
        if let data = image.jpegData(compressionQuality: 0.92) {
            return (data, .jpeg, "jpg")
        }

        if let data = image.pngData() ?? fallbackData {
            return (data, .png, "png")
        }

        throw ImportExportError.unsupportedImageData
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
