//
//  NotebookFolder.swift
//  BeanNotes
//

import Foundation
import SwiftData

@Model
final class NotebookFolder {
    var id: UUID
    var name: String
    var colorHex: String
    var createdAt: Date
    var updatedAt: Date
    var archivedAt: Date? = nil

    @Relationship(deleteRule: .cascade, inverse: \NoteDocument.folder)
    var notes: [NoteDocument]

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = "#2563EB",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        archivedAt: Date? = nil,
        notes: [NoteDocument] = []
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
        self.notes = notes
    }

    var isArchived: Bool {
        archivedAt != nil
    }

    var sortedNotes: [NoteDocument] {
        notes.sorted(by: NoteDocument.libraryOrder)
    }

    var activeSortedNotes: [NoteDocument] {
        notes.filter { !$0.isInTrash }.sorted(by: NoteDocument.libraryOrder)
    }

    var activeNoteCount: Int {
        notes.lazy.filter { !$0.isInTrash }.count
    }

    static func archivedOrder(_ lhs: NotebookFolder, _ rhs: NotebookFolder) -> Bool {
        let lhsDate = lhs.archivedAt ?? .distantPast
        let rhsDate = rhs.archivedAt ?? .distantPast
        if lhsDate == rhsDate {
            let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if comparison == .orderedSame {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return comparison == .orderedAscending
        }
        return lhsDate > rhsDate
    }
}
