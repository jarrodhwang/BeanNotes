//
//  DrawingToolState.swift
//  BeanNotes
//

import Combine
import PencilKit
import SwiftUI

enum DrawingTool: String, CaseIterable, Identifiable {
    case pen
    case pencil
    case highlighter
    case eraser
    case lasso

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pen:
            "Pen"
        case .pencil:
            "Pencil"
        case .highlighter:
            "Highlighter"
        case .eraser:
            "Eraser"
        case .lasso:
            "Lasso"
        }
    }

    var systemImage: String {
        switch self {
        case .pen:
            "pencil.tip"
        case .pencil:
            "pencil"
        case .highlighter:
            "highlighter"
        case .eraser:
            "eraser"
        case .lasso:
            "lasso"
        }
    }
}

struct DrawingColorSwatch: Identifiable, Equatable {
    var index: Int
    var name: String
    var colorHex: String

    var id: Int { index }

    var color: Color {
        Color(hex: colorHex)
    }
}

struct DrawingStrokeWidthCalibration: Equatable {
    let minimumWidth: CGFloat
    let maximumWidth: CGFloat
    let step: CGFloat
    let presets: [CGFloat]

    var range: ClosedRange<CGFloat> {
        minimumWidth...maximumWidth
    }

    var fineStep: CGFloat {
        max(step / 2, 0.05)
    }

    func clamped(_ width: CGFloat) -> CGFloat {
        clamped(width, step: step)
    }

    func clamped(_ width: CGFloat, step: CGFloat) -> CGFloat {
        let bounded = bounded(width)
        guard step > 0 else { return bounded }
        guard bounded > minimumWidth, bounded < maximumWidth else { return bounded }

        let stepped = minimumWidth + ((bounded - minimumWidth) / step).rounded() * step
        return min(max(stepped, minimumWidth), maximumWidth)
    }

    func bounded(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return minimumWidth }
        return min(max(width, minimumWidth), maximumWidth)
    }

    func withStep(_ step: CGFloat) -> DrawingStrokeWidthCalibration {
        DrawingStrokeWidthCalibration(
            minimumWidth: minimumWidth,
            maximumWidth: maximumWidth,
            step: step,
            presets: presets
        )
    }
}

enum DrawingStrokeZoomBehavior: String, CaseIterable, Identifiable {
    static let storageKey = "drawingStrokeZoomBehavior"
    static let defaultBehavior: DrawingStrokeZoomBehavior = .zoomCalibrated

    case pageWidth
    case zoomCalibrated

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pageWidth:
            "Page Width"
        case .zoomCalibrated:
            "Zoom Calibrated"
        }
    }

    var systemImage: String {
        switch self {
        case .pageWidth:
            "doc.text"
        case .zoomCalibrated:
            "scope"
        }
    }

    var description: String {
        switch self {
        case .pageWidth:
            "Keep the same stored page stroke width at every zoom level."
        case .zoomCalibrated:
            "Make new ink finer on the page as you zoom in for detail writing."
        }
    }

    var adjustsForZoomScale: Bool {
        self == .zoomCalibrated
    }
}

struct DrawingStrokeWidthReadout: Equatable {
    let storedWidth: CGFloat
    let effectiveWidth: CGFloat
    let zoomScale: CGFloat
    let zoomBehavior: DrawingStrokeZoomBehavior

    var showsEffectiveWidth: Bool {
        zoomBehavior.adjustsForZoomScale
            && zoomScale > 1.01
            && abs(storedWidth - effectiveWidth) >= 0.05
    }

    var storedWidthText: String {
        Self.pointsText(for: storedWidth)
    }

    var effectiveWidthText: String {
        Self.pointsText(for: effectiveWidth)
    }

    var accessibilityText: String {
        guard showsEffectiveWidth else {
            return "\(storedWidthText) points"
        }

        return "Stored \(storedWidthText) points, page ink \(effectiveWidthText) points at \(zoomPercentageText) zoom"
    }

    private var zoomPercentageText: String {
        guard zoomScale.isFinite, zoomScale > 0 else { return "100%" }
        return "\(Int((zoomScale * 100).rounded()))%"
    }

    static func pointsText(for width: CGFloat) -> String {
        guard width.isFinite else { return "0" }

        if abs(width.rounded() - width) < 0.01 {
            return "\(Int(width.rounded()))"
        }

        let halfStep = (width * 2).rounded() / 2
        if abs(halfStep - width) < 0.01 {
            return String(format: "%.1f", Double(width))
        }

        let rounded = (Double(width) * 100).rounded() / 100
        return String(format: "%.2f", rounded)
    }
}

struct DrawingInkPreviewMetrics: Equatable {
    private static let visualScale: CGFloat = 3
    private static let minimumVisualThickness: CGFloat = 1.5
    private static let maximumVisualThickness: CGFloat = 12

    let storedVisualThickness: CGFloat
    let effectiveVisualThickness: CGFloat
    let accessibilityLabel: String

    init(readout: DrawingStrokeWidthReadout) {
        storedVisualThickness = Self.visualThickness(for: readout.storedWidth)
        effectiveVisualThickness = Self.visualThickness(for: readout.effectiveWidth)
        accessibilityLabel = "Ink preview, \(readout.accessibilityText)"
    }

    static func visualThickness(for width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return minimumVisualThickness }
        return min(max(width * visualScale, minimumVisualThickness), maximumVisualThickness)
    }
}

struct DrawingInkCalibrationStatus: Equatable {
    let zoomText: String
    let pageInkText: String
    let storedInkText: String
    let accessibilityLabel: String

    init(tool: DrawingTool, readout: DrawingStrokeWidthReadout) {
        zoomText = DrawingZoomLevel.percentageText(for: readout.zoomScale)
        pageInkText = "Page \(readout.effectiveWidthText) pt"
        storedInkText = "Stored \(readout.storedWidthText) pt"
        accessibilityLabel = "\(tool.label) ink, page width \(readout.effectiveWidthText) points at \(zoomText) zoom, stored width \(readout.storedWidthText) points"
    }

    static func shouldShow(
        readout: DrawingStrokeWidthReadout,
        isUsingCustomPalette: Bool,
        toolUsesInk: Bool
    ) -> Bool {
        isUsingCustomPalette && toolUsesInk && readout.showsEffectiveWidth
    }
}

enum DrawingStrokeWidthNudgePrecision {
    case normal
    case fine
}

enum DrawingStrokeWidthMode: String, CaseIterable, Identifiable {
    case lightTouch
    case standard
    case precision

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lightTouch:
            "Light Touch"
        case .standard:
            "Standard"
        case .precision:
            "Precision"
        }
    }

    var systemImage: String {
        switch self {
        case .lightTouch:
            "pencil.tip"
        case .standard:
            "lineweight"
        case .precision:
            "scope"
        }
    }

    var description: String {
        switch self {
        case .lightTouch:
            "Sub-point detail ink, smaller presets, and finer nudges for light handwriting."
        case .standard:
            "General-purpose stroke widths for notes, diagrams, and markup."
        case .precision:
            "Fine slider steps while keeping the full stroke-width range."
        }
    }
}

enum DrawingEraserMode: String, CaseIterable, Identifiable {
    case pixel
    case object

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pixel:
            "Pixel"
        case .object:
            "Object"
        }
    }

    var eraserType: PKEraserTool.EraserType {
        switch self {
        case .pixel:
            .fixedWidthBitmap
        case .object:
            .vector
        }
    }
}

enum PencilDoubleTapAction: String, CaseIterable, Identifiable {
    case switchToEraser
    case switchToPreviousTool
    case cycleTools

    var id: String { rawValue }

    var label: String {
        switch self {
        case .switchToEraser:
            "Switch to Eraser"
        case .switchToPreviousTool:
            "Previous Tool"
        case .cycleTools:
            "Cycle Tools"
        }
    }
}

enum PenPaletteMode: String, CaseIterable, Identifiable {
    case custom
    case applePencil

    var id: String { rawValue }

    var label: String {
        switch self {
        case .custom:
            "BeanNotes Custom"
        case .applePencil:
            "Apple Pencil"
        }
    }

    var description: String {
        switch self {
        case .custom:
            "Use BeanNotes' compact floating palette."
        case .applePencil:
            "Use Apple's PencilKit tool picker."
        }
    }
}

enum DrawingInputMode: String, CaseIterable, Identifiable {
    static let storageKey = "drawingInputMode"
    static let defaultMode: DrawingInputMode = .pencilOnly

    case pencilOnly
    case anyInput

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pencilOnly:
            "Pencil Only"
        case .anyInput:
            "Pencil or Finger"
        }
    }

    var systemImage: String {
        switch self {
        case .pencilOnly:
            "hand.raised"
        case .anyInput:
            "scribble"
        }
    }

    var description: String {
        switch self {
        case .pencilOnly:
            "Finger touches scroll, zoom, and move around the page without leaving stray marks."
        case .anyInput:
            "Finger touches can draw too; use two fingers to scroll or zoom the page."
        }
    }

    var drawingPolicy: PKCanvasViewDrawingPolicy {
        switch self {
        case .pencilOnly:
            .pencilOnly
        case .anyInput:
            .anyInput
        }
    }
}

enum DrawingRenderQuality: String, CaseIterable, Identifiable {
    static let storageKey = "drawingRenderQuality"
    static let defaultQuality: DrawingRenderQuality = .ultraFine

    case balanced
    case highResolution
    case ultraFine

    var id: String { rawValue }

    var label: String {
        switch self {
        case .balanced:
            "Balanced"
        case .highResolution:
            "High Resolution"
        case .ultraFine:
            "Ultra Fine"
        }
    }

    var systemImage: String {
        switch self {
        case .balanced:
            "speedometer"
        case .highResolution:
            "magnifyingglass"
        case .ultraFine:
            "scope"
        }
    }

    var description: String {
        switch self {
        case .balanced:
            "Lower memory use for long notebooks and older iPads."
        case .highResolution:
            "Sharper strokes, backgrounds, and image attachments while zooming."
        case .ultraFine:
            "Maximum zoom detail for careful handwriting and diagrams on newer iPads."
        }
    }

    var maximumZoomScale: CGFloat {
        switch self {
        case .balanced:
            3.5
        case .highResolution:
            4.5
        case .ultraFine:
            6
        }
    }

    var maximumZoomFitMultiplier: CGFloat {
        switch self {
        case .balanced:
            3
        case .highResolution:
            4
        case .ultraFine:
            5
        }
    }

    var backgroundScaleMultiplier: CGFloat {
        switch self {
        case .balanced:
            1.5
        case .highResolution:
            2
        case .ultraFine:
            2.75
        }
    }

    var drawingScaleMultiplier: CGFloat {
        switch self {
        case .balanced:
            2
        case .highResolution:
            2.5
        case .ultraFine:
            3.25
        }
    }

    var imageScaleMultiplier: CGFloat {
        switch self {
        case .balanced:
            1.5
        case .highResolution:
            2
        case .ultraFine:
            2.6
        }
    }
}

struct DrawingRenderResolutionStatus: Equatable {
    let qualityLabel: String
    let zoomText: String
    let drawingScaleText: String
    let maximumZoomText: String
    let maximumDrawingScaleText: String
    let menuSummary: String
    let stripText: String
    let settingsSummary: String
    let accessibilityLabel: String

    init(
        quality: DrawingRenderQuality,
        zoomScale: CGFloat,
        screenScale: CGFloat
    ) {
        let normalizedZoomScale = Self.normalizedPositive(zoomScale, fallback: 1)
        let normalizedScreenScale = Self.normalizedPositive(screenScale, fallback: 1)
        let drawingBackingScale = Self.drawingBackingScale(
            quality: quality,
            zoomScale: normalizedZoomScale,
            screenScale: normalizedScreenScale
        )
        let maximumDrawingBackingScale = Self.maximumDrawingBackingScale(
            quality: quality,
            screenScale: normalizedScreenScale
        )

        qualityLabel = quality.label
        zoomText = DrawingZoomLevel.percentageText(for: normalizedZoomScale)
        drawingScaleText = Self.scaleText(for: drawingBackingScale)
        maximumZoomText = DrawingZoomLevel.percentageText(for: quality.maximumZoomScale)
        maximumDrawingScaleText = Self.scaleText(for: maximumDrawingBackingScale)
        menuSummary = "\(quality.label) detail, \(drawingScaleText) drawing backing"
        stripText = "\(drawingScaleText) backing"
        settingsSummary = "Native PencilKit detail tracks zoom up to \(maximumZoomText), reaching \(maximumDrawingScaleText) on this device. Live and saved strokes stay screen-sharp."
        accessibilityLabel = "\(quality.label) detail, \(zoomText) zoom, drawing backing \(Self.accessibilityScaleText(for: drawingBackingScale))"
    }

    static func drawingBackingScale(
        quality: DrawingRenderQuality,
        zoomScale: CGFloat,
        screenScale: CGFloat
    ) -> CGFloat {
        let normalizedZoomScale = Self.normalizedPositive(zoomScale, fallback: 1)
        let normalizedScreenScale = Self.normalizedPositive(screenScale, fallback: 1)
        return max(normalizedZoomScale, 1) * normalizedScreenScale
    }

    static func maximumDrawingBackingScale(
        quality: DrawingRenderQuality,
        screenScale: CGFloat
    ) -> CGFloat {
        normalizedPositive(screenScale, fallback: 1) * quality.maximumZoomScale
    }

    private static func normalizedPositive(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return fallback }
        return value
    }

    private static func scaleText(for scale: CGFloat) -> String {
        guard scale.isFinite, scale > 0 else { return "1x" }

        if abs(scale.rounded() - scale) < 0.01 {
            return "\(Int(scale.rounded()))x"
        }

        return String(format: "%.1fx", Double(scale))
    }

    private static func accessibilityScaleText(for scale: CGFloat) -> String {
        scaleText(for: scale).replacingOccurrences(of: "x", with: " times")
    }
}

@MainActor
final class DrawingToolState: ObservableObject {
    private enum DefaultsKey {
        static let selectedTool = "drawingToolState.selectedTool"
        static let previousTool = "drawingToolState.previousTool"
        static let pencilColor = "drawingToolState.pencilColor"
        static let penColor = "drawingToolState.penColor"
        static let highlighterColor = "drawingToolState.highlighterColor"
        static let pencilWidth = "drawingToolState.pencilWidth"
        static let penWidth = "drawingToolState.penWidth"
        static let highlighterWidth = "drawingToolState.highlighterWidth"
        static let eraserMode = "drawingToolState.eraserMode"
        static let eraserWidth = "drawingToolState.eraserWidth"
        static let penPaletteColors = "drawingToolState.penPaletteColors"
        static let pencilPaletteColors = "drawingToolState.pencilPaletteColors"
        static let highlighterPaletteColors = "drawingToolState.highlighterPaletteColors"
        static let widthMode = "drawingToolState.widthMode"
    }

    private let defaults: UserDefaults

    @Published var selectedTool: DrawingTool = .pen {
        didSet { defaults.set(selectedTool.rawValue, forKey: DefaultsKey.selectedTool) }
    }

    @Published var previousTool: DrawingTool = .pen {
        didSet { defaults.set(previousTool.rawValue, forKey: DefaultsKey.previousTool) }
    }

    @Published var pencilColor: Color = .black {
        didSet { defaults.set(pencilColor.hexRGB, forKey: DefaultsKey.pencilColor) }
    }

    @Published var penColor: Color = .black {
        didSet { defaults.set(penColor.hexRGB, forKey: DefaultsKey.penColor) }
    }

    @Published var highlighterColor: Color = .yellow {
        didSet { defaults.set(highlighterColor.hexRGB, forKey: DefaultsKey.highlighterColor) }
    }

    @Published private(set) var pencilWidth: CGFloat = 3.5 {
        didSet {
            defaults.set(Double(pencilWidth), forKey: DefaultsKey.pencilWidth)
        }
    }

    @Published private(set) var penWidth: CGFloat = 2.5 {
        didSet {
            defaults.set(Double(penWidth), forKey: DefaultsKey.penWidth)
        }
    }

    @Published private(set) var highlighterWidth: CGFloat = 10 {
        didSet {
            defaults.set(Double(highlighterWidth), forKey: DefaultsKey.highlighterWidth)
        }
    }

    @Published var eraserMode: DrawingEraserMode = .pixel {
        didSet { defaults.set(eraserMode.rawValue, forKey: DefaultsKey.eraserMode) }
    }

    @Published private(set) var eraserWidth: CGFloat = 16 {
        didSet { defaults.set(Double(eraserWidth), forKey: DefaultsKey.eraserWidth) }
    }

    @Published private var penPaletteColorHexes: [String] = [] {
        didSet { defaults.set(Self.serializedPalette(penPaletteColorHexes), forKey: DefaultsKey.penPaletteColors) }
    }

    @Published private var pencilPaletteColorHexes: [String] = [] {
        didSet { defaults.set(Self.serializedPalette(pencilPaletteColorHexes), forKey: DefaultsKey.pencilPaletteColors) }
    }

    @Published private var highlighterPaletteColorHexes: [String] = [] {
        didSet { defaults.set(Self.serializedPalette(highlighterPaletteColorHexes), forKey: DefaultsKey.highlighterPaletteColors) }
    }

    @Published var widthMode: DrawingStrokeWidthMode = .lightTouch {
        didSet { defaults.set(widthMode.rawValue, forKey: DefaultsKey.widthMode) }
    }

    @Published private(set) var temporaryEraserActive = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedTool = Self.storedTool(defaults, key: DefaultsKey.selectedTool, fallback: .pen)
        previousTool = Self.storedTool(defaults, key: DefaultsKey.previousTool, fallback: .pen)
        pencilColor = Self.storedColor(defaults, key: DefaultsKey.pencilColor, fallback: Self.defaultColorHex(for: .pencil))
        penColor = Self.storedColor(defaults, key: DefaultsKey.penColor, fallback: Self.defaultColorHex(for: .pen))
        highlighterColor = Self.storedColor(
            defaults,
            key: DefaultsKey.highlighterColor,
            fallback: Self.defaultColorHex(for: .highlighter)
        )
        pencilWidth = Self.storedWidth(
            defaults,
            key: DefaultsKey.pencilWidth,
            fallback: Self.defaultStrokeWidth(for: .pencil),
            for: .pencil
        )
        penWidth = Self.storedWidth(
            defaults,
            key: DefaultsKey.penWidth,
            fallback: Self.defaultStrokeWidth(for: .pen),
            for: .pen
        )
        highlighterWidth = Self.storedWidth(
            defaults,
            key: DefaultsKey.highlighterWidth,
            fallback: Self.defaultStrokeWidth(for: .highlighter),
            for: .highlighter
        )
        eraserMode = Self.storedEraserMode(defaults, key: DefaultsKey.eraserMode, fallback: .pixel)
        eraserWidth = Self.storedWidth(
            defaults,
            key: DefaultsKey.eraserWidth,
            fallback: Self.defaultStrokeWidth(for: .eraser),
            for: .eraser
        )
        penPaletteColorHexes = Self.storedPalette(
            defaults,
            key: DefaultsKey.penPaletteColors,
            fallback: Self.defaultPaletteColorHexes(for: .pen)
        )
        pencilPaletteColorHexes = Self.storedPalette(
            defaults,
            key: DefaultsKey.pencilPaletteColors,
            fallback: Self.defaultPaletteColorHexes(for: .pencil)
        )
        highlighterPaletteColorHexes = Self.storedPalette(
            defaults,
            key: DefaultsKey.highlighterPaletteColors,
            fallback: Self.defaultPaletteColorHexes(for: .highlighter)
        )
        widthMode = Self.storedWidthMode(defaults, key: DefaultsKey.widthMode, fallback: .lightTouch)
    }

    var activeColorTool: DrawingTool {
        switch selectedTool {
        case .pen, .pencil, .highlighter:
            return selectedTool
        case .eraser, .lasso:
            return previousTool.usesInkColor ? previousTool : .pen
        }
    }

    var activeInkColor: Color {
        inkColor(for: activeColorTool)
    }

    var activeStrokeWidth: CGFloat {
        strokeWidth(for: activeColorTool)
    }

    var activeWidthCalibration: DrawingStrokeWidthCalibration {
        Self.widthCalibration(for: activeColorTool, mode: widthMode)
    }

    var activeWidthStep: CGFloat {
        activeWidthCalibration.step
    }

    var activeFineWidthStep: CGFloat {
        activeWidthCalibration.fineStep
    }

    var selectedToolUsesInkColor: Bool {
        selectedTool.usesInkColor
    }

    var eraserWidthCalibration: DrawingStrokeWidthCalibration {
        Self.widthCalibration(for: .eraser)
    }

    var eraserWidthPresets: [CGFloat] {
        eraserWidthCalibration.presets
    }

    func inkColor(for tool: DrawingTool) -> Color {
        switch tool {
        case .pencil:
            pencilColor
        case .highlighter:
            highlighterColor
        default:
            penColor
        }
    }

    func strokeWidth(for tool: DrawingTool) -> CGFloat {
        switch tool {
        case .pencil:
            Self.widthCalibration(for: .pencil, mode: widthMode).bounded(pencilWidth)
        case .highlighter:
            Self.widthCalibration(for: .highlighter, mode: widthMode).bounded(highlighterWidth)
        default:
            Self.widthCalibration(for: .pen, mode: widthMode).bounded(penWidth)
        }
    }

    func effectiveStrokeWidth(
        for tool: DrawingTool,
        zoomScale: CGFloat,
        zoomBehavior: DrawingStrokeZoomBehavior
    ) -> CGFloat {
        let baseWidth = strokeWidth(for: tool)
        guard zoomBehavior.adjustsForZoomScale else { return baseWidth }

        let detailScale = max(zoomScale.isFinite ? zoomScale : 1, 1)
        let calibration = Self.widthCalibration(for: tool, mode: widthMode)
        return calibration.bounded(baseWidth / detailScale)
    }

    func strokeWidthReadout(
        for tool: DrawingTool,
        zoomScale: CGFloat,
        zoomBehavior: DrawingStrokeZoomBehavior
    ) -> DrawingStrokeWidthReadout {
        DrawingStrokeWidthReadout(
            storedWidth: strokeWidth(for: tool),
            effectiveWidth: effectiveStrokeWidth(for: tool, zoomScale: zoomScale, zoomBehavior: zoomBehavior),
            zoomScale: zoomScale,
            zoomBehavior: zoomBehavior
        )
    }

    func widthPresets(for tool: DrawingTool? = nil) -> [CGFloat] {
        Self.widthCalibration(for: tool ?? activeColorTool, mode: widthMode).presets
    }

    func paletteSwatches(
        for tool: DrawingTool? = nil,
        displaying colorCount: Int? = nil
    ) -> [DrawingColorSwatch] {
        let swatchTool = tool ?? activeColorTool
        return paletteColorHexes(for: swatchTool, displaying: colorCount).enumerated().map { index, hex in
            DrawingColorSwatch(index: index, name: Self.colorName(for: hex), colorHex: hex)
        }
    }

    func primaryPaletteColor(for tool: DrawingTool? = nil) -> Color {
        paletteColor(at: 0, for: tool)
    }

    func paletteIndexMatchingActiveColor(
        for tool: DrawingTool? = nil,
        preferredIndex: Int? = nil,
        displaying colorCount: Int? = nil
    ) -> Int {
        let swatchTool = tool ?? activeColorTool
        let activeColorHex = Self.normalizedHex(UIColor(inkColor(for: swatchTool)).hexRGB)
        let colors = paletteColorHexes(for: swatchTool, displaying: colorCount)
        if let preferredIndex,
           colors.indices.contains(preferredIndex),
           Self.normalizedHex(colors[preferredIndex]) == activeColorHex {
            return preferredIndex
        }

        return colors.firstIndex { Self.normalizedHex($0) == activeColorHex } ?? 0
    }

    /// Keeps the active ink aligned with the swatches currently visible in the palette UI.
    func ensureActivePaletteColorIsVisible(
        for tool: DrawingTool? = nil,
        preferredIndex: Int? = nil,
        displaying colorCount: Int
    ) -> Int {
        let swatchTool = tool ?? activeColorTool
        let selectedIndex = paletteIndexMatchingActiveColor(
            for: swatchTool,
            preferredIndex: preferredIndex,
            displaying: colorCount
        )
        let selectedColor = paletteColor(at: selectedIndex, for: swatchTool)
        let selectedColorHex = Self.normalizedHex(UIColor(selectedColor).hexRGB)
        let activeColorHex = Self.normalizedHex(UIColor(inkColor(for: swatchTool)).hexRGB)

        if selectedColorHex != activeColorHex {
            setInkColor(selectedColor, for: swatchTool)
        }

        return selectedIndex
    }

    func paletteColor(at index: Int, for tool: DrawingTool? = nil) -> Color {
        let swatchTool = tool ?? activeColorTool
        let colors = paletteColorHexes(for: swatchTool)
        guard colors.indices.contains(index) else {
            return inkColor(for: swatchTool)
        }
        return Color(hex: colors[index])
    }

    var activeInkType: PKInkingTool.InkType? {
        switch selectedTool {
        case .pen:
            .pen
        case .pencil:
            .pencil
        case .highlighter:
            .marker
        case .eraser, .lasso:
            nil
        }
    }

    var pkToolSignature: String {
        pkToolSignature(zoomScale: 1, zoomBehavior: .pageWidth)
    }

    func pkToolSignature(
        zoomScale: CGFloat,
        zoomBehavior: DrawingStrokeZoomBehavior
    ) -> String {
        switch selectedTool {
        case .pen:
            let width = effectiveStrokeWidth(for: .pen, zoomScale: zoomScale, zoomBehavior: zoomBehavior)
            return "pen:\(penColor.hexRGB):\(widthSignatureValue(width)):\(zoomBehavior.rawValue)"
        case .pencil:
            let width = effectiveStrokeWidth(for: .pencil, zoomScale: zoomScale, zoomBehavior: zoomBehavior)
            return "pencil:\(pencilColor.hexRGB):\(widthSignatureValue(width)):\(zoomBehavior.rawValue)"
        case .highlighter:
            let width = effectiveStrokeWidth(for: .highlighter, zoomScale: zoomScale, zoomBehavior: zoomBehavior)
            return "highlighter:\(highlighterColor.hexRGB):\(widthSignatureValue(width)):\(zoomBehavior.rawValue)"
        case .eraser:
            return "eraser:\(eraserMode.rawValue):\(widthSignatureValue(eraserWidth))"
        case .lasso:
            return "lasso"
        }
    }

    func select(_ tool: DrawingTool) {
        if temporaryEraserActive {
            temporaryEraserActive = false
        }

        if tool != .eraser, tool != selectedTool {
            previousTool = selectedTool == .eraser ? previousTool : selectedTool
        }

        if tool == .eraser, selectedTool != .eraser {
            previousTool = selectedTool
        }

        selectedTool = tool
    }

    func selectPaletteColor(_ color: Color) {
        applyActiveColor(color, remembersInPalette: false)
    }

    func setPrimaryPaletteColor(_ color: Color) {
        setPaletteColor(color, at: 0)
    }

    func setPaletteColor(_ color: Color, at index: Int, for tool: DrawingTool? = nil) {
        let tool = tool ?? activeColorTool
        guard tool.usesInkColor else { return }

        let colorHex = Self.normalizedHex(UIColor(color).hexRGB)
        var colors = paletteColorHexes(for: tool)
        guard !colors.isEmpty else {
            setInkColor(color, for: tool)
            setPaletteColorHexes([colorHex], for: tool)
            return
        }

        let boundedIndex = min(max(index, 0), colors.count - 1)
        colors[boundedIndex] = colorHex

        if selectedTool.usesInkColor == false {
            select(tool)
        }

        setInkColor(color, for: tool)
        setPaletteColorHexes(Self.normalizedPalette(colors), for: tool)
    }

    func applyActiveColor(_ color: Color, remembersInPalette: Bool = true) {
        let tool = activeColorTool

        if selectedTool.usesInkColor == false {
            select(tool)
        }

        setInkColor(color, for: tool)

        if remembersInPalette {
            rememberPaletteColor(color, for: tool)
        }
    }

    func applyActiveWidth(_ width: CGFloat) {
        applyActiveWidth(width, step: activeWidthStep)
    }

    private func applyActiveWidth(_ width: CGFloat, step: CGFloat) {
        switch activeColorTool {
        case .pencil:
            pencilWidth = Self.widthCalibration(for: .pencil, mode: widthMode).clamped(width, step: step)
        case .pen:
            penWidth = Self.widthCalibration(for: .pen, mode: widthMode).clamped(width, step: step)
        case .highlighter:
            highlighterWidth = Self.widthCalibration(for: .highlighter, mode: widthMode).clamped(width, step: step)
        case .eraser, .lasso:
            select(.pen)
            penWidth = Self.widthCalibration(for: .pen, mode: widthMode).clamped(width, step: step)
        }
    }

    func selectWidthMode(_ mode: DrawingStrokeWidthMode) {
        widthMode = mode
    }

    func toggleWidthMode() {
        switch widthMode {
        case .lightTouch:
            selectWidthMode(.standard)
        case .standard:
            selectWidthMode(.precision)
        case .precision:
            selectWidthMode(.lightTouch)
        }
    }

    func nudgeActiveWidth(
        by steps: CGFloat,
        precision: DrawingStrokeWidthNudgePrecision = .normal
    ) {
        guard steps.isFinite, steps != 0 else { return }

        let step: CGFloat
        switch precision {
        case .normal:
            step = activeWidthStep
        case .fine:
            step = activeFineWidthStep
        }

        applyActiveWidth(activeStrokeWidth + step * steps, step: step)
    }

    @discardableResult
    func lockActiveWidthToEffectivePageInk(
        zoomScale: CGFloat,
        zoomBehavior: DrawingStrokeZoomBehavior
    ) -> Bool {
        guard selectedToolUsesInkColor else { return false }

        let readout = strokeWidthReadout(
            for: activeColorTool,
            zoomScale: zoomScale,
            zoomBehavior: zoomBehavior
        )
        guard readout.showsEffectiveWidth else { return false }

        applyActiveWidth(readout.effectiveWidth, step: activeFineWidthStep)
        return true
    }

    func selectEraserMode(_ mode: DrawingEraserMode) {
        eraserMode = mode
        select(.eraser)
    }

    func applyEraserWidth(_ width: CGFloat) {
        eraserWidth = eraserWidthCalibration.clamped(width)
        select(.eraser)
    }

    func activateTemporaryEraser() {
        guard selectedTool != .eraser else { return }
        previousTool = selectedTool
        temporaryEraserActive = true
        selectedTool = .eraser
    }

    func restoreAfterTemporaryEraser() {
        guard temporaryEraserActive else { return }
        temporaryEraserActive = false
        selectedTool = previousTool
    }

    func handleDoubleTap(action: PencilDoubleTapAction) {
        switch action {
        case .switchToEraser:
            if selectedTool == .eraser {
                restorePreviousTool()
            } else {
                activateTemporaryEraser()
            }
        case .switchToPreviousTool:
            restorePreviousTool()
        case .cycleTools:
            cycleTool()
        }
    }

    func makePKTool(
        zoomScale: CGFloat = 1,
        zoomBehavior: DrawingStrokeZoomBehavior = .pageWidth
    ) -> PKTool {
        switch selectedTool {
        case .pen:
            PKInkingTool(
                activeInkType ?? .pen,
                color: UIColor(penColor),
                width: effectiveStrokeWidth(for: .pen, zoomScale: zoomScale, zoomBehavior: zoomBehavior)
            )
        case .pencil:
            PKInkingTool(
                activeInkType ?? .pencil,
                color: UIColor(pencilColor),
                width: effectiveStrokeWidth(for: .pencil, zoomScale: zoomScale, zoomBehavior: zoomBehavior)
            )
        case .highlighter:
            PKInkingTool(
                activeInkType ?? .marker,
                color: UIColor(highlighterColor).withAlphaComponent(0.5),
                width: effectiveStrokeWidth(
                    for: .highlighter,
                    zoomScale: zoomScale,
                    zoomBehavior: zoomBehavior
                )
            )
        case .eraser:
            switch eraserMode {
            case .pixel:
                PKEraserTool(.fixedWidthBitmap, width: eraserWidth)
            case .object:
                // PencilKit's vector eraser has no configurable native width. PageCanvasView
                // supplies the adjustable whole-stroke hit testing for this mode instead.
                PKEraserTool(.vector)
            }
        case .lasso:
            PKLassoTool()
        }
    }

    private func restorePreviousTool() {
        let current = selectedTool
        selectedTool = previousTool
        previousTool = current == .eraser ? previousTool : current
        temporaryEraserActive = false
    }

    private func cycleTool() {
        let tools = DrawingTool.allCases
        guard let index = tools.firstIndex(of: selectedTool) else {
            select(.pen)
            return
        }
        let nextIndex = tools.index(after: index)
        select(nextIndex == tools.endIndex ? tools[0] : tools[nextIndex])
    }

    private func widthSignatureValue(_ width: CGFloat) -> Int {
        Int((width * 100).rounded())
    }

    private static func storedTool(_ defaults: UserDefaults, key: String, fallback: DrawingTool) -> DrawingTool {
        guard let rawValue = defaults.string(forKey: key) else { return fallback }
        return DrawingTool(rawValue: rawValue) ?? fallback
    }

    private static func storedEraserMode(
        _ defaults: UserDefaults,
        key: String,
        fallback: DrawingEraserMode
    ) -> DrawingEraserMode {
        guard let rawValue = defaults.string(forKey: key) else { return fallback }
        return DrawingEraserMode(rawValue: rawValue) ?? fallback
    }

    private static func storedWidthMode(
        _ defaults: UserDefaults,
        key: String,
        fallback: DrawingStrokeWidthMode
    ) -> DrawingStrokeWidthMode {
        guard let rawValue = defaults.string(forKey: key) else { return fallback }
        return DrawingStrokeWidthMode(rawValue: rawValue) ?? fallback
    }

    private static func storedColor(_ defaults: UserDefaults, key: String, fallback: String) -> Color {
        Color(hex: defaults.string(forKey: key) ?? fallback)
    }

    static func widthCalibration(for tool: DrawingTool) -> DrawingStrokeWidthCalibration {
        switch tool {
        case .pencil:
            return DrawingStrokeWidthCalibration(
                minimumWidth: 1,
                maximumWidth: 18,
                step: 0.5,
                presets: [2, 4, 6, 10]
            )
        case .highlighter:
            return DrawingStrokeWidthCalibration(
                minimumWidth: 4,
                maximumWidth: 44,
                step: 1,
                presets: [8, 14, 22, 32]
            )
        case .eraser:
            let range = fixedWidthBitmapEraserRange
            return DrawingStrokeWidthCalibration(
                minimumWidth: range.lowerBound,
                maximumWidth: range.upperBound,
                step: 2,
                presets: fixedWidthBitmapEraserPresets(in: range)
            )
        case .pen, .lasso:
            return DrawingStrokeWidthCalibration(
                minimumWidth: 0.5,
                maximumWidth: 24,
                step: 0.5,
                presets: [1, 3, 5, 8]
            )
        }
    }

    private static func widthCalibration(
        for tool: DrawingTool,
        mode: DrawingStrokeWidthMode
    ) -> DrawingStrokeWidthCalibration {
        switch mode {
        case .lightTouch:
            lightTouchWidthCalibration(for: tool)
        case .standard:
            widthCalibration(for: tool)
        case .precision:
            widthCalibration(for: tool).withStep(precisionWidthStep(for: tool))
        }
    }

    private static func lightTouchWidthCalibration(for tool: DrawingTool) -> DrawingStrokeWidthCalibration {
        switch tool {
        case .pencil:
            DrawingStrokeWidthCalibration(
                minimumWidth: 0.5,
                maximumWidth: 12,
                step: 0.25,
                presets: [1, 1.5, 2.5, 4]
            )
        case .highlighter:
            DrawingStrokeWidthCalibration(
                minimumWidth: 3,
                maximumWidth: 28,
                step: 0.5,
                presets: [4, 6, 10, 14]
            )
        case .eraser:
            widthCalibration(for: .eraser)
        case .pen, .lasso:
            DrawingStrokeWidthCalibration(
                minimumWidth: 0.25,
                maximumWidth: 12,
                step: 0.25,
                presets: [0.5, 1, 1.5, 2.5]
            )
        }
    }

    private static func precisionWidthStep(for tool: DrawingTool) -> CGFloat {
        switch tool {
        case .highlighter:
            0.5
        case .pen, .pencil, .lasso:
            0.1
        case .eraser:
            widthCalibration(for: .eraser).step
        }
    }

    private static func storedWidth(
        _ defaults: UserDefaults,
        key: String,
        fallback: CGFloat,
        for tool: DrawingTool
    ) -> CGFloat {
        guard defaults.object(forKey: key) != nil else {
            return boundedWidth(fallback, for: tool)
        }
        return boundedWidth(CGFloat(defaults.double(forKey: key)), for: tool)
    }

    private static var fixedWidthBitmapEraserRange: ClosedRange<CGFloat> {
        let range = PKEraserTool.EraserType.fixedWidthBitmap.validWidthRange
        guard range.lowerBound.isFinite,
              range.upperBound.isFinite,
              range.lowerBound > 0,
              range.lowerBound <= range.upperBound else {
            return 16...64
        }
        return range
    }

    private static func fixedWidthBitmapEraserPresets(
        in range: ClosedRange<CGFloat>
    ) -> [CGFloat] {
        let preferred: [CGFloat] = [range.lowerBound, 32, 48, 64, range.upperBound]
        var presets: [CGFloat] = []

        for width in preferred {
            let bounded = min(max(width, range.lowerBound), range.upperBound)
            guard !presets.contains(where: { abs($0 - bounded) < 0.01 }) else { continue }
            presets.append(bounded)
            if presets.count == 4 {
                break
            }
        }

        return presets
    }

    private static func boundedWidth(_ width: CGFloat, for tool: DrawingTool) -> CGFloat {
        let bounds = storageWidthBounds(for: tool)
        guard width.isFinite else { return bounds.lowerBound }

        return min(max(width, bounds.lowerBound), bounds.upperBound)
    }

    private static func storageWidthBounds(for tool: DrawingTool) -> ClosedRange<CGFloat> {
        switch tool {
        case .pencil:
            0.5...widthCalibration(for: .pencil).maximumWidth
        case .highlighter:
            3...widthCalibration(for: .highlighter).maximumWidth
        case .eraser:
            widthCalibration(for: .eraser).range
        case .pen, .lasso:
            0.25...widthCalibration(for: .pen).maximumWidth
        }
    }

    private static func defaultStrokeWidth(for tool: DrawingTool) -> CGFloat {
        switch tool {
        case .pen:
            2.5
        case .pencil:
            3.5
        case .highlighter:
            10
        case .eraser:
            PKEraserTool.EraserType.fixedWidthBitmap.defaultWidth
        case .lasso:
            defaultStrokeWidth(for: .pen)
        }
    }

    private static func defaultColorHex(for tool: DrawingTool) -> String {
        defaultPaletteColorHexes(for: tool).first ?? "#000000"
    }

    private func paletteColorHexes(
        for tool: DrawingTool,
        displaying colorCount: Int? = nil
    ) -> [String] {
        let colors: [String]

        switch tool {
        case .pen:
            colors = penPaletteColorHexes
        case .pencil:
            colors = pencilPaletteColorHexes
        case .highlighter:
            colors = highlighterPaletteColorHexes
        case .eraser, .lasso:
            colors = penPaletteColorHexes
        }

        guard let colorCount else { return colors }
        return Array(colors.prefix(DrawingPaletteConfiguration.normalizedColorCount(colorCount)))
    }

    private func setPaletteColorHexes(_ colorHexes: [String], for tool: DrawingTool) {
        switch tool {
        case .pen:
            penPaletteColorHexes = colorHexes
        case .pencil:
            pencilPaletteColorHexes = colorHexes
        case .highlighter:
            highlighterPaletteColorHexes = colorHexes
        case .eraser, .lasso:
            penPaletteColorHexes = colorHexes
        }
    }

    private func setInkColor(_ color: Color, for tool: DrawingTool) {
        switch tool {
        case .pencil:
            pencilColor = color
        case .pen:
            penColor = color
        case .highlighter:
            highlighterColor = color
        case .eraser, .lasso:
            penColor = color
        }
    }

    private func rememberPaletteColor(_ color: Color, for tool: DrawingTool) {
        guard tool.usesInkColor else { return }

        let colorHex = Self.normalizedHex(UIColor(color).hexRGB)
        var colors = paletteColorHexes(for: tool)
        colors.removeAll { Self.normalizedHex($0) == colorHex }
        colors.insert(colorHex, at: 0)

        colors = Self.normalizedPalette(colors, removesDuplicates: true)
        setPaletteColorHexes(colors, for: tool)
    }

    private static func storedPalette(
        _ defaults: UserDefaults,
        key: String,
        fallback: [String]
    ) -> [String] {
        guard let stored = defaults.string(forKey: key), !stored.isEmpty else {
            return fallback
        }

        let colors = stored
            .split(separator: "|")
            .map(String.init)
        let normalized = normalizedPalette(colors)
        return normalized.isEmpty ? fallback : normalized
    }

    private static func serializedPalette(_ colors: [String]) -> String {
        normalizedPalette(colors).joined(separator: "|")
    }

    private static func normalizedPalette(_ colors: [String], removesDuplicates: Bool = false) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []

        for color in colors {
            let hex = normalizedHex(color)
            guard hex.count == 7 else { continue }
            if removesDuplicates {
                guard !seen.contains(hex) else { continue }
                seen.insert(hex)
            }
            normalized.append(hex)
        }

        return Array(normalized.prefix(DrawingPaletteConfiguration.maximumColorCount))
    }

    private static func normalizedHex(_ colorHex: String) -> String {
        UIColor(hex: colorHex).hexRGB.uppercased()
    }

    private static func defaultPaletteColorHexes(for tool: DrawingTool) -> [String] {
        switch tool {
        case .pen:
            ["#000000", "#0A84FF", "#FF3B30", "#34C759", "#FF9500", "#FFFFFF", "#AF52DE", "#8E8E93"]
        case .pencil:
            ["#1C1C1E", "#636366", "#0A84FF", "#FF3B30", "#34C759", "#A2845E", "#AF52DE", "#FFFFFF"]
        case .highlighter:
            ["#FFE45E", "#FF9F0A", "#FF2D55", "#64D2FF", "#30D158", "#BF5AF2", "#0A84FF", "#FFFFFF"]
        case .eraser, .lasso:
            defaultPaletteColorHexes(for: .pen)
        }
    }

    private static func colorName(for colorHex: String) -> String {
        switch normalizedHex(colorHex) {
        case "#000000":
            return "Black"
        case "#1C1C1E":
            return "Graphite"
        case "#636366", "#8E8E93":
            return "Gray"
        case "#0A84FF":
            return "Blue"
        case "#FF3B30":
            return "Red"
        case "#34C759", "#30D158":
            return "Green"
        case "#FFE45E":
            return "Yellow"
        case "#FF9500", "#FF9F0A":
            return "Orange"
        case "#FF2D55":
            return "Pink"
        case "#64D2FF":
            return "Cyan"
        case "#AF52DE", "#BF5AF2":
            return "Purple"
        case "#A2845E":
            return "Brown"
        case "#FFFFFF":
            return "White"
        default:
            return "Custom \(normalizedHex(colorHex))"
        }
    }
}

private extension DrawingTool {
    var usesInkColor: Bool {
        switch self {
        case .pen, .pencil, .highlighter:
            true
        case .eraser, .lasso:
            false
        }
    }
}
