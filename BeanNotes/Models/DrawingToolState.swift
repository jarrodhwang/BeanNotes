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
            .bitmap
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

enum DrawingRenderQuality: String, CaseIterable, Identifiable {
    static let storageKey = "drawingRenderQuality"
    static let defaultQuality: DrawingRenderQuality = .highResolution

    case balanced
    case highResolution

    var id: String { rawValue }

    var label: String {
        switch self {
        case .balanced:
            "Balanced"
        case .highResolution:
            "High Resolution"
        }
    }

    var description: String {
        switch self {
        case .balanced:
            "Lower memory use for long notebooks and older iPads."
        case .highResolution:
            "Sharper strokes, backgrounds, and image attachments while zooming."
        }
    }

    var maximumZoomScale: CGFloat {
        switch self {
        case .balanced:
            3.5
        case .highResolution:
            4.5
        }
    }

    var maximumZoomFitMultiplier: CGFloat {
        switch self {
        case .balanced:
            3
        case .highResolution:
            4
        }
    }

    var backgroundScaleMultiplier: CGFloat {
        switch self {
        case .balanced:
            1.5
        case .highResolution:
            2
        }
    }

    var drawingScaleMultiplier: CGFloat {
        switch self {
        case .balanced:
            2
        case .highResolution:
            2.5
        }
    }

    var imageScaleMultiplier: CGFloat {
        switch self {
        case .balanced:
            1.5
        case .highResolution:
            2
        }
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
        static let penPaletteColors = "drawingToolState.penPaletteColors"
        static let pencilPaletteColors = "drawingToolState.pencilPaletteColors"
        static let highlighterPaletteColors = "drawingToolState.highlighterPaletteColors"
    }

    private static let maximumPaletteColorCount = 8

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

    @Published var pencilWidth: CGFloat = 6 {
        didSet { defaults.set(Double(pencilWidth), forKey: DefaultsKey.pencilWidth) }
    }

    @Published var penWidth: CGFloat = 5 {
        didSet { defaults.set(Double(penWidth), forKey: DefaultsKey.penWidth) }
    }

    @Published var highlighterWidth: CGFloat = 14 {
        didSet { defaults.set(Double(highlighterWidth), forKey: DefaultsKey.highlighterWidth) }
    }

    @Published var eraserMode: DrawingEraserMode = .pixel {
        didSet { defaults.set(eraserMode.rawValue, forKey: DefaultsKey.eraserMode) }
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

    @Published var temporaryEraserActive = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedTool = Self.storedTool(defaults, key: DefaultsKey.selectedTool, fallback: .pen)
        previousTool = Self.storedTool(defaults, key: DefaultsKey.previousTool, fallback: .pen)
        pencilColor = Self.storedColor(defaults, key: DefaultsKey.pencilColor, fallback: "#000000")
        penColor = Self.storedColor(defaults, key: DefaultsKey.penColor, fallback: "#000000")
        highlighterColor = Self.storedColor(defaults, key: DefaultsKey.highlighterColor, fallback: "#FFFF00")
        pencilWidth = Self.storedWidth(defaults, key: DefaultsKey.pencilWidth, fallback: 6)
        penWidth = Self.storedWidth(defaults, key: DefaultsKey.penWidth, fallback: 5)
        highlighterWidth = Self.storedWidth(defaults, key: DefaultsKey.highlighterWidth, fallback: 14)
        eraserMode = Self.storedEraserMode(defaults, key: DefaultsKey.eraserMode, fallback: .pixel)
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

    var selectedToolUsesInkColor: Bool {
        selectedTool.usesInkColor
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
            pencilWidth
        case .highlighter:
            highlighterWidth
        default:
            penWidth
        }
    }

    func paletteSwatches(for tool: DrawingTool? = nil) -> [DrawingColorSwatch] {
        let swatchTool = tool ?? activeColorTool
        return paletteColorHexes(for: swatchTool).enumerated().map { index, hex in
            DrawingColorSwatch(index: index, name: Self.colorName(for: hex), colorHex: hex)
        }
    }

    func primaryPaletteColor(for tool: DrawingTool? = nil) -> Color {
        paletteColor(at: 0, for: tool)
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
        switch selectedTool {
        case .pen:
            return "pen:\(penColor.hexRGB):\(Int(penWidth * 10))"
        case .pencil:
            return "pencil:\(pencilColor.hexRGB):\(Int(pencilWidth * 10))"
        case .highlighter:
            return "highlighter:\(highlighterColor.hexRGB):\(Int(highlighterWidth * 10))"
        case .eraser:
            return "eraser:\(eraserMode.rawValue)"
        case .lasso:
            return "lasso"
        }
    }

    func select(_ tool: DrawingTool) {
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
        switch activeColorTool {
        case .pencil:
            pencilWidth = width
        case .pen:
            penWidth = width
        case .highlighter:
            highlighterWidth = width
        case .eraser, .lasso:
            select(.pen)
            penWidth = width
        }
    }

    func selectEraserMode(_ mode: DrawingEraserMode) {
        eraserMode = mode
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

    func makePKTool() -> PKTool {
        switch selectedTool {
        case .pen:
            PKInkingTool(activeInkType ?? .pen, color: UIColor(penColor), width: penWidth)
        case .pencil:
            PKInkingTool(activeInkType ?? .pencil, color: UIColor(pencilColor), width: pencilWidth)
        case .highlighter:
            PKInkingTool(activeInkType ?? .marker, color: UIColor(highlighterColor).withAlphaComponent(0.5), width: highlighterWidth)
        case .eraser:
            PKEraserTool(eraserMode.eraserType)
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

    private static func storedColor(_ defaults: UserDefaults, key: String, fallback: String) -> Color {
        Color(hex: defaults.string(forKey: key) ?? fallback)
    }

    private static func storedWidth(_ defaults: UserDefaults, key: String, fallback: CGFloat) -> CGFloat {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return CGFloat(defaults.double(forKey: key))
    }

    private func paletteColorHexes(for tool: DrawingTool) -> [String] {
        switch tool {
        case .pen:
            penPaletteColorHexes
        case .pencil:
            pencilPaletteColorHexes
        case .highlighter:
            highlighterPaletteColorHexes
        case .eraser, .lasso:
            penPaletteColorHexes
        }
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

        return Array(normalized.prefix(maximumPaletteColorCount))
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
