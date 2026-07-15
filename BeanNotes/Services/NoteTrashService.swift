//
//  NoteTrashService.swift
//  BeanNotes
//

import Foundation
import SwiftData

struct NoteTrashDeletionResult: Equatable {
    var deletedNoteIDs: Set<UUID>
    var cleanupReport: LocalStorageCleanupReport
}

@MainActor
struct NoteTrashService {
    var storage = LocalStorageService()

    @discardableResult
    func moveToTrash(
        _ notes: [NoteDocument],
        at date: Date = Date(),
        in modelContext: ModelContext
    ) throws -> Set<UUID> {
        let notes = uniqueNotes(notes).filter { !$0.isInTrash }
        guard !notes.isEmpty else { return [] }

        for note in notes {
            note.trashedAt = date
            note.folder?.updatedAt = date
        }

        try saveOrRollback(modelContext)
        return Set(notes.map(\.id))
    }

    @discardableResult
    func restore(
        _ notes: [NoteDocument],
        to folder: NotebookFolder,
        at date: Date = Date(),
        in modelContext: ModelContext
    ) throws -> Set<UUID> {
        let notes = uniqueNotes(notes).filter(\.isInTrash)
        guard !notes.isEmpty else { return [] }

        for note in notes {
            note.folder?.updatedAt = date
            note.folder = folder
            note.trashedAt = nil
        }
        folder.updatedAt = date

        try saveOrRollback(modelContext)
        return Set(notes.map(\.id))
    }

    @discardableResult
    func moveContentsToTrashAndDelete(
        _ folder: NotebookFolder,
        at date: Date = Date(),
        in modelContext: ModelContext
    ) throws -> Set<UUID> {
        let notes = uniqueNotes(folder.notes)

        for note in notes {
            if !note.isInTrash {
                note.trashedAt = date
            }
            note.folder = nil
        }

        modelContext.delete(folder)
        try saveOrRollback(modelContext)
        return Set(notes.map(\.id))
    }

    func permanentlyDelete(
        _ notes: [NoteDocument],
        in modelContext: ModelContext
    ) throws -> NoteTrashDeletionResult {
        let notes = uniqueNotes(notes)
        guard !notes.isEmpty else {
            return NoteTrashDeletionResult(deletedNoteIDs: [], cleanupReport: LocalStorageCleanupReport())
        }

        let cleanupTarget = LocalStorageCleanupTarget(notes: notes)
        let deletedNoteIDs = Set(notes.map(\.id))

        for note in notes {
            modelContext.delete(note)
        }

        try saveOrRollback(modelContext)
        let cleanupReport = storage.removeStoredFiles(matching: cleanupTarget)
        return NoteTrashDeletionResult(deletedNoteIDs: deletedNoteIDs, cleanupReport: cleanupReport)
    }

    func purgeExpiredNotes(
        in modelContext: ModelContext,
        now: Date = Date()
    ) throws -> NoteTrashDeletionResult {
        let notes = try modelContext.fetch(FetchDescriptor<NoteDocument>())
            .filter { NoteTrashPolicy.shouldPurge(trashedAt: $0.trashedAt, now: now) }
        return try permanentlyDelete(notes, in: modelContext)
    }

    private func uniqueNotes(_ notes: [NoteDocument]) -> [NoteDocument] {
        var seenIDs: Set<UUID> = []
        return notes.filter { seenIDs.insert($0.id).inserted }
    }

    private func saveOrRollback(_ modelContext: ModelContext) throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
