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

    @Relationship(deleteRule: .cascade, inverse: \NoteDocument.folder)
    var notes: [NoteDocument]

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = "#2563EB",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        notes: [NoteDocument] = []
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.notes = notes
    }

    var sortedNotes: [NoteDocument] {
        notes.sorted(by: NoteDocument.libraryOrder)
    }
}
