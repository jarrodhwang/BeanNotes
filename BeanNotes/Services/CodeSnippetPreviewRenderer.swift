//
//  CodeSnippetPreviewRenderer.swift
//  BeanNotes
//

import UIKit

/// Produces the flattened preview used to place an editable code snippet on a note page.
///
/// Rendering is deliberately limited to drawing the supplied string. The source is never
/// interpreted or executed, and the fixed output bounds keep unusually large snippets from
/// causing unbounded image allocations.
@MainActor
enum CodeSnippetPreviewRenderer {
    nonisolated static let defaultLogicalSize = CGSize(width: 560, height: 320)

    private static let minimumLogicalSize = CGSize(width: 280, height: 160)
    private static let maximumLogicalSize = CGSize(width: 1_200, height: 900)
    private static let renderScale: CGFloat = 2
    private static let cornerRadius: CGFloat = 22
    private static let headerHeight: CGFloat = 54
    private static let horizontalPadding: CGFloat = 20
    private static let codeTopPadding: CGFloat = 15
    private static let codeBottomPadding: CGFloat = 18
    private static let minimumFontSize: CGFloat = 8
    private static let maximumFontSize: CGFloat = 40

    /// Returns PNG data with transparent pixels outside the rounded snippet surface.
    /// Invalid or extreme dimensions are normalized before any bitmap is allocated.
    static func pngData(
        for draft: CodeSnippetDraft,
        logicalSize proposedSize: CGSize = defaultLogicalSize,
        automaticInterfaceStyle: UIUserInterfaceStyle = UITraitCollection.current.userInterfaceStyle
    ) -> Data? {
        let logicalSize = normalizedLogicalSize(proposedSize)
        let fontSize = normalizedFontSize(draft.fontSize)
        let requestedFont = draft.font.uiFont(size: fontSize)
        let font = requestedFont.pointSize.isFinite && requestedFont.pointSize > 0
            ? requestedFont
            : UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let isDark = resolvesToDark(
            draft.backgroundStyle,
            automaticInterfaceStyle: automaticInterfaceStyle
        )
        let palette = Palette(isDark: isDark)

        let format = UIGraphicsImageRendererFormat()
        format.scale = renderScale
        format.opaque = false
        format.preferredRange = .standard

        let renderer = UIGraphicsImageRenderer(size: logicalSize, format: format)
        let image = renderer.image { rendererContext in
            drawPreview(
                draft: draft,
                font: font,
                palette: palette,
                size: logicalSize,
                context: rendererContext.cgContext
            )
        }

        return image.pngData()
    }

    static func normalizedLogicalSize(_ proposedSize: CGSize) -> CGSize {
        CGSize(
            width: normalizedDimension(
                proposedSize.width,
                fallback: defaultLogicalSize.width,
                range: minimumLogicalSize.width...maximumLogicalSize.width
            ),
            height: normalizedDimension(
                proposedSize.height,
                fallback: defaultLogicalSize.height,
                range: minimumLogicalSize.height...maximumLogicalSize.height
            )
        )
    }

    private static func normalizedDimension(
        _ value: CGFloat,
        fallback: CGFloat,
        range: ClosedRange<CGFloat>
    ) -> CGFloat {
        guard value.isFinite, value > 0 else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func normalizedFontSize(_ value: Double) -> CGFloat {
        guard value.isFinite else { return 15 }
        return min(max(CGFloat(value), minimumFontSize), maximumFontSize)
    }

    private static func resolvesToDark(
        _ style: CodeSnippetBackgroundStyle,
        automaticInterfaceStyle: UIUserInterfaceStyle
    ) -> Bool {
        switch style {
        case .automatic:
            automaticInterfaceStyle == .dark
        case .light:
            false
        case .dark:
            true
        }
    }

    private static func drawPreview(
        draft: CodeSnippetDraft,
        font: UIFont,
        palette: Palette,
        size: CGSize,
        context: CGContext
    ) {
        let bounds = CGRect(origin: .zero, size: size)
        let surfacePath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: min(cornerRadius, min(size.width, size.height) / 2)
        )

        context.saveGState()
        surfacePath.addClip()
        drawSurface(in: bounds, palette: palette, context: context)
        drawHeader(
            languageLabel: draft.language.label,
            in: bounds,
            palette: palette,
            context: context
        )
        drawCode(
            draft.code,
            language: draft.language,
            font: font,
            in: bounds,
            palette: palette,
            context: context
        )
        context.restoreGState()

        palette.borderColor.setStroke()
        surfacePath.lineWidth = 1
        surfacePath.stroke()

        let innerHighlight = UIBezierPath(
            roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
            cornerRadius: max(cornerRadius - 1.5, 0)
        )
        palette.innerHighlightColor.setStroke()
        innerHighlight.lineWidth = 1
        innerHighlight.stroke()
    }

    private static func drawSurface(
        in bounds: CGRect,
        palette: Palette,
        context: CGContext
    ) {
        context.setFillColor(palette.baseColor.cgColor)
        context.fill(bounds)
    }

    private static func drawHeader(
        languageLabel: String,
        in bounds: CGRect,
        palette: Palette,
        context: CGContext
    ) {
        let separatorY = min(bounds.minY + headerHeight, bounds.maxY)
        context.saveGState()
        context.setStrokeColor(palette.separatorColor.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: bounds.minX + 1, y: separatorY))
        context.addLine(to: CGPoint(x: bounds.maxX - 1, y: separatorY))
        context.strokePath()
        context.restoreGState()

        let labelFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
        let normalizedLabel = languageLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayedLabel = normalizedLabel.isEmpty ? "Code" : normalizedLabel
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: palette.headerTextColor
        ]
        let measuredLabelSize = (displayedLabel as NSString).size(withAttributes: labelAttributes)
        let availablePillWidth = max(bounds.width - horizontalPadding * 2 - 50, 44)
        let pillWidth = min(max(measuredLabelSize.width + 24, 58), availablePillWidth)
        let pillRect = CGRect(
            x: bounds.minX + horizontalPadding,
            y: bounds.minY + (headerHeight - 30) / 2,
            width: pillWidth,
            height: 30
        )
        let pillPath = UIBezierPath(roundedRect: pillRect, cornerRadius: pillRect.height / 2)
        palette.pillColor.setFill()
        pillPath.fill()
        palette.pillBorderColor.setStroke()
        pillPath.lineWidth = 1
        pillPath.stroke()

        let labelRect = pillRect.insetBy(dx: 12, dy: 0)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byTruncatingTail
        var centeredLabelAttributes = labelAttributes
        centeredLabelAttributes[.paragraphStyle] = paragraphStyle
        (displayedLabel as NSString).draw(
            in: CGRect(
                x: labelRect.minX,
                y: labelRect.midY - labelFont.lineHeight / 2,
                width: labelRect.width,
                height: labelFont.lineHeight
            ),
            withAttributes: centeredLabelAttributes
        )

        let gearSide: CGFloat = 22
        let gearRect = CGRect(
            x: bounds.maxX - horizontalPadding - gearSide,
            y: bounds.minY + (headerHeight - gearSide) / 2,
            width: gearSide,
            height: gearSide
        )
        drawGear(in: gearRect, color: palette.gearColor)
    }

    private static func drawGear(in rect: CGRect, color: UIColor) {
        let configuration = UIImage.SymbolConfiguration(pointSize: rect.height, weight: .semibold)
        if let gear = UIImage(systemName: "gearshape.fill", withConfiguration: configuration)?
            .withTintColor(color, renderingMode: .alwaysOriginal) {
            gear.draw(in: rect)
            return
        }

        // The symbol is available on every supported OS, but retain a deterministic
        // fallback so an asset lookup failure never makes preview generation fail.
        color.setStroke()
        let ring = UIBezierPath(ovalIn: rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2))
        ring.lineWidth = max(rect.width * 0.14, 1)
        ring.stroke()
        let hub = UIBezierPath(ovalIn: rect.insetBy(dx: rect.width * 0.39, dy: rect.height * 0.39))
        color.setFill()
        hub.fill()
    }

    private static func drawCode(
        _ code: String,
        language: CodeSnippetLanguage,
        font: UIFont,
        in bounds: CGRect,
        palette: Palette,
        context: CGContext
    ) {
        let codeRect = CGRect(
            x: bounds.minX + horizontalPadding,
            y: min(bounds.minY + headerHeight + codeTopPadding, bounds.maxY),
            width: max(bounds.width - horizontalPadding * 2, 0),
            height: max(bounds.height - headerHeight - codeTopPadding - codeBottomPadding, 0)
        )
        guard codeRect.width > 0, codeRect.height > 0, !code.isEmpty else { return }

        let highlighted = CodeSyntaxHighlighter.attributedString(
            for: code,
            language: language,
            font: font,
            foregroundColor: palette.codeTextColor
        )
        let drawableText = NSMutableAttributedString(attributedString: highlighted)
        let fullRange = NSRange(location: 0, length: drawableText.length)
        if fullRange.length > 0 {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byClipping
            paragraphStyle.lineSpacing = max(font.pointSize * 0.15, 1)
            paragraphStyle.tabStops = []
            paragraphStyle.defaultTabInterval = max(font.pointSize * 4 * 0.6, 1)
            drawableText.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)
        }

        context.saveGState()
        context.clip(to: codeRect)
        drawableText.draw(
            with: CGRect(
                x: codeRect.minX,
                y: codeRect.minY,
                width: max(codeRect.width, 20_000),
                height: codeRect.height
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        context.restoreGState()
    }
}

private extension CodeSnippetPreviewRenderer {
    struct Palette {
        let baseColor: UIColor
        let borderColor: UIColor
        let innerHighlightColor: UIColor
        let separatorColor: UIColor
        let pillColor: UIColor
        let pillBorderColor: UIColor
        let headerTextColor: UIColor
        let gearColor: UIColor
        let codeTextColor: UIColor

        init(isDark: Bool) {
            if isDark {
                baseColor = UIColor(red: 0.14, green: 0.15, blue: 0.17, alpha: 1)
                borderColor = UIColor.white.withAlphaComponent(0.2)
                innerHighlightColor = UIColor.white.withAlphaComponent(0.08)
                separatorColor = UIColor.white.withAlphaComponent(0.12)
                pillColor = UIColor.white.withAlphaComponent(0.1)
                pillBorderColor = UIColor.white.withAlphaComponent(0.16)
                headerTextColor = UIColor.white.withAlphaComponent(0.94)
                gearColor = UIColor.white.withAlphaComponent(0.72)
                codeTextColor = UIColor(red: 0.89, green: 0.91, blue: 0.96, alpha: 1)
            } else {
                baseColor = .white
                borderColor = UIColor.black.withAlphaComponent(0.18)
                innerHighlightColor = UIColor.black.withAlphaComponent(0.04)
                separatorColor = UIColor.black.withAlphaComponent(0.12)
                pillColor = UIColor.black.withAlphaComponent(0.05)
                pillBorderColor = UIColor.black.withAlphaComponent(0.14)
                headerTextColor = UIColor(red: 0.09, green: 0.13, blue: 0.22, alpha: 0.94)
                gearColor = UIColor(red: 0.18, green: 0.24, blue: 0.34, alpha: 0.68)
                codeTextColor = UIColor(red: 0.08, green: 0.11, blue: 0.17, alpha: 1)
            }
        }
    }
}
