//
//  NoteEditorPageFlowMode.swift
//  BeanNote
//

import Foundation

enum NoteEditorPageFlowMode: String, CaseIterable, Identifiable {
    case singlePage
    case continuous
    case infinite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .singlePage:
            "Single Page"
        case .continuous:
            "Continuous Pages"
        case .infinite:
            "Auto-Add Pages"
        }
    }

    var description: String {
        switch self {
        case .singlePage:
            "Show one page at a time with page buttons."
        case .continuous:
            "Scroll pages vertically with a small gap."
        case .infinite:
            "Scroll down to create more blank pages."
        }
    }

    var autoAddsPages: Bool {
        self == .infinite
    }
}
