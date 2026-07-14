//
//  NoteBackgroundRenderer.swift
//  BeanNotes
//

import SwiftUI
import UIKit

enum BeanPaperArtworkLayout: Hashable, Sendable {
    case centered
    case tiled
    case scattered
    case border
}

struct BeanPaperArtwork: Equatable, Sendable {
    let imageName: String
    let aspectRatio: CGFloat
    let widthRatio: CGFloat
    let maximumHeightRatio: CGFloat
    let opacity: CGFloat
    let clipsToEllipse: Bool
    let layout: BeanPaperArtworkLayout
}

enum NoteBackgroundRenderer {
    @MainActor
    static func draw(
        background: NoteBackground,
        theme: BeanNotesTheme = .standard,
        showsBeanArtwork: Bool = false,
        pageID: UUID? = nil,
        in rect: CGRect,
        context: inout GraphicsContext
    ) {
        context.fill(Path(rect), with: .color(Color(hex: background.renderedColorHex)))
        drawBeanArtworkIfNeeded(
            theme: theme,
            showsBeanArtwork: showsBeanArtwork,
            pageID: pageID,
            in: rect,
            context: &context
        )

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
        case .chalkboard:
            drawChalkboard(in: rect, context: &context)
        }
    }

    nonisolated static func draw(
        background: NoteBackground,
        theme: BeanNotesTheme = .standard,
        showsBeanArtwork: Bool = false,
        pageID: UUID? = nil,
        in rect: CGRect,
        context: CGContext
    ) {
        context.saveGState()
        defer {
            context.restoreGState()
        }

        UIColor(hex: background.renderedColorHex).setFill()
        context.fill(rect)
        drawBeanArtworkIfNeeded(
            theme: theme,
            showsBeanArtwork: showsBeanArtwork,
            pageID: pageID,
            in: rect,
            context: context
        )

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
        case .chalkboard:
            drawChalkboard(in: rect, context: context)
        }
    }

    nonisolated static func beanPaperArtwork(for pageID: UUID?) -> BeanPaperArtwork {
        guard let pageID else { return beanPaperArtworks[0] }

        let index = pageID.uuidString.utf8.reduce(0) { partialResult, byte in
            (partialResult + Int(byte)) % beanPaperArtworks.count
        }
        return beanPaperArtworks[index]
    }

    nonisolated static func beanPaperArtworkRect(
        for artwork: BeanPaperArtwork,
        in rect: CGRect
    ) -> CGRect {
        let pageWidth = max(0, rect.width)
        let pageHeight = max(0, rect.height)
        let aspectRatio = max(artwork.aspectRatio, 0.01)
        let width = min(
            pageWidth * artwork.widthRatio,
            pageHeight * artwork.maximumHeightRatio * aspectRatio
        )
        let height = width / aspectRatio

        return CGRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
    }

    nonisolated static func beanPaperArtworkRects(
        for artwork: BeanPaperArtwork,
        in rect: CGRect
    ) -> [CGRect] {
        guard rect.width > 0, rect.height > 0 else { return [] }

        switch artwork.layout {
        case .centered:
            return [beanPaperArtworkRect(for: artwork, in: rect)]
        case .tiled:
            return tiledBeanRects(for: artwork, in: rect)
        case .scattered:
            return scatteredBeanRects(for: artwork, in: rect)
        case .border:
            return borderBeanRects(for: artwork, in: rect)
        }
    }
}

private extension NoteBackgroundRenderer {
    nonisolated static let beanPaperArtworks = [
        BeanPaperArtwork(
            imageName: "BeanWelcomeImage",
            aspectRatio: CGFloat(418) / 560,
            widthRatio: 0.56,
            maximumHeightRatio: 0.60,
            opacity: 0.08,
            clipsToEllipse: false,
            layout: .centered
        ),
        BeanPaperArtwork(
            imageName: "BeanTabAvatar",
            aspectRatio: 1,
            widthRatio: 0.60,
            maximumHeightRatio: 0.50,
            opacity: 0.075,
            clipsToEllipse: true,
            layout: .centered
        ),
        BeanPaperArtwork(
            imageName: "BeanBadge",
            aspectRatio: 1,
            widthRatio: 0.072,
            maximumHeightRatio: 0.08,
            opacity: 0.045,
            clipsToEllipse: false,
            layout: .tiled
        ),
        BeanPaperArtwork(
            imageName: "BeanTabAvatar",
            aspectRatio: 1,
            widthRatio: 0.105,
            maximumHeightRatio: 0.11,
            opacity: 0.05,
            clipsToEllipse: true,
            layout: .scattered
        ),
        BeanPaperArtwork(
            imageName: "BeanBadge",
            aspectRatio: 1,
            widthRatio: 0.09,
            maximumHeightRatio: 0.10,
            opacity: 0.055,
            clipsToEllipse: false,
            layout: .border
        )
    ]

    static var lineColor: Color { lightSecondaryColor.opacity(0.24) }
    static var strongLineColor: Color { lightSecondaryColor.opacity(0.34) }
    static var dotColor: Color { lightSecondaryColor.opacity(0.36) }
    static var checkboxColor: Color { lightSecondaryColor.opacity(0.2) }

    nonisolated static var uiLineColor: UIColor { lightSecondaryLabel.withAlphaComponent(0.24) }
    nonisolated static var uiStrongLineColor: UIColor { lightSecondaryLabel.withAlphaComponent(0.34) }
    nonisolated static var uiDotColor: UIColor { lightSecondaryLabel.withAlphaComponent(0.34) }
    nonisolated static var uiCheckboxColor: UIColor { lightSecondaryLabel.withAlphaComponent(0.2) }
    static var chalkSmudgeColor: Color { Color.white.opacity(0.035) }
    static var chalkDustColor: Color { Color.white.opacity(0.07) }
    nonisolated static var uiChalkSmudgeColor: UIColor { UIColor.white.withAlphaComponent(0.035) }
    nonisolated static var uiChalkDustColor: UIColor { UIColor.white.withAlphaComponent(0.07) }

    static var lightSecondaryColor: Color { Color(uiColor: lightSecondaryLabel) }

    /// Note paper intentionally keeps its light appearance even when the surrounding app is dark.
    nonisolated static var lightSecondaryLabel: UIColor {
        UIColor.secondaryLabel.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .light)
        )
    }

    @MainActor
    static func drawBeanArtworkIfNeeded(
        theme: BeanNotesTheme,
        showsBeanArtwork: Bool,
        pageID: UUID?,
        in rect: CGRect,
        context: inout GraphicsContext
    ) {
        guard theme == .bean, showsBeanArtwork else { return }

        let artwork = beanPaperArtwork(for: pageID)
        var artworkContext = context
        artworkContext.opacity = artwork.opacity
        let image = artworkContext.resolve(Image(artwork.imageName))
        for artworkRect in beanPaperArtworkRects(for: artwork, in: rect) {
            var itemContext = artworkContext
            if artwork.clipsToEllipse {
                itemContext.clip(to: Path(ellipseIn: artworkRect))
            }
            itemContext.draw(image, in: artworkRect)
        }
    }

    nonisolated static func drawBeanArtworkIfNeeded(
        theme: BeanNotesTheme,
        showsBeanArtwork: Bool,
        pageID: UUID?,
        in rect: CGRect,
        context: CGContext
    ) {
        guard theme == .bean, showsBeanArtwork else { return }

        let artwork = beanPaperArtwork(for: pageID)
        if let image = UIImage(named: artwork.imageName) {
            for artworkRect in beanPaperArtworkRects(for: artwork, in: rect) {
                context.saveGState()
                if artwork.clipsToEllipse {
                    context.addEllipse(in: artworkRect)
                    context.clip()
                }
                image.draw(in: artworkRect, blendMode: .normal, alpha: artwork.opacity)
                context.restoreGState()
            }
        }
    }

    nonisolated static func tiledBeanRects(
        for artwork: BeanPaperArtwork,
        in rect: CGRect
    ) -> [CGRect] {
        let beanWidth = min(rect.width * artwork.widthRatio, rect.height * artwork.maximumHeightRatio)
        let horizontalStep = beanWidth * 1.8
        let verticalStep = beanWidth * 1.9
        guard beanWidth > 0, horizontalStep > 0, verticalStep > 0 else { return [] }

        var results: [CGRect] = []
        var row = 0
        var y = rect.minY + verticalStep * 0.55
        while y + beanWidth <= rect.maxY {
            let rowOffset = row.isMultiple(of: 2) ? 0 : horizontalStep * 0.5
            var x = rect.minX + horizontalStep * 0.45 + rowOffset
            while x + beanWidth <= rect.maxX {
                results.append(CGRect(x: x, y: y, width: beanWidth, height: beanWidth))
                x += horizontalStep
            }
            row += 1
            y += verticalStep
        }
        return results
    }

    nonisolated static func scatteredBeanRects(
        for artwork: BeanPaperArtwork,
        in rect: CGRect
    ) -> [CGRect] {
        let beanWidth = min(rect.width * artwork.widthRatio, rect.height * artwork.maximumHeightRatio)
        guard beanWidth > 0 else { return [] }

        return (0..<22).map { index in
            let availableWidth = max(0, rect.width - beanWidth)
            let availableHeight = max(0, rect.height - beanWidth)
            return CGRect(
                x: rect.minX + availableWidth * artworkUnitValue(index: index, salt: 29),
                y: rect.minY + availableHeight * artworkUnitValue(index: index, salt: 67),
                width: beanWidth,
                height: beanWidth
            )
        }
    }

    nonisolated static func borderBeanRects(
        for artwork: BeanPaperArtwork,
        in rect: CGRect
    ) -> [CGRect] {
        let beanWidth = min(rect.width * artwork.widthRatio, rect.height * artwork.maximumHeightRatio)
        let inset = beanWidth * 0.42
        let horizontalStep = beanWidth * 1.65
        let verticalStep = beanWidth * 1.75
        guard beanWidth > 0, horizontalStep > 0, verticalStep > 0 else { return [] }

        var results: [CGRect] = []
        var x = rect.minX + inset
        while x + beanWidth <= rect.maxX - inset {
            results.append(CGRect(x: x, y: rect.minY + inset, width: beanWidth, height: beanWidth))
            results.append(CGRect(x: x, y: rect.maxY - inset - beanWidth, width: beanWidth, height: beanWidth))
            x += horizontalStep
        }

        var y = rect.minY + inset + verticalStep
        while y + beanWidth <= rect.maxY - inset - verticalStep {
            results.append(CGRect(x: rect.minX + inset, y: y, width: beanWidth, height: beanWidth))
            results.append(CGRect(x: rect.maxX - inset - beanWidth, y: y, width: beanWidth, height: beanWidth))
            y += verticalStep
        }
        return results
    }

    nonisolated static func artworkUnitValue(index: Int, salt: Int) -> CGFloat {
        let value = (index * 83 + salt * 41 + index * index * 23) % 1009
        return CGFloat(value) / 1008
    }

    static func drawChalkboard(in rect: CGRect, context: inout GraphicsContext) {
        var smudges = Path()
        for index in 0..<24 {
            let start = chalkSmudgeStart(index: index, in: rect)
            let end = chalkSmudgeEnd(index: index, start: start, in: rect)
            smudges.move(to: start)
            smudges.addLine(to: end)
        }
        context.stroke(
            smudges,
            with: .color(chalkSmudgeColor),
            lineWidth: chalkSmudgeWidth(in: rect)
        )

        var dust = Path()
        for index in 0..<72 {
            dust.addEllipse(in: chalkDustRect(index: index, in: rect))
        }
        context.fill(dust, with: .color(chalkDustColor))
    }

    nonisolated static func drawChalkboard(in rect: CGRect, context: CGContext) {
        context.beginPath()
        for index in 0..<24 {
            let start = chalkSmudgeStart(index: index, in: rect)
            let end = chalkSmudgeEnd(index: index, start: start, in: rect)
            context.move(to: start)
            context.addLine(to: end)
        }
        context.setStrokeColor(uiChalkSmudgeColor.cgColor)
        context.setLineWidth(chalkSmudgeWidth(in: rect))
        context.setLineCap(.round)
        context.strokePath()

        context.setFillColor(uiChalkDustColor.cgColor)
        for index in 0..<72 {
            context.fillEllipse(in: chalkDustRect(index: index, in: rect))
        }
    }

    nonisolated static func chalkSmudgeStart(index: Int, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + rect.width * chalkUnitValue(index: index, salt: 17),
            y: rect.minY + rect.height * chalkUnitValue(index: index, salt: 43)
        )
    }

    nonisolated static func chalkSmudgeEnd(index: Int, start: CGPoint, in rect: CGRect) -> CGPoint {
        let length = rect.width * (0.08 + chalkUnitValue(index: index, salt: 71) * 0.18)
        let rise = rect.height * (chalkUnitValue(index: index, salt: 97) - 0.5) * 0.018
        return CGPoint(x: min(start.x + length, rect.maxX), y: start.y + rise)
    }

    nonisolated static func chalkDustRect(index: Int, in rect: CGRect) -> CGRect {
        let diameter = max(0.7, min(rect.width, rect.height) * 0.0018)
        return CGRect(
            x: rect.minX + rect.width * chalkUnitValue(index: index, salt: 131),
            y: rect.minY + rect.height * chalkUnitValue(index: index, salt: 173),
            width: diameter,
            height: diameter
        )
    }

    nonisolated static func chalkSmudgeWidth(in rect: CGRect) -> CGFloat {
        max(1, min(rect.width, rect.height) * 0.006)
    }

    nonisolated static func chalkUnitValue(index: Int, salt: Int) -> CGFloat {
        let value = (index * 73 + salt * 37 + index * index * 19) % 997
        return CGFloat(value) / 996
    }

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
        context.stroke(checkboxPath, with: .color(checkboxColor), lineWidth: 1)
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
        context.setStrokeColor(uiCheckboxColor.cgColor)
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
