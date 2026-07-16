//
//  NotePageEditCommand.swift
//  BeanNotes
//

import Foundation

enum NotePagePlacement: Equatable, Sendable {
    case above
    case below
}

struct NotePageEditChange {
    enum Kind: Equatable {
        case added(placement: NotePagePlacement)
        case removed
    }

    let page: NotePage
    let originalIndex: Int
    let priorSelectedPageID: UUID?
    let kind: Kind
}

struct NotePageEditResult {
    let change: NotePageEditChange
    let selectedPageID: UUID?
}

enum NotePageEditCommand {
    static func applyAdd(
        relativeTo targetPage: NotePage,
        placement: NotePagePlacement,
        in note: NoteDocument,
        selectedPageID: UUID?
    ) -> NotePageEditResult? {
        var orderedPages = note.sortedPages
        guard let targetIndex = orderedPages.firstIndex(where: { $0.id == targetPage.id }) else {
            return nil
        }

        let insertionIndex = placement == .above ? targetIndex : targetIndex + 1
        let addedPage = NotePage(
            pageOrder: insertionIndex,
            background: targetPage.background,
            width: targetPage.normalizedWidth,
            height: targetPage.normalizedHeight
        )
        orderedPages.insert(addedPage, at: insertionIndex)
        note.pages.append(addedPage)
        applyPageOrder(orderedPages)

        let change = NotePageEditChange(
            page: addedPage,
            originalIndex: insertionIndex,
            priorSelectedPageID: selectedPageID,
            kind: .added(placement: placement)
        )
        return NotePageEditResult(change: change, selectedPageID: addedPage.id)
    }

    static func applyRemove(
        _ page: NotePage,
        from note: NoteDocument,
        selectedPageID: UUID?
    ) -> NotePageEditResult? {
        var orderedPages = note.sortedPages
        guard orderedPages.count > 1,
              let removalIndex = orderedPages.firstIndex(where: { $0.id == page.id }) else {
            return nil
        }

        let removedPage = orderedPages.remove(at: removalIndex)
        note.pages.removeAll { $0.id == removedPage.id }
        applyPageOrder(orderedPages)

        let change = NotePageEditChange(
            page: removedPage,
            originalIndex: removalIndex,
            priorSelectedPageID: selectedPageID,
            kind: .removed
        )
        return NotePageEditResult(
            change: change,
            selectedPageID: selectionAfterRemoving(
                removedPage,
                from: orderedPages,
                removalIndex: removalIndex,
                priorSelectedPageID: selectedPageID
            )
        )
    }

    static func undo(
        _ change: NotePageEditChange,
        in note: NoteDocument
    ) -> NotePageEditResult? {
        switch change.kind {
        case .added:
            var orderedPages = note.sortedPages
            guard orderedPages.count > 1,
                  let removalIndex = orderedPages.firstIndex(where: { $0.id == change.page.id }) else {
                return nil
            }

            orderedPages.remove(at: removalIndex)
            note.pages.removeAll { $0.id == change.page.id }
            applyPageOrder(orderedPages)
            return NotePageEditResult(
                change: change,
                selectedPageID: restoredSelection(
                    change.priorSelectedPageID,
                    in: orderedPages
                )
            )

        case .removed:
            guard !note.pages.contains(where: { $0.id == change.page.id }) else {
                return nil
            }

            var orderedPages = note.sortedPages
            let insertionIndex = min(max(change.originalIndex, 0), orderedPages.count)
            orderedPages.insert(change.page, at: insertionIndex)
            note.pages.append(change.page)
            applyPageOrder(orderedPages)
            return NotePageEditResult(
                change: change,
                selectedPageID: restoredSelection(
                    change.priorSelectedPageID,
                    in: orderedPages
                )
            )
        }
    }

    static func redo(
        _ change: NotePageEditChange,
        in note: NoteDocument
    ) -> NotePageEditResult? {
        switch change.kind {
        case .added:
            guard !note.pages.contains(where: { $0.id == change.page.id }) else {
                return nil
            }

            var orderedPages = note.sortedPages
            let insertionIndex = min(max(change.originalIndex, 0), orderedPages.count)
            orderedPages.insert(change.page, at: insertionIndex)
            note.pages.append(change.page)
            applyPageOrder(orderedPages)
            return NotePageEditResult(change: change, selectedPageID: change.page.id)

        case .removed:
            var orderedPages = note.sortedPages
            guard orderedPages.count > 1,
                  let removalIndex = orderedPages.firstIndex(where: { $0.id == change.page.id }) else {
                return nil
            }

            orderedPages.remove(at: removalIndex)
            note.pages.removeAll { $0.id == change.page.id }
            applyPageOrder(orderedPages)
            return NotePageEditResult(
                change: change,
                selectedPageID: selectionAfterRemoving(
                    change.page,
                    from: orderedPages,
                    removalIndex: removalIndex,
                    priorSelectedPageID: change.priorSelectedPageID
                )
            )
        }
    }

    private static func applyPageOrder(_ orderedPages: [NotePage]) {
        for (index, page) in orderedPages.enumerated() {
            page.pageOrder = index
        }
    }

    private static func selectionAfterRemoving(
        _ removedPage: NotePage,
        from remainingPages: [NotePage],
        removalIndex: Int,
        priorSelectedPageID: UUID?
    ) -> UUID? {
        if let priorSelectedPageID,
           priorSelectedPageID != removedPage.id,
           remainingPages.contains(where: { $0.id == priorSelectedPageID }) {
            return priorSelectedPageID
        }

        guard !remainingPages.isEmpty else { return nil }
        return remainingPages[min(removalIndex, remainingPages.count - 1)].id
    }

    private static func restoredSelection(
        _ priorSelectedPageID: UUID?,
        in orderedPages: [NotePage]
    ) -> UUID? {
        guard let priorSelectedPageID else { return nil }
        return orderedPages.contains(where: { $0.id == priorSelectedPageID })
            ? priorSelectedPageID
            : orderedPages.first?.id
    }
}
