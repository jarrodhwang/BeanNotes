import SwiftUI
import Testing
import UIKit
@testable import BeanNotes

@MainActor
struct ThemeAppearanceTests {
    @Test(arguments: BeanNotesTheme.allCases, [UIUserInterfaceStyle.light, .dark])
    func filledControlsHaveReadableLabels(theme: BeanNotesTheme, style: UIUserInterfaceStyle) {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let background = theme.accentUIColor.resolvedColor(with: traits)
        let foreground = theme.accentForegroundUIColor.resolvedColor(with: traits)
        #expect(contrast(foreground, background) >= 4.5)
    }

    @Test(arguments: BeanNotesTheme.allCases)
    func darkSurfacesRemainDarkWithReadableText(theme: BeanNotesTheme) {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let light = UITraitCollection(userInterfaceStyle: .light)
        for surface in [theme.appBackgroundUIColor, theme.cardBackgroundUIColor, theme.previewBackgroundUIColor] {
            let background = surface.resolvedColor(with: dark)
            #expect(luminance(background) < 0.1)
            #expect(contrast(UIColor.label.resolvedColor(with: dark), background) >= 7)
            #expect(!background.isEqual(surface.resolvedColor(with: light)))
        }
    }

    private func contrast(_ first: UIColor, _ second: UIColor) -> Double {
        let firstValue = luminance(first), secondValue = luminance(second)
        return (max(firstValue, secondValue) + 0.05) / (min(firstValue, secondValue) + 0.05)
    }

    private func luminance(_ color: UIColor) -> Double {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let channels = [Double(red), Double(green), Double(blue)].map { value -> Double in
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
    }
}
