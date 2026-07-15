//
//  FolderArchiveService.swift
//  BeanNotes
//

import Foundation
import SwiftData

@MainActor
struct FolderArchiveService {
    @discardableResult
    func archive(
        _ folder: NotebookFolder,
        at date: Date = Date(),
        in modelContext: ModelContext
    ) throws -> Bool {
        guard !folder.isArchived else { return false }

        folder.archivedAt = date
        try saveOrRollback(modelContext)
        return true
    }

    @discardableResult
    func unarchive(
        _ folder: NotebookFolder,
        in modelContext: ModelContext
    ) throws -> Bool {
        guard folder.isArchived else { return false }

        folder.archivedAt = nil
        try saveOrRollback(modelContext)
        return true
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
