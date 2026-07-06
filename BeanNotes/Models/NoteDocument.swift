//
//  NoteDocument.swift
//  BeanNotes
//

import Foundation
import SwiftData

@Model
final class NoteDocument {
    var id: UUID
    var title: String
    var searchableText: String = ""
    var searchIndexUpdatedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var folder: NotebookFolder?

    @Relationship(deleteRule: .cascade, inverse: \NotePage.note)
    var pages: [NotePage]

    init(
        id: UUID = UUID(),
        title: String,
        searchableText: String = "",
        searchIndexUpdatedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        folder: NotebookFolder? = nil,
        pages: [NotePage] = []
    ) {
        self.id = id
        self.title = title
        self.searchableText = searchableText
        self.searchIndexUpdatedAt = searchIndexUpdatedAt
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

    func markSearchIndexStale() {
        searchIndexUpdatedAt = nil
    }

    func rebuildSearchableText() {
        searchableText = NoteSearchText.join(
            sortedPages.map(\.searchableText) + sortedPages.flatMap { page in
                page.attachments.map {
                    "\($0.displayName) \($0.originalFileName) \($0.kind.displayName)"
                }
            }
        )
    }

    func matchesSearch(_ rawQuery: String) -> Bool {
        NoteSearchText.matches(rawQuery, in: NoteSearchText.join([title, searchableText]))
    }
}
