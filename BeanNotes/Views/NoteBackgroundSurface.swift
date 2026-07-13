//
//  NoteBackgroundSurface.swift
//  BeanNotes
//

import SwiftUI

struct NoteBackgroundSurface: View {
    @Environment(\.beanNotesTheme) private var beanNotesTheme

    var background: NoteBackground
    var pageID: UUID? = nil

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            NoteBackgroundRenderer.draw(
                background: background,
                theme: beanNotesTheme,
                pageID: pageID,
                in: rect,
                context: &context
            )
        }
        .accessibilityHidden(true)
    }
}
