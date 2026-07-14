//
//  NoteBackgroundPickerView.swift
//  BeanNotes
//

import SwiftUI

struct NoteBackgroundPickerView: View {
    @Binding var styleRaw: String
    @Binding var colorHex: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Template", selection: styleSelection) {
                ForEach(NoteBackgroundStyle.allCases) { style in
                    Text(style.label).tag(style.rawValue)
                }
            }
            .pickerStyle(.menu)

            NoteBackgroundSurface(background: background)
                .frame(height: 116)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                }

            templateControls

            if background.style.supportsCustomColor {
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
    }

    private var background: NoteBackground {
        NoteBackground.fromDefaults(styleRaw: styleRaw, colorHex: colorHex)
    }

    private var styleSelection: Binding<String> {
        Binding(
            get: { background.style.rawValue },
            set: { rawValue in
                let style = NoteBackgroundStyle(rawValue: rawValue) ?? .plain
                styleRaw = background.changingStyle(to: style).storageStyleRaw
            }
        )
    }

    @ViewBuilder
    private var templateControls: some View {
        let selectedStyle = background.style

        if selectedStyle.supportsSpacing || selectedStyle.supportsMargin {
            VStack(alignment: .leading, spacing: 14) {
                if selectedStyle.supportsSpacing {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(spacingLabel(for: selectedStyle))
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(Int(background.resolvedSpacing.rounded())) pt")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Slider(
                            value: Binding(
                                get: { background.resolvedSpacing },
                                set: { styleRaw = background.changingSpacing(to: $0).storageStyleRaw }
                            ),
                            in: selectedStyle.spacingRange,
                            step: 1
                        )
                    }
                }

                if selectedStyle.supportsMargin {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(marginLabel(for: selectedStyle))
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(Int(background.resolvedMarginWidth.rounded())) pt")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Slider(
                            value: Binding(
                                get: { background.resolvedMarginWidth },
                                set: { styleRaw = background.changingMarginWidth(to: $0).storageStyleRaw }
                            ),
                            in: selectedStyle.marginRange,
                            step: 4
                        )
                    }
                }
            }
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 42, maximum: 42), spacing: 12)]
    }

    private func spacingLabel(for style: NoteBackgroundStyle) -> String {
        switch style {
        case .musicStaff:
            "Staff Line Gap"
        case .planner:
            "Row Height"
        default:
            "Spacing"
        }
    }

    private func marginLabel(for style: NoteBackgroundStyle) -> String {
        switch style {
        case .cornell:
            "Cue Column"
        case .planner:
            "Time Column"
        default:
            "Margin"
        }
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
