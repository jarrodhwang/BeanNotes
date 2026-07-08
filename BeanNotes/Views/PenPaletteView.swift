//
//  PenPaletteView.swift
//  BeanNotes
//

import SwiftUI
import UIKit

struct PenPaletteView: View {
    @ObservedObject var toolState: DrawingToolState
    var availableSize: CGSize = UIScreen.main.bounds.size
    var zoomScale: CGFloat = 1
    var strokeZoomBehavior: DrawingStrokeZoomBehavior = .pageWidth

    @State private var isCollapsed = false
    @State private var isShowingEraserModes = false
    @State private var committedOffset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    @State private var selectedPaletteIndex = 0
    @State private var measuredPaletteSize: CGSize = .zero
    @State private var selectionFeedback = UISelectionFeedbackGenerator()

    var body: some View {
        paletteBody
            .fixedSize()
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: PenPaletteSizePreferenceKey.self, value: proxy.size)
                }
            }
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
                x: dockOffset.width + committedOffset.width + dragOffset.width,
                y: dockOffset.height + committedOffset.height + dragOffset.height
            )
            .onAppear {
                selectionFeedback.prepare()
                syncSelectedPaletteIndex()
                committedOffset = clampedOffset(committedOffset)
            }
            .onPreferenceChange(PenPaletteSizePreferenceKey.self) { size in
                measuredPaletteSize = size
                committedOffset = clampedOffset(committedOffset)
            }
            .onChange(of: availableSize) { _, _ in
                committedOffset = clampedOffset(committedOffset)
            }
            .onChange(of: isCollapsed) { _, _ in
                committedOffset = clampedOffset(committedOffset)
            }
            .onChange(of: activePaletteSelectionSignature) { _, _ in
                syncSelectedPaletteIndex()
            }
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
        Group {
            if usesCompactLayout {
                compactExpandedPalette
            } else {
                regularExpandedPalette
            }
        }
    }

    private var regularExpandedPalette: some View {
        HStack(spacing: 8) {
            dragHandle

            toolButtons

            if toolState.selectedTool == .eraser, isShowingEraserModes {
                eraserModePicker
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }

            if showsInkControls {
                Divider()
                    .frame(height: 24)

                colorControls

                Divider()
                    .frame(height: 24)

                regularWidthControls
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 18)
        .padding(.vertical, 6)
    }

    private var compactExpandedPalette: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                dragHandle
                toolButtons
            }

            if toolState.selectedTool == .eraser, isShowingEraserModes {
                eraserModePicker
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }

            if showsInkControls {
                colorControls
                compactWidthControls
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 18)
        .padding(.vertical, 7)
    }

    private var toolButtons: some View {
        HStack(spacing: 3) {
            ForEach(DrawingTool.allCases) { tool in
                toolButton(tool)
            }
        }
    }

    private var colorControls: some View {
        HStack(spacing: 5) {
            ForEach(toolState.paletteSwatches()) { swatch in
                swatchButton(swatch)
            }

            selectedPaletteColorPicker
        }
    }

    private var regularWidthControls: some View {
        HStack(spacing: 6) {
            strokeWidthModeSegment

            widthPresetControls

            widthSliderControls

            widthReadout
        }
        .frame(height: 30)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(toolState.activeColorTool.label) stroke width")
        .accessibilityValue(activeWidthReadout.accessibilityText)
    }

    private var compactWidthControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                strokeWidthModeSegment

                widthPresetControls
            }
            .frame(height: 30)

            HStack(spacing: 6) {
                widthSliderControls

                widthReadout
            }
            .frame(height: 30)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(toolState.activeColorTool.label) stroke width")
        .accessibilityValue(activeWidthReadout.accessibilityText)
    }

    private var strokeWidthModeSegment: some View {
        HStack(spacing: 2) {
            ForEach(DrawingStrokeWidthMode.allCases) { mode in
                strokeWidthModeButton(mode)
            }
        }
        .padding(2)
        .background(Color(.secondarySystemBackground).opacity(0.7), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Stroke width mode")
    }

    private func strokeWidthModeButton(_ mode: DrawingStrokeWidthMode) -> some View {
        let isSelected = toolState.widthMode == mode

        return Button {
            performSelectionFeedback()
            isShowingEraserModes = false
            toolState.selectWidthMode(mode)
        } label: {
            Image(systemName: mode.systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 24, height: 24)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(.blue.opacity(0.14))
                    }
                }
                .overlay {
                    if isSelected {
                        Capsule()
                            .stroke(.blue, lineWidth: 1.6)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.label) stroke width mode")
        .accessibilityHint(mode.description)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var widthPresetControls: some View {
        HStack(spacing: 6) {
            ForEach(toolState.widthPresets(), id: \.self) { width in
                widthButton(width)
            }
        }
    }

    private var widthSliderControls: some View {
        HStack(spacing: 6) {
            widthNudgeButton(direction: -1)

            Slider(value: activeWidthBinding, in: activeWidthRange, step: activeWidthStep) {
                Text("Stroke width")
            }
            .labelsHidden()
            .frame(width: usesCompactLayout ? 124 : 108)

            widthNudgeButton(direction: 1)
        }
    }

    private var widthReadout: some View {
        ZStack(alignment: .trailing) {
            Text(activeWidthText)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .opacity(activeWidthReadout.showsEffectiveWidth ? 0 : 1)

            VStack(alignment: .trailing, spacing: 0) {
                Text(activeWidthText)
                    .font(.caption2.weight(.semibold).monospacedDigit())

                Text("page \(activeWidthReadout.effectiveWidthText)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .opacity(activeWidthReadout.showsEffectiveWidth ? 1 : 0)
            .accessibilityHidden(true)
        }
        .foregroundStyle(.secondary)
        .frame(width: 58, height: 30, alignment: .trailing)
    }

    private func widthNudgeButton(direction: CGFloat) -> some View {
        Button {
            performSelectionFeedback()
            isShowingEraserModes = false
            toolState.nudgeActiveWidth(by: direction)
        } label: {
            Image(systemName: direction < 0 ? "minus" : "plus")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color(.secondarySystemBackground).opacity(0.7), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(direction < 0 ? "Decrease stroke width" : "Increase stroke width")
        .accessibilityValue(activeWidthReadout.accessibilityText)
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
            .contentShape(Rectangle())
            .gesture(moveGesture)
            .accessibilityHidden(true)
    }

    private var collapseButton: some View {
        Button {
            performSelectionFeedback()
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
                let proposedOffset = CGSize(
                    width: committedOffset.width + value.translation.width,
                    height: committedOffset.height + value.translation.height
                )
                committedOffset = clampedOffset(proposedOffset)
                dragOffset = .zero
            }
    }

    private func clampedOffset(_ proposedOffset: CGSize) -> CGSize {
        PenPaletteLayoutMetrics.clampedCommittedOffset(
            proposedOffset,
            availableSize: availableSize,
            paletteSize: effectivePaletteSize,
            dockOffset: dockOffset
        )
    }

    private var dockOffset: CGSize {
        PenPaletteLayoutMetrics.defaultDockOffset(for: availableSize)
    }

    private var usesCompactLayout: Bool {
        PenPaletteLayoutMetrics.prefersCompactLayout(for: availableSize)
    }

    private var effectivePaletteSize: CGSize {
        measuredPaletteSize == .zero
            ? PenPaletteLayoutMetrics.estimatedPaletteSize(isCompact: usesCompactLayout, showsInkControls: showsInkControls)
            : measuredPaletteSize
    }

    private var showsInkControls: Bool {
        toolState.selectedToolUsesInkColor
    }

    private var activePaletteSelectionSignature: String {
        let tool = toolState.activeColorTool
        let activeColorHex = UIColor(toolState.inkColor(for: tool)).hexRGB
        let paletteSignature = toolState.paletteSwatches(for: tool)
            .map(\.colorHex)
            .joined(separator: "|")
        return "\(tool.rawValue)#\(activeColorHex)#\(paletteSignature)"
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
            performSelectionFeedback()
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
        performSelectionFeedback()

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

    private var selectedPaletteColorPicker: some View {
        ColorPicker("", selection: selectedPaletteColorBinding, supportsOpacity: false)
            .labelsHidden()
            .frame(width: 24, height: 24)
            .overlay {
                Circle()
                    .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
                    .frame(width: 29, height: 29)
            }
            .accessibilityLabel("Edit selected \(toolState.activeColorTool.label) color")
            .accessibilityHint("Changes the highlighted palette swatch")
    }

    private var selectedPaletteColorBinding: Binding<Color> {
        Binding {
            toolState.paletteColor(at: selectedPaletteIndex)
        } set: { newColor in
            isShowingEraserModes = false
            toolState.setPaletteColor(newColor, at: selectedPaletteIndex)
        }
    }

    private func swatchButton(_ swatch: DrawingColorSwatch) -> some View {
        Button {
            selectPaletteSwatch(swatch)
        } label: {
            Circle()
                .fill(swatch.color)
                .frame(width: 21, height: 21)
                .overlay {
                    Circle()
                        .stroke(isLightSwatch(swatch) ? Color.secondary.opacity(0.42) : Color.clear, lineWidth: 1)
                }
                .overlay {
                    if isSelectedPaletteSwatch(swatch) {
                        Circle()
                            .stroke(.blue, lineWidth: 2)
                            .frame(width: 27, height: 27)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(swatch.name) \(toolState.activeColorTool.label) color")
    }

    private func selectPaletteSwatch(_ swatch: DrawingColorSwatch) {
        performSelectionFeedback()
        isShowingEraserModes = false
        selectedPaletteIndex = swatch.index
        toolState.selectPaletteColor(swatch.color)
    }

    private func syncSelectedPaletteIndex() {
        selectedPaletteIndex = toolState.paletteIndexMatchingActiveColor(preferredIndex: selectedPaletteIndex)
    }

    private func widthButton(_ width: CGFloat) -> some View {
        Button {
            performSelectionFeedback()
            isShowingEraserModes = false
            toolState.applyActiveWidth(width)
        } label: {
            Circle()
                .fill(.secondary)
                .frame(width: widthButtonDiameter(for: width), height: widthButtonDiameter(for: width))
                .frame(width: 26, height: 26)
                .background {
                    if isActiveWidthPreset(width) {
                        Circle()
                            .fill(.blue.opacity(0.12))
                    }
                }
                .overlay {
                    if isActiveWidthPreset(width) {
                        Circle()
                            .stroke(.blue, lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(widthLabel(for: width)) point stroke")
    }

    private var activeWidthBinding: Binding<Double> {
        Binding {
            Double(toolState.activeStrokeWidth)
        } set: { newValue in
            isShowingEraserModes = false
            toolState.applyActiveWidth(CGFloat(newValue))
        }
    }

    private var activeWidthRange: ClosedRange<Double> {
        let range = toolState.activeWidthCalibration.range
        return Double(range.lowerBound)...Double(range.upperBound)
    }

    private var activeWidthStep: Double {
        Double(toolState.activeWidthStep)
    }

    private var activeWidthText: String {
        activeWidthReadout.storedWidthText
    }

    private var activeWidthReadout: DrawingStrokeWidthReadout {
        toolState.strokeWidthReadout(
            for: toolState.activeColorTool,
            zoomScale: zoomScale,
            zoomBehavior: strokeZoomBehavior
        )
    }

    private func widthButtonDiameter(for width: CGFloat) -> CGFloat {
        let calibration = toolState.activeWidthCalibration
        let span = max(calibration.maximumWidth - calibration.minimumWidth, 0.1)
        let progress = (width - calibration.minimumWidth) / span
        return min(max(7 + progress * 14, 7), 21)
    }

    private func isActiveWidthPreset(_ width: CGFloat) -> Bool {
        let tolerance = max(toolState.activeWidthStep / 2, 0.05)
        return abs(toolState.activeStrokeWidth - width) <= tolerance
    }

    private func widthLabel(for width: CGFloat) -> String {
        DrawingStrokeWidthReadout.pointsText(for: width)
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

    private func isSelectedPaletteSwatch(_ swatch: DrawingColorSwatch) -> Bool {
        swatch.index == selectedPaletteIndex
    }

    private func performSelectionFeedback() {
        selectionFeedback.selectionChanged()
        selectionFeedback.prepare()
    }
}

struct PenPaletteLayoutMetrics {
    static let compactWidthThreshold: CGFloat = 1_180
    private static let minimumVisibleInset: CGFloat = 8
    private static let trailingInset: CGFloat = 16
    private static let bottomInset: CGFloat = 24

    static func prefersCompactLayout(for availableSize: CGSize) -> Bool {
        guard availableSize.width > 0 else { return false }
        return availableSize.width < compactWidthThreshold
    }

    static func defaultDockOffset(for availableSize: CGSize) -> CGSize {
        CGSize(
            width: prefersCompactLayout(for: availableSize) ? 18 : 96,
            height: 14
        )
    }

    static func estimatedPaletteSize(isCompact: Bool, showsInkControls: Bool) -> CGSize {
        if isCompact {
            return CGSize(width: showsInkControls ? 286 : 212, height: showsInkControls ? 162 : 44)
        }

        return CGSize(width: showsInkControls ? 902 : 246, height: 44)
    }

    static func clampedCommittedOffset(
        _ proposedOffset: CGSize,
        availableSize: CGSize,
        paletteSize: CGSize,
        dockOffset: CGSize
    ) -> CGSize {
        let fallbackSize = availableSize == .zero ? UIScreen.main.bounds.size : availableSize
        let minimumOffset = CGSize(
            width: minimumVisibleInset - dockOffset.width,
            height: minimumVisibleInset - dockOffset.height
        )
        let maximumOffset = CGSize(
            width: max(
                minimumOffset.width,
                fallbackSize.width - dockOffset.width - paletteSize.width - trailingInset
            ),
            height: max(
                minimumOffset.height,
                fallbackSize.height - dockOffset.height - paletteSize.height - bottomInset
            )
        )

        return CGSize(
            width: min(max(proposedOffset.width, minimumOffset.width), maximumOffset.width),
            height: min(max(proposedOffset.height, minimumOffset.height), maximumOffset.height)
        )
    }
}

private struct PenPaletteSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        guard next != .zero else { return }
        value = next
    }
}
