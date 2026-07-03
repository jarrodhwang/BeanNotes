//
//  DrawingToolState.swift
//  BeanNote
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
            "BeanNote Custom"
        case .applePencil:
            "Apple Pencil"
        }
    }

    var description: String {
        switch self {
        case .custom:
            "Use BeanNote's compact floating palette."
        case .applePencil:
            "Use Apple's PencilKit tool picker."
        }
    }
}

@MainActor
final class DrawingToolState: ObservableObject {
    @Published var selectedTool: DrawingTool = .pen
    @Published var previousTool: DrawingTool = .pen
    @Published var pencilColor: Color = .black
    @Published var penColor: Color = .black
    @Published var highlighterColor: Color = .yellow
    @Published var pencilWidth: CGFloat = 6
    @Published var penWidth: CGFloat = 5
    @Published var highlighterWidth: CGFloat = 14
    @Published var temporaryEraserActive = false

    var activeInkColor: Color {
        switch selectedTool {
        case .pencil:
            pencilColor
        case .highlighter:
            highlighterColor
        default:
            penColor
        }
    }

    var activeStrokeWidth: CGFloat {
        switch selectedTool {
        case .pencil:
            pencilWidth
        case .highlighter:
            highlighterWidth
        default:
            penWidth
        }
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

    func select(_ tool: DrawingTool) {
        if tool != .eraser, tool != selectedTool {
            previousTool = selectedTool == .eraser ? previousTool : selectedTool
        }

        if tool == .eraser, selectedTool != .eraser {
            previousTool = selectedTool
        }

        selectedTool = tool
    }

    func applyActiveColor(_ color: Color) {
        switch selectedTool {
        case .pencil:
            pencilColor = color
        case .pen:
            penColor = color
        case .highlighter:
            highlighterColor = color
        case .eraser, .lasso:
            select(.pen)
            penColor = color
        }
    }

    func applyActiveWidth(_ width: CGFloat) {
        switch selectedTool {
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
            PKEraserTool(.bitmap)
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
}
