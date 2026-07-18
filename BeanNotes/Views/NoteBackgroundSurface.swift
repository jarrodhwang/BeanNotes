//
//  NoteBackgroundSurface.swift
//  BeanNotes
//

import SwiftUI

struct NoteBackgroundSurface: View {
    @Environment(\.beanNotesTheme) private var beanNotesTheme
    @AppStorage(NoteBackground.showsBeanArtworkKey) private var showsBeanArtwork = false
    @AppStorage(NoteBackground.showsBlueberryArtworkKey) private var showsBlueberryArtwork = true

    var background: NoteBackground
    var pageID: UUID? = nil
    var artworkVisibilityOverride: Bool? = nil

    private var showsThemeArtwork: Bool {
        if let artworkVisibilityOverride {
            return artworkVisibilityOverride
        }

        return switch beanNotesTheme {
        case .standard:
            false
        case .bean:
            showsBeanArtwork
        case .blueberry:
            showsBlueberryArtwork
        }
    }

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            NoteBackgroundRenderer.draw(
                background: background,
                theme: beanNotesTheme,
                showsBeanArtwork: showsThemeArtwork,
                pageID: pageID,
                in: rect,
                context: &context
            )
        }
        .accessibilityHidden(true)
    }
}
