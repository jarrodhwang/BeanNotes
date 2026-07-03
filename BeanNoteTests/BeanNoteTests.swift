//
//  BeanNoteTests.swift
//  BeanNoteTests
//
//  Created by Jarrod on 2026-07-02.
//

import Testing
@testable import BeanNote
import Foundation
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

}
