//
//  PenPaletteView.swift
//  BeanNotes
//

import SwiftUI
import UIKit

struct PenPaletteView: View {
    @ObservedObject var toolState: DrawingToolState

    @State private var isCollapsed = false
    @State private var isShowingEraserModes = false
    @State private var committedOffset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero

    private let widths: [CGFloat] = [3, 5, 8, 14]

    var body: some View {
        paletteBody
            .fixedSize()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.secondary.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 10)
            .overlay(alignment: .topTrailing) {
                collapseButton
                    .offset(x: 9, y: -9)
            }
            .offset(
                x: committedOffset.width + dragOffset.width,
                y: committedOffset.height + dragOffset.height
            )
            .gesture(moveGesture)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pen palette")
    }

    @ViewBuilder
    private var paletteBody: some View {
        if isCollapsed {
            collapsedPalette
        } else {
            expandedPalette
        }
    }

    private var expandedPalette: some View {
        HStack(spacing: 8) {
            dragHandle

            HStack(spacing: 3) {
                ForEach(DrawingTool.allCases) { tool in
                    toolButton(tool)
                }
            }

            if toolState.selectedTool == .eraser, isShowingEraserModes {
                eraserModePicker
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }

            if showsInkControls {
                Divider()
                    .frame(height: 24)

                HStack(spacing: 5) {
                    primaryPaletteColorPicker

                    ForEach(Array(toolState.paletteSwatches().dropFirst())) { swatch in
                        swatchButton(swatch)
                    }
                }

                Divider()
                    .frame(height: 24)

                HStack(spacing: 2) {
                    ForEach(widths, id: \.self) { width in
                        widthButton(width)
                    }
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 18)
        .padding(.vertical, 6)
    }

    private var eraserModePicker: some View {
        HStack(spacing: 3) {
            ForEach(DrawingEraserMode.allCases) { mode in
                eraserModeButton(mode)
            }
        }
        .padding(3)
        .background(Color(.secondarySystemBackground).opacity(0.82), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Eraser mode")
    }

    private var collapsedPalette: some View {
        HStack(spacing: 8) {
            dragHandle

            Image(systemName: toolState.selectedTool.systemImage)
                .font(.callout.weight(.semibold))
                .symbolVariant(.fill)
                .frame(width: 26, height: 26)

            if showsInkControls {
                Circle()
                    .fill(toolState.activeInkColor)
                    .frame(width: 18, height: 18)
                    .overlay {
                        Circle()
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    }
                    .accessibilityLabel("Current color")
            } else if toolState.selectedTool == .eraser {
                Text(toolState.eraserMode.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(toolState.eraserMode.label) eraser")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 24)
        .padding(.vertical, 7)
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 28)
            .accessibilityHidden(true)
    }

    private var collapseButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) {
                isCollapsed.toggle()
            }
        } label: {
            Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle()
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCollapsed ? "Expand palette" : "Collapse palette")
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                committedOffset.width += value.translation.width
                committedOffset.height += value.translation.height
                dragOffset = .zero
            }
    }

    private var primaryPaletteColor: Binding<Color> {
        Binding {
            toolState.primaryPaletteColor()
        } set: { newColor in
            isShowingEraserModes = false
            toolState.setPrimaryPaletteColor(newColor)
        }
    }

    private var showsInkControls: Bool {
        toolState.selectedToolUsesInkColor
    }

    private var primaryPaletteColorPicker: some View {
        ColorPicker("", selection: primaryPaletteColor, supportsOpacity: false)
            .labelsHidden()
            .frame(width: 24, height: 24)
            .overlay {
                Circle()
                    .stroke(isPrimaryPaletteColorSelected ? .blue : Color.secondary.opacity(0.22), lineWidth: isPrimaryPaletteColorSelected ? 2 : 1)
                    .frame(width: 29, height: 29)
            }
            .accessibilityLabel("\(toolState.activeColorTool.label) custom color")
    }

    private func toolButton(_ tool: DrawingTool) -> some View {
        Button {
            selectTool(tool)
        } label: {
            Image(systemName: tool.systemImage)
                .font(.callout.weight(.semibold))
                .symbolVariant(toolState.selectedTool == tool ? .fill : .none)
                .foregroundStyle(toolState.selectedTool == tool ? .primary : .secondary)
                .frame(width: 28, height: 28)
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

    private func eraserModeButton(_ mode: DrawingEraserMode) -> some View {
        let isSelected = toolState.eraserMode == mode

        return Button {
            toolState.selectEraserMode(mode)
            withAnimation(.snappy(duration: 0.16)) {
                isShowingEraserModes = false
            }
        } label: {
            Text(mode.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(.blue.opacity(0.15))
                    }
                }
                .overlay {
                    if isSelected {
                        Capsule()
                            .stroke(.blue, lineWidth: 1.4)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.label) eraser")
    }

    private func selectTool(_ tool: DrawingTool) {
        if tool == .eraser, toolState.selectedTool == .eraser {
            withAnimation(.snappy(duration: 0.16)) {
                isShowingEraserModes.toggle()
            }
            return
        }

        toolState.select(tool)

        if tool != .eraser {
            withAnimation(.snappy(duration: 0.16)) {
                isShowingEraserModes = false
            }
        }
    }

    private func swatchButton(_ swatch: DrawingColorSwatch) -> some View {
        Button {
            isShowingEraserModes = false
            toolState.selectPaletteColor(swatch.color)
        } label: {
            Circle()
                .fill(swatch.color)
                .frame(width: 21, height: 21)
                .overlay {
                    Circle()
                        .stroke(isLightSwatch(swatch) ? Color.secondary.opacity(0.42) : Color.clear, lineWidth: 1)
                }
                .overlay {
                    if isCurrentColor(swatch) {
                        Circle()
                            .stroke(.blue, lineWidth: 2)
                            .frame(width: 27, height: 27)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(swatch.name)
    }

    private func widthButton(_ width: CGFloat) -> some View {
        Button {
            isShowingEraserModes = false
            toolState.applyActiveWidth(width)
        } label: {
            Circle()
                .fill(.secondary)
                .frame(width: width + 4, height: width + 4)
                .frame(width: 26, height: 26)
                .background {
                    if abs(toolState.activeStrokeWidth - width) < 0.5 {
                        Circle()
                            .fill(.blue.opacity(0.12))
                    }
                }
                .overlay {
                    if abs(toolState.activeStrokeWidth - width) < 0.5 {
                        Circle()
                            .stroke(.blue, lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(Int(width)) point stroke")
    }

    private func isLightSwatch(_ swatch: DrawingColorSwatch) -> Bool {
        let color = UIColor(hex: swatch.colorHex)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red * 0.299 + green * 0.587 + blue * 0.114) > 0.78
    }

    private func isCurrentColor(_ swatch: DrawingColorSwatch) -> Bool {
        UIColor(toolState.activeInkColor).hexRGB == UIColor(hex: swatch.colorHex).hexRGB
    }

    private var isPrimaryPaletteColorSelected: Bool {
        UIColor(toolState.activeInkColor).hexRGB == UIColor(toolState.primaryPaletteColor()).hexRGB
    }
}
