//
//  BeanNotesTests.swift
//  BeanNotesTests
//
//  Created by Jarrod on 2026-07-02.
//

import Testing
@testable import BeanNotes
import Foundation
import PDFKit
import PencilKit
import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

@Suite(.serialized)
@MainActor
struct BeanNotesTests {
    private static var retainedModelContainers: [ModelContainer] = []

    private func makeInMemoryModelContext() throws -> ModelContext {
        let schema = Schema([
            NotebookFolder.self,
            NoteDocument.self,
            NotePage.self,
            Attachment.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        Self.retainedModelContainers.append(container)
        return ModelContext(container)
    }

    @Test func modelGraphCreatesFolderNotePageAndAttachment() throws {
        let context = try makeInMemoryModelContext()

        let folder = NotebookFolder(name: "Projects", colorHex: "#5B8DEF")
        let note = NoteDocument(title: "Roast Notes")
        let page = NotePage(pageOrder: 0, background: NoteBackground(style: .grid, colorHex: "#FFFFFF"))
        let attachment = Attachment(
            kind: .pdf,
            displayName: "Menu",
            originalFileName: "menu.pdf",
            storedFileName: "Imports/menu.pdf",
            contentTypeIdentifier: UTType.pdf.identifier,
            fileExtension: "pdf"
        )

        folder.notes.append(note)
        note.pages.append(page)
        page.attachments.append(attachment)
        context.insert(folder)

        try context.save()

        let folders = try context.fetch(FetchDescriptor<NotebookFolder>())
        #expect(folders.count == 1)
        #expect(folders[0].sortedNotes.first?.title == "Roast Notes")
        #expect(folders[0].sortedNotes.first?.sortedPages.first?.background.style == .grid)
        #expect(folders[0].sortedNotes.first?.sortedPages.first?.attachments.first?.kind == .pdf)
    }

    @Test func attachmentLockAndDrawingLayerAreIndependent() {
        let attachment = Attachment(
            kind: .image,
            displayName: "Diagram",
            originalFileName: "diagram.png",
            storedFileName: "Imports/diagram.png",
            contentTypeIdentifier: UTType.png.identifier,
            fileExtension: "png",
            isLocked: true,
            rendersBehindDrawing: true
        )

        #expect(attachment.isLocked)
        #expect(attachment.rendersBehindDrawing)

        attachment.isLocked = false
        #expect(!attachment.isLocked)
        #expect(attachment.rendersBehindDrawing)

        attachment.rendersBehindDrawing = false
        #expect(!attachment.isLocked)
        #expect(!attachment.rendersBehindDrawing)
    }

    @Test func noteSearchMatchesIndexedPageTextAndAttachmentMetadata() throws {
        let context = try makeInMemoryModelContext()
        let note = NoteDocument(title: "CMPT 310")
        let page = NotePage(pageOrder: 0, searchableText: "Bayes theorem posterior probability")
        let attachment = Attachment(
            kind: .pdf,
            displayName: "Weekly Activity",
            originalFileName: "robotics-ai-worksheet.pdf",
            storedFileName: "Imports/robotics-ai-worksheet.pdf",
            contentTypeIdentifier: UTType.pdf.identifier,
            fileExtension: "pdf"
        )

        note.pages.append(page)
        page.attachments.append(attachment)
        context.insert(note)
        try context.save()
        note.rebuildSearchableText()

        #expect(note.matchesSearch("bayes posterior"))
        #expect(note.matchesSearch("robotics worksheet"))
        #expect(note.matchesSearch("cmpt"))
        #expect(!note.matchesSearch("organic chemistry"))
    }

    @Test func pageTouchMarksSearchIndexStale() throws {
        let context = try makeInMemoryModelContext()
        let note = NoteDocument(title: "Indexed", searchIndexUpdatedAt: Date())
        let page = NotePage(
            pageOrder: 0,
            searchableText: "Indexed text",
            searchIndexUpdatedAt: Date()
        )

        note.pages.append(page)
        context.insert(note)
        try context.save()
        page.touch()

        #expect(page.searchIndexUpdatedAt == nil)
        #expect(note.searchIndexUpdatedAt == nil)
    }

    @Test func localStorageCreatesAppRelativePaths() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()

        let stored = try storage.saveData(
            Data("hello".utf8),
            preferredName: "Sample Import.txt",
            contentType: .plainText,
            to: .imports
        )

        #expect(stored.relativePath.hasPrefix("Imports/"))
        #expect(!stored.relativePath.hasPrefix(rootURL.path))
        #expect(FileManager.default.fileExists(atPath: storage.url(forRelativePath: stored.relativePath).path))
    }

    @Test func localStorageUsageSnapshotCountsContentDirectories() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesStorageUsage-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()

        _ = try storage.saveData(Data(repeating: 1, count: 11), preferredName: "Drawing.pkdraw", contentType: .data, to: .drawings)
        _ = try storage.saveData(Data(repeating: 2, count: 13), preferredName: "Import.pdf", contentType: .pdf, to: .imports)
        _ = try storage.saveData(Data(repeating: 3, count: 17), preferredName: "Thumb.jpg", contentType: .jpeg, to: .thumbnails)
        _ = try storage.saveData(Data(repeating: 4, count: 19), preferredName: "Export.pdf", contentType: .pdf, to: .exports)

        let snapshot = try storage.storageUsageSnapshot()

        #expect(snapshot.usage(for: .drawings)?.byteCount == 11)
        #expect(snapshot.usage(for: .imports)?.byteCount == 13)
        #expect(snapshot.usage(for: .thumbnails)?.byteCount == 17)
        #expect(snapshot.usage(for: .exports)?.byteCount == 19)
        #expect(snapshot.totalByteCount == 60)
        #expect(snapshot.totalFileCount == 4)
    }

    @Test func localStorageRemovesOnlyOldExports() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesOldExports-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()

        let oldExport = try storage.saveData(Data(repeating: 1, count: 7), preferredName: "Old.pdf", contentType: .pdf, to: .exports)
        let recentExport = try storage.saveData(Data(repeating: 2, count: 9), preferredName: "Recent.pdf", contentType: .pdf, to: .exports)
        let oldBackup = try storage.saveData(Data(repeating: 3, count: 11), preferredName: "Backup.beannotes", contentType: .data, to: .exports)
        let oldURL = storage.url(forRelativePath: oldExport.relativePath)
        let recentURL = storage.url(forRelativePath: recentExport.relativePath)
        let oldBackupURL = storage.url(forRelativePath: oldBackup.relativePath)
        let oldDate = Date().addingTimeInterval(-9 * 24 * 60 * 60)
        let cutoffDate = Date().addingTimeInterval(-7 * 24 * 60 * 60)

        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldURL.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldBackupURL.path)

        let report = try storage.removeExports(olderThan: cutoffDate)

        #expect(report.removedFileCount == 1)
        #expect(report.removedByteCount == 7)
        #expect(report.failedFileCount == 0)
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(FileManager.default.fileExists(atPath: recentURL.path))
        #expect(FileManager.default.fileExists(atPath: oldBackupURL.path))
        #expect(try storage.storageUsageSnapshot().usage(for: .exports)?.fileCount == 2)
    }

    @Test @MainActor func libraryBackupManifestCapturesWholeLibraryMetadata() throws {
        let context = try makeInMemoryModelContext()
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let folder = NotebookFolder(name: "CMPT 310", colorHex: "#4F7CFF", createdAt: createdAt, updatedAt: createdAt)
        let note = NoteDocument(title: "Weekly Activity", searchableText: "robotics notes", createdAt: createdAt, updatedAt: createdAt)
        let page = NotePage(
            pageOrder: 0,
            drawingFileName: "page-1.drawing",
            thumbnailFileName: "Thumbnails/page-1.jpg",
            background: NoteBackground(style: .grid, colorHex: "#FFF7C2"),
            searchableText: "bayes theorem",
            width: 1024,
            height: 1366,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let attachment = Attachment(
            kind: .pdf,
            displayName: "Lecture",
            originalFileName: "lecture.pdf",
            storedFileName: "Imports/lecture.pdf",
            contentTypeIdentifier: UTType.pdf.identifier,
            fileExtension: "pdf",
            isLocked: true,
            rendersBehindDrawing: true,
            createdAt: createdAt,
            updatedAt: createdAt
        )

        folder.notes.append(note)
        note.pages.append(page)
        page.attachments.append(attachment)
        context.insert(folder)
        try context.save()

        let manifest = LibraryBackupManifest(folders: [folder], createdAt: createdAt)

        #expect(manifest.formatVersion == 1)
        #expect(manifest.folderCount == 1)
        #expect(manifest.noteCount == 1)
        #expect(manifest.pageCount == 1)
        #expect(manifest.attachmentCount == 1)
        #expect(manifest.folders.first?.name == "CMPT 310")
        #expect(manifest.folders.first?.notes.first?.title == "Weekly Activity")
        #expect(manifest.folders.first?.notes.first?.pages.first?.drawingFileName == "page-1.drawing")
        #expect(manifest.folders.first?.notes.first?.pages.first?.attachments.first?.storedFileName == "Imports/lecture.pdf")
    }

    @Test @MainActor func libraryBackupCreatesBeanNotesArchiveAndSkipsPriorBackups() async throws {
        let context = try makeInMemoryModelContext()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesLibraryBackup-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()

        let drawing = try storage.saveData(Data("drawing-data".utf8), fileName: "page-1.drawing", contentType: .data, to: .drawings, replacingExisting: true)
        let imported = try storage.saveData(Data("pdf-data".utf8), preferredName: "Lecture.pdf", contentType: .pdf, to: .imports)
        let exported = try storage.saveData(Data("export-data".utf8), preferredName: "Rendered.pdf", contentType: .pdf, to: .exports)
        let priorBackup = try storage.saveData(Data("old-backup".utf8), preferredName: "Old.beannotes", contentType: .data, to: .exports)

        let folder = NotebookFolder(name: "Inbox")
        let note = NoteDocument(title: "Backup Test")
        let page = NotePage(pageOrder: 0, drawingFileName: drawing.fileName)
        let attachment = Attachment(
            kind: .pdf,
            displayName: "Lecture",
            originalFileName: "Lecture.pdf",
            storedFileName: imported.relativePath,
            contentTypeIdentifier: UTType.pdf.identifier,
            fileExtension: "pdf"
        )

        folder.notes.append(note)
        note.pages.append(page)
        page.attachments.append(attachment)
        context.insert(folder)
        try context.save()

        let result = try await LibraryBackupService(storage: storage).exportLibraryBackup(folders: [folder])
        let archiveData = try Data(contentsOf: result.url)
        let archiveText = String(decoding: archiveData, as: UTF8.self)

        #expect(result.url.pathExtension == "beannotes")
        #expect(result.fileCount == 3)
        #expect(result.byteCount > 0)
        #expect(Array(archiveData.prefix(4)) == [0x50, 0x4B, 0x03, 0x04])
        #expect(archiveText.contains("manifest.json"))
        #expect(archiveText.contains("storage/\(drawing.relativePath)"))
        #expect(archiveText.contains("storage/\(imported.relativePath)"))
        #expect(archiveText.contains("storage/\(exported.relativePath)"))
        #expect(!archiveText.contains("storage/\(priorBackup.relativePath)"))
    }

    @Test func localStorageRejectsPathsOutsideRootUsingPathComponents() throws {
        let containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesPathValidation-\(UUID().uuidString)", isDirectory: true)
        let rootURL = containerURL.appendingPathComponent("Storage", isDirectory: true)
        let siblingURL = containerURL.appendingPathComponent("Storage-Sibling", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: containerURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()

        let insideURL = rootURL
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent("inside.txt")
        let siblingFileURL = siblingURL
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent("outside.txt")

        try FileManager.default.createDirectory(
            at: siblingFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("outside".utf8).write(to: siblingFileURL)

        #expect(try storage.relativePath(for: insideURL) == "Imports/inside.txt")

        do {
            _ = try storage.relativePath(for: siblingFileURL)
            Issue.record("Sibling storage path should not be treated as inside BeanNotes storage.")
        } catch LocalStorageError.invalidRelativePath {
            // Expected: same-prefix sibling directories are outside the storage root.
        }

        do {
            _ = try storage.removeFile(relativePath: "../Storage-Sibling/Imports/outside.txt")
            Issue.record("Escaped relative path should not be removable through BeanNotes storage.")
        } catch LocalStorageError.invalidRelativePath {
            // Expected: cleanup cannot escape the storage root.
        }

        do {
            _ = try storage.removeFile(relativePath: ".")
            Issue.record("Storage root should not be removable as a file cleanup target.")
        } catch LocalStorageError.invalidRelativePath {
            // Expected: cleanup targets must be descendants of the storage root.
        }

        #expect(FileManager.default.fileExists(atPath: siblingFileURL.path))
        #expect(FileManager.default.fileExists(atPath: rootURL.path))
    }

    @Test func localStorageCopiesStoredFilesToIndependentPaths() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesStoredCopy-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()

        let original = try storage.saveData(
            Data("page attachment".utf8),
            preferredName: "Attachment.txt",
            contentType: .plainText,
            to: .imports
        )
        let copiedPath = try #require(try storage.copyStoredFileIfPresent(relativePath: original.relativePath))

        #expect(copiedPath != original.relativePath)
        #expect(copiedPath.hasPrefix("Imports/"))
        #expect(
            try Data(contentsOf: storage.url(forRelativePath: copiedPath)) ==
            Data(contentsOf: storage.url(forRelativePath: original.relativePath))
        )

        try storage.removeFile(relativePath: original.relativePath)

        #expect(!FileManager.default.fileExists(atPath: storage.url(forRelativePath: original.relativePath).path))
        #expect(FileManager.default.fileExists(atPath: storage.url(forRelativePath: copiedPath).path))
    }

    @Test func localStorageCleanupTargetRemovesOnlyOnePageFiles() throws {
        let context = try makeInMemoryModelContext()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesPageCleanup-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()

        let note = NoteDocument(title: "Two Pages")
        context.insert(note)
        let firstPage = NotePage(pageOrder: 0)
        let secondPage = NotePage(pageOrder: 1)
        note.pages.append(firstPage)
        note.pages.append(secondPage)

        let firstDrawingURL = try storage.directoryURL(for: .drawings).appendingPathComponent(firstPage.drawingFileName)
        let secondDrawingURL = try storage.directoryURL(for: .drawings).appendingPathComponent(secondPage.drawingFileName)
        try Data("first drawing".utf8).write(to: firstDrawingURL)
        try Data("second drawing".utf8).write(to: secondDrawingURL)

        let firstAttachmentFile = try storage.saveData(
            Data("first attachment".utf8),
            preferredName: "First.pdf",
            contentType: .pdf,
            to: .imports
        )
        let secondAttachmentFile = try storage.saveData(
            Data("second attachment".utf8),
            preferredName: "Second.pdf",
            contentType: .pdf,
            to: .imports
        )
        let firstAttachment = Attachment(
            kind: .pdf,
            displayName: "First",
            originalFileName: "First.pdf",
            storedFileName: firstAttachmentFile.relativePath,
            contentTypeIdentifier: UTType.pdf.identifier,
            fileExtension: "pdf"
        )
        let secondAttachment = Attachment(
            kind: .pdf,
            displayName: "Second",
            originalFileName: "Second.pdf",
            storedFileName: secondAttachmentFile.relativePath,
            contentTypeIdentifier: UTType.pdf.identifier,
            fileExtension: "pdf"
        )
        firstPage.attachments.append(firstAttachment)
        secondPage.attachments.append(secondAttachment)
        try context.save()

        let report = storage.removeStoredFiles(matching: LocalStorageCleanupTarget(page: firstPage))

        #expect(report.failedRelativePaths.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: firstDrawingURL.path))
        #expect(!FileManager.default.fileExists(atPath: storage.url(forRelativePath: firstAttachmentFile.relativePath).path))
        #expect(FileManager.default.fileExists(atPath: secondDrawingURL.path))
        #expect(FileManager.default.fileExists(atPath: storage.url(forRelativePath: secondAttachmentFile.relativePath).path))
    }

    @Test func localStorageCleanupRemovesDeletedNoteFiles() throws {
        let context = try makeInMemoryModelContext()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesCleanup-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()

        let folder = NotebookFolder(name: "Cleanup")
        let note = NoteDocument(title: "Delete Me")
        let page = NotePage(pageOrder: 0)
        let storedImport = try storage.saveData(
            Data("pdf".utf8),
            preferredName: "Syllabus.pdf",
            contentType: .pdf,
            to: .imports
        )
        let attachment = Attachment(
            kind: .pdf,
            displayName: "Syllabus",
            originalFileName: "Syllabus.pdf",
            storedFileName: storedImport.relativePath,
            contentTypeIdentifier: UTType.pdf.identifier,
            fileExtension: "pdf"
        )

        folder.notes.append(note)
        note.pages.append(page)
        page.attachments.append(attachment)
        context.insert(folder)
        try context.save()

        let drawingURL = try storage.directoryURL(for: .drawings).appendingPathComponent(page.drawingFileName)
        try Data("drawing".utf8).write(to: drawingURL)

        let storedThumbnail = try storage.saveData(
            Data("thumbnail".utf8),
            fileName: "\(page.id.uuidString).jpg",
            contentType: .jpeg,
            to: .thumbnails,
            replacingExisting: true
        )
        page.thumbnailFileName = storedThumbnail.relativePath

        let exportDirectory = try storage.directoryURL(for: .exports)
        let matchingExportURL = exportDirectory.appendingPathComponent(storage.uniqueFileName("Delete Me.pdf"))
        try Data("export".utf8).write(to: matchingExportURL)

        let unrelatedImport = try storage.saveData(
            Data("keep".utf8),
            preferredName: "Keep.pdf",
            contentType: .pdf,
            to: .imports
        )
        let unrelatedExportURL = exportDirectory.appendingPathComponent(storage.uniqueFileName("Keep Me.pdf"))
        try Data("keep export".utf8).write(to: unrelatedExportURL)

        let report = storage.removeStoredFiles(matching: LocalStorageCleanupTarget(note: note))

        #expect(report.failedRelativePaths.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: drawingURL.path))
        #expect(!FileManager.default.fileExists(atPath: storage.url(forRelativePath: storedThumbnail.relativePath).path))
        #expect(!FileManager.default.fileExists(atPath: storage.url(forRelativePath: storedImport.relativePath).path))
        #expect(!FileManager.default.fileExists(atPath: matchingExportURL.path))
        #expect(FileManager.default.fileExists(atPath: storage.url(forRelativePath: unrelatedImport.relativePath).path))
        #expect(FileManager.default.fileExists(atPath: unrelatedExportURL.path))
    }

    @Test func noteBackgroundDefaultsResolveStyleAndColor() {
        let dottedYellow = NoteBackground.fromDefaults(styleRaw: NoteBackgroundStyle.dotted.rawValue, colorHex: "#FFF7BF")
        let fallback = NoteBackground.fromDefaults(styleRaw: "unknown", colorHex: "")

        #expect(dottedYellow.style == .dotted)
        #expect(dottedYellow.colorHex == "#FFF7BF")
        #expect(fallback.style == .plain)
        #expect(fallback.colorHex == NoteBackground.defaultColorHex)
        #expect(NoteBackground.colorPresets.contains { $0.name == "Beige" })
        #expect(NoteBackgroundStyle.allCases.contains(.cornell))
        #expect(NoteBackgroundStyle.allCases.contains(.musicStaff))
        #expect(NoteBackgroundStyle.allCases.contains(.planner))
    }

    @Test func noteBackgroundTemplatesRoundTripSpacingAndMargins() {
        let cornell = NoteBackground(style: .cornell, colorHex: "#FFF7BF", spacing: 42, marginWidth: 244)
        let restoredCornell = NoteBackground.fromDefaults(styleRaw: cornell.storageStyleRaw, colorHex: cornell.colorHex)

        #expect(cornell.storageStyleRaw == "cornell;spacing=42;margin=244")
        #expect(restoredCornell.style == .cornell)
        #expect(restoredCornell.resolvedSpacing == 42)
        #expect(restoredCornell.resolvedMarginWidth == 244)

        let page = NotePage(pageOrder: 0, background: cornell)
        #expect(page.backgroundStyleRaw == "cornell;spacing=42;margin=244")
        #expect(page.background.style == .cornell)
        #expect(page.background.resolvedSpacing == 42)
        #expect(page.background.resolvedMarginWidth == 244)

        let clampedGrid = NoteBackground.fromDefaults(styleRaw: "grid;spacing=4;margin=999", colorHex: "#FFFFFF")
        #expect(clampedGrid.resolvedSpacing == NoteBackgroundStyle.grid.spacingRange.lowerBound)
        #expect(clampedGrid.resolvedMarginWidth == NoteBackgroundStyle.grid.marginRange.upperBound)
    }

    @Test func hexColorsRoundTripWithoutComponentDrift() {
        for colorHex in ["#E81E2D", "#2345EA", "#94F02B", "#0A84FF", "#FFF7BF"] {
            #expect(UIColor(hex: colorHex).hexRGB == colorHex)
            #expect(Color(hex: colorHex).hexRGB == colorHex)
        }
    }

    @Test func paginationSettingsMapToEditorFlowModes() {
        #expect(
            NoteEditorPageFlowMode.combined(layoutMode: .singlePage, creationMode: .manual) == .singlePage
        )
        #expect(
            NoteEditorPageFlowMode.combined(layoutMode: .singlePage, creationMode: .auto) == .singlePage
        )
        #expect(
            NoteEditorPageFlowMode.combined(layoutMode: .scroll, creationMode: .manual) == .continuous
        )
        #expect(
            NoteEditorPageFlowMode.combined(layoutMode: .scroll, creationMode: .auto) == .infinite
        )
        #expect(NoteEditorPageFlowMode.infinite.layoutMode == .scroll)
        #expect(NoteEditorPageFlowMode.infinite.creationMode == .auto)
    }

    @Test func drawingRenderQualityExposesSharperZoomBudget() {
        #expect(DrawingRenderQuality.highResolution.maximumZoomScale > DrawingRenderQuality.balanced.maximumZoomScale)
        #expect(DrawingRenderQuality.highResolution.maximumZoomFitMultiplier > DrawingRenderQuality.balanced.maximumZoomFitMultiplier)
        #expect(DrawingRenderQuality.highResolution.drawingScaleMultiplier > DrawingRenderQuality.balanced.drawingScaleMultiplier)
        #expect(DrawingRenderQuality.highResolution.backgroundScaleMultiplier > DrawingRenderQuality.balanced.backgroundScaleMultiplier)
        #expect(DrawingRenderQuality.highResolution.imageScaleMultiplier > DrawingRenderQuality.balanced.imageScaleMultiplier)
    }

    @Test func welcomeModalAppearsForFirstRunAndNewContentVersions() {
        #expect(ContentView.shouldShowWelcome(hasSeenWelcome: false, seenContentVersion: 0))
        #expect(ContentView.shouldShowWelcome(
            hasSeenWelcome: true,
            seenContentVersion: ContentView.currentWelcomeContentVersion - 1
        ))
        #expect(!ContentView.shouldShowWelcome(
            hasSeenWelcome: true,
            seenContentVersion: ContentView.currentWelcomeContentVersion
        ))
    }

    @Test func attachmentImageRasterBudgetBalancesSharpnessAndMemory() {
        let baseBudget = AttachmentImageRasterBudget(
            attachmentSize: CGSize(width: 320, height: 220),
            renderScale: 2
        )
        let zoomedBudget = AttachmentImageRasterBudget(
            attachmentSize: CGSize(width: 320, height: 220),
            renderScale: 8
        )
        let cappedBudget = AttachmentImageRasterBudget(
            attachmentSize: CGSize(width: 2_400, height: 1_800),
            renderScale: 8
        )
        let moderateZoomBudget = AttachmentImageRasterBudget(
            attachmentSize: CGSize(width: 320, height: 220),
            renderScale: 4
        )

        #expect(baseBudget.maxPixelSize == 1_024)
        #expect(zoomedBudget.maxPixelSize == 2_560)
        #expect(cappedBudget.maxPixelSize == 3_072)
        #expect(zoomedBudget.shouldReplaceLoadedBudget(baseBudget))
        #expect(baseBudget.shouldReplaceLoadedBudget(zoomedBudget))
        #expect(!moderateZoomBudget.shouldReplaceLoadedBudget(baseBudget))
    }

    @Test @MainActor func customDrawingToolsMapToDistinctPencilKitTools() {
        let toolState = DrawingToolState()
        let selectedRed = Color(uiColor: UIColor(red: 1, green: 0, blue: 0, alpha: 1))
        let selectedBlue = Color(uiColor: UIColor(red: 0, green: 0, blue: 1, alpha: 1))

        toolState.select(.pencil)
        toolState.applyActiveColor(selectedRed)
        toolState.applyActiveWidth(8)
        #expect(toolState.activeInkType == .pencil)
        _ = toolState.makePKTool()
        #expect(UIColor(toolState.pencilColor).hexRGB == UIColor(selectedRed).hexRGB)
        #expect(toolState.activeStrokeWidth == 8)

        toolState.select(.pen)
        toolState.applyActiveColor(selectedBlue)
        #expect(toolState.activeInkType == .pen)
        _ = toolState.makePKTool()
        #expect(UIColor(toolState.penColor).hexRGB == UIColor(selectedBlue).hexRGB)

        toolState.select(.highlighter)
        #expect(toolState.activeInkType == .marker)
        _ = toolState.makePKTool()

        toolState.select(.eraser)
        #expect(toolState.activeInkType == nil)
        _ = toolState.makePKTool()

        toolState.select(.lasso)
        #expect(toolState.activeInkType == nil)
        _ = toolState.makePKTool()
    }

    @Test @MainActor func customPaletteRestoresSelectedColorsAndEraserMode() throws {
        let suiteName = "BeanNotesToolState-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let selectedRed = Color(uiColor: UIColor(red: 0.91, green: 0.12, blue: 0.18, alpha: 1))
        let selectedBlue = Color(uiColor: UIColor(red: 0.13, green: 0.27, blue: 0.92, alpha: 1))
        let selectedGreen = Color(uiColor: UIColor(red: 0.58, green: 0.94, blue: 0.17, alpha: 1))
        let selectedRedHex = UIColor(selectedRed).hexRGB
        let selectedBlueHex = UIColor(selectedBlue).hexRGB
        let selectedGreenHex = UIColor(selectedGreen).hexRGB

        let firstSession = DrawingToolState(defaults: defaults)
        firstSession.select(.pen)
        firstSession.applyActiveColor(selectedRed)
        firstSession.applyActiveWidth(8)
        firstSession.select(.pencil)
        firstSession.applyActiveColor(selectedBlue)
        firstSession.select(.highlighter)
        firstSession.applyActiveColor(selectedGreen)
        firstSession.selectEraserMode(.object)
        firstSession.select(.pencil)

        let restoredSession = DrawingToolState(defaults: defaults)

        #expect(restoredSession.selectedTool == .pencil)
        #expect(UIColor(restoredSession.penColor).hexRGB == selectedRedHex)
        #expect(UIColor(restoredSession.pencilColor).hexRGB == selectedBlueHex)
        #expect(UIColor(restoredSession.highlighterColor).hexRGB == selectedGreenHex)
        #expect(restoredSession.penWidth == 8)
        #expect(restoredSession.eraserMode == .object)

        let penPalette = restoredSession.paletteSwatches(for: .pen).map(\.colorHex)
        let pencilPalette = restoredSession.paletteSwatches(for: .pencil).map(\.colorHex)
        let highlighterPalette = restoredSession.paletteSwatches(for: .highlighter).map(\.colorHex)

        #expect(penPalette.first == selectedRedHex)
        #expect(pencilPalette.first == selectedBlueHex)
        #expect(highlighterPalette.first == selectedGreenHex)
        #expect(!penPalette.contains(selectedBlueHex))
        #expect(!pencilPalette.contains(selectedGreenHex))
        #expect(!highlighterPalette.contains(selectedRedHex))
    }

    @Test @MainActor func customPalettePrimaryColorPersistsPerInkTool() throws {
        let suiteName = "BeanNotesPrimaryPalette-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let penCustomColor = Color(uiColor: UIColor(red: 0.25, green: 0.08, blue: 0.93, alpha: 1))
        let pencilCustomColor = Color(uiColor: UIColor(red: 0.90, green: 0.22, blue: 0.08, alpha: 1))
        let highlighterCustomColor = Color(uiColor: UIColor(red: 0.08, green: 0.78, blue: 0.44, alpha: 1))
        let penCustomHex = UIColor(penCustomColor).hexRGB
        let pencilCustomHex = UIColor(pencilCustomColor).hexRGB
        let highlighterCustomHex = UIColor(highlighterCustomColor).hexRGB

        let firstSession = DrawingToolState(defaults: defaults)
        firstSession.select(.pen)
        firstSession.setPrimaryPaletteColor(penCustomColor)
        firstSession.select(.pencil)
        firstSession.setPrimaryPaletteColor(pencilCustomColor)
        firstSession.select(.highlighter)
        firstSession.setPrimaryPaletteColor(highlighterCustomColor)
        firstSession.select(.eraser)

        #expect(firstSession.selectedToolUsesInkColor == false)

        let restoredSession = DrawingToolState(defaults: defaults)
        #expect(restoredSession.paletteSwatches(for: .pen).first?.colorHex == penCustomHex)
        #expect(restoredSession.paletteSwatches(for: .pencil).first?.colorHex == pencilCustomHex)
        #expect(restoredSession.paletteSwatches(for: .highlighter).first?.colorHex == highlighterCustomHex)
        #expect(UIColor(restoredSession.primaryPaletteColor(for: .pen)).hexRGB == penCustomHex)
        #expect(UIColor(restoredSession.primaryPaletteColor(for: .pencil)).hexRGB == pencilCustomHex)
        #expect(UIColor(restoredSession.primaryPaletteColor(for: .highlighter)).hexRGB == highlighterCustomHex)
    }

    @Test @MainActor func customPaletteEditsSelectedIndexInPlace() throws {
        let suiteName = "BeanNotesIndexedPalette-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let selectedIndex = 3
        let customColor = Color(uiColor: UIColor(red: 0.22, green: 0.71, blue: 0.41, alpha: 1))
        let customHex = UIColor(customColor).hexRGB

        let firstSession = DrawingToolState(defaults: defaults)
        firstSession.select(.pen)
        let originalPalette = firstSession.paletteSwatches(for: .pen).map(\.colorHex)

        firstSession.setPaletteColor(customColor, at: selectedIndex)
        let updatedPalette = firstSession.paletteSwatches(for: .pen).map(\.colorHex)

        #expect(updatedPalette.count == originalPalette.count)
        #expect(updatedPalette[0] == originalPalette[0])
        #expect(updatedPalette[selectedIndex] == customHex)
        #expect(UIColor(firstSession.activeInkColor).hexRGB == customHex)

        let restoredSession = DrawingToolState(defaults: defaults)
        let restoredPalette = restoredSession.paletteSwatches(for: .pen).map(\.colorHex)
        #expect(restoredPalette[selectedIndex] == customHex)
        #expect(restoredPalette[0] == originalPalette[0])
    }

    @Test @MainActor func customPaletteDuplicateColorEditDoesNotDropSwatches() throws {
        let suiteName = "BeanNotesDuplicatePalette-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let duplicatedIndex = 4
        let firstSession = DrawingToolState(defaults: defaults)
        firstSession.select(.pen)
        let originalPalette = firstSession.paletteSwatches(for: .pen).map(\.colorHex)
        let duplicatedColor = firstSession.paletteColor(at: 0, for: .pen)

        firstSession.setPaletteColor(duplicatedColor, at: duplicatedIndex)

        let updatedPalette = firstSession.paletteSwatches(for: .pen).map(\.colorHex)
        #expect(updatedPalette.count == originalPalette.count)
        #expect(updatedPalette[0] == originalPalette[0])
        #expect(updatedPalette[duplicatedIndex] == originalPalette[0])

        let restoredSession = DrawingToolState(defaults: defaults)
        let restoredPalette = restoredSession.paletteSwatches(for: .pen).map(\.colorHex)
        #expect(restoredPalette.count == originalPalette.count)
        #expect(restoredPalette[duplicatedIndex] == originalPalette[0])
    }

    @Test @MainActor func thumbnailGenerationStoresFirstPagePreview() throws {
        let context = try makeInMemoryModelContext()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesThumbnail-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        let drawingStorage = DrawingStorageService(storage: storage)
        let service = ThumbnailService(storage: storage, drawingStorage: drawingStorage)
        try storage.prepareDirectories()

        let pageSize = CGSize(width: 240, height: 320)
        let renderer = UIGraphicsImageRenderer(size: pageSize)
        let firstPageImage = renderer.image { context in
            UIColor(red: 1, green: 0.95, blue: 0.55, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: pageSize))

            "First Page".draw(
                at: CGPoint(x: 36, y: 48),
                withAttributes: [.font: UIFont.systemFont(ofSize: 28, weight: .bold)]
            )
        }

        let imageData = try #require(firstPageImage.jpegData(compressionQuality: 0.9))
        let storedImage = try storage.saveData(imageData, preferredName: "first-page.jpg", contentType: .jpeg, to: .imports)
        let page = NotePage(
            pageOrder: 0,
            background: .plain(),
            width: Double(pageSize.width),
            height: Double(pageSize.height)
        )
        let attachment = Attachment(
            kind: .image,
            displayName: "First Page",
            originalFileName: "first-page.jpg",
            storedFileName: storedImage.relativePath,
            contentTypeIdentifier: UTType.jpeg.identifier,
            fileExtension: "jpg",
            x: 0,
            y: 0,
            width: Double(pageSize.width),
            height: Double(pageSize.height),
            isLocked: true,
            rendersBehindDrawing: true
        )
        page.attachments.append(attachment)
        context.insert(page)
        try context.save()
        let thumbnailURL = try service.generateThumbnail(for: page, maxDimension: 120)
        let thumbnail = try #require(UIImage(contentsOfFile: thumbnailURL.path))
        let refreshedThumbnailURL = try service.generateThumbnail(for: page, maxDimension: 120)

        #expect(page.thumbnailFileName?.hasPrefix("Thumbnails/") == true)
        #expect(FileManager.default.fileExists(atPath: thumbnailURL.path))
        #expect(FileManager.default.fileExists(atPath: refreshedThumbnailURL.path))
        #expect(thumbnailURL.lastPathComponent == refreshedThumbnailURL.lastPathComponent)
        #expect(refreshedThumbnailURL.lastPathComponent == "\(page.id.uuidString).jpg")
        #expect(refreshedThumbnailURL.lastPathComponent.hasPrefix("Thumbnails-") == false)
        #expect(page.thumbnailFileName?.components(separatedBy: "/").count == 2)
        #expect(max(thumbnail.size.width, thumbnail.size.height) <= 120.5)
        #expect(thumbnail.size.height > thumbnail.size.width)
    }

    @Test @MainActor func pdfImportCreatesAnnotatablePages() async throws {
        let context = try makeInMemoryModelContext()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesPDFImport-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        let drawingStorage = DrawingStorageService(storage: storage)
        let thumbnailService = ThumbnailService(storage: storage, drawingStorage: drawingStorage)
        let service = ImportExportService(
            storage: storage,
            drawingStorage: drawingStorage,
            thumbnailService: thumbnailService
        )
        try storage.prepareDirectories()

        let pdfURL = rootURL.appendingPathComponent("Syllabus.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: pdfURL) { context in
            context.beginPage()
            "Page 1".draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            context.beginPage()
            "Page 2".draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
        }

        let folder = NotebookFolder(name: "Class")
        context.insert(folder)
        try context.save()
        let imported = try await service.importDocumentAsNote(from: pdfURL, into: folder)
        try context.save()

        #expect(imported.note.title == "Syllabus")
        #expect(imported.pages.count == 2)
        #expect(imported.pages.allSatisfy { $0.lockedImageAttachments.count == 1 })
        #expect(imported.attachments.contains { $0.kind == .pdf && !$0.isLocked })
        #expect(imported.pages.allSatisfy { $0.lockedImageAttachments.allSatisfy(\.rendersBehindDrawing) })

        let lockedImage = try #require(imported.pages.first?.lockedImageAttachments.first)
        #expect(FileManager.default.fileExists(atPath: storage.url(forRelativePath: lockedImage.storedFileName).path))
    }

    @Test @MainActor func stagedPDFImportRollbackRemovesCopiedFilesBeforeCommit() async throws {
        let context = try makeInMemoryModelContext()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesPDFRollback-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        let drawingStorage = DrawingStorageService(storage: storage)
        let thumbnailService = ThumbnailService(storage: storage, drawingStorage: drawingStorage)
        let service = ImportExportService(
            storage: storage,
            drawingStorage: drawingStorage,
            thumbnailService: thumbnailService
        )
        try storage.prepareDirectories()

        let pdfURL = rootURL.appendingPathComponent("Rollback.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: pdfURL) { context in
            context.beginPage()
            "Draft Page 1".draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            context.beginPage()
            "Draft Page 2".draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
        }

        let folder = NotebookFolder(name: "Class")
        context.insert(folder)
        try context.save()
        let staging = storage.beginImportStagingTransaction()
        let imported = try await service.importDocumentAsNote(from: pdfURL, into: folder, staging: staging)
        let storedPaths = Set(imported.attachments.map(\.storedFileName))

        #expect(storedPaths.count == 3)
        #expect(FileManager.default.fileExists(atPath: staging.stagingDirectoryURL.path))
        #expect(!FileManager.default.fileExists(atPath: staging.finalDirectoryURL.path))

        for relativePath in storedPaths {
            let finalURL = storage.url(forRelativePath: relativePath)
            let stagedURL = staging.stagingDirectoryURL.appendingPathComponent(finalURL.lastPathComponent)

            #expect(FileManager.default.fileExists(atPath: stagedURL.path))
            #expect(!FileManager.default.fileExists(atPath: finalURL.path))
        }

        staging.rollback()

        #expect(!FileManager.default.fileExists(atPath: staging.stagingDirectoryURL.path))
        #expect(!FileManager.default.fileExists(atPath: staging.finalDirectoryURL.path))

        for relativePath in storedPaths {
            #expect(!FileManager.default.fileExists(atPath: storage.url(forRelativePath: relativePath).path))
        }
    }

    @Test @MainActor func imageImportCreatesAnnotatableImageNote() async throws {
        let context = try makeInMemoryModelContext()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesImageImport-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        let drawingStorage = DrawingStorageService(storage: storage)
        let thumbnailService = ThumbnailService(storage: storage, drawingStorage: drawingStorage)
        let service = ImportExportService(
            storage: storage,
            drawingStorage: drawingStorage,
            thumbnailService: thumbnailService
        )
        try storage.prepareDirectories()

        let imageURL = rootURL.appendingPathComponent("Diagram.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 320)).image { context in
            UIColor.systemYellow.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 320))
            UIColor.systemBlue.setStroke()
            context.cgContext.setLineWidth(10)
            context.cgContext.strokeEllipse(in: CGRect(x: 80, y: 60, width: 320, height: 200))
        }
        try #require(image.pngData()).write(to: imageURL)

        let folder = NotebookFolder(name: "Images")
        context.insert(folder)
        try context.save()
        let imported = try await service.importDocumentAsNote(from: imageURL, into: folder)
        try context.save()
        let page = try #require(imported.pages.first)
        let lockedImage = try #require(page.lockedImageAttachments.first)

        #expect(imported.note.title == "Diagram")
        #expect(imported.pages.count == 1)
        #expect(imported.attachments.count == 1)
        #expect(lockedImage.kind == .image)
        #expect(lockedImage.isLocked)
        #expect(lockedImage.rendersBehindDrawing)
        #expect(lockedImage.x == 0)
        #expect(lockedImage.y == 0)
        #expect(lockedImage.width == page.width)
        #expect(lockedImage.height == page.height)
        #expect(folder.notes.contains { $0.id == imported.note.id })
        #expect(FileManager.default.fileExists(atPath: storage.url(forRelativePath: lockedImage.storedFileName).path))
    }

    @Test @MainActor func csvImportCreatesPreviewNoteAndKeepsOriginalFile() async throws {
        let context = try makeInMemoryModelContext()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesCSVImport-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        let drawingStorage = DrawingStorageService(storage: storage)
        let thumbnailService = ThumbnailService(storage: storage, drawingStorage: drawingStorage)
        let service = ImportExportService(
            storage: storage,
            drawingStorage: drawingStorage,
            thumbnailService: thumbnailService
        )
        try storage.prepareDirectories()

        let csvURL = rootURL.appendingPathComponent("Grades.csv")
        try Data("name,score\nBean,100\n".utf8).write(to: csvURL)

        let folder = NotebookFolder(name: "Tables")
        context.insert(folder)
        try context.save()
        let imported = try await service.importDocumentAsNote(from: csvURL, into: folder)
        try context.save()
        let page = try #require(imported.pages.first)
        let originalAttachment = try #require(imported.attachments.first { $0.kind == .csv && !$0.isLocked })
        let previewAttachment = try #require(page.lockedImageAttachments.first)

        #expect(imported.note.title == "Grades")
        #expect(imported.pages.count == 1)
        #expect(imported.attachments.count == 2)
        #expect(previewAttachment.kind == .image)
        #expect(previewAttachment.rendersBehindDrawing)
        #expect(originalAttachment.originalFileName == "Grades.csv")
        #expect(FileManager.default.fileExists(atPath: storage.url(forRelativePath: originalAttachment.storedFileName).path))
    }

    @Test @MainActor func noteExportCreatesPDFAndImageFiles() async throws {
        let context = try makeInMemoryModelContext()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesExport-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        let drawingStorage = DrawingStorageService(storage: storage)
        let thumbnailService = ThumbnailService(storage: storage, drawingStorage: drawingStorage)
        let service = ImportExportService(
            storage: storage,
            drawingStorage: drawingStorage,
            thumbnailService: thumbnailService
        )
        try storage.prepareDirectories()

        let note = NoteDocument(title: "Export Me")
        let pages = [
            NotePage(
                pageOrder: 0,
                background: NoteBackground(style: .grid, colorHex: "#FFF7BF"),
                width: 320,
                height: 420
            ),
            NotePage(
                pageOrder: 1,
                background: NoteBackground(style: .lined, colorHex: "#FFFFFF"),
                width: 320,
                height: 420
            )
        ]
        note.pages.append(contentsOf: pages)
        context.insert(note)
        try context.save()
        #expect(pages.count == 2)

        let pdfURLs = try await service.exportNote(note, format: .pdf)
        let imageURLs = try await service.exportNote(note, format: .png)

        #expect(pdfURLs.count == 1)
        #expect(pdfURLs.first?.pathExtension == "pdf")
        #expect(FileManager.default.fileExists(atPath: try #require(pdfURLs.first).path))
        #expect(PDFDocument(url: try #require(pdfURLs.first))?.pageCount == 2)

        #expect(imageURLs.count == 2)
        #expect(imageURLs.allSatisfy { $0.pathExtension == "png" })
        #expect(imageURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test @MainActor func cancelingNoteExportRemovesPartialFiles() async throws {
        let context = try makeInMemoryModelContext()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesExportCancel-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        let drawingStorage = DrawingStorageService(storage: storage)
        let thumbnailService = ThumbnailService(storage: storage, drawingStorage: drawingStorage)
        let service = ImportExportService(
            storage: storage,
            drawingStorage: drawingStorage,
            thumbnailService: thumbnailService
        )
        try storage.prepareDirectories()

        let note = NoteDocument(title: "Cancel Export")
        let pages = (0..<3).map { index in
            NotePage(
                pageOrder: index,
                background: NoteBackground(style: .plain, colorHex: "#FFFFFF"),
                width: 320,
                height: 420
            )
        }
        note.pages.append(contentsOf: pages)
        context.insert(note)
        try context.save()
        #expect(pages.count == 3)

        var exportTask: Task<[URL], Error>?
        exportTask = Task { @MainActor in
            try await service.exportNoteForSharing(note, format: .png) { _, message in
                if message.contains("page 2") {
                    exportTask?.cancel()
                }
            }
        }

        do {
            _ = try await #require(exportTask).value
            Issue.record("Expected export cancellation to throw.")
        } catch is CancellationError {
            let exportDirectory = try storage.directoryURL(for: .exports)
            let contents = try FileManager.default.contentsOfDirectory(
                at: exportDirectory,
                includingPropertiesForKeys: nil
            )
            #expect(contents.isEmpty)
        }
    }

}
