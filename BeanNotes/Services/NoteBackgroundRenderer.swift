//
//  NoteBackgroundRenderer.swift
//  BeanNotes
//

import SwiftUI
import UIKit

enum NoteBackgroundRenderer {
    @MainActor
    static func draw(background: NoteBackground, in rect: CGRect, context: inout GraphicsContext) {
        context.fill(Path(rect), with: .color(Color(hex: background.colorHex)))

        switch background.style {
        case .plain:
            return
        case .grid:
            drawGrid(background: background, in: rect, context: &context)
        case .dotted:
            drawDots(background: background, in: rect, context: &context)
        case .lined:
            drawLines(background: background, in: rect, context: &context)
            drawMargin(background: background, in: rect, context: &context)
        case .cornell:
            drawCornell(background: background, in: rect, context: &context)
        case .musicStaff:
            drawMusicStaff(background: background, in: rect, context: &context)
        case .planner:
            drawPlanner(background: background, in: rect, context: &context)
        }
    }

    nonisolated static func draw(background: NoteBackground, in rect: CGRect, context: CGContext) {
        context.saveGState()
        defer {
            context.restoreGState()
        }

        UIColor(hex: background.colorHex).setFill()
        context.fill(rect)

        switch background.style {
        case .plain:
            return
        case .grid:
            drawGrid(background: background, in: rect, context: context)
        case .dotted:
            drawDots(background: background, in: rect, context: context)
        case .lined:
            drawLines(background: background, in: rect, context: context)
            drawMargin(background: background, in: rect, context: context)
        case .cornell:
            drawCornell(background: background, in: rect, context: context)
        case .musicStaff:
            drawMusicStaff(background: background, in: rect, context: context)
        case .planner:
            drawPlanner(background: background, in: rect, context: context)
        }
    }
}

private extension NoteBackgroundRenderer {
    static var lineColor: Color { Color.secondary.opacity(0.24) }
    static var strongLineColor: Color { Color.secondary.opacity(0.34) }
    static var dotColor: Color { Color.secondary.opacity(0.36) }

    nonisolated static var uiLineColor: UIColor { UIColor.secondaryLabel.withAlphaComponent(0.24) }
    nonisolated static var uiStrongLineColor: UIColor { UIColor.secondaryLabel.withAlphaComponent(0.34) }
    nonisolated static var uiDotColor: UIColor { UIColor.secondaryLabel.withAlphaComponent(0.34) }

    static func drawGrid(background: NoteBackground, in rect: CGRect, context: inout GraphicsContext) {
        let spacing = CGFloat(background.resolvedSpacing)
        var path = Path()

        stride(from: rect.minX, through: rect.maxX, by: spacing).forEach { x in
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }

        stride(from: rect.minY, through: rect.maxY, by: spacing).forEach { y in
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }

        context.stroke(path, with: .color(lineColor), lineWidth: 1)
        drawMargin(background: background, in: rect, context: &context)
    }

    nonisolated static func drawGrid(background: NoteBackground, in rect: CGRect, context: CGContext) {
        let spacing = CGFloat(background.resolvedSpacing)
        context.beginPath()

        stride(from: rect.minX, through: rect.maxX, by: spacing).forEach { x in
            context.move(to: CGPoint(x: x, y: rect.minY))
            context.addLine(to: CGPoint(x: x, y: rect.maxY))
        }

        stride(from: rect.minY, through: rect.maxY, by: spacing).forEach { y in
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
        }

        context.setStrokeColor(uiLineColor.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        drawMargin(background: background, in: rect, context: context)
    }

    static func drawLines(background: NoteBackground, in rect: CGRect, context: inout GraphicsContext) {
        let spacing = CGFloat(background.resolvedSpacing)
        var path = Path()

        stride(from: rect.minY + spacing, through: rect.maxY, by: spacing).forEach { y in
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }

        context.stroke(path, with: .color(lineColor), lineWidth: 1)
    }

    nonisolated static func drawLines(background: NoteBackground, in rect: CGRect, context: CGContext) {
        let spacing = CGFloat(background.resolvedSpacing)
        context.beginPath()

        stride(from: rect.minY + spacing, through: rect.maxY, by: spacing).forEach { y in
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
        }

        context.setStrokeColor(uiLineColor.cgColor)
        context.setLineWidth(1)
        context.strokePath()
    }

    static func drawDots(background: NoteBackground, in rect: CGRect, context: inout GraphicsContext) {
        let spacing = CGFloat(background.resolvedSpacing)
        let dotSize: CGFloat = 2.6

        stride(from: rect.minX + spacing, through: rect.maxX, by: spacing).forEach { x in
            stride(from: rect.minY + spacing, through: rect.maxY, by: spacing).forEach { y in
                let dotRect = CGRect(x: x - dotSize / 2, y: y - dotSize / 2, width: dotSize, height: dotSize)
                context.fill(Path(ellipseIn: dotRect), with: .color(dotColor))
            }
        }

        drawMargin(background: background, in: rect, context: &context)
    }

    nonisolated static func drawDots(background: NoteBackground, in rect: CGRect, context: CGContext) {
        let spacing = CGFloat(background.resolvedSpacing)
        let dotSize: CGFloat = 2.4

        context.setFillColor(uiDotColor.cgColor)
        stride(from: rect.minX + spacing, through: rect.maxX, by: spacing).forEach { x in
            stride(from: rect.minY + spacing, through: rect.maxY, by: spacing).forEach { y in
                context.fillEllipse(in: CGRect(x: x - dotSize / 2, y: y - dotSize / 2, width: dotSize, height: dotSize))
            }
        }

        drawMargin(background: background, in: rect, context: context)
    }

    static func drawCornell(background: NoteBackground, in rect: CGRect, context: inout GraphicsContext) {
        let spacing = CGFloat(background.resolvedSpacing)
        let cueWidth = CGFloat(background.resolvedMarginWidth)
        let summaryHeight = min(max(rect.height * 0.18, 132), 220)
        let noteRect = CGRect(x: cueWidth, y: rect.minY, width: rect.width - cueWidth, height: rect.height - summaryHeight)

        var rulePath = Path()
        stride(from: noteRect.minY + spacing, through: noteRect.maxY, by: spacing).forEach { y in
            rulePath.move(to: CGPoint(x: noteRect.minX, y: y))
            rulePath.addLine(to: CGPoint(x: noteRect.maxX, y: y))
        }
        context.stroke(rulePath, with: .color(lineColor), lineWidth: 1)

        var structurePath = Path()
        structurePath.move(to: CGPoint(x: cueWidth, y: rect.minY))
        structurePath.addLine(to: CGPoint(x: cueWidth, y: rect.maxY - summaryHeight))
        structurePath.move(to: CGPoint(x: rect.minX, y: rect.maxY - summaryHeight))
        structurePath.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - summaryHeight))
        context.stroke(structurePath, with: .color(strongLineColor), lineWidth: 1.35)
    }

    nonisolated static func drawCornell(background: NoteBackground, in rect: CGRect, context: CGContext) {
        let spacing = CGFloat(background.resolvedSpacing)
        let cueWidth = CGFloat(background.resolvedMarginWidth)
        let summaryHeight = min(max(rect.height * 0.18, 132), 220)
        let noteRect = CGRect(x: cueWidth, y: rect.minY, width: rect.width - cueWidth, height: rect.height - summaryHeight)

        context.beginPath()
        stride(from: noteRect.minY + spacing, through: noteRect.maxY, by: spacing).forEach { y in
            context.move(to: CGPoint(x: noteRect.minX, y: y))
            context.addLine(to: CGPoint(x: noteRect.maxX, y: y))
        }
        context.setStrokeColor(uiLineColor.cgColor)
        context.setLineWidth(1)
        context.strokePath()

        context.beginPath()
        context.move(to: CGPoint(x: cueWidth, y: rect.minY))
        context.addLine(to: CGPoint(x: cueWidth, y: rect.maxY - summaryHeight))
        context.move(to: CGPoint(x: rect.minX, y: rect.maxY - summaryHeight))
        context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - summaryHeight))
        context.setStrokeColor(uiStrongLineColor.cgColor)
        context.setLineWidth(1.35)
        context.strokePath()
    }

    static func drawMusicStaff(background: NoteBackground, in rect: CGRect, context: inout GraphicsContext) {
        let lineGap = CGFloat(background.resolvedSpacing)
        let staffHeight = lineGap * 4
        let staffGap = lineGap * 4.4
        var y = rect.minY + 54

        var path = Path()
        while y + staffHeight <= rect.maxY - 36 {
            for index in 0..<5 {
                let lineY = y + CGFloat(index) * lineGap
                path.move(to: CGPoint(x: rect.minX + 44, y: lineY))
                path.addLine(to: CGPoint(x: rect.maxX - 44, y: lineY))
            }
            y += staffHeight + staffGap
        }

        context.stroke(path, with: .color(strongLineColor), lineWidth: 1)
    }

    nonisolated static func drawMusicStaff(background: NoteBackground, in rect: CGRect, context: CGContext) {
        let lineGap = CGFloat(background.resolvedSpacing)
        let staffHeight = lineGap * 4
        let staffGap = lineGap * 4.4
        var y = rect.minY + 54

        context.beginPath()
        while y + staffHeight <= rect.maxY - 36 {
            for index in 0..<5 {
                let lineY = y + CGFloat(index) * lineGap
                context.move(to: CGPoint(x: rect.minX + 44, y: lineY))
                context.addLine(to: CGPoint(x: rect.maxX - 44, y: lineY))
            }
            y += staffHeight + staffGap
        }

        context.setStrokeColor(uiStrongLineColor.cgColor)
        context.setLineWidth(1)
        context.strokePath()
    }

    static func drawPlanner(background: NoteBackground, in rect: CGRect, context: inout GraphicsContext) {
        let rowSpacing = CGFloat(background.resolvedSpacing)
        let timeColumnWidth = CGFloat(background.resolvedMarginWidth)
        let headerHeight: CGFloat = 78
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + headerHeight))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + headerHeight))
        path.move(to: CGPoint(x: rect.minX + timeColumnWidth, y: rect.minY + headerHeight))
        path.addLine(to: CGPoint(x: rect.minX + timeColumnWidth, y: rect.maxY))

        stride(from: rect.minY + headerHeight + rowSpacing, through: rect.maxY, by: rowSpacing).forEach { y in
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }

        context.stroke(path, with: .color(lineColor), lineWidth: 1)

        var checkboxPath = Path()
        let checkboxSize: CGFloat = 12
        stride(from: rect.minY + headerHeight + rowSpacing * 0.42, through: rect.maxY, by: rowSpacing).forEach { y in
            checkboxPath.addRect(CGRect(x: rect.maxX - 52, y: y - checkboxSize / 2, width: checkboxSize, height: checkboxSize))
        }
        context.stroke(checkboxPath, with: .color(Color.secondary.opacity(0.2)), lineWidth: 1)
    }

    nonisolated static func drawPlanner(background: NoteBackground, in rect: CGRect, context: CGContext) {
        let rowSpacing = CGFloat(background.resolvedSpacing)
        let timeColumnWidth = CGFloat(background.resolvedMarginWidth)
        let headerHeight: CGFloat = 78

        context.beginPath()
        context.move(to: CGPoint(x: rect.minX, y: rect.minY + headerHeight))
        context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + headerHeight))
        context.move(to: CGPoint(x: rect.minX + timeColumnWidth, y: rect.minY + headerHeight))
        context.addLine(to: CGPoint(x: rect.minX + timeColumnWidth, y: rect.maxY))

        stride(from: rect.minY + headerHeight + rowSpacing, through: rect.maxY, by: rowSpacing).forEach { y in
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
        }

        context.setStrokeColor(uiLineColor.cgColor)
        context.setLineWidth(1)
        context.strokePath()

        let checkboxSize: CGFloat = 12
        context.beginPath()
        stride(from: rect.minY + headerHeight + rowSpacing * 0.42, through: rect.maxY, by: rowSpacing).forEach { y in
            context.addRect(CGRect(x: rect.maxX - 52, y: y - checkboxSize / 2, width: checkboxSize, height: checkboxSize))
        }
        context.setStrokeColor(UIColor.secondaryLabel.withAlphaComponent(0.2).cgColor)
        context.setLineWidth(1)
        context.strokePath()
    }

    static func drawMargin(background: NoteBackground, in rect: CGRect, context: inout GraphicsContext) {
        let marginWidth = CGFloat(background.resolvedMarginWidth)
        guard marginWidth > 0 else { return }

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + marginWidth, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + marginWidth, y: rect.maxY))
        context.stroke(path, with: .color(strongLineColor), lineWidth: 1.2)
    }

    nonisolated static func drawMargin(background: NoteBackground, in rect: CGRect, context: CGContext) {
        let marginWidth = CGFloat(background.resolvedMarginWidth)
        guard marginWidth > 0 else { return }

        context.beginPath()
        context.move(to: CGPoint(x: rect.minX + marginWidth, y: rect.minY))
        context.addLine(to: CGPoint(x: rect.minX + marginWidth, y: rect.maxY))
        context.setStrokeColor(uiStrongLineColor.cgColor)
        context.setLineWidth(1.2)
        context.strokePath()
    }
}
