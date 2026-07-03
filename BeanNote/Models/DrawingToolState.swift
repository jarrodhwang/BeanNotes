//
//  DrawingToolState.swift
//  BeanNote
//

import Combine
import PencilKit
import SwiftUI

enum DrawingTool: String, CaseIterable, Identifiable {
    case pen
    case highlighter
    case eraser
    case lasso

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pen:
            "Pen"
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
    @Published var penColor: Color = .black
    @Published var highlighterColor: Color = .yellow.opacity(0.55)
    @Published var strokeWidth: CGFloat = 5
    @Published var temporaryEraserActive = false

    var activeInkColor: Color {
        switch selectedTool {
        case .highlighter:
            highlighterColor
        default:
            penColor
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
        if selectedTool == .highlighter {
            highlighterColor = color.opacity(0.55)
        } else {
            penColor = color

            if selectedTool == .eraser || selectedTool == .lasso {
                select(.pen)
            }
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
            PKInkingTool(.pen, color: UIColor(penColor), width: strokeWidth)
        case .highlighter:
            PKInkingTool(.marker, color: UIColor(highlighterColor), width: max(strokeWidth * 2, 8))
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
