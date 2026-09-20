import Foundation
import PDFKit
import SwiftData
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import BeanNotes

private final class ImportFixtureBundle: NSObject {}

@MainActor
private final class ImportTestStore {
    let container: ModelContainer
    let context: ModelContext
    let folder: NotebookFolder

    init(folderName: String) throws {
        let schema = Schema([NotebookFolder.self, NoteDocument.self, NotePage.self, Attachment.self])
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        context = ModelContext(container)
        folder = NotebookFolder(name: folderName)
        context.insert(folder)
        try context.save()
    }
}

@Suite(.serialized)
@MainActor
struct DocumentImportTests {
    @Test func spreadsheetsIncludeRowsBeyondTheFirstScreen() async throws {
        let source = try #require(Bundle(for: ImportFixtureBundle.self).url(forResource: "AllRows", withExtension: "xlsx"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LocalStorageService(rootURL: root)
        try storage.prepareDirectories()
        let store = try ImportTestStore(folderName: "Sheets")
        defer { withExtendedLifetime(store) {} }
        let imported = try await ImportExportService(storage: storage).importDocumentAsNote(from: source, into: store.folder)
        let path = try #require(imported.pages.first?.lockedImageAttachments.first?.vectorSourceStoredFileName)
        let pdf = try #require(PDFDocument(url: storage.url(forRelativePath: path)))
        #expect(pdf.string?.contains("Row 160 must be imported") == true)
        let lastRow = try #require(pdf.findString("Row 160 must be imported", withOptions: []).first)
        let lastPage = try #require(lastRow.pages.first)
        #expect(lastPage.bounds(for: .mediaBox).contains(lastRow.bounds(for: lastPage)))
    }

    @Test(arguments: ["html", "docx", "pptx", "doc", "ppt", "rtf", "xlsx", "xls"])
    func printableDocumentsPreserveEveryPageAndOriginal(fileExtension: String) async throws {
        let source = try #require(Bundle(for: ImportFixtureBundle.self).url(forResource: "ThreePages", withExtension: fileExtension))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LocalStorageService(rootURL: root)
        try storage.prepareDirectories()
        let service = ImportExportService(storage: storage)
        let store = try ImportTestStore(folderName: "Imports")
        defer { withExtendedLifetime(store) {} }
        let imported = try await service.importDocumentAsNote(from: source, into: store.folder)
        #expect(imported.note.title == "ThreePages")
        if ["doc", "xlsx", "xls", "rtf"].contains(fileExtension) {
            // iOS reflows legacy Word and spreadsheet previews. Require complete
            // content below without asserting pagination the platform discards.
            #expect(!imported.pages.isEmpty)
        } else {
            #expect(imported.pages.count == 3)
        }
        let original = try #require(imported.attachments.first { !$0.isLocked })
        #expect(original.originalFileName == source.lastPathComponent)
        #expect(try Data(contentsOf: service.originalFileURL(for: original)) == Data(contentsOf: source))
        let background = try #require(imported.pages.first?.lockedImageAttachments.first)
        let pdfPath = try #require(background.vectorSourceStoredFileName)
        let pdf = try #require(PDFDocument(url: storage.url(forRelativePath: pdfPath)))
        #expect(pdf.pageCount == imported.pages.count)
        #expect(pdf.string?.contains("First page marker") == true)
        #expect(pdf.string?.contains("Middle page marker") == true)
        #expect(pdf.string?.contains("Final page marker") == true)
        #expect(imported.pages.allSatisfy { $0.lockedImageAttachments.count == 1 })
    }

    @Test func destinationMemoryIgnoresUnavailableFolders() throws {
        let name = "BeanNotesImportTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = UUID(), last = UUID()
        #expect(DocumentImportPreferences.initialFolderID(available: [first, last], defaults: defaults) == first)
        DocumentImportPreferences.remember(folderID: last, in: defaults)
        #expect(DocumentImportPreferences.initialFolderID(available: [first, last], defaults: defaults) == last)
        #expect(DocumentImportPreferences.initialFolderID(available: [first], defaults: defaults) == first)
        #expect(DocumentImportPreferences.initialFolderID(available: [], defaults: defaults) == nil)
    }

    @Test(arguments: [true, false, nil] as [Bool?])
    func sharedImportOpensOnlyWhenRequested(openAfterImport: Bool?) async throws {
        let schema = Schema([NotebookFolder.self, NoteDocument.self, NotePage.self, Attachment.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        defer { withExtendedLifetime(container) {} }
        let context = ModelContext(container)
        let folder = NotebookFolder(name: "Remembered folder")
        context.insert(folder)
        try context.save()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LocalStorageService(rootURL: root.appendingPathComponent("Storage"))
        try storage.prepareDirectories()
        let inbox = root.appendingPathComponent("Inbox")
        let request = inbox.appendingPathComponent("Requests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: request.appendingPathComponent("0"), withIntermediateDirectories: true)
        try Data("Every line must remain in this note.".utf8).write(to: request.appendingPathComponent("0/Original Name.txt"))
        var manifest: [String: Any] = [
            "id": UUID().uuidString, "title": "", "folderID": folder.id.uuidString,
            "importMode": "notePages", "files": ["0/Original Name.txt"]
        ]
        if let openAfterImport { manifest["openAfterImport"] = openAfterImport }
        try JSONSerialization.data(withJSONObject: manifest).write(to: request.appendingPathComponent("request.json"))
        let service = ImportExportService(storage: storage)
        let result = try await service.absorbSharedInbox(into: context, inboxURL: inbox)
        #expect(result.failureMessages.isEmpty)
        #expect(result.notesToOpen.count == (openAfterImport == true ? 1 : 0))
        #expect(folder.notes.count == 1)
        #expect(folder.notes.first?.title == "Original Name")
        #expect(folder.notes.first?.pages.count == 1)
        #expect(!FileManager.default.fileExists(atPath: request.path))
        let second = try await service.absorbSharedInbox(into: context, inboxURL: inbox)
        #expect(second.notesToOpen.isEmpty)
        #expect(folder.notes.count == 1)
    }

    @Test func longTextImportDoesNotTruncateAfterPreviewLines() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LocalStorageService(rootURL: root)
        try storage.prepareDirectories()
        let source = root.appendingPathComponent("Long Notes.txt")
        let text = (1...180).map { "Line \($0): all content should be imported." }.joined(separator: "\n")
        try Data(text.utf8).write(to: source)
        let store = try ImportTestStore(folderName: "Text")
        defer { withExtendedLifetime(store) {} }
        let imported = try await ImportExportService(storage: storage).importDocumentAsNote(from: source, into: store.folder)
        #expect(imported.pages.count > 1)
        let path = try #require(imported.pages.first?.lockedImageAttachments.first?.vectorSourceStoredFileName)
        let pdf = try #require(PDFDocument(url: storage.url(forRelativePath: path)))
        #expect(pdf.string?.contains("Line 180:") == true)
    }

    @Test func sharedNamesPreserveDocumentTitlesAndExtensions() {
        #expect(SharedDocumentName.title(for: " ") == nil)
        #expect(SharedDocumentName.title(for: "0/Lecture 1.pptx") == "Lecture 1")
        #expect(SharedDocumentName.title(for: "Study notes v1.2") == "Study notes v1.2")
        #expect(SharedDocumentName.fileName(sourceURL: URL(fileURLWithPath: "/tmp/Exam.docx"), suggestedName: nil,
                                          typeIdentifier: "public.data") == "Exam.docx")
        #expect(SharedDocumentName.fileName(sourceURL: nil, suggestedName: "Diagram",
                                          typeIdentifier: "public.png") == "Diagram.png")
        #expect(SharedDocumentName.fileName(sourceURL: URL(fileURLWithPath: "/tmp/Lecture.pptx"), suggestedName: "Shared Notes",
                                          typeIdentifier: "public.data") == "Lecture.pptx")
        #expect(SharedDocumentName.fileName(sourceURL: URL(fileURLWithPath: "/tmp/Image.png"), suggestedName: "Image.jpg",
                                          typeIdentifier: "public.png") == "Image.png")
        #expect(SharedDocumentName.fileName(sourceURL: URL(fileURLWithPath: "/tmp/provider.tmp"), suggestedName: "Lecture.docx",
                                          typeIdentifier: "org.openxmlformats.wordprocessingml.document") == "Lecture.docx")
        #expect(SharedDocumentName.fileName(sourceURL: URL(fileURLWithPath: "/tmp/provider.tmp"), suggestedName: "Lecture.docx",
                                          typeIdentifier: "public.data") == "Lecture.docx")
    }

    @Test(arguments: [UTType.png.identifier, UTType.image.identifier, UTType.data.identifier])
    func dataOnlyImageProvidersKeepFileNamesAndImageBytes(typeIdentifier: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try #require(UIGraphicsImageRenderer(size: CGSize(width: 48, height: 32)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        }.pngData())
        let provider = NSItemProvider()
        provider.suggestedName = "Original Diagram"
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        let name: String = try await withCheckedThrowingContinuation { continuation in
            SharedItemFileReader.writeRepresentation(from: provider, typeIdentifier: typeIdentifier, into: root) {
                continuation.resume(with: $0)
            }
        }
        #expect(name == "Original Diagram.png")
        #expect(try Data(contentsOf: root.appendingPathComponent(name)) == data)
    }

    @Test(arguments: ["png", "jpg", "jpeg", "PNG", "JPEG"])
    func commonImageExtensionsCreateFullImagePages(fileExtension: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LocalStorageService(rootURL: root)
        try storage.prepareDirectories()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        let data = try #require(fileExtension.lowercased() == "png" ? image.pngData() : image.jpegData(compressionQuality: 0.9))
        let source = root.appendingPathComponent("Original Image.\(fileExtension)")
        try data.write(to: source)
        let store = try ImportTestStore(folderName: "Images")
        defer { withExtendedLifetime(store) {} }
        let imported = try await ImportExportService(storage: storage).importDocumentAsNote(from: source, into: store.folder)
        #expect(imported.note.title == "Original Image")
        #expect(imported.pages.count == 1)
        let page = try #require(imported.pages.first)
        let attachment = try #require(page.lockedImageAttachments.first)
        #expect(abs(page.width / page.height - 1.5) < 0.01)
        #expect(try Data(contentsOf: storage.url(forRelativePath: attachment.storedFileName)) == data)
    }
}
