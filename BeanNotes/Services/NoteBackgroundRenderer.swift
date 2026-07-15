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
        drawThemeArtworkIfNeeded(
            background: background,
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
            drawChalkboard(background: background, in: rect, context: &context)
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
        drawThemeArtworkIfNeeded(
            background: background,
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
            drawChalkboard(background: background, in: rect, context: context)
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

    nonisolated static func blueberryPaperTextureRects(in rect: CGRect) -> [CGRect] {
        guard rect.width > 0, rect.height > 0 else { return [] }

        let tileSide = max(180, min(640, rect.width * 0.52))
        var results: [CGRect] = []
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX {
                results.append(CGRect(x: x, y: y, width: tileSide, height: tileSide))
                x += tileSide
            }
            y += tileSide
        }
        return results
    }

    nonisolated static let chalkboardBeanImageName = "BeanWelcomeImage"

    nonisolated static func chalkboardBeanArtworkRect(in rect: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return .zero }

        let aspectRatio = CGFloat(418) / 560
        let width = min(rect.width * 0.22, rect.height * 0.42 * aspectRatio)
        let height = width / aspectRatio
        let preferredInset = max(4, min(14, min(rect.width, rect.height) * 0.024))
        let availableInset = max(0, min(rect.width - width, rect.height - height))
        let inset = min(preferredInset, availableInset)

        return CGRect(
            x: rect.maxX - width - inset,
            y: rect.maxY - height - inset,
            width: width,
            height: height
        )
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
    static var chalkGridColor: Color { Color.white.opacity(0.12) }
    static var chalkboardFrameColor: Color { Color(hex: "#C9B58F").opacity(0.82) }
    nonisolated static var uiChalkGridColor: UIColor { UIColor.white.withAlphaComponent(0.12) }
    nonisolated static var uiChalkboardFrameColor: UIColor { UIColor(hex: "#C9B58F").withAlphaComponent(0.82) }

    static var lightSecondaryColor: Color { Color(uiColor: lightSecondaryLabel) }

    /// Note paper intentionally keeps its light appearance even when the surrounding app is dark.
    nonisolated static var lightSecondaryLabel: UIColor {
        UIColor.secondaryLabel.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .light)
        )
    }

    @MainActor
    static func drawThemeArtworkIfNeeded(
        background: NoteBackground,
        theme: BeanNotesTheme,
        showsBeanArtwork: Bool,
        pageID: UUID?,
        in rect: CGRect,
        context: inout GraphicsContext
    ) {
        guard showsBeanArtwork else { return }

        switch theme {
        case .standard:
            return
        case .bean:
            if background.style == .chalkboard {
                var artworkContext = context
                artworkContext.opacity = 0.34
                let image = artworkContext.resolve(Image(chalkboardBeanImageName))
                artworkContext.draw(image, in: chalkboardBeanArtworkRect(in: rect))
                return
            }

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
        case .blueberry:
            guard background.style != .chalkboard,
                  let imageName = theme.paperTextureImageName else { return }

            var textureContext = context
            textureContext.opacity = 0.12
            textureContext.blendMode = .multiply
            let image = textureContext.resolve(Image(imageName))
            for textureRect in blueberryPaperTextureRects(in: rect) {
                textureContext.draw(image, in: textureRect)
            }
        }
    }

    nonisolated static func drawThemeArtworkIfNeeded(
        background: NoteBackground,
        theme: BeanNotesTheme,
        showsBeanArtwork: Bool,
        pageID: UUID?,
        in rect: CGRect,
        context: CGContext
    ) {
        guard showsBeanArtwork else { return }

        switch theme {
        case .standard:
            return
        case .bean:
            if background.style == .chalkboard {
                UIImage(named: chalkboardBeanImageName)?.draw(
                    in: chalkboardBeanArtworkRect(in: rect),
                    blendMode: .normal,
                    alpha: 0.34
                )
                return
            }

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
        case .blueberry:
            guard background.style != .chalkboard,
                  let imageName = theme.paperTextureImageName,
                  let image = UIImage(named: imageName) else { return }

            for textureRect in blueberryPaperTextureRects(in: rect) {
                image.draw(in: textureRect, blendMode: .multiply, alpha: 0.12)
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

    static func drawChalkboard(
        background: NoteBackground,
        in rect: CGRect,
        context: inout GraphicsContext
    ) {
        if background.resolvedChalkboardPattern == .grid {
            var grid = Path()
            let contentRect = chalkboardContentRect(in: rect)
            let spacing = chalkboardGridSpacing(in: rect)

            stride(from: contentRect.minX, through: contentRect.maxX, by: spacing).forEach { x in
                grid.move(to: CGPoint(x: x, y: contentRect.minY))
                grid.addLine(to: CGPoint(x: x, y: contentRect.maxY))
            }
            stride(from: contentRect.minY, through: contentRect.maxY, by: spacing).forEach { y in
                grid.move(to: CGPoint(x: contentRect.minX, y: y))
                grid.addLine(to: CGPoint(x: contentRect.maxX, y: y))
            }

            context.stroke(grid, with: .color(chalkGridColor), lineWidth: chalkGridLineWidth(in: rect))
        }

        let frameRect = chalkboardFrameRect(in: rect)
        let frame = Path(
            roundedRect: frameRect,
            cornerRadius: chalkboardFrameCornerRadius(in: rect)
        )
        context.stroke(
            frame,
            with: .color(chalkboardFrameColor),
            lineWidth: chalkboardFrameLineWidth(in: rect)
        )
    }

    nonisolated static func drawChalkboard(
        background: NoteBackground,
        in rect: CGRect,
        context: CGContext
    ) {
        if background.resolvedChalkboardPattern == .grid {
            let contentRect = chalkboardContentRect(in: rect)
            let spacing = chalkboardGridSpacing(in: rect)
            context.beginPath()
            stride(from: contentRect.minX, through: contentRect.maxX, by: spacing).forEach { x in
                context.move(to: CGPoint(x: x, y: contentRect.minY))
                context.addLine(to: CGPoint(x: x, y: contentRect.maxY))
            }
            stride(from: contentRect.minY, through: contentRect.maxY, by: spacing).forEach { y in
                context.move(to: CGPoint(x: contentRect.minX, y: y))
                context.addLine(to: CGPoint(x: contentRect.maxX, y: y))
            }
            context.setStrokeColor(uiChalkGridColor.cgColor)
            context.setLineWidth(chalkGridLineWidth(in: rect))
            context.strokePath()
        }

        context.setStrokeColor(uiChalkboardFrameColor.cgColor)
        context.setLineWidth(chalkboardFrameLineWidth(in: rect))
        context.addPath(
            UIBezierPath(
                roundedRect: chalkboardFrameRect(in: rect),
                cornerRadius: chalkboardFrameCornerRadius(in: rect)
            ).cgPath
        )
        context.strokePath()
    }

    nonisolated static func chalkboardFrameLineWidth(in rect: CGRect) -> CGFloat {
        max(1, min(4, min(rect.width, rect.height) * 0.004))
    }

    nonisolated static func chalkboardFrameRect(in rect: CGRect) -> CGRect {
        let minimumDimension = max(0, min(rect.width, rect.height))
        let preferredInset = max(2, min(10, minimumDimension * 0.012))
        let inset = min(preferredInset, minimumDimension * 0.25)
        return rect.insetBy(dx: inset, dy: inset)
    }

    nonisolated static func chalkboardFrameCornerRadius(in rect: CGRect) -> CGFloat {
        max(2, min(12, min(rect.width, rect.height) * 0.014))
    }

    nonisolated static func chalkboardContentRect(in rect: CGRect) -> CGRect {
        let minimumDimension = max(0, min(rect.width, rect.height))
        let preferredInset = max(8, min(24, minimumDimension * 0.045))
        let inset = min(preferredInset, minimumDimension * 0.25)
        return rect.insetBy(dx: inset, dy: inset)
    }

    nonisolated static func chalkboardGridSpacing(in rect: CGRect) -> CGFloat {
        max(24, min(rect.width, rect.height) * 0.065)
    }

    nonisolated static func chalkGridLineWidth(in rect: CGRect) -> CGFloat {
        max(0.5, min(1, min(rect.width, rect.height) * 0.0015))
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
