//
//  BeanNotesTests.swift
//  BeanNotesTests
//
//  Created by Jarrod on 2026-07-02.
//

import Testing
@testable import BeanNotes
import Foundation
import ImageIO
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

    private func makeTestDrawing(color: UIColor, xOffset: CGFloat) -> PKDrawing {
        let points = [
            PKStrokePoint(
                location: CGPoint(x: 12 + xOffset, y: 18),
                timeOffset: 0,
                size: CGSize(width: 7, height: 7),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ),
            PKStrokePoint(
                location: CGPoint(x: 72 + xOffset, y: 84),
                timeOffset: 0.18,
                size: CGSize(width: 7, height: 7),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_800_000_000))
        let stroke = PKStroke(ink: PKInk(.pen, color: color), path: path)
        return PKDrawing(strokes: [stroke])
    }

    private func attachPDFVersion(
        named name: String,
        storedBaseName: String,
        to pages: [NotePage],
        createdAt: Date
    ) -> [BeanNotes.Attachment] {
        precondition(!pages.isEmpty)
        let sourcePath = "Imports/\(storedBaseName).pdf"
        var attachments = pages.enumerated().map { index, page in
            let background = Attachment(
                kind: .image,
                displayName: "\(name) Page \(index + 1)",
                originalFileName: "\(storedBaseName)-page-\(index + 1).jpg",
                storedFileName: "Imports/\(storedBaseName)-page-\(index + 1).jpg",
                contentTypeIdentifier: UTType.jpeg.identifier,
                fileExtension: "jpg",
                x: 0,
                y: 0,
                width: page.normalizedWidth,
                height: page.normalizedHeight,
                isLocked: true,
                rendersBehindDrawing: true,
                vectorSourceStoredFileName: sourcePath,
                vectorSourcePageIndex: index,
                createdAt: createdAt,
                updatedAt: createdAt
            )
            page.attachments.append(background)
            return background
        }
        let source = Attachment(
            kind: .pdf,
            displayName: name,
            originalFileName: "\(storedBaseName).pdf",
            storedFileName: sourcePath,
            contentTypeIdentifier: UTType.pdf.identifier,
            fileExtension: "pdf",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        pages[0].attachments.append(source)
        attachments.append(source)
        return attachments
    }

    private func makeTestStroke(
        from start: CGPoint,
        to end: CGPoint,
        width: CGFloat = 6,
        color: UIColor = .black,
        transform: CGAffineTransform = .identity
    ) -> PKStroke {
        let points = [
            PKStrokePoint(
                location: start,
                timeOffset: 0,
                size: CGSize(width: width, height: width),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ),
            PKStrokePoint(
                location: end,
                timeOffset: 0.2,
                size: CGSize(width: width, height: width),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: .distantPast)
        return PKStroke(
            ink: PKInk(.pen, color: color),
            path: path,
            transform: transform,
            mask: nil
        )
    }

    private func imageContainsDominantRedInk(_ image: UIImage) -> Bool {
        guard let source = image.cgImage else { return false }

        let width = min(source.width, 384)
        let height = min(source.height, 512)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }

        context.interpolationQuality = .low
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        return stride(from: 0, to: pixels.count, by: 4).contains { offset in
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            return red > 145 && red > green + 45 && red > blue + 45
        }
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

    @Test func pageEditAddsAboveWithInheritedPaper() throws {
        let context = try makeInMemoryModelContext()
        let leadingPage = NotePage(pageOrder: 0)
        let targetBackground = NoteBackground(
            style: .grid,
            colorHex: "#FFF7BF",
            spacing: 24,
            marginWidth: 42
        )
        let targetPage = NotePage(
            pageOrder: 1,
            background: targetBackground,
            width: 612,
            height: 792
        )
        let trailingPage = NotePage(pageOrder: 2)
        let note = NoteDocument(
            title: "Add Above",
            pages: [trailingPage, targetPage, leadingPage]
        )
        context.insert(note)

        let result = try #require(NotePageEditCommand.applyAdd(
            relativeTo: targetPage,
            placement: .above,
            in: note,
            selectedPageID: targetPage.id
        ))
        let addedPage = result.change.page
        let expectedPageIDs = [
            leadingPage.id,
            addedPage.id,
            targetPage.id,
            trailingPage.id
        ]

        #expect(note.sortedPages.map(\.id) == expectedPageIDs)
        #expect(note.sortedPages.map(\.pageOrder) == [0, 1, 2, 3])
        #expect(addedPage.background == targetBackground)
        #expect(addedPage.pageSize == targetPage.pageSize)
        #expect(result.selectedPageID == addedPage.id)
        #expect(result.change.originalIndex == 1)
        #expect(result.change.priorSelectedPageID == targetPage.id)
        #expect(result.change.kind == .added(placement: .above))
    }

    @Test func pageEditAddsBelowWithInheritedPaper() throws {
        let context = try makeInMemoryModelContext()
        let targetBackground = NoteBackground(
            style: .lined,
            colorHex: "#DDEBFF",
            spacing: 31,
            marginWidth: 70
        )
        let targetPage = NotePage(
            pageOrder: 0,
            background: targetBackground,
            width: 1_200,
            height: 900
        )
        let trailingPage = NotePage(pageOrder: 1)
        let note = NoteDocument(title: "Add Below", pages: [targetPage, trailingPage])
        context.insert(note)

        let result = try #require(NotePageEditCommand.applyAdd(
            relativeTo: targetPage,
            placement: .below,
            in: note,
            selectedPageID: targetPage.id
        ))
        let addedPage = result.change.page

        #expect(note.sortedPages.map(\.id) == [targetPage.id, addedPage.id, trailingPage.id])
        #expect(note.sortedPages.map(\.pageOrder) == [0, 1, 2])
        #expect(addedPage.background == targetBackground)
        #expect(addedPage.pageSize == targetPage.pageSize)
        #expect(result.selectedPageID == addedPage.id)
        #expect(result.change.originalIndex == 1)
        #expect(result.change.kind == .added(placement: .below))
    }

    @Test func pageEditRemoveChoosesFallbackAndRefusesSolePage() throws {
        let context = try makeInMemoryModelContext()
        let firstPage = NotePage(pageOrder: 10)
        let middlePage = NotePage(pageOrder: 20)
        let lastPage = NotePage(pageOrder: 30)
        let note = NoteDocument(title: "Remove", pages: [lastPage, firstPage, middlePage])
        context.insert(note)

        let removal = try #require(NotePageEditCommand.applyRemove(
            middlePage,
            from: note,
            selectedPageID: middlePage.id
        ))

        #expect(note.sortedPages.map(\.id) == [firstPage.id, lastPage.id])
        #expect(note.sortedPages.map(\.pageOrder) == [0, 1])
        #expect(removal.selectedPageID == lastPage.id)
        #expect(removal.change.page.id == middlePage.id)
        #expect(removal.change.originalIndex == 1)
        #expect(removal.change.priorSelectedPageID == middlePage.id)
        #expect(removal.change.kind == .removed)

        let retainedSelection = try #require(NotePageEditCommand.applyRemove(
            lastPage,
            from: note,
            selectedPageID: firstPage.id
        ))
        #expect(retainedSelection.selectedPageID == firstPage.id)
        #expect(note.sortedPages.map(\.id) == [firstPage.id])
        #expect(NotePageEditCommand.applyRemove(
            firstPage,
            from: note,
            selectedPageID: firstPage.id
        ) == nil)
        #expect(note.sortedPages.map(\.id) == [firstPage.id])
        #expect(note.sortedPages.map(\.pageOrder) == [0])
    }

    @Test func pageEditUndoAndRedoReuseExactAddedPage() throws {
        let context = try makeInMemoryModelContext()
        let firstPage = NotePage(pageOrder: 0)
        let targetPage = NotePage(pageOrder: 1)
        let note = NoteDocument(title: "Undo Add", pages: [firstPage, targetPage])
        context.insert(note)
        let addition = try #require(NotePageEditCommand.applyAdd(
            relativeTo: targetPage,
            placement: .above,
            in: note,
            selectedPageID: firstPage.id
        ))
        let addedPage = addition.change.page
        let attachment = Attachment(
            kind: .image,
            displayName: "Retained image",
            originalFileName: "retained.png",
            storedFileName: "Imports/retained.png",
            contentTypeIdentifier: UTType.png.identifier,
            fileExtension: "png"
        )
        addedPage.attachments.append(attachment)

        let undo = try #require(NotePageEditCommand.undo(addition.change, in: note))
        #expect(note.sortedPages.map(\.id) == [firstPage.id, targetPage.id])
        #expect(note.sortedPages.map(\.pageOrder) == [0, 1])
        #expect(undo.selectedPageID == firstPage.id)
        #expect(addition.change.page.attachments.first?.id == attachment.id)

        let redo = try #require(NotePageEditCommand.redo(addition.change, in: note))
        #expect(note.sortedPages.map(\.id) == [firstPage.id, addedPage.id, targetPage.id])
        #expect(note.sortedPages.map(\.pageOrder) == [0, 1, 2])
        #expect(note.sortedPages[1].id == addedPage.id)
        #expect(note.sortedPages[1].attachments.first?.id == attachment.id)
        #expect(redo.selectedPageID == addedPage.id)
    }

    @Test func pageEditUndoAndRedoReuseExactRemovedPage() throws {
        let context = try makeInMemoryModelContext()
        let firstPage = NotePage(pageOrder: 0)
        let removedPage = NotePage(pageOrder: 1)
        let lastPage = NotePage(pageOrder: 2)
        let attachment = Attachment(
            kind: .pdf,
            displayName: "Retained PDF",
            originalFileName: "retained.pdf",
            storedFileName: "Imports/retained.pdf",
            contentTypeIdentifier: UTType.pdf.identifier,
            fileExtension: "pdf"
        )
        removedPage.attachments.append(attachment)
        let note = NoteDocument(title: "Undo Remove", pages: [firstPage, removedPage, lastPage])
        context.insert(note)
        let originalIDs = note.sortedPages.map(\.id)

        let removal = try #require(NotePageEditCommand.applyRemove(
            removedPage,
            from: note,
            selectedPageID: removedPage.id
        ))
        #expect(removal.selectedPageID == lastPage.id)

        let undo = try #require(NotePageEditCommand.undo(removal.change, in: note))
        #expect(note.sortedPages.map(\.id) == originalIDs)
        #expect(note.sortedPages.map(\.pageOrder) == [0, 1, 2])
        #expect(note.sortedPages[1].id == removedPage.id)
        #expect(note.sortedPages[1].attachments.first?.id == attachment.id)
        #expect(undo.selectedPageID == removedPage.id)

        let redo = try #require(NotePageEditCommand.redo(removal.change, in: note))
        #expect(note.sortedPages.map(\.id) == [firstPage.id, lastPage.id])
        #expect(note.sortedPages.map(\.pageOrder) == [0, 1])
        #expect(removal.change.page.id == removedPage.id)
        #expect(removal.change.page.attachments.first?.id == attachment.id)
        #expect(redo.selectedPageID == lastPage.id)
    }

    @Test func removedPageRemainsPersistedUntilUndoWindowFinalizes() throws {
        let context = try makeInMemoryModelContext()
        let retainedPage = NotePage(pageOrder: 0)
        let removedPage = NotePage(pageOrder: 1, searchableText: "Keep this ink searchable")
        let attachment = Attachment(
            kind: .image,
            displayName: "Undo image",
            originalFileName: "undo.png",
            storedFileName: "Imports/undo.png",
            contentTypeIdentifier: UTType.png.identifier,
            fileExtension: "png"
        )
        removedPage.attachments.append(attachment)
        let note = NoteDocument(title: "Persist Undo", pages: [retainedPage, removedPage])
        context.insert(note)
        try context.save()

        let removal = try #require(NotePageEditCommand.applyRemove(
            removedPage,
            from: note,
            selectedPageID: removedPage.id
        ))
        try context.save()

        let detachedPage = try #require(
            context.fetch(FetchDescriptor<NotePage>()).first(where: { $0.id == removedPage.id })
        )
        #expect(detachedPage.note == nil)
        #expect(detachedPage.searchableText == "Keep this ink searchable")
        #expect(detachedPage.attachments.first?.id == attachment.id)

        let undo = try #require(NotePageEditCommand.undo(removal.change, in: note))
        try context.save()

        #expect(note.sortedPages.map(\.id) == [retainedPage.id, removedPage.id])
        #expect(note.sortedPages[1].attachments.first?.id == attachment.id)
        #expect(undo.selectedPageID == removedPage.id)
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

    @Test func imageAttachmentsDefaultBehindDrawingAndAllowForegroundOverride() {
        let backgroundImage = Attachment(
            kind: .image,
            displayName: "Pasted Image",
            originalFileName: "pasted.png",
            storedFileName: "Imports/pasted.png",
            contentTypeIdentifier: UTType.png.identifier,
            fileExtension: "png"
        )
        let foregroundImage = Attachment(
            kind: .image,
            displayName: "Foreground Image",
            originalFileName: "foreground.png",
            storedFileName: "Imports/foreground.png",
            contentTypeIdentifier: UTType.png.identifier,
            fileExtension: "png",
            rendersBehindDrawing: false
        )
        let document = Attachment(
            kind: .pdf,
            displayName: "Document",
            originalFileName: "document.pdf",
            storedFileName: "Imports/document.pdf",
            contentTypeIdentifier: UTType.pdf.identifier,
            fileExtension: "pdf"
        )

        #expect(backgroundImage.rendersBehindDrawing)
        #expect(!foregroundImage.rendersBehindDrawing)
        #expect(!document.rendersBehindDrawing)
    }

    @Test func libraryNoteOrderDoesNotChangeWhenContentIsSaved() {
        let olderCreation = Date(timeIntervalSince1970: 1_700_000_000)
        let newerCreation = Date(timeIntervalSince1970: 1_800_000_000)
        let olderNote = NoteDocument(
            title: "Older",
            createdAt: olderCreation,
            updatedAt: Date(timeIntervalSince1970: 1_900_000_000)
        )
        let newerNote = NoteDocument(
            title: "Newer",
            createdAt: newerCreation,
            updatedAt: newerCreation
        )
        let notes = [olderNote, newerNote]

        #expect(notes.sorted(by: NoteDocument.libraryOrder).map(\.id) == [newerNote.id, olderNote.id])

        olderNote.touch(at: Date(timeIntervalSince1970: 2_000_000_000))

        #expect(notes.sorted(by: NoteDocument.libraryOrder).map(\.id) == [newerNote.id, olderNote.id])
    }

    @Test func folderArchiveServiceArchivesContentsAndCanUnarchive() throws {
        let context = try makeInMemoryModelContext()
        let folder = NotebookFolder(name: "Completed Projects")
        let note = NoteDocument(title: "Project Notes")
        folder.notes.append(note)
        context.insert(folder)
        try context.save()

        let archivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let service = FolderArchiveService()

        #expect(try service.archive(folder, at: archivedAt, in: context))
        #expect(folder.isArchived)
        #expect(folder.archivedAt == archivedAt)
        #expect(folder.activeSortedNotes.map(\.id) == [note.id])
        #expect(try !service.archive(folder, at: archivedAt.addingTimeInterval(60), in: context))
        #expect(folder.archivedAt == archivedAt)

        #expect(try service.unarchive(folder, in: context))
        #expect(!folder.isArchived)
        #expect(folder.archivedAt == nil)
        #expect(folder.activeSortedNotes.map(\.id) == [note.id])
        #expect(try !service.unarchive(folder, in: context))
    }

    @Test func archivedFoldersGroupByYearAndSortByNewestArchiveDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let olderDate = calendar.date(from: DateComponents(year: 2024, month: 12, day: 31))!
        let earlierCurrentYearDate = calendar.date(from: DateComponents(year: 2025, month: 2, day: 1))!
        let newerDate = calendar.date(from: DateComponents(year: 2025, month: 11, day: 15))!
        let activeFolder = NotebookFolder(name: "Active")
        let olderFolder = NotebookFolder(name: "Older", archivedAt: olderDate)
        let earlierCurrentYearFolder = NotebookFolder(name: "Earlier", archivedAt: earlierCurrentYearDate)
        let newerFolder = NotebookFolder(name: "Newer", archivedAt: newerDate)

        let sections = ArchivedFolderOrganizer.sections(
            from: [activeFolder, olderFolder, earlierCurrentYearFolder, newerFolder],
            calendar: calendar
        )

        #expect(sections.map(\.year) == [2025, 2024])
        #expect(sections[0].folders.map(\.id) == [newerFolder.id, earlierCurrentYearFolder.id])
        #expect(sections[1].folders.map(\.id) == [olderFolder.id])
    }

    @Test func trashPolicyExpiresNotesAtThirtyDays() {
        let trashedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let justBeforeExpiration = trashedAt.addingTimeInterval(NoteTrashPolicy.retentionInterval - 1)
        let expiration = trashedAt.addingTimeInterval(NoteTrashPolicy.retentionInterval)

        #expect(NoteTrashPolicy.retentionDays == 30)
        #expect(!NoteTrashPolicy.shouldPurge(trashedAt: nil, now: expiration))
        #expect(!NoteTrashPolicy.shouldPurge(trashedAt: trashedAt, now: justBeforeExpiration))
        #expect(NoteTrashPolicy.shouldPurge(trashedAt: trashedAt, now: expiration))
        #expect(NoteTrashPolicy.remainingDays(trashedAt: trashedAt, now: trashedAt) == 30)
    }

    @Test func trashServiceMovesAndRestoresNotesToSelectedFolder() throws {
        let context = try makeInMemoryModelContext()
        let sourceFolder = NotebookFolder(name: "Inbox")
        let destinationFolder = NotebookFolder(name: "Archive")
        let firstNote = NoteDocument(title: "First")
        let secondNote = NoteDocument(title: "Second")
        sourceFolder.notes.append(contentsOf: [firstNote, secondNote])
        context.insert(sourceFolder)
        context.insert(destinationFolder)
        try context.save()

        let trashedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let movedIDs = try NoteTrashService().moveToTrash(
            [firstNote, firstNote],
            at: trashedAt,
            in: context
        )

        #expect(movedIDs == [firstNote.id])
        #expect(firstNote.trashedAt == trashedAt)
        #expect(firstNote.folder?.id == sourceFolder.id)
        #expect(sourceFolder.activeSortedNotes.map(\.id) == [secondNote.id])
        #expect(sourceFolder.activeNoteCount == 1)

        let restoredAt = trashedAt.addingTimeInterval(60)
        let restoredIDs = try NoteTrashService().restore(
            [firstNote],
            to: destinationFolder,
            at: restoredAt,
            in: context
        )

        #expect(restoredIDs == [firstNote.id])
        #expect(firstNote.trashedAt == nil)
        #expect(firstNote.folder?.id == destinationFolder.id)
        #expect(sourceFolder.activeNoteCount == 1)
        #expect(destinationFolder.activeSortedNotes.map(\.id) == [firstNote.id])
        #expect(destinationFolder.updatedAt == restoredAt)
    }

    @Test func trashMoveCanBeUndoneWithoutChangingOriginalFolders() throws {
        let context = try makeInMemoryModelContext()
        let firstFolder = NotebookFolder(name: "Inbox")
        let secondFolder = NotebookFolder(name: "Projects")
        let firstNote = NoteDocument(title: "First")
        let secondNote = NoteDocument(title: "Second")
        let activeNote = NoteDocument(title: "Active")
        firstFolder.notes.append(contentsOf: [firstNote, activeNote])
        secondFolder.notes.append(secondNote)
        context.insert(firstFolder)
        context.insert(secondFolder)
        try context.save()

        try NoteTrashService().moveToTrash([firstNote, secondNote], in: context)
        let restoredAt = Date(timeIntervalSince1970: 1_900_000_000)
        let restoredIDs = try NoteTrashService().undoMoveToTrash(
            [firstNote, secondNote, firstNote, activeNote],
            at: restoredAt,
            in: context
        )

        #expect(restoredIDs == [firstNote.id, secondNote.id])
        #expect(firstNote.trashedAt == nil)
        #expect(secondNote.trashedAt == nil)
        #expect(firstNote.folder?.id == firstFolder.id)
        #expect(secondNote.folder?.id == secondFolder.id)
        #expect(firstFolder.updatedAt == restoredAt)
        #expect(secondFolder.updatedAt == restoredAt)
    }

    @Test func deletingFolderMovesItsContentsToTrashWithoutDeletingNotes() throws {
        let context = try makeInMemoryModelContext()
        let folder = NotebookFolder(name: "Projects")
        let activeNote = NoteDocument(title: "Active")
        let existingTrashDate = Date(timeIntervalSince1970: 1_700_000_000)
        let alreadyTrashedNote = NoteDocument(title: "Already Trashed", trashedAt: existingTrashDate)
        folder.notes.append(contentsOf: [activeNote, alreadyTrashedNote])
        context.insert(folder)
        try context.save()

        let activeNoteID = activeNote.id
        let alreadyTrashedNoteID = alreadyTrashedNote.id
        let deletionDate = Date(timeIntervalSince1970: 1_800_000_000)
        let movedIDs = try NoteTrashService().moveContentsToTrashAndDelete(
            folder,
            at: deletionDate,
            in: context
        )
        let remainingFolders = try context.fetch(FetchDescriptor<NotebookFolder>())
        let remainingNotes = try context.fetch(FetchDescriptor<NoteDocument>())

        #expect(movedIDs == [activeNoteID, alreadyTrashedNoteID])
        #expect(remainingFolders.isEmpty)
        #expect(Set(remainingNotes.map(\.id)) == [activeNoteID, alreadyTrashedNoteID])
        #expect(activeNote.trashedAt == deletionDate)
        #expect(alreadyTrashedNote.trashedAt == existingTrashDate)
        #expect(remainingNotes.allSatisfy { $0.folder == nil })
    }

    @Test func trashServicePurgesOnlyExpiredNotes() throws {
        let context = try makeInMemoryModelContext()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let folder = NotebookFolder(name: "Inbox")
        let expiredNote = NoteDocument(
            title: "Expired",
            trashedAt: now.addingTimeInterval(-NoteTrashPolicy.retentionInterval)
        )
        let recentTrashNote = NoteDocument(
            title: "Recent",
            trashedAt: now.addingTimeInterval(-NoteTrashPolicy.retentionInterval + 1)
        )
        let activeNote = NoteDocument(title: "Active")
        let expiredNoteID = expiredNote.id
        let recentTrashNoteID = recentTrashNote.id
        let activeNoteID = activeNote.id
        folder.notes.append(contentsOf: [expiredNote, recentTrashNote, activeNote])
        context.insert(folder)
        try context.save()

        let result = try NoteTrashService().purgeExpiredNotes(in: context, now: now)
        let remainingNotes = try context.fetch(FetchDescriptor<NoteDocument>())

        #expect(result.deletedNoteIDs == [expiredNoteID])
        #expect(result.cleanupReport.failedRelativePaths.isEmpty)
        #expect(Set(remainingNotes.map(\.id)) == [recentTrashNoteID, activeNoteID])
    }

    @Test func permanentTrashDeletionRemovesLocalFilesOnlyAtFinalDelete() throws {
        let context = try makeInMemoryModelContext()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesTrashCleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let folder = NotebookFolder(name: "Inbox")
        let note = NoteDocument(title: "Recoverable")
        let page = NotePage(pageOrder: 0)
        let drawing = try storage.saveData(
            Data("drawing".utf8),
            fileName: page.drawingFileName,
            contentType: .data,
            to: .drawings,
            replacingExisting: true
        )
        let imported = try storage.saveData(
            Data("attachment".utf8),
            preferredName: "Attachment.pdf",
            contentType: .pdf,
            to: .imports
        )
        let attachment = Attachment(
            kind: .pdf,
            displayName: "Attachment",
            originalFileName: "Attachment.pdf",
            storedFileName: imported.relativePath,
            contentTypeIdentifier: UTType.pdf.identifier,
            fileExtension: "pdf"
        )
        folder.notes.append(note)
        note.pages.append(page)
        page.attachments.append(attachment)
        context.insert(folder)
        try context.save()

        let service = NoteTrashService(storage: storage)
        try service.moveToTrash([note], in: context)

        #expect(FileManager.default.fileExists(atPath: storage.url(forRelativePath: drawing.relativePath).path))
        #expect(FileManager.default.fileExists(atPath: storage.url(forRelativePath: imported.relativePath).path))

        let result = try service.permanentlyDelete([note], in: context)

        #expect(result.cleanupReport.failedRelativePaths.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: storage.url(forRelativePath: drawing.relativePath).path))
        #expect(!FileManager.default.fileExists(atPath: storage.url(forRelativePath: imported.relativePath).path))
    }

    @Test func permanentTrashDeletionPreservesFilesReferencedByRemainingNotes() throws {
        let context = try makeInMemoryModelContext()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesSharedTrashCleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let sharedDrawingFileName = "shared-page.drawing"
        let sharedDrawing = try storage.saveData(
            Data("shared drawing".utf8),
            fileName: sharedDrawingFileName,
            contentType: .data,
            to: .drawings,
            replacingExisting: true
        )
        let sharedAttachment = try storage.saveData(
            Data("shared attachment".utf8),
            preferredName: "Shared.pdf",
            contentType: .pdf,
            to: .imports
        )

        let folder = NotebookFolder(name: "Inbox")
        let deletedNote = NoteDocument(title: "Deleted")
        let retainedNote = NoteDocument(title: "Retained")
        let deletedPage = NotePage(pageOrder: 0, drawingFileName: sharedDrawingFileName)
        let retainedPage = NotePage(pageOrder: 0, drawingFileName: sharedDrawingFileName)
        let deletedAttachment = Attachment(
            kind: .pdf,
            displayName: "Shared",
            originalFileName: "Shared.pdf",
            storedFileName: sharedAttachment.relativePath,
            contentTypeIdentifier: UTType.pdf.identifier,
            fileExtension: "pdf"
        )
        let retainedAttachment = Attachment(
            kind: .pdf,
            displayName: "Shared",
            originalFileName: "Shared.pdf",
            storedFileName: sharedAttachment.relativePath,
            contentTypeIdentifier: UTType.pdf.identifier,
            fileExtension: "pdf"
        )
        folder.notes.append(contentsOf: [deletedNote, retainedNote])
        deletedNote.pages.append(deletedPage)
        retainedNote.pages.append(retainedPage)
        deletedPage.attachments.append(deletedAttachment)
        retainedPage.attachments.append(retainedAttachment)
        context.insert(folder)
        try context.save()

        let service = NoteTrashService(storage: storage)
        try service.moveToTrash([deletedNote], in: context)
        let result = try service.permanentlyDelete([deletedNote], in: context)

        #expect(result.cleanupReport.failedRelativePaths.isEmpty)
        #expect(FileManager.default.fileExists(atPath: storage.url(forRelativePath: sharedDrawing.relativePath).path))
        #expect(FileManager.default.fileExists(atPath: storage.url(forRelativePath: sharedAttachment.relativePath).path))
        #expect(try context.fetch(FetchDescriptor<NoteDocument>()).map(\.id) == [retainedNote.id])
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

    @Test func pageTouchMarksSearchIndexStaleAndUpdatesNoteFreshness() throws {
        let context = try makeInMemoryModelContext()
        let originalDate = Date(timeIntervalSince1970: 1_800_000_000)
        let touchedDate = Date(timeIntervalSince1970: 1_800_000_300)
        let note = NoteDocument(
            title: "Indexed",
            searchIndexUpdatedAt: originalDate,
            createdAt: originalDate,
            updatedAt: originalDate
        )
        let page = NotePage(
            pageOrder: 0,
            searchableText: "Indexed text",
            searchIndexUpdatedAt: originalDate,
            createdAt: originalDate,
            updatedAt: originalDate
        )

        note.pages.append(page)
        context.insert(note)
        try context.save()
        page.touch(at: touchedDate)

        #expect(page.searchIndexUpdatedAt == nil)
        #expect(note.searchIndexUpdatedAt == nil)
        #expect(page.updatedAt == touchedDate)
        #expect(note.updatedAt == touchedDate)
    }

    @Test func notePageNormalizesCorruptStoredDimensions() {
        let page = NotePage(pageOrder: 0, width: .nan, height: .infinity)

        #expect(page.normalizedWidth == NotePage.defaultPageWidth)
        #expect(page.normalizedHeight == NotePage.defaultPageHeight)
        #expect(page.pageSize == CGSize(width: NotePage.defaultPageWidth, height: NotePage.defaultPageHeight))

        page.width = 0
        page.height = -12

        #expect(page.pageSize == CGSize(width: NotePage.defaultPageWidth, height: NotePage.defaultPageHeight))

        page.width = NotePage.maximumPageDimension + 900
        page.height = 612

        #expect(page.normalizedWidth == NotePage.maximumPageDimension)
        #expect(page.normalizedHeight == 612)
    }

    @Test func paperSizesProvideValidDimensionsIncludingLandscapeDisplayPresets() {
        let landscapePaperSizes: Set<PaperSize> = [.chalkboard, .hd, .fhd, .fhdPlus, .qhd, .qhdPlus, .fourK]

        for paperSize in PaperSize.allCases {
            #expect(paperSize.dimensions.width > 0)
            if landscapePaperSizes.contains(paperSize) {
                #expect(paperSize.dimensions.width > paperSize.dimensions.height)
            } else {
                #expect(paperSize.dimensions.height > paperSize.dimensions.width)
            }
            #expect(paperSize.dimensions.width <= NotePage.maximumPageDimension)
            #expect(paperSize.dimensions.height <= NotePage.maximumPageDimension)
        }

        #expect(PaperSize.defaultPaperSize == .letter)
        #expect(PaperSize.a4.dimensions == CGSize(width: 595, height: 842))
        #expect(PaperSize.b5.dimensions == CGSize(width: 499, height: 709))
        #expect(PaperSize.chalkboard.dimensions == CGSize(width: 960, height: 540))
        #expect(PaperSize.hd.dimensions == CGSize(width: 1_280, height: 720))
        #expect(PaperSize.fhd.dimensions == CGSize(width: 1_920, height: 1_080))
        #expect(PaperSize.fhdPlus.dimensions == CGSize(width: 1_920, height: 1_200))
        #expect(PaperSize.qhd.dimensions == CGSize(width: 2_560, height: 1_440))
        #expect(PaperSize.qhdPlus.dimensions == CGSize(width: 3_200, height: 1_800))
        #expect(PaperSize.fourK.dimensions == CGSize(width: 3_840, height: 2_160))
        #expect(PaperSize.matching(CGSize(width: 595, height: 842)) == .a4)
        #expect(PaperSize.matching(CGSize(width: 960, height: 540)) == .chalkboard)
        #expect(PaperSize.matching(CGSize(width: 1_920, height: 1_080)) == .fhd)
        #expect(PaperSize.matching(CGSize(width: 3_840, height: 2_160)) == .fourK)
        #expect(PaperSize.matching(CGSize(width: 595.25, height: 841.75)) == .a4)
        #expect(PaperSize.matching(CGSize(width: 640, height: 900)) == nil)
    }

    @Test func customPaperSizeValidatesAndNormalizesDimensions() {
        #expect(CustomPaperSize.isValid(width: 640, height: 900))
        #expect(!CustomPaperSize.isValid(width: 0, height: 900))
        #expect(!CustomPaperSize.isValid(width: 640, height: .infinity))
        #expect(!CustomPaperSize.isValid(width: 640, height: NotePage.maximumPageDimension + 1))
        let pdfMinimumSize = CGSize(width: 612, height: 792)
        #expect(CustomPaperSize.isValid(width: 612, height: 792, minimumSize: pdfMinimumSize))
        #expect(!CustomPaperSize.isValid(width: 611, height: 792, minimumSize: pdfMinimumSize))
        #expect(!CustomPaperSize.isValid(width: 612, height: 791, minimumSize: pdfMinimumSize))

        #expect(CustomPaperSize.dimensions(width: 640, height: 900) == CGSize(width: 640, height: 900))
        #expect(CustomPaperSize.dimensions(width: 0, height: .nan) == CustomPaperSize.defaultDimensions)
        #expect(CustomPaperSize.dimensions(width: 5_000, height: 6_000) == CGSize(
            width: NotePage.maximumPageDimension,
            height: NotePage.maximumPageDimension
        ))
    }

    @Test func pdfPageContentSetsTheMinimumPaperSize() {
        let page = NotePage(pageOrder: 0, width: 1_200, height: 1_600)
        let regularImage = Attachment(
            kind: .image,
            displayName: "Photo",
            originalFileName: "photo.jpg",
            storedFileName: "Imports/photo.jpg",
            contentTypeIdentifier: UTType.jpeg.identifier,
            fileExtension: "jpg",
            width: 2_000,
            height: 2_000,
            isLocked: true
        )
        let pdfPageImage = Attachment(
            kind: .image,
            displayName: "PDF Page",
            originalFileName: "document-page-1.jpg",
            storedFileName: "Imports/document-page-1.jpg",
            contentTypeIdentifier: UTType.jpeg.identifier,
            fileExtension: "jpg",
            width: 1_024,
            height: 1_325,
            isLocked: true,
            vectorSourceStoredFileName: "Imports/document.pdf",
            vectorSourcePageIndex: 0
        )
        page.attachments.append(regularImage)
        page.attachments.append(pdfPageImage)

        let minimumSize = page.minimumPDFContentSize
        #expect(minimumSize == CGSize(width: 1_024, height: 1_325))
        #expect(
            page.pageSizeFittingPDFContent(CGSize(width: 612, height: 792))
                == CGSize(width: 1_024, height: 1_325)
        )
        #expect(
            page.pageSizeFittingPDFContent(CGSize(width: 1_440, height: 1_800))
                == CGSize(width: 1_440, height: 1_800)
        )
        #expect(minimumSize.map { !PaperSize.fhdPlus.fits(minimumSize: $0) } == true)
        #expect(minimumSize.map { PaperSize.qhd.fits(minimumSize: $0) } == true)
    }

    @Test func followingPageInheritsPaperAndBackground() {
        let background = NoteBackground(style: .grid, colorHex: "#F5E8C8")
        let page = NotePage(
            pageOrder: 3,
            background: background,
            width: PaperSize.a5.dimensions.width,
            height: PaperSize.a5.dimensions.height
        )

        let followingPage = page.makeFollowingPage()

        #expect(followingPage.pageOrder == 4)
        #expect(followingPage.pageSize == page.pageSize)
        #expect(page.standardPaperSize == .a5)
        #expect(followingPage.background == background)
        #expect(followingPage.id != page.id)
        #expect(followingPage.drawingFileName != page.drawingFileName)
    }

    @Test func attachmentFrameNormalizesCorruptStoredGeometry() {
        let pageSize = CGSize(width: 612, height: 792)
        let corruptFrame = Attachment.normalizedFrame(
            x: .nan,
            y: .infinity,
            width: .nan,
            height: -.infinity,
            pageSize: pageSize
        )

        #expect(corruptFrame == CGRect(
            x: Attachment.defaultX,
            y: Attachment.defaultY,
            width: Attachment.defaultWidth,
            height: Attachment.defaultHeight
        ))

        let oversizedFrame = Attachment.normalizedFrame(
            x: 800,
            y: 900,
            width: 900,
            height: 1_200,
            pageSize: pageSize
        )

        #expect(oversizedFrame == CGRect(x: 0, y: 0, width: 612, height: 792))
    }

    @Test func attachmentEditingInitialFramePreservesAspectBoundsAndCascade() {
        let pageSize = CGSize(width: 612, height: 792)
        let sourceSize = CGSize(width: 1_200, height: 600)
        let firstFrame = AttachmentEditingGeometry.initialImageFrame(
            sourceSize: sourceSize,
            pageSize: pageSize,
            occupiedFrames: []
        )
        let secondFrame = AttachmentEditingGeometry.initialImageFrame(
            sourceSize: sourceSize,
            pageSize: pageSize,
            occupiedFrames: [firstFrame]
        )

        #expect(firstFrame == CGRect(x: 80, y: 100, width: 420, height: 210))
        #expect(abs(firstFrame.width / firstFrame.height - sourceSize.width / sourceSize.height) < 0.001)
        #expect(firstFrame.minX >= 0)
        #expect(firstFrame.minY >= 0)
        #expect(firstFrame.maxX <= pageSize.width)
        #expect(firstFrame.maxY <= pageSize.height)
        #expect(secondFrame.origin == CGPoint(x: firstFrame.minX + 24, y: firstFrame.minY + 24))
        #expect(secondFrame.size == firstFrame.size)
    }

    @Test func attachmentEditingMoveClampsToPageBounds() {
        let pageSize = CGSize(width: 612, height: 792)
        let startFrame = CGRect(x: 100, y: 200, width: 200, height: 100)

        let topLeftFrame = AttachmentEditingGeometry.movedFrame(
            from: startFrame,
            translation: CGPoint(x: -1_000, y: -1_000),
            pageSize: pageSize
        )
        let bottomRightFrame = AttachmentEditingGeometry.movedFrame(
            from: startFrame,
            translation: CGPoint(x: 1_000, y: 1_000),
            pageSize: pageSize
        )

        #expect(topLeftFrame == CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(bottomRightFrame == CGRect(x: 412, y: 692, width: 200, height: 100))
    }

    @Test func attachmentEditingResizeUsesEveryBorderProportionallyAndClampsToBounds() {
        let startFrame = CGRect(x: 100, y: 100, width: 240, height: 120)
        let pageSize = CGSize(width: 500, height: 400)
        let resizeCases: [(AttachmentResizeHandle, CGPoint, CGRect)] = [
            (.topLeft, CGPoint(x: -60, y: -30), CGRect(x: 40, y: 70, width: 300, height: 150)),
            (.top, CGPoint(x: 0, y: -30), CGRect(x: 70, y: 70, width: 300, height: 150)),
            (.topRight, CGPoint(x: 60, y: -30), CGRect(x: 100, y: 70, width: 300, height: 150)),
            (.right, CGPoint(x: 60, y: 0), CGRect(x: 100, y: 85, width: 300, height: 150)),
            (.bottomRight, CGPoint(x: 60, y: 30), CGRect(x: 100, y: 100, width: 300, height: 150)),
            (.bottom, CGPoint(x: 0, y: 30), CGRect(x: 70, y: 100, width: 300, height: 150)),
            (.bottomLeft, CGPoint(x: -60, y: 30), CGRect(x: 40, y: 100, width: 300, height: 150)),
            (.left, CGPoint(x: -60, y: 0), CGRect(x: 40, y: 85, width: 300, height: 150))
        ]

        for (handle, translation, expectedFrame) in resizeCases {
            let resizedFrame = AttachmentEditingGeometry.resizedFrame(
                from: startFrame,
                translation: translation,
                pageSize: pageSize,
                handle: handle
            )
            #expect(resizedFrame == expectedFrame)
            #expect(abs(resizedFrame.width / resizedFrame.height - 2) < 0.001)
        }

        let minimumBottomRightFrame = AttachmentEditingGeometry.resizedFrame(
            from: startFrame,
            translation: CGPoint(x: -1_000, y: -1_000),
            pageSize: pageSize,
            handle: .bottomRight
        )
        let maximumBottomRightFrame = AttachmentEditingGeometry.resizedFrame(
            from: startFrame,
            translation: CGPoint(x: 1_000, y: 1_000),
            pageSize: pageSize,
            handle: .bottomRight
        )

        #expect(minimumBottomRightFrame == CGRect(x: 100, y: 100, width: 180, height: 90))
        #expect(maximumBottomRightFrame == CGRect(x: 100, y: 100, width: 400, height: 200))
        #expect(maximumBottomRightFrame.maxX <= pageSize.width)
        #expect(maximumBottomRightFrame.maxY <= pageSize.height)
    }

    @Test func attachmentImageRenderingAspectFitsAndCenters() {
        let bounds = CGRect(x: 10, y: 20, width: 200, height: 200)

        let wideFrame = AttachmentImageRenderingGeometry.aspectFitRect(
            for: CGSize(width: 400, height: 200),
            in: bounds
        )
        let tallFrame = AttachmentImageRenderingGeometry.aspectFitRect(
            for: CGSize(width: 100, height: 200),
            in: bounds
        )

        #expect(wideFrame == CGRect(x: 10, y: 70, width: 200, height: 100))
        #expect(tallFrame == CGRect(x: 60, y: 20, width: 100, height: 200))
    }

    @Test func imagePasteServicePreservesImageDataAndSuggestedName() async throws {
        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02])
        let textProvider = NSItemProvider(object: "Not an image" as NSString)
        let imageProvider = NSItemProvider()
        imageProvider.suggestedName = "Coffee Diagram.png"
        imageProvider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            visibility: .all
        ) { completion in
            completion(imageData, nil)
            return Progress(totalUnitCount: 1)
        }

        let pastedImage = try await ImagePasteService().loadFirstImage(
            from: [textProvider, imageProvider]
        )

        #expect(pastedImage.data == imageData)
        #expect(pastedImage.originalFileName == "Coffee Diagram.png")
    }

    @Test func imagePasteServiceRejectsProvidersWithoutImages() async {
        let textProvider = NSItemProvider(object: "Not an image" as NSString)

        do {
            _ = try await ImagePasteService().loadFirstImage(from: [textProvider])
            Issue.record("Expected a clipboard without images to be rejected.")
        } catch ImagePasteError.noImageProvider {
            // Expected.
        } catch {
            Issue.record("Expected noImageProvider, received \(error).")
        }
    }

    @Test func noteCaptureSelectionMovesAndResizesWithinPageBounds() {
        let pageBounds = CGRect(x: 40, y: 60, width: 500, height: 700)
        let initialFrame = NoteCaptureSelectionGeometry.initialFrame(in: pageBounds)

        #expect(pageBounds.contains(initialFrame))
        #expect(initialFrame.width >= NoteCaptureSelectionGeometry.minimumWidth)
        #expect(initialFrame.height >= NoteCaptureSelectionGeometry.minimumHeight)

        let movedFrame = NoteCaptureSelectionGeometry.movedFrame(
            from: initialFrame,
            translation: CGPoint(x: -2_000, y: 2_000),
            in: pageBounds
        )
        #expect(movedFrame.minX == pageBounds.minX)
        #expect(movedFrame.maxY == pageBounds.maxY)

        let expandedFrame = NoteCaptureSelectionGeometry.resizedFrame(
            from: movedFrame,
            translation: CGPoint(x: 2_000, y: -2_000),
            handle: .topRight,
            in: pageBounds
        )
        #expect(expandedFrame.maxX == pageBounds.maxX)
        #expect(expandedFrame.minY == pageBounds.minY)
        #expect(pageBounds.contains(expandedFrame))

        let minimumFrame = NoteCaptureSelectionGeometry.resizedFrame(
            from: initialFrame,
            translation: CGPoint(x: -2_000, y: -2_000),
            handle: .bottomRight,
            in: pageBounds
        )
        #expect(minimumFrame.width == NoteCaptureSelectionGeometry.minimumWidth)
        #expect(minimumFrame.height == NoteCaptureSelectionGeometry.minimumHeight)
    }

    @Test func noteCaptureRendererProducesHighResolutionCrop() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesCaptureRender-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let page = NotePage(
            pageOrder: 0,
            background: .plain(colorHex: "#FFF7E8"),
            width: 400,
            height: 500
        )
        let snapshot = NotePageRenderSnapshot(
            page: page,
            theme: .standard,
            showsBeanArtwork: false
        )
        let captureRect = CGRect(x: 35, y: 45, width: 120, height: 80)
        let image = try #require(ThumbnailService.renderPageCaptureImage(
            snapshot: snapshot,
            drawing: makeTestDrawing(color: .black, xOffset: 30),
            rootURL: rootURL,
            selectionRect: captureRect,
            scale: 3
        ))
        let cgImage = try #require(image.cgImage)

        #expect(image.size == captureRect.size)
        #expect(cgImage.width == 360)
        #expect(cgImage.height == 240)
        #expect(image.pngData()?.isEmpty == false)
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

    @Test func localStorageExcludesRegenerableThumbnailsFromDeviceBackup() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesThumbnailBackup-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        let thumbnailsURL = try storage.directoryURL(for: .thumbnails)
        let values = try thumbnailsURL.resourceValues(forKeys: [.isExcludedFromBackupKey])

        #expect(values.isExcludedFromBackup == true)
    }

    @Test func modelContainerArchivesAllStoreSidecarsIntoUniqueDirectory() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesStoreArchive-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let fileManager = FileManager.default
        let storeURL = rootURL.appendingPathComponent("BeanNotes.store")
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        for (index, sidecarURL) in BeanNotesModelContainer.persistentStoreSidecarURLs(for: storeURL).enumerated() {
            try Data("sidecar-\(index)".utf8).write(to: sidecarURL)
        }

        let firstArchiveURL = try #require(
            BeanNotesModelContainer.archivePersistentStore(at: storeURL, fileManager: fileManager)
        )

        for (index, sidecarURL) in BeanNotesModelContainer.persistentStoreSidecarURLs(for: storeURL).enumerated() {
            #expect(!fileManager.fileExists(atPath: sidecarURL.path))
            let archivedURL = firstArchiveURL.appendingPathComponent(sidecarURL.lastPathComponent)
            #expect(try Data(contentsOf: archivedURL) == Data("sidecar-\(index)".utf8))
        }

        try Data("retry".utf8).write(to: storeURL)
        let secondArchiveURL = try #require(
            BeanNotesModelContainer.archivePersistentStore(at: storeURL, fileManager: fileManager)
        )

        #expect(firstArchiveURL != secondArchiveURL)
        #expect(fileManager.fileExists(atPath: secondArchiveURL.appendingPathComponent(storeURL.lastPathComponent).path))
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
        let archivedAt = createdAt.addingTimeInterval(600)
        let documentVersionID = UUID(uuidString: "00000000-0000-0000-0000-000000000310")!
        let folder = NotebookFolder(
            name: "CMPT 310",
            colorHex: "#4F7CFF",
            createdAt: createdAt,
            updatedAt: createdAt,
            archivedAt: archivedAt
        )
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
            documentVersionID: documentVersionID,
            documentVersionName: "Instructor Revision",
            documentVersionCreatedAt: createdAt,
            documentVersionIsCurrent: true,
            documentVersionIsLatest: true,
            createdAt: createdAt,
            updatedAt: createdAt
        )

        folder.notes.append(note)
        note.pages.append(page)
        page.attachments.append(attachment)
        context.insert(folder)
        try context.save()

        let manifest = LibraryBackupManifest(folders: [folder], createdAt: createdAt)

        #expect(manifest.formatVersion == 3)
        #expect(manifest.folderCount == 1)
        #expect(manifest.noteCount == 1)
        #expect(manifest.pageCount == 1)
        #expect(manifest.attachmentCount == 1)
        #expect(manifest.folders.first?.name == "CMPT 310")
        #expect(manifest.folders.first?.archivedAt == archivedAt)
        #expect(manifest.folders.first?.notes.first?.title == "Weekly Activity")
        #expect(manifest.folders.first?.notes.first?.pages.first?.drawingFileName == "page-1.drawing")
        #expect(manifest.folders.first?.notes.first?.pages.first?.attachments.first?.storedFileName == "Imports/lecture.pdf")
        let attachmentSnapshot = manifest.folders.first?.notes.first?.pages.first?.attachments.first
        #expect(attachmentSnapshot?.documentVersionID == documentVersionID)
        #expect(attachmentSnapshot?.documentVersionName == "Instructor Revision")
        #expect(attachmentSnapshot?.documentVersionCreatedAt == createdAt)
        #expect(attachmentSnapshot?.documentVersionIsCurrent == true)
        #expect(attachmentSnapshot?.documentVersionIsLatest == true)
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

    @Test @MainActor func cancelingLibraryBackupBeforeSavingLeavesNoArchive() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesCanceledLibraryBackup-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let service = LibraryBackupService(storage: storage)
        var backupTask: Task<LibraryBackupResult, Error>?

        backupTask = Task { @MainActor in
            try await service.exportLibraryBackup(folders: []) { fraction, _ in
                if fraction.map({ $0 >= 0.96 }) == true {
                    backupTask?.cancel()
                }
            }
        }

        guard let backupTask else {
            Issue.record("Backup task should be created.")
            return
        }

        do {
            _ = try await backupTask.value
            Issue.record("Canceled backup should not return an archive.")
        } catch is CancellationError {
            // Expected: cancellation is observed before the archive reaches Exports.
        }

        let exportDirectoryURL = try storage.directoryURL(for: .exports)
        let exportURLs = try FileManager.default.contentsOfDirectory(
            at: exportDirectoryURL,
            includingPropertiesForKeys: nil
        )
        #expect(exportURLs.allSatisfy { $0.pathExtension.lowercased() != "beannotes" })
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

    @Test func localStorageValidatesReadURLsInsideRoot() throws {
        let containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesReadPathValidation-\(UUID().uuidString)", isDirectory: true)
        let rootURL = containerURL.appendingPathComponent("Storage", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: containerURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()

        let stored = try storage.saveData(
            Data("preview".utf8),
            preferredName: "Preview.png",
            contentType: .png,
            to: .imports
        )

        #expect(try storage.validatedURL(forRelativePath: stored.relativePath).path.hasPrefix(rootURL.path))

        do {
            _ = try storage.validatedURL(forRelativePath: "../Outside/secret.png")
            Issue.record("Escaped stored read path should not validate.")
        } catch LocalStorageError.invalidRelativePath {
            // Expected: model-backed preview paths cannot escape BeanNotes storage.
        }

        do {
            _ = try storage.validatedURL(forRelativePath: "")
            Issue.record("Empty stored read path should not validate.")
        } catch LocalStorageError.invalidRelativePath {
            // Expected: a read target must name a file under the storage root.
        }
    }

    @Test func drawingStorageCacheSeparatesMatchingFileNamesAcrossRoots() throws {
        let containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesDrawingCache-\(UUID().uuidString)", isDirectory: true)
        let firstRootURL = containerURL.appendingPathComponent("First", isDirectory: true)
        let secondRootURL = containerURL.appendingPathComponent("Second", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: containerURL)
        }

        DrawingStorageService.clearCache()

        let firstStorage = DrawingStorageService(storage: LocalStorageService(rootURL: firstRootURL))
        let secondStorage = DrawingStorageService(storage: LocalStorageService(rootURL: secondRootURL))
        let sharedFileName = "shared-page.drawing"
        let firstPage = NotePage(pageOrder: 0, drawingFileName: sharedFileName)
        let secondPage = NotePage(pageOrder: 0, drawingFileName: sharedFileName)
        let firstDrawing = makeTestDrawing(color: .systemRed, xOffset: 0)
        let secondDrawing = makeTestDrawing(color: .systemBlue, xOffset: 40)

        try firstStorage.save(firstDrawing, for: firstPage)
        try secondStorage.save(secondDrawing, for: secondPage)

        #expect(firstStorage.loadDrawing(for: firstPage).dataRepresentation() == firstDrawing.dataRepresentation())
        #expect(secondStorage.loadDrawing(for: secondPage).dataRepresentation() == secondDrawing.dataRepresentation())
    }

    @Test func drawingStorageCacheClearsOnMemoryWarning() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesDrawingMemoryWarning-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        DrawingStorageService.clearCache()

        let drawingStorage = DrawingStorageService(storage: LocalStorageService(rootURL: rootURL))
        let page = NotePage(pageOrder: 0, drawingFileName: "memory-warning.drawing")
        let cachedDrawing = makeTestDrawing(color: .systemRed, xOffset: 0)
        let diskDrawing = makeTestDrawing(color: .systemBlue, xOffset: 56)

        try drawingStorage.save(cachedDrawing, for: page)
        try diskDrawing.dataRepresentation().write(to: drawingStorage.drawingURL(for: page), options: [.atomic])

        let cachedLoad = drawingStorage.loadDrawing(for: page)
        #expect(abs(cachedLoad.bounds.midX - cachedDrawing.bounds.midX) < 0.5)

        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)

        let warningLoad = drawingStorage.loadDrawing(for: page)
        #expect(abs(warningLoad.bounds.midX - diskDrawing.bounds.midX) < 0.5)
        #expect(abs(warningLoad.bounds.midX - cachedDrawing.bounds.midX) > 20)
    }

    @Test func drawingPrefetchCannotReplaceNewerCachedInk() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesDrawingPrefetchRace-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        DrawingStorageService.clearCache()
        let storage = LocalStorageService(rootURL: rootURL)
        let drawingStorage = DrawingStorageService(storage: storage)
        let page = NotePage(pageOrder: 0, drawingFileName: "prefetch-race.drawing")
        let diskDrawing = makeTestDrawing(color: .systemBlue, xOffset: 0)
        let liveDrawing = makeTestDrawing(color: .systemRed, xOffset: 64)
        try drawingStorage.save(diskDrawing, for: page)
        DrawingStorageService.clearCache()

        DrawingStorageService.prefetchDrawing(fileName: page.drawingFileName, rootURL: rootURL)
        DrawingStorageService.cache(liveDrawing, fileName: page.drawingFileName, rootURL: rootURL)
        try await Task.sleep(nanoseconds: 100_000_000)

        let loadedDrawing = drawingStorage.loadDrawing(for: page)
        #expect(abs(loadedDrawing.bounds.midX - liveDrawing.bounds.midX) < 0.5)
        #expect(abs(loadedDrawing.bounds.midX - diskDrawing.bounds.midX) > 20)
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
        #expect(NoteBackground.colorPresets.contains { $0.name == "Wood Paper" && $0.colorHex == "#FFF9EC" })
        #expect(NoteBackgroundStyle.allCases.contains(.cornell))
        #expect(NoteBackgroundStyle.allCases.contains(.musicStaff))
        #expect(NoteBackgroundStyle.allCases.contains(.planner))
        #expect(NoteBackgroundStyle.allCases.contains(.chalkboard))
    }

    @Test func chalkboardTemplateUsesItsBoardSurfaceAndPreservesPaperColor() {
        let chalkboard = NoteBackground(
            style: .chalkboard,
            colorHex: "#FFF7BF",
            spacing: 42,
            marginWidth: 120
        )
        let restored = NoteBackground.fromDefaults(
            styleRaw: chalkboard.storageStyleRaw,
            colorHex: chalkboard.colorHex
        )

        #expect(chalkboard.storageStyleRaw == "chalkboard")
        #expect(chalkboard.renderedColorHex == NoteBackground.chalkboardColorHex)
        #expect(!NoteBackgroundStyle.chalkboard.supportsCustomColor)
        #expect(restored.style == .chalkboard)
        #expect(restored.colorHex == "#FFF7BF")
        #expect(restored.resolvedSpacing == 0)
        #expect(restored.resolvedMarginWidth == 0)
        #expect(restored.changingStyle(to: .plain).renderedColorHex == "#FFF7BF")

        let configured = NoteBackground(
            style: .chalkboard,
            colorHex: "#FFF7BF",
            chalkboardPattern: .grid,
            chalkColorHex: "#262A2D"
        )
        let restoredConfiguration = NoteBackground.fromDefaults(
            styleRaw: configured.storageStyleRaw,
            colorHex: configured.colorHex
        )

        #expect(configured.storageStyleRaw == "chalkboard;pattern=grid;color=#262A2D")
        #expect(configured.renderedColorHex == "#262A2D")
        #expect(restoredConfiguration.resolvedChalkboardPattern == .grid)
        #expect(restoredConfiguration.resolvedChalkboardColorHex == "#262A2D")
        #expect(restoredConfiguration.colorHex == "#FFF7BF")
        #expect(NoteBackground.chalkboardColorPresets.count == 3)

        let invalidConfiguration = NoteBackground.fromDefaults(
            styleRaw: "chalkboard;pattern=unknown;color=#FFFFFF",
            colorHex: "#FFE1E8"
        )
        #expect(invalidConfiguration.resolvedChalkboardPattern == .plain)
        #expect(invalidConfiguration.resolvedChalkboardColorHex == NoteBackground.chalkboardColorHex)
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

        let clampedGrid = NoteBackground.fromDefaults(styleRaw: "grid;spacing=1;margin=999", colorHex: "#FFFFFF")
        #expect(clampedGrid.resolvedSpacing == NoteBackgroundStyle.grid.spacingRange.lowerBound)
        #expect(clampedGrid.resolvedMarginWidth == NoteBackgroundStyle.grid.marginRange.upperBound)
    }

    @Test func legacyThemePaperDefaultsMigrateToPlainWhiteWithoutOverwritingCustomColors() throws {
        let suiteName = "BeanNotesThemePaperMigration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(NoteBackgroundStyle.plain.rawValue, forKey: NoteBackground.defaultStyleRawKey)
        defaults.set("#FFF9EC", forKey: NoteBackground.defaultColorHexKey)
        NoteBackground.migrateLegacyThemeControlledDefaultsIfNeeded(in: defaults)

        #expect(defaults.string(forKey: NoteBackground.defaultColorHexKey) == NoteBackground.defaultColorHex)
        #expect(defaults.bool(forKey: NoteBackground.legacyThemePaperMigrationKey))

        defaults.removeObject(forKey: NoteBackground.legacyThemePaperMigrationKey)
        defaults.set("#FFE1E8", forKey: NoteBackground.defaultColorHexKey)
        NoteBackground.migrateLegacyThemeControlledDefaultsIfNeeded(in: defaults)

        #expect(defaults.string(forKey: NoteBackground.defaultColorHexKey) == "#FFE1E8")
    }

    @Test func noteBackgroundRejectsNonFiniteSpacingAndMargins() {
        let decodedGrid = NoteBackground.fromDefaults(styleRaw: "grid;spacing=nan;margin=inf", colorHex: "#FFFFFF")

        #expect(decodedGrid.resolvedSpacing == NoteBackgroundStyle.grid.spacingRange.lowerBound)
        #expect(decodedGrid.resolvedMarginWidth == NoteBackgroundStyle.grid.marginRange.upperBound)
        #expect(!decodedGrid.storageStyleRaw.contains("nan"))
        #expect(!decodedGrid.storageStyleRaw.contains("inf"))

        let directGrid = NoteBackground(
            style: .grid,
            colorHex: "#FFFFFF",
            spacing: .nan,
            marginWidth: -.infinity
        )

        #expect(directGrid.resolvedSpacing == NoteBackgroundStyle.grid.spacingRange.lowerBound)
        #expect(directGrid.resolvedMarginWidth == NoteBackgroundStyle.grid.marginRange.lowerBound)
        #expect(!directGrid.storageStyleRaw.contains("nan"))
        #expect(!directGrid.storageStyleRaw.contains("inf"))
    }

    @Test func hexColorsRoundTripWithoutComponentDrift() {
        for colorHex in ["#E81E2D", "#2345EA", "#94F02B", "#0A84FF", "#FFF7BF"] {
            #expect(UIColor(hex: colorHex).hexRGB == colorHex)
            #expect(Color(hex: colorHex).hexRGB == colorHex)
        }
    }

    @Test func paginationSettingsMapToEditorFlowModes() {
        #expect(NoteEditorPageLayoutMode.allCases.map(\.label) == ["One Page", "Scrollable"])
        #expect(NoteEditorPageLayoutMode.singlePage.pageFlowMode == .separated)
        #expect(NoteEditorPageLayoutMode.scroll.pageFlowMode == .seamless)
        #expect(NoteEditorPageFlowMode.singlePage.migratedLayoutMode == .singlePage)
        #expect(NoteEditorPageFlowMode.continuous.migratedLayoutMode == .scroll)
        #expect(NoteEditorPageFlowMode.infinite.migratedLayoutMode == .scroll)
        #expect(NoteEditorPageFlowMode.seamless.pageStatusText(currentPage: 2, totalPages: 4) == "Continuous canvas")
    }

    @Test func drawingRenderQualityExposesSharperZoomBudget() {
        #expect(DrawingRenderQuality.defaultQuality == .ultraFine)
        #expect(DrawingRenderQuality.allCases.map(\.label) == ["Balanced", "High Resolution", "Ultra Fine"])
        #expect(DrawingRenderQuality.highResolution.maximumZoomScale > DrawingRenderQuality.balanced.maximumZoomScale)
        #expect(DrawingRenderQuality.ultraFine.maximumZoomScale > DrawingRenderQuality.highResolution.maximumZoomScale)
        #expect(DrawingRenderQuality.highResolution.maximumZoomFitMultiplier > DrawingRenderQuality.balanced.maximumZoomFitMultiplier)
        #expect(DrawingRenderQuality.ultraFine.maximumZoomFitMultiplier > DrawingRenderQuality.highResolution.maximumZoomFitMultiplier)
        #expect(DrawingRenderQuality.highResolution.drawingScaleMultiplier > DrawingRenderQuality.balanced.drawingScaleMultiplier)
        #expect(DrawingRenderQuality.ultraFine.drawingScaleMultiplier > DrawingRenderQuality.highResolution.drawingScaleMultiplier)
        #expect(DrawingRenderQuality.highResolution.backgroundScaleMultiplier > DrawingRenderQuality.balanced.backgroundScaleMultiplier)
        #expect(DrawingRenderQuality.ultraFine.backgroundScaleMultiplier > DrawingRenderQuality.highResolution.backgroundScaleMultiplier)
        #expect(DrawingRenderQuality.highResolution.imageScaleMultiplier > DrawingRenderQuality.balanced.imageScaleMultiplier)
        #expect(DrawingRenderQuality.ultraFine.imageScaleMultiplier > DrawingRenderQuality.highResolution.imageScaleMultiplier)
    }

    @Test func drawingResolutionStatusReportsCurrentBackingScale() {
        let ultraFineStatus = DrawingRenderResolutionStatus(
            quality: .ultraFine,
            zoomScale: 6,
            screenScale: 2
        )

        #expect(ultraFineStatus.qualityLabel == "Ultra Fine")
        #expect(ultraFineStatus.zoomText == "600%")
        #expect(ultraFineStatus.drawingScaleText == "12x")
        #expect(ultraFineStatus.maximumZoomText == "600%")
        #expect(ultraFineStatus.maximumDrawingScaleText == "12x")
        #expect(ultraFineStatus.menuSummary == "Ultra Fine detail, 12x drawing backing")
        #expect(ultraFineStatus.stripText == "12x backing")
        #expect(ultraFineStatus.settingsSummary.contains("Live and saved strokes stay screen-sharp"))
        #expect(ultraFineStatus.accessibilityLabel == "Ultra Fine detail, 600% zoom, drawing backing 12 times")

        #expect(DrawingRenderResolutionStatus.drawingBackingScale(
            quality: .balanced,
            zoomScale: 10,
            screenScale: 2
        ) == 20)
        #expect(DrawingRenderResolutionStatus.drawingBackingScale(
            quality: .highResolution,
            zoomScale: 0.75,
            screenScale: 2
        ) == 2)
        #expect(DrawingRenderResolutionStatus.drawingBackingScale(
            quality: .highResolution,
            zoomScale: .infinity,
            screenScale: .nan
        ) == 1)
    }

    @Test func drawingInputModeMapsToPencilKitPolicies() {
        #expect(DrawingInputMode.defaultMode == .pencilOnly)
        #expect(DrawingInputMode.allCases.map(\.label) == ["Pencil Only", "Pencil or Finger"])
        #expect(DrawingInputMode.allCases.map(\.systemImage) == ["hand.raised", "scribble"])
        #expect(DrawingInputMode.pencilOnly.drawingPolicy.rawValue == PKCanvasViewDrawingPolicy.pencilOnly.rawValue)
        #expect(DrawingInputMode.anyInput.drawingPolicy.rawValue == PKCanvasViewDrawingPolicy.anyInput.rawValue)
    }

    @Test func nativeDrawingScaleUsesCurrentResolutionWithoutOversizedHeadroom() {
        #expect(DrawingCanvasView.CanvasContainerView.preparedNativeDrawingScale(for: 0.75) == 1)
        #expect(DrawingCanvasView.CanvasContainerView.preparedNativeDrawingScale(for: 1) == 1)
        #expect(DrawingCanvasView.CanvasContainerView.preparedNativeDrawingScale(for: 1.01) == 1.25)
        #expect(DrawingCanvasView.CanvasContainerView.preparedNativeDrawingScale(for: 2.26) == 2.5)
        #expect(DrawingCanvasView.CanvasContainerView.preparedNativeDrawingScale(for: 2) == 2)
        #expect(DrawingCanvasView.CanvasContainerView.preparedNativeDrawingScale(for: 4) == 4)
        #expect(DrawingCanvasView.CanvasContainerView.preparedNativeDrawingScale(for: 6) == 6)
        #expect(DrawingCanvasView.CanvasContainerView.preparedNativeDrawingScale(for: 6.1) == 6.25)
        #expect(DrawingCanvasView.CanvasContainerView.preparedNativeDrawingScale(for: .infinity) == 1)
    }

    @Test func pageCanvasAppliesSelectedDrawingInputMode() {
        let pageView = DrawingCanvasView.PageCanvasView()

        pageView.applyInputMode(.anyInput)
        #expect(pageView.canvasView.drawingPolicy.rawValue == PKCanvasViewDrawingPolicy.anyInput.rawValue)

        pageView.applyInputMode(.pencilOnly)
        #expect(pageView.canvasView.drawingPolicy.rawValue == PKCanvasViewDrawingPolicy.pencilOnly.rawValue)
    }

    @Test func pageCanvasRestoresDrawingInteractionDuringReconfiguration() {
        let pageView = DrawingCanvasView.PageCanvasView()
        pageView.applyInputMode(.anyInput)
        pageView.canvasView.isUserInteractionEnabled = false
        pageView.canvasView.drawingGestureRecognizer.isEnabled = false

        pageView.applyInputMode(.anyInput)

        #expect(pageView.canvasView.isUserInteractionEnabled)
        #expect(pageView.canvasView.drawingGestureRecognizer.isEnabled)
        #expect(pageView.canvasView.drawingPolicy.rawValue == PKCanvasViewDrawingPolicy.anyInput.rawValue)
    }

    @Test func captureModeSuspendsAndRestoresDrawingInteraction() {
        let pageView = DrawingCanvasView.PageCanvasView()
        pageView.applyInputMode(.anyInput)

        pageView.setCaptureInteractionEnabled(true)
        #expect(!pageView.canvasView.drawingGestureRecognizer.isEnabled)
        #expect(!pageView.allowsPageActionLongPress)

        pageView.setCaptureInteractionEnabled(false)
        #expect(pageView.canvasView.drawingGestureRecognizer.isEnabled)
        #expect(pageView.allowsPageActionLongPress)
    }

    @Test func selectingCaptureToolShowsAndRemovesPageSelectionOverlay() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesCaptureOverlay-\(UUID().uuidString)", isDirectory: true)
        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let page = NotePage(pageOrder: 0, drawingFileName: "capture-overlay.drawing", width: 612, height: 792)
        let parent = makeDrawingCanvasView(page: page, drawingStorage: drawingStorage)
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let container = DrawingCanvasView.CanvasContainerView(
            frame: CGRect(x: 0, y: 0, width: 700, height: 900)
        )
        coordinator.containerView = container

        defer {
            container.cancelPendingRenderingWork()
            container.releaseAllMaterializedPages()
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        container.configure(
            pages: [page],
            selectedPageID: page.id,
            pageFlowMode: .continuous,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: coordinator
        )
        container.layoutIfNeeded()

        parent.toolState.select(.capture)
        coordinator.applyCustomToolIfNeeded()
        let overlay = try #require(container.captureSelectionOverlay)
        #expect(overlay.accessibilityIdentifier == "noteCaptureSelection")
        #expect(!container.activeCanvasView!.drawingGestureRecognizer.isEnabled)

        parent.toolState.select(.pen)
        coordinator.applyCustomToolIfNeeded()
        #expect(container.captureSelectionOverlay == nil)
        #expect(container.activeCanvasView!.drawingGestureRecognizer.isEnabled)
    }

    @Test @MainActor func pageCanvasLayoutPreservesStableCanvasOffsetUntilPageSizeChanges() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesPageCanvasLayout-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let page = NotePage(pageOrder: 0, drawingFileName: "stable-layout.drawing", width: 612, height: 792)
        let parent = makeDrawingCanvasView(page: page, drawingStorage: drawingStorage)
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let pageView = DrawingCanvasView.PageCanvasView()

        pageView.configure(
            page: page,
            storage: storage,
            drawingStorage: drawingStorage,
            inputMode: .pencilOnly,
            coordinator: coordinator,
            attachmentChanged: {},
            deleteAttachment: { _ in }
        )

        let retainedOffset = CGPoint(x: 17, y: 23)
        pageView.canvasView.contentOffset = retainedOffset
        pageView.layoutPage()

        #expect(pageView.canvasView.contentOffset == retainedOffset)

        page.width = 640
        pageView.configure(
            page: page,
            storage: storage,
            drawingStorage: drawingStorage,
            inputMode: .pencilOnly,
            coordinator: coordinator,
            attachmentChanged: {},
            deleteAttachment: { _ in }
        )

        #expect(pageView.canvasView.contentSize == page.pageSize)
        #expect(pageView.canvasView.contentOffset == .zero)
    }

    @Test @MainActor func pageCanvasImageLayersSurroundDrawingAndSelectionClearsForLiveInk() throws {
        let modelContext = try makeInMemoryModelContext()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesImageLayerOrder-\(UUID().uuidString)", isDirectory: true)
        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let page = NotePage(
            pageOrder: 0,
            drawingFileName: "ImageLayerOrder.drawing",
            width: 612,
            height: 792
        )
        let behindImage = Attachment(
            kind: .image,
            displayName: "Behind",
            originalFileName: "behind.png",
            storedFileName: "Imports/behind.png",
            contentTypeIdentifier: UTType.png.identifier,
            fileExtension: "png",
            x: 80,
            y: 100,
            width: 240,
            height: 120,
            rendersBehindDrawing: true,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let foregroundImage = Attachment(
            kind: .image,
            displayName: "Foreground",
            originalFileName: "foreground.png",
            storedFileName: "Imports/foreground.png",
            contentTypeIdentifier: UTType.png.identifier,
            fileExtension: "png",
            x: 120,
            y: 160,
            width: 180,
            height: 180,
            rendersBehindDrawing: false,
            createdAt: Date(timeIntervalSince1970: 1_800_000_001)
        )
        modelContext.insert(page)
        page.attachments.append(contentsOf: [behindImage, foregroundImage])
        try modelContext.save()
        let parent = makeDrawingCanvasView(page: page, drawingStorage: drawingStorage)
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let pageView = DrawingCanvasView.PageCanvasView()
        let documentScrollView = UIScrollView()
        documentScrollView.addSubview(pageView)
        var deletedAttachmentID: UUID?
        defer {
            pageView.releaseHeavyResources()
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        pageView.configure(
            page: page,
            storage: storage,
            drawingStorage: drawingStorage,
            inputMode: .pencilOnly,
            coordinator: coordinator,
            attachmentChanged: {},
            deleteAttachment: { deletedAttachmentID = $0.id }
        )

        let behindIndex = try #require(pageView.subviews.firstIndex {
            $0 === pageView.behindImageContainerView
        })
        let drawingIndex = try #require(pageView.subviews.firstIndex {
            $0 === pageView.drawingViewportView
        })
        let foregroundIndex = try #require(pageView.subviews.firstIndex {
            $0 === pageView.foregroundImageContainerView
        })

        #expect(behindIndex < drawingIndex)
        #expect(drawingIndex < foregroundIndex)
        #expect(pageView.behindImageContainerView.subviews.count == 1)
        #expect(pageView.foregroundImageContainerView.subviews.count == 1)
        #expect(pageView.behindImageContainerView.subviews.allSatisfy { !$0.isUserInteractionEnabled })
        #expect(pageView.foregroundImageContainerView.subviews.allSatisfy { !$0.isUserInteractionEnabled })

        pageView.beginEditingAttachment(id: behindImage.id)

        #expect(pageView.selectedAttachmentID == behindImage.id)
        let overlay = try #require(pageView.subviews
            .compactMap { $0 as? DrawingCanvasView.AttachmentEditingOverlayView }
            .first)
        let overlayIndex = try #require(pageView.subviews.firstIndex { $0 === overlay })
        #expect(overlayIndex > foregroundIndex)
        overlay.layoutIfNeeded()
        #expect(overlay.hitTest(
            CGPoint(x: overlay.bounds.midX, y: overlay.bounds.midY),
            with: nil
        ) === overlay)
        #expect(overlay.hitTest(
            CGPoint(x: -10, y: overlay.bounds.midY),
            with: nil
        ) === overlay)
        #expect(overlay.resizeHandle(at: CGPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)) == nil)
        #expect(overlay.resizeHandle(at: CGPoint(x: 0, y: 0)) == .topLeft)
        #expect(overlay.resizeHandle(at: CGPoint(x: overlay.bounds.midX, y: 0)) == .top)
        #expect(overlay.resizeHandle(at: CGPoint(x: overlay.bounds.maxX, y: 0)) == .topRight)
        #expect(overlay.resizeHandle(at: CGPoint(x: overlay.bounds.maxX, y: overlay.bounds.midY)) == .right)
        #expect(overlay.resizeHandle(at: CGPoint(x: overlay.bounds.maxX, y: overlay.bounds.maxY)) == .bottomRight)
        #expect(overlay.resizeHandle(at: CGPoint(x: overlay.bounds.midX, y: overlay.bounds.maxY)) == .bottom)
        #expect(overlay.resizeHandle(at: CGPoint(x: 0, y: overlay.bounds.maxY)) == .bottomLeft)
        #expect(overlay.resizeHandle(at: CGPoint(x: 0, y: overlay.bounds.midY)) == .left)
        #expect(overlay.editingPanGestureRecognizers.count == 1)
        #expect(overlay.editingPanGestureRecognizers.allSatisfy { $0.maximumNumberOfTouches == 1 })
        #expect(overlay.editingPanGestureRecognizers.allSatisfy {
            overlay.gestureRecognizer(
                $0,
                shouldBeRequiredToFailBy: documentScrollView.panGestureRecognizer
            )
        })
        #expect(documentScrollView.panGestureRecognizer.isEnabled)

        let deleteButton = try #require(overlay.subviews
            .compactMap { $0 as? UIButton }
            .first { $0.accessibilityLabel == "Delete Behind" })
        #expect(overlay.subviews.compactMap { $0 as? UIButton }.count == 1)
        #expect(!overlay.bounds.intersects(deleteButton.frame))
        #expect(overlay.hitTest(deleteButton.center, with: nil) === deleteButton)
        #expect(deleteButton.accessibilityHint == "Removes the image after confirmation")
        deleteButton.sendActions(for: .touchUpInside)

        #expect(deletedAttachmentID == behindImage.id)
        #expect(pageView.selectedAttachmentID == nil)
        #expect(!pageView.subviews.contains {
            $0 is DrawingCanvasView.AttachmentEditingOverlayView
        })
        #expect(documentScrollView.panGestureRecognizer.isEnabled)

        pageView.beginEditingAttachment(id: behindImage.id)

        pageView.setLiveDrawingActive(true)

        #expect(pageView.selectedAttachmentID == nil)
        #expect(!pageView.subviews.contains {
            $0 is DrawingCanvasView.AttachmentEditingOverlayView
        })
        pageView.setLiveDrawingActive(false)
    }

    @Test @MainActor func nativeDrawingViewportUsesPencilKitZoomAndPreservesPageCoordinates() throws {
        let fixture = try makePageCanvasFixture(name: "NativeViewport")
        defer { fixture.cleanup() }

        let visibleRect = CGRect(x: 100, y: 180, width: 140, height: 160)
        fixture.pageView.updateNativeDrawingViewport(
            visiblePageRect: visibleRect,
            overscan: 0,
            nativeZoomScale: 4,
            force: true
        )

        #expect(abs(fixture.pageView.canvasView.zoomScale - 4) < 0.01)
        #expect(fixture.pageView.drawingViewportView.frame == visibleRect)
        #expect(fixture.pageView.canvasView.bounds.size == CGSize(width: 560, height: 640))
        #expect(fixture.pageView.canvasView.contentOffset == CGPoint(x: 400, y: 720))
        #expect(abs(fixture.pageView.canvasView.frame.width - visibleRect.width) < 0.01)
        #expect(abs(fixture.pageView.canvasView.frame.height - visibleRect.height) < 0.01)

        let viewportPoint = CGPoint(x: 25, y: 40)
        let pagePoint = CGPoint(
            x: (fixture.pageView.canvasView.contentOffset.x + viewportPoint.x * 4) / 4,
            y: (fixture.pageView.canvasView.contentOffset.y + viewportPoint.y * 4) / 4
        )
        #expect(pagePoint == CGPoint(x: 125, y: 220))
    }

    @Test @MainActor func nativeDrawingViewportStaysStableDuringLiveInk() throws {
        let fixture = try makePageCanvasFixture(name: "StableLiveInk")
        defer { fixture.cleanup() }

        fixture.pageView.updateNativeDrawingViewport(
            visiblePageRect: CGRect(x: 0, y: 0, width: 180, height: 220),
            overscan: 0,
            nativeZoomScale: 2,
            force: true
        )
        fixture.pageView.setLiveDrawingActive(true)
        fixture.pageView.updateNativeDrawingViewport(
            visiblePageRect: CGRect(x: 200, y: 260, width: 120, height: 150),
            overscan: 0,
            nativeZoomScale: 5,
            force: true
        )

        #expect(abs(fixture.pageView.canvasView.zoomScale - 2) < 0.01)
        #expect(fixture.pageView.drawingViewportView.frame == CGRect(x: 0, y: 0, width: 180, height: 220))

        fixture.pageView.setLiveDrawingActive(false)
        #expect(abs(fixture.pageView.canvasView.zoomScale - 5) < 0.01)
        #expect(fixture.pageView.drawingViewportView.frame == CGRect(x: 200, y: 260, width: 120, height: 150))
    }

    @Test @MainActor func nativeDrawingViewportCoversTheTrailingVisiblePageEdge() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesTrailingViewport-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let page = NotePage(pageOrder: 0, drawingFileName: "trailing-viewport.drawing", width: 1_200, height: 900)
        let parent = makeDrawingCanvasView(page: page, drawingStorage: drawingStorage)
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let container = DrawingCanvasView.CanvasContainerView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 700)
        )
        coordinator.containerView = container
        defer {
            DrawingCanvasView.dismantleUIView(container, coordinator: coordinator)
        }

        container.configure(
            pages: [page],
            selectedPageID: page.id,
            pageFlowMode: .continuous,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: coordinator
        )
        container.setNeedsLayout()
        container.layoutIfNeeded()
        container.scrollView.setZoomScale(1.5, animated: false)
        container.scrollView.setContentOffset(
            CGPoint(
                x: container.scrollView.contentSize.width
                    - container.scrollView.bounds.width
                    + container.scrollView.adjustedContentInset.right,
                y: container.scrollView.contentOffset.y
            ),
            animated: false
        )
        container.scrollViewDidScroll(container.scrollView)
        container.layoutIfNeeded()

        let pageView = try #require(container.contentView.subviews
            .compactMap { $0 as? DrawingCanvasView.PageCanvasView }
            .first)
        let visiblePageRect = pageView.convert(container.scrollView.bounds, from: container.scrollView)
            .intersection(pageView.bounds)

        #expect(!visiblePageRect.isEmpty)
        #expect(pageView.drawingViewportView.frame.maxX >= visiblePageRect.maxX - 1)

        let trailingPoint = CGPoint(
            x: visiblePageRect.maxX - 4,
            y: visiblePageRect.midY
        )
        let hitView = pageView.hitTest(trailingPoint, with: nil)
        #expect(
            hitView === pageView.canvasView
                || hitView?.isDescendant(of: pageView.canvasView) == true
        )
    }

    @Test @MainActor func documentBackgroundDoesNotBlockDrawingInput() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesPDFDrawing-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let attachment = Attachment(
            kind: .image,
            displayName: "PDF Page 1",
            originalFileName: "PDF-page-1.jpg",
            storedFileName: "Imports/PDF-page-1.jpg",
            contentTypeIdentifier: "public.jpeg",
            fileExtension: "jpg",
            x: 0,
            y: 0,
            width: 612,
            height: 792,
            isLocked: true,
            rendersBehindDrawing: true
        )
        let imageView = DrawingCanvasView.AttachmentImageContainerView(frame: .zero)
        imageView.configure(
            attachment: attachment,
            storage: storage,
            pageSize: CGSize(width: 612, height: 792),
            changed: {}
        )

        #expect(!imageView.isUserInteractionEnabled)
    }

    @Test func fingerDrawingRequiresTwoFingerDocumentNavigation() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesFingerNavigation-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let page = NotePage(pageOrder: 0, drawingFileName: "finger-navigation.drawing")
        let parent = makeDrawingCanvasView(page: page, drawingStorage: drawingStorage)
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let container = DrawingCanvasView.CanvasContainerView(
            frame: CGRect(x: 0, y: 0, width: 700, height: 900)
        )
        coordinator.containerView = container

        container.configure(
            pages: [page],
            selectedPageID: page.id,
            pageFlowMode: .continuous,
            inputMode: .anyInput,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: coordinator
        )
        #expect(container.scrollView.panGestureRecognizer.minimumNumberOfTouches == 2)
        #expect(container.activeCanvasView?.drawingPolicy.rawValue == PKCanvasViewDrawingPolicy.anyInput.rawValue)
        #expect(container.activeCanvasView?.panGestureRecognizer.isEnabled == false)

        container.configure(
            pages: [page],
            selectedPageID: page.id,
            pageFlowMode: .continuous,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: coordinator
        )
        #expect(container.scrollView.panGestureRecognizer.minimumNumberOfTouches == 1)
        #expect(container.activeCanvasView?.drawingPolicy.rawValue == PKCanvasViewDrawingPolicy.pencilOnly.rawValue)
    }

    @Test @MainActor func documentTopScrollRequiresDoubleTap() {
        let container = DrawingCanvasView.CanvasContainerView()

        #expect(container.scrollView.scrollsToTop)
        #expect(!DrawingCanvasView.PageCanvasView().canvasView.scrollsToTop)
        #expect(!container.scrollViewShouldScrollToTop(container.scrollView))
        #expect(container.scrollViewShouldScrollToTop(container.scrollView))
        #expect(container.isDocumentTraversalActive)
        container.scrollViewDidScrollToTop(container.scrollView)
        #expect(!container.isDocumentTraversalActive)

        #expect(!container.shouldAllowScrollToTop(at: 10))
        #expect(container.shouldAllowScrollToTop(at: 10.4))

        // A completed double tap resets the sequence, and a delayed second tap must
        // start a new sequence rather than moving the reader unexpectedly.
        #expect(!container.shouldAllowScrollToTop(at: 10.5))
        #expect(!container.shouldAllowScrollToTop(at: 11.1))
        #expect(container.shouldAllowScrollToTop(at: 11.5))
    }

    @Test func attachmentSelectionWaitsForFingerDoubleTapZoom() throws {
        let pageView = DrawingCanvasView.PageCanvasView()
        let attachmentSelection = try #require(pageView.attachmentSelectionGesture)

        let fingerDoubleTap = UITapGestureRecognizer()
        fingerDoubleTap.numberOfTouchesRequired = 1
        fingerDoubleTap.numberOfTapsRequired = 2

        let fingerSingleTap = UITapGestureRecognizer()
        fingerSingleTap.numberOfTouchesRequired = 1
        fingerSingleTap.numberOfTapsRequired = 1

        let twoFingerDoubleTap = UITapGestureRecognizer()
        twoFingerDoubleTap.numberOfTouchesRequired = 2
        twoFingerDoubleTap.numberOfTapsRequired = 2

        #expect(pageView.gestureRecognizer(
            attachmentSelection,
            shouldRequireFailureOf: fingerDoubleTap
        ))
        #expect(!pageView.gestureRecognizer(
            attachmentSelection,
            shouldRequireFailureOf: fingerSingleTap
        ))
        #expect(!pageView.gestureRecognizer(
            attachmentSelection,
            shouldRequireFailureOf: twoFingerDoubleTap
        ))
    }

    @Test @MainActor func pageCanvasUsesDirectLongPressForPageActions() throws {
        let fixture = try makePageCanvasFixture(name: "PageActionMenu")
        defer { fixture.cleanup() }

        let pageView = fixture.pageView
        let longPress = try #require(pageView.pageActionLongPressGesture)
        let directTouch = NSNumber(value: UITouch.TouchType.direct.rawValue)

        #expect(longPress.minimumPressDuration == 0.5)
        #expect(longPress.allowedTouchTypes == [directTouch])
        #expect(pageView.interactions.contains { $0 === pageView.pageActionMenuInteraction })
        #expect(pageView.consumesBlankCanvasTaps)
        #expect(pageView.allowsPageActionLongPress)
        #expect(pageView.canvasView.drawingGestureRecognizer.isEnabled)
        #expect(!pageView.gestureRecognizer(
            longPress,
            shouldRecognizeSimultaneouslyWith: UIPanGestureRecognizer()
        ))

        let enabledMenu = pageView.makePageContextMenu(
            for: UUID(),
            canRemovePage: true,
            canPasteImage: true
        )
        let enabledActions = enabledMenu.children.compactMap { $0 as? UIAction }
        try #require(enabledActions.count == 4)
        #expect(enabledActions.map(\.title) == [
            "Add Page Below",
            "Add Page Above",
            "Paste Image",
            "Remove Page"
        ])
        #expect(enabledActions[3].attributes.contains(.destructive))
        #expect(!enabledActions[3].attributes.contains(.disabled))

        let menuWithoutPasteImage = pageView.makePageContextMenu(
            for: UUID(),
            canRemovePage: true,
            canPasteImage: false
        )
        let actionsWithoutPasteImage = menuWithoutPasteImage.children.compactMap { $0 as? UIAction }
        #expect(actionsWithoutPasteImage.map(\.title) == [
            "Add Page Below",
            "Add Page Above",
            "Remove Page"
        ])

        let solePageMenu = pageView.makePageContextMenu(
            for: UUID(),
            canRemovePage: false,
            canPasteImage: false
        )
        let solePageActions = solePageMenu.children.compactMap { $0 as? UIAction }
        try #require(solePageActions.count == 3)
        #expect(solePageActions[2].attributes.contains(.destructive))
        #expect(solePageActions[2].attributes.contains(.disabled))

        #expect(!pageView.canPerformAction(#selector(UIResponder.selectAll(_:)), withSender: nil))
        #expect(!pageView.canPerformAction(Selector(("insertSpace:")), withSender: nil))
        #expect(!pageView.canvasView.canPerformAction(#selector(UIResponder.selectAll(_:)), withSender: nil))
        #expect(!pageView.canvasView.canPerformAction(Selector(("insertSpace:")), withSender: nil))

        pageView.applyInputMode(.anyInput)
        #expect(!pageView.consumesBlankCanvasTaps)
        #expect(pageView.allowsPageActionLongPress)
        #expect(pageView.canvasView.drawingGestureRecognizer.isEnabled)

        pageView.canvasView.tool = PKLassoTool()
        #expect(pageView.canvasView.tool is PKLassoTool)
        #expect(!pageView.consumesBlankCanvasTaps)
        #expect(!pageView.allowsPageActionLongPress)
    }

    @Test func drawingZoomPresetsFormatAndClampDetailTargets() {
        #expect(DrawingZoomPreset.allCases.map(\.label) == ["100%", "200%", "300%", "400%", "600%"])
        #expect(DrawingZoomPreset.quickPresets(for: .balanced).map(\.label) == ["100%", "200%", "300%"])
        #expect(DrawingZoomPreset.quickPresets(for: .highResolution).map(\.label) == ["100%", "200%", "300%", "400%"])
        #expect(DrawingZoomPreset.quickPresets(for: .ultraFine).map(\.label) == ["100%", "200%", "300%", "400%", "600%"])
        #expect(DrawingZoomLevel.percentageText(for: 1.245) == "125%")
        #expect(DrawingZoomLevel.percentageText(for: -1) == "0%")
        #expect(DrawingZoomLevel.clampedScale(0.5, minimum: 0.75, maximum: 3) == 0.75)
        #expect(DrawingZoomLevel.clampedScale(4.5, minimum: 0.75, maximum: 3) == 3)
        #expect(DrawingZoomLevel.clampedScale(2, minimum: 0.75, maximum: 3) == 2)
        #expect(DrawingZoomLevel.isScale(2.02, closeTo: 2))
        #expect(!DrawingZoomLevel.isScale(2.08, closeTo: 2))
        #expect(DrawingZoomLevel.doubleTapTargetScale(
            current: 0.75,
            fitScale: 0.7,
            minimum: 0.3,
            maximum: 4
        ) == 2)
        #expect(DrawingZoomLevel.doubleTapTargetScale(
            current: 1.7,
            fitScale: 0.7,
            minimum: 0.3,
            maximum: 4
        ) == 0.7)
        #expect(DrawingZoomLevel.doubleTapTargetScale(
            current: 1,
            fitScale: 1.2,
            minimum: 0.5,
            maximum: 1.5
        ) == 1.5)
        #expect(DrawingZoomLevel.doubleTapTargetScale(
            current: 1.45,
            fitScale: 1.2,
            minimum: 0.5,
            maximum: 1.5
        ) == 1.2)
    }

    @Test func detailWritingModeBundlesUltraFineZoomAndLightTouchInk() {
        #expect(DrawingDetailWritingMode.label == "Detail Writing Mode")
        #expect(DrawingDetailWritingMode.renderQuality == .ultraFine)
        #expect(DrawingDetailWritingMode.strokeZoomBehavior == .zoomCalibrated)
        #expect(DrawingDetailWritingMode.widthMode == .lightTouch)
        #expect(DrawingDetailWritingMode.zoomScale == DrawingZoomPreset.ultraFineDetail.scale)
        #expect(DrawingDetailWritingMode.description.contains("600 percent zoom"))
    }

    @Test func lightTouchFocusModeBundlesQuietIPadWritingSettings() {
        #expect(DrawingLightTouchFocusMode.label == "Light Touch Focus")
        #expect(DrawingLightTouchFocusMode.renderQuality == .ultraFine)
        #expect(DrawingLightTouchFocusMode.inputMode == .pencilOnly)
        #expect(DrawingLightTouchFocusMode.strokeZoomBehavior == .zoomCalibrated)
        #expect(DrawingLightTouchFocusMode.widthMode == .lightTouch)
        #expect(DrawingLightTouchFocusMode.zoomScale == DrawingZoomPreset.fineDetail.scale)
        #expect(DrawingLightTouchFocusMode.description.contains("400 percent zoom"))
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

    @Test func beanThemeIsTheFreshInstallFallback() throws {
        let suiteName = "BeanNotesThemeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(BeanNotesTheme.currentFromDefaults(defaults) == .bean)

        defaults.set(BeanNotesTheme.blueberry.rawValue, forKey: BeanNotesTheme.storageKey)
        #expect(BeanNotesTheme.currentFromDefaults(defaults) == .blueberry)

        defaults.set("unknown-theme", forKey: BeanNotesTheme.storageKey)
        #expect(BeanNotesTheme.currentFromDefaults(defaults) == .bean)
    }

    @Test func beanThemeMapsToMascotPaperAndNotificationAssets() {
        #expect(BeanNotesTheme.bean.brandImageName == "BeanBadge")
        #expect(BeanNotesTheme.bean.paperTextureImageName == "BeanPaperTexture")
        #expect(BeanNotesTheme.bean.notificationAttachmentName == "BeanNotesNotificationIcon")
        #expect(BeanNotesTheme.bean.notePaperPreviewHex == "#FFF9EC")
        #expect(BeanNotesTheme.bean.folderCreatedBody(folderName: "Projects").contains("Bean"))

        #expect(BeanNotesTheme.standard.brandImageName == nil)
        #expect(BeanNotesTheme.standard.paperTextureImageName == nil)
        #expect(BeanNotesTheme.standard.notePaperPreviewHex == "#FFFFFF")
        #expect(!BeanNotesTheme.standard.supportsFriendlyVisits)
        #expect(BeanNotesTheme.blueberry.brandImageName == "BlueberryBadge")
        #expect(BeanNotesTheme.blueberry.mascotAvatarImageName == "BlueberryBadge")
        #expect(BeanNotesTheme.blueberry.mascotWelcomeImageName == "BlueberryVisitImage")
        #expect(BeanNotesTheme.blueberry.paperTextureImageName == "BlueberryPaperTexture")
        #expect(BeanNotesTheme.blueberry.notificationAttachmentName == "BlueberryNotificationIcon")
        #expect(BeanNotesTheme.blueberry.notePaperPreviewHex == "#EAF3FF")
        #expect(BeanNotesTheme.bean.alternateAppIconName == nil)
        #expect(BeanNotesTheme.blueberry.alternateAppIconName == "BlueberryAppIcon")
        #expect(BeanNotesTheme.bean.supportsFriendlyVisits)
        #expect(BeanNotesTheme.blueberry.supportsFriendlyVisits)
    }

    @Test func beanThemeCyclesCornerStatusMessages() {
        #expect(BeanNotesTheme.bean.cornerStatusMessages == [
            "Bean's fav place (She is sleeping)",
            "Bean is drinking water",
            "Bean's want ~"
        ])
        #expect(BeanNotesTheme.blueberry.cornerStatusMessages == [BeanNotesTheme.blueberry.cornerSubtitle])
    }

    @Test func beanAndBlueberryPaperArtworkPreferencesStayIndependent() throws {
        let suiteName = "BeanNotesPaperArtworkIsolation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!NoteBackground.showsArtwork(for: .standard, in: defaults))
        #expect(!NoteBackground.showsArtwork(for: .bean, in: defaults))
        #expect(NoteBackground.showsArtwork(for: .blueberry, in: defaults))

        defaults.set(true, forKey: NoteBackground.showsBeanArtworkKey)
        defaults.set(false, forKey: NoteBackground.showsBlueberryArtworkKey)

        #expect(NoteBackground.showsArtwork(for: .bean, in: defaults))
        #expect(!NoteBackground.showsArtwork(for: .blueberry, in: defaults))
    }

    @Test func noteTemplateRenderingStaysLightInDarkMode() throws {
        let background = NoteBackground(style: .planner, colorHex: "#FFFFFF")
        let size = CGSize(width: 320, height: 420)

        func renderedData(for interfaceStyle: UIUserInterfaceStyle) -> Data? {
            var data: Data?
            UITraitCollection(userInterfaceStyle: interfaceStyle).performAsCurrent {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = true
                let renderer = UIGraphicsImageRenderer(size: size, format: format)
                data = renderer.image { context in
                    NoteBackgroundRenderer.draw(
                        background: background,
                        in: CGRect(origin: .zero, size: size),
                        context: context.cgContext
                    )
                }.pngData()
            }
            return data
        }

        let lightRendering = try #require(renderedData(for: .light))
        let darkRendering = try #require(renderedData(for: .dark))

        #expect(lightRendering == darkRendering)
    }

    @Test func drawingPagesKeepLightAppearanceInDarkMode() {
        let pageView = DrawingCanvasView.PageCanvasView()

        #expect(pageView.overrideUserInterfaceStyle == .light)
    }

    @Test func beanVisitPolicyRequiresAnIdleHealthyBeanLibrary() {
        let eligible = BeanVisitPolicy.canSchedule(
            theme: .bean,
            isEnabled: true,
            sceneIsActive: true,
            isSafeSurface: true,
            isLowPowerModeEnabled: false,
            thermalState: .nominal,
            launchArguments: []
        )
        #expect(eligible)

        #expect(BeanVisitPolicy.canSchedule(
            theme: .blueberry,
            isEnabled: true,
            sceneIsActive: true,
            isSafeSurface: true,
            isLowPowerModeEnabled: false,
            thermalState: .nominal,
            launchArguments: []
        ))

        #expect(!BeanVisitPolicy.canSchedule(
            theme: .standard,
            isEnabled: true,
            sceneIsActive: true,
            isSafeSurface: true,
            isLowPowerModeEnabled: false,
            thermalState: .nominal,
            launchArguments: []
        ))
        #expect(!BeanVisitPolicy.canSchedule(
            theme: .bean,
            isEnabled: false,
            sceneIsActive: true,
            isSafeSurface: true,
            isLowPowerModeEnabled: false,
            thermalState: .nominal,
            launchArguments: []
        ))
        #expect(!BeanVisitPolicy.canSchedule(
            theme: .bean,
            isEnabled: true,
            sceneIsActive: true,
            isSafeSurface: false,
            isLowPowerModeEnabled: false,
            thermalState: .nominal,
            launchArguments: []
        ))
        #expect(!BeanVisitPolicy.canSchedule(
            theme: .bean,
            isEnabled: true,
            sceneIsActive: true,
            isSafeSurface: true,
            isLowPowerModeEnabled: true,
            thermalState: .nominal,
            launchArguments: []
        ))
        #expect(!BeanVisitPolicy.canSchedule(
            theme: .bean,
            isEnabled: true,
            sceneIsActive: true,
            isSafeSurface: true,
            isLowPowerModeEnabled: false,
            thermalState: .serious,
            launchArguments: []
        ))
        #expect(!BeanVisitPolicy.canSchedule(
            theme: .bean,
            isEnabled: true,
            sceneIsActive: true,
            isSafeSurface: true,
            isLowPowerModeEnabled: false,
            thermalState: .nominal,
            launchArguments: [BeanNotesLaunchConfiguration.uiTestingArgument]
        ))
    }

    @Test func beanVisitPolicyPersistsAndEnforcesItsCooldown() throws {
        let suiteName = "BeanVisitPolicyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(BeanVisitPolicy.cooldownHasElapsed(now: now, lastShownDate: nil))

        BeanVisitPolicy.recordVisit(at: now, in: defaults)
        #expect(BeanVisitPolicy.lastShownDate(in: defaults) == now)
        #expect(!BeanVisitPolicy.cooldownHasElapsed(now: now.addingTimeInterval(60), lastShownDate: now))
        #expect(BeanVisitPolicy.cooldownHasElapsed(
            now: now.addingTimeInterval(BeanVisitPolicy.minimumCooldown),
            lastShownDate: now
        ))
        #expect(BeanVisitPolicy.cooldownRemaining(now: now, lastShownDate: now) == BeanVisitPolicy.minimumCooldown)
        #expect(BeanVisitPolicy.cooldownRemaining(
            now: now.addingTimeInterval(BeanVisitPolicy.minimumCooldown),
            lastShownDate: now
        ) == 0)
    }

    @Test func beanAndBlueberryVisitsKeepIndependentPreferencesAndCooldowns() throws {
        let suiteName = "BeanNotesThemeVisitIsolation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let blueberryDate = now.addingTimeInterval(120)

        #expect(BeanVisitPolicy.storageKeys(for: .standard) == nil)
        #expect(BeanVisitPolicy.storageKeys(for: .bean) != BeanVisitPolicy.storageKeys(for: .blueberry))

        BeanVisitPolicy.recordVisit(for: .bean, at: now, in: defaults)
        #expect(BeanVisitPolicy.lastShownDate(for: .bean, in: defaults) == now)
        #expect(BeanVisitPolicy.lastShownDate(for: .blueberry, in: defaults) == nil)

        BeanVisitPolicy.recordVisit(for: .blueberry, at: blueberryDate, in: defaults)
        #expect(BeanVisitPolicy.lastShownDate(for: .bean, in: defaults) == now)
        #expect(BeanVisitPolicy.lastShownDate(for: .blueberry, in: defaults) == blueberryDate)

        #expect(!BeanVisitPolicy.cooldownHasElapsed(for: .bean, now: now, in: defaults))
        #expect(!BeanVisitPolicy.cooldownHasElapsed(for: .blueberry, now: blueberryDate, in: defaults))
    }

    @Test func beanVisitPolicyRespectsBreakAndFocusInterruptionPreferences() {
        #expect(!BeanVisitPolicy.shouldVisitAfterReturning(
            awayDuration: BeanVisitPolicy.awayThreshold - 1,
            allowsInterruptions: false
        ))
        #expect(BeanVisitPolicy.shouldVisitAfterReturning(
            awayDuration: BeanVisitPolicy.awayThreshold,
            allowsInterruptions: false
        ))
        #expect(!BeanVisitPolicy.shouldVisitAfterReturning(
            awayDuration: BeanVisitPolicy.awayThreshold * 2,
            allowsInterruptions: true
        ))

        #expect(!BeanVisitPolicy.shouldVisitAfterFocusing(
            focusDuration: BeanVisitPolicy.defaultFocusReminderInterval - 1,
            reminderInterval: BeanVisitPolicy.defaultFocusReminderInterval,
            allowsInterruptions: false
        ))
        #expect(BeanVisitPolicy.shouldVisitAfterFocusing(
            focusDuration: BeanVisitPolicy.defaultFocusReminderInterval,
            reminderInterval: BeanVisitPolicy.defaultFocusReminderInterval,
            allowsInterruptions: false
        ))
        #expect(!BeanVisitPolicy.shouldVisitAfterFocusing(
            focusDuration: BeanVisitPolicy.defaultFocusReminderInterval * 2,
            reminderInterval: BeanVisitPolicy.defaultFocusReminderInterval,
            allowsInterruptions: true
        ))
        #expect(BeanVisitPolicy.normalizedFocusReminderInterval(42) == BeanVisitPolicy.defaultFocusReminderInterval)
        #expect(BeanVisitPolicy.normalizedFocusReminderInterval(30 * 60) == 30 * 60)
    }

    @Test func beanVisitsOfferVariedDogSayingsAndScreenPlacements() {
        #expect(BeanVisit.Placement.allCases.count == 8)

        for reason in [
            BeanVisitPolicy.VisitReason.friendly,
            .returnFromBreak,
            .focusBreak
        ] {
            #expect(reason.sayings.count >= 4)
            #expect(Set(reason.sayings.map(\.title)).count == reason.sayings.count)
            #expect(reason.sayings.allSatisfy { !$0.message.isEmpty })
        }

        let dogLanguage = ["Bean", "tail", "dog", "paws", "walk", "sniff", "ears", "scratch"]
        let allMessages = [
            BeanVisitPolicy.VisitReason.friendly,
            .returnFromBreak,
            .focusBreak
        ].flatMap(\.sayings).map { "\($0.title) \($0.message)" }

        #expect(allMessages.allSatisfy { saying in
            dogLanguage.contains { saying.localizedCaseInsensitiveContains($0) }
        })
    }

    @Test func blueberryVisitsUseBerrySpecificArtworkAndHelpfulSnackCopy() {
        let reasons: [BeanVisitPolicy.VisitReason] = [.friendly, .returnFromBreak, .focusBreak]
        let dogLanguage = ["Bean", "tail", "dog", "paws", "walkies", "sniff", "ears", "scratch"]
        let blueberryLanguage = ["blueberr", "fiber", "vitamin C", "anthocyanin"]

        for reason in reasons {
            let sayings = reason.sayings(for: .blueberry)
            #expect(sayings.count >= 4)
            #expect(Set(sayings.map(\.title)).count == sayings.count)
            #expect(sayings.allSatisfy { !$0.message.isEmpty })
            #expect(sayings.allSatisfy { saying in
                let fullText = "\(saying.title) \(saying.message)"
                return blueberryLanguage.contains { fullText.localizedCaseInsensitiveContains($0) }
            })
            #expect(sayings.allSatisfy { saying in
                let fullText = "\(saying.title) \(saying.message)"
                let words = Set(
                    fullText
                        .lowercased()
                        .split { !$0.isLetter }
                        .map(String.init)
                )
                return dogLanguage.allSatisfy { !words.contains($0.lowercased()) }
            })
        }

        #expect(BeanVisit.Artwork.allCases.allSatisfy {
            guard let imageName = $0.imageName(for: .blueberry) else { return false }
            return ["BlueberryVisitImage", "BlueberryBadge"].contains(imageName)
        })
        #expect(BeanVisit.Artwork.allCases.allSatisfy {
            !($0.imageName(for: .bean) ?? "").localizedCaseInsensitiveContains("blueberry")
        })

        let visit = BeanVisit.make(reason: .friendly, theme: .blueberry)
        #expect(visit.theme == .blueberry)
        #expect(visit.artworkImageName.map {
            ["BlueberryVisitImage", "BlueberryBadge"].contains($0)
        } == true)
    }

    @Test func folderWelcomeUsesOnlyInAppFeedbackWhileForegrounded() {
        #expect(!LocalNotificationService.shouldPresentSystemNotificationInForeground(
            identifier: "folder-welcome-test"
        ))
        #expect(LocalNotificationService.shouldPresentSystemNotificationInForeground(
            identifier: "unrelated-notification"
        ))
    }

    @Test func penPaletteUsesCompactDockingOnNarrowIPadWidths() {
        let narrowSize = CGSize(width: 1_024, height: 1_366)
        let wideSize = CGSize(width: 1_366, height: 1_024)

        #expect(PenPaletteLayoutMetrics.prefersCompactLayout(for: narrowSize))
        #expect(!PenPaletteLayoutMetrics.prefersCompactLayout(for: wideSize))
        #expect(
            PenPaletteLayoutMetrics.defaultDockOffset(for: narrowSize).width
            < PenPaletteLayoutMetrics.defaultDockOffset(for: wideSize).width
        )
    }

    @Test func paletteColorCountDefaultsMatchIPadScreenClasses() throws {
        let elevenInchPortrait = CGSize(width: 834, height: 1_210)
        let elevenInchLandscape = CGSize(width: 1_210, height: 834)
        let thirteenInchPortrait = CGSize(width: 1_032, height: 1_376)
        let thirteenInchLandscape = CGSize(width: 1_376, height: 1_032)

        #expect(DrawingPaletteConfiguration.defaultColorCount(for: elevenInchPortrait) == 5)
        #expect(DrawingPaletteConfiguration.defaultColorCount(for: elevenInchLandscape) == 5)
        #expect(DrawingPaletteConfiguration.defaultColorCount(for: thirteenInchPortrait) == 8)
        #expect(DrawingPaletteConfiguration.defaultColorCount(for: thirteenInchLandscape) == 8)
        #expect(DrawingPaletteConfiguration.normalizedColorCount(0) == 1)
        #expect(DrawingPaletteConfiguration.normalizedColorCount(6) == 6)
        #expect(DrawingPaletteConfiguration.normalizedColorCount(99) == 8)

        let elevenInchSuiteName = "BeanNotesPaletteCountDefaults11-\(UUID().uuidString)"
        let thirteenInchSuiteName = "BeanNotesPaletteCountDefaults13-\(UUID().uuidString)"
        let elevenInchDefaults = try #require(UserDefaults(suiteName: elevenInchSuiteName))
        let thirteenInchDefaults = try #require(UserDefaults(suiteName: thirteenInchSuiteName))
        defer {
            elevenInchDefaults.removePersistentDomain(forName: elevenInchSuiteName)
            thirteenInchDefaults.removePersistentDomain(forName: thirteenInchSuiteName)
        }

        #expect(DrawingPaletteConfiguration.persistedColorCount(for: elevenInchPortrait, in: elevenInchDefaults) == 5)
        #expect(DrawingPaletteConfiguration.persistedColorCount(for: thirteenInchPortrait, in: thirteenInchDefaults) == 8)
        #expect(DrawingPaletteConfiguration.persistedColorCount(for: thirteenInchPortrait, in: elevenInchDefaults) == 5)

        elevenInchDefaults.set(6, forKey: DrawingPaletteConfiguration.colorCountStorageKey)
        #expect(DrawingPaletteConfiguration.persistedColorCount(for: thirteenInchPortrait, in: elevenInchDefaults) == 6)

        elevenInchDefaults.set(99, forKey: DrawingPaletteConfiguration.colorCountStorageKey)
        #expect(DrawingPaletteConfiguration.persistedColorCount(for: thirteenInchPortrait, in: elevenInchDefaults) == 8)
    }

    @Test func penPaletteEstimatesCompactCalibrationLayoutInTwoRows() {
        let compactInkSize = PenPaletteLayoutMetrics.estimatedPaletteSize(
            isCompact: true,
            showsInkControls: true
        )
        let regularInkSize = PenPaletteLayoutMetrics.estimatedPaletteSize(
            isCompact: false,
            showsInkControls: true
        )

        #expect(compactInkSize.width < regularInkSize.width)
        #expect(compactInkSize.height > regularInkSize.height)
    }

    @Test func penPaletteDragClampsInsideEditorBounds() {
        let availableSize = CGSize(width: 744, height: 1_024)
        let paletteSize = CGSize(width: 288, height: 126)
        let dockOffset = PenPaletteLayoutMetrics.defaultDockOffset(for: availableSize)

        let farUpperLeft = PenPaletteLayoutMetrics.clampedCommittedOffset(
            CGSize(width: -1_000, height: -1_000),
            availableSize: availableSize,
            paletteSize: paletteSize,
            dockOffset: dockOffset
        )
        let farLowerRight = PenPaletteLayoutMetrics.clampedCommittedOffset(
            CGSize(width: 2_000, height: 2_000),
            availableSize: availableSize,
            paletteSize: paletteSize,
            dockOffset: dockOffset
        )

        #expect(dockOffset.width + farUpperLeft.width == 8)
        #expect(dockOffset.height + farUpperLeft.height == 8)
        #expect(dockOffset.width + farLowerRight.width + paletteSize.width == availableSize.width - 16)
        #expect(dockOffset.height + farLowerRight.height + paletteSize.height == availableSize.height - 24)
    }

    @Test func penPaletteCommittedOffsetStorageRoundTripsFiniteValues() throws {
        let offset = CGSize(width: 24.5, height: -12.25)
        let decoded = try #require(PenPaletteLayoutMetrics.decodedCommittedOffset(
            from: PenPaletteLayoutMetrics.encodedCommittedOffset(offset)
        ))

        #expect(abs(decoded.width - offset.width) < 0.001)
        #expect(abs(decoded.height - offset.height) < 0.001)
        #expect(PenPaletteLayoutMetrics.encodedCommittedOffset(CGSize(width: CGFloat.infinity, height: 3)) == "0.0,3.0")
        #expect(PenPaletteLayoutMetrics.decodedCommittedOffset(from: "bad") == nil)
        #expect(PenPaletteLayoutMetrics.decodedCommittedOffset(from: "1,nan") == nil)
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
        #expect(cappedBudget.maxPixelSize == 6_144)
        #expect(zoomedBudget.shouldReplaceLoadedBudget(baseBudget))
        #expect(baseBudget.shouldReplaceLoadedBudget(zoomedBudget))
        #expect(!moderateZoomBudget.shouldReplaceLoadedBudget(baseBudget))
    }

    @Test func attachmentImageRasterBudgetNormalizesCorruptGeometry() {
        let corruptBudget = AttachmentImageRasterBudget(
            attachmentSize: CGSize(width: CGFloat.nan, height: CGFloat.infinity),
            renderScale: .infinity
        )
        let partiallyValidBudget = AttachmentImageRasterBudget(
            attachmentSize: CGSize(width: CGFloat.nan, height: 900),
            renderScale: 2
        )
        let extremeZoomBudget = AttachmentImageRasterBudget(
            attachmentSize: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 1),
            renderScale: CGFloat.greatestFiniteMagnitude
        )

        #expect(corruptBudget.maxPixelSize == 1_024)
        #expect(partiallyValidBudget.maxPixelSize == 1_800)
        #expect(extremeZoomBudget.maxPixelSize == 6_144)
    }

    @Test func drawingCanvasLayoutSignatureTracksOnlyDocumentLayoutInputs() {
        let page = NotePage(
            pageOrder: 0,
            background: .plain(),
            width: 612,
            height: 792
        )
        let attachment = Attachment(
            kind: .image,
            displayName: "Page",
            originalFileName: "page.jpg",
            storedFileName: "Imports/page.jpg",
            contentTypeIdentifier: UTType.jpeg.identifier,
            fileExtension: "jpg",
            width: 612,
            height: 792,
            isLocked: true,
            rendersBehindDrawing: true
        )
        page.attachments.append(attachment)

        let baseline = DrawingCanvasLayoutSignature(
            pages: [page],
            pageFlowMode: .continuous,
            hasTopContent: false
        )

        page.background = NoteBackground(style: .grid, colorHex: "#FFF7BF")
        attachment.x = 32
        attachment.y = 44
        attachment.width = 540
        attachment.height = 700
        attachment.storedFileName = "Imports/page-revised.jpg"
        attachment.isLocked = false
        attachment.rendersBehindDrawing = false

        #expect(DrawingCanvasLayoutSignature(
            pages: [page],
            pageFlowMode: .continuous,
            hasTopContent: false
        ) == baseline)

        #expect(DrawingCanvasLayoutSignature(
            pages: [page],
            pageFlowMode: .continuous,
            hasTopContent: true
        ) != baseline)

        #expect(DrawingCanvasLayoutSignature(
            pages: [page],
            pageFlowMode: .singlePage,
            hasTopContent: false
        ) != baseline)

        page.width = 640

        #expect(DrawingCanvasLayoutSignature(
            pages: [page],
            pageFlowMode: .continuous,
            hasTopContent: false
        ) != baseline)
    }

    @Test func drawingCanvasConfigurationSignatureIgnoresDrawingMetadataChanges() throws {
        let modelContext = try makeInMemoryModelContext()
        let page = NotePage(pageOrder: 0, width: 612, height: 792)
        let attachment = Attachment(
            kind: .image,
            displayName: "Diagram",
            originalFileName: "diagram.png",
            storedFileName: "Imports/diagram.png",
            contentTypeIdentifier: UTType.png.identifier,
            fileExtension: "png",
            x: 40,
            y: 60,
            width: 240,
            height: 160
        )
        modelContext.insert(page)
        page.attachments.append(attachment)
        try modelContext.save()

        func signature() -> DrawingCanvasConfigurationSignature {
            DrawingCanvasConfigurationSignature(
                pages: [page],
                pageFlowMode: .continuous,
                inputMode: .pencilOnly,
                renderQuality: .balanced,
                storageRootURL: URL(fileURLWithPath: "/tmp/BeanNotesConfigurationSignature"),
                theme: .bean,
                showsBeanArtwork: false,
                hasTopContent: false
            )
        }

        let baseline = signature()
        page.touch(at: Date(timeIntervalSince1970: 1_900_000_000))
        attachment.touch(at: Date(timeIntervalSince1970: 1_900_000_001))

        #expect(signature() == baseline)

        attachment.x += 12
        #expect(signature() != baseline)

        attachment.x -= 12
        page.backgroundStyleRaw = NoteBackgroundStyle.grid.rawValue
        #expect(signature() != baseline)

        attachment.x = .nan
        attachment.y = .infinity
        attachment.width = .nan
        attachment.height = .infinity
        let corruptGeometry = signature()
        #expect(signature() == corruptGeometry)
    }

    @Test @MainActor func attachmentPreviewCommitsOnceAndSurvivesCanvasRefresh() throws {
        let modelContext = try makeInMemoryModelContext()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesAttachmentPreview-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let page = NotePage(pageOrder: 0, width: 612, height: 792)
        let initialUpdate = Date(timeIntervalSince1970: 1_700_000_000)
        let attachment = Attachment(
            kind: .image,
            displayName: "Movable",
            originalFileName: "movable.png",
            storedFileName: "Imports/movable.png",
            contentTypeIdentifier: UTType.png.identifier,
            fileExtension: "png",
            x: 80,
            y: 100,
            width: 240,
            height: 180,
            updatedAt: initialUpdate
        )
        modelContext.insert(page)
        page.attachments.append(attachment)
        try modelContext.save()

        let parent = makeDrawingCanvasView(page: page, drawingStorage: drawingStorage)
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let pageView = DrawingCanvasView.PageCanvasView()
        var commitCount = 0
        defer { pageView.releaseHeavyResources() }

        pageView.configure(
            page: page,
            storage: storage,
            drawingStorage: drawingStorage,
            inputMode: .pencilOnly,
            theme: .bean,
            coordinator: coordinator,
            attachmentChanged: { commitCount += 1 },
            deleteAttachment: { _ in }
        )
        pageView.beginEditingAttachment(id: attachment.id)

        let overlay = try #require(pageView.subviews
            .compactMap { $0 as? DrawingCanvasView.AttachmentEditingOverlayView }
            .first)
        let raster = try #require(pageView.behindImageContainerView.subviews
            .compactMap { $0 as? DrawingCanvasView.AttachmentImageContainerView }
            .first)
        let startFrame = attachment.normalizedFrame(for: page.pageSize)
        let previewFrame = CGRect(x: 132, y: 156, width: 280, height: 210)

        overlay.applyPreview(previewFrame)

        #expect(attachment.normalizedFrame(for: page.pageSize) == startFrame)
        #expect(attachment.updatedAt == initialUpdate)
        #expect(overlay.displayedFrame == previewFrame)
        #expect(raster.frame == previewFrame)
        #expect(commitCount == 0)

        pageView.configure(
            page: page,
            storage: storage,
            drawingStorage: drawingStorage,
            inputMode: .pencilOnly,
            theme: .blueberry,
            coordinator: coordinator,
            attachmentChanged: { commitCount += 1 },
            deleteAttachment: { _ in }
        )
        pageView.layoutPage()

        #expect(overlay.displayedFrame == previewFrame)
        #expect(raster.frame == previewFrame)
        #expect(attachment.normalizedFrame(for: page.pageSize) == startFrame)

        overlay.commitPreview(startingAt: startFrame)

        #expect(attachment.normalizedFrame(for: page.pageSize) == previewFrame)
        #expect(attachment.updatedAt > initialUpdate)
        #expect(commitCount == 1)
    }

    @Test @MainActor func canvasSelectionSynchronizesBeforeLayoutAndRetriesScrolling() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesDeferredCanvasSelection-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let pages = [
            NotePage(pageOrder: 0, drawingFileName: "selection-first.drawing", width: 612, height: 500),
            NotePage(pageOrder: 1, drawingFileName: "selection-second.drawing", width: 612, height: 500)
        ]
        let parent = makeDrawingCanvasView(
            page: pages[0],
            drawingStorage: drawingStorage,
            pages: pages
        )
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let container = DrawingCanvasView.CanvasContainerView(frame: .zero)
        coordinator.containerView = container
        defer { DrawingCanvasView.dismantleUIView(container, coordinator: coordinator) }

        container.configure(
            pages: pages,
            selectedPageID: pages[0].id,
            pageFlowMode: .separated,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: coordinator
        )

        container.synchronizeSelectedPageID(nil)
        #expect(container.currentSelectedPageID == pages[0].id)

        container.prepareForProgrammaticScroll(to: pages[1].id)
        container.synchronizeSelectedPageID(pages[1].id)
        container.scrollToPage(id: pages[1].id, animated: true)
        #expect(container.currentSelectedPageID == pages[1].id)

        container.frame = CGRect(x: 0, y: 0, width: 700, height: 640)
        container.setNeedsLayout()
        container.layoutIfNeeded()

        #expect(container.currentSelectedPageID == pages[1].id)
        #expect(container.scrollView.contentOffset.y > 0)
        #expect(!container.isDocumentTraversalActive)

        container.scrollToPage(id: pages[0].id, animated: true)
        container.scrollToPage(id: pages[0].id, animated: false)
        #expect(!container.isDocumentTraversalActive)
    }

    @Test @MainActor func lightweightCanvasRefreshReassertsDrawingInteraction() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesCanvasInteractionRefresh-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let page = NotePage(pageOrder: 0, drawingFileName: "interaction-refresh.drawing")
        let parent = makeDrawingCanvasView(page: page, drawingStorage: drawingStorage)
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let container = DrawingCanvasView.CanvasContainerView(
            frame: CGRect(x: 0, y: 0, width: 700, height: 900)
        )
        coordinator.containerView = container
        defer { DrawingCanvasView.dismantleUIView(container, coordinator: coordinator) }

        container.configure(
            pages: [page],
            selectedPageID: page.id,
            pageFlowMode: .separated,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: coordinator
        )
        container.layoutIfNeeded()
        let canvas = try #require(container.activeCanvasView)
        canvas.drawingGestureRecognizer.isEnabled = false

        container.reassertInteractionState()

        #expect(canvas.drawingGestureRecognizer.isEnabled)
    }

    @Test @MainActor func paginationModesUseFlushOrSeparatedPageSpacing() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesPaginationSpacing-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let pages = [
            NotePage(pageOrder: 0, drawingFileName: "spacing-first.drawing", width: 612, height: 300),
            NotePage(pageOrder: 1, drawingFileName: "spacing-second.drawing", width: 612, height: 300)
        ]
        let parent = makeDrawingCanvasView(
            page: pages[0],
            drawingStorage: drawingStorage,
            pages: pages
        )
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let container = DrawingCanvasView.CanvasContainerView(
            frame: CGRect(x: 0, y: 0, width: 700, height: 900)
        )
        coordinator.containerView = container
        defer {
            DrawingCanvasView.dismantleUIView(container, coordinator: coordinator)
        }

        func pageFrames() throws -> [CGRect] {
            let frames = container.contentView.subviews
                .compactMap { $0 as? DrawingCanvasView.PageCanvasView }
                .filter { $0.accessibilityLabel != "Continuous drawing canvas" }
                .sorted { ($0.page?.pageOrder ?? 0) < ($1.page?.pageOrder ?? 0) }
                .map(\.frame)
            try #require(frames.count == 2)
            return frames
        }

        container.configure(
            pages: pages,
            selectedPageID: pages[0].id,
            pageFlowMode: .separated,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: coordinator
        )
        container.setNeedsLayout()
        container.layoutIfNeeded()
        let separatedFrames = try pageFrames()
        #expect(abs(separatedFrames[1].minY - separatedFrames[0].maxY - 28) < 0.01)
        #expect(!container.addPageFooterButton.isHidden)
        #expect(container.addPageFooterButton.accessibilityIdentifier == "editor.addPageFooter")

        container.configure(
            pages: pages,
            selectedPageID: pages[0].id,
            pageFlowMode: .seamless,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: coordinator
        )
        container.setNeedsLayout()
        container.layoutIfNeeded()
        let seamlessFrames = try pageFrames()
        #expect(abs(seamlessFrames[1].minY - seamlessFrames[0].maxY) < 0.01)
        #expect(!container.addPageFooterButton.isHidden)
        #expect(abs(container.addPageFooterButton.frame.minY - seamlessFrames[1].maxY - 36) < 0.01)
        #expect(container.addPageFooterButton.accessibilityLabel == "Add drawing space")
    }

    @Test @MainActor func scrollablePaginationUsesOneCanvasAcrossSectionBoundaries() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesContinuousCanvas-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let pages = [
            NotePage(pageOrder: 0, drawingFileName: "continuous-first.drawing", width: 612, height: 300),
            NotePage(pageOrder: 1, drawingFileName: "continuous-second.drawing", width: 612, height: 300)
        ]
        try drawingStorage.save(makeTestDrawing(color: .systemRed, xOffset: 0), for: pages[0])
        try drawingStorage.save(makeTestDrawing(color: .systemBlue, xOffset: 20), for: pages[1])

        let parent = makeDrawingCanvasView(
            page: pages[0],
            drawingStorage: drawingStorage,
            pages: pages
        )
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let container = DrawingCanvasView.CanvasContainerView(
            frame: CGRect(x: 0, y: 0, width: 700, height: 900)
        )
        coordinator.containerView = container
        defer {
            DrawingCanvasView.dismantleUIView(container, coordinator: coordinator)
        }

        container.configure(
            pages: pages,
            selectedPageID: pages[0].id,
            pageFlowMode: .seamless,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: coordinator
        )
        container.setNeedsLayout()
        container.layoutIfNeeded()

        let continuousPageView = try #require(
            container.contentView.subviews
                .compactMap { $0 as? DrawingCanvasView.PageCanvasView }
                .first { $0.accessibilityLabel == "Continuous drawing canvas" }
        )
        let sectionViews = container.contentView.subviews
            .compactMap { $0 as? DrawingCanvasView.PageCanvasView }
            .filter { $0.accessibilityIdentifier == "noteCanvasSection" }

        #expect(container.activeCanvasView === continuousPageView.canvasView)
        #expect(continuousPageView.frame.size == CGSize(width: 612, height: 600))
        #expect(continuousPageView.canvasView.drawing.strokes.count == 2)
        #expect(sectionViews.count == 2)
        #expect(sectionViews.allSatisfy { $0.layer.shadowOpacity == 0 })
        #expect(sectionViews.allSatisfy { !$0.canvasView.isUserInteractionEnabled })

        let boundaryStroke = makeTestStroke(
            from: CGPoint(x: 140, y: 285),
            to: CGPoint(x: 180, y: 315),
            width: 8
        )
        continuousPageView.canvasView.drawing = PKDrawing(
            strokes: continuousPageView.canvasView.drawing.strokes + [boundaryStroke]
        )
        coordinator.canvasViewDrawingDidChange(continuousPageView.canvasView)
        coordinator.saveAllCanvases(force: true)

        let firstSavedDrawing = drawingStorage.loadDrawing(for: pages[0])
        let secondSavedDrawing = drawingStorage.loadDrawing(for: pages[1])
        #expect(firstSavedDrawing.strokes.count == 2)
        #expect(secondSavedDrawing.strokes.count == 2)
        #expect(firstSavedDrawing.strokes.contains { $0.renderBounds.maxY > pages[0].pageSize.height })
        #expect(secondSavedDrawing.strokes.contains { $0.renderBounds.minY < 0 })

        container.configure(
            pages: pages,
            selectedPageID: pages[0].id,
            pageFlowMode: .separated,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: coordinator
        )
        container.configure(
            pages: pages,
            selectedPageID: pages[0].id,
            pageFlowMode: .seamless,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: coordinator
        )

        let rejoinedCanvas = try #require(container.activeCanvasView)
        #expect(rejoinedCanvas.drawing.strokes.count == 3)
    }

    @Test @MainActor func scrollableCanvasRoutesImageSelectionAndControlsAbovePencilKit() throws {
        let modelContext = try makeInMemoryModelContext()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesScrollableImageEditing-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let page = NotePage(
            pageOrder: 0,
            drawingFileName: "scrollable-image-editing.drawing",
            width: 612,
            height: 792
        )
        let image = Attachment(
            kind: .image,
            displayName: "Editable Image",
            originalFileName: "editable.png",
            storedFileName: "Imports/editable.png",
            contentTypeIdentifier: UTType.png.identifier,
            fileExtension: "png",
            x: 80,
            y: 100,
            width: 240,
            height: 180,
            rendersBehindDrawing: true
        )
        modelContext.insert(page)
        page.attachments.append(image)
        try modelContext.save()

        let parent = makeDrawingCanvasView(page: page, drawingStorage: drawingStorage)
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let container = DrawingCanvasView.CanvasContainerView(
            frame: CGRect(x: 0, y: 0, width: 700, height: 900)
        )
        coordinator.containerView = container
        defer {
            DrawingCanvasView.dismantleUIView(container, coordinator: coordinator)
        }

        container.configure(
            pages: [page],
            selectedPageID: page.id,
            pageFlowMode: .seamless,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: coordinator
        )
        container.setNeedsLayout()
        container.layoutIfNeeded()

        let sectionView = try #require(container.contentView.subviews
            .compactMap { $0 as? DrawingCanvasView.PageCanvasView }
            .first { $0.accessibilityIdentifier == "noteCanvasSection" })
        let continuousView = try #require(container.contentView.subviews
            .compactMap { $0 as? DrawingCanvasView.PageCanvasView }
            .first { $0.accessibilityLabel == "Continuous drawing canvas" })
        let selectionPoint = CGPoint(
            x: sectionView.frame.minX + image.frame.midX,
            y: sectionView.frame.minY + image.frame.midY
        )

        #expect(container.selectSeamlessAttachment(at: selectionPoint))
        #expect(sectionView.selectedAttachmentID == image.id)

        let editingHost = try #require(container.contentView.subviews
            .compactMap { $0 as? DrawingCanvasView.AttachmentEditingHostView }
            .first)
        let overlay = try #require(editingHost.subviews
            .compactMap { $0 as? DrawingCanvasView.AttachmentEditingOverlayView }
            .first)
        let continuousIndex = try #require(container.contentView.subviews.firstIndex { $0 === continuousView })
        let editingHostIndex = try #require(container.contentView.subviews.firstIndex { $0 === editingHost })
        #expect(editingHostIndex > continuousIndex)

        overlay.layoutIfNeeded()
        let controls = overlay.subviews.compactMap { $0 as? UIButton }
        #expect(controls.count == 1)
        for control in controls {
            let controlCenter = control.convert(
                CGPoint(x: control.bounds.midX, y: control.bounds.midY),
                to: container.contentView
            )
            #expect(container.contentView.hitTest(controlCenter, with: nil) === control)
        }

        let overlayCenter = overlay.convert(
            CGPoint(x: overlay.bounds.midX, y: overlay.bounds.midY),
            to: container.contentView
        )
        #expect(container.contentView.hitTest(overlayCenter, with: nil) === overlay)
        #expect(overlay.editingPanGestureRecognizers.count == 1)
        #expect(overlay.resizeHandle(at: CGPoint(x: overlay.bounds.maxX, y: overlay.bounds.midY)) == .right)

        let focusReleasePoint = CGPoint(
            x: sectionView.frame.minX + 20,
            y: sectionView.frame.minY + 20
        )
        #expect(!container.selectSeamlessAttachment(at: focusReleasePoint))
        #expect(sectionView.selectedAttachmentID == nil)
        #expect(!container.contentView.subviews.contains { $0 is DrawingCanvasView.AttachmentEditingHostView })

        #expect(container.selectSeamlessAttachment(at: selectionPoint))
        let deletionHost = try #require(container.contentView.subviews
            .compactMap { $0 as? DrawingCanvasView.AttachmentEditingHostView }
            .first)
        let deletionOverlay = try #require(deletionHost.subviews
            .compactMap { $0 as? DrawingCanvasView.AttachmentEditingOverlayView }
            .first)
        deletionOverlay.layoutIfNeeded()
        let deleteControl = try #require(deletionOverlay.subviews
            .compactMap { $0 as? UIButton }
            .first { $0.accessibilityLabel == "Delete Editable Image" })
        deleteControl.sendActions(for: .touchUpInside)
        #expect(sectionView.selectedAttachmentID == nil)
        #expect(!container.contentView.subviews.contains { $0 is DrawingCanvasView.AttachmentEditingHostView })
    }

    @Test @MainActor func zoomedRelayoutPreservesViewportAndReachableDocumentEdges() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesZoomedRelayout-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let firstPage = NotePage(
            pageOrder: 0,
            drawingFileName: "relayout-first.drawing",
            width: 1_200,
            height: 900
        )
        let secondPage = NotePage(
            pageOrder: 1,
            drawingFileName: "relayout-second.drawing",
            width: 1_200,
            height: 900
        )
        let parent = makeDrawingCanvasView(page: firstPage, drawingStorage: drawingStorage)
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let container = DrawingCanvasView.CanvasContainerView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 700)
        )
        coordinator.containerView = container
        defer {
            DrawingCanvasView.dismantleUIView(container, coordinator: coordinator)
        }

        container.configure(
            pages: [firstPage],
            selectedPageID: firstPage.id,
            pageFlowMode: .seamless,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: coordinator
        )
        container.setNeedsLayout()
        container.layoutIfNeeded()
        container.scrollView.setZoomScale(2, animated: false)
        container.scrollView.setContentOffset(CGPoint(x: 700, y: 300), animated: false)
        let expectedViewport = try #require(container.currentViewport())

        container.configure(
            pages: [firstPage, secondPage],
            selectedPageID: firstPage.id,
            pageFlowMode: .seamless,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: coordinator
        )
        container.setNeedsLayout()
        container.layoutIfNeeded()

        let expectedDocumentSize = CGSize(width: 1_200, height: 1_934)
        #expect(container.contentView.bounds == CGRect(origin: .zero, size: expectedDocumentSize))
        #expect(abs(container.contentView.center.x - 1_200) < 0.01)
        #expect(abs(container.contentView.center.y - 1_934) < 0.01)
        #expect(abs(container.scrollView.contentSize.width - 2_400) < 0.01)
        #expect(abs(container.scrollView.contentSize.height - 3_868) < 0.01)

        let actualViewport = try #require(container.currentViewport())
        #expect(abs(actualViewport.zoomScale - expectedViewport.zoomScale) < 0.01)
        #expect(abs(actualViewport.center.x - expectedViewport.center.x) < 1)
        #expect(abs(actualViewport.center.y - expectedViewport.center.y) < 1)

        let inset = container.scrollView.adjustedContentInset
        container.scrollView.setContentOffset(
            CGPoint(
                x: container.scrollView.contentSize.width - container.scrollView.bounds.width + inset.right,
                y: container.scrollView.contentSize.height - container.scrollView.bounds.height + inset.bottom
            ),
            animated: false
        )
        let trailingVisibleRect = container.contentView.convert(
            container.scrollView.bounds,
            from: container.scrollView
        )
        #expect(trailingVisibleRect.maxX >= expectedDocumentSize.width - 1)
        #expect(trailingVisibleRect.maxY >= expectedDocumentSize.height - 1)
    }

    @Test func drawingCanvasLayoutSignatureNormalizesCorruptPageDimensions() {
        let page = NotePage(
            pageOrder: 0,
            background: .plain(),
            width: .nan,
            height: .infinity
        )
        let baseline = DrawingCanvasLayoutSignature(
            pages: [page],
            pageFlowMode: .continuous,
            hasTopContent: false
        )

        #expect(DrawingCanvasLayoutSignature(
            pages: [page],
            pageFlowMode: .continuous,
            hasTopContent: false
        ) == baseline)

        page.width = NotePage.maximumPageDimension + 100
        page.height = 612
        let clamped = DrawingCanvasLayoutSignature(
            pages: [page],
            pageFlowMode: .continuous,
            hasTopContent: false
        )

        page.width = NotePage.maximumPageDimension + 900

        #expect(DrawingCanvasLayoutSignature(
            pages: [page],
            pageFlowMode: .continuous,
            hasTopContent: false
        ) == clamped)
    }

    @Test @MainActor func drawingStaticSignatureNormalizesCorruptAttachmentGeometry() {
        let attachment = Attachment(
            kind: .image,
            displayName: "Corrupt Image",
            originalFileName: "corrupt.png",
            storedFileName: "Imports/corrupt.png",
            contentTypeIdentifier: UTType.png.identifier,
            fileExtension: "png",
            isLocked: true,
            rendersBehindDrawing: true
        )
        attachment.x = .nan
        attachment.y = .infinity
        attachment.width = .nan
        attachment.height = .infinity

        let signature = DrawingCanvasStaticContentSignature.attachmentComponent(for: attachment)

        #expect(signature.contains("320x220"))
    }

    @Test @MainActor func renderSnapshotNormalizesCorruptPageAndAttachmentGeometry() {
        let page = NotePage(
            pageOrder: 0,
            background: .plain()
        )
        page.width = .nan
        page.height = .infinity

        let snapshot = NotePageRenderSnapshot(page: page)

        let corruptAttachment = Attachment(
            kind: .image,
            displayName: "Corrupt Render Image",
            originalFileName: "corrupt-render.png",
            storedFileName: "Imports/corrupt-render.png",
            contentTypeIdentifier: UTType.png.identifier,
            fileExtension: "png",
            isLocked: true,
            rendersBehindDrawing: true
        )
        corruptAttachment.x = .nan
        corruptAttachment.y = .infinity
        corruptAttachment.width = .nan
        corruptAttachment.height = .infinity
        let attachmentSnapshot = NoteImageAttachmentRenderSnapshot(
            attachment: corruptAttachment,
            pageSize: snapshot.pageSize
        )

        #expect(snapshot.pageSize == CGSize(width: NotePage.defaultPageWidth, height: NotePage.defaultPageHeight))
        #expect(attachmentSnapshot.frame == CGRect(
            x: Attachment.defaultX,
            y: Attachment.defaultY,
            width: Attachment.defaultWidth,
            height: Attachment.defaultHeight
        ))
    }

    @Test func imageMemoryCacheEvictsAllVariantsForFileURL() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesImageCache-\(UUID().uuidString)", isDirectory: true)
        defer {
            ImageMemoryCache.shared.removeAllImages()
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let imageURL = rootURL.appendingPathComponent("diagram.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
        }
        try #require(image.pngData()).write(to: imageURL)

        ImageMemoryCache.shared.removeAllImages()
        #expect(ImageMemoryCache.shared.image(at: imageURL, maxPixelSize: 48) != nil)
        #expect(ImageMemoryCache.shared.image(at: imageURL, maxPixelSize: 96) != nil)
        #expect(ImageMemoryCache.shared.cachedVariantCount(for: imageURL) == 2)

        ImageMemoryCache.shared.removeImages(for: imageURL)
        #expect(ImageMemoryCache.shared.cachedVariantCount(for: imageURL) == 0)
    }

    @Test func imageMemoryCacheBoundedLoadsRespectPixelBudget() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesBoundedImageCache-\(UUID().uuidString)", isDirectory: true)
        defer {
            ImageMemoryCache.shared.removeAllImages()
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let imageURL = rootURL.appendingPathComponent("large-diagram.jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 240)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 240))
        }
        try #require(image.jpegData(compressionQuality: 0.9)).write(to: imageURL)

        ImageMemoryCache.shared.removeAllImages()
        let boundedImage = try #require(ImageMemoryCache.shared.image(at: imageURL, maxPixelSize: 80))
        let cgImage = try #require(boundedImage.cgImage)

        #expect(max(cgImage.width, cgImage.height) <= 80)
        #expect(ImageMemoryCache.shared.cachedVariantCount(for: imageURL) == 1)
    }

    @Test func imageMemoryCacheNormalizesInvalidAndExtremePixelBudgets() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesImageBudgetNormalization-\(UUID().uuidString)", isDirectory: true)
        defer {
            ImageMemoryCache.shared.removeAllImages()
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let imageURL = rootURL.appendingPathComponent("budget.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 16)).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        }
        try #require(image.pngData()).write(to: imageURL)

        ImageMemoryCache.shared.removeAllImages()
        #expect(ImageMemoryCache.shared.image(at: imageURL) != nil)
        #expect(ImageMemoryCache.shared.cachedVariantCount(for: imageURL) == 1)

        for invalidBudget in [CGFloat.nan, .infinity, -.infinity, -1, 0] {
            #expect(ImageMemoryCache.shared.image(
                at: imageURL,
                maxPixelSize: invalidBudget
            ) != nil)
        }
        #expect(ImageMemoryCache.shared.cachedVariantCount(for: imageURL) == 1)

        let onePixelImage = try #require(ImageMemoryCache.shared.image(
            at: imageURL,
            maxPixelSize: 0.4
        ))
        let onePixelRaster = try #require(onePixelImage.cgImage)
        #expect(max(onePixelRaster.width, onePixelRaster.height) <= 1)

        #expect(ImageMemoryCache.shared.image(
            at: imageURL,
            maxPixelSize: .greatestFiniteMagnitude
        ) != nil)
        #expect(ImageMemoryCache.shared.cachedVariantCount(for: imageURL) == 3)
    }

    @Test func imageMemoryCacheLoadsThumbnailsInBackground() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesBackgroundImageCache-\(UUID().uuidString)", isDirectory: true)
        defer {
            ImageMemoryCache.shared.removeAllImages()
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let imageURL = rootURL.appendingPathComponent("note-preview.jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 720, height: 360)).image { context in
            UIColor.systemMint.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 720, height: 360))
        }
        try #require(image.jpegData(compressionQuality: 0.9)).write(to: imageURL)

        ImageMemoryCache.shared.removeAllImages()
        let decodedImage = try #require(
            await ImageMemoryCache.shared.imageInBackground(at: imageURL, maxPixelSize: 120)
        )
        let cgImage = try #require(decodedImage.cgImage)

        #expect(max(cgImage.width, cgImage.height) <= 120)
        #expect(ImageMemoryCache.shared.cachedVariantCount(for: imageURL) == 1)
    }

    @Test func imageMemoryCacheSkipsCancelledQueuedDecode() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesCancelledImageCache-\(UUID().uuidString)", isDirectory: true)
        defer {
            ImageMemoryCache.shared.removeAllImages()
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let imageURL = rootURL.appendingPathComponent("cancelled-preview.jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        }
        try #require(image.jpegData(compressionQuality: 0.9)).write(to: imageURL)

        ImageMemoryCache.shared.removeAllImages()
        let decodedImage = await Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return await ImageMemoryCache.shared.imageInBackground(
                at: imageURL,
                maxPixelSize: 120
            )
        }.value

        #expect(decodedImage == nil)
        #expect(ImageMemoryCache.shared.cachedVariantCount(for: imageURL) == 0)
    }

    @Test func thumbnailAttachmentRenderingUsesBoundedRaster() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesThumbnailAttachmentRaster-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let imageURL = rootURL.appendingPathComponent("large-attachment.jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 720, height: 280)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 720, height: 280))
        }
        try #require(image.jpegData(compressionQuality: 0.9)).write(to: imageURL)

        let renderedImage = try #require(ThumbnailService.renderAttachmentImage(at: imageURL, maxPixelSize: 90))
        let cgImage = try #require(renderedImage.cgImage)

        #expect(max(cgImage.width, cgImage.height) <= 90)
    }

    @Test func thumbnailAttachmentRenderingNormalizesCorruptPixelBudget() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesThumbnailBudget-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let imageURL = rootURL.appendingPathComponent("image.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        try #require(image.pngData()).write(to: imageURL, options: [.atomic])

        let rendered = try #require(ThumbnailService.renderAttachmentImage(at: imageURL, maxPixelSize: .nan))

        #expect(rendered.size.width >= 1)
        #expect(rendered.size.height >= 1)
    }

    @Test @MainActor func thumbnailRenderingNormalizesInvalidMaxDimensions() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesThumbnailDimension-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let page = NotePage(pageOrder: 0, width: 1_024, height: 1_366)
        let snapshot = NotePageRenderSnapshot(page: page)
        let invalidThumbnail = ThumbnailService.renderThumbnailImage(
            snapshot: snapshot,
            drawing: PKDrawing(),
            rootURL: rootURL,
            maxDimension: .nan
        )
        let cappedThumbnail = ThumbnailService.renderThumbnailImage(
            snapshot: snapshot,
            drawing: PKDrawing(),
            rootURL: rootURL,
            maxDimension: 20_000
        )
        let invalidCGImage = try #require(invalidThumbnail.cgImage)
        let cappedCGImage = try #require(cappedThumbnail.cgImage)

        #expect(max(invalidCGImage.width, invalidCGImage.height) <= 360)
        #expect(max(invalidCGImage.width, invalidCGImage.height) > 0)
        #expect(max(cappedCGImage.width, cappedCGImage.height) <= 1_024)
        #expect(max(cappedCGImage.width, cappedCGImage.height) > 0)
    }

    @Test @MainActor func pageRenderingNormalizesInvalidAndExtremeScales() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesPageRenderScale-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let page = NotePage(pageOrder: 0, width: 320, height: 240)
        let snapshot = NotePageRenderSnapshot(page: page)
        let nanScaleImage = ThumbnailService.renderPageImage(
            snapshot: snapshot,
            drawing: PKDrawing(),
            rootURL: rootURL,
            scale: .nan
        )
        let negativeScaleImage = ThumbnailService.renderPageImage(
            snapshot: snapshot,
            drawing: PKDrawing(),
            rootURL: rootURL,
            scale: -12
        )
        let nanCGImage = try #require(nanScaleImage.cgImage)
        let negativeCGImage = try #require(negativeScaleImage.cgImage)

        #expect(nanCGImage.width == 320)
        #expect(nanCGImage.height == 240)
        #expect(negativeCGImage.width == 320)
        #expect(negativeCGImage.height == 240)

        let widePage = NotePage(pageOrder: 0, width: 4_096, height: 512)
        let wideSnapshot = NotePageRenderSnapshot(page: widePage)
        let extremeScaleImage = ThumbnailService.renderPageImage(
            snapshot: wideSnapshot,
            drawing: PKDrawing(),
            rootURL: rootURL,
            scale: 100
        )
        let extremeCGImage = try #require(extremeScaleImage.cgImage)

        #expect(max(extremeCGImage.width, extremeCGImage.height) <= 6_144)
        #expect(min(extremeCGImage.width, extremeCGImage.height) > 0)

        let squarePage = NotePage(pageOrder: 0, width: 4_096, height: 4_096)
        let squareImage = ThumbnailService.renderPageImage(
            snapshot: NotePageRenderSnapshot(page: squarePage),
            drawing: PKDrawing(),
            rootURL: rootURL,
            scale: 100
        )
        let squareCGImage = try #require(squareImage.cgImage)

        #expect(squareCGImage.width * squareCGImage.height <= 16_000_000)
        #expect(squareCGImage.width > 2_000)
        #expect(squareCGImage.height > 2_000)
    }

    @Test @MainActor func thumbnailRenderingPreservesInkColorInDarkMode() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesThumbnailInkAppearance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let page = NotePage(
            pageOrder: 0,
            background: NoteBackground(style: .plain, colorHex: "#FFFFFF"),
            width: 120,
            height: 140
        )
        let drawing = makeTestDrawing(color: .systemRed, xOffset: 0)
        var image: UIImage?

        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            image = ThumbnailService.renderThumbnailImage(
                snapshot: NotePageRenderSnapshot(page: page, theme: .standard),
                drawing: drawing,
                rootURL: rootURL,
                maxDimension: 140
            )
        }

        #expect(imageContainsDominantRedInk(try #require(image)))
    }

    @Test @MainActor func beanThemeRendersIntoNotePagesAndExportImages() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesBeanPaper-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let page = NotePage(
            pageOrder: 0,
            background: NoteBackground(style: .plain, colorHex: "#FFF9EC"),
            width: 320,
            height: 420
        )
        let standardImage = ThumbnailService.renderPageImage(
            snapshot: NotePageRenderSnapshot(page: page, theme: .standard),
            drawing: PKDrawing(),
            rootURL: rootURL,
            scale: 1
        )
        let beanImageWithoutArtwork = ThumbnailService.renderPageImage(
            snapshot: NotePageRenderSnapshot(page: page, theme: .bean, showsBeanArtwork: false),
            drawing: PKDrawing(),
            rootURL: rootURL,
            scale: 1
        )
        let beanImageWithArtwork = ThumbnailService.renderPageImage(
            snapshot: NotePageRenderSnapshot(page: page, theme: .bean, showsBeanArtwork: true),
            drawing: PKDrawing(),
            rootURL: rootURL,
            scale: 1
        )

        #expect(standardImage.size == beanImageWithArtwork.size)
        #expect(standardImage.pngData() == beanImageWithoutArtwork.pngData())
        #expect(standardImage.pngData() != beanImageWithArtwork.pngData())
    }

    @Test @MainActor func blueberryPaperRendersOnlyForBlueberryWhenEnabled() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesBlueberryPaper-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let page = NotePage(
            pageOrder: 0,
            background: NoteBackground(style: .lined, colorHex: "#FFFFFF"),
            width: 320,
            height: 420
        )
        let drawing = PKDrawing()
        let standardImage = ThumbnailService.renderPageImage(
            snapshot: NotePageRenderSnapshot(page: page, theme: .standard, showsBeanArtwork: true),
            drawing: drawing,
            rootURL: rootURL,
            scale: 1
        )
        let blueberryWithoutArtwork = ThumbnailService.renderPageImage(
            snapshot: NotePageRenderSnapshot(page: page, theme: .blueberry, showsBeanArtwork: false),
            drawing: drawing,
            rootURL: rootURL,
            scale: 1
        )
        let blueberryWithArtwork = ThumbnailService.renderPageImage(
            snapshot: NotePageRenderSnapshot(page: page, theme: .blueberry, showsBeanArtwork: true),
            drawing: drawing,
            rootURL: rootURL,
            scale: 1
        )

        #expect(standardImage.pngData() == blueberryWithoutArtwork.pngData())
        #expect(standardImage.pngData() != blueberryWithArtwork.pngData())
        #expect(blueberryWithoutArtwork.pngData() != blueberryWithArtwork.pngData())
    }

    @Test func blueberryPaperTextureTilesCoverPracticalPageSizesEfficiently() {
        for rect in [
            CGRect(x: 0, y: 0, width: 320, height: 420),
            CGRect(x: 24, y: 40, width: 1_024, height: 1_366),
            CGRect(x: 0, y: 0, width: 4_096, height: 4_096)
        ] {
            let tiles = NoteBackgroundRenderer.blueberryPaperTextureRects(in: rect)
            #expect(!tiles.isEmpty)
            #expect(tiles.count <= 64)
            #expect(tiles.allSatisfy { $0.intersects(rect) })

            let coveredBounds = tiles.reduce(CGRect.null) { $0.union($1) }
            #expect(coveredBounds.contains(rect))
        }
    }

    @Test func beanPaperArtworkSelectionIsDeterministicPerPage() throws {
        let firstPageID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000004"))
        let secondPageID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))

        let firstSelection = NoteBackgroundRenderer.beanPaperArtwork(for: firstPageID)
        let repeatedSelection = NoteBackgroundRenderer.beanPaperArtwork(for: firstPageID)
        let secondSelection = NoteBackgroundRenderer.beanPaperArtwork(for: secondPageID)

        #expect(firstSelection == repeatedSelection)
        #expect(
            Set([firstSelection.imageName, secondSelection.imageName])
                == Set(["BeanWelcomeImage", "BeanTabAvatar"])
        )
    }

    @Test func chalkboardUsesTransparentRedBeanInBottomRight() {
        let pageRect = CGRect(x: 24, y: 40, width: 960, height: 540)
        let artworkRect = NoteBackgroundRenderer.chalkboardBeanArtworkRect(in: pageRect)
        let beanImage = UIImage(named: NoteBackgroundRenderer.chalkboardBeanImageName)

        #expect(NoteBackgroundRenderer.chalkboardBeanImageName == "BeanWelcomeImage")
        #expect(beanImage?.cgImage?.alphaInfo != CGImageAlphaInfo.none)
        #expect(beanImage?.cgImage?.alphaInfo != CGImageAlphaInfo.noneSkipFirst)
        #expect(beanImage?.cgImage?.alphaInfo != CGImageAlphaInfo.noneSkipLast)
        #expect(pageRect.contains(artworkRect))
        #expect(artworkRect.midX > pageRect.midX)
        #expect(artworkRect.midY > pageRect.midY)
        #expect(artworkRect.width <= pageRect.width * 0.22 + 0.001)
        #expect(artworkRect.height <= pageRect.height * 0.42 + 0.001)
    }

    @Test @MainActor func plainChalkboardInteriorHasNoDecorativeMarks() throws {
        let size = CGSize(width: 320, height: 180)
        let bounds = CGRect(origin: .zero, size: size)
        let background = NoteBackground(style: .chalkboard, colorHex: "#FFFFFF")
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1

        let renderedImage = UIGraphicsImageRenderer(size: size, format: format).image { context in
            NoteBackgroundRenderer.draw(
                background: background,
                in: bounds,
                context: context.cgContext
            )
        }
        let expectedImage = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(hex: background.renderedColorHex).setFill()
            context.fill(bounds)
        }

        let interior = CGRect(x: 20, y: 20, width: 280, height: 140)
        let renderedInterior = try #require(renderedImage.cgImage?.cropping(to: interior))
        let expectedInterior = try #require(expectedImage.cgImage?.cropping(to: interior))

        #expect(UIImage(cgImage: renderedInterior).pngData() == UIImage(cgImage: expectedInterior).pngData())
    }

    @Test @MainActor func chalkboardRenderingSupportsGridColorAndStableBeanArtwork() throws {
        let size = CGSize(width: 320, height: 180)
        let plain = NoteBackground(style: .chalkboard, colorHex: "#FFFFFF")
        let grid = NoteBackground(
            style: .chalkboard,
            colorHex: "#FFFFFF",
            chalkboardPattern: .grid
        )
        let charcoal = NoteBackground(
            style: .chalkboard,
            colorHex: "#FFFFFF",
            chalkColorHex: "#262A2D"
        )

        func render(
            _ background: NoteBackground,
            showsBean: Bool = false,
            pageID: UUID? = nil
        ) -> Data? {
            UIGraphicsImageRenderer(size: size).image { context in
                NoteBackgroundRenderer.draw(
                    background: background,
                    theme: .bean,
                    showsBeanArtwork: showsBean,
                    pageID: pageID,
                    in: CGRect(origin: .zero, size: size),
                    context: context.cgContext
                )
            }.pngData()
        }

        let firstPageID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondPageID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))

        #expect(render(plain) != render(grid))
        #expect(render(plain) != render(charcoal))
        #expect(render(grid, showsBean: true, pageID: firstPageID) != render(grid))
        #expect(
            render(grid, showsBean: true, pageID: firstPageID)
                == render(grid, showsBean: true, pageID: secondPageID)
        )
    }

    @Test func beanPaperArtworkIsCenteredAndLarge() throws {
        let pageRect = CGRect(x: 24, y: 40, width: 1_024, height: 1_366)
        let pageIDs = [
            try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000004")),
            try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        ]

        for pageID in pageIDs {
            let artwork = NoteBackgroundRenderer.beanPaperArtwork(for: pageID)
            let artworkRect = NoteBackgroundRenderer.beanPaperArtworkRect(for: artwork, in: pageRect)

            #expect(abs(artworkRect.midX - pageRect.midX) < 0.001)
            #expect(abs(artworkRect.midY - pageRect.midY) < 0.001)
            #expect(artworkRect.width >= pageRect.width * 0.55)
            #expect(artworkRect.height <= pageRect.height * artwork.maximumHeightRatio + 0.001)
        }
    }

    @Test func beanPaperArtworkIncludesVariedStableLayouts() throws {
        let pageRect = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
        var layouts = Set<BeanPaperArtworkLayout>()

        for suffix in 0...4 {
            let pageID = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000\(suffix)"))
            let artwork = NoteBackgroundRenderer.beanPaperArtwork(for: pageID)
            let repeatedArtwork = NoteBackgroundRenderer.beanPaperArtwork(for: pageID)

            #expect(artwork == repeatedArtwork)
            #expect(!NoteBackgroundRenderer.beanPaperArtworkRects(for: artwork, in: pageRect).isEmpty)
            layouts.insert(artwork.layout)
        }

        #expect(layouts == Set([.centered, .tiled, .scattered, .border]))
    }

    @Test func tiledBeanPaperArtworkUsesManySmallBeans() throws {
        let pageID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let pageRect = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
        let artwork = NoteBackgroundRenderer.beanPaperArtwork(for: pageID)
        let artworkRects = NoteBackgroundRenderer.beanPaperArtworkRects(for: artwork, in: pageRect)

        #expect(artwork.layout == .tiled)
        #expect(artworkRects.count >= 40)
        #expect(artworkRects.allSatisfy { $0.width < pageRect.width * 0.1 })
        #expect(artworkRects.allSatisfy { pageRect.contains($0) })
    }

    @Test @MainActor func beanPaperArtworkSelectionFlowsIntoExportRendering() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesRandomBeanPaper-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let firstPageID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        let secondPageID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let background = NoteBackground(style: .plain, colorHex: "#FFF9EC")
        let firstPage = NotePage(
            id: firstPageID,
            pageOrder: 0,
            background: background,
            width: 320,
            height: 420
        )
        let secondPage = NotePage(
            id: secondPageID,
            pageOrder: 0,
            background: background,
            width: 320,
            height: 420
        )

        let firstImage = ThumbnailService.renderPageImage(
            snapshot: NotePageRenderSnapshot(page: firstPage, theme: .bean, showsBeanArtwork: true),
            drawing: PKDrawing(),
            rootURL: rootURL,
            scale: 1
        )
        let secondImage = ThumbnailService.renderPageImage(
            snapshot: NotePageRenderSnapshot(page: secondPage, theme: .bean, showsBeanArtwork: true),
            drawing: PKDrawing(),
            rootURL: rootURL,
            scale: 1
        )

        #expect(firstImage.pngData() != secondImage.pngData())
    }

    @Test func imageMemoryCacheReusesStandardizedURLVariants() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesStandardizedImageCache-\(UUID().uuidString)", isDirectory: true)
        defer {
            ImageMemoryCache.shared.removeAllImages()
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("Alias", isDirectory: true),
            withIntermediateDirectories: true
        )
        let imageURL = rootURL.appendingPathComponent("diagram.png")
        let aliasURL = rootURL
            .appendingPathComponent("Alias", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("diagram.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96)).image { context in
            UIColor.systemMint.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
        }
        try #require(image.pngData()).write(to: imageURL)

        ImageMemoryCache.shared.removeAllImages()
        let firstImage = try #require(ImageMemoryCache.shared.image(at: aliasURL, maxPixelSize: 64))
        let secondImage = try #require(ImageMemoryCache.shared.image(at: imageURL, maxPixelSize: 64))

        #expect(firstImage === secondImage)
        #expect(ImageMemoryCache.shared.cachedVariantCount(for: imageURL) == 1)
    }

    @Test func localStorageCleanupEvictsDecodedImageVariants() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesCleanupImageCache-\(UUID().uuidString)", isDirectory: true)
        defer {
            ImageMemoryCache.shared.removeAllImages()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let storedImage = try storage.saveData(
            try #require(image.pngData()),
            preferredName: "cached.png",
            contentType: .png,
            to: .imports
        )
        let imageURL = storage.url(forRelativePath: storedImage.relativePath)
        let attachment = Attachment(
            kind: .image,
            displayName: "Cached",
            originalFileName: "cached.png",
            storedFileName: storedImage.relativePath,
            contentTypeIdentifier: UTType.png.identifier,
            fileExtension: "png"
        )

        ImageMemoryCache.shared.removeAllImages()
        #expect(ImageMemoryCache.shared.image(at: imageURL, maxPixelSize: 64) != nil)
        #expect(ImageMemoryCache.shared.cachedVariantCount(for: imageURL) == 1)

        let report = storage.removeStoredFiles(matching: LocalStorageCleanupTarget(attachment: attachment))

        #expect(report.failedRelativePaths.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: imageURL.path))
        #expect(ImageMemoryCache.shared.cachedVariantCount(for: imageURL) == 0)
    }

    @Test @MainActor func attachmentImageContainerDefersAndReleasesOffscreenRasters() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesAttachmentRaster-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48))
        let sourceImage = renderer.image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        }
        let imageData = try #require(sourceImage.pngData())
        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let storedImage = try storage.saveData(
            imageData,
            preferredName: "diagram.png",
            contentType: .png,
            to: .imports
        )
        let attachment = Attachment(
            kind: .image,
            displayName: "Diagram",
            originalFileName: "diagram.png",
            storedFileName: storedImage.relativePath,
            contentTypeIdentifier: UTType.png.identifier,
            fileExtension: "png",
            width: 320,
            height: 220
        )
        let imageContainer = DrawingCanvasView.AttachmentImageContainerView()

        imageContainer.setImageLoadingEnabled(false)
        imageContainer.updateRasterScale(2)
        imageContainer.configure(
            attachment: attachment,
            storage: storage,
            pageSize: CGSize(width: 612, height: 792),
            changed: {}
        )
        #expect(!imageContainer.hasVectorPDFView)
        #expect(!imageContainer.isRasterImageLoaded)

        imageContainer.setImageLoadingEnabled(true)
        try await waitForRasterImage(in: imageContainer)

        imageContainer.setImageLoadingEnabled(false)
        #expect(!imageContainer.isRasterImageLoaded)
    }

    @Test @MainActor func attachmentImageContainerRetriesAfterTransientDecodeFailure() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesAttachmentRetry-\(UUID().uuidString)", isDirectory: true)
        defer {
            ImageMemoryCache.shared.removeAllImages()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let imageURL = try storage.directoryURL(for: .imports).appendingPathComponent("transient.png")

        let attachment = Attachment(
            kind: .image,
            displayName: "Transient",
            originalFileName: "transient.png",
            storedFileName: try storage.relativePath(for: imageURL),
            contentTypeIdentifier: UTType.png.identifier,
            fileExtension: "png",
            width: 320,
            height: 220
        )
        let imageContainer = DrawingCanvasView.AttachmentImageContainerView()
        defer {
            imageContainer.releaseImage(evictCachedVariants: true)
        }

        imageContainer.updateRasterScale(2)
        imageContainer.configure(
            attachment: attachment,
            storage: storage,
            pageSize: CGSize(width: 612, height: 792),
            changed: {}
        )
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(!imageContainer.isRasterImageLoaded)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48))
        let sourceImage = renderer.image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        }
        try #require(sourceImage.pngData()).write(to: imageURL, options: [.atomic])
        #expect(ImageMemoryCache.shared.image(at: imageURL, maxPixelSize: 1_024) != nil)

        imageContainer.configure(
            attachment: attachment,
            storage: storage,
            pageSize: CGSize(width: 612, height: 792),
            changed: {}
        )
        try await waitForRasterImage(in: imageContainer)
    }

    @Test @MainActor func attachmentImageReleaseKeepsDecodedCacheUnlessEvicting() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesAttachmentImageCache-\(UUID().uuidString)", isDirectory: true)
        defer {
            ImageMemoryCache.shared.removeAllImages()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96))
        let sourceImage = renderer.image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
        }
        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let storedImage = try storage.saveData(
            try #require(sourceImage.jpegData(compressionQuality: 0.9)),
            preferredName: "pdf-page.jpg",
            contentType: .jpeg,
            to: .imports
        )
        let imageURL = storage.url(forRelativePath: storedImage.relativePath)
        let attachment = Attachment(
            kind: .image,
            displayName: "PDF Page",
            originalFileName: "pdf-page.jpg",
            storedFileName: storedImage.relativePath,
            contentTypeIdentifier: UTType.jpeg.identifier,
            fileExtension: "jpg",
            width: 320,
            height: 220,
            isLocked: true,
            rendersBehindDrawing: true
        )
        let page = NotePage(pageOrder: 0, width: 612, height: 792)
        page.attachments.append(attachment)

        ImageMemoryCache.shared.removeAllImages()

        let imageContainer = DrawingCanvasView.AttachmentImageContainerView()
        imageContainer.configure(
            attachment: attachment,
            storage: storage,
            pageSize: page.pageSize,
            changed: {}
        )
        imageContainer.updateRasterScale(2)
        try await waitForRasterImage(in: imageContainer)
        try await waitForCachedImageVariant(for: imageURL)
        let retainedVariantCount = ImageMemoryCache.shared.cachedVariantCount(for: imageURL)

        imageContainer.releaseImage()

        #expect(retainedVariantCount > 0)
        #expect(ImageMemoryCache.shared.cachedVariantCount(for: imageURL) == retainedVariantCount)
        #expect(!imageContainer.isRasterImageLoaded)

        imageContainer.releaseImage(evictCachedVariants: true)

        #expect(ImageMemoryCache.shared.cachedVariantCount(for: imageURL) == 0)
    }

    @Test @MainActor func attachmentImageEvictionPreventsCanceledDecodeFromRefillingCache() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesAttachmentImageEvictPending-\(UUID().uuidString)", isDirectory: true)
        defer {
            ImageMemoryCache.shared.removeAllImages()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1_800, height: 1_800))
        let sourceImage = renderer.image { context in
            UIColor.systemCyan.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_800, height: 1_800))
        }
        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let storedImage = try storage.saveData(
            try #require(sourceImage.jpegData(compressionQuality: 0.88)),
            preferredName: "large-page.jpg",
            contentType: .jpeg,
            to: .imports
        )
        let imageURL = storage.url(forRelativePath: storedImage.relativePath)
        let attachment = Attachment(
            kind: .image,
            displayName: "Large Page",
            originalFileName: "large-page.jpg",
            storedFileName: storedImage.relativePath,
            contentTypeIdentifier: UTType.jpeg.identifier,
            fileExtension: "jpg",
            width: 1_024,
            height: 768,
            isLocked: true,
            rendersBehindDrawing: true
        )
        let imageContainer = DrawingCanvasView.AttachmentImageContainerView()

        ImageMemoryCache.shared.removeAllImages()
        imageContainer.updateRasterScale(6)
        imageContainer.configure(
            attachment: attachment,
            storage: storage,
            pageSize: CGSize(width: 1_024, height: 768),
            changed: {}
        )
        imageContainer.releaseImage(evictCachedVariants: true)

        try await assertNoCachedImageVariant(for: imageURL)
        #expect(!imageContainer.isRasterImageLoaded)
    }

    @Test func canvasUnloadFlushesPendingDrawingSaveSynchronously() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesCanvasUnload-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let page = NotePage(pageOrder: 0, drawingFileName: "pending-unload.drawing")
        let drawing = makeTestDrawing(color: .systemPurple, xOffset: 24)
        let parent = makeDrawingCanvasView(page: page, drawingStorage: drawingStorage)
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let canvasView = PKCanvasView()
        canvasView.drawing = drawing

        coordinator.register(canvasView: canvasView, page: page)
        coordinator.canvasViewDrawingDidChange(canvasView)
        #expect(coordinator.pendingSaves[page.id] != nil)

        coordinator.unregister(canvasView: canvasView, page: page)

        let savedData = try Data(contentsOf: drawingStorage.drawingURL(for: page))
        let savedDrawing = try PKDrawing(data: savedData)
        #expect(savedDrawing.strokes.count == drawing.strokes.count)
        #expect(coordinator.pendingSaves[page.id] == nil)
        #expect(!coordinator.dirtyPageIDs.contains(page.id))
    }

    @Test func exportPreparationFlushesLiveCanvasBeforeCompleting() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesExportPreparation-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let page = NotePage(pageOrder: 0, drawingFileName: "live-export.drawing")
        let drawing = makeTestDrawing(color: .systemRed, xOffset: 36)
        var completionContinuation: CheckedContinuation<Int, Never>?
        var completionResult: Result<Void, Error>?
        let parent = makeDrawingCanvasView(
            page: page,
            drawingStorage: drawingStorage,
            exportPreparationCompleted: { requestID, result in
                completionResult = result
                completionContinuation?.resume(returning: requestID)
                completionContinuation = nil
            }
        )
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let container = DrawingCanvasView.CanvasContainerView(
            frame: CGRect(x: 0, y: 0, width: 700, height: 900)
        )
        coordinator.containerView = container
        container.configure(
            pages: [page],
            selectedPageID: page.id,
            pageFlowMode: .continuous,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: coordinator
        )

        let canvasView = try #require(container.activeCanvasView)
        canvasView.drawing = drawing
        coordinator.canvasViewDrawingDidChange(canvasView)
        let completedRequestID: Int = await withCheckedContinuation { continuation in
            completionContinuation = continuation
            coordinator.prepareForExport(requestID: 42)
        }

        let savedData = try Data(contentsOf: drawingStorage.drawingURL(for: page))
        let savedDrawing = try PKDrawing(data: savedData)
        #expect(savedDrawing.strokes.count == drawing.strokes.count)
        #expect(abs(savedDrawing.bounds.midX - drawing.bounds.midX) < 0.5)
        #expect(completedRequestID == 42)
        let completedResult = try #require(completionResult)
        try completedResult.get()
        #expect(coordinator.pendingSaves[page.id] == nil)
        #expect(!coordinator.dirtyPageIDs.contains(page.id))
    }

    @Test func exportPreparationSnapshotsCanvasBeforeChangeCallbackArrives() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesImmediateExport-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let page = NotePage(pageOrder: 0, drawingFileName: "immediate-export.drawing")
        let drawing = makeTestDrawing(color: .systemRed, xOffset: 44)
        var completionContinuation: CheckedContinuation<Result<Void, Error>, Never>?
        let parent = makeDrawingCanvasView(
            page: page,
            drawingStorage: drawingStorage,
            exportPreparationCompleted: { _, result in
                completionContinuation?.resume(returning: result)
                completionContinuation = nil
            }
        )
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let container = DrawingCanvasView.CanvasContainerView(
            frame: CGRect(x: 0, y: 0, width: 700, height: 900)
        )
        coordinator.containerView = container
        container.configure(
            pages: [page],
            selectedPageID: page.id,
            pageFlowMode: .continuous,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: coordinator
        )

        let canvasView = try #require(container.activeCanvasView)
        canvasView.drawing = drawing
        coordinator.pendingSaves[page.id]?.cancel()
        coordinator.pendingSaves[page.id] = nil
        coordinator.pendingSaveTokens[page.id] = nil
        coordinator.dirtyPageIDs.remove(page.id)

        let completionResult = await withCheckedContinuation { continuation in
            completionContinuation = continuation
            coordinator.prepareForExport(requestID: 91)
        }
        try completionResult.get()

        let savedData = try Data(contentsOf: drawingStorage.drawingURL(for: page))
        let savedDrawing = try PKDrawing(data: savedData)
        #expect(savedDrawing.strokes.count == drawing.strokes.count)
        #expect(abs(savedDrawing.bounds.midX - drawing.bounds.midX) < 0.5)
    }

    @Test func exportPreparationWaitsForLivePencilStrokeToEnd() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesActiveStrokeExport-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let page = NotePage(pageOrder: 0, drawingFileName: "active-stroke-export.drawing")
        let drawing = makeTestDrawing(color: .systemBlue, xOffset: 52)
        var didComplete = false
        var completionContinuation: CheckedContinuation<Int, Never>?
        var completionResult: Result<Void, Error>?
        let parent = makeDrawingCanvasView(
            page: page,
            drawingStorage: drawingStorage,
            exportPreparationCompleted: { requestID, result in
                didComplete = true
                completionResult = result
                completionContinuation?.resume(returning: requestID)
                completionContinuation = nil
            }
        )
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let container = DrawingCanvasView.CanvasContainerView(
            frame: CGRect(x: 0, y: 0, width: 700, height: 900)
        )
        coordinator.containerView = container
        container.configure(
            pages: [page],
            selectedPageID: page.id,
            pageFlowMode: .continuous,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: coordinator
        )

        let canvasView = try #require(container.activeCanvasView)
        canvasView.drawing = drawing
        coordinator.canvasViewDidBeginUsingTool(canvasView)
        #expect(container.isLiveDrawingInteractionActive)
        coordinator.canvasViewDrawingDidChange(canvasView)
        coordinator.prepareForExport(requestID: 77)

        #expect(!didComplete)
        let drawingURL = try drawingStorage.drawingURL(for: page)
        #expect(!FileManager.default.fileExists(atPath: drawingURL.path))

        let completedRequestID: Int = await withCheckedContinuation { continuation in
            completionContinuation = continuation
            coordinator.canvasViewDidEndUsingTool(canvasView)
        }

        #expect(!container.isLiveDrawingInteractionActive)
        #expect(completedRequestID == 77)
        let completedResult = try #require(completionResult)
        try completedResult.get()
        let savedData = try Data(contentsOf: drawingURL)
        let savedDrawing = try PKDrawing(data: savedData)
        #expect(savedDrawing.strokes.count == drawing.strokes.count)
        #expect(abs(savedDrawing.bounds.midX - drawing.bounds.midX) < 0.5)
        #expect(coordinator.pendingSaves[page.id] == nil)
        #expect(!coordinator.dirtyPageIDs.contains(page.id))
    }

    @Test func livePencilStrokeDefersAutosaveWorkUntilPencilLifts() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesLiveStroke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let page = NotePage(pageOrder: 0, drawingFileName: "live-stroke.drawing")
        let parent = makeDrawingCanvasView(page: page, drawingStorage: drawingStorage)
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let canvasView = PKCanvasView()
        canvasView.drawing = makeTestDrawing(color: .systemBlue, xOffset: 0)

        coordinator.register(canvasView: canvasView, page: page)
        coordinator.canvasViewDidBeginUsingTool(canvasView)
        coordinator.canvasViewDrawingDidChange(canvasView)

        #expect(coordinator.dirtyPageIDs.contains(page.id))
        #expect(coordinator.pendingSaves[page.id] == nil)

        coordinator.canvasViewDidEndUsingTool(canvasView)

        #expect(coordinator.pendingSaves[page.id] != nil)
        coordinator.unregister(canvasView: canvasView, page: page)
    }

    @Test func canvasUnloadFlushesCurrentDrawingWhileAsyncSaveIsInFlight() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesCanvasInFlightUnload-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let page = NotePage(pageOrder: 0, drawingFileName: "in-flight-unload.drawing")
        let firstDrawing = makeTestDrawing(color: .systemRed, xOffset: 0)
        let latestDrawing = makeTestDrawing(color: .systemBlue, xOffset: 48)
        let parent = makeDrawingCanvasView(page: page, drawingStorage: drawingStorage)
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let container = DrawingCanvasView.CanvasContainerView(
            frame: CGRect(x: 0, y: 0, width: 700, height: 900)
        )
        coordinator.containerView = container
        container.configure(
            pages: [page],
            selectedPageID: page.id,
            pageFlowMode: .continuous,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: coordinator
        )
        let canvasView = try #require(container.activeCanvasView)

        canvasView.drawing = firstDrawing
        coordinator.canvasViewDrawingDidChange(canvasView)
        coordinator.saveAllCanvases(synchronously: false)

        #expect(coordinator.pendingSaves[page.id] == nil)
        #expect(coordinator.dirtyPageIDs.contains(page.id))
        #expect(coordinator.inFlightSaveTokens[page.id]?.isEmpty == false)

        canvasView.drawing = latestDrawing
        coordinator.canvasViewDrawingDidChange(canvasView)
        coordinator.unregister(canvasView: canvasView, page: page)
        try await Task.sleep(nanoseconds: 20_000_000)

        let savedData = try Data(contentsOf: drawingStorage.drawingURL(for: page))
        let savedDrawing = try PKDrawing(data: savedData)
        #expect(savedDrawing.strokes.count == latestDrawing.strokes.count)
        #expect(abs(savedDrawing.bounds.midX - latestDrawing.bounds.midX) < 0.5)
        #expect(abs(savedDrawing.bounds.midY - latestDrawing.bounds.midY) < 0.5)
        #expect(abs(savedDrawing.bounds.midX - firstDrawing.bounds.midX) > 20)
        #expect(coordinator.pendingSaves[page.id] == nil)
        #expect(coordinator.inFlightSaveTokens[page.id] == nil)
        #expect(!coordinator.dirtyPageIDs.contains(page.id))
    }

    @Test @MainActor func canvasDismantleReleasesMaterializedPagesAfterFinalFlush() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesCanvasDismantle-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let page = NotePage(pageOrder: 0, drawingFileName: "dismantle-flush.drawing")
        let drawing = makeTestDrawing(color: .systemTeal, xOffset: 36)
        let parent = makeDrawingCanvasView(page: page, drawingStorage: drawingStorage)
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let container = DrawingCanvasView.CanvasContainerView(
            frame: CGRect(x: 0, y: 0, width: 700, height: 900)
        )

        coordinator.containerView = container
        container.configure(
            pages: [page],
            selectedPageID: page.id,
            pageFlowMode: .continuous,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: coordinator
        )

        let canvasView = try #require(container.activeCanvasView)
        canvasView.drawing = drawing
        coordinator.canvasViewDrawingDidChange(canvasView)

        #expect(!container.canvasPagePairs.isEmpty)
        #expect(!coordinator.registeredCanvasIDs.isEmpty)
        #expect(coordinator.pendingSaves[page.id] != nil)

        DrawingCanvasView.dismantleUIView(container, coordinator: coordinator)

        #expect(container.canvasPagePairs.isEmpty)
        #expect(coordinator.registeredCanvasIDs.isEmpty)
        #expect(coordinator.pendingSaves[page.id] == nil)
        #expect(coordinator.containerView == nil)

        let deadline = ContinuousClock.now + .seconds(5)
        var savedDrawing: PKDrawing?

        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: drawingStorage.drawingURL(for: page)),
               let loaded = try? PKDrawing(data: data),
               loaded.strokes.count == drawing.strokes.count {
                savedDrawing = loaded
                break
            }

            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let finalDrawing = try #require(savedDrawing)
        #expect(abs(finalDrawing.bounds.midX - drawing.bounds.midX) < 0.5)
        #expect(abs(finalDrawing.bounds.midY - drawing.bounds.midY) < 0.5)
    }

    @Test @MainActor func canvasViewportRestoresReadingAnchorAfterCanvasRecreation() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesViewportRestore-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let pages = [
            NotePage(pageOrder: 0, drawingFileName: "viewport-first.drawing", width: 612, height: 1_000),
            NotePage(pageOrder: 1, drawingFileName: "viewport-second.drawing", width: 612, height: 1_000)
        ]
        let parent = makeDrawingCanvasView(
            page: pages[0],
            drawingStorage: drawingStorage,
            pages: pages
        )
        let originalCoordinator = DrawingCanvasView.Coordinator(parent: parent)
        let original = DrawingCanvasView.CanvasContainerView(
            frame: CGRect(x: 0, y: 0, width: 700, height: 900)
        )
        originalCoordinator.containerView = original
        original.configure(
            pages: pages,
            selectedPageID: pages[0].id,
            pageFlowMode: .continuous,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: originalCoordinator
        )
        original.setNeedsLayout()
        original.layoutIfNeeded()
        original.scrollView.setZoomScale(1.4, animated: false)
        original.scrollView.setContentOffset(CGPoint(x: 0, y: 1_200), animated: false)

        let expectedViewport = try #require(original.currentViewport())
        #expect(expectedViewport.center.y > pages[1].pageSize.height)
        #expect(abs(expectedViewport.zoomScale - 1.4) < 0.01)

        let restoredCoordinator = DrawingCanvasView.Coordinator(parent: parent)
        let restored = DrawingCanvasView.CanvasContainerView(
            frame: CGRect(x: 0, y: 0, width: 700, height: 900)
        )
        restoredCoordinator.containerView = restored
        restored.configure(
            pages: pages,
            selectedPageID: pages[0].id,
            pageFlowMode: .continuous,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: restoredCoordinator
        )
        restored.restoreViewport(expectedViewport)
        restored.setNeedsLayout()
        restored.layoutIfNeeded()

        let actualViewport = try #require(restored.currentViewport())
        #expect(abs(actualViewport.zoomScale - expectedViewport.zoomScale) < 0.01)
        #expect(abs(actualViewport.center.x - expectedViewport.center.x) < 1)
        #expect(abs(actualViewport.center.y - expectedViewport.center.y) < 1)

        DrawingCanvasView.dismantleUIView(original, coordinator: originalCoordinator)
        DrawingCanvasView.dismantleUIView(restored, coordinator: restoredCoordinator)
    }

    @Test @MainActor func staleSelectionUpdateDoesNotInterruptScrollingToNextPage() {
        let firstPage = NotePage(pageOrder: 0)
        let secondPage = NotePage(pageOrder: 1)
        let parent = makeDrawingCanvasView(
            page: firstPage,
            drawingStorage: DrawingStorageService(),
            pages: [firstPage, secondPage]
        )
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)

        coordinator.selectVisiblePage(secondPage.id)

        let staleUpdate = coordinator.reconcileSelectedPageID(firstPage.id)
        #expect(staleUpdate.effectivePageID == secondPage.id)
        #expect(!staleUpdate.shouldScroll)
        #expect(coordinator.pendingVisiblePageID == secondPage.id)

        let publishedUpdate = coordinator.reconcileSelectedPageID(secondPage.id)
        #expect(publishedUpdate.effectivePageID == secondPage.id)
        #expect(!publishedUpdate.shouldScroll)
        #expect(coordinator.pendingVisiblePageID == nil)

        let externalUpdate = coordinator.reconcileSelectedPageID(firstPage.id)
        #expect(externalUpdate.effectivePageID == firstPage.id)
        #expect(externalUpdate.shouldScroll)
    }

    @Test @MainActor func selectingCurrentPageDoesNotLeavePendingSelection() {
        let firstPage = NotePage(pageOrder: 0)
        let secondPage = NotePage(pageOrder: 1)
        let parent = makeDrawingCanvasView(
            page: firstPage,
            drawingStorage: DrawingStorageService(),
            pages: [firstPage, secondPage]
        )
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)

        coordinator.selectVisiblePage(firstPage.id)

        #expect(coordinator.pendingVisiblePageID == nil)
        let externalUpdate = coordinator.reconcileSelectedPageID(secondPage.id)
        #expect(externalUpdate.effectivePageID == secondPage.id)
        #expect(externalUpdate.shouldScroll)

        // A relayout can leave UIKit's cached selection behind the live SwiftUI
        // binding. Re-observing the already-published page must not enqueue a stale
        // binding write that can overwrite a subsequent undo selection.
        coordinator.selectVisiblePage(firstPage.id)
        #expect(coordinator.pendingVisiblePageID == nil)

        let nextExternalUpdate = coordinator.reconcileSelectedPageID(secondPage.id)
        #expect(nextExternalUpdate.effectivePageID == secondPage.id)
        #expect(nextExternalUpdate.shouldScroll)
    }

    @Test @MainActor func programmaticSelectionCancelsQueuedVisiblePagePublication() {
        let firstPage = NotePage(pageOrder: 0)
        let secondPage = NotePage(pageOrder: 1)
        var selectionRevision: UInt64 = 0
        let parent = makeDrawingCanvasView(
            page: firstPage,
            drawingStorage: DrawingStorageService(),
            pages: [firstPage, secondPage],
            selectionRevision: { selectionRevision }
        )
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)

        coordinator.selectVisiblePage(secondPage.id)
        #expect(coordinator.pendingVisiblePageID == secondPage.id)

        selectionRevision &+= 1
        let programmaticUpdate = coordinator.reconcileSelectedPageID(firstPage.id)

        #expect(coordinator.pendingVisiblePageID == nil)
        #expect(programmaticUpdate.effectivePageID == firstPage.id)
        #expect(programmaticUpdate.shouldScroll)
    }

    @Test @MainActor func canvasDismantlePublishesFinalReadingState() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesFinalViewport-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let pages = [
            NotePage(pageOrder: 0, drawingFileName: "final-viewport-first.drawing", width: 612, height: 1_000),
            NotePage(pageOrder: 1, drawingFileName: "final-viewport-second.drawing", width: 612, height: 1_000)
        ]
        let session = NoteEditorSession()
        let parent = makeDrawingCanvasView(
            page: pages[0],
            drawingStorage: drawingStorage,
            pages: pages,
            finalViewportChanged: { viewport, selectedPageID in
                session.recordFinalCanvasState(
                    viewport: viewport,
                    selectedPageID: selectedPageID
                )
            }
        )
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let container = DrawingCanvasView.CanvasContainerView(
            frame: CGRect(x: 0, y: 0, width: 700, height: 900)
        )
        coordinator.containerView = container
        container.configure(
            pages: pages,
            selectedPageID: pages[0].id,
            pageFlowMode: .continuous,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: coordinator
        )
        container.setNeedsLayout()
        container.layoutIfNeeded()
        container.scrollView.setZoomScale(1.4, animated: false)
        container.scrollView.setContentOffset(CGPoint(x: 0, y: 1_200), animated: false)
        let expectedViewport = try #require(container.currentViewport())

        DrawingCanvasView.dismantleUIView(container, coordinator: coordinator)

        let deadline = ContinuousClock.now + .seconds(1)
        while session.viewportRestorationID == 0 && ContinuousClock.now < deadline {
            await Task.yield()
        }

        #expect(session.viewportRestorationID == 1)
        #expect(session.selectedPageID == pages[1].id)
        let finalViewport = try #require(session.viewport)
        #expect(abs(finalViewport.zoomScale - expectedViewport.zoomScale) < 0.01)
        #expect(abs(finalViewport.center.y - expectedViewport.center.y) < 1)
    }

    @Test func programmaticPageSelectionRejectsStaleCanvasUpdatesUntilUserNavigation() {
        let firstPageID = UUID()
        let secondPageID = UUID()
        let session = NoteEditorSession(selectedPageID: firstPageID)

        session.selectPageProgrammatically(secondPageID)
        session.applyCanvasSelection(firstPageID)

        #expect(session.selectedPageID == secondPageID)
        #expect(session.isProgrammaticSelectionProtected)

        session.beginUserPageSelection()
        session.applyCanvasSelection(firstPageID)

        #expect(session.selectedPageID == firstPageID)
        #expect(!session.isProgrammaticSelectionProtected)
    }

    @Test func noteEditorSessionStoreKeepsTabStateIsolated() {
        let store = NoteEditorSessionStore()
        let firstNoteID = UUID()
        let secondNoteID = UUID()
        let firstSession = store.session(for: firstNoteID)
        let finalPageID = UUID()
        firstSession.selectedPageID = UUID()
        firstSession.currentZoomScale = 1.8
        firstSession.viewport = DrawingCanvasViewport(
            center: CGPoint(x: 320, y: 1_400),
            zoomScale: 1.8
        )
        firstSession.recordFinalCanvasState(
            viewport: DrawingCanvasViewport(center: CGPoint(x: 360, y: 1_620), zoomScale: 2),
            selectedPageID: finalPageID
        )

        let secondSession = store.session(for: secondNoteID)

        #expect(store.session(for: firstNoteID) === firstSession)
        #expect(secondSession !== firstSession)
        #expect(secondSession.selectedPageID == nil)
        #expect(secondSession.currentZoomScale == 1)
        #expect(secondSession.viewport == nil)
        #expect(firstSession.selectedPageID == finalPageID)
        #expect(firstSession.currentZoomScale == 2)
        #expect(firstSession.viewport?.center == CGPoint(x: 360, y: 1_620))
        #expect(firstSession.viewportRestorationID == 1)
    }

    @Test @MainActor func restoringScrollableCanvasNearFooterDoesNotAddAPage() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesViewportFooter-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let page = NotePage(pageOrder: 0, drawingFileName: "viewport-footer.drawing", width: 612, height: 1_000)
        let parent = makeDrawingCanvasView(page: page, drawingStorage: drawingStorage)
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let container = DrawingCanvasView.CanvasContainerView(
            frame: CGRect(x: 0, y: 0, width: 700, height: 900)
        )
        coordinator.containerView = container
        container.configure(
            pages: [page],
            selectedPageID: page.id,
            pageFlowMode: .seamless,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: coordinator
        )
        container.setNeedsLayout()
        container.layoutIfNeeded()

        var addPageRequestCount = 0
        container.addPageRequested = {
            addPageRequestCount += 1
        }
        container.restoreViewport(
            DrawingCanvasViewport(center: CGPoint(x: 306, y: 960), zoomScale: 1.4)
        )
        container.setNeedsLayout()
        container.layoutIfNeeded()

        #expect(addPageRequestCount == 0)
        DrawingCanvasView.dismantleUIView(container, coordinator: coordinator)
    }

    @Test @MainActor func scrollingNeverAddsPageAndFooterTapAddsOnce() {
        let drawingStorage = DrawingStorageService()
        let page = NotePage(pageOrder: 0, width: 612, height: 792)
        let parent = makeDrawingCanvasView(page: page, drawingStorage: drawingStorage)
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let container = DrawingCanvasView.CanvasContainerView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        var addPageRequestCount = 0
        container.addPageRequested = {
            addPageRequestCount += 1
        }
        coordinator.containerView = container

        container.configure(
            pages: [page],
            selectedPageID: page.id,
            pageFlowMode: .seamless,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: coordinator
        )
        container.setNeedsLayout()
        container.layoutIfNeeded()

        #expect(addPageRequestCount == 0)

        container.scrollViewWillBeginDragging(container.scrollView)
        container.scrollView.setContentOffset(
            CGPoint(
                x: container.scrollView.contentOffset.x,
                y: container.scrollView.contentOffset.y + 1
            ),
            animated: false
        )

        #expect(addPageRequestCount == 0)

        container.addPageFooterButton.sendActions(for: .touchUpInside)
        #expect(addPageRequestCount == 1)
        DrawingCanvasView.dismantleUIView(container, coordinator: coordinator)
    }

    @Test @MainActor func documentTraversalStaysActiveThroughDecelerationAndZoom() {
        let container = DrawingCanvasView.CanvasContainerView()

        #expect(!container.scrollView.alwaysBounceHorizontal)
        #expect(container.scrollView.alwaysBounceVertical)
        #expect(container.scrollView.isDirectionalLockEnabled)
        #expect(!container.isDocumentTraversalActive)
        #expect(!container.isLiveDrawingInteractionActive)

        container.scrollViewWillBeginDragging(container.scrollView)
        #expect(container.isDocumentTraversalActive)

        container.scrollViewDidEndDragging(container.scrollView, willDecelerate: true)
        #expect(container.isDocumentTraversalActive)

        container.scrollViewDidEndDecelerating(container.scrollView)
        #expect(!container.isDocumentTraversalActive)

        container.scrollViewWillBeginZooming(container.scrollView, with: nil)
        #expect(container.isDocumentTraversalActive)

        container.scrollViewDidEndZooming(container.scrollView, with: nil, atScale: 1)
        #expect(!container.isDocumentTraversalActive)

        container.scrollViewWillBeginDragging(container.scrollView)
        container.cancelPendingRenderingWork()
        #expect(!container.isDocumentTraversalActive)

        container.setDrawingInteractionActive(true)
        #expect(container.isLiveDrawingInteractionActive)
        container.setDrawingInteractionActive(false)
        #expect(!container.isLiveDrawingInteractionActive)
    }

    private struct PageCanvasFixture {
        let rootURL: URL
        let storage: LocalStorageService
        let drawingStorage: DrawingStorageService
        let coordinator: DrawingCanvasView.Coordinator
        let pageView: DrawingCanvasView.PageCanvasView

        @MainActor func cleanup() {
            pageView.releaseHeavyResources()
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    private func makePageCanvasFixture(name: String) throws -> PageCanvasFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotes\(name)-\(UUID().uuidString)", isDirectory: true)
        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let page = NotePage(pageOrder: 0, drawingFileName: "\(name).drawing", width: 612, height: 792)
        let parent = makeDrawingCanvasView(page: page, drawingStorage: drawingStorage)
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let pageView = DrawingCanvasView.PageCanvasView()
        pageView.configure(
            page: page,
            storage: storage,
            drawingStorage: drawingStorage,
            inputMode: .pencilOnly,
            coordinator: coordinator,
            attachmentChanged: {},
            deleteAttachment: { _ in }
        )
        return PageCanvasFixture(
            rootURL: rootURL,
            storage: storage,
            drawingStorage: drawingStorage,
            coordinator: coordinator,
            pageView: pageView
        )
    }

    private func makeDrawingCanvasView(
        page: NotePage,
        drawingStorage: DrawingStorageService,
        pages: [NotePage]? = nil,
        finalViewportChanged: @escaping (DrawingCanvasViewport, UUID?) -> Void = { _, _ in },
        selectionRevision: @escaping () -> UInt64 = { 0 },
        exportPreparationCompleted: @escaping (Int, Result<Void, Error>) -> Void = { _, _ in }
    ) -> DrawingCanvasView {
        let defaults = UserDefaults(suiteName: "BeanNotesCanvasTest-\(UUID().uuidString)")!
        return DrawingCanvasView(
            pages: pages ?? [page],
            selectedPageID: .constant(page.id),
            toolState: DrawingToolState(defaults: defaults),
            paletteMode: .custom,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            strokeZoomBehavior: .pageWidth,
            pageFlowMode: .continuous,
            doubleTapAction: .switchToEraser,
            saveNowSignal: 0,
            fitToPageSignal: 0,
            zoomInSignal: 0,
            zoomOutSignal: 0,
            zoomToScaleSignal: 0,
            zoomTargetScale: 1,
            undoSignal: 0,
            redoSignal: 0,
            toolShortcutSignal: 0,
            drawingStorage: drawingStorage,
            attachmentChanged: {},
            deleteAttachment: { _ in },
            drawingChanged: { _ in },
            saveStarted: {},
            saveSucceeded: {},
            saveFailed: { _ in },
            exportPreparationCompleted: exportPreparationCompleted,
            undoRedoAvailabilityChanged: { _, _ in },
            zoomScaleChanged: { _ in },
            finalViewportChanged: finalViewportChanged,
            selectionRevision: selectionRevision,
            addPageRequested: {},
            topContent: nil
        )
    }

    private func writeMinimalPDF(
        to url: URL,
        mediaBox: CGRect,
        rotationAngle: Int
    ) throws {
        let stream = "BT /F1 24 Tf 72 720 Td (Rotated Page) Tj ET\n"
        let mediaBoxText = [
            mediaBox.minX,
            mediaBox.minY,
            mediaBox.maxX,
            mediaBox.maxY
        ]
            .map { String(format: "%.0f", $0) }
            .joined(separator: " ")
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            """
            << /Type /Page /Parent 2 0 R /MediaBox [\(mediaBoxText)] /Rotate \(rotationAngle) /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>
            """,
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            """
            << /Length \(stream.utf8.count) >>
            stream
            \(stream)endstream
            """
        ]

        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []

        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }

        let xrefOffset = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n"
        pdf += "0000000000 65535 f \n"

        for offset in offsets {
            pdf += String(format: "%010d 00000 n \n", offset)
        }

        pdf += """
        trailer
        << /Size \(objects.count + 1) /Root 1 0 R >>
        startxref
        \(xrefOffset)
        %%EOF
        """

        try Data(pdf.utf8).write(to: url, options: [.atomic])
    }

    @MainActor private func waitForRasterImage(
        in imageContainer: DrawingCanvasView.AttachmentImageContainerView,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async throws {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))

        while ContinuousClock.now < deadline {
            if imageContainer.isRasterImageLoaded {
                return
            }

            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(imageContainer.isRasterImageLoaded)
    }

    private func waitForCachedImageVariant(
        for imageURL: URL,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async throws {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))

        while ContinuousClock.now < deadline {
            if ImageMemoryCache.shared.cachedVariantCount(for: imageURL) > 0 {
                return
            }

            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(ImageMemoryCache.shared.cachedVariantCount(for: imageURL) > 0)
    }

    private func assertNoCachedImageVariant(
        for imageURL: URL,
        settlingNanoseconds: UInt64 = 1_000_000_000
    ) async throws {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(settlingNanoseconds))
        var observedVariantCount = ImageMemoryCache.shared.cachedVariantCount(for: imageURL)

        while observedVariantCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            observedVariantCount = ImageMemoryCache.shared.cachedVariantCount(for: imageURL)
        }

        #expect(observedVariantCount == 0)
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

    @Test @MainActor func temporaryEraserRestoresOnlyAfterAnEraserStrokeEnds() throws {
        let fixture = try makePageCanvasFixture(name: "TemporaryEraserLifecycle")
        defer { fixture.cleanup() }
        let toolState = fixture.coordinator.parent.toolState
        let canvasView = fixture.pageView.canvasView

        toolState.select(.pencil)
        fixture.coordinator.applyCustomToolIfNeeded()
        fixture.coordinator.canvasViewDidBeginUsingTool(canvasView)

        toolState.handleDoubleTap(action: .switchToEraser)
        fixture.coordinator.applyCustomToolIfNeeded()
        fixture.coordinator.canvasViewDidEndUsingTool(canvasView)

        #expect(toolState.selectedTool == .eraser)
        #expect(toolState.temporaryEraserActive)

        fixture.coordinator.canvasViewDidBeginUsingTool(canvasView)
        fixture.coordinator.canvasViewDidEndUsingTool(canvasView)

        #expect(toolState.selectedTool == .pencil)
        #expect(!toolState.temporaryEraserActive)
    }

    @Test @MainActor func pencilDoubleTapAppliesCustomToolAfterZoomSettles() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesDeferredDoubleTap-\(UUID().uuidString)", isDirectory: true)
        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let page = NotePage(pageOrder: 0, drawingFileName: "deferred-double-tap.drawing")
        let parent = makeDrawingCanvasView(page: page, drawingStorage: drawingStorage)
        let coordinator = DrawingCanvasView.Coordinator(parent: parent)
        let container = DrawingCanvasView.CanvasContainerView(
            frame: CGRect(x: 0, y: 0, width: 700, height: 900)
        )
        coordinator.containerView = container
        coordinator.configurePencilInteraction(on: container)

        defer {
            container.cancelPendingRenderingWork()
            container.releaseAllMaterializedPages()
            coordinator.removePencilInteraction()
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        container.configure(
            pages: [page],
            selectedPageID: page.id,
            pageFlowMode: .continuous,
            inputMode: .pencilOnly,
            renderQuality: .balanced,
            drawingStorage: drawingStorage,
            coordinator: coordinator
        )
        container.layoutIfNeeded()

        let canvasView = try #require(container.activeCanvasView)
        #expect(container.interactions.compactMap { $0 as? UIPencilInteraction }.count == 1)
        #expect(canvasView.interactions.compactMap { $0 as? UIPencilInteraction }.isEmpty)

        parent.toolState.select(.pencil)
        coordinator.applyCustomToolIfNeeded()
        #expect(canvasView.tool is PKInkingTool)

        container.zoomSelectedPage(by: 1.2, animated: true)
        #expect(container.isZoomTransitionActive)

        coordinator.handlePencilDoubleTap()
        #expect(parent.toolState.selectedTool == .eraser)

        let deadline = ContinuousClock.now + .seconds(2)
        while container.isZoomTransitionActive, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(!container.isZoomTransitionActive)
        #expect(canvasView.tool is PKEraserTool)
    }

    @Test @MainActor func pixelEraserSizeClampsPersistsAndUpdatesThePencilKitTool() throws {
        let suiteName = "BeanNotesEraserWidth-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let firstSession = DrawingToolState(defaults: defaults)
        firstSession.select(.eraser)

        #expect(firstSession.eraserWidth == 16)
        #expect(firstSession.eraserWidthCalibration.minimumWidth == 4)
        #expect(
            firstSession.eraserWidthCalibration.maximumWidth
                == PKEraserTool.EraserType.fixedWidthBitmap.validWidthRange.upperBound
        )
        #expect(firstSession.eraserWidthPresets == [12, 16, 26, 42])
        for preset in firstSession.eraserWidthPresets {
            firstSession.applyEraserWidth(preset)
            #expect(firstSession.eraserWidth == preset)
        }

        let initialSignature = firstSession.pkToolSignature
        let firstSliderIncrement = firstSession.eraserWidthCalibration.minimumWidth
            + firstSession.eraserWidthCalibration.step
        firstSession.applyEraserWidth(firstSliderIncrement)
        #expect(firstSession.eraserWidth == firstSliderIncrement)

        firstSession.applyEraserWidth(firstSession.eraserWidthCalibration.maximumWidth)
        #expect(
            firstSession.eraserWidth
                == PKEraserTool.EraserType.fixedWidthBitmap.validWidthRange.upperBound
        )
        #expect(firstSession.pkToolSignature != initialSignature)

        let pixelEraser = try #require(firstSession.makePKTool() as? PKEraserTool)
        #expect(pixelEraser.eraserType == .fixedWidthBitmap)
        #expect(pixelEraser.width == firstSession.eraserWidth)

        let restoredSession = DrawingToolState(defaults: defaults)
        #expect(restoredSession.eraserWidth == firstSession.eraserWidth)

        restoredSession.applyEraserWidth(.infinity)
        #expect(restoredSession.eraserWidth == 4)

        restoredSession.selectEraserMode(.object)
        let objectEraser = try #require(restoredSession.makePKTool() as? PKEraserTool)
        #expect(objectEraser.eraserType == .vector)
        #expect(objectEraser.width == 0)

        let selectedWidth = restoredSession.eraserWidthCalibration.clamped(41)
        restoredSession.applyEraserWidth(41)
        #expect(restoredSession.eraserWidth == selectedWidth)
    }

    @Test @MainActor func rubEraserSettingsPersistWithoutChangingPixelOrObjectSettings() throws {
        let suiteName = "BeanNotesRubEraser-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstSession = DrawingToolState(defaults: defaults)
        #expect(firstSession.rubEraserSize == 16)
        #expect(firstSession.rubEraserSizePresets == [12, 16, 26, 42])
        for preset in firstSession.rubEraserSizePresets {
            firstSession.applyRubEraserSize(preset)
            #expect(firstSession.rubEraserSize == preset)
        }
        firstSession.applyEraserWidth(48)
        let pixelWidth = firstSession.eraserWidth
        firstSession.selectRubEraserShape(.wedge)
        firstSession.applyRubEraserSize(73)
        firstSession.applyRubEraserAngle(137.6)

        #expect(firstSession.eraserMode == .rub)
        #expect(firstSession.rubEraserShape == .wedge)
        #expect(firstSession.rubEraserSize == 74)
        #expect(firstSession.rubEraserAngle == 138)
        #expect(firstSession.eraserWidth == pixelWidth)
        #expect(DrawingRubEraserShape.allCases.count == 5)

        let rubTool = try #require(firstSession.makePKTool() as? PKEraserTool)
        #expect(rubTool.eraserType == .vector)

        let restoredSession = DrawingToolState(defaults: defaults)
        #expect(restoredSession.eraserMode == .rub)
        #expect(restoredSession.rubEraserShape == .wedge)
        #expect(restoredSession.rubEraserSize == 74)
        #expect(restoredSession.rubEraserAngle == 138)
        #expect(restoredSession.eraserWidth == pixelWidth)

        restoredSession.selectEraserMode(.object)
        #expect(restoredSession.eraserWidth == pixelWidth)
        restoredSession.selectEraserMode(.pixel)
        #expect(restoredSession.eraserWidth == pixelWidth)
    }

    @Test @MainActor func rubEraserGeometrySupportsEveryShapeAndRotation() {
        for shape in DrawingRubEraserShape.allCases {
            let path = DrawingCanvasView.RubEraserGeometry.shapePath(
                centeredAt: CGPoint(x: 100, y: 100),
                configuration: .init(shape: shape, size: 40, angle: 0)
            )
            #expect(!path.isEmpty)
            #expect(path.contains(CGPoint(x: 100, y: 100)))
        }

        let horizontal = DrawingCanvasView.RubEraserGeometry.shapePath(
            centeredAt: CGPoint(x: 100, y: 100),
            configuration: .init(shape: .rectangle, size: 40, angle: 0)
        )
        let vertical = DrawingCanvasView.RubEraserGeometry.shapePath(
            centeredAt: CGPoint(x: 100, y: 100),
            configuration: .init(shape: .rectangle, size: 40, angle: 90)
        )

        #expect(horizontal.contains(CGPoint(x: 118, y: 100)))
        #expect(!horizontal.contains(CGPoint(x: 100, y: 118)))
        #expect(!vertical.contains(CGPoint(x: 118, y: 100)))
        #expect(vertical.contains(CGPoint(x: 100, y: 118)))
    }

    @Test @MainActor func rubEraserRemovesOnlyTheCoveredPartOfAStroke() throws {
        let rubbedStroke = makeTestStroke(
            from: CGPoint(x: 20, y: 100),
            to: CGPoint(x: 180, y: 100),
            width: 4
        )
        let retainedStroke = makeTestStroke(
            from: CGPoint(x: 20, y: 160),
            to: CGPoint(x: 180, y: 160),
            width: 4
        )
        let result = try #require(
            DrawingCanvasView.PartialEraserStrokeProcessor.strokesByErasing(
                [rubbedStroke, retainedStroke],
                along: [CGPoint(x: 100, y: 100)],
                configuration: .init(shape: .rectangle, size: 32, angle: 0)
            )
        )

        #expect(result.count == 2)
        let updatedStroke = result[0]
        let updatedMask = try #require(updatedStroke.mask)
        #expect(!updatedMask.contains(CGPoint(x: 100, y: 100)))
        #expect(updatedMask.contains(CGPoint(x: 50, y: 100)))
        #expect(updatedMask.contains(CGPoint(x: 150, y: 100)))
        #expect(updatedStroke.path.count == rubbedStroke.path.count)
        #expect(updatedStroke.randomSeed == rubbedStroke.randomSeed)
        #expect(result[1].mask == nil)
        #expect(result[1].renderBounds == retainedStroke.renderBounds)
    }

    @Test @MainActor func rubEraserAtAStrokeEndKeepsTheUncoveredInk() throws {
        let stroke = makeTestStroke(
            from: CGPoint(x: 20, y: 100),
            to: CGPoint(x: 180, y: 100),
            width: 4
        )
        let result = try #require(
            DrawingCanvasView.PartialEraserStrokeProcessor.strokesByErasing(
                [stroke],
                along: [CGPoint(x: 20, y: 100)],
                configuration: .init(shape: .rectangle, size: 32, angle: 0)
            )
        )

        #expect(result.count == 1)
        let updatedMask = try #require(result[0].mask)
        #expect(!updatedMask.contains(CGPoint(x: 20, y: 100)))
        #expect(updatedMask.contains(CGPoint(x: 100, y: 100)))
        #expect(result[0].path.count == stroke.path.count)
        #expect(result[0].randomSeed == stroke.randomSeed)
    }

    @Test @MainActor func partialEraserRenderingSurvivesDrawingSerialization() throws {
        let stroke = makeTestStroke(
            from: CGPoint(x: 20, y: 100),
            to: CGPoint(x: 180, y: 100),
            width: 8,
            color: .red
        )
        let erasedStrokes = try #require(
            DrawingCanvasView.PartialEraserStrokeProcessor.strokesByErasing(
                [stroke],
                along: [CGPoint(x: 100, y: 100)],
                configuration: .init(shape: .rectangle, size: 32, angle: 0)
            )
        )
        let restoredDrawing = try PKDrawing(
            data: PKDrawing(strokes: erasedStrokes).dataRepresentation()
        )

        let erasedArea = restoredDrawing.image(
            from: CGRect(x: 96, y: 96, width: 8, height: 8),
            scale: 2
        )
        let retainedArea = restoredDrawing.image(
            from: CGRect(x: 46, y: 96, width: 8, height: 8),
            scale: 2
        )

        #expect(!imageContainsDominantRedInk(erasedArea))
        #expect(imageContainsDominantRedInk(retainedArea))
    }

    @Test @MainActor func partialEraserRemovesAStrokeWithNoRenderedInkLeft() throws {
        let stroke = makeTestStroke(
            from: CGPoint(x: 20, y: 100),
            to: CGPoint(x: 180, y: 100),
            width: 4
        )
        let result = try #require(
            DrawingCanvasView.PartialEraserStrokeProcessor.strokesByErasing(
                [stroke],
                along: [CGPoint(x: 100, y: 100)],
                diameter: 168
            )
        )

        #expect(result.isEmpty)
    }

    @Test @MainActor func circularEraserUsesTheSelectedBoundary() throws {
        let stroke = makeTestStroke(
            from: CGPoint(x: 20, y: 100),
            to: CGPoint(x: 180, y: 100),
            width: 4
        )
        let eraserLocation = CGPoint(x: 100, y: 114)

        let smallResult = DrawingCanvasView.PartialEraserStrokeProcessor.strokesByErasing(
            [stroke],
            along: [eraserLocation],
            diameter: 12
        )
        #expect(smallResult == nil)

        let largeResult = try #require(
            DrawingCanvasView.PartialEraserStrokeProcessor.strokesByErasing(
                [stroke],
                along: [eraserLocation],
                diameter: 26
            )
        )
        #expect(largeResult.count == 1)
        let largeMask = try #require(largeResult[0].mask)
        #expect(!largeMask.contains(CGPoint(x: 100, y: 102)))
        #expect(largeMask.contains(CGPoint(x: 100, y: 100)))
        #expect(largeResult[0].path.count == stroke.path.count)

        let boundaryResult = DrawingCanvasView.PartialEraserStrokeProcessor.strokesByErasing(
            [stroke],
            along: [CGPoint(x: 100, y: 108)],
            diameter: 12
        )
        #expect(boundaryResult != nil)
    }

    @Test @MainActor func circularEraserClipsOnlyTheRubbedPixelsOfAWideStroke() throws {
        let stroke = makeTestStroke(
            from: CGPoint(x: 20, y: 100),
            to: CGPoint(x: 180, y: 100),
            width: 40
        )
        let result = try #require(
            DrawingCanvasView.PartialEraserStrokeProcessor.strokesByErasing(
                [stroke],
                along: [CGPoint(x: 100, y: 86)],
                diameter: 12
            )
        )

        #expect(result.count == 1)
        let updatedStroke = result[0]
        let updatedMask = try #require(updatedStroke.mask)
        #expect(!updatedMask.contains(CGPoint(x: 100, y: 86)))
        #expect(updatedMask.contains(CGPoint(x: 100, y: 100)))
        #expect(updatedStroke.path.count == stroke.path.count)
        #expect(updatedStroke.randomSeed == stroke.randomSeed)
    }

    @Test @MainActor func partialEraserPreservesExistingMasksAndStrokeTransforms() throws {
        let baseStroke = makeTestStroke(
            from: CGPoint(x: 20, y: 100),
            to: CGPoint(x: 180, y: 100),
            width: 12
        )
        let existingMask = UIBezierPath(rect: CGRect(x: 10, y: 85, width: 180, height: 30))
        existingMask.append(UIBezierPath(rect: CGRect(x: 90, y: 85, width: 20, height: 30)))
        existingMask.usesEvenOddFillRule = true
        var maskedStroke = baseStroke
        maskedStroke.mask = existingMask

        let maskedResult = try #require(
            DrawingCanvasView.PartialEraserStrokeProcessor.strokesByErasing(
                [maskedStroke],
                along: [CGPoint(x: 50, y: 100)],
                diameter: 12
            )
        )
        let updatedMaskedStroke = try #require(maskedResult.first)
        let updatedMask = try #require(updatedMaskedStroke.mask)
        #expect(!updatedMask.contains(CGPoint(x: 50, y: 100)))
        #expect(!updatedMask.contains(CGPoint(x: 100, y: 100)))
        #expect(updatedMask.contains(CGPoint(x: 150, y: 100)))
        #expect(updatedMaskedStroke.randomSeed == maskedStroke.randomSeed)

        let transform = CGAffineTransform(translationX: 450, y: 300)
            .rotated(by: .pi / 7)
            .scaledBy(x: 1.4, y: 0.75)
        let transformedStroke = makeTestStroke(
            from: CGPoint(x: 20, y: 100),
            to: CGPoint(x: 180, y: 100),
            width: 12,
            transform: transform
        )
        let localRubbedPoint = CGPoint(x: 100, y: 100)
        let transformedResult = try #require(
            DrawingCanvasView.PartialEraserStrokeProcessor.strokesByErasing(
                [transformedStroke],
                along: [localRubbedPoint.applying(transform)],
                diameter: 12
            )
        )
        let transformedMask = try #require(transformedResult.first?.mask)
        #expect(!transformedMask.contains(localRubbedPoint))
        #expect(transformedMask.contains(CGPoint(x: 50, y: 100)))
        #expect(transformedResult[0].transform == transform)
        #expect(transformedResult[0].path.count == transformedStroke.path.count)
    }

    @Test @MainActor func partialErasersDoNotBridgeAcrossInvalidLocations() {
        let stroke = makeTestStroke(
            from: CGPoint(x: 100, y: 90),
            to: CGPoint(x: 100, y: 110),
            width: 4
        )
        let locations = [
            CGPoint(x: 20, y: 100),
            CGPoint(x: CGFloat.nan, y: CGFloat.nan),
            CGPoint(x: 180, y: 100)
        ]
        let rubResult = DrawingCanvasView.PartialEraserStrokeProcessor.strokesByErasing(
            [stroke],
            along: locations,
            configuration: .init(shape: .wedge, size: 12, angle: 0)
        )
        let circleResult = DrawingCanvasView.PartialEraserStrokeProcessor.strokesByErasing(
            [stroke],
            along: locations,
            diameter: 12
        )

        #expect(rubResult == nil)
        #expect(circleResult == nil)
    }

    @Test @MainActor func partialEraserIgnoresEmptyCornersOfAStrokeRenderBounds() {
        let stroke = makeTestStroke(
            from: CGPoint(x: 20, y: 20),
            to: CGPoint(x: 180, y: 180),
            width: 4
        )

        let miss = DrawingCanvasView.PartialEraserStrokeProcessor.strokesByErasing(
            [stroke],
            along: [CGPoint(x: 20, y: 180)],
            diameter: 12
        )
        #expect(miss == nil)

        let hit = DrawingCanvasView.PartialEraserStrokeProcessor.strokesByErasing(
            [stroke],
            along: [CGPoint(x: 100, y: 100)],
            diameter: 12
        )
        #expect(hit?.first?.mask != nil)
    }

    @Test @MainActor func eraserScopeTracksTheActivePencilKitEraserWidth() throws {
        let fixture = try makePageCanvasFixture(name: "EraserScope")
        defer { fixture.cleanup() }

        let location = CGPoint(x: 140, y: 220)
        fixture.pageView.canvasView.tool = PKEraserTool(.fixedWidthBitmap, width: 42)
        fixture.pageView.updateEraserScope(at: location)
        #expect(fixture.pageView.eraserScopeView.isHidden)

        fixture.pageView.setLiveDrawingActive(true)
        fixture.pageView.updateEraserScope(at: location)

        #expect(!fixture.pageView.eraserScopeView.isHidden)
        #expect(fixture.pageView.eraserScopeView.center == location)
        #expect(fixture.pageView.eraserScopeView.bounds.size == CGSize(width: 42, height: 42))

        fixture.pageView.setEraserPreviewEnabled(
            true,
            diameter: 12
        )
        fixture.pageView.updateEraserScope(at: location)
        #expect(fixture.pageView.eraserScopeView.bounds.size == CGSize(width: 12, height: 12))

        fixture.pageView.setEraserPreviewEnabled(
            true,
            diameter: 42
        )
        #expect(fixture.pageView.eraserScopeView.center == location)
        #expect(fixture.pageView.eraserScopeView.bounds.size == CGSize(width: 42, height: 42))

        fixture.pageView.canvasView.tool = PKInkingTool(.pen, color: .black, width: 2)
        fixture.pageView.updateEraserScope(at: location)
        #expect(fixture.pageView.eraserScopeView.isHidden)

        fixture.pageView.canvasView.tool = PKEraserTool(.vector)
        fixture.pageView.setEraserPreviewEnabled(true, diameter: 26)
        fixture.pageView.updateEraserScope(at: nil)
        #expect(fixture.pageView.eraserScopeView.isHidden)

        fixture.pageView.updateEraserScope(at: location)
        #expect(!fixture.pageView.eraserScopeView.isHidden)
        #expect(fixture.pageView.eraserScopeView.center == location)
        #expect(
            fixture.pageView.eraserScopeView.bounds.size == CGSize(width: 26, height: 26)
        )

        fixture.pageView.setLiveDrawingActive(false)
        fixture.pageView.updateEraserScope(at: location)
        #expect(fixture.pageView.eraserScopeView.isHidden)
    }

    @Test @MainActor func customObjectEraserSuppressesNativeVectorInput() throws {
        let fixture = try makePageCanvasFixture(name: "CustomObjectEraser")
        defer { fixture.cleanup() }

        fixture.pageView.setEraserPreviewEnabled(
            true,
            diameter: 32,
            usesCustomObjectEraser: true
        )

        #expect(fixture.pageView.isUsingCustomObjectEraser)
        #expect(!fixture.pageView.canvasView.drawingGestureRecognizer.isEnabled)

        fixture.pageView.setEraserPreviewEnabled(true, diameter: 32)

        #expect(!fixture.pageView.isUsingCustomObjectEraser)
        #expect(fixture.pageView.canvasView.drawingGestureRecognizer.isEnabled)
    }

    @Test @MainActor func pixelEraserUsesNativePencilKitInput() throws {
        let fixture = try makePageCanvasFixture(name: "NativePixelEraser")
        defer { fixture.cleanup() }
        let page = try #require(fixture.pageView.page)
        let stroke = makeTestStroke(
            from: CGPoint(x: 20, y: 100),
            to: CGPoint(x: 180, y: 100),
            width: 4
        )
        fixture.pageView.canvasView.drawing = PKDrawing(strokes: [stroke])
        let toolState = fixture.coordinator.parent.toolState
        toolState.selectEraserMode(.pixel)
        toolState.applyEraserWidth(26)
        fixture.coordinator.register(
            canvasView: fixture.pageView.canvasView,
            page: page,
            pageView: fixture.pageView
        )

        let eraser = try #require(fixture.pageView.canvasView.tool as? PKEraserTool)
        #expect(eraser.eraserType == .fixedWidthBitmap)
        #expect(eraser.width == 26)
        #expect(!fixture.pageView.isUsingCustomObjectEraser)
        #expect(!fixture.pageView.isUsingCustomRubEraser)
        #expect(fixture.pageView.canvasView.drawingGestureRecognizer.isEnabled)

        // The scope recognizer may observe the touch for its cursor, but pixel erasing
        // stays exclusively on PencilKit's optimized drawing recognizer.
        fixture.pageView.handleEraserInteraction(.began(CGPoint(x: 100, y: 100)))
        fixture.pageView.handleEraserInteraction(.moved(CGPoint(x: 120, y: 100)))
        fixture.pageView.handleEraserInteraction(.ended(CGPoint(x: 140, y: 100)))
        #expect(fixture.pageView.canvasView.drawing.strokes.first?.mask == nil)
        #expect(fixture.pageView.canvasView.drawing.strokes.first?.renderBounds == stroke.renderBounds)
    }

    @Test @MainActor func customRubEraserRetainsTightMovementSamples() throws {
        let fixture = try makePageCanvasFixture(name: "TightRubEraserMovement")
        defer { fixture.cleanup() }
        let stroke = makeTestStroke(
            from: CGPoint(x: 20, y: 118),
            to: CGPoint(x: 180, y: 118),
            width: 4
        )
        fixture.pageView.canvasView.drawing = PKDrawing(strokes: [stroke])
        fixture.pageView.setEraserPreviewEnabled(
            true,
            diameter: 42,
            rubEraserConfiguration: .init(shape: .rectangle, size: 42, angle: 0)
        )

        fixture.pageView.handleEraserInteraction(.began(CGPoint(x: 100, y: 100)))
        #expect(fixture.pageView.canvasView.drawing.strokes.first?.mask == nil)

        // Eight points is below the old size/4 simplification threshold, but the
        // translated rub boundary reaches this stroke and must be retained.
        fixture.pageView.handleEraserInteraction(.moved(CGPoint(x: 100, y: 108)))
        let updatedStroke = try #require(fixture.pageView.canvasView.drawing.strokes.first)
        let updatedMask = try #require(updatedStroke.mask)
        #expect(!updatedMask.contains(CGPoint(x: 100, y: 118)))

        fixture.pageView.handleEraserInteraction(.ended(CGPoint(x: 100, y: 108)))
    }

    @Test @MainActor func customRubEraserSuppressesNativeInputAndShowsItsShapeScope() throws {
        let fixture = try makePageCanvasFixture(name: "CustomRubEraser")
        defer { fixture.cleanup() }
        let page = try #require(fixture.pageView.page)
        fixture.coordinator.register(
            canvasView: fixture.pageView.canvasView,
            page: page,
            pageView: fixture.pageView
        )
        defer {
            fixture.coordinator.unregister(
                canvasView: fixture.pageView.canvasView,
                page: page,
                flushDrawingBeforeRelease: false
            )
        }
        let toolState = fixture.coordinator.parent.toolState
        toolState.selectRubEraserShape(.chisel)
        toolState.applyRubEraserSize(44)
        toolState.applyRubEraserAngle(35)
        fixture.coordinator.register(
            canvasView: fixture.pageView.canvasView,
            page: page,
            pageView: fixture.pageView
        )

        #expect(fixture.pageView.isUsingCustomRubEraser)
        #expect(!fixture.pageView.isUsingCustomObjectEraser)
        #expect(!fixture.pageView.canvasView.drawingGestureRecognizer.isEnabled)
        fixture.pageView.applyInputMode(.anyInput)
        #expect(!fixture.pageView.canvasView.drawingGestureRecognizer.isEnabled)
        fixture.pageView.applyInputMode(.pencilOnly)
        #expect(!fixture.pageView.canvasView.drawingGestureRecognizer.isEnabled)

        let location = CGPoint(x: 120, y: 180)
        let stroke = makeTestStroke(
            from: CGPoint(x: 80, y: location.y),
            to: CGPoint(x: 160, y: location.y),
            width: 4
        )
        fixture.pageView.canvasView.drawing = PKDrawing(strokes: [stroke])
        fixture.pageView.handleEraserInteraction(.began(location))

        #expect(!fixture.pageView.eraserScopeView.isHidden)
        #expect(fixture.pageView.eraserScopeView.center == location)
        #expect(fixture.pageView.eraserScopeView.bounds.size == CGSize(width: 44, height: 44))
        #expect(fixture.pageView.canvasView.drawing.strokes.first?.mask != nil)

        let movedLocation = CGPoint(x: location.x + 2, y: location.y)
        fixture.pageView.handleEraserInteraction(.moved(movedLocation))
        #expect(!fixture.pageView.eraserScopeView.isHidden)
        #expect(fixture.pageView.eraserScopeView.center == movedLocation)
        fixture.pageView.handleEraserInteraction(.ended(movedLocation))
        #expect(fixture.pageView.eraserScopeView.isHidden)

        toolState.selectEraserMode(.pixel)
        fixture.coordinator.register(
            canvasView: fixture.pageView.canvasView,
            page: page,
            pageView: fixture.pageView
        )
        #expect(!fixture.pageView.isUsingCustomRubEraser)
        #expect(!fixture.pageView.isUsingCustomObjectEraser)
        #expect(fixture.pageView.canvasView.drawingGestureRecognizer.isEnabled)
        let pixelEraser = try #require(
            fixture.pageView.canvasView.tool as? PKEraserTool
        )
        #expect(pixelEraser.eraserType == .fixedWidthBitmap)

        toolState.select(.pen)
        fixture.coordinator.register(
            canvasView: fixture.pageView.canvasView,
            page: page,
            pageView: fixture.pageView
        )
        fixture.pageView.applyInputMode(.anyInput)
        #expect(fixture.pageView.canvasView.drawingGestureRecognizer.isEnabled)
    }

    @Test @MainActor func objectEraserHitTestingUsesTheDisplayedCircleBoundary() {
        let edgeStroke = makeTestStroke(
            from: CGPoint(x: 20, y: 100),
            to: CGPoint(x: 180, y: 100),
            width: 4
        )
        let outsideStroke = makeTestStroke(
            from: CGPoint(x: 20, y: 140),
            to: CGPoint(x: 180, y: 140),
            width: 4
        )
        let transformedStroke = makeTestStroke(
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 60, y: 0),
            width: 4,
            transform: CGAffineTransform(translationX: 80, y: 80)
        )
        let strokes = [edgeStroke, outsideStroke, transformedStroke]

        let edgeHit = DrawingCanvasView.ObjectEraserHitTester.intersectedStrokeIndexes(
            in: strokes,
            eraserPath: [CGPoint(x: 100, y: 112)],
            diameter: 20
        )
        #expect(edgeHit == IndexSet(integer: 0))

        let outside = DrawingCanvasView.ObjectEraserHitTester.intersectedStrokeIndexes(
            in: strokes,
            eraserPath: [CGPoint(x: 100, y: 112.2)],
            diameter: 20
        )
        #expect(outside.isEmpty)

        let sweptHit = DrawingCanvasView.ObjectEraserHitTester.intersectedStrokeIndexes(
            in: strokes,
            eraserPath: [CGPoint(x: 40, y: 80), CGPoint(x: 160, y: 80)],
            diameter: 20
        )
        #expect(sweptHit == IndexSet(integer: 2))
    }

    @Test @MainActor func objectEraserIncludesTheLargestAffineStrokeScale() {
        let transform = CGAffineTransform(translationX: 100, y: 100)
            .rotated(by: .pi / 4)
            .scaledBy(x: 4, y: 1)
        let stroke = makeTestStroke(
            from: .zero,
            to: CGPoint(x: 1, y: 0),
            width: 10,
            transform: transform
        )
        let transformedEndpoint = CGPoint(x: 1, y: 0).applying(transform)
        let directionLength = hypot(transform.a, transform.b)
        let majorAxisDirection = CGPoint(
            x: transform.a / directionLength,
            y: transform.b / directionLength
        )
        let boundaryPoint = CGPoint(
            x: transformedEndpoint.x + majorAxisDirection.x * 18,
            y: transformedEndpoint.y + majorAxisDirection.y * 18
        )

        let intersected = DrawingCanvasView.ObjectEraserHitTester.intersectedStrokeIndexes(
            in: [stroke],
            eraserPath: [boundaryPoint],
            diameter: 2
        )

        #expect(intersected == IndexSet(integer: 0))
    }

    @Test @MainActor func objectEraserPathRetainsTouchDownAcrossGradualMovement() {
        let touchDown = CGPoint(x: 100, y: 116)
        let finalPoint = CGPoint(x: 106, y: 116)
        var path = DrawingCanvasView.ObjectEraserPathAccumulator()
        path.begin(at: touchDown)

        for x in 101...105 {
            path.append(
                CGPoint(x: CGFloat(x), y: 116),
                minimumSpacing: 8
            )
        }
        path.append(finalPoint, minimumSpacing: 8, force: true)

        #expect(path.points == [touchDown, finalPoint])

        let touchDownOnlyStroke = makeTestStroke(
            from: CGPoint(x: 100, y: 98),
            to: CGPoint(x: 101, y: 98),
            width: 4
        )
        let intersected = DrawingCanvasView.ObjectEraserHitTester.intersectedStrokeIndexes(
            in: [touchDownOnlyStroke],
            eraserPath: path.points,
            diameter: 32
        )
        #expect(intersected == IndexSet(integer: 0))
    }

    @Test @MainActor func objectEraserIgnoresMaskedOutStrokeGaps() {
        let unmaskedStroke = makeTestStroke(
            from: CGPoint(x: 20, y: 100),
            to: CGPoint(x: 180, y: 100),
            width: 6
        )
        let visibleSegmentsMask = UIBezierPath(ovalIn: CGRect(x: 40, y: 90, width: 20, height: 20))
        visibleSegmentsMask.append(UIBezierPath(ovalIn: CGRect(x: 140, y: 90, width: 20, height: 20)))
        let maskedStroke = PKStroke(
            ink: unmaskedStroke.ink,
            path: unmaskedStroke.path,
            transform: unmaskedStroke.transform,
            mask: visibleSegmentsMask
        )

        #expect(maskedStroke.maskedPathRanges.count == 2)

        let maskedGap = DrawingCanvasView.ObjectEraserHitTester.intersectedStrokeIndexes(
            in: [maskedStroke],
            eraserPath: [CGPoint(x: 100, y: 100)],
            diameter: 8
        )
        #expect(maskedGap.isEmpty)

        let visibleSegment = DrawingCanvasView.ObjectEraserHitTester.intersectedStrokeIndexes(
            in: [maskedStroke],
            eraserPath: [CGPoint(x: 50, y: 100)],
            diameter: 8
        )
        #expect(visibleSegment == IndexSet(integer: 0))
    }

    @Test @MainActor func customObjectEraserRemovesOnlyIntersectingWholeStrokesOnce() throws {
        let fixture = try makePageCanvasFixture(name: "ObjectEraserCommit")
        defer { fixture.cleanup() }

        let hitStroke = makeTestStroke(
            from: CGPoint(x: 20, y: 100),
            to: CGPoint(x: 180, y: 100)
        )
        let retainedStroke = makeTestStroke(
            from: CGPoint(x: 20, y: 180),
            to: CGPoint(x: 180, y: 180)
        )
        fixture.pageView.canvasView.drawing = PKDrawing(strokes: [hitStroke, retainedStroke])

        var changeCount = 0
        fixture.pageView.objectEraserDrawingChanged = {
            changeCount += 1
        }

        let didErase = fixture.pageView.eraseObjects(
            along: [CGPoint(x: 100, y: 100)],
            diameter: 20
        )

        #expect(didErase)
        #expect(fixture.pageView.canvasView.drawing.strokes.count == 1)
        #expect(fixture.pageView.canvasView.drawing.strokes.first?.renderBounds == retainedStroke.renderBounds)
        #expect(changeCount == 1)
    }

    @Test @MainActor func customObjectEraserUpdatesDrawingBeforePencilLift() throws {
        let fixture = try makePageCanvasFixture(name: "LiveObjectEraser")
        defer { fixture.cleanup() }

        let touchDownStroke = makeTestStroke(
            from: CGPoint(x: 20, y: 100),
            to: CGPoint(x: 180, y: 100)
        )
        let movedStroke = makeTestStroke(
            from: CGPoint(x: 20, y: 180),
            to: CGPoint(x: 180, y: 180)
        )
        let retainedStroke = makeTestStroke(
            from: CGPoint(x: 20, y: 260),
            to: CGPoint(x: 180, y: 260)
        )
        fixture.pageView.canvasView.drawing = PKDrawing(
            strokes: [touchDownStroke, movedStroke, retainedStroke]
        )
        fixture.pageView.setEraserPreviewEnabled(
            true,
            diameter: 20,
            usesCustomObjectEraser: true
        )

        var beginCount = 0
        var endCount = 0
        var changeCount = 0
        fixture.pageView.objectEraserDidBegin = { beginCount += 1 }
        fixture.pageView.objectEraserDidEnd = { endCount += 1 }
        fixture.pageView.objectEraserDrawingChanged = { changeCount += 1 }

        fixture.pageView.handleEraserInteraction(.began(CGPoint(x: 100, y: 100)))

        #expect(fixture.pageView.canvasView.drawing.strokes.count == 2)
        #expect(beginCount == 1)
        #expect(endCount == 0)
        #expect(changeCount == 1)

        fixture.pageView.handleEraserInteraction(.movedBatch([
            CGPoint(x: 100, y: 120),
            CGPoint(x: 100, y: 150),
            CGPoint(x: 100, y: 180)
        ]))

        #expect(fixture.pageView.canvasView.drawing.strokes.count == 1)
        #expect(
            fixture.pageView.canvasView.drawing.strokes.first?.renderBounds
                == retainedStroke.renderBounds
        )
        #expect(endCount == 0)
        #expect(changeCount == 1)

        fixture.pageView.handleEraserInteraction(.endedBatch([
            CGPoint(x: 100, y: 180)
        ]))

        #expect(endCount == 1)
        #expect(changeCount == 1)
    }

    @Test @MainActor func objectEraserEndedBatchPreservesReturningLoopAndUndo() throws {
        let fixture = try makePageCanvasFixture(name: "LoopingObjectEraser")
        defer { fixture.cleanup() }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        let hostViewController = UIViewController()
        window.rootViewController = hostViewController
        window.makeKeyAndVisible()
        hostViewController.view.addSubview(fixture.pageView)
        fixture.pageView.frame = hostViewController.view.bounds
        fixture.pageView.layoutIfNeeded()
        defer { window.isHidden = true }

        let boundaryStroke = makeTestStroke(
            from: CGPoint(x: 90, y: 129),
            to: CGPoint(x: 110, y: 129),
            width: 2
        )
        fixture.pageView.canvasView.drawing = PKDrawing(strokes: [boundaryStroke])
        fixture.pageView.setEraserPreviewEnabled(
            true,
            diameter: 40,
            usesCustomObjectEraser: true
        )
        let undoManager = try #require(fixture.pageView.canvasView.undoManager)
        var endCount = 0
        fixture.pageView.objectEraserDidEnd = { endCount += 1 }

        fixture.pageView.handleEraserInteraction(.began(CGPoint(x: 100, y: 100)))
        #expect(fixture.pageView.canvasView.drawing.strokes.count == 1)

        fixture.pageView.handleEraserInteraction(.movedBatch([
            CGPoint(x: 100, y: 105)
        ]))
        #expect(fixture.pageView.canvasView.drawing.strokes.count == 1)

        fixture.pageView.handleEraserInteraction(.endedBatch([
            CGPoint(x: 100, y: 109),
            CGPoint(x: 100, y: 100)
        ]))

        #expect(fixture.pageView.canvasView.drawing.strokes.isEmpty)
        #expect(endCount == 1)

        undoManager.undo()
        #expect(fixture.pageView.canvasView.drawing.strokes.count == 1)
    }

    @Test @MainActor func objectEraserBuffersSlowSinglePointEvents() throws {
        let fixture = try makePageCanvasFixture(name: "BufferedObjectEraser")
        defer { fixture.cleanup() }

        fixture.pageView.setEraserPreviewEnabled(
            true,
            diameter: 40,
            usesCustomObjectEraser: true
        )
        fixture.pageView.handleEraserInteraction(.began(CGPoint(x: 100, y: 100)))
        #expect(fixture.pageView.objectEraserLiveEvaluationCount == 1)

        for x in 101...109 {
            fixture.pageView.handleEraserInteraction(
                .moved(CGPoint(x: CGFloat(x), y: 100))
            )
        }
        #expect(fixture.pageView.objectEraserLiveEvaluationCount == 1)

        fixture.pageView.handleEraserInteraction(.moved(CGPoint(x: 110, y: 100)))
        #expect(fixture.pageView.objectEraserLiveEvaluationCount == 2)

        fixture.pageView.handleEraserInteraction(.endedBatch([
            CGPoint(x: 110, y: 100)
        ]))
    }

    @Test @MainActor func cancelledLiveObjectEraseRestoresTheOriginalDrawing() throws {
        let fixture = try makePageCanvasFixture(name: "CancelledLiveObjectEraser")
        defer { fixture.cleanup() }

        let stroke = makeTestStroke(
            from: CGPoint(x: 20, y: 100),
            to: CGPoint(x: 180, y: 100)
        )
        fixture.pageView.canvasView.drawing = PKDrawing(strokes: [stroke])
        fixture.pageView.setEraserPreviewEnabled(
            true,
            diameter: 20,
            usesCustomObjectEraser: true
        )

        var changeCount = 0
        fixture.pageView.objectEraserDrawingChanged = { changeCount += 1 }
        fixture.pageView.handleEraserInteraction(.began(CGPoint(x: 100, y: 100)))

        #expect(fixture.pageView.canvasView.drawing.strokes.isEmpty)

        fixture.pageView.handleEraserInteraction(.cancelled)

        #expect(fixture.pageView.canvasView.drawing.strokes.count == 1)
        #expect(
            fixture.pageView.canvasView.drawing.strokes.first?.renderBounds == stroke.renderBounds
        )
        #expect(changeCount == 2)
    }

    @Test @MainActor func objectEraserUndoDefersDrawingNotificationUntilUndoCompletes() async throws {
        let fixture = try makePageCanvasFixture(name: "ObjectEraserUndoNotification")
        defer { fixture.cleanup() }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        let hostViewController = UIViewController()
        window.rootViewController = hostViewController
        window.makeKeyAndVisible()
        hostViewController.view.addSubview(fixture.pageView)
        fixture.pageView.frame = hostViewController.view.bounds
        fixture.pageView.layoutIfNeeded()
        defer { window.isHidden = true }

        let stroke = makeTestStroke(
            from: CGPoint(x: 20, y: 100),
            to: CGPoint(x: 180, y: 100)
        )
        fixture.pageView.canvasView.drawing = PKDrawing(strokes: [stroke])
        let undoManager = try #require(fixture.pageView.canvasView.undoManager)

        var notificationDuringUndo: Bool?
        fixture.pageView.objectEraserDrawingChanged = {
            notificationDuringUndo = fixture.pageView.canvasView.undoManager?.isUndoing == true
        }

        #expect(fixture.pageView.eraseObjects(along: [CGPoint(x: 100, y: 100)], diameter: 20))
        notificationDuringUndo = nil

        undoManager.undo()

        #expect(notificationDuringUndo == nil)
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(notificationDuringUndo == false)
        #expect(fixture.pageView.canvasView.drawing.strokes.count == 1)
    }

    @Test @MainActor func strokeWidthCalibrationClampsRoundsAndPersistsPerTool() throws {
        let suiteName = "BeanNotesStrokeWidth-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let firstSession = DrawingToolState(defaults: defaults)
        firstSession.selectWidthMode(.standard)
        firstSession.select(.pen)
        firstSession.applyActiveWidth(2.26)
        #expect(firstSession.penWidth == 2.5)

        firstSession.applyActiveWidth(0.1)
        #expect(firstSession.penWidth == 0.5)

        firstSession.applyActiveWidth(99)
        #expect(firstSession.penWidth == 24)

        firstSession.select(.pencil)
        firstSession.applyActiveWidth(.infinity)
        #expect(firstSession.pencilWidth == 1)

        firstSession.select(.highlighter)
        firstSession.applyActiveWidth(7.6)
        #expect(firstSession.highlighterWidth == 8)
        #expect(firstSession.widthPresets(for: .highlighter) == [8, 14, 22, 32])

        let restoredSession = DrawingToolState(defaults: defaults)
        #expect(restoredSession.widthMode == .standard)
        #expect(restoredSession.penWidth == 24)
        #expect(restoredSession.pencilWidth == 1)
        #expect(restoredSession.highlighterWidth == 8)
    }

    @Test @MainActor func lightTouchStrokeWidthModeIsDefaultForFineHandwriting() throws {
        let suiteName = "BeanNotesLightTouchStrokeWidth-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let firstSession = DrawingToolState(defaults: defaults)
        #expect(DrawingStrokeWidthMode.allCases.map(\.label) == ["Light Touch", "Standard", "Precision"])
        #expect(DrawingStrokeWidthMode.allCases.map(\.systemImage) == ["pencil.tip", "lineweight", "scope"])
        #expect(firstSession.widthMode == .lightTouch)
        #expect(firstSession.penWidth == 2.5)
        #expect(firstSession.pencilWidth == 3.5)
        #expect(firstSession.highlighterWidth == 10)

        firstSession.select(.pen)
        #expect(firstSession.activeWidthStep == 0.25)
        #expect(abs(firstSession.activeFineWidthStep - 0.125) < 0.001)
        #expect(firstSession.widthPresets(for: .pen) == [0.5, 1, 1.5, 2.5])

        firstSession.applyActiveWidth(2.26)
        #expect(firstSession.penWidth == 2.25)

        firstSession.nudgeActiveWidth(by: 1)
        #expect(firstSession.penWidth == 2.5)

        firstSession.applyActiveWidth(2.26)
        firstSession.nudgeActiveWidth(by: 1, precision: .fine)
        #expect(abs(firstSession.penWidth - 2.375) < 0.001)
        #expect(abs(firstSession.activeStrokeWidth - 2.375) < 0.001)

        firstSession.applyActiveWidth(99)
        #expect(firstSession.penWidth == 12)
        #expect(firstSession.strokeWidth(for: .pen) == 12)

        firstSession.applyActiveWidth(0.1)
        #expect(firstSession.penWidth == 0.25)
        #expect(firstSession.strokeWidth(for: .pen) == 0.25)

        firstSession.select(.highlighter)
        #expect(firstSession.activeWidthStep == 0.5)
        #expect(firstSession.widthPresets(for: .highlighter) == [4, 6, 10, 14])

        let restoredSession = DrawingToolState(defaults: defaults)
        #expect(restoredSession.widthMode == .lightTouch)
        #expect(restoredSession.penWidth == 0.25)
    }

    @Test @MainActor func strokeWidthModeSwitchPreservesStoredToolWidths() throws {
        let suiteName = "BeanNotesStrokeWidthModeSwitch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let toolState = DrawingToolState(defaults: defaults)
        toolState.select(.pen)
        toolState.selectWidthMode(.standard)
        toolState.applyActiveWidth(24)
        #expect(toolState.penWidth == 24)
        #expect(toolState.strokeWidth(for: .pen) == 24)

        toolState.selectWidthMode(.lightTouch)
        #expect(toolState.penWidth == 24)
        #expect(toolState.strokeWidth(for: .pen) == 12)

        toolState.selectWidthMode(.standard)
        #expect(toolState.penWidth == 24)
        #expect(toolState.strokeWidth(for: .pen) == 24)
    }

    @Test @MainActor func precisionStrokeWidthModeAllowsFineAdjustmentsAndPersists() throws {
        let suiteName = "BeanNotesPrecisionStrokeWidth-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let firstSession = DrawingToolState(defaults: defaults)
        #expect(firstSession.widthMode == .lightTouch)
        #expect(firstSession.activeWidthStep == 0.25)

        firstSession.select(.pen)
        firstSession.selectWidthMode(.standard)
        #expect(firstSession.widthMode == .standard)
        #expect(firstSession.activeWidthStep == 0.5)

        firstSession.applyActiveWidth(2.26)
        #expect(firstSession.penWidth == 2.5)

        firstSession.selectWidthMode(.precision)
        #expect(firstSession.widthMode == .precision)
        #expect(firstSession.activeWidthStep == 0.1)

        firstSession.applyActiveWidth(2.26)
        #expect(abs(firstSession.penWidth - 2.3) < 0.001)

        firstSession.nudgeActiveWidth(by: -1)
        #expect(abs(firstSession.penWidth - 2.2) < 0.001)

        let restoredSession = DrawingToolState(defaults: defaults)
        #expect(restoredSession.widthMode == .precision)
        #expect(abs(restoredSession.penWidth - 2.2) < 0.001)
        #expect(abs(restoredSession.strokeWidth(for: .pen) - 2.2) < 0.001)
    }

    @Test @MainActor func zoomCalibratedInkScalesNewStrokeWidthWithoutChangingStoredWidth() throws {
        let suiteName = "BeanNotesZoomCalibratedInk-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let toolState = DrawingToolState(defaults: defaults)
        #expect(DrawingStrokeZoomBehavior.defaultBehavior == .zoomCalibrated)
        #expect(DrawingStrokeZoomBehavior.allCases.map(\.label) == ["Page Width", "Zoom Calibrated"])

        toolState.select(.pen)
        toolState.applyActiveWidth(2.5)

        #expect(toolState.strokeWidth(for: .pen) == 2.5)
        #expect(toolState.effectiveStrokeWidth(
            for: .pen,
            zoomScale: 4,
            zoomBehavior: .pageWidth
        ) == 2.5)
        #expect(abs(toolState.effectiveStrokeWidth(
            for: .pen,
            zoomScale: 4,
            zoomBehavior: .zoomCalibrated
        ) - 0.625) < 0.001)
        #expect(abs(toolState.effectiveStrokeWidth(
            for: .pen,
            zoomScale: 6,
            zoomBehavior: .zoomCalibrated
        ) - 0.416_666) < 0.001)
        #expect(toolState.penWidth == 2.5)

        let readout = toolState.strokeWidthReadout(
            for: .pen,
            zoomScale: 4,
            zoomBehavior: .zoomCalibrated
        )
        #expect(readout.storedWidthText == "2.5")
        #expect(readout.effectiveWidthText == "0.63")
        #expect(readout.showsEffectiveWidth)
        #expect(readout.accessibilityText == "Stored 2.5 points, page ink 0.63 points at 400% zoom")

        let pageWidthTool = try #require(toolState.makePKTool(
            zoomScale: 4,
            zoomBehavior: .pageWidth
        ) as? PKInkingTool)
        let zoomCalibratedTool = try #require(toolState.makePKTool(
            zoomScale: 4,
            zoomBehavior: .zoomCalibrated
        ) as? PKInkingTool)

        #expect(abs(pageWidthTool.width - 2.5) < 0.001)
        #expect(zoomCalibratedTool.width < pageWidthTool.width)
        #expect(zoomCalibratedTool.width > 0)
        #expect(toolState.pkToolSignature(
            zoomScale: 1,
            zoomBehavior: .zoomCalibrated
        ) != toolState.pkToolSignature(
            zoomScale: 4,
            zoomBehavior: .zoomCalibrated
        ))
    }

    @Test @MainActor func lockingPageInkStoresCurrentEffectiveWidthForConsistentZoom() throws {
        let suiteName = "BeanNotesPageInkLock-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let toolState = DrawingToolState(defaults: defaults)
        toolState.select(.pen)
        toolState.selectWidthMode(.lightTouch)
        toolState.applyActiveWidth(2.5)

        #expect(toolState.lockActiveWidthToEffectivePageInk(
            zoomScale: 4,
            zoomBehavior: .zoomCalibrated
        ))
        #expect(abs(toolState.penWidth - 0.625) < 0.001)
        #expect(abs(toolState.effectiveStrokeWidth(
            for: .pen,
            zoomScale: 4,
            zoomBehavior: .pageWidth
        ) - 0.625) < 0.001)
        #expect(!toolState.lockActiveWidthToEffectivePageInk(
            zoomScale: 1,
            zoomBehavior: .zoomCalibrated
        ))

        toolState.select(.eraser)
        #expect(!toolState.lockActiveWidthToEffectivePageInk(
            zoomScale: 4,
            zoomBehavior: .zoomCalibrated
        ))
    }

    @Test func drawingStrokeWidthReadoutFormatsCommonPointSizes() {
        #expect(DrawingStrokeWidthReadout.pointsText(for: 1) == "1")
        #expect(DrawingStrokeWidthReadout.pointsText(for: 1.5) == "1.5")
        #expect(DrawingStrokeWidthReadout.pointsText(for: 0.25) == "0.25")
        #expect(DrawingStrokeWidthReadout.pointsText(for: 0.625) == "0.63")

        let pageWidthReadout = DrawingStrokeWidthReadout(
            storedWidth: 2.5,
            effectiveWidth: 2.5,
            zoomScale: 4,
            zoomBehavior: .pageWidth
        )
        #expect(!pageWidthReadout.showsEffectiveWidth)
        #expect(pageWidthReadout.accessibilityText == "2.5 points")
    }

    @Test func drawingInkPreviewMetricsClampFineWidthsForVisibility() {
        let detailReadout = DrawingStrokeWidthReadout(
            storedWidth: 2.5,
            effectiveWidth: 0.625,
            zoomScale: 4,
            zoomBehavior: .zoomCalibrated
        )
        let detailMetrics = DrawingInkPreviewMetrics(readout: detailReadout)

        #expect(detailMetrics.storedVisualThickness == 7.5)
        #expect(detailMetrics.effectiveVisualThickness == 1.875)
        #expect(detailMetrics.accessibilityLabel == "Ink preview, Stored 2.5 points, page ink 0.63 points at 400% zoom")

        #expect(DrawingInkPreviewMetrics.visualThickness(for: 0.1) == 1.5)
        #expect(DrawingInkPreviewMetrics.visualThickness(for: 10) == 12)
        #expect(DrawingInkPreviewMetrics.visualThickness(for: .infinity) == 1.5)
    }

    @Test func drawingInkCalibrationStatusAppearsOnlyForDetailedCustomInk() {
        let detailReadout = DrawingStrokeWidthReadout(
            storedWidth: 2.5,
            effectiveWidth: 0.625,
            zoomScale: 4,
            zoomBehavior: .zoomCalibrated
        )
        let status = DrawingInkCalibrationStatus(tool: .pen, readout: detailReadout)

        #expect(DrawingInkCalibrationStatus.shouldShow(
            readout: detailReadout,
            isUsingCustomPalette: true,
            toolUsesInk: true
        ))
        #expect(!DrawingInkCalibrationStatus.shouldShow(
            readout: detailReadout,
            isUsingCustomPalette: false,
            toolUsesInk: true
        ))
        #expect(!DrawingInkCalibrationStatus.shouldShow(
            readout: detailReadout,
            isUsingCustomPalette: true,
            toolUsesInk: false
        ))
        #expect(status.zoomText == "400%")
        #expect(status.pageInkText == "Page 0.63 pt")
        #expect(status.storedInkText == "Stored 2.5 pt")
        #expect(status.accessibilityLabel == "Pen ink, page width 0.63 points at 400% zoom, stored width 2.5 points")

        let pageWidthReadout = DrawingStrokeWidthReadout(
            storedWidth: 2.5,
            effectiveWidth: 2.5,
            zoomScale: 4,
            zoomBehavior: .pageWidth
        )

        #expect(!DrawingInkCalibrationStatus.shouldShow(
            readout: pageWidthReadout,
            isUsingCustomPalette: true,
            toolUsesInk: true
        ))
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

    @Test @MainActor func customPaletteDisplayCountPreservesHiddenSwatches() throws {
        let suiteName = "BeanNotesPaletteDisplayCount-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let toolState = DrawingToolState(defaults: defaults)
        let fullPalette = toolState.paletteSwatches(for: .pen).map(\.colorHex)
        let compactPalette = toolState.paletteSwatches(for: .pen, displaying: 5).map(\.colorHex)

        #expect(fullPalette.count == DrawingPaletteConfiguration.maximumColorCount)
        #expect(compactPalette == Array(fullPalette.prefix(5)))
        #expect(toolState.paletteSwatches(for: .pen, displaying: 99).map(\.colorHex) == fullPalette)

        toolState.select(.pen)
        toolState.selectPaletteColor(toolState.paletteColor(at: 7, for: .pen))

        let visibleSelectionIndex = toolState.ensureActivePaletteColorIsVisible(
            for: .pen,
            displaying: 5
        )
        #expect(visibleSelectionIndex == 0)
        #expect(
            UIColor(toolState.inkColor(for: .pen)).hexRGB
                == UIColor(toolState.paletteColor(at: visibleSelectionIndex, for: .pen)).hexRGB
        )
        #expect(toolState.paletteSwatches(for: .pen).map(\.colorHex) == fullPalette)
    }

    @Test @MainActor func customPaletteIndexesMatchActiveColorsAcrossTools() throws {
        let suiteName = "BeanNotesPaletteActiveIndex-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let firstSession = DrawingToolState(defaults: defaults)
        #expect(firstSession.paletteIndexMatchingActiveColor(for: .pen) == 0)
        #expect(firstSession.paletteIndexMatchingActiveColor(for: .pencil) == 0)
        #expect(firstSession.paletteIndexMatchingActiveColor(for: .highlighter) == 0)

        firstSession.select(.pen)
        firstSession.selectPaletteColor(firstSession.paletteColor(at: 3, for: .pen))
        #expect(firstSession.paletteIndexMatchingActiveColor() == 3)

        firstSession.select(.pencil)
        firstSession.setPaletteColor(
            Color(uiColor: UIColor(red: 0.18, green: 0.43, blue: 0.88, alpha: 1)),
            at: 5
        )
        #expect(firstSession.paletteIndexMatchingActiveColor() == 5)

        firstSession.select(.highlighter)
        let duplicatedPrimaryColor = firstSession.paletteColor(at: 0, for: .highlighter)
        firstSession.setPaletteColor(duplicatedPrimaryColor, at: 4)
        #expect(firstSession.paletteIndexMatchingActiveColor(for: .highlighter, preferredIndex: 4) == 4)
        #expect(firstSession.paletteIndexMatchingActiveColor(for: .highlighter) == 0)

        firstSession.select(.pencil)
        firstSession.select(.eraser)
        #expect(firstSession.activeColorTool == .pencil)
        #expect(firstSession.paletteIndexMatchingActiveColor() == 5)

        let restoredSession = DrawingToolState(defaults: defaults)
        #expect(restoredSession.paletteIndexMatchingActiveColor(for: .pen) == 3)
        #expect(restoredSession.paletteIndexMatchingActiveColor(for: .pencil) == 5)
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
        let thumbnailURL = try service.generateThumbnail(
            for: page,
            theme: .bean,
            showsBeanArtwork: false,
            maxDimension: 120
        )
        let thumbnail = try #require(UIImage(contentsOfFile: thumbnailURL.path))
        #expect(ImageMemoryCache.shared.image(at: thumbnailURL, maxPixelSize: 120) != nil)
        #expect(ImageMemoryCache.shared.cachedVariantCount(for: thumbnailURL) == 1)
        let refreshedThumbnailURL = try service.generateThumbnail(
            for: page,
            theme: .bean,
            showsBeanArtwork: false,
            maxDimension: 120
        )

        #expect(ImageMemoryCache.shared.cachedVariantCount(for: thumbnailURL) == 0)
        #expect(page.thumbnailFileName?.hasPrefix("Thumbnails/") == true)
        #expect(FileManager.default.fileExists(atPath: thumbnailURL.path))
        #expect(FileManager.default.fileExists(atPath: refreshedThumbnailURL.path))
        #expect(thumbnailURL.lastPathComponent == refreshedThumbnailURL.lastPathComponent)
        #expect(
            refreshedThumbnailURL.lastPathComponent
                == ThumbnailService.thumbnailFileName(
                    pageID: page.id,
                    theme: .bean,
                    showsBeanArtwork: false
                )
        )
        #expect(refreshedThumbnailURL.lastPathComponent.hasPrefix("Thumbnails-") == false)
        #expect(page.thumbnailFileName?.components(separatedBy: "/").count == 2)
        #expect(max(thumbnail.size.width, thumbnail.size.height) <= 120.5)
        #expect(thumbnail.size.height > thumbnail.size.width)
    }

    @Test @MainActor func backgroundThumbnailUsesLatestCachedDrawing() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesLiveThumbnail-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        try storage.prepareDirectories()
        let drawingStorage = DrawingStorageService(storage: storage)
        let service = ThumbnailService(storage: storage, drawingStorage: drawingStorage)
        let page = NotePage(pageOrder: 0, width: 180, height: 180)
        let diskDrawing = makeTestDrawing(color: .systemBlue, xOffset: 0)
        let liveDrawing = makeTestDrawing(color: .systemRed, xOffset: 48)
        try drawingStorage.save(diskDrawing, for: page)
        DrawingStorageService.cache(liveDrawing, fileName: page.drawingFileName, rootURL: rootURL)
        let currentTheme = BeanNotesTheme.currentFromDefaults()
        let showsArtwork = NoteBackground.showsArtwork(for: currentTheme)

        let thumbnailURL = try await service.generateThumbnailInBackground(
            for: page,
            theme: currentTheme,
            showsBeanArtwork: showsArtwork,
            maxDimension: 180
        )
        let thumbnail = try #require(UIImage(contentsOfFile: thumbnailURL.path))

        #expect(imageContainsDominantRedInk(thumbnail))
    }

    @Test func documentVersionSwitchKeepsPageAndDrawingIdentityAndSeparatesCurrentFromLatest() throws {
        let context = try makeInMemoryModelContext()
        let firstPage = NotePage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            pageOrder: 0,
            drawingFileName: "version-page-one.drawing",
            width: 612,
            height: 792
        )
        let secondPage = NotePage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            pageOrder: 1,
            drawingFileName: "version-page-two.drawing",
            width: 612,
            height: 792
        )
        let note = NoteDocument(title: "Versioned Plan", pages: [secondPage, firstPage])
        context.insert(note)
        let pageIDs = note.sortedPages.map(\.id)
        let drawingFileNames = note.sortedPages.map(\.drawingFileName)
        let service = DocumentVersionService()

        let originalAttachments = attachPDFVersion(
            named: "Original",
            storedBaseName: "original-plan",
            to: note.sortedPages,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let original = try #require(service.registerImportedVersion(
            attachments: originalAttachments,
            named: "Original",
            in: note,
            createdAt: Date(timeIntervalSince1970: 100)
        ))
        let revisionAttachments = attachPDFVersion(
            named: "Revision",
            storedBaseName: "revised-plan",
            to: note.sortedPages,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let revision = try #require(service.registerImportedVersion(
            attachments: revisionAttachments,
            named: "Revision",
            in: note,
            createdAt: Date(timeIntervalSince1970: 200)
        ))

        #expect(note.sortedPages.map(\.id) == pageIDs)
        #expect(note.sortedPages.map(\.drawingFileName) == drawingFileNames)
        #expect(note.sortedPages.map { $0.lockedImageAttachments.map(\.storedFileName) } == [
            ["Imports/revised-plan-page-1.jpg"],
            ["Imports/revised-plan-page-2.jpg"]
        ])
        #expect(service.versions(in: note).filter(\.isCurrent).map(\.id) == [revision.id])
        #expect(service.versions(in: note).filter(\.isLatest).map(\.id) == [revision.id])

        let indexedAt = Date(timeIntervalSince1970: 300)
        for page in note.pages {
            page.searchIndexUpdatedAt = indexedAt
        }
        note.searchIndexUpdatedAt = indexedAt
        #expect(service.useVersion(original.id, in: note))
        #expect(note.sortedPages.map(\.id) == pageIDs)
        #expect(note.sortedPages.map(\.drawingFileName) == drawingFileNames)
        #expect(note.sortedPages.allSatisfy { $0.searchIndexUpdatedAt == nil })
        #expect(note.searchIndexUpdatedAt == nil)
        #expect(note.sortedPages.map { $0.lockedImageAttachments.map(\.storedFileName) } == [
            ["Imports/original-plan-page-1.jpg"],
            ["Imports/original-plan-page-2.jpg"]
        ])
        #expect(service.versions(in: note).filter(\.isCurrent).map(\.id) == [original.id])
        #expect(service.versions(in: note).filter(\.isLatest).map(\.id) == [revision.id])

        #expect(service.renameVersion(original.id, to: "  Archived Original  ", in: note))
        #expect(service.attachments(for: original.id, in: note).allSatisfy {
            $0.documentVersionName == "Archived Original"
        })
        #expect(!service.renameVersion(original.id, to: "  \n ", in: note))
        #expect(service.makeLatest(original.id, in: note))
        let renamed = try #require(service.versions(in: note).first { $0.id == original.id })
        #expect(renamed.name == "Archived Original")
        #expect(renamed.isCurrent)
        #expect(renamed.isLatest)
        #expect(service.versions(in: note).filter(\.isLatest).count == 1)
    }

    @Test func deletingCurrentLatestDocumentVersionFallsBackWithoutDeletingPagesOrDrawings() throws {
        let context = try makeInMemoryModelContext()
        let firstPage = NotePage(pageOrder: 0, drawingFileName: "retained-first.drawing")
        let secondPage = NotePage(pageOrder: 1, drawingFileName: "retained-second.drawing")
        let ordinaryAttachment = Attachment(
            kind: .other,
            displayName: "Reference",
            originalFileName: "reference.txt",
            storedFileName: "Imports/reference.txt",
            contentTypeIdentifier: UTType.plainText.identifier,
            fileExtension: "txt"
        )
        firstPage.attachments.append(ordinaryAttachment)
        let note = NoteDocument(title: "Retained Notes", pages: [firstPage, secondPage])
        context.insert(note)
        let pageIDs = note.sortedPages.map(\.id)
        let drawingFileNames = note.sortedPages.map(\.drawingFileName)
        let service = DocumentVersionService()

        let firstAttachments = attachPDFVersion(
            named: "Version 1",
            storedBaseName: "retained-v1",
            to: note.sortedPages,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let firstVersion = try #require(service.registerImportedVersion(
            attachments: firstAttachments,
            named: "Version 1",
            in: note,
            createdAt: Date(timeIntervalSince1970: 100)
        ))
        let secondAttachments = attachPDFVersion(
            named: "Version 2",
            storedBaseName: "retained-v2",
            to: note.sortedPages,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let secondVersion = try #require(service.registerImportedVersion(
            attachments: secondAttachments,
            named: "Version 2",
            in: note,
            createdAt: Date(timeIntervalSince1970: 200)
        ))
        let removedIDs = Set(secondAttachments.map(\.id))

        let removed = service.removeVersion(secondVersion.id, from: note)
        let retainedAttachmentIDs = Set(note.sortedPages.flatMap(\.attachments).map(\.id))

        #expect(Set(removed.map(\.id)) == removedIDs)
        #expect(removedIDs.isDisjoint(with: retainedAttachmentIDs))
        #expect(note.sortedPages.map(\.id) == pageIDs)
        #expect(note.sortedPages.map(\.drawingFileName) == drawingFileNames)
        #expect(firstPage.attachments.contains { $0.id == ordinaryAttachment.id })
        #expect(note.sortedPages.map { $0.lockedImageAttachments.map(\.storedFileName) } == [
            ["Imports/retained-v1-page-1.jpg"],
            ["Imports/retained-v1-page-2.jpg"]
        ])
        let fallback = try #require(service.versions(in: note).first)
        #expect(fallback.id == firstVersion.id)
        #expect(fallback.isCurrent)
        #expect(fallback.isLatest)
        #expect(service.versions(in: note).count == 1)
    }

    @Test func legacyPDFAdoptsDocumentVersionMetadataWithoutCopying() throws {
        let context = try makeInMemoryModelContext()
        let pdfPages = [
            NotePage(pageOrder: 0, width: 612, height: 792),
            NotePage(pageOrder: 1, width: 792, height: 612)
        ]
        let pdfNote = NoteDocument(title: "Legacy PDF", pages: pdfPages)
        context.insert(pdfNote)
        let legacyPDFAttachments = attachPDFVersion(
            named: "Legacy PDF",
            storedBaseName: "legacy-source",
            to: pdfNote.sortedPages,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let legacyPDFBackgrounds = legacyPDFAttachments.filter { $0.kind == .image }
        for page in pdfNote.pages {
            page.attachments.removeAll { $0.kind == .pdf }
        }
        let service = DocumentVersionService()

        #expect(legacyPDFAttachments.allSatisfy { $0.documentVersionID == nil })
        let adoptedPDF = try #require(service.adoptLegacyVersionIfNeeded(
            in: pdfNote,
            at: Date(timeIntervalSince1970: 200)
        ))
        #expect(adoptedPDF.name == "Legacy PDF")
        #expect(adoptedPDF.kind == .pdf)
        #expect(adoptedPDF.pageCount == 2)
        #expect(adoptedPDF.isCurrent)
        #expect(adoptedPDF.isLatest)
        #expect(Set(legacyPDFBackgrounds.compactMap(\.documentVersionID)) == Set([adoptedPDF.id]))
        #expect(legacyPDFAttachments.first { $0.kind == .pdf }?.documentVersionID == nil)
        #expect(service.adoptLegacyVersionIfNeeded(in: pdfNote)?.id == adoptedPDF.id)
    }

    @Test func thumbnailCacheIdentityIncludesThemeAndRendererVersion() {
        let pageID = UUID()
        let beanFileName = ThumbnailService.thumbnailFileName(
            pageID: pageID,
            theme: .bean,
            showsBeanArtwork: false
        )
        let beanArtworkFileName = ThumbnailService.thumbnailFileName(
            pageID: pageID,
            theme: .bean,
            showsBeanArtwork: true
        )
        let blueberryFileName = ThumbnailService.thumbnailFileName(
            pageID: pageID,
            theme: .blueberry,
            showsBeanArtwork: false
        )
        let blueberryArtworkFileName = ThumbnailService.thumbnailFileName(
            pageID: pageID,
            theme: .blueberry,
            showsBeanArtwork: true
        )
        let standardFileName = ThumbnailService.thumbnailFileName(pageID: pageID, theme: .standard)

        #expect(beanFileName != standardFileName)
        #expect(beanFileName != beanArtworkFileName)
        #expect(blueberryFileName != blueberryArtworkFileName)
        #expect(beanFileName != blueberryFileName)
        #expect(beanFileName.hasSuffix("-bean-off-v10.jpg"))
        #expect(beanArtworkFileName.hasSuffix("-bean-on-v10.jpg"))
        #expect(blueberryFileName.hasSuffix("-blueberry-bean-off-v10.jpg"))
        #expect(blueberryArtworkFileName.hasSuffix("-blueberry-bean-on-v10.jpg"))
        #expect(ThumbnailService.isCurrentThumbnailPath(
            "Thumbnails/\(beanFileName)",
            pageID: pageID,
            theme: .bean
        ))
        #expect(!ThumbnailService.isCurrentThumbnailPath(
            "Thumbnails/\(beanArtworkFileName)",
            pageID: pageID,
            theme: .bean,
            showsBeanArtwork: false
        ))
        #expect(ThumbnailService.isCurrentThumbnailPath(
            "Thumbnails/\(beanArtworkFileName)",
            pageID: pageID,
            theme: .bean,
            showsBeanArtwork: true
        ))
        #expect(!ThumbnailService.isCurrentThumbnailPath(
            "Thumbnails/\(pageID.uuidString).jpg",
            pageID: pageID,
            theme: .bean
        ))
        #expect(!ThumbnailService.isCurrentThumbnailPath(
            "Thumbnails/\(beanFileName)",
            pageID: pageID,
            theme: .standard
        ))
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
            context.beginPage(
                withBounds: CGRect(x: 0, y: 0, width: 792, height: 612),
                pageInfo: [:]
            )
            "Page 2".draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            context.beginPage(
                withBounds: CGRect(x: 0, y: 0, width: 200, height: 1_000),
                pageInfo: [:]
            )
            "Receipt".draw(at: CGPoint(x: 24, y: 36), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }

        let folder = NotebookFolder(name: "Class")
        context.insert(folder)
        try context.save()
        let imported = try await service.importDocumentAsNote(from: pdfURL, into: folder)
        try context.save()

        #expect(imported.note.title == "Syllabus")
        #expect(imported.pages.count == 3)
        #expect(imported.pages.allSatisfy { $0.lockedImageAttachments.count == 1 })
        #expect(imported.attachments.contains { $0.kind == .pdf && !$0.isLocked })
        #expect(imported.pages.allSatisfy { $0.lockedImageAttachments.allSatisfy(\.rendersBehindDrawing) })
        #expect(imported.pages.compactMap { $0.lockedImageAttachments.first?.vectorSourcePageIndex }.sorted() == [0, 1, 2])
        #expect(imported.pages.allSatisfy { $0.width == 1_024 })
        #expect(imported.pages.allSatisfy { $0.minimumPDFContentSize == $0.pageSize })
        #expect(imported.pages[0].height > imported.pages[1].height)
        #expect(imported.pages[2].height > imported.pages[0].height)
        #expect(imported.pages[2].height == NotePage.maximumPageDimension)

        let firstPage = try #require(imported.pages.first)
        let lockedImage = try #require(firstPage.lockedImageAttachments.first)
        let rasterURL = storage.url(forRelativePath: lockedImage.storedFileName)
        #expect(FileManager.default.fileExists(atPath: rasterURL.path))
        let rasterImage = try #require(UIImage(contentsOfFile: rasterURL.path))
        #expect(max(rasterImage.size.width, rasterImage.size.height) <= 1_280)
        #expect(rasterImage.size.width > 900)
        let vectorSource = try #require(lockedImage.vectorSourceStoredFileName)
        #expect(FileManager.default.fileExists(atPath: storage.url(forRelativePath: vectorSource).path))

        let tiledPage = DrawingCanvasView.PDFPageTiledView(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        tiledPage.configure(url: storage.url(forRelativePath: vectorSource), pageIndex: 0)
        #expect(tiledPage.layer is CATiledLayer)
        let stableContentsScale = tiledPage.layer.contentsScale
        tiledPage.updateRenderScale(12)
        #expect(tiledPage.layer.contentsScale == stableContentsScale)
        #expect(DrawingCanvasView.ImmediatePDFTiledLayer.fadeDuration() == 0)
        let idleTiledPage = DrawingCanvasView.PDFPageTiledView(frame: .zero)
        idleTiledPage.configure(url: storage.url(forRelativePath: vectorSource), pageIndex: 0)
        let initialInvalidationCount = idleTiledPage.displayInvalidationCount
        idleTiledPage.setRenderingSuspended(true)
        idleTiledPage.setRenderingSuspended(false)
        #expect(idleTiledPage.displayInvalidationCount == initialInvalidationCount)

        idleTiledPage.setRenderingSuspended(true)
        idleTiledPage.configure(url: storage.url(forRelativePath: vectorSource), pageIndex: 1)
        #expect(idleTiledPage.displayInvalidationCount == initialInvalidationCount)
        idleTiledPage.setRenderingSuspended(false)
        #expect(idleTiledPage.displayInvalidationCount == initialInvalidationCount + 1)

        let configuredInvalidationCount = idleTiledPage.displayInvalidationCount
        for _ in 0..<25 {
            idleTiledPage.setRenderingSuspended(true)
            idleTiledPage.setRenderingSuspended(false)
        }
        #expect(idleTiledPage.displayInvalidationCount == configuredInvalidationCount)

        let imageContainer = DrawingCanvasView.AttachmentImageContainerView()
        defer {
            imageContainer.releaseImage(evictCachedVariants: true)
        }
        imageContainer.updateRasterScale(2)
        imageContainer.configure(
            attachment: lockedImage,
            storage: storage,
            pageSize: firstPage.pageSize,
            changed: {}
        )
        try await waitForRasterImage(in: imageContainer)
        #expect(imageContainer.hasVectorPDFView)
        #expect(imageContainer.isVectorPDFVisible)

        imageContainer.setDocumentTraversalActive(true)
        #expect(!imageContainer.isVectorPDFVisible)
        #expect(imageContainer.isVectorPDFRenderingSuspended)

        imageContainer.setDocumentTraversalActive(false)
        #expect(imageContainer.isVectorPDFVisible)
        #expect(!imageContainer.isVectorPDFRenderingSuspended)

        imageContainer.setDrawingInteractionActive(true)
        #expect(!imageContainer.isVectorPDFVisible)
        #expect(imageContainer.isVectorPDFRenderingSuspended)

        imageContainer.setDocumentTraversalActive(true)
        imageContainer.setDrawingInteractionActive(false)
        #expect(!imageContainer.isVectorPDFVisible)
        #expect(imageContainer.isVectorPDFRenderingSuspended)

        imageContainer.setDocumentTraversalActive(false)
        #expect(imageContainer.isVectorPDFVisible)
        #expect(!imageContainer.isVectorPDFRenderingSuspended)

        let deferredVectorContainer = DrawingCanvasView.AttachmentImageContainerView()
        deferredVectorContainer.setDocumentTraversalActive(true)
        deferredVectorContainer.configure(
            attachment: lockedImage,
            storage: storage,
            pageSize: firstPage.pageSize,
            changed: {}
        )
        #expect(!deferredVectorContainer.hasVectorPDFView)
        deferredVectorContainer.setDocumentTraversalActive(false)
        #expect(deferredVectorContainer.hasVectorPDFView)
        #expect(deferredVectorContainer.isVectorPDFVisible)
        deferredVectorContainer.releaseImage(evictCachedVariants: true)

        imageContainer.setImageLoadingEnabled(false)
        #expect(!imageContainer.hasVectorPDFView)
        #expect(!imageContainer.isVectorPDFVisible)

        imageContainer.setImageLoadingEnabled(true)
        #expect(imageContainer.hasVectorPDFView)
        #expect(imageContainer.isVectorPDFVisible)
    }

    @Test @MainActor func stagedDocumentVersionImportPreservesPagesAndDrawingsAndCreatesLatestVersion() async throws {
        let context = try makeInMemoryModelContext()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesVersionImport-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        let drawingStorage = DrawingStorageService(storage: storage)
        let thumbnailService = ThumbnailService(storage: storage, drawingStorage: drawingStorage)
        let importService = ImportExportService(
            storage: storage,
            drawingStorage: drawingStorage,
            thumbnailService: thumbnailService
        )
        try storage.prepareDirectories()

        let originalURL = rootURL.appendingPathComponent("Original.pdf")
        let originalRenderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try originalRenderer.writePDF(to: originalURL) { rendererContext in
            rendererContext.beginPage()
            "Original 1".draw(
                at: CGPoint(x: 72, y: 72),
                withAttributes: [.font: UIFont.systemFont(ofSize: 24)]
            )
            rendererContext.beginPage()
            "Original 2".draw(
                at: CGPoint(x: 72, y: 72),
                withAttributes: [.font: UIFont.systemFont(ofSize: 24)]
            )
        }

        let revisionURL = rootURL.appendingPathComponent("Revision.pdf")
        let revisionRenderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 792, height: 612))
        try revisionRenderer.writePDF(to: revisionURL) { rendererContext in
            rendererContext.beginPage()
            "Revision 1".draw(
                at: CGPoint(x: 72, y: 72),
                withAttributes: [.font: UIFont.systemFont(ofSize: 24)]
            )
            rendererContext.beginPage()
            "Revision 2".draw(
                at: CGPoint(x: 72, y: 72),
                withAttributes: [.font: UIFont.systemFont(ofSize: 24)]
            )
        }

        let folder = NotebookFolder(name: "Version Imports")
        context.insert(folder)
        try context.save()
        let originalStaging = storage.beginImportStagingTransaction()
        let imported = try await importService.importDocumentAsNote(
            from: originalURL,
            into: folder,
            staging: originalStaging
        )
        try context.save()
        try originalStaging.commit()

        let versionService = DocumentVersionService()
        for attachment in imported.attachments {
            attachment.documentVersionID = nil
            attachment.documentVersionName = nil
            attachment.documentVersionCreatedAt = nil
            attachment.documentVersionIsCurrent = nil
            attachment.documentVersionIsLatest = nil
        }
        let legacyAttachmentIDs = Set(imported.attachments.map(\.id))
        #expect(versionService.versions(in: imported.note).isEmpty)
        let originalBackground = try #require(imported.attachments.first { $0.kind == .image })
        let ordinaryImage = Attachment(
            kind: .image,
            displayName: "Pinned Overlay",
            originalFileName: "pinned-overlay.jpg",
            storedFileName: originalBackground.storedFileName,
            contentTypeIdentifier: UTType.jpeg.identifier,
            fileExtension: "jpg",
            x: 48,
            y: 48,
            width: 120,
            height: 120,
            isLocked: false,
            rendersBehindDrawing: true,
            createdAt: Date(timeIntervalSinceNow: 3_600)
        )
        imported.note.sortedPages[0].attachments.append(ordinaryImage)
        let originalPageIDs = imported.note.sortedPages.map(\.id)
        let originalDrawingFileNames = imported.note.sortedPages.map(\.drawingFileName)
        var drawingDataByFileName: [String: Data] = [:]
        for (index, page) in imported.note.sortedPages.enumerated() {
            try drawingStorage.save(
                makeTestDrawing(color: index == 0 ? .systemRed : .systemBlue, xOffset: CGFloat(index * 24)),
                for: page
            )
            drawingDataByFileName[page.drawingFileName] = try Data(contentsOf: drawingStorage.drawingURL(for: page))
        }
        try context.save()

        let revisionStaging = storage.beginImportStagingTransaction()
        let revision = try await importService.importDocumentVersion(
            from: revisionURL,
            into: imported.note,
            named: "Final Review",
            staging: revisionStaging
        )
        let revisionAttachments = versionService.attachments(for: revision.id, in: imported.note)

        #expect(revisionStaging.stagedFileNames().count == 3)
        #expect(!FileManager.default.fileExists(atPath: revisionStaging.finalDirectoryURL.path))
        #expect(revisionAttachments.allSatisfy {
            !FileManager.default.fileExists(atPath: storage.url(forRelativePath: $0.storedFileName).path)
        })

        try context.save()
        try revisionStaging.commit()

        #expect(imported.note.sortedPages.map(\.id) == originalPageIDs)
        #expect(imported.note.sortedPages.map(\.drawingFileName) == originalDrawingFileNames)
        #expect(imported.note.sortedPages.count == 2)
        for page in imported.note.sortedPages {
            let expectedDrawingData = try #require(drawingDataByFileName[page.drawingFileName])
            #expect(try Data(contentsOf: drawingStorage.drawingURL(for: page)) == expectedDrawingData)
        }

        let versions = versionService.versions(in: imported.note)
        #expect(versions.count == 2)
        #expect(versions.filter(\.isCurrent).map(\.id) == [revision.id])
        #expect(versions.filter(\.isLatest).map(\.id) == [revision.id])
        #expect(revision.name == "Final Review")
        #expect(revision.originalFileName == "Revision.pdf")
        let adoptedLegacyVersion = try #require(versions.first { $0.id != revision.id })
        #expect(Set(versionService.attachments(for: adoptedLegacyVersion.id, in: imported.note).map(\.id)) == legacyAttachmentIDs)
        #expect(!versionService.attachments(for: adoptedLegacyVersion.id, in: imported.note).contains {
            $0.documentVersionIsCurrent == true
        })
        let revisionBackgrounds = Set(revisionAttachments.filter { $0.kind == .image }.map(\.storedFileName))
        let visibleBackgrounds = Set(imported.note.sortedPages.flatMap {
            $0.lockedImageAttachments.map(\.storedFileName)
        })
        #expect(visibleBackgrounds == revisionBackgrounds)
        #expect(imported.note.sortedPages.allSatisfy { $0.lockedImageAttachments.count == 1 })
        let firstPageImages = imported.note.sortedPages[0].imageAttachments
        let revisionBackground = try #require(firstPageImages.first { $0.documentVersionID == revision.id })
        #expect(revisionBackground.createdAt < ordinaryImage.createdAt)
        #expect(firstPageImages.first?.id == revisionBackground.id)
        #expect(firstPageImages.last?.id == ordinaryImage.id)
        #expect(revisionAttachments.allSatisfy {
            FileManager.default.fileExists(atPath: storage.url(forRelativePath: $0.storedFileName).path)
        })
        #expect(versionService.attachments(for: adoptedLegacyVersion.id, in: imported.note).allSatisfy {
            FileManager.default.fileExists(atPath: storage.url(forRelativePath: $0.storedFileName).path)
        })
    }

    @Test @MainActor func rotatedPDFImportUsesDisplayedPageAspect() async throws {
        let context = try makeInMemoryModelContext()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesRotatedPDFImport-\(UUID().uuidString)", isDirectory: true)
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

        let pdfURL = rootURL.appendingPathComponent("Landscape-Rotated.pdf")
        try writeMinimalPDF(
            to: pdfURL,
            mediaBox: CGRect(x: 0, y: 0, width: 612, height: 792),
            rotationAngle: 90
        )

        let folder = NotebookFolder(name: "Class")
        context.insert(folder)
        try context.save()
        let imported = try await service.importDocumentAsNote(from: pdfURL, into: folder)
        try context.save()

        let page = try #require(imported.pages.first)
        let lockedImage = try #require(page.lockedImageAttachments.first)
        let imageURL = storage.url(forRelativePath: lockedImage.storedFileName)
        let importedPageImage = try #require(UIImage(contentsOfFile: imageURL.path))

        #expect(page.width > page.height)
        #expect(lockedImage.width == page.width)
        #expect(lockedImage.height == page.height)
        #expect(importedPageImage.size.width > importedPageImage.size.height)
    }

    @Test @MainActor func pdfPreviewDismantleCancelsLoadAndClearsDocument() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesPDFPreview-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let pdfURL = rootURL.appendingPathComponent("Preview.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 320, height: 420))
        try renderer.writePDF(to: pdfURL) { context in
            context.beginPage()
            "Preview".draw(at: CGPoint(x: 36, y: 48), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }

        let pdfView = PDFView()
        let coordinator = PDFPreviewView.Coordinator()
        coordinator.load(url: pdfURL, into: pdfView)

        PDFPreviewView.dismantleUIView(pdfView, coordinator: coordinator)
        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(coordinator.url == nil)
        #expect(pdfView.document == nil)
    }

    @Test func quickLookPreviewReloadsOnlyWhenItsURLChanges() {
        let firstURL = URL(fileURLWithPath: "/tmp/BeanNotes-Preview.docx")
        let secondURL = URL(fileURLWithPath: "/tmp/BeanNotes-Slides.pptx")
        let coordinator = QuickLookPreview.Coordinator(url: firstURL)

        #expect(!coordinator.updateURLIfNeeded(firstURL))
        #expect(coordinator.updateURLIfNeeded(secondURL))
        #expect(coordinator.url == secondURL)
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

    @Test @MainActor func cancelingDirectPDFImportRemovesStagedFiles() async throws {
        let context = try makeInMemoryModelContext()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesPDFImportCancel-\(UUID().uuidString)", isDirectory: true)
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

        let pdfURL = rootURL.appendingPathComponent("Cancel Import.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: pdfURL) { context in
            context.beginPage()
            "Page 1".draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            context.beginPage()
            "Page 2".draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            context.beginPage()
            "Page 3".draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
        }

        let folder = NotebookFolder(name: "Class")
        context.insert(folder)
        try context.save()

        var importTask: Task<ImportedDocumentNote, Error>?
        var progressMessages: [String] = []
        importTask = Task { @MainActor in
            try await service.importDocumentAsNote(from: pdfURL, into: folder) { _, message in
                progressMessages.append(message)
                if message.contains("page 2") {
                    importTask?.cancel()
                }
            }
        }

        do {
            _ = try await #require(importTask).value
            Issue.record("Expected import cancellation to throw.")
        } catch is CancellationError {
            let importsDirectory = try storage.directoryURL(for: .imports)
            let contents = try FileManager.default.contentsOfDirectory(
                at: importsDirectory,
                includingPropertiesForKeys: nil
            )

            #expect(contents.isEmpty)
            #expect(folder.notes.isEmpty)
            #expect(!progressMessages.contains { $0.contains("page 3") })
        }
    }

    @Test @MainActor func imageDataImportCreatesEditableBackgroundImagesAndCascadesPlacement() async throws {
        let modelContext = try makeInMemoryModelContext()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesImageDataImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let storage = LocalStorageService(rootURL: rootURL)
        let drawingStorage = DrawingStorageService(storage: storage)
        let service = ImportExportService(
            storage: storage,
            drawingStorage: drawingStorage,
            thumbnailService: ThumbnailService(storage: storage, drawingStorage: drawingStorage)
        )
        try storage.prepareDirectories()

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 800, height: 400),
            format: format
        ).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        }
        let imageData = try #require(image.pngData())
        let page = NotePage(pageOrder: 0, width: 612, height: 792)
        modelContext.insert(page)

        let firstImage = try await service.importImageData(
            imageData,
            named: "Layered Photo.jpg",
            into: page
        )
        try modelContext.save()
        let secondImage = try await service.importImageData(
            imageData,
            named: "Layered Photo.jpg",
            into: page
        )
        try modelContext.save()
        let firstFrame = firstImage.normalizedFrame(for: page.pageSize)
        let secondFrame = secondImage.normalizedFrame(for: page.pageSize)
        let pageBounds = CGRect(origin: .zero, size: page.pageSize)

        #expect(!firstImage.isLocked)
        #expect(firstImage.rendersBehindDrawing)
        #expect(firstImage.kind == .image)
        #expect(firstImage.fileExtension == "png")
        #expect(firstImage.originalFileName == "Layered Photo.png")
        #expect(pageBounds.contains(firstFrame))
        #expect(abs(firstFrame.width / firstFrame.height - 2) < 0.001)
        #expect(secondFrame.size == firstFrame.size)
        #expect(secondFrame.origin == CGPoint(x: firstFrame.minX + 24, y: firstFrame.minY + 24))
        #expect(page.imageAttachments.map(\.id).contains(firstImage.id))
        #expect(page.imageAttachments.map(\.id).contains(secondImage.id))
        #expect(FileManager.default.fileExists(
            atPath: storage.url(forRelativePath: firstImage.storedFileName).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: storage.url(forRelativePath: secondImage.storedFileName).path
        ))
    }

    @Test @MainActor func imageDataImportUsesDisplayOrientedAspectForRotatedJPEGs() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesOrientedImageDataImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let storage = LocalStorageService(rootURL: rootURL)
        let drawingStorage = DrawingStorageService(storage: storage)
        let service = ImportExportService(
            storage: storage,
            drawingStorage: drawingStorage,
            thumbnailService: ThumbnailService(storage: storage, drawingStorage: drawingStorage)
        )
        try storage.prepareDirectories()

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let sourceImage = UIGraphicsImageRenderer(
            size: CGSize(width: 400, height: 200),
            format: format
        ).image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        }
        let sourceCGImage = try #require(sourceImage.cgImage)

        for orientation in [6, 8] {
            let encodedData = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(
                encodedData as CFMutableData,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ))
            let properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
            CGImageDestinationAddImage(destination, sourceCGImage, properties as CFDictionary)
            try #require(CGImageDestinationFinalize(destination))

            let page = NotePage(pageOrder: orientation, width: 612, height: 792)
            let importedImage = try await service.importImageData(
                Data(referencing: encodedData),
                named: "Rotated-\(orientation).jpg",
                into: page
            )
            let frame = importedImage.normalizedFrame(for: page.pageSize)

            #expect(frame.height > frame.width)
            #expect(abs(frame.width / frame.height - 0.5) < 0.001)
            #expect(CGRect(origin: .zero, size: page.pageSize).contains(frame))
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

        let storedFileName = lockedImage.storedFileName
        lockedImage.documentVersionID = nil
        lockedImage.documentVersionName = nil
        lockedImage.documentVersionCreatedAt = nil
        lockedImage.documentVersionIsCurrent = nil
        lockedImage.documentVersionIsLatest = nil
        let adoptedVersion = try #require(DocumentVersionService().adoptLegacyVersionIfNeeded(
            in: imported.note,
            at: Date(timeIntervalSince1970: 200)
        ))
        #expect(adoptedVersion.kind == .image)
        #expect(adoptedVersion.pageCount == 1)
        #expect(adoptedVersion.isCurrent)
        #expect(adoptedVersion.isLatest)
        #expect(lockedImage.documentVersionID == adoptedVersion.id)
        #expect(lockedImage.storedFileName == storedFileName)
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
        let defaults = UserDefaults.standard
        let previousTheme = defaults.object(forKey: BeanNotesTheme.storageKey)
        defaults.set(BeanNotesTheme.standard.rawValue, forKey: BeanNotesTheme.storageKey)
        defer {
            if let previousTheme {
                defaults.set(previousTheme, forKey: BeanNotesTheme.storageKey)
            } else {
                defaults.removeObject(forKey: BeanNotesTheme.storageKey)
            }
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
                background: .plain(),
                width: 320,
                height: 420
            ),
            NotePage(
                pageOrder: 1,
                background: .plain(),
                width: 320,
                height: 420
            )
        ]
        note.pages.append(contentsOf: pages)
        context.insert(note)
        try context.save()
        #expect(pages.count == 2)
        try drawingStorage.save(makeTestDrawing(color: .systemRed, xOffset: 96), for: pages[0])

        let pdfURLs = try await service.exportNote(note, format: .pdf)
        let pngURLs = try await service.exportNote(note, format: .png)
        let jpegURLs = try await service.exportNote(note, format: .jpeg)
        let pagePDFURL = try await service.exportPage(pages[0], format: .pdf)

        #expect(pdfURLs.count == 1)
        #expect(pdfURLs.first?.pathExtension == "pdf")
        let pdfURL = try #require(pdfURLs.first)
        #expect(FileManager.default.fileExists(atPath: pdfURL.path))
        let pdfDocument = try #require(PDFDocument(url: pdfURL))
        #expect(pdfDocument.pageCount == 2)
        let firstPDFPage = try #require(pdfDocument.page(at: 0))
        let pdfPageImage = firstPDFPage.thumbnail(
            of: CGSize(width: 320, height: 420),
            for: .mediaBox
        )
        #expect(imageContainsDominantRedInk(pdfPageImage))
        let pagePDFDocument = try #require(PDFDocument(url: pagePDFURL))
        #expect(pagePDFDocument.pageCount == 1)
        let exportedPageImage = try #require(pagePDFDocument.page(at: 0)).thumbnail(
            of: CGSize(width: 320, height: 420),
            for: .mediaBox
        )
        #expect(imageContainsDominantRedInk(exportedPageImage))

        #expect(pngURLs.count == 2)
        #expect(pngURLs.allSatisfy { $0.pathExtension == "png" })
        #expect(pngURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let pngURL = try #require(pngURLs.first)
        let pngImage = try #require(UIImage(contentsOfFile: pngURL.path))
        #expect(imageContainsDominantRedInk(pngImage))
        let pngCGImage = try #require(pngImage.cgImage)
        #expect(pngCGImage.width == 960)
        #expect(pngCGImage.height == 1_260)

        #expect(jpegURLs.count == 2)
        #expect(jpegURLs.allSatisfy { $0.pathExtension == "jpg" })
        #expect(jpegURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let jpegURL = try #require(jpegURLs.first)
        let jpegImage = try #require(UIImage(contentsOfFile: jpegURL.path))
        #expect(imageContainsDominantRedInk(jpegImage))
        let jpegCGImage = try #require(jpegImage.cgImage)
        #expect(jpegCGImage.width == 960)
        #expect(jpegCGImage.height == 1_260)

        var sharingProgress: [Double] = []
        let sharedPNGURLs = try await service.exportNoteForSharing(note, format: .png) { fraction, _ in
            if let fraction {
                sharingProgress.append(fraction)
            }
        }
        #expect(sharedPNGURLs.count == 2)
        #expect(sharingProgress.contains { $0 > 0 && $0 < 0.5 })
        #expect(sharingProgress.contains { $0 > 0.5 && $0 < 1 })
        #expect(sharingProgress.last == 1)

        let exportDirectory = try storage.directoryURL(for: .exports)
        let exportFileNames = try FileManager.default.contentsOfDirectory(atPath: exportDirectory.path)
        #expect(!exportFileNames.contains { $0.contains(".partial.") })
    }

    @Test @MainActor func pageExportRejectsCorruptDrawingDataWhilePreviewStaysBestEffort() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesCorruptDrawingExport-\(UUID().uuidString)", isDirectory: true)
        defer {
            DrawingStorageService.clearCache()
            try? FileManager.default.removeItem(at: rootURL)
        }

        let storage = LocalStorageService(rootURL: rootURL)
        let drawingStorage = DrawingStorageService(storage: storage)
        let service = ImportExportService(
            storage: storage,
            drawingStorage: drawingStorage,
            thumbnailService: ThumbnailService(storage: storage, drawingStorage: drawingStorage)
        )
        try storage.prepareDirectories()

        let page = NotePage(
            pageOrder: 0,
            drawingFileName: "corrupt-export.drawing",
            background: .plain(),
            width: 320,
            height: 420
        )
        try Data("not-a-pencilkit-drawing".utf8).write(
            to: drawingStorage.drawingURL(for: page),
            options: [.atomic]
        )

        let previewDrawing = ThumbnailService.loadDrawing(
            fileName: page.drawingFileName,
            rootURL: rootURL
        )
        let preview = ThumbnailService.renderPageImage(
            snapshot: NotePageRenderSnapshot(page: page, theme: .standard),
            drawing: previewDrawing,
            rootURL: rootURL,
            scale: 1
        )
        #expect(previewDrawing.strokes.isEmpty)
        #expect(preview.size == page.pageSize)

        var didRejectExport = false
        do {
            _ = try await service.exportPage(page, format: .png)
        } catch {
            didRejectExport = true
        }
        #expect(didRejectExport)

        let exportDirectory = try storage.directoryURL(for: .exports)
        let exports = try FileManager.default.contentsOfDirectory(
            at: exportDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(exports.isEmpty)
    }

    @Test @MainActor func pdfExportRejectsUnavailablePageImagesWhilePreviewStaysBestEffort() async throws {
        let context = try makeInMemoryModelContext()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNotesLockedImageExport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let storage = LocalStorageService(rootURL: rootURL)
        let drawingStorage = DrawingStorageService(storage: storage)
        let service = ImportExportService(
            storage: storage,
            drawingStorage: drawingStorage,
            thumbnailService: ThumbnailService(storage: storage, drawingStorage: drawingStorage)
        )
        try storage.prepareDirectories()
        let corruptImage = try storage.saveData(
            Data("not-an-image".utf8),
            preferredName: "corrupt-page.png",
            contentType: .png,
            to: .imports
        )
        let unavailableImages = [
            (storedFileName: "Imports/missing-page.png", isLocked: true),
            (storedFileName: corruptImage.relativePath, isLocked: false)
        ]

        for (index, unavailableImage) in unavailableImages.enumerated() {
            let note = NoteDocument(title: "Unavailable Page \(index)")
            let page = NotePage(
                pageOrder: 0,
                background: .plain(),
                width: 320,
                height: 420
            )
            let attachment = Attachment(
                kind: .image,
                displayName: "Page image",
                originalFileName: "page.png",
                storedFileName: unavailableImage.storedFileName,
                contentTypeIdentifier: UTType.png.identifier,
                fileExtension: "png",
                x: 0,
                y: 0,
                width: 320,
                height: 420,
                isLocked: unavailableImage.isLocked,
                rendersBehindDrawing: unavailableImage.isLocked
            )
            page.attachments.append(attachment)
            note.pages.append(page)
            context.insert(note)
            try context.save()

            let preview = ThumbnailService.renderPageImage(
                snapshot: NotePageRenderSnapshot(page: page, theme: .standard),
                drawing: PKDrawing(),
                rootURL: rootURL,
                scale: 1
            )
            #expect(preview.size == page.pageSize)

            var didRejectExport = false
            do {
                _ = try await service.exportNote(note, format: .pdf)
            } catch {
                didRejectExport = true
            }
            #expect(didRejectExport)
        }

        let exportDirectory = try storage.directoryURL(for: .exports)
        let exports = try FileManager.default.contentsOfDirectory(
            at: exportDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(exports.isEmpty)
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
