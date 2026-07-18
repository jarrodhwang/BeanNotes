//
//  ImportExportService.swift
//  BeanNotes
//

import Foundation
import ImageIO
import PDFKit
import PencilKit
import QuickLookThumbnailing
import SwiftData
import UIKit
import UniformTypeIdentifiers

typealias ImportExportProgressHandler = @MainActor @Sendable (_ fraction: Double?, _ message: String) -> Void

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
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

enum ExportPageBackgroundMode: String, CaseIterable, Identifiable, Sendable {
    case original
    case none
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original:
            "As Shown"
        case .none:
            "No Page Background"
        case .custom:
            "Custom"
        }
    }
}

enum ExportPDFQuality: String, CaseIterable, Identifiable, Sendable {
    case compact
    case balanced
    case best

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact:
            "Compact"
        case .balanced:
            "Balanced"
        case .best:
            "Best"
        }
    }

    nonisolated var renderScale: CGFloat {
        switch self {
        case .compact:
            1
        case .balanced:
            2
        case .best:
            3
        }
    }
}

enum ExportImageResolution: String, CaseIterable, Identifiable, Sendable {
    case oneX
    case twoX
    case threeX

    var id: String { rawValue }

    var label: String {
        switch self {
        case .oneX:
            "1\u{00D7}"
        case .twoX:
            "2\u{00D7}"
        case .threeX:
            "3\u{00D7}"
        }
    }

    nonisolated var renderScale: CGFloat {
        switch self {
        case .oneX:
            1
        case .twoX:
            2
        case .threeX:
            3
        }
    }
}

enum ExportJPEGQuality: String, CaseIterable, Identifiable, Sendable {
    case compact
    case balanced
    case best

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact:
            "70%"
        case .balanced:
            "85%"
        case .best:
            "95%"
        }
    }

    nonisolated var compressionQuality: CGFloat {
        switch self {
        case .compact:
            0.7
        case .balanced:
            0.85
        case .best:
            0.95
        }
    }
}

struct ExportOptions: Sendable {
    var pageBackgroundMode: ExportPageBackgroundMode = .original
    var customPageBackground: NoteBackground = .plain()
    var includesThemeArtwork: Bool?
    var pdfQuality: ExportPDFQuality = .best
    var imageResolution: ExportImageResolution = .threeX
    var jpegQuality: ExportJPEGQuality = .best

    nonisolated static let standard = ExportOptions()

    nonisolated func applying(to snapshot: NotePageRenderSnapshot) -> NotePageRenderSnapshot {
        var snapshot = snapshot

        switch pageBackgroundMode {
        case .original:
            break
        case .none:
            snapshot.rendersPageBackground = false
            snapshot.showsBeanArtwork = false
        case .custom:
            snapshot.backgroundStyleRaw = customPageBackground.storageStyleRaw
            snapshot.backgroundColorHex = customPageBackground.colorHex
        }

        if pageBackgroundMode != .none, let includesThemeArtwork {
            snapshot.showsBeanArtwork = includesThemeArtwork
        }

        return snapshot
    }

    nonisolated func renderScale(for format: ExportFormat) -> CGFloat {
        switch format {
        case .pdf:
            pdfQuality.renderScale
        case .png, .jpeg:
            imageResolution.renderScale
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

struct SharedNoteSummary: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var folderID: UUID
    var folderName: String
}

private struct SharedFolderIndex: Codable {
    var folders: [SharedFolderSummary]
    var notes: [SharedNoteSummary]?
    var theme: String?
}

private enum SharedImportMode: String, Codable {
    case notePages
    case attachments
    case newVersion
}

private struct SharedImportRequest: Codable {
    var id: UUID
    var title: String
    var folderID: UUID?
    var targetNoteID: UUID?
    var importMode: SharedImportMode
    var files: [String]
}

private struct SharedImportFailureReport: Codable {
    var failedAt: Date
    var originalDirectoryName: String
    var errorDescription: String
    var recoverySuggestion: String
    var request: SharedImportRequest?
    var filesInRequestDirectory: [String]
}

private enum SharedInboxImportError: LocalizedError {
    case missingRequestManifest
    case noImportableFiles([String])
    case missingVersionTarget
    case invalidVersionFileCount

    var errorDescription: String? {
        switch self {
        case .missingRequestManifest:
            "The shared import request is missing request.json."
        case .noImportableFiles(let fileNames):
            if fileNames.isEmpty {
                "The shared import request did not include any files."
            } else {
                "None of the shared import files could be found: \(fileNames.joined(separator: ", "))"
            }
        case .missingVersionTarget:
            "The note selected for this document version is no longer available."
        case .invalidVersionFileCount:
            "Share exactly one PDF or image when adding a document version."
        }
    }
}

private struct ImportedPageImageFile: Sendable {
    var pageOrder: Int
    var pageSize: CGSize
    var storedImage: StoredFile
    var displayName: String
    var originalFileName: String
}

private struct PDFImportWorkerResult: Sendable {
    var baseName: String
    var originalStored: StoredFile
    var sourceFileName: String
    var sourceFileExtension: String
    var pages: [ImportedPageImageFile]
}

private struct PreviewableDocumentWorkerResult: Sendable {
    var baseName: String
    var sourceFileName: String
    var sourceFileExtension: String
    var originalStored: StoredFile
    var storedPreview: StoredFile
    var pageSize: CGSize
}

private struct StoredImagePageResult: Sendable {
    var storedImage: StoredFile
    var sourceSize: CGSize
    var originalFileName: String
    var displayName: String
}

private enum PreparedDocumentVersion: Sendable {
    case pdf(PDFImportWorkerResult)
    case image(StoredImagePageResult)
}

enum ImportExportError: LocalizedError {
    case unsupportedImageData
    case unsupportedDocument
    case unsupportedVersionDocument
    case originalFileMissing
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedImageData:
            "BeanNotes could not read that image."
        case .unsupportedDocument:
            "BeanNotes could not import that document as note pages."
        case .unsupportedVersionDocument:
            "Document versions must be a PDF or image."
        case .originalFileMissing:
            "The original attachment file is missing from local storage."
        case .exportFailed:
            "BeanNotes could not create the export."
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

    func importsAsDocumentVersion(_ sourceURL: URL) -> Bool {
        let contentType = UTType(filenameExtension: sourceURL.pathExtension) ?? .data
        let kind = attachmentKind(for: contentType, fileExtension: sourceURL.pathExtension)
        return kind == .pdf || kind == .image
    }

    func importDocumentAsNote(
        from sourceURL: URL,
        into folder: NotebookFolder,
        staging: ImportStagingTransaction? = nil,
        progress: ImportExportProgressHandler? = nil
    ) async throws -> ImportedDocumentNote {
        try Task.checkCancellation()
        let ownedStaging = staging == nil ? storage.beginImportStagingTransaction() : nil
        let activeStaging = staging ?? ownedStaging
        let note = NoteDocument(title: sourceURL.deletingPathExtension().lastPathComponent)
        folder.notes.append(note)

        do {
            let imported = try await importDocumentPages(
                from: sourceURL,
                into: note,
                startingAt: 0,
                staging: activeStaging,
                progress: progress
            )
            try Task.checkCancellation()
            if importsAsDocumentVersion(sourceURL) {
                _ = DocumentVersionService(storage: storage).registerImportedVersion(
                    attachments: imported.attachments,
                    named: note.title,
                    in: note
                )
            }
            try ownedStaging?.commit()
            folder.updatedAt = Date()

            return ImportedDocumentNote(
                note: note,
                pages: imported.pages,
                attachments: imported.attachments
            )
        } catch {
            folder.notes.removeAll { $0.id == note.id }
            ownedStaging?.rollback()
            throw error
        }
    }

    func importImageAsNote(_ image: UIImage, named displayName: String, into folder: NotebookFolder) throws -> ImportedDocumentNote {
        let title = URL(fileURLWithPath: displayName).deletingPathExtension().lastPathComponent
        let note = NoteDocument(title: title.isEmpty ? "Photo" : title)
        folder.notes.append(note)

        do {
            let imported = try importImagePage(
                image,
                sourceData: nil,
                originalFileName: displayName,
                displayName: note.title,
                into: note,
                pageOrder: 0
            )
            _ = DocumentVersionService(storage: storage).registerImportedVersion(
                attachments: imported.attachments,
                named: note.title,
                in: note
            )
            folder.updatedAt = Date()

            return ImportedDocumentNote(
                note: note,
                pages: imported.pages,
                attachments: imported.attachments
            )
        } catch {
            folder.notes.removeAll { $0.id == note.id }
            throw error
        }
    }

    func importImageDataAsNote(
        _ data: Data,
        named displayName: String,
        into folder: NotebookFolder,
        staging: ImportStagingTransaction? = nil
    ) async throws -> ImportedDocumentNote {
        try Task.checkCancellation()
        let title = URL(fileURLWithPath: displayName).deletingPathExtension().lastPathComponent
        let note = NoteDocument(title: title.isEmpty ? "Photo" : title)
        folder.notes.append(note)

        do {
            let storedImage = try await Self.storeImageDataInBackground(
                data,
                preferredName: displayName,
                rootURL: storage.rootURL,
                staging: staging
            )
            try Task.checkCancellation()
            let imported = try makeLockedImagePage(
                sourceSize: storedImage.sourceSize,
                storedImage: storedImage.storedImage,
                originalFileName: storedImage.originalFileName,
                displayName: note.title,
                into: note,
                pageOrder: 0
            )
            _ = DocumentVersionService(storage: storage).registerImportedVersion(
                attachments: imported.attachments,
                named: note.title,
                in: note
            )
            folder.updatedAt = Date()

            return ImportedDocumentNote(
                note: note,
                pages: imported.pages,
                attachments: imported.attachments
            )
        } catch {
            folder.notes.removeAll { $0.id == note.id }
            throw error
        }
    }

    func importDocumentPages(
        from sourceURL: URL,
        into note: NoteDocument,
        startingAt startOrder: Int,
        staging: ImportStagingTransaction? = nil,
        progress: ImportExportProgressHandler? = nil
    ) async throws -> ImportedDocumentPages {
        try Task.checkCancellation()
        let contentType = UTType(filenameExtension: sourceURL.pathExtension) ?? .data
        let kind = attachmentKind(for: contentType, fileExtension: sourceURL.pathExtension)

        switch kind {
        case .pdf:
            return try await importPDFPages(
                from: sourceURL,
                into: note,
                startingAt: startOrder,
                staging: staging,
                progress: progress
            )
        case .image:
            progress?(nil, "Importing image...")
            await Task.yield()
            try Task.checkCancellation()
            return try await importImageDocumentPage(from: sourceURL, into: note, pageOrder: startOrder, staging: staging)
        case .codeSnippet, .docx, .csv, .presentation, .other:
            return try await importPreviewableDocumentPage(
                from: sourceURL,
                kind: kind,
                into: note,
                pageOrder: startOrder,
                staging: staging,
                progress: progress
            )
        }
    }

    /// Imports an immutable PDF/image version, then maps its backgrounds onto
    /// existing note pages without replacing their identities, drawings, paper
    /// sizes, or paper styles.
    func importDocumentVersion(
        from sourceURL: URL,
        into note: NoteDocument,
        named proposedName: String? = nil,
        staging: ImportStagingTransaction? = nil,
        progress: ImportExportProgressHandler? = nil
    ) async throws -> NoteDocumentVersion {
        guard importsAsDocumentVersion(sourceURL) else {
            throw ImportExportError.unsupportedVersionDocument
        }

        try Task.checkCancellation()
        let ownedStaging = staging == nil ? storage.beginImportStagingTransaction() : nil
        let activeStaging = staging ?? ownedStaging

        do {
            let preparedVersion = try await prepareDocumentVersion(
                from: sourceURL,
                staging: activeStaging,
                progress: progress
            )
            try Task.checkCancellation()

            // With an owned transaction, finalize files before mutating the live
            // note so a commit failure cannot leave dangling model references.
            try ownedStaging?.commit()

            // Adopt an existing pre-versioning background before attaching the
            // replacement. Otherwise the new unversioned PDF/image can make
            // legacy detection ambiguous and leave both backgrounds visible.
            let versionService = DocumentVersionService(storage: storage)
            _ = versionService.adoptLegacyVersionIfNeeded(in: note)

            let existingPages = note.sortedPages
            let backgroundLayerDate = documentVersionBackgroundLayerDate(in: note)
            let mappedAttachments = attachPreparedDocumentVersion(
                preparedVersion,
                to: note,
                existingPages: existingPages,
                backgroundLayerDate: backgroundLayerDate
            )

            let versionName = proposedName ?? sourceURL.deletingPathExtension().lastPathComponent
            guard let version = versionService.registerImportedVersion(
                attachments: mappedAttachments,
                named: versionName,
                in: note
            ) else {
                throw ImportExportError.unsupportedVersionDocument
            }
            progress?(1, "Version import ready.")
            return version
        } catch {
            ownedStaging?.rollback()
            throw error
        }
    }

    private func prepareDocumentVersion(
        from sourceURL: URL,
        staging: ImportStagingTransaction?,
        progress: ImportExportProgressHandler?
    ) async throws -> PreparedDocumentVersion {
        let contentType = UTType(filenameExtension: sourceURL.pathExtension) ?? .data
        let kind = attachmentKind(for: contentType, fileExtension: sourceURL.pathExtension)

        switch kind {
        case .pdf:
            let result = try await Self.importPDFPagesInBackground(
                from: sourceURL,
                rootURL: storage.rootURL,
                startOrder: 0,
                staging: staging,
                progress: progress
            )
            guard !result.pages.isEmpty else {
                throw ImportExportError.unsupportedDocument
            }
            return .pdf(result)
        case .image:
            progress?(nil, "Importing image...")
            let result = try await Self.storeImageFileInBackground(
                from: sourceURL,
                rootURL: storage.rootURL,
                staging: staging
            )
            return .image(result)
        case .codeSnippet, .docx, .csv, .presentation, .other:
            throw ImportExportError.unsupportedVersionDocument
        }
    }

    private func attachPreparedDocumentVersion(
        _ preparedVersion: PreparedDocumentVersion,
        to note: NoteDocument,
        existingPages: [NotePage],
        backgroundLayerDate: Date
    ) -> [Attachment] {
        switch preparedVersion {
        case .pdf(let result):
            var attachments: [Attachment] = []
            var firstTargetPage: NotePage?

            for (index, pageFile) in result.pages.enumerated() {
                let targetPage = documentVersionTargetPage(
                    at: index,
                    preferredSize: pageFile.pageSize,
                    in: note,
                    existingPages: existingPages
                )
                firstTargetPage = firstTargetPage ?? targetPage

                let background = Attachment(
                    kind: .image,
                    displayName: pageFile.displayName,
                    originalFileName: pageFile.originalFileName,
                    storedFileName: pageFile.storedImage.relativePath,
                    contentTypeIdentifier: UTType.jpeg.identifier,
                    fileExtension: "jpg",
                    x: 0,
                    y: 0,
                    width: targetPage.normalizedWidth,
                    height: targetPage.normalizedHeight,
                    isLocked: true,
                    rendersBehindDrawing: true,
                    vectorSourceStoredFileName: result.originalStored.relativePath,
                    vectorSourcePageIndex: index,
                    createdAt: backgroundLayerDate
                )
                targetPage.attachments.append(background)
                attachments.append(background)
            }

            if let firstTargetPage {
                let original = Attachment(
                    kind: .pdf,
                    displayName: result.baseName,
                    originalFileName: result.sourceFileName,
                    storedFileName: result.originalStored.relativePath,
                    contentTypeIdentifier: result.originalStored.contentTypeIdentifier,
                    fileExtension: result.sourceFileExtension
                )
                firstTargetPage.attachments.append(original)
                attachments.append(original)
            }

            return attachments
        case .image(let result):
            let pageSize = Self.normalizedImagePageSize(for: result.sourceSize)
            let targetPage = documentVersionTargetPage(
                at: 0,
                preferredSize: pageSize,
                in: note,
                existingPages: existingPages
            )
            let image = Attachment(
                kind: .image,
                displayName: result.displayName.isEmpty ? "Image" : result.displayName,
                originalFileName: result.originalFileName,
                storedFileName: result.storedImage.relativePath,
                contentTypeIdentifier: result.storedImage.contentTypeIdentifier,
                fileExtension: URL(fileURLWithPath: result.storedImage.fileName).pathExtension,
                x: 0,
                y: 0,
                width: targetPage.normalizedWidth,
                height: targetPage.normalizedHeight,
                isLocked: true,
                rendersBehindDrawing: true,
                createdAt: backgroundLayerDate
            )
            targetPage.attachments.append(image)
            return [image]
        }
    }

    private func documentVersionBackgroundLayerDate(in note: NoteDocument) -> Date {
        let oldestImageDate = note.pages
            .flatMap(\.attachments)
            .filter { $0.kind == .image }
            .map(\.createdAt)
            .min()
        return oldestImageDate?.addingTimeInterval(-0.001) ?? Date()
    }

    private func documentVersionTargetPage(
        at index: Int,
        preferredSize: CGSize,
        in note: NoteDocument,
        existingPages: [NotePage]
    ) -> NotePage {
        if existingPages.indices.contains(index) {
            return existingPages[index]
        }

        // A replacement can contain more pages than the original document.
        // Those pages still need a canvas, but they must inherit the existing
        // note's paper configuration instead of letting the imported PDF
        // silently change it. There is no drawing to copy for a new page.
        let page: NotePage
        if let templatePage = existingPages.last {
            page = templatePage.makeFollowingPage()
            page.pageOrder = (note.pages.map(\.pageOrder).max() ?? -1) + 1
        } else {
            page = NotePage(
                pageOrder: (note.pages.map(\.pageOrder).max() ?? -1) + 1,
                background: .plain(),
                width: Double(preferredSize.width),
                height: Double(preferredSize.height)
            )
        }
        note.pages.append(page)
        return page
    }

    func importFile(
        from sourceURL: URL,
        into page: NotePage,
        staging: ImportStagingTransaction? = nil
    ) throws -> Attachment {
        try Task.checkCancellation()
        let contentType = UTType(filenameExtension: sourceURL.pathExtension) ?? .data
        let stored = try Self.copyImportFile(
            from: sourceURL,
            rootURL: storage.rootURL,
            staging: staging
        )
        try Task.checkCancellation()
        let kind = attachmentKind(for: contentType, fileExtension: sourceURL.pathExtension)

        var frame = CGRect(
            x: Attachment.defaultX,
            y: Attachment.defaultY,
            width: Attachment.defaultWidth,
            height: Attachment.defaultHeight
        )

        if kind == .image,
           let imageSize = Self.imageSize(at: actualURL(for: stored, staging: staging)) {
            frame = initialImageAttachmentFrame(sourceSize: imageSize, on: page)
        }

        let attachment = Attachment(
            kind: kind,
            displayName: sourceURL.deletingPathExtension().lastPathComponent,
            originalFileName: sourceURL.lastPathComponent,
            storedFileName: stored.relativePath,
            contentTypeIdentifier: stored.contentTypeIdentifier,
            fileExtension: sourceURL.pathExtension,
            x: Double(frame.minX),
            y: Double(frame.minY),
            width: Double(frame.width),
            height: Double(frame.height),
            rendersBehindDrawing: kind == .image ? true : nil
        )

        page.attachments.append(attachment)
        page.touch()
        return attachment
    }

    func importImage(
        _ image: UIImage,
        named fileName: String = "Pasted Image",
        into page: NotePage,
        staging: ImportStagingTransaction? = nil
    ) throws -> Attachment {
        guard let data = image.pngData() else {
            throw ImportExportError.unsupportedImageData
        }

        let baseName = fileName.sanitizedFileName
        let preferredName = baseName.hasSuffix(".png") ? baseName : "\(baseName).png"
        let stored = try Self.saveImportData(
            data,
            preferredName: preferredName,
            contentType: .png,
            rootURL: storage.rootURL,
            staging: staging
        )
        let frame = initialImageAttachmentFrame(sourceSize: image.size, on: page)

        let attachment = Attachment(
            kind: .image,
            displayName: URL(fileURLWithPath: preferredName).deletingPathExtension().lastPathComponent,
            originalFileName: preferredName,
            storedFileName: stored.relativePath,
            contentTypeIdentifier: UTType.png.identifier,
            fileExtension: "png",
            x: Double(frame.minX),
            y: Double(frame.minY),
            width: Double(frame.width),
            height: Double(frame.height),
            rendersBehindDrawing: true
        )

        page.attachments.append(attachment)
        page.touch()
        return attachment
    }

    func importImageData(
        _ data: Data,
        named fileName: String = "Pasted Image",
        into page: NotePage,
        staging: ImportStagingTransaction? = nil
    ) async throws -> Attachment {
        try Task.checkCancellation()
        let storedImage = try await Self.storeImageDataInBackground(
            data,
            preferredName: fileName,
            rootURL: storage.rootURL,
            staging: staging
        )
        try Task.checkCancellation()
        let frame = initialImageAttachmentFrame(sourceSize: storedImage.sourceSize, on: page)

        let attachment = Attachment(
            kind: .image,
            displayName: storedImage.displayName.isEmpty ? "Image" : storedImage.displayName,
            originalFileName: storedImage.originalFileName,
            storedFileName: storedImage.storedImage.relativePath,
            contentTypeIdentifier: storedImage.storedImage.contentTypeIdentifier,
            fileExtension: URL(fileURLWithPath: storedImage.storedImage.fileName).pathExtension,
            x: Double(frame.minX),
            y: Double(frame.minY),
            width: Double(frame.width),
            height: Double(frame.height),
            rendersBehindDrawing: true
        )

        page.attachments.append(attachment)
        page.touch()
        return attachment
    }

    private func initialImageAttachmentFrame(sourceSize: CGSize, on page: NotePage) -> CGRect {
        AttachmentEditingGeometry.initialImageFrame(
            sourceSize: sourceSize,
            pageSize: page.pageSize,
            occupiedFrames: page.visualAttachments.map { $0.normalizedFrame(for: page.pageSize) }
        )
    }

    func exportPage(
        _ page: NotePage,
        format: ExportFormat,
        options: ExportOptions = .standard
    ) async throws -> URL {
        try Task.checkCancellation()
        let snapshot = options.applying(to: NotePageRenderSnapshot(page: page))
        let title = page.note?.title.sanitizedFileName ?? "BeanNotes"
        let fileName = "\(title)-Page-\(page.pageOrder + 1).\(format.fileExtension)"
        let exportDirectory = try storage.directoryURL(for: .exports)
        let exportURL = exportDirectory.appendingPathComponent(storage.uniqueFileName(fileName))

        do {
            try await Self.exportPageSnapshot(
                snapshot,
                format: format,
                rootURL: storage.rootURL,
                exportURL: exportURL,
                renderScale: options.renderScale(for: format),
                jpegCompressionQuality: options.jpegQuality.compressionQuality
            )
        } catch {
            try? storage.fileManager.removeItem(at: exportURL)
            throw error
        }
        return exportURL
    }

    func exportNote(
        _ note: NoteDocument,
        format: ExportFormat,
        options: ExportOptions = .standard
    ) async throws -> [URL] {
        let pages = note.sortedPages
        guard !pages.isEmpty else { throw ImportExportError.exportFailed }
        let snapshots = pages.map { options.applying(to: NotePageRenderSnapshot(page: $0)) }

        switch format {
        case .pdf:
            let title = note.title.sanitizedFileName
            let exportDirectory = try storage.directoryURL(for: .exports)
            let exportURL = exportDirectory.appendingPathComponent(storage.uniqueFileName("\(title).pdf"))
            do {
                try await Self.writePDF(
                    snapshots: snapshots,
                    title: title,
                    rootURL: storage.rootURL,
                    exportURL: exportURL,
                    renderScale: options.pdfQuality.renderScale
                )
            } catch {
                try? storage.fileManager.removeItem(at: exportURL)
                throw error
            }
            return [exportURL]
        case .png, .jpeg:
            var urls: [URL] = []
            var currentExportURL: URL?
            do {
                for snapshot in snapshots {
                    try Task.checkCancellation()
                    let title = note.title.sanitizedFileName
                    let fileName = "\(title)-Page-\(snapshot.pageOrder + 1).\(format.fileExtension)"
                    let exportDirectory = try storage.directoryURL(for: .exports)
                    let exportURL = exportDirectory.appendingPathComponent(storage.uniqueFileName(fileName))
                    currentExportURL = exportURL
                    try await Self.exportPageSnapshot(
                        snapshot,
                        format: format,
                        rootURL: storage.rootURL,
                        exportURL: exportURL,
                        renderScale: options.imageResolution.renderScale,
                        jpegCompressionQuality: options.jpegQuality.compressionQuality
                    )
                    urls.append(exportURL)
                    currentExportURL = nil
                }
            } catch {
                if let currentExportURL {
                    removeExportFiles([currentExportURL])
                }
                removeExportFiles(urls)
                throw error
            }
            return urls
        }
    }

    func exportPageForSharing(
        _ page: NotePage,
        format: ExportFormat,
        options: ExportOptions = .standard,
        progress: ImportExportProgressHandler? = nil
    ) async throws -> URL {
        try Task.checkCancellation()
        progress?(0.05, "Preparing page...")
        await Task.yield()
        try Task.checkCancellation()

        let snapshot = options.applying(to: NotePageRenderSnapshot(page: page))
        let title = page.note?.title.sanitizedFileName ?? "BeanNotes"
        let fileName = "\(title)-Page-\(page.pageOrder + 1).\(format.fileExtension)"
        let exportDirectory = try storage.directoryURL(for: .exports)
        let exportURL = exportDirectory.appendingPathComponent(storage.uniqueFileName(fileName))

        do {
            try await Self.exportPageSnapshot(
                snapshot,
                format: format,
                rootURL: storage.rootURL,
                exportURL: exportURL,
                renderScale: options.renderScale(for: format),
                jpegCompressionQuality: options.jpegQuality.compressionQuality,
                progress: { fraction, message in
                    guard let fraction else {
                        progress?(nil, message)
                        return
                    }
                    progress?(0.1 + fraction * 0.85, message)
                }
            )
        } catch {
            try? storage.fileManager.removeItem(at: exportURL)
            throw error
        }

        progress?(1, "Export ready.")
        return exportURL
    }

    func exportNoteForSharing(
        _ note: NoteDocument,
        format: ExportFormat,
        options: ExportOptions = .standard,
        progress: ImportExportProgressHandler? = nil
    ) async throws -> [URL] {
        let pages = note.sortedPages
        guard !pages.isEmpty else { throw ImportExportError.exportFailed }
        let snapshots = pages.map { options.applying(to: NotePageRenderSnapshot(page: $0)) }

        switch format {
        case .pdf:
            let title = note.title.sanitizedFileName
            let exportDirectory = try storage.directoryURL(for: .exports)
            let exportURL = exportDirectory.appendingPathComponent(storage.uniqueFileName("\(title).pdf"))
            do {
                try await Self.writePDF(
                    snapshots: snapshots,
                    title: title,
                    rootURL: storage.rootURL,
                    exportURL: exportURL,
                    renderScale: options.pdfQuality.renderScale,
                    progress: progress
                )
            } catch {
                try? storage.fileManager.removeItem(at: exportURL)
                throw error
            }
            progress?(1, "Export ready.")
            return [exportURL]
        case .png, .jpeg:
            var urls: [URL] = []
            var currentExportURL: URL?
            let total = max(snapshots.count, 1)

            do {
                for (index, snapshot) in snapshots.enumerated() {
                    try Task.checkCancellation()
                    let baseProgress = Double(index) / Double(total)
                    progress?(baseProgress, "Exporting page \(index + 1) of \(total)...")
                    await Task.yield()
                    try Task.checkCancellation()

                    let fileName = "\(note.title.sanitizedFileName)-Page-\(snapshot.pageOrder + 1).\(format.fileExtension)"
                    let exportDirectory = try storage.directoryURL(for: .exports)
                    let exportURL = exportDirectory.appendingPathComponent(storage.uniqueFileName(fileName))
                    currentExportURL = exportURL
                    try await Self.exportPageSnapshot(
                        snapshot,
                        format: format,
                        rootURL: storage.rootURL,
                        exportURL: exportURL,
                        renderScale: options.imageResolution.renderScale,
                        jpegCompressionQuality: options.jpegQuality.compressionQuality,
                        progress: { fraction, message in
                            guard let fraction else {
                                progress?(nil, message)
                                return
                            }
                            let overallFraction = (Double(index) + fraction) / Double(total)
                            progress?(
                                overallFraction,
                                "\(message) Page \(index + 1) of \(total)."
                            )
                        }
                    )
                    urls.append(exportURL)
                    currentExportURL = nil
                    progress?((Double(index) + 1) / Double(total), "Exported page \(index + 1) of \(total).")
                }
            } catch {
                if let currentExportURL {
                    removeExportFiles([currentExportURL])
                }
                removeExportFiles(urls)
                throw error
            }

            progress?(1, "Export ready.")
            return urls
        }
    }

    func originalFileURL(for attachment: Attachment) throws -> URL {
        let url = try storage.validatedURL(forRelativePath: attachment.storedFileName)
        guard storage.fileManager.fileExists(atPath: url.path) else {
            throw ImportExportError.originalFileMissing
        }
        return url
    }

    func removeTemporaryExportFiles(_ urls: [URL]) {
        removeExportFiles(urls)
    }

    private func removeExportFiles(_ urls: [URL]) {
        for url in urls {
            try? storage.fileManager.removeItem(at: url)
        }
    }

    func writeSharedFolderIndex(folders: [NotebookFolder]) throws {
        guard let indexURL = LocalStorageService.sharedFolderIndexURL(fileManager: storage.fileManager) else {
            return
        }

        let index = SharedFolderIndex(
            folders: folders
                .filter { !$0.isArchived }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map {
                    SharedFolderSummary(
                        id: $0.id,
                        name: $0.name,
                        colorHex: $0.colorHex
                    )
                },
            notes: folders
                .filter { !$0.isArchived }
                .flatMap { folder in
                    folder.notes.compactMap { note -> SharedNoteSummary? in
                        guard !note.isInTrash, supportsDocumentVersions(note) else { return nil }
                        let trimmedTitle = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        return SharedNoteSummary(
                            id: note.id,
                            title: trimmedTitle.isEmpty ? "Untitled Note" : trimmedTitle,
                            folderID: folder.id,
                            folderName: folder.name
                        )
                    }
                }
                .sorted { lhs, rhs in
                    if lhs.folderName == rhs.folderName {
                        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                    }
                    return lhs.folderName.localizedCaseInsensitiveCompare(rhs.folderName) == .orderedAscending
                },
            theme: UserDefaults.standard.string(forKey: BeanNotesTheme.storageKey)
        )
        let data = try JSONEncoder().encode(index)
        try storage.fileManager.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: indexURL, options: [.atomic])
    }

    private func supportsDocumentVersions(_ note: NoteDocument) -> Bool {
        let attachments = note.pages.flatMap(\.attachments)
        if attachments.contains(where: { $0.documentVersionID != nil }) {
            return true
        }
        let vectorSourcePaths = Set(attachments.compactMap { attachment -> String? in
            guard attachment.documentVersionID == nil,
                  attachment.kind == .image,
                  attachment.isLocked,
                  attachment.rendersBehindDrawing,
                  let sourcePath = attachment.vectorSourceStoredFileName?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !sourcePath.isEmpty else {
                return nil
            }
            return sourcePath
        })
        if vectorSourcePaths.count == 1 {
            return true
        }

        guard note.sortedPages.count == 1, let page = note.sortedPages.first else { return false }
        return page.attachments.contains { attachment in
            guard attachment.kind == .image,
                  attachment.isLocked,
                  attachment.rendersBehindDrawing else {
                return false
            }
            let frame = attachment.normalizedFrame(for: page.pageSize)
            return abs(frame.minX) < 0.5
                && abs(frame.minY) < 0.5
                && abs(frame.width - page.pageSize.width) < 0.5
                && abs(frame.height - page.pageSize.height) < 0.5
        }
    }

    func absorbSharedInbox(into modelContext: ModelContext) async throws {
        guard let inboxURL = LocalStorageService.sharedInboxURL(fileManager: storage.fileManager) else {
            return
        }

        try storage.fileManager.createDirectory(at: inboxURL, withIntermediateDirectories: true)

        try modelContext.save()
        _ = try await absorbSharedImportRequests(from: inboxURL, into: modelContext)
        _ = try await absorbLooseSharedFiles(from: inboxURL, into: modelContext)
    }

    private func absorbLooseSharedFiles(
        from inboxURL: URL,
        into modelContext: ModelContext
    ) async throws -> Bool {
        let staging = storage.beginImportStagingTransaction()
        var importedSourceURLs: [URL] = []
        var didSave = false

        do {
            let sharedFiles = try storage.fileManager.contentsOfDirectory(
                at: inboxURL,
                includingPropertiesForKeys: nil
            )
            .filter { !$0.hasDirectoryPath }
            .filter { $0.pathExtension.lowercased() != "json" }

            var didImport = false

            if !sharedFiles.isEmpty {
                let inboxFolder = try ensureInboxFolder(in: modelContext)

                for fileURL in sharedFiles {
                    _ = try await importDocumentAsNote(
                        from: fileURL,
                        into: inboxFolder,
                        staging: staging
                    )

                    importedSourceURLs.append(fileURL)
                    didImport = true
                }
            }

            guard didImport else {
                staging.rollback()
                return false
            }

            try modelContext.save()
            didSave = true
            try staging.commit()

            for sourceURL in importedSourceURLs {
                try? storage.fileManager.removeItem(at: sourceURL)
            }

            return true
        } catch {
            if !didSave {
                modelContext.rollback()
                staging.rollback()
            }
            throw error
        }
    }

    private func absorbSharedImportRequests(
        from inboxURL: URL,
        into modelContext: ModelContext
    ) async throws -> Bool {
        let requestsURL = inboxURL.appendingPathComponent("Requests", isDirectory: true)
        guard storage.fileManager.fileExists(atPath: requestsURL.path) else { return false }

        let requestDirectories = try storage.fileManager.contentsOfDirectory(
            at: requestsURL,
            includingPropertiesForKeys: nil
        )
        .filter(\.hasDirectoryPath)

        var didImport = false

        for requestDirectory in requestDirectories {
            do {
                try await absorbSharedImportRequestDirectory(requestDirectory, into: modelContext)
                didImport = true
            } catch {
                modelContext.rollback()
                try? quarantineSharedImportRequest(requestDirectory, inboxURL: inboxURL, error: error)
            }
        }

        return didImport
    }

    private func absorbSharedImportRequestDirectory(
        _ requestDirectory: URL,
        into modelContext: ModelContext
    ) async throws {
        let requestURL = requestDirectory.appendingPathComponent("request.json")
        guard storage.fileManager.fileExists(atPath: requestURL.path) else {
            throw SharedInboxImportError.missingRequestManifest
        }

        let request = try JSONDecoder().decode(
            SharedImportRequest.self,
            from: try Data(contentsOf: requestURL)
        )
        let fileURLs = request.files
            .map { requestDirectory.appendingPathComponent($0) }
            .filter { storage.fileManager.fileExists(atPath: $0.path) }

        guard !fileURLs.isEmpty else {
            throw SharedInboxImportError.noImportableFiles(request.files)
        }

        let staging = storage.beginImportStagingTransaction()
        var didCommitStaging = false

        do {
            if request.importMode == .newVersion {
                try await importSharedVersionRequest(
                    request,
                    fileURLs: fileURLs,
                    in: modelContext,
                    staging: staging
                )
            } else {
                let folder = try folder(for: request.folderID, in: modelContext)
                try await importSharedRequest(
                    request,
                    fileURLs: fileURLs,
                    into: folder,
                    staging: staging
                )
            }
            try staging.commit()
            didCommitStaging = true
            try modelContext.save()
            try? storage.fileManager.removeItem(at: requestDirectory)
        } catch {
            if didCommitStaging {
                try? storage.fileManager.removeItem(at: staging.finalDirectoryURL)
            } else {
                staging.rollback()
            }
            throw error
        }
    }

    private func quarantineSharedImportRequest(_ requestDirectory: URL, inboxURL: URL, error: Error) throws {
        guard storage.fileManager.fileExists(atPath: requestDirectory.path) else {
            return
        }

        let failedRootURL = inboxURL.appendingPathComponent("Failed", isDirectory: true)
        try storage.fileManager.createDirectory(at: failedRootURL, withIntermediateDirectories: true)

        let fileNames = (try? storage.fileManager.contentsOfDirectory(
            at: requestDirectory,
            includingPropertiesForKeys: nil
        ))?
            .map(\.lastPathComponent)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } ?? []
        let request = try? JSONDecoder().decode(
            SharedImportRequest.self,
            from: Data(contentsOf: requestDirectory.appendingPathComponent("request.json"))
        )

        let destinationURL = uniqueFailedSharedRequestURL(
            for: requestDirectory.lastPathComponent,
            in: failedRootURL
        )
        try storage.fileManager.moveItem(at: requestDirectory, to: destinationURL)

        let report = SharedImportFailureReport(
            failedAt: Date(),
            originalDirectoryName: requestDirectory.lastPathComponent,
            errorDescription: readableErrorDescription(error),
            recoverySuggestion: "The original shared files were preserved here. Re-share them after checking that each file is still available.",
            request: request,
            filesInRequestDirectory: fileNames
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: destinationURL.appendingPathComponent("failure.json"), options: [.atomic])
    }

    private func uniqueFailedSharedRequestURL(for directoryName: String, in failedRootURL: URL) -> URL {
        let baseName = directoryName.sanitizedFileName
        var destinationURL = failedRootURL.appendingPathComponent(baseName, isDirectory: true)

        while storage.fileManager.fileExists(atPath: destinationURL.path) {
            destinationURL = failedRootURL.appendingPathComponent("\(baseName)-\(UUID().uuidString)", isDirectory: true)
        }

        return destinationURL
    }

    private func readableErrorDescription(_ error: Error) -> String {
        let description = (error as NSError).localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? "Unknown import error" : description
    }

    private func importSharedRequest(
        _ request: SharedImportRequest,
        fileURLs: [URL],
        into folder: NotebookFolder,
        staging: ImportStagingTransaction
    ) async throws {
        let noteTitle = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = fileURLs.first?.deletingPathExtension().lastPathComponent ?? "Shared Import"
        let note = NoteDocument(title: noteTitle.isEmpty ? fallbackTitle : noteTitle)
        folder.notes.append(note)

        switch request.importMode {
        case .notePages:
            try await importSharedFilesAsPages(fileURLs, into: note, staging: staging)
        case .attachments:
            try importSharedFilesAsAttachments(fileURLs, into: note, staging: staging)
        case .newVersion:
            throw SharedInboxImportError.missingVersionTarget
        }

        if note.pages.isEmpty {
            let page = NotePage(pageOrder: 0)
            note.pages.append(page)
        }

        note.touch()
    }

    private func importSharedVersionRequest(
        _ request: SharedImportRequest,
        fileURLs: [URL],
        in modelContext: ModelContext,
        staging: ImportStagingTransaction
    ) async throws {
        guard fileURLs.count == 1, let sourceURL = fileURLs.first else {
            throw SharedInboxImportError.invalidVersionFileCount
        }
        guard importsAsDocumentVersion(sourceURL) else {
            throw ImportExportError.unsupportedVersionDocument
        }
        guard let targetNoteID = request.targetNoteID else {
            throw SharedInboxImportError.missingVersionTarget
        }

        let notes = try modelContext.fetch(FetchDescriptor<NoteDocument>())
        guard let note = notes.first(where: { $0.id == targetNoteID && !$0.isInTrash }) else {
            throw SharedInboxImportError.missingVersionTarget
        }

        let proposedName = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await importDocumentVersion(
            from: sourceURL,
            into: note,
            named: proposedName.isEmpty ? nil : proposedName,
            staging: staging
        )
        note.touch()
    }

    private func importSharedFilesAsPages(
        _ fileURLs: [URL],
        into note: NoteDocument,
        staging: ImportStagingTransaction
    ) async throws {
        var attachmentPage: NotePage?

        for fileURL in fileURLs {
            let retainedStagedFiles = staging.stagedFileNames()
            do {
                let nextOrder = (note.pages.map(\.pageOrder).max() ?? -1) + 1
                let imported = try await importDocumentPages(
                    from: fileURL,
                    into: note,
                    startingAt: nextOrder,
                    staging: staging
                )
                if fileURLs.count == 1, importsAsDocumentVersion(fileURL) {
                    _ = DocumentVersionService(storage: storage).registerImportedVersion(
                        attachments: imported.attachments,
                        named: note.title,
                        in: note
                    )
                }
            } catch {
                staging.removeStagedFiles(excluding: retainedStagedFiles)

                let page = attachmentPage ?? {
                    let page = NotePage(pageOrder: (note.pages.map(\.pageOrder).max() ?? -1) + 1)
                    note.pages.append(page)
                    attachmentPage = page
                    return page
                }()
                _ = try importFile(from: fileURL, into: page, staging: staging)
            }
        }
    }

    private func importSharedFilesAsAttachments(
        _ fileURLs: [URL],
        into note: NoteDocument,
        staging: ImportStagingTransaction
    ) throws {
        let page = NotePage(pageOrder: 0)
        note.pages.append(page)

        for fileURL in fileURLs {
            _ = try importFile(from: fileURL, into: page, staging: staging)
        }
    }

    private func folder(for folderID: UUID?, in modelContext: ModelContext) throws -> NotebookFolder {
        let folders = try modelContext.fetch(FetchDescriptor<NotebookFolder>())

        if let folderID,
           let folder = folders.first(where: { $0.id == folderID && !$0.isArchived }) {
            return folder
        }

        return try ensureInboxFolder(in: modelContext)
    }

    private func ensureInboxFolder(in modelContext: ModelContext) throws -> NotebookFolder {
        let folders = try modelContext.fetch(FetchDescriptor<NotebookFolder>())

        if let inbox = folders.first(where: { $0.name == "Inbox" && !$0.isArchived }) {
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
        startingAt startOrder: Int,
        staging: ImportStagingTransaction?,
        progress: ImportExportProgressHandler?
    ) async throws -> ImportedDocumentPages {
        let result = try await Self.importPDFPagesInBackground(
            from: sourceURL,
            rootURL: storage.rootURL,
            startOrder: startOrder,
            staging: staging,
            progress: progress
        )
        try Task.checkCancellation()
        var importedPages: [NotePage] = []
        var importedAttachments: [Attachment] = []

        for pageFile in result.pages {
            try Task.checkCancellation()
            let notePage = NotePage(
                pageOrder: pageFile.pageOrder,
                background: .plain(),
                width: Double(pageFile.pageSize.width),
                height: Double(pageFile.pageSize.height)
            )
            let pageImageAttachment = Attachment(
                kind: .image,
                displayName: pageFile.displayName,
                originalFileName: pageFile.originalFileName,
                storedFileName: pageFile.storedImage.relativePath,
                contentTypeIdentifier: UTType.jpeg.identifier,
                fileExtension: "jpg",
                x: 0,
                y: 0,
                width: Double(pageFile.pageSize.width),
                height: Double(pageFile.pageSize.height),
                isLocked: true,
                rendersBehindDrawing: true,
                vectorSourceStoredFileName: result.originalStored.relativePath,
                vectorSourcePageIndex: pageFile.pageOrder - startOrder
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
            displayName: result.baseName,
            originalFileName: result.sourceFileName,
            storedFileName: result.originalStored.relativePath,
            contentTypeIdentifier: result.originalStored.contentTypeIdentifier,
            fileExtension: result.sourceFileExtension
        )
        firstPage.attachments.append(originalAttachment)
        importedAttachments.append(originalAttachment)
        note.touch()
        progress?(1, "PDF import ready.")

        return ImportedDocumentPages(pages: importedPages, attachments: importedAttachments)
    }

    private func importPreviewableDocumentPage(
        from sourceURL: URL,
        kind: AttachmentKind,
        into note: NoteDocument,
        pageOrder: Int,
        staging: ImportStagingTransaction?,
        progress: ImportExportProgressHandler?
    ) async throws -> ImportedDocumentPages {
        progress?(0.1, "Copying original file...")
        await Task.yield()
        try Task.checkCancellation()

        let result = try await Self.importPreviewableDocumentInBackground(
            from: sourceURL,
            rootURL: storage.rootURL,
            staging: staging,
            progress: progress
        )
        try Task.checkCancellation()

        let page = NotePage(
            pageOrder: pageOrder,
            background: .plain(),
            width: Double(result.pageSize.width),
            height: Double(result.pageSize.height)
        )
        let previewAttachment = Attachment(
            kind: .image,
            displayName: "\(result.baseName) Preview",
            originalFileName: "\(result.baseName)-preview.jpg",
            storedFileName: result.storedPreview.relativePath,
            contentTypeIdentifier: UTType.jpeg.identifier,
            fileExtension: "jpg",
            x: 0,
            y: 0,
            width: Double(result.pageSize.width),
            height: Double(result.pageSize.height),
            isLocked: true,
            rendersBehindDrawing: true
        )
        let originalAttachment = Attachment(
            kind: kind,
            displayName: result.baseName,
            originalFileName: result.sourceFileName,
            storedFileName: result.originalStored.relativePath,
            contentTypeIdentifier: result.originalStored.contentTypeIdentifier,
            fileExtension: result.sourceFileExtension
        )

        page.attachments.append(previewAttachment)
        note.pages.append(page)
        page.attachments.append(originalAttachment)
        note.touch()
        progress?(1, "Document import ready.")

        return ImportedDocumentPages(
            pages: [page],
            attachments: [previewAttachment, originalAttachment]
        )
    }

    private func importImageDocumentPage(
        from sourceURL: URL,
        into note: NoteDocument,
        pageOrder: Int,
        staging: ImportStagingTransaction?
    ) async throws -> ImportedDocumentPages {
        let result = try await Self.storeImageFileInBackground(
            from: sourceURL,
            rootURL: storage.rootURL,
            staging: staging
        )
        try Task.checkCancellation()

        return try makeLockedImagePage(
            sourceSize: result.sourceSize,
            storedImage: result.storedImage,
            originalFileName: result.originalFileName,
            displayName: result.displayName,
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
            sourceSize: image.size,
            storedImage: storedImage,
            originalFileName: sanitizedOriginal,
            displayName: displayName,
            into: note,
            pageOrder: pageOrder
        )
    }

    private func makeLockedImagePage(
        sourceSize: CGSize,
        storedImage: StoredFile,
        originalFileName: String,
        displayName: String,
        into note: NoteDocument,
        pageOrder: Int
    ) throws -> ImportedDocumentPages {
        let pageSize = Self.normalizedImagePageSize(for: sourceSize)
        let page = NotePage(
            pageOrder: pageOrder,
            background: .plain(),
            width: Double(pageSize.width),
            height: Double(pageSize.height)
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
            rendersBehindDrawing: true
        )

        page.attachments.append(imageAttachment)
        note.pages.append(page)
        note.touch()

        return ImportedDocumentPages(pages: [page], attachments: [imageAttachment])
    }

    private func actualURL(for storedFile: StoredFile, staging: ImportStagingTransaction?) -> URL {
        Self.actualURL(for: storedFile, rootURL: storage.rootURL, staging: staging)
    }

    nonisolated private static func copyImportFile(
        from sourceURL: URL,
        rootURL: URL,
        staging: ImportStagingTransaction?
    ) throws -> StoredFile {
        if let staging {
            return try staging.copyFile(from: sourceURL)
        }

        return try LocalStorageService(rootURL: rootURL).copyFile(from: sourceURL, to: .imports)
    }

    nonisolated private static func saveImportData(
        _ data: Data,
        preferredName: String,
        contentType: UTType,
        rootURL: URL,
        staging: ImportStagingTransaction?
    ) throws -> StoredFile {
        if let staging {
            return try staging.saveData(data, preferredName: preferredName, contentType: contentType)
        }

        return try LocalStorageService(rootURL: rootURL).saveData(
            data,
            preferredName: preferredName,
            contentType: contentType,
            to: .imports
        )
    }

    nonisolated private static func actualURL(
        for storedFile: StoredFile,
        rootURL: URL,
        staging: ImportStagingTransaction?
    ) -> URL {
        if let staging {
            return staging.url(for: storedFile)
        }

        return LocalStorageService(rootURL: rootURL).url(forRelativePath: storedFile.relativePath)
    }

    nonisolated private static func importPDFPagesInBackground(
        from sourceURL: URL,
        rootURL: URL,
        startOrder: Int,
        staging: ImportStagingTransaction?,
        progress: ImportExportProgressHandler?
    ) async throws -> PDFImportWorkerResult {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { () async throws -> PDFImportWorkerResult in
            let isScoped = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if isScoped {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            guard let document = CGPDFDocument(sourceURL as CFURL), document.numberOfPages > 0 else {
                throw ImportExportError.unsupportedDocument
            }

            try Task.checkCancellation()
            let baseName = sourceURL.deletingPathExtension().lastPathComponent
            let originalStored = try copyImportFile(from: sourceURL, rootURL: rootURL, staging: staging)
            try Task.checkCancellation()
            var pages: [ImportedPageImageFile] = []
            let total = document.numberOfPages

            for index in 0..<total {
                try Task.checkCancellation()
                await MainActor.run {
                    progress?(Double(index) / Double(total), "Importing PDF page \(index + 1) of \(total)...")
                }

                guard let pdfPage = document.page(at: index + 1) else { continue }
                let displayedSize = displayedPDFPageSize(for: pdfPage)
                let pageSize = normalizedPDFPageSize(for: displayedSize)
                let storedImage = try autoreleasepool { () throws -> StoredFile in
                    try Task.checkCancellation()
                    guard let imageData = renderPDFPageJPEGData(
                        pdfPage,
                        displayedSize: displayedSize,
                        compressionQuality: 0.82
                    ) else {
                        throw ImportExportError.exportFailed
                    }
                    try Task.checkCancellation()

                    let storedImage = try saveImportData(
                        imageData,
                        preferredName: "\(baseName)-page-\(index + 1).jpg",
                        contentType: .jpeg,
                        rootURL: rootURL,
                        staging: staging
                    )
                    try Task.checkCancellation()
                    return storedImage
                }

                pages.append(
                    ImportedPageImageFile(
                        pageOrder: startOrder + index,
                        pageSize: pageSize,
                        storedImage: storedImage,
                        displayName: "\(baseName) Page \(index + 1)",
                        originalFileName: "\(baseName)-page-\(index + 1).jpg"
                    )
                )
            }

            await MainActor.run {
                progress?(1, "PDF import ready.")
            }

            return PDFImportWorkerResult(
                baseName: baseName,
                originalStored: originalStored,
                sourceFileName: sourceURL.lastPathComponent,
                sourceFileExtension: sourceURL.pathExtension,
                pages: pages
            )
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated private static func importPreviewableDocumentInBackground(
        from sourceURL: URL,
        rootURL: URL,
        staging: ImportStagingTransaction?,
        progress: ImportExportProgressHandler?
    ) async throws -> PreviewableDocumentWorkerResult {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { () async throws -> PreviewableDocumentWorkerResult in
            try Task.checkCancellation()
            let pageSize = CGSize(width: 1024, height: 1366)
            let baseName = sourceURL.deletingPathExtension().lastPathComponent
            let originalStored = try copyImportFile(from: sourceURL, rootURL: rootURL, staging: staging)
            try Task.checkCancellation()
            let originalURL = actualURL(for: originalStored, rootURL: rootURL, staging: staging)

            await MainActor.run {
                progress?(0.35, "Building preview...")
            }
            try Task.checkCancellation()

            let fastPreviewData = await MainActor.run {
                makeFastTextPreviewPage(
                    for: originalURL,
                    fileExtension: sourceURL.pathExtension,
                    title: baseName,
                    pageSize: pageSize
                )?.jpegData(compressionQuality: 0.9)
            }
            let imageData: Data

            if let fastPreviewData {
                imageData = fastPreviewData
            } else {
                try Task.checkCancellation()
                let previewThumbnail = try? await quickLookThumbnail(for: originalURL, size: pageSize)
                try Task.checkCancellation()
                guard let previewData = await MainActor.run(body: {
                    makeDocumentPreviewPage(
                        thumbnail: previewThumbnail,
                        title: baseName,
                        fileExtension: sourceURL.pathExtension,
                        pageSize: pageSize
                    ).jpegData(compressionQuality: 0.9)
                }) else {
                    throw ImportExportError.exportFailed
                }
                imageData = previewData
            }
            try Task.checkCancellation()

            await MainActor.run {
                progress?(0.75, "Saving preview...")
            }

            let storedPreview = try saveImportData(
                imageData,
                preferredName: "\(baseName)-preview.jpg",
                contentType: .jpeg,
                rootURL: rootURL,
                staging: staging
            )
            try Task.checkCancellation()

            return PreviewableDocumentWorkerResult(
                baseName: baseName,
                sourceFileName: sourceURL.lastPathComponent,
                sourceFileExtension: sourceURL.pathExtension,
                originalStored: originalStored,
                storedPreview: storedPreview,
                pageSize: pageSize
            )
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated private static func storeImageFileInBackground(
        from sourceURL: URL,
        rootURL: URL,
        staging: ImportStagingTransaction?
    ) async throws -> StoredImagePageResult {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { () throws -> StoredImagePageResult in
            try Task.checkCancellation()
            let storedImage = try copyImportFile(from: sourceURL, rootURL: rootURL, staging: staging)
            try Task.checkCancellation()
            let storedURL = actualURL(for: storedImage, rootURL: rootURL, staging: staging)

            guard let imageSize = imageSize(at: storedURL) else {
                throw ImportExportError.unsupportedImageData
            }

            return StoredImagePageResult(
                storedImage: storedImage,
                sourceSize: imageSize,
                originalFileName: sourceURL.lastPathComponent,
                displayName: sourceURL.deletingPathExtension().lastPathComponent
            )
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated private static func storeImageDataInBackground(
        _ data: Data,
        preferredName: String,
        rootURL: URL,
        staging: ImportStagingTransaction?
    ) async throws -> StoredImagePageResult {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { () throws -> StoredImagePageResult in
            try Task.checkCancellation()
            guard let imageSize = imageSize(in: data) else {
                throw ImportExportError.unsupportedImageData
            }
            try Task.checkCancellation()

            let sanitizedName = preferredName.sanitizedFileName
            let preferredURL = URL(fileURLWithPath: sanitizedName)
            let contentType = imageContentType(for: data, fallbackExtension: preferredURL.pathExtension)
            let fileExtension = contentType.preferredFilenameExtension
                ?? (preferredURL.pathExtension.isEmpty ? "png" : preferredURL.pathExtension)
            let baseName = preferredURL.deletingPathExtension().lastPathComponent
            let storedImage = try saveImportData(
                data,
                preferredName: "\(baseName).\(fileExtension)",
                contentType: contentType,
                rootURL: rootURL,
                staging: staging
            )
            try Task.checkCancellation()

            return StoredImagePageResult(
                storedImage: storedImage,
                sourceSize: imageSize,
                originalFileName: "\(baseName).\(fileExtension)",
                displayName: baseName
            )
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated private static func exportPageSnapshot(
        _ snapshot: NotePageRenderSnapshot,
        format: ExportFormat,
        rootURL: URL,
        exportURL: URL,
        renderScale: CGFloat,
        jpegCompressionQuality: CGFloat,
        progress: ImportExportProgressHandler? = nil
    ) async throws {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { () async throws -> Void in
            let stagedURL = stagedExportURL(for: exportURL)
            defer { try? FileManager.default.removeItem(at: stagedURL) }

            try Task.checkCancellation()
            await progress?(0.12, "Loading page data...")
            await Task.yield()
            let drawing = try autoreleasepool {
                try ThumbnailService.loadDrawingForExport(
                    fileName: snapshot.drawingFileName,
                    rootURL: rootURL
                )
            }
            try Task.checkCancellation()
            await progress?(0.38, "Rendering page...")
            await Task.yield()
            let image = try autoreleasepool {
                try ThumbnailService.renderPageImageForExport(
                    snapshot: snapshot,
                    drawing: drawing,
                    rootURL: rootURL,
                    scale: renderScale,
                    usesOpaqueBackground: format != .png
                )
            }
            try Task.checkCancellation()
            await progress?(0.78, "Writing \(format.label)...")
            await Task.yield()

            try autoreleasepool {
                switch format {
                case .png:
                    guard let data = image.pngData() else { throw ImportExportError.exportFailed }
                    try Task.checkCancellation()
                    try data.write(to: stagedURL, options: [.atomic])
                    try validateImage(at: stagedURL, expectedType: .png, expectedImage: image)
                case .jpeg:
                    guard let data = image.jpegData(compressionQuality: jpegCompressionQuality) else {
                        throw ImportExportError.exportFailed
                    }
                    try Task.checkCancellation()
                    try data.write(to: stagedURL, options: [.atomic])
                    try validateImage(at: stagedURL, expectedType: .jpeg, expectedImage: image)
                case .pdf:
                    try writePDFImage(image, pageSize: snapshot.pageSize, exportURL: stagedURL)
                    try validatePDF(at: stagedURL, expectedPageSizes: [snapshot.pageSize])
                }
            }
            try Task.checkCancellation()
            await progress?(0.94, "Finalizing export...")
            await Task.yield()
            try autoreleasepool {
                try commitStagedExport(at: stagedURL, to: exportURL)
            }
            try Task.checkCancellation()
        }

        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated private static func writePDF(
        snapshots: [NotePageRenderSnapshot],
        title: String,
        rootURL: URL,
        exportURL: URL,
        renderScale: CGFloat,
        progress: ImportExportProgressHandler? = nil
    ) async throws {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { () async throws -> Void in
            guard let firstSnapshot = snapshots.first else {
                throw ImportExportError.exportFailed
            }
            let stagedURL = stagedExportURL(for: exportURL)
            defer { try? FileManager.default.removeItem(at: stagedURL) }

            let format = UIGraphicsPDFRendererFormat()
            format.documentInfo = [
                kCGPDFContextCreator as String: "BeanNotes",
                kCGPDFContextTitle as String: title
            ]

            let renderer = UIGraphicsPDFRenderer(
                bounds: CGRect(origin: .zero, size: firstSnapshot.pageSize),
                format: format
            )

            let total = max(snapshots.count, 1)
            await MainActor.run {
                progress?(0.04, "Preparing \(total == 1 ? "page" : "pages")...")
            }
            await Task.yield()

            var renderError: Error?
            try renderer.writePDF(to: stagedURL) { context in
                for (index, snapshot) in snapshots.enumerated() {
                    if Task.isCancelled || renderError != nil { return }

                    let pageNumber = index + 1
                    let preparingFraction = (Double(index) + 0.1) / Double(total)
                    Task { @MainActor in
                        progress?(preparingFraction, "Rendering page \(pageNumber) of \(total)...")
                    }

                    autoreleasepool {
                        let pageBounds = CGRect(origin: .zero, size: snapshot.pageSize)
                        context.beginPage(withBounds: pageBounds, pageInfo: [:])
                        do {
                            let drawing = try ThumbnailService.loadDrawingForExport(
                                fileName: snapshot.drawingFileName,
                                rootURL: rootURL
                            )
                            let image = try ThumbnailService.renderPageImageForExport(
                                snapshot: snapshot,
                                drawing: drawing,
                                rootURL: rootURL,
                                scale: renderScale
                            )
                            image.draw(in: pageBounds)
                        } catch {
                            renderError = error
                        }
                    }

                    let renderedFraction = (Double(index) + 0.85) / Double(total)
                    Task { @MainActor in
                        progress?(renderedFraction, "Rendered page \(pageNumber) of \(total).")
                    }
                }
            }
            if let renderError {
                throw renderError
            }
            try Task.checkCancellation()
            let finalizingFraction = (Double(total) - 0.01) / Double(total)
            await MainActor.run {
                progress?(finalizingFraction, "Finalizing PDF...")
            }
            await Task.yield()
            try validatePDF(
                at: stagedURL,
                expectedPageSizes: snapshots.map(\.pageSize)
            )
            try Task.checkCancellation()
            try commitStagedExport(at: stagedURL, to: exportURL)
            try Task.checkCancellation()

            await MainActor.run {
                progress?(1, "Export ready.")
            }

            guard FileManager.default.fileExists(atPath: exportURL.path) else {
                throw ImportExportError.exportFailed
            }
        }

        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated private static func writePDFImage(_ image: UIImage, pageSize: CGSize, exportURL: URL) throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))

        try renderer.writePDF(to: exportURL) { context in
            context.beginPage()
            image.draw(in: CGRect(origin: .zero, size: pageSize))
        }
    }

    nonisolated private static func stagedExportURL(for exportURL: URL) -> URL {
        let fileExtension = exportURL.pathExtension
        let baseName = exportURL.deletingPathExtension().lastPathComponent
        return exportURL.deletingLastPathComponent().appendingPathComponent(
            ".\(baseName)-\(UUID().uuidString).partial.\(fileExtension)"
        )
    }

    nonisolated private static func commitStagedExport(at stagedURL: URL, to exportURL: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: stagedURL.path),
              !fileManager.fileExists(atPath: exportURL.path) else {
            throw ImportExportError.exportFailed
        }
        try fileManager.moveItem(at: stagedURL, to: exportURL)
    }

    nonisolated private static func validateImage(
        at url: URL,
        expectedType: UTType,
        expectedImage: UIImage
    ) throws {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              let actualType = UTType(typeIdentifier),
              actualType.conforms(to: expectedType),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              let cgImage = expectedImage.cgImage,
              width.intValue == cgImage.width,
              height.intValue == cgImage.height else {
            throw ImportExportError.exportFailed
        }
    }

    nonisolated private static func validatePDF(
        at url: URL,
        expectedPageSizes: [CGSize]
    ) throws {
        guard !expectedPageSizes.isEmpty,
              let document = CGPDFDocument(url as CFURL),
              document.numberOfPages == expectedPageSizes.count else {
            throw ImportExportError.exportFailed
        }

        for (index, expectedSize) in expectedPageSizes.enumerated() {
            guard let page = document.page(at: index + 1) else {
                throw ImportExportError.exportFailed
            }
            let actualSize = page.getBoxRect(.mediaBox).size
            guard actualSize.width.isFinite,
                  actualSize.height.isFinite,
                  abs(actualSize.width - expectedSize.width) < 0.5,
                  abs(actualSize.height - expectedSize.height) < 0.5 else {
                throw ImportExportError.exportFailed
            }
        }
    }

    nonisolated private static func normalizedPDFPageSize(for sourceSize: CGSize) -> CGSize {
        let safeSize = safePDFPageSize(sourceSize)
        let commonWidth = CGFloat(NotePage.defaultPageWidth)
        // Logical document geometry stays independent from the bounded JPEG fallback,
        // so one receipt-shaped page cannot make every normal page narrow and blurry.
        // Match the model limit here instead of relying on NotePage and Attachment to
        // silently clamp different geometry when the imported objects are created.
        let maximumLogicalHeight = CGFloat(NotePage.maximumPageDimension)
        return CGSize(
            width: commonWidth,
            height: min(
                maximumLogicalHeight,
                max(1, (commonWidth * safeSize.height / safeSize.width).rounded())
            )
        )
    }

    nonisolated private static func safePDFPageSize(_ sourceSize: CGSize) -> CGSize {
        CGSize(
            width: sourceSize.width.isFinite ? max(sourceSize.width, 1) : 1,
            height: sourceSize.height.isFinite ? max(sourceSize.height, 1) : 1
        )
    }

    nonisolated private static func boundedPDFRasterSize(for sourceSize: CGSize) -> CGSize {
        let safeSize = safePDFPageSize(sourceSize)
        let scale = 1_280 / max(safeSize.width, safeSize.height)
        return CGSize(
            width: min(1_280, max(1, (safeSize.width * scale).rounded())),
            height: min(1_280, max(1, (safeSize.height * scale).rounded()))
        )
    }

    nonisolated private static func displayedPDFPageSize(for page: CGPDFPage) -> CGSize {
        let mediaBoxSize = page.getBoxRect(.mediaBox).size
        let rotation = ((page.rotationAngle % 360) + 360) % 360

        if rotation == 90 || rotation == 270 {
            return CGSize(width: mediaBoxSize.height, height: mediaBoxSize.width)
        }

        return mediaBoxSize
    }

    nonisolated private static func normalizedImagePageSize(for sourceSize: CGSize) -> CGSize {
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

    nonisolated private static func imageSize(at url: URL) -> CGSize? {
        let options = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary

        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, options),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
        else {
            return nil
        }

        return displayOrientedImageSize(from: properties)
    }

    nonisolated private static func imageSize(in data: Data) -> CGSize? {
        let options = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary

        guard
            let source = CGImageSourceCreateWithData(data as CFData, options),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
        else {
            return nil
        }

        return displayOrientedImageSize(from: properties)
    }

    nonisolated private static func displayOrientedImageSize(
        from properties: [CFString: Any]
    ) -> CGSize? {
        guard let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsDimensions = [5, 6, 7, 8].contains(orientation)
        return swapsDimensions
            ? CGSize(width: height.doubleValue, height: width.doubleValue)
            : CGSize(width: width.doubleValue, height: height.doubleValue)
    }

    nonisolated private static func imageContentType(for data: Data, fallbackExtension: String) -> UTType {
        let options = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary

        if let source = CGImageSourceCreateWithData(data as CFData, options),
           let identifier = CGImageSourceGetType(source) as String?,
           let contentType = UTType(identifier) {
            return contentType
        }

        return UTType(filenameExtension: fallbackExtension) ?? .png
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

    nonisolated private static func renderPDFPageJPEGData(
        _ page: CGPDFPage,
        displayedSize: CGSize,
        compressionQuality: CGFloat
    ) -> Data? {
        let rasterSize = boundedPDFRasterSize(for: displayedSize)
        let pixelWidth = Int(rasterSize.width.rounded(.up))
        let pixelHeight = Int(rasterSize.height.rounded(.up))
        let renderSize = CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        let renderRect = CGRect(origin: .zero, size: renderSize)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(renderRect)
        context.saveGState()
        context.concatenate(
            page.getDrawingTransform(
                .mediaBox,
                rect: renderRect,
                rotate: 0,
                preserveAspectRatio: true
            )
        )
        context.drawPDFPage(page)
        context.restoreGState()

        guard let image = context.makeImage() else {
            return nil
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let options = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)

        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return data as Data
    }

    nonisolated private static func quickLookThumbnail(for url: URL, size: CGSize) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: size,
                scale: 2,
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

    nonisolated private static func makeFastTextPreviewPage(
        for url: URL,
        fileExtension: String,
        title: String,
        pageSize: CGSize
    ) -> UIImage? {
        let supportedExtensions = Set(["csv", "txt", "text", "md", "json"])
        let normalizedExtension = fileExtension.lowercased()
        guard supportedExtensions.contains(normalizedExtension) else { return nil }

        guard
            let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
            !data.isEmpty
        else {
            return nil
        }

        let previewData = Data(data.prefix(32_768))
        guard let text = String(data: previewData, encoding: .utf8) else { return nil }

        let rows = text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(18)
            .map { line -> String in
                if normalizedExtension == "csv" {
                    return line
                        .split(separator: ",", omittingEmptySubsequences: false)
                        .prefix(6)
                        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                        .joined(separator: "    ")
                } else {
                    return String(line.prefix(96))
                }
            }

        guard !rows.isEmpty else { return nil }

        let previewRect = CGRect(x: 92, y: 120, width: pageSize.width - 184, height: pageSize.height - 360)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: pageSize, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pageSize))

            UIColor(white: 0.98, alpha: 1).setFill()
            context.fill(previewRect)
            UIColor(white: 0.86, alpha: 1).setStroke()
            context.cgContext.setLineWidth(1)
            context.cgContext.stroke(previewRect.insetBy(dx: 0.5, dy: 0.5))

            let previewTitleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 28, weight: .semibold),
                .foregroundColor: UIColor.secondaryLabel
            ]
            "Preview".draw(
                in: CGRect(x: previewRect.minX + 32, y: previewRect.minY + 28, width: previewRect.width - 64, height: 38),
                withAttributes: previewTitleAttributes
            )

            let rowAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
                .foregroundColor: UIColor.label
            ]
            let rowHeight: CGFloat = 34
            let rowWidth = previewRect.width - 64

            for (index, row) in rows.enumerated() {
                let rowRect = CGRect(
                    x: previewRect.minX + 32,
                    y: previewRect.minY + 88 + CGFloat(index) * rowHeight,
                    width: rowWidth,
                    height: rowHeight
                )
                String(row.prefix(110)).draw(in: rowRect, withAttributes: rowAttributes)
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

    nonisolated private static func makeDocumentPreviewPage(
        thumbnail: UIImage?,
        title: String,
        fileExtension: String,
        pageSize: CGSize
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: pageSize, format: format)
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

    nonisolated private static func aspectFitRect(for imageSize: CGSize, in rect: CGRect) -> CGRect {
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
