//
//  NoteEditorPageFlowMode.swift
//  BeanNotes
//

import Foundation

enum NoteEditorPageLayoutMode: String, CaseIterable, Identifiable {
    static let storageKey = "noteEditorPageLayoutMode"

    case singlePage
    case scroll

    var id: String { rawValue }

    var label: String {
        switch self {
        case .singlePage:
            "One Page"
        case .scroll:
            "Scrollable"
        }
    }

    var description: String {
        switch self {
        case .singlePage:
            "Show one page at a time and move with page buttons."
        case .scroll:
            "Stack pages vertically with a small gap between pages."
        }
    }
}

enum NoteEditorPageCreationMode: String, CaseIterable, Identifiable {
    static let storageKey = "noteEditorPageCreationMode"

    case manual
    case auto

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual:
            "Add Button"
        case .auto:
            "Auto Add"
        }
    }

    var description: String {
        switch self {
        case .manual:
            "Use the add-page button when you want another page."
        case .auto:
            "Keep a blank page ready as you scroll downward."
        }
    }
}

enum NoteEditorPageFlowMode: String, CaseIterable, Identifiable {
    static let storageKey = "noteEditorPageFlowMode"

    case singlePage
    case continuous
    case infinite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .singlePage:
            "One Page"
        case .continuous:
            "Scrollable + Add Button"
        case .infinite:
            "Scrollable + Auto Add"
        }
    }

    var description: String {
        switch self {
        case .singlePage:
            "Show one page at a time with page buttons."
        case .continuous:
            "Scroll pages vertically and add pages manually."
        case .infinite:
            "Scroll downward while BeanNotes keeps one blank page ready at the bottom."
        }
    }

    var layoutMode: NoteEditorPageLayoutMode {
        switch self {
        case .singlePage:
            .singlePage
        case .continuous, .infinite:
            .scroll
        }
    }

    var creationMode: NoteEditorPageCreationMode {
        switch self {
        case .singlePage, .continuous:
            .manual
        case .infinite:
            .auto
        }
    }

    var showsOnePageAtATime: Bool {
        self == .singlePage
    }

    var autoAddsPages: Bool {
        self == .infinite
    }

    func pageStatusText(currentPage: Int, totalPages: Int) -> String {
        switch self {
        case .singlePage, .continuous:
            "Page \(currentPage) / \(totalPages)"
        case .infinite:
            "Page \(currentPage) / \(totalPages)+"
        }
    }

    static func combined(
        layoutMode: NoteEditorPageLayoutMode,
        creationMode: NoteEditorPageCreationMode
    ) -> NoteEditorPageFlowMode {
        switch layoutMode {
        case .singlePage:
            .singlePage
        case .scroll:
            creationMode == .auto ? .infinite : .continuous
        }
    }
}
