//
//  BeanNoteTests.swift
//  BeanNoteTests
//
//  Created by Jarrod on 2026-07-02.
//

import Testing
@testable import BeanNote
import Foundation
import PDFKit
import PencilKit
import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

struct BeanNoteTests {

    @Test func modelGraphCreatesFolderNotePageAndAttachment() throws {
        let schema = Schema([
            NotebookFolder.self,
            NoteDocument.self,
            NotePage.self,
            Attachment.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let folder = NotebookFolder(name: "Projects", colorHex: "#5B8DEF")
        let note = NoteDocument(title: "Roast Notes", folder: folder)
        let page = NotePage(pageOrder: 0, background: NoteBackground(style: .grid, colorHex: "#FFFFFF"), note: note)
        let attachment = Attachment(
            kind: .pdf,
            displayName: "Menu",
            originalFileName: "menu.pdf",
            storedFileName: "Imports/menu.pdf",
            contentTypeIdentifier: UTType.pdf.identifier,
            fileExtension: "pdf",
            page: page
        )

        folder.notes.append(note)
        note.pages.append(page)
        page.attachments.append(attachment)

        context.insert(folder)
        context.insert(note)
        context.insert(page)
        context.insert(attachment)

        try context.save()

        let folders = try context.fetch(FetchDescriptor<NotebookFolder>())
        #expect(folders.count == 1)
        #expect(folders[0].sortedNotes.first?.title == "Roast Notes")
        #expect(folders[0].sortedNotes.first?.sortedPages.first?.background.style == .grid)
        #expect(folders[0].sortedNotes.first?.sortedPages.first?.attachments.first?.kind == .pdf)
    }

    @Test func localStorageCreatesAppRelativePaths() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNoteTests-\(UUID().uuidString)", isDirectory: true)
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

    @Test func noteBackgroundDefaultsResolveStyleAndColor() {
        let dottedYellow = NoteBackground.fromDefaults(styleRaw: NoteBackgroundStyle.dotted.rawValue, colorHex: "#FFF7BF")
        let fallback = NoteBackground.fromDefaults(styleRaw: "unknown", colorHex: "")

        #expect(dottedYellow.style == .dotted)
        #expect(dottedYellow.colorHex == "#FFF7BF")
        #expect(fallback.style == .plain)
        #expect(fallback.colorHex == NoteBackground.defaultColorHex)
        #expect(NoteBackground.colorPresets.contains { $0.name == "Beige" })
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

    @Test @MainActor func thumbnailGenerationStoresFirstPagePreview() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNoteThumbnail-\(UUID().uuidString)", isDirectory: true)
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
            page: page
        )
        page.attachments.append(attachment)

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
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotePDFImport-\(UUID().uuidString)", isDirectory: true)
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
        let imported = try await service.importDocumentAsNote(from: pdfURL, into: folder)

        #expect(imported.note.title == "Syllabus")
        #expect(imported.pages.count == 2)
        #expect(imported.pages.allSatisfy { $0.lockedImageAttachments.count == 1 })
        #expect(imported.attachments.contains { $0.kind == .pdf && !$0.isLocked })

        let lockedImage = try #require(imported.pages.first?.lockedImageAttachments.first)
        #expect(FileManager.default.fileExists(atPath: storage.url(forRelativePath: lockedImage.storedFileName).path))
    }

    @Test @MainActor func imageImportCreatesAnnotatableImageNote() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNoteImageImport-\(UUID().uuidString)", isDirectory: true)
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
        let imported = try await service.importDocumentAsNote(from: imageURL, into: folder)
        let page = try #require(imported.pages.first)
        let lockedImage = try #require(page.lockedImageAttachments.first)

        #expect(imported.note.title == "Diagram")
        #expect(imported.pages.count == 1)
        #expect(imported.attachments.count == 1)
        #expect(lockedImage.kind == .image)
        #expect(lockedImage.isLocked)
        #expect(lockedImage.x == 0)
        #expect(lockedImage.y == 0)
        #expect(lockedImage.width == page.width)
        #expect(lockedImage.height == page.height)
        #expect(folder.notes.contains { $0.id == imported.note.id })
        #expect(FileManager.default.fileExists(atPath: storage.url(forRelativePath: lockedImage.storedFileName).path))
    }

    @Test @MainActor func csvImportCreatesPreviewNoteAndKeepsOriginalFile() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNoteCSVImport-\(UUID().uuidString)", isDirectory: true)
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
        let imported = try await service.importDocumentAsNote(from: csvURL, into: folder)
        let page = try #require(imported.pages.first)
        let originalAttachment = try #require(imported.attachments.first { $0.kind == .csv && !$0.isLocked })
        let previewAttachment = try #require(page.lockedImageAttachments.first)

        #expect(imported.note.title == "Grades")
        #expect(imported.pages.count == 1)
        #expect(imported.attachments.count == 2)
        #expect(previewAttachment.kind == .image)
        #expect(originalAttachment.originalFileName == "Grades.csv")
        #expect(FileManager.default.fileExists(atPath: storage.url(forRelativePath: originalAttachment.storedFileName).path))
    }

    @Test @MainActor func noteExportCreatesPDFAndImageFiles() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNoteExport-\(UUID().uuidString)", isDirectory: true)
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
        let firstPage = NotePage(
            pageOrder: 0,
            background: NoteBackground(style: .grid, colorHex: "#FFF7BF"),
            width: 320,
            height: 420,
            note: note
        )
        let secondPage = NotePage(
            pageOrder: 1,
            background: NoteBackground(style: .lined, colorHex: "#FFFFFF"),
            width: 320,
            height: 420,
            note: note
        )
        note.pages.append(firstPage)
        note.pages.append(secondPage)

        let pdfURLs = try service.exportNote(note, format: .pdf)
        let imageURLs = try service.exportNote(note, format: .png)

        #expect(pdfURLs.count == 1)
        #expect(pdfURLs.first?.pathExtension == "pdf")
        #expect(FileManager.default.fileExists(atPath: try #require(pdfURLs.first).path))
        #expect(PDFDocument(url: try #require(pdfURLs.first))?.pageCount == 2)

        #expect(imageURLs.count == 2)
        #expect(imageURLs.allSatisfy { $0.pathExtension == "png" })
        #expect(imageURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

}
