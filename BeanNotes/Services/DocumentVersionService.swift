//
//  DocumentVersionService.swift
//  BeanNotes
//

import CoreGraphics
import Foundation

struct NoteDocumentVersion: Identifiable, Equatable {
    var id: UUID
    /// The chronological position of this version, starting with 1 for the
    /// originally imported document. This is derived from immutable version
    /// metadata so old notes do not need a schema migration.
    var displayOrder: Int
    var name: String
    var originalFileName: String
    var kind: AttachmentKind
    var createdAt: Date
    var pageCount: Int
    var isCurrent: Bool
    var isLatest: Bool
}

/// Manages version metadata on immutable imported attachments. Keeping every
/// version's files attached to its note lets the existing backup, trash, and
/// storage cleanup paths continue to account for those files.
@MainActor
struct DocumentVersionService {
    var storage = LocalStorageService()

    func versions(in note: NoteDocument) -> [NoteDocumentVersion] {
        let grouped = Dictionary(grouping: versionAttachments(in: note)) { attachment in
            attachment.documentVersionID!
        }

        let resolvedVersions: [NoteDocumentVersion] = grouped.compactMap { id, attachments in
            guard let representative = representativeAttachment(in: attachments) else { return nil }
            let backgroundPages = Set(
                attachments.compactMap { attachment -> UUID? in
                    guard attachment.kind == .image,
                          attachment.isLocked,
                          attachment.rendersBehindDrawing else {
                        return nil
                    }
                    return attachment.page?.id
                }
            )
            let storedName = attachments
                .compactMap(\.documentVersionName)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackName = representative.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let originalPDF = attachments.first { $0.kind == .pdf }
            let vectorSourceName = attachments
                .compactMap(\.vectorSourceStoredFileName)
                .first
                .map { URL(fileURLWithPath: $0).lastPathComponent }
            let isPDFVersion = originalPDF != nil || vectorSourceName != nil
            let resolvedName = (storedName?.isEmpty == false ? storedName : nil)
                ?? (fallbackName.isEmpty ? "Imported Document" : fallbackName)

            return NoteDocumentVersion(
                id: id,
                displayOrder: 0,
                name: resolvedName,
                originalFileName: originalPDF?.originalFileName
                    ?? vectorSourceName
                    ?? representative.originalFileName,
                kind: isPDFVersion ? .pdf : .image,
                createdAt: attachments.compactMap(\.documentVersionCreatedAt).min()
                    ?? attachments.map(\.createdAt).min()
                    ?? .distantPast,
                pageCount: backgroundPages.count,
                isCurrent: attachments.contains { $0.documentVersionIsCurrent == true },
                isLatest: attachments.contains { $0.documentVersionIsLatest == true }
            )
        }
        .sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString > rhs.id.uuidString
            }
            return lhs.createdAt > rhs.createdAt
        }

        // The list is shown newest first, while its number describes the
        // import sequence: the original document is Version 1 and each later
        // replacement increments that number.
        return resolvedVersions.enumerated().map { offset, version in
            var version = version
            version.displayOrder = resolvedVersions.count - offset
            return version
        }
    }

    func attachments(for versionID: UUID, in note: NoteDocument) -> [Attachment] {
        versionAttachments(in: note).filter { $0.documentVersionID == versionID }
    }

    @discardableResult
    func registerImportedVersion(
        attachments: [Attachment],
        named proposedName: String,
        in note: NoteDocument,
        createdAt: Date = Date(),
        makeLatest: Bool = true
    ) -> NoteDocumentVersion? {
        let attachedIDs = Set(note.pages.flatMap(\.attachments).map(\.id))
        let importedAttachments = attachments.filter { attachedIDs.contains($0.id) }
        guard !importedAttachments.isEmpty else { return nil }

        let versionID = UUID()
        let representative = representativeAttachment(in: importedAttachments)
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = representative?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let versionName = trimmedName.isEmpty
            ? (fallbackName.isEmpty ? "Imported Document" : fallbackName)
            : trimmedName

        for attachment in versionAttachments(in: note) {
            attachment.documentVersionIsCurrent = false
            if makeLatest {
                attachment.documentVersionIsLatest = false
            }
        }

        for attachment in importedAttachments {
            attachment.documentVersionID = versionID
            attachment.documentVersionName = versionName
            attachment.documentVersionCreatedAt = createdAt
            attachment.documentVersionIsCurrent = true
            attachment.documentVersionIsLatest = makeLatest
        }

        invalidateDerivedPageData(in: note)
        note.touch(at: createdAt)
        return versions(in: note).first { $0.id == versionID }
    }

    /// Lazily adopts the pre-versioning PDF/image background shape without
    /// copying files. Notes containing multiple independent PDFs are left alone
    /// because treating appended documents as alternate versions would hide data.
    @discardableResult
    func adoptLegacyVersionIfNeeded(in note: NoteDocument, at date: Date = Date()) -> NoteDocumentVersion? {
        let existingVersions = versions(in: note)
        if let existing = existingVersions.first {
            let latestID = existingVersions.first(where: \.isLatest)?.id ?? existing.id
            let currentID = existingVersions.first(where: \.isCurrent)?.id ?? latestID
            let hasLatest = existingVersions.contains(where: \.isLatest)
            let hasCurrent = existingVersions.contains(where: \.isCurrent)
            for attachment in versionAttachments(in: note) {
                if !hasLatest {
                    attachment.documentVersionIsLatest = attachment.documentVersionID == latestID
                }
                if !hasCurrent {
                    attachment.documentVersionIsCurrent = attachment.documentVersionID == currentID
                }
            }
            return versions(in: note).first { $0.id == currentID } ?? existing
        }

        let attachments = note.sortedPages.flatMap(\.attachments)
        let vectorBackgrounds = attachments.filter { attachment in
            attachment.documentVersionID == nil
                && attachment.kind == .image
                && attachment.isLocked
                && attachment.rendersBehindDrawing
                && attachment.vectorSourceStoredFileName?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty == false
        }
        let vectorSourcePaths = Set(vectorBackgrounds.compactMap(\.vectorSourceStoredFileName))

        if vectorSourcePaths.count == 1, let sourcePath = vectorSourcePaths.first {
            let backgrounds = vectorBackgrounds.filter { $0.vectorSourceStoredFileName == sourcePath }
            let sources = attachments.filter {
                $0.documentVersionID == nil
                    && $0.kind == .pdf
                    && $0.storedFileName == sourcePath
            }
            let createdAt = (backgrounds + sources).map(\.createdAt).min() ?? date
            return registerImportedVersion(
                attachments: backgrounds + sources,
                named: sources.first?.displayName ?? note.title,
                in: note,
                createdAt: min(createdAt, date)
            )
        }

        guard note.sortedPages.count == 1, let page = note.sortedPages.first else { return nil }
        let fullPageImages = page.attachments.filter { attachment in
            guard attachment.documentVersionID == nil,
                  attachment.kind == .image,
                  attachment.isLocked,
                  attachment.rendersBehindDrawing else {
                return false
            }
            let frame = attachment.normalizedFrame(for: page.pageSize)
            return abs(frame.minX) < 0.5
                && abs(frame.minY) < 0.5
                && abs(frame.width - page.pageSize.width) < 0.5
                && abs(frame.height - page.pageSize.height) < 0.5
        }
        guard fullPageImages.count == 1, let image = fullPageImages.first else { return nil }

        return registerImportedVersion(
            attachments: [image],
            named: image.displayName,
            in: note,
            createdAt: min(image.createdAt, date)
        )
    }

    @discardableResult
    func useVersion(_ versionID: UUID, in note: NoteDocument) -> Bool {
        let target = attachments(for: versionID, in: note)
        guard !target.isEmpty else { return false }

        for attachment in versionAttachments(in: note) {
            attachment.documentVersionIsCurrent = attachment.documentVersionID == versionID
        }

        invalidateDerivedPageData(in: note)
        note.touch()
        return true
    }

    @discardableResult
    func makeLatest(_ versionID: UUID, in note: NoteDocument) -> Bool {
        guard useVersion(versionID, in: note) else { return false }

        for attachment in versionAttachments(in: note) {
            attachment.documentVersionIsLatest = attachment.documentVersionID == versionID
        }
        note.touch()
        return true
    }

    @discardableResult
    func renameVersion(_ versionID: UUID, to proposedName: String, in note: NoteDocument) -> Bool {
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = attachments(for: versionID, in: note)
        guard !trimmedName.isEmpty, !target.isEmpty else { return false }

        let now = Date()
        for attachment in target {
            attachment.documentVersionName = trimmedName
            attachment.updatedAt = now
        }
        note.touch(at: now)
        return true
    }

    /// Detaches a version and chooses safe current/latest fallbacks. The caller
    /// remains responsible for deleting the detached models and stored files only
    /// after its ModelContext save succeeds.
    func removeVersion(_ versionID: UUID, from note: NoteDocument) -> [Attachment] {
        let removed = attachments(for: versionID, in: note)
        guard !removed.isEmpty else { return [] }

        let removedWasCurrent = removed.contains { $0.documentVersionIsCurrent == true }
        let removedWasLatest = removed.contains { $0.documentVersionIsLatest == true }
        let remainingVersions = versions(in: note).filter { $0.id != versionID }
        let existingLatest = remainingVersions.first { $0.isLatest }
        let latestFallback = existingLatest ?? remainingVersions.first

        if removedWasLatest, let latestFallback {
            for attachment in versionAttachments(in: note) where attachment.documentVersionID != versionID {
                attachment.documentVersionIsLatest = attachment.documentVersionID == latestFallback.id
            }
        }

        if removedWasCurrent, let currentFallback = latestFallback ?? remainingVersions.first {
            for attachment in versionAttachments(in: note) where attachment.documentVersionID != versionID {
                attachment.documentVersionIsCurrent = attachment.documentVersionID == currentFallback.id
            }
        }

        invalidateDerivedPageData(in: note)
        for page in note.pages {
            page.attachments.removeAll { $0.documentVersionID == versionID }
        }
        note.touch()
        return removed
    }

    private func versionAttachments(in note: NoteDocument) -> [Attachment] {
        note.sortedPages
            .flatMap(\.attachments)
            .filter { $0.documentVersionID != nil }
    }

    private func representativeAttachment(in attachments: [Attachment]) -> Attachment? {
        attachments.first { $0.kind == .pdf }
            ?? attachments.first { $0.kind == .image && $0.rendersBehindDrawing }
            ?? attachments.first
    }

    private func invalidateDerivedPageData(in note: NoteDocument) {
        for page in note.pages where page.attachments.contains(where: { $0.documentVersionID != nil }) {
            if let thumbnailFileName = page.thumbnailFileName {
                ImageMemoryCache.shared.removeImages(for: storage.url(forRelativePath: thumbnailFileName))
            }
            page.thumbnailFileName = nil
            page.markSearchIndexStale()
        }
        note.markSearchIndexStale()
    }
}
