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
    var trashedAt: Date? = nil
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
        trashedAt: Date? = nil,
        folder: NotebookFolder? = nil,
        pages: [NotePage] = []
    ) {
        self.id = id
        self.title = title
        self.searchableText = searchableText
        self.searchIndexUpdatedAt = searchIndexUpdatedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.trashedAt = trashedAt
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

    var isInTrash: Bool {
        trashedAt != nil
    }

    var trashExpirationDate: Date? {
        trashedAt.map(NoteTrashPolicy.expirationDate(for:))
    }

    static func libraryOrder(_ lhs: NoteDocument, _ rhs: NoteDocument) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.createdAt > rhs.createdAt
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
                    let language = CodeSnippetLanguage(
                        rawValue: $0.codeSnippetLanguageRaw ?? ""
                    )?.label ?? ""
                    let source = page.searchIndexUpdatedAt == nil
                        ? CodeSnippetSearchIndex.sourceProjection($0.codeSnippetText ?? "")
                        : ""
                    return NoteSearchText.join([
                        "\($0.displayName) \($0.originalFileName) \($0.kind.displayName) \(language)",
                        source
                    ])
                }
            }
        )
    }

    func matchesSearch(_ rawQuery: String) -> Bool {
        NoteSearchText.matches(rawQuery, in: NoteSearchText.join([title, searchableText]))
    }
}

enum NoteTrashPolicy {
    nonisolated static let retentionDays = 30
    nonisolated static let retentionInterval: TimeInterval = TimeInterval(retentionDays * 24 * 60 * 60)

    nonisolated static func expirationDate(for trashedAt: Date) -> Date {
        trashedAt.addingTimeInterval(retentionInterval)
    }

    nonisolated static func shouldPurge(trashedAt: Date?, now: Date = Date()) -> Bool {
        guard let trashedAt else { return false }
        return expirationDate(for: trashedAt) <= now
    }

    nonisolated static func remainingDays(trashedAt: Date?, now: Date = Date()) -> Int? {
        guard let trashedAt else { return nil }
        let remaining = expirationDate(for: trashedAt).timeIntervalSince(now)
        return max(0, Int(ceil(remaining / (24 * 60 * 60))))
    }
}
