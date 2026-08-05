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
    nonisolated static let currentVersion = 3
    nonisolated static let defaultLogicalSize = CGSize(width: 560, height: 320)

    private static let minimumBitmapLogicalSize = CGSize(width: 280, height: 160)
    private static let maximumBitmapLogicalSize = CGSize(width: 1_200, height: 900)
    nonisolated static let renderScale: CGFloat = 2
    private static let minimumFontSize: CGFloat = 8
    private static let maximumFontSize: CGFloat = 40
    private static let minimumRasterFontSize: CGFloat = 1
    private static let maximumRasterFontSize: CGFloat = 512

    /// Adaptive snippets with an automatic surface need a separate light/dark
    /// revision because their flattened PNG changes with app appearance. Named
    /// themes and explicitly light/dark surfaces are appearance-independent.
    nonisolated static func previewVersion(
        for draft: CodeSnippetDraft,
        automaticInterfaceStyle: UIUserInterfaceStyle
    ) -> Int {
        guard draft.syntaxTheme == .adaptive,
              draft.backgroundStyle == .automatic else {
            return currentVersion
        }
        return currentVersion * 10 + (automaticInterfaceStyle == .dark ? 1 : 0)
    }

    struct RenderLayout: Equatable {
        let requestedLogicalSize: CGSize
        let bitmapLogicalSize: CGSize
        let contentScale: CGFloat

        func scaled(_ value: CGFloat) -> CGFloat {
            value * contentScale
        }
    }

    struct HeaderLayout: Equatable {
        let iconRect: CGRect
        let pillRect: CGRect
        let labelRect: CGRect
        let measuredLabelWidth: CGFloat
    }

    /// Returns PNG data with transparent pixels outside the rounded snippet surface.
    /// Invalid dimensions fall back to the default. Valid dimensions retain their
    /// document-space layout while the backing bitmap is uniformly scaled into a
    /// bounded allocation. Scaling every metric by the same factor means displaying
    /// the PNG in `proposedSize` preserves the requested font and corner-radius sizes.
    static func pngData(
        for draft: CodeSnippetDraft,
        logicalSize proposedSize: CGSize = defaultLogicalSize,
        automaticInterfaceStyle: UIUserInterfaceStyle = UITraitCollection.current.userInterfaceStyle
    ) -> Data? {
        let layout = renderLayout(for: proposedSize)
        let rasterFontSize = rasterFontSize(for: draft.fontSize, layout: layout)
        let requestedFont = previewFont(draft.font, size: rasterFontSize)
        let font = requestedFont.pointSize.isFinite && requestedFont.pointSize > 0
            ? requestedFont
            : UIFont.monospacedSystemFont(ofSize: rasterFontSize, weight: .regular)
        let palette = draft.syntaxPalette(for: automaticInterfaceStyle)

        let format = UIGraphicsImageRendererFormat()
        format.scale = renderScale
        format.opaque = false
        format.preferredRange = .standard

        let renderer = UIGraphicsImageRenderer(size: layout.bitmapLogicalSize, format: format)
        let image = renderer.image { rendererContext in
            drawPreview(
                draft: draft,
                font: font,
                palette: palette,
                layout: layout,
                context: rendererContext.cgContext
            )
        }

        return image.pngData()
    }

    static func renderLayout(for proposedSize: CGSize) -> RenderLayout {
        let requestedSize = sanitizedRequestedSize(proposedSize)
        let minimumScale = max(
            minimumBitmapLogicalSize.width / requestedSize.width,
            minimumBitmapLogicalSize.height / requestedSize.height
        )
        let maximumScale = min(
            maximumBitmapLogicalSize.width / requestedSize.width,
            maximumBitmapLogicalSize.height / requestedSize.height
        )

        // Normal snippet frames can satisfy both bounds. If corrupted geometry has
        // an extreme aspect ratio, prioritize the maximum so bitmap work stays bounded.
        let contentScale = minimumScale <= maximumScale
            ? min(max(1, minimumScale), maximumScale)
            : maximumScale
        let bitmapSize = CGSize(
            width: requestedSize.width * contentScale,
            height: requestedSize.height * contentScale
        )

        guard contentScale.isFinite,
              contentScale > 0,
              bitmapSize.width * renderScale >= 1,
              bitmapSize.height * renderScale >= 1 else {
            return RenderLayout(
                requestedLogicalSize: defaultLogicalSize,
                bitmapLogicalSize: defaultLogicalSize,
                contentScale: 1
            )
        }

        return RenderLayout(
            requestedLogicalSize: requestedSize,
            bitmapLogicalSize: bitmapSize,
            contentScale: contentScale
        )
    }

    static func normalizedLogicalSize(_ proposedSize: CGSize) -> CGSize {
        renderLayout(for: proposedSize).bitmapLogicalSize
    }

    static func rasterFontSize(for value: Double, layout: RenderLayout) -> CGFloat {
        min(
            max(normalizedFontSize(value) * layout.contentScale, minimumRasterFontSize),
            maximumRasterFontSize
        )
    }

    private static func sanitizedRequestedSize(_ proposedSize: CGSize) -> CGSize {
        CGSize(
            width: proposedSize.width.isFinite && proposedSize.width > 0
                ? proposedSize.width
                : defaultLogicalSize.width,
            height: proposedSize.height.isFinite && proposedSize.height > 0
                ? proposedSize.height
                : defaultLogicalSize.height
        )
    }

    private static func normalizedFontSize(_ value: Double) -> CGFloat {
        guard value.isFinite else { return 15 }
        return min(max(CGFloat(value), minimumFontSize), maximumFontSize)
    }

    private static func previewFont(
        _ choice: CodeSnippetFontChoice,
        size: CGFloat
    ) -> UIFont {
        switch choice {
        case .systemMono:
            .monospacedSystemFont(ofSize: size, weight: .regular)
        case .menlo:
            UIFont(name: "Menlo-Regular", size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        case .courier:
            UIFont(name: "Courier", size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    private static func drawPreview(
        draft: CodeSnippetDraft,
        font: UIFont,
        palette: CodeSnippetSyntaxPalette,
        layout: RenderLayout,
        context: CGContext
    ) {
        let bounds = CGRect(origin: .zero, size: layout.bitmapLogicalSize)
        let cornerRadius = layout.scaled(CodeSnippetLayout.cornerRadius)
        let surfacePath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: min(cornerRadius, min(bounds.width, bounds.height) / 2)
        )

        context.saveGState()
        surfacePath.addClip()
        drawSurface(in: bounds, palette: palette, context: context)
        drawHeader(
            languageLabel: draft.language.label,
            in: bounds,
            palette: palette,
            layout: layout,
            context: context
        )
        drawCode(
            draft.code,
            language: draft.language,
            font: font,
            in: bounds,
            palette: palette,
            layout: layout,
            context: context
        )
        context.restoreGState()

        palette.borderColor.setStroke()
        surfacePath.lineWidth = layout.scaled(1)
        surfacePath.stroke()

        let highlightInset = layout.scaled(1.5)
        let innerHighlight = UIBezierPath(
            roundedRect: bounds.insetBy(dx: highlightInset, dy: highlightInset),
            cornerRadius: max(cornerRadius - highlightInset, 0)
        )
        palette.innerHighlightColor.setStroke()
        innerHighlight.lineWidth = layout.scaled(1)
        innerHighlight.stroke()
    }

    private static func drawSurface(
        in bounds: CGRect,
        palette: CodeSnippetSyntaxPalette,
        context: CGContext
    ) {
        context.setFillColor(palette.baseColor.cgColor)
        context.fill(bounds)
    }

    private static func drawHeader(
        languageLabel: String,
        in bounds: CGRect,
        palette: CodeSnippetSyntaxPalette,
        layout: RenderLayout,
        context: CGContext
    ) {
        let headerHeight = layout.scaled(CodeSnippetLayout.headerHeight)
        let separatorY = min(bounds.minY + headerHeight, bounds.maxY)
        context.saveGState()
        context.setStrokeColor(palette.separatorColor.cgColor)
        context.setLineWidth(layout.scaled(1))
        context.move(to: CGPoint(x: bounds.minX + layout.scaled(1), y: separatorY))
        context.addLine(to: CGPoint(x: bounds.maxX - layout.scaled(1), y: separatorY))
        context.strokePath()
        context.restoreGState()

        let normalizedLabel = languageLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayedLabel = normalizedLabel.isEmpty ? "Code" : normalizedLabel
        let labelFont = UIFont.systemFont(ofSize: layout.scaled(12), weight: .semibold)
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: palette.headerTextColor
        ]
        let resolvedHeaderLayout = headerLayout(
            for: displayedLabel,
            in: bounds,
            renderLayout: layout,
            labelFont: labelFont
        )

        if let symbol = UIImage(
            systemName: "chevron.left.forwardslash.chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: layout.scaled(CodeSnippetLayout.codeIconSize),
                weight: .semibold
            )
        )?.withTintColor(palette.headerTextColor, renderingMode: .alwaysOriginal) {
            symbol.draw(in: aspectFitRect(
                aspectRatio: symbol.size,
                inside: resolvedHeaderLayout.iconRect
            ))
        }

        let pillRect = resolvedHeaderLayout.pillRect
        let pillPath = UIBezierPath(roundedRect: pillRect, cornerRadius: pillRect.height / 2)
        palette.pillColor.setFill()
        pillPath.fill()
        palette.pillBorderColor.setStroke()
        pillPath.lineWidth = layout.scaled(1)
        pillPath.stroke()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byClipping
        var centeredLabelAttributes = labelAttributes
        centeredLabelAttributes[.paragraphStyle] = paragraphStyle
        (displayedLabel as NSString).draw(
            in: CGRect(
                x: resolvedHeaderLayout.labelRect.minX,
                y: resolvedHeaderLayout.labelRect.midY - labelFont.lineHeight / 2,
                width: resolvedHeaderLayout.labelRect.width,
                height: labelFont.lineHeight
            ),
            withAttributes: centeredLabelAttributes
        )
    }

    static func headerLayout(
        for languageLabel: String,
        in bounds: CGRect,
        renderLayout layout: RenderLayout,
        labelFont: UIFont? = nil
    ) -> HeaderLayout {
        let headerHeight = layout.scaled(CodeSnippetLayout.headerHeight)
        let horizontalPadding = layout.scaled(CodeSnippetLayout.headerHorizontalPadding)
        let iconWidth = layout.scaled(CodeSnippetLayout.codeIconWidth)
        let iconHeight = layout.scaled(CodeSnippetLayout.codeIconSize)
        let spacing = layout.scaled(CodeSnippetLayout.headerControlSpacing)
        let pillHeight = layout.scaled(CodeSnippetLayout.languageChipHeight)
        let chipPadding = layout.scaled(CodeSnippetLayout.languageChipHorizontalPadding)
        let font = labelFont ?? UIFont.systemFont(
            ofSize: layout.scaled(12),
            weight: .semibold
        )
        let measuredLabelWidth = (languageLabel as NSString).size(
            withAttributes: [.font: font]
        ).width
        let iconRect = CGRect(
            x: bounds.minX + horizontalPadding,
            y: bounds.minY + (headerHeight - iconHeight) / 2,
            width: iconWidth,
            height: iconHeight
        )
        let pillX = iconRect.maxX + spacing
        let availablePillWidth = max(
            bounds.maxX
                - layout.scaled(CodeSnippetLayout.settingsReservedWidth)
                - pillX,
            layout.scaled(CodeSnippetLayout.languageChipMinimumWidth)
        )
        let pillWidth = min(
            max(
                measuredLabelWidth + chipPadding * 2,
                layout.scaled(CodeSnippetLayout.languageChipMinimumWidth)
            ),
            availablePillWidth
        )
        let pillRect = CGRect(
            x: pillX,
            y: bounds.minY + (headerHeight - pillHeight) / 2,
            width: pillWidth,
            height: pillHeight
        )
        return HeaderLayout(
            iconRect: iconRect,
            pillRect: pillRect,
            labelRect: pillRect.insetBy(dx: chipPadding, dy: 0),
            measuredLabelWidth: measuredLabelWidth
        )
    }

    private static func aspectFitRect(
        aspectRatio sourceSize: CGSize,
        inside destination: CGRect
    ) -> CGRect {
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              destination.width > 0,
              destination.height > 0 else {
            return destination
        }
        let scale = min(
            destination.width / sourceSize.width,
            destination.height / sourceSize.height
        )
        let fittedSize = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        return CGRect(
            x: destination.midX - fittedSize.width / 2,
            y: destination.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    private static func drawCode(
        _ code: String,
        language: CodeSnippetLanguage,
        font: UIFont,
        in bounds: CGRect,
        palette: CodeSnippetSyntaxPalette,
        layout: RenderLayout,
        context: CGContext
    ) {
        let horizontalPadding = layout.scaled(CodeSnippetLayout.codeHorizontalPadding)
        let headerHeight = layout.scaled(CodeSnippetLayout.headerHeight)
        let headerSeparatorHeight = layout.scaled(CodeSnippetLayout.headerSeparatorHeight)
        let codeTopPadding = layout.scaled(CodeSnippetLayout.codeTopPadding)
        let codeBottomPadding = layout.scaled(CodeSnippetLayout.codeBottomPadding)
        let codeRect = CGRect(
            x: bounds.minX + horizontalPadding,
            y: min(
                bounds.minY + headerHeight + headerSeparatorHeight + codeTopPadding,
                bounds.maxY
            ),
            width: max(bounds.width - horizontalPadding * 2, 0),
            height: max(
                bounds.height
                    - headerHeight
                    - headerSeparatorHeight
                    - codeTopPadding
                    - codeBottomPadding,
                0
            )
        )
        guard codeRect.width > 0, codeRect.height > 0, !code.isEmpty else { return }

        let highlighted = CodeSyntaxHighlighter.attributedString(
            for: code,
            language: language,
            font: font,
            palette: palette
        )
        let drawableText = NSMutableAttributedString(attributedString: highlighted)
        let fullRange = NSRange(location: 0, length: drawableText.length)
        if fullRange.length > 0 {
            drawableText.addAttribute(
                .paragraphStyle,
                value: CodeSnippetLayout.codeParagraphStyle(
                    font: font,
                    minimumMetricScale: layout.contentScale
                ),
                range: fullRange
            )
        }

        context.saveGState()
        context.clip(to: codeRect)
        drawableText.draw(
            with: CGRect(
                x: codeRect.minX,
                y: codeRect.minY,
                width: max(codeRect.width, layout.scaled(20_000)),
                height: codeRect.height
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        context.restoreGState()
    }
}
