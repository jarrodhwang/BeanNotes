//
//  PenPaletteView.swift
//  BeanNote
//

import SwiftUI
import UIKit

struct PenPaletteView: View {
    @ObservedObject var toolState: DrawingToolState

    var addAttachment: () -> Void
    var pasteImage: () -> Void
    var showAttachments: () -> Void
    var showBackgrounds: () -> Void

    private let swatches: [(name: String, color: Color)] = [
        ("Black", .black),
        ("Blue", .blue),
        ("Red", .red),
        ("Green", .green),
        ("Yellow", .yellow),
        ("White", .white),
        ("Rose", .pink),
        ("Orange", .orange)
    ]

    private let widths: [CGFloat] = [3, 7, 12]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                toolButton(.pen)
                toolButton(.highlighter)
                toolButton(.eraser)
                toolButton(.lasso)

                Divider()
                    .frame(height: 24)

                actionButton(systemImage: "plus.circle", label: "Add attachment", action: addAttachment)
                actionButton(systemImage: "photo", label: "Paste image", action: pasteImage)
                actionButton(systemImage: "rectangle.inset.filled", label: "Page background", action: showBackgrounds)
                actionButton(systemImage: "paperclip", label: "Attachments", action: showAttachments)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            HStack(spacing: 14) {
                ForEach(swatches, id: \.name) { swatch in
                    swatchButton(name: swatch.name, color: swatch.color)
                }

                Divider()
                    .frame(height: 30)

                ForEach(widths, id: \.self) { width in
                    widthButton(width)
                }

                ColorPicker("", selection: activeColor)
                    .labelsHidden()
                    .frame(width: 34, height: 34)
                    .accessibilityLabel("Custom color")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.secondary.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pen palette")
    }

    private var activeColor: Binding<Color> {
        Binding {
            toolState.activeInkColor
        } set: { newColor in
            toolState.applyActiveColor(newColor)
        }
    }

    private func toolButton(_ tool: DrawingTool) -> some View {
        Button {
            toolState.select(tool)
        } label: {
            Image(systemName: tool.systemImage)
                .font(.title3.weight(.semibold))
                .symbolVariant(toolState.selectedTool == tool ? .fill : .none)
                .foregroundStyle(toolState.selectedTool == tool ? .primary : .secondary)
                .frame(width: 34, height: 34)
                .background {
                    if toolState.selectedTool == tool {
                        Circle()
                            .fill(.blue.opacity(0.14))
                    }
                }
                .overlay {
                    if toolState.selectedTool == tool {
                        Circle()
                            .stroke(.blue, lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.label)
    }

    private func actionButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func swatchButton(name: String, color: Color) -> some View {
        Button {
            toolState.applyActiveColor(color)
        } label: {
            Circle()
                .fill(color)
                .frame(width: 28, height: 28)
                .overlay {
                    Circle()
                        .stroke(name == "White" ? Color.secondary.opacity(0.42) : Color.clear, lineWidth: 1)
                }
                .overlay {
                    if isCurrentColor(color) {
                        Circle()
                            .stroke(.blue, lineWidth: 2)
                            .frame(width: 34, height: 34)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }

    private func widthButton(_ width: CGFloat) -> some View {
        Button {
            toolState.strokeWidth = width
        } label: {
            Circle()
                .fill(.secondary)
                .frame(width: width + 5, height: width + 5)
                .frame(width: 34, height: 34)
                .background {
                    if abs(toolState.strokeWidth - width) < 0.5 {
                        Circle()
                            .fill(.blue.opacity(0.12))
                    }
                }
                .overlay {
                    if abs(toolState.strokeWidth - width) < 0.5 {
                        Circle()
                            .stroke(.blue, lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(Int(width)) point stroke")
    }

    private func isCurrentColor(_ color: Color) -> Bool {
        UIColor(toolState.activeInkColor).hexRGB == UIColor(color).hexRGB
    }
}
