//
//  BeanNotesTheme.swift
//  BeanNotes
//

import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    static let storageKey = "appTheme"

    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system:
            "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

enum BeanNotesTheme: String, CaseIterable, Identifiable {
    static let storageKey = "beanNotesTheme"

    case standard = "default"
    case bean
    case blueberry

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard:
            "Default"
        case .bean:
            "Bean"
        case .blueberry:
            "Blueberry"
        }
    }

    var subtitle: String {
        switch self {
        case .standard:
            "Clean iPadOS surfaces, balanced contrast, and familiar blue controls."
        case .bean:
            "Warm paper, soft caramel accents, and cozy folder colors."
        case .blueberry:
            "Cool paper, vivid blue controls, and crisp study-focused surfaces."
        }
    }

    var symbolName: String {
        switch self {
        case .standard:
            "square.grid.2x2.fill"
        case .bean:
            "pawprint.fill"
        case .blueberry:
            "drop.circle.fill"
        }
    }

    var accentHex: String {
        switch self {
        case .standard:
            "#0A84FF"
        case .bean:
            "#D97706"
        case .blueberry:
            "#2563EB"
        }
    }

    var secondaryAccentHex: String {
        switch self {
        case .standard:
            "#34C759"
        case .bean:
            "#FBBF24"
        case .blueberry:
            "#38BDF8"
        }
    }

    var appBackgroundHex: String {
        switch self {
        case .standard:
            "#F6F7FB"
        case .bean:
            "#FFF7ED"
        case .blueberry:
            "#EFF6FF"
        }
    }

    var sidebarBackgroundHex: String {
        switch self {
        case .standard:
            "#ECEFF5"
        case .bean:
            "#FEF3C7"
        case .blueberry:
            "#DBEAFE"
        }
    }

    var cardBackgroundHex: String {
        switch self {
        case .standard:
            "#FFFFFF"
        case .bean:
            "#FFFBEB"
        case .blueberry:
            "#F8FBFF"
        }
    }

    var previewBackgroundHex: String {
        switch self {
        case .standard:
            "#EEF1F6"
        case .bean:
            "#FDECC8"
        case .blueberry:
            "#DCEBFF"
        }
    }

    var defaultFolderColorHex: String {
        switch self {
        case .standard:
            "#0A84FF"
        case .bean:
            "#F59E0B"
        case .blueberry:
            "#3B82F6"
        }
    }

    var defaultNoteBackgroundHex: String {
        switch self {
        case .standard:
            "#FFFFFF"
        case .bean:
            "#FFF7D6"
        case .blueberry:
            "#EAF3FF"
        }
    }

    var notificationAttachmentName: String {
        switch self {
        case .standard:
            "BeanNotesNotificationIcon"
        case .bean:
            "BeanNotesNotificationIcon"
        case .blueberry:
            "BlueberryNotificationIcon"
        }
    }

    var alternateAppIconName: String? {
        switch self {
        case .standard, .bean:
            nil
        case .blueberry:
            "BlueberryAppIcon"
        }
    }

    var notificationTitle: String {
        switch self {
        case .standard, .bean:
            "BeanNotes"
        case .blueberry:
            "Blueberry BeanNotes"
        }
    }

    func folderCreatedBody(folderName: String) -> String {
        switch self {
        case .standard:
            "\"\(folderName)\" is ready."
        case .bean:
            "Welcome to \"\(folderName)\"!"
        case .blueberry:
            "\"\(folderName)\" is ready for fresh notes."
        }
    }

    var accentColor: Color {
        Color(hex: accentHex)
    }

    var secondaryAccentColor: Color {
        Color(hex: secondaryAccentHex)
    }

    var appBackground: Color {
        adaptiveColor(light: appBackgroundHex, dark: appBackgroundDarkHex)
    }

    var sidebarBackground: Color {
        adaptiveColor(light: sidebarBackgroundHex, dark: sidebarBackgroundDarkHex)
    }

    var cardBackground: Color {
        adaptiveColor(light: cardBackgroundHex, dark: cardBackgroundDarkHex)
    }

    var previewBackground: Color {
        adaptiveColor(light: previewBackgroundHex, dark: previewBackgroundDarkHex)
    }

    static func currentFromDefaults(_ defaults: UserDefaults = .standard) -> BeanNotesTheme {
        let rawValue = defaults.string(forKey: storageKey) ?? BeanNotesTheme.standard.rawValue
        return BeanNotesTheme(rawValue: rawValue) ?? .standard
    }

    private var appBackgroundDarkHex: String {
        switch self {
        case .standard:
            "#111318"
        case .bean:
            "#1F1710"
        case .blueberry:
            "#0B1424"
        }
    }

    private var sidebarBackgroundDarkHex: String {
        switch self {
        case .standard:
            "#171A21"
        case .bean:
            "#2A1E12"
        case .blueberry:
            "#111C30"
        }
    }

    private var cardBackgroundDarkHex: String {
        switch self {
        case .standard:
            "#1F232B"
        case .bean:
            "#2E2115"
        case .blueberry:
            "#18263D"
        }
    }

    private var previewBackgroundDarkHex: String {
        switch self {
        case .standard:
            "#2B313B"
        case .bean:
            "#3A2A18"
        case .blueberry:
            "#1E3354"
        }
    }

    private func adaptiveColor(light: String, dark: String) -> Color {
        Color(
            UIColor { traits in
                traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
            }
        )
    }
}

private struct BeanNotesThemeKey: EnvironmentKey {
    static let defaultValue: BeanNotesTheme = .standard
}

extension EnvironmentValues {
    var beanNotesTheme: BeanNotesTheme {
        get { self[BeanNotesThemeKey.self] }
        set { self[BeanNotesThemeKey.self] = newValue }
    }
}
