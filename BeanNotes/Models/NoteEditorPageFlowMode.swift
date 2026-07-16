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
            "Keep each page visually separate while scrolling through the note."
        case .scroll:
            "Use one continuous drawing canvas and extend it with the add-space button."
        }
    }

    var pageFlowMode: NoteEditorPageFlowMode {
        switch self {
        case .singlePage:
            .separated
        case .scroll:
            .seamless
        }
    }
}

/// Internal canvas modes, including raw values retained for legacy preference migration.
enum NoteEditorPageFlowMode: String, CaseIterable, Identifiable {
    static let storageKey = "noteEditorPageFlowMode"

    case singlePage
    case continuous
    case infinite
    case separated
    case seamless

    var id: String { rawValue }

    var label: String {
        switch self {
        case .singlePage:
            "One Page"
        case .continuous:
            "Scrollable + Add Button"
        case .infinite:
            "Scrollable + Auto Add"
        case .separated:
            "One Page"
        case .seamless:
            "Scrollable"
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
        case .separated:
            "Scroll through visually separated pages."
        case .seamless:
            "Draw across every section as one uninterrupted canvas."
        }
    }

    var migratedLayoutMode: NoteEditorPageLayoutMode {
        switch self {
        case .singlePage, .separated:
            .singlePage
        case .continuous, .infinite, .seamless:
            .scroll
        }
    }

    func pageStatusText(currentPage: Int, totalPages: Int) -> String {
        if self == .seamless {
            return "Continuous canvas"
        }
        return "Page \(currentPage) / \(totalPages)"
    }
}
