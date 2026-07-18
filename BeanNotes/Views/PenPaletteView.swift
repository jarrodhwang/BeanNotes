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
    var createCodeSnippet: () -> Void = {}

    @AppStorage(PenPaletteLayoutMetrics.isCollapsedStorageKey) private var isCollapsed = false
    @AppStorage(PenPaletteLayoutMetrics.committedOffsetStorageKey) private var committedOffsetRaw = ""
    @AppStorage(DrawingPaletteConfiguration.colorCountStorageKey)
    private var paletteColorCount = DrawingPaletteConfiguration.defaultColorCountForCurrentDevice
    @State private var isShowingEraserModes = false
    @State private var committedOffset: CGSize = .zero
    @GestureState private var dragOffset: CGSize = .zero
    @State private var selectedPaletteIndex = 0
    @State private var isShowingWidthControls = false
    @State private var isShowingCustomWidth = false
    @State private var isShowingCustomEraserWidth = false
    @State private var isShowingRubEraserAngle = false
    @State private var measuredPaletteSize: CGSize = .zero
    @State private var selectionFeedback = UISelectionFeedbackGenerator()
    @State private var hasLoadedCommittedOffset = false

    var body: some View {
        paletteBody
            .fixedSize()
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: PenPaletteSizePreferenceKey.self, value: proxy.size)
                }
            }
            // A live backdrop blur is expensive while this floating control moves over
            // PencilKit's Metal surface. An opaque system surface stays compositor-only.
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.secondary.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.13), radius: 8, x: 0, y: 4)
            .overlay(alignment: .topTrailing) {
                collapseButton
                    .offset(x: 9, y: -9)
            }
            .offset(
                x: dockOffset.width + committedOffset.width + dragOffset.width,
                y: dockOffset.height + committedOffset.height + dragOffset.height
            )
            .onAppear {
                if toolState.widthMode != .standard {
                    toolState.selectWidthMode(.standard)
                }
                normalizeEraserModeForPalette()
                restorePaletteColorCount()
                selectionFeedback.prepare()
                syncSelectedPaletteIndex()
                clampCommittedOffset()
            }
            .onPreferenceChange(PenPaletteSizePreferenceKey.self) { size in
                measuredPaletteSize = size
                clampCommittedOffset()
            }
            .onChange(of: availableSize) { _, _ in
                clampCommittedOffset()
            }
            .onChange(of: isCollapsed) { _, _ in
                clampCommittedOffset(persisting: true)
            }
            .onChange(of: paletteColorCount) { _, _ in
                normalizePaletteColorCountIfNeeded()
                measuredPaletteSize = .zero
                syncSelectedPaletteIndex()
                clampCommittedOffset(persisting: true)
            }
            .onChange(of: activePaletteSelectionSignature) { _, _ in
                syncSelectedPaletteIndex()
            }
            .onChange(of: toolState.selectedTool) { _, _ in
                isShowingWidthControls = false
                isShowingCustomWidth = false
                isShowingCustomEraserWidth = false
                isShowingRubEraserAngle = false
                isShowingEraserModes = false
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pen palette")
            .accessibilityValue("\(displayedPaletteColorCount) colors")
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
        HStack(spacing: 10) {
            dragHandle

            toolButtons

            if toolState.selectedTool == .eraser, isShowingEraserModes {
                regularEraserControls
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }

            if showsInkControls {
                Divider()
                    .frame(height: 24)

                colorControls

                if isShowingWidthControls {
                    Divider()
                        .frame(height: 30)

                    regularWidthControls
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 20)
        .padding(.vertical, 7)
    }

    private var compactExpandedPalette: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                dragHandle
                toolButtons
            }

            if toolState.selectedTool == .eraser, isShowingEraserModes {
                compactEraserControls
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }

            if showsInkControls {
                colorControls

                if isShowingWidthControls {
                    compactWidthControls
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 20)
        .padding(.vertical, 7)
    }

    private var toolButtons: some View {
        HStack(spacing: 0) {
            ForEach(DrawingTool.allCases) { tool in
                toolButton(tool)
            }

            Button {
                performSelectionFeedback()
                createCodeSnippet()
            } label: {
                Image(systemName: "curlybraces.square")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .palettePrimaryHitTarget()
            .accessibilityLabel("Add code snippet")
            .accessibilityHint("Opens an editor for highlighted code, pasted text, or Apple Pencil handwriting")
            .accessibilityIdentifier("penPalette.codeSnippet")

        }
    }

    private var colorControls: some View {
        HStack(spacing: 0) {
            ForEach(displayedPaletteSwatches) { swatch in
                swatchButton(swatch)
            }
        }
    }

    private var regularWidthControls: some View {
        HStack(spacing: 6) {
            widthPresetControls

            customWidthButton

            if isShowingCustomWidth {
                customWidthSlider
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .frame(height: 30)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(toolState.activeColorTool.label) stroke width")
        .accessibilityValue(activeWidthReadout.accessibilityText)
    }

    private var compactWidthControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                widthPresetControls
                customWidthButton
            }
            .frame(height: 30)

            if isShowingCustomWidth {
                customWidthSlider
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(toolState.activeColorTool.label) stroke width")
        .accessibilityValue(activeWidthReadout.accessibilityText)
    }

    private var widthPresetControls: some View {
        HStack(spacing: 6) {
            ForEach(toolState.widthPresets(), id: \.self) { width in
                widthButton(width)
            }
        }
    }

    private var customWidthButton: some View {
        Button {
            performSelectionFeedback()
            withAnimation(.snappy(duration: 0.16)) {
                isShowingCustomWidth.toggle()
            }
        } label: {
            Text("Custom")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isShowingCustomWidth ? .primary : .secondary)
                .frame(minWidth: 48, minHeight: 26)
                .background(isShowingCustomWidth ? Color.blue.opacity(0.12) : Color.clear, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(isShowingCustomWidth ? Color.blue : Color.secondary.opacity(0.24), lineWidth: 1.4)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Custom pen thickness")
        .accessibilityValue(activeWidthText)
    }

    private var customWidthSlider: some View {
        HStack(spacing: 7) {
            Slider(value: activeWidthBinding, in: activeWidthRange, step: activeWidthStep) {
                Text("Custom pen thickness")
            }
            .labelsHidden()
            .frame(width: usesCompactLayout ? 150 : 120)

            Text(activeWidthText)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .frame(height: 30)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Custom pen thickness")
        .accessibilityValue(activeWidthText)
    }

    private var eraserModePicker: some View {
        HStack(spacing: 3) {
            ForEach(DrawingEraserMode.paletteModes) { mode in
                eraserModeButton(mode)
            }
        }
        .padding(3)
        .background(Color(.secondarySystemBackground).opacity(0.82), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Eraser mode")
    }

    private var regularEraserControls: some View {
        HStack(spacing: 6) {
            eraserModePicker

            Divider()
                .frame(height: 30)

            eraserWidthPresetControls
            customEraserWidthButton

            if isShowingCustomEraserWidth {
                customEraserWidthSlider
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            if toolState.eraserMode == .rub {
                Divider()
                    .frame(height: 30)

                rubEraserShapePicker
                rubEraserAngleButton

                if isShowingRubEraserAngle {
                    rubEraserAngleSlider
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Eraser controls")
    }

    private var compactEraserControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            eraserModePicker

            HStack(spacing: 6) {
                eraserWidthPresetControls
                customEraserWidthButton
            }

            if isShowingCustomEraserWidth {
                customEraserWidthSlider
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if toolState.eraserMode == .rub {
                HStack(spacing: 6) {
                    rubEraserShapePicker
                    rubEraserAngleButton
                }

                if isShowingRubEraserAngle {
                    rubEraserAngleSlider
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Eraser controls")
    }

    private var eraserWidthPresetControls: some View {
        HStack(spacing: 6) {
            ForEach(Array(activeEraserSizePresets.enumerated()), id: \.offset) { index, width in
                eraserWidthButton(width)
                    .accessibilityIdentifier("eraser-size-\(index)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Eraser size")
        .accessibilityValue("\(activeEraserSizeText) points")
    }

    private var customEraserWidthButton: some View {
        Button {
            performSelectionFeedback()
            withAnimation(.snappy(duration: 0.16)) {
                isShowingCustomEraserWidth.toggle()
            }
        } label: {
            Text("Custom")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isShowingCustomEraserWidth ? .primary : .secondary)
                .frame(minWidth: 48, minHeight: 26)
                .background(isShowingCustomEraserWidth ? Color.blue.opacity(0.12) : Color.clear, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(
                            isShowingCustomEraserWidth ? Color.blue : Color.secondary.opacity(0.24),
                            lineWidth: 1.4
                        )
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Custom eraser size")
        .accessibilityValue("\(activeEraserSizeText) points")
    }

    private var customEraserWidthSlider: some View {
        HStack(spacing: 7) {
            Slider(
                value: activeEraserSizeBinding,
                in: activeEraserSizeRange,
                step: Double(activeEraserSizeCalibration.step)
            ) {
                Text("Custom eraser size")
            }
            .labelsHidden()
            .frame(width: usesCompactLayout ? 150 : 120)

            Text(activeEraserSizeText)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .frame(height: 30)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Custom eraser size")
        .accessibilityValue("\(activeEraserSizeText) points")
    }

    private var rubEraserShapePicker: some View {
        Menu {
            ForEach(DrawingRubEraserShape.allCases) { shape in
                Button {
                    performSelectionFeedback()
                    toolState.selectRubEraserShape(shape)
                } label: {
                    Label(shape.label, systemImage: shape.systemImage)
                    if toolState.rubEraserShape == shape {
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            Label(toolState.rubEraserShape.label, systemImage: toolState.rubEraserShape.systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minHeight: 26)
                .padding(.horizontal, 7)
                .overlay {
                    Capsule()
                        .stroke(Color.secondary.opacity(0.24), lineWidth: 1.4)
                }
        }
        .accessibilityLabel("Rub eraser shape")
        .accessibilityValue(toolState.rubEraserShape.label)
    }

    private var rubEraserAngleButton: some View {
        Button {
            performSelectionFeedback()
            withAnimation(.snappy(duration: 0.16)) {
                isShowingRubEraserAngle.toggle()
            }
        } label: {
            Label("\(rubEraserAngleText)°", systemImage: "rotate.right")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(isShowingRubEraserAngle ? .primary : .secondary)
                .frame(minHeight: 26)
                .padding(.horizontal, 7)
                .background(isShowingRubEraserAngle ? Color.blue.opacity(0.12) : Color.clear, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(
                            isShowingRubEraserAngle ? Color.blue : Color.secondary.opacity(0.24),
                            lineWidth: 1.4
                        )
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Rub eraser angle")
        .accessibilityValue("\(rubEraserAngleText) degrees")
    }

    private var rubEraserAngleSlider: some View {
        HStack(spacing: 7) {
            Slider(value: rubEraserAngleBinding, in: 0...180, step: 1) {
                Text("Rub eraser angle")
            }
            .labelsHidden()
            .frame(width: usesCompactLayout ? 150 : 120)

            Text("\(rubEraserAngleText)°")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .frame(height: 30)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rub eraser angle")
        .accessibilityValue("\(rubEraserAngleText) degrees")
    }

    private var collapsedPalette: some View {
        HStack(spacing: 10) {
            dragHandle

            Image(systemName: toolState.selectedTool.systemImage)
                .font(.body.weight(.semibold))
                .symbolVariant(.fill)
                .frame(width: 32, height: 32)

            if showsInkControls {
                Circle()
                    .fill(toolState.activeInkColor)
                    .frame(width: 24, height: 24)
                    .overlay {
                        Circle()
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    }
                    .accessibilityLabel("Current color")
            } else if toolState.selectedTool == .eraser {
                Text(collapsedEraserSummary)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(collapsedEraserAccessibilityLabel)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 26)
        .padding(.vertical, 9)
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.callout.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 40)
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
                .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                .overlay {
                    Circle()
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCollapsed ? "Expand palette" : "Collapse palette")
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .updating($dragOffset) { value, state, transaction in
                transaction.animation = nil
                state = value.translation
            }
            .onEnded { value in
                let proposedOffset = CGSize(
                    width: committedOffset.width + value.translation.width,
                    height: committedOffset.height + value.translation.height
                )
                committedOffset = clampedOffset(proposedOffset)
                persistCommittedOffset()
            }
    }

    private func clampCommittedOffset(persisting: Bool = false) {
        loadCommittedOffsetIfNeeded()
        let clamped = clampedOffset(committedOffset)
        guard clamped != committedOffset else { return }
        committedOffset = clamped

        if persisting {
            persistCommittedOffset()
        }
    }

    private func loadCommittedOffsetIfNeeded() {
        guard !hasLoadedCommittedOffset else { return }
        committedOffset = PenPaletteLayoutMetrics.decodedCommittedOffset(from: committedOffsetRaw) ?? .zero
        hasLoadedCommittedOffset = true
    }

    private func persistCommittedOffset() {
        committedOffsetRaw = PenPaletteLayoutMetrics.encodedCommittedOffset(committedOffset)
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
            ? PenPaletteLayoutMetrics.estimatedPaletteSize(
                isCompact: usesCompactLayout,
                showsInkControls: showsInkControls,
                paletteColorCount: displayedPaletteColorCount
            )
            : measuredPaletteSize
    }

    private var showsInkControls: Bool {
        toolState.selectedToolUsesInkColor
    }

    private var displayedPaletteColorCount: Int {
        DrawingPaletteConfiguration.normalizedColorCount(paletteColorCount)
    }

    private var displayedPaletteSwatches: [DrawingColorSwatch] {
        toolState.paletteSwatches(displaying: displayedPaletteColorCount)
    }

    private var activePaletteSelectionSignature: String {
        let tool = toolState.activeColorTool
        let activeColorHex = UIColor(toolState.inkColor(for: tool)).hexRGB
        let paletteSignature = toolState.paletteSwatches(
            for: tool,
            displaying: displayedPaletteColorCount
        )
            .map(\.colorHex)
            .joined(separator: "|")
        return "\(tool.rawValue)#\(activeColorHex)#\(paletteSignature)"
    }

    private func toolButton(_ tool: DrawingTool) -> some View {
        Button {
            selectTool(tool)
        } label: {
            Image(systemName: tool.systemImage)
                .font(.body.weight(.semibold))
                .symbolVariant(toolState.selectedTool == tool ? .fill : .none)
                .foregroundStyle(toolState.selectedTool == tool ? .primary : .secondary)
                .frame(width: 38, height: 38)
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
                .palettePrimaryHitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.label)
    }

    private func eraserModeButton(_ mode: DrawingEraserMode) -> some View {
        let isSelected = toolState.eraserMode == mode

        return Button {
            performSelectionFeedback()
            toolState.selectEraserMode(mode)
            if mode == .object {
                isShowingCustomEraserWidth = false
            }
            if mode != .rub {
                isShowingRubEraserAngle = false
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
        .accessibilityHint(eraserModeAccessibilityHint(mode))
    }

    private func selectTool(_ tool: DrawingTool) {
        performSelectionFeedback()

        if tool == .eraser {
            normalizeEraserModeForPalette()
        }

        if toolState.selectedTool == tool {
            if tool == .eraser {
                withAnimation(.snappy(duration: 0.16)) {
                    isShowingEraserModes.toggle()
                    if !isShowingEraserModes {
                        isShowingCustomEraserWidth = false
                        isShowingRubEraserAngle = false
                    }
                }
            } else if toolState.selectedToolUsesInkColor {
                withAnimation(.snappy(duration: 0.16)) {
                    isShowingWidthControls.toggle()
                    if !isShowingWidthControls {
                        isShowingCustomWidth = false
                    }
                }
            }
            return
        }

        toolState.select(tool)
        isShowingEraserModes = false
        isShowingWidthControls = false
        isShowingCustomWidth = false
        isShowingCustomEraserWidth = false
        isShowingRubEraserAngle = false
    }

    private func normalizeEraserModeForPalette() {
        guard !DrawingEraserMode.paletteModes.contains(toolState.eraserMode) else { return }
        toolState.eraserMode = .pixel
    }

    private var selectedPaletteColorBinding: Binding<Color> {
        Binding {
            toolState.paletteColor(at: selectedPaletteIndex)
        } set: { newColor in
            isShowingEraserModes = false
            toolState.setPaletteColor(newColor, at: selectedPaletteIndex)
        }
    }

    @ViewBuilder
    private func swatchButton(_ swatch: DrawingColorSwatch) -> some View {
        if isSelectedPaletteSwatch(swatch) {
            ColorPicker("", selection: selectedPaletteColorBinding, supportsOpacity: false)
                .labelsHidden()
                .scaleEffect(1.12)
                .frame(width: 38, height: 38)
                .overlay {
                    Circle()
                        .stroke(.blue, lineWidth: 2.5)
                        .frame(width: 35, height: 35)
                        .allowsHitTesting(false)
                }
                .palettePrimaryHitTarget()
                .accessibilityLabel("Edit \(swatch.name) \(toolState.activeColorTool.label) color")
                .accessibilityHint("Opens the color picker for this selected swatch")
        } else {
            Button {
                selectPaletteSwatch(swatch)
            } label: {
                swatchCircle(swatch)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(swatch.name) \(toolState.activeColorTool.label) color")
            .accessibilityHint("Selects this color; tap it again to edit")
        }
    }

    private func swatchCircle(_ swatch: DrawingColorSwatch) -> some View {
        Circle()
            .fill(swatch.color)
            .frame(width: 28, height: 28)
            .overlay {
                Circle()
                    .stroke(isLightSwatch(swatch) ? Color.secondary.opacity(0.42) : Color.clear, lineWidth: 1)
            }
            .frame(width: 38, height: 38)
            .palettePrimaryHitTarget()
    }

    private func selectPaletteSwatch(_ swatch: DrawingColorSwatch) {
        performSelectionFeedback()
        isShowingEraserModes = false
        selectedPaletteIndex = swatch.index
        toolState.selectPaletteColor(swatch.color)
    }

    private func syncSelectedPaletteIndex() {
        selectedPaletteIndex = toolState.ensureActivePaletteColorIsVisible(
            preferredIndex: selectedPaletteIndex,
            displaying: displayedPaletteColorCount
        )
    }

    private func normalizePaletteColorCountIfNeeded() {
        let normalized = displayedPaletteColorCount
        guard paletteColorCount != normalized else { return }
        paletteColorCount = normalized
    }

    private func restorePaletteColorCount() {
        paletteColorCount = DrawingPaletteConfiguration.persistedColorCountForCurrentDevice()
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

    private func eraserWidthButton(_ width: CGFloat) -> some View {
        Button {
            performSelectionFeedback()
            applyActiveEraserSize(width)
        } label: {
            Group {
                if toolState.eraserMode == .rub {
                    RubEraserGlyph(shape: toolState.rubEraserShape)
                        .fill(.secondary)
                        .rotationEffect(.degrees(Double(toolState.rubEraserAngle)))
                } else {
                    Circle()
                        .fill(.secondary)
                }
            }
                .frame(width: eraserWidthButtonDiameter(for: width), height: eraserWidthButtonDiameter(for: width))
                .frame(width: 26, height: 26)
                .background {
                    if isActiveEraserWidthPreset(width) {
                        Circle()
                            .fill(.blue.opacity(0.12))
                    }
                }
                .overlay {
                    if isActiveEraserWidthPreset(width) {
                        Circle()
                            .stroke(.blue, lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(widthLabel(for: width)) point eraser")
    }

    private var activeWidthBinding: Binding<Double> {
        Binding {
            Double(toolState.activeStrokeWidth)
        } set: { newValue in
            isShowingEraserModes = false
            toolState.applyActiveWidth(CGFloat(newValue))
        }
    }

    private var activeEraserSizeBinding: Binding<Double> {
        Binding {
            Double(activeEraserSize)
        } set: { newValue in
            applyActiveEraserSize(CGFloat(newValue))
        }
    }

    private var activeEraserSizeRange: ClosedRange<Double> {
        let range = activeEraserSizeCalibration.range
        return Double(range.lowerBound)...Double(range.upperBound)
    }

    private var activeEraserSizeText: String {
        DrawingStrokeWidthReadout.pointsText(for: activeEraserSize)
    }

    private var collapsedEraserSummary: String {
        if toolState.eraserMode == .rub {
            return "Rub · \(toolState.rubEraserShape.label) · \(activeEraserSizeText) pt · \(rubEraserAngleText)°"
        }
        return "\(toolState.eraserMode.label) · \(activeEraserSizeText) pt"
    }

    private var collapsedEraserAccessibilityLabel: String {
        if toolState.eraserMode == .rub {
            return "Rub eraser, \(toolState.rubEraserShape.label), \(activeEraserSizeText) points, \(rubEraserAngleText) degrees"
        }
        return "\(toolState.eraserMode.label) eraser, \(activeEraserSizeText) points"
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

    private func eraserWidthButtonDiameter(for width: CGFloat) -> CGFloat {
        let calibration = activeEraserSizeCalibration
        let span = max(calibration.maximumWidth - calibration.minimumWidth, 0.1)
        let progress = (width - calibration.minimumWidth) / span
        return min(max(7 + progress * 14, 7), 21)
    }

    private func isActiveWidthPreset(_ width: CGFloat) -> Bool {
        let tolerance = max(toolState.activeWidthStep / 2, 0.05)
        return abs(toolState.activeStrokeWidth - width) <= tolerance
    }

    private func isActiveEraserWidthPreset(_ width: CGFloat) -> Bool {
        let tolerance = max(activeEraserSizeCalibration.step / 2, 0.05)
        return abs(activeEraserSize - width) <= tolerance
    }

    private var activeEraserSize: CGFloat {
        toolState.eraserMode == .rub ? toolState.rubEraserSize : toolState.eraserWidth
    }

    private var activeEraserSizeCalibration: DrawingStrokeWidthCalibration {
        toolState.eraserMode == .rub
            ? toolState.rubEraserSizeCalibration
            : toolState.eraserWidthCalibration
    }

    private var activeEraserSizePresets: [CGFloat] {
        toolState.eraserMode == .rub
            ? toolState.rubEraserSizePresets
            : toolState.eraserWidthPresets
    }

    private var rubEraserAngleBinding: Binding<Double> {
        Binding {
            Double(toolState.rubEraserAngle)
        } set: { angle in
            toolState.applyRubEraserAngle(CGFloat(angle))
        }
    }

    private var rubEraserAngleText: String {
        String(Int(toolState.rubEraserAngle.rounded()))
    }

    private func applyActiveEraserSize(_ size: CGFloat) {
        if toolState.eraserMode == .rub {
            toolState.applyRubEraserSize(size)
        } else {
            toolState.applyEraserWidth(size)
        }
    }

    private func eraserModeAccessibilityHint(_ mode: DrawingEraserMode) -> String {
        switch mode {
        case .pixel:
            "Erases within the selected size"
        case .object:
            "Removes a whole stroke"
        case .rub:
            "Erases ink with the selected rubber shape and angle"
        }
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

private struct RubEraserGlyph: Shape {
    let shape: DrawingRubEraserShape

    func path(in rect: CGRect) -> Path {
        switch shape {
        case .rectangle:
            Path(rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.25))
        case .chisel:
            Path(rect.insetBy(dx: rect.width * 0.34, dy: rect.height * 0.05))
        case .beveled:
            Path { path in
                path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.25))
                path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.28, y: rect.minY + rect.height * 0.25))
                path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.08, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.28, y: rect.maxY - rect.height * 0.25))
                path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.maxY - rect.height * 0.25))
                path.closeSubpath()
            }
        case .wedge:
            Path { path in
                path.move(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.08))
                path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.08, y: rect.maxY - rect.height * 0.12))
                path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.maxY - rect.height * 0.12))
                path.closeSubpath()
            }
        case .rubberBlock:
            Path(roundedRect: rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.18), cornerRadius: rect.width * 0.22)
        }
    }
}

struct PenPaletteLayoutMetrics {
    static let isCollapsedStorageKey = "penPalette.isCollapsed"
    static let committedOffsetStorageKey = "penPalette.committedOffset"
    static let compactWidthThreshold: CGFloat = 1_180
    static let primaryControlHitSize: CGFloat = 44
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

    static func estimatedPaletteSize(
        isCompact: Bool,
        showsInkControls: Bool,
        paletteColorCount: Int = DrawingPaletteConfiguration.maximumColorCount
    ) -> CGSize {
        let normalizedColorCount = DrawingPaletteConfiguration.normalizedColorCount(paletteColorCount)
        let hiddenColorCount = DrawingPaletteConfiguration.maximumColorCount - normalizedColorCount
        let widthReduction = CGFloat(hiddenColorCount) * 44

        if isCompact {
            return CGSize(
                width: showsInkControls ? max(308, 410 - widthReduction) : 308,
                height: showsInkControls ? 118 : 58
            )
        }

        return CGSize(width: showsInkControls ? 688 - widthReduction : 344, height: 58)
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

    static func encodedCommittedOffset(_ offset: CGSize) -> String {
        let width = offset.width.isFinite ? offset.width : 0
        let height = offset.height.isFinite ? offset.height : 0
        return "\(Double(width)),\(Double(height))"
    }

    static func decodedCommittedOffset(from rawValue: String) -> CGSize? {
        let components = rawValue.split(separator: ",", omittingEmptySubsequences: false)
        guard components.count == 2,
              let width = Double(components[0]),
              let height = Double(components[1]),
              width.isFinite,
              height.isFinite else {
            return nil
        }

        return CGSize(width: width, height: height)
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

private extension View {
    func palettePrimaryHitTarget() -> some View {
        frame(
            width: PenPaletteLayoutMetrics.primaryControlHitSize,
            height: PenPaletteLayoutMetrics.primaryControlHitSize
        )
        .contentShape(.interaction, Rectangle())
    }
}
