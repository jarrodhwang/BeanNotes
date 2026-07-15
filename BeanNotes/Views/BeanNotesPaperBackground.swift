//
//  BeanNotesPaperBackground.swift
//  BeanNotes
//

import SwiftUI

struct BeanNotesPaperBackground: View {
    var theme: BeanNotesTheme
    var baseColor: Color
    var showsMascotWatermark = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency

    var body: some View {
        ZStack {
            baseColor

            if !accessibilityReduceTransparency,
               let imageName = theme.paperTextureImageName {
                Image(imageName)
                    .resizable(resizingMode: .tile)
                    .blendMode(colorScheme == .dark ? .softLight : .multiply)
                    .opacity(colorScheme == .dark ? 0.07 : 0.16)
                    .accessibilityHidden(true)
            }

            if let watermarkImageName = theme.mascotWatermarkImageName,
               showsMascotWatermark,
               !accessibilityReduceTransparency {
                GeometryReader { proxy in
                    let imageWidth = min(220, max(108, proxy.size.width * 0.58))

                    Image(watermarkImageName)
                        .resizable()
                        .scaledToFit()
                        .saturation(colorScheme == .dark ? 0.32 : 0.55)
                        .opacity(colorScheme == .dark ? 0.08 : 0.11)
                        .frame(width: imageWidth)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.trailing, 16)
                        .padding(.bottom, 10)
                        .accessibilityHidden(true)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
