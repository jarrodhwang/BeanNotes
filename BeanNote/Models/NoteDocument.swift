//
//  NoteDocument.swift
//  BeanNote
//

import Foundation
import SwiftData

@Model
final class NoteDocument {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var folder: NotebookFolder?

    @Relationship(deleteRule: .cascade, inverse: \NotePage.note)
    var pages: [NotePage]

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        folder: NotebookFolder? = nil,
        pages: [NotePage] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.folder = folder
        self.pages = pages
    }

    var sortedPages: [NotePage] {
        pages.sorted { lhs, rhs in
            if lhs.pageOrder == rhs.pageOrder {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.pageOrder < rhs.pageOrder
        }
    }

    func touch(at date: Date = Date()) {
        updatedAt = date
        folder?.updatedAt = date
    }
}
