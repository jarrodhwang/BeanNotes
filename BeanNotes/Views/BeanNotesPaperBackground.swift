//
//  BeanNotesPaperBackground.swift
//  BeanNotes
//

import SwiftUI

struct BeanNotesPaperBackground: View {
    var theme: BeanNotesTheme
    var baseColor: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            baseColor

            if let imageName = theme.paperTextureImageName {
                Image(imageName)
                    .resizable(resizingMode: .tile)
                    .blendMode(colorScheme == .dark ? .softLight : .multiply)
                    .opacity(colorScheme == .dark ? 0.07 : 0.16)
                    .accessibilityHidden(true)
            }
        }
        .allowsHitTesting(false)
    }
}
