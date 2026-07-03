//
//  NoteBackgroundPickerView.swift
//  BeanNote
//

import SwiftUI

struct NoteBackgroundPickerView: View {
    @Binding var styleRaw: String
    @Binding var colorHex: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Type", selection: $styleRaw) {
                ForEach(NoteBackgroundStyle.allCases) { style in
                    Text(style.label).tag(style.rawValue)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 12) {
                Text("Color")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(NoteBackground.colorPresets) { preset in
                        Button {
                            colorHex = preset.colorHex
                        } label: {
                            colorSwatch(preset)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.name)
                    }
                }
            }

            ColorPicker(
                "More Colors",
                selection: Binding(
                    get: { Color(hex: colorHex) },
                    set: { colorHex = $0.hexRGB }
                ),
                supportsOpacity: false
            )
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 42, maximum: 42), spacing: 12)]
    }

    private func colorSwatch(_ preset: NoteBackgroundColorPreset) -> some View {
        ZStack {
            Circle()
                .fill(Color(hex: preset.colorHex))
                .frame(width: 34, height: 34)
                .overlay {
                    Circle()
                        .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
                }

            if colorHex.caseInsensitiveCompare(preset.colorHex) == .orderedSame {
                Circle()
                    .stroke(Color.accentColor, lineWidth: 3)
                    .frame(width: 42, height: 42)

                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(readableCheckmarkColor(for: preset.colorHex))
            }
        }
        .frame(width: 42, height: 42)
    }

    private func readableCheckmarkColor(for colorHex: String) -> Color {
        UIColor(hex: colorHex).isLightColor ? .black : .white
    }
}

private extension UIColor {
    var isLightColor: Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let luminance = (0.299 * red) + (0.587 * green) + (0.114 * blue)
        return luminance > 0.72
    }
}
