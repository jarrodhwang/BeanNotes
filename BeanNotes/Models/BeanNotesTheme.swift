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
    static let defaultTheme = BeanNotesTheme.bean

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
            "Cool blueberry paper, berry buttons, and cheerful snack-break visits."
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
            "#A64B2A"
        case .blueberry:
            "#2563EB"
        }
    }

    var secondaryAccentHex: String {
        switch self {
        case .standard:
            "#34C759"
        case .bean:
            "#9F1239"
        case .blueberry:
            "#38BDF8"
        }
    }

    var appBackgroundHex: String {
        switch self {
        case .standard:
            "#F6F7FB"
        case .bean:
            "#FFF8EA"
        case .blueberry:
            "#EFF6FF"
        }
    }

    var sidebarBackgroundHex: String {
        switch self {
        case .standard:
            "#ECEFF5"
        case .bean:
            "#F3E6D3"
        case .blueberry:
            "#DBEAFE"
        }
    }

    var cardBackgroundHex: String {
        switch self {
        case .standard:
            "#FFFFFF"
        case .bean:
            "#FFFCF6"
        case .blueberry:
            "#F8FBFF"
        }
    }

    var previewBackgroundHex: String {
        switch self {
        case .standard:
            "#EEF1F6"
        case .bean:
            "#EEDDC7"
        case .blueberry:
            "#DCEBFF"
        }
    }

    var defaultFolderColorHex: String {
        switch self {
        case .standard:
            "#0A84FF"
        case .bean:
            "#A64B2A"
        case .blueberry:
            "#3B82F6"
        }
    }

    var notePaperPreviewHex: String {
        switch self {
        case .standard:
            "#FFFFFF"
        case .bean:
            "#FFF9EC"
        case .blueberry:
            "#EAF3FF"
        }
    }

    var supportsFriendlyVisits: Bool {
        switch self {
        case .standard:
            false
        case .bean, .blueberry:
            true
        }
    }

    var mascotName: String {
        mascotCopy?.name ?? label
    }

    var visitThemeSectionTitle: String {
        mascotCopy?.themeSectionTitle ?? "Theme"
    }

    var visitToggleTitle: String {
        mascotCopy?.visitsToggleTitle ?? "Occasional Visits"
    }

    var visitHintMessage: String {
        mascotCopy?.hintMessage ?? "BeanNotes is ready for your next idea."
    }

    var visitInterruptionsToggleTitle: String {
        mascotCopy?.interruptionsToggleTitle ?? "Allow Interrupts"
    }

    var visitInterruptionsDescription: String {
        mascotCopy?.interruptionsDescription ?? "Optional check-ins can appear while you are writing."
    }

    var inviteVisitTitle: String {
        mascotCopy?.inviteTitle ?? "Preview a Visit"
    }

    var paperArtworkToggleTitle: String {
        mascotCopy?.paperArtworkToggleTitle ?? "Show Theme Art on Note Backgrounds"
    }

    var paperArtworkDescription: String {
        mascotCopy?.paperArtworkDescription ?? "Adds subtle theme art without changing your note template or color."
    }

    var cornerTitle: String {
        mascotCopy?.cornerTitle ?? "BeanNotes"
    }

    var cornerSubtitle: String {
        mascotCopy?.cornerSubtitle ?? "Ready for your next idea"
    }

    var mascotEmptyStateTitle: String {
        mascotCopy?.emptyStateTitle ?? "Ready for a new note?"
    }

    var mascotEmptyStateMessage: String {
        mascotCopy?.emptyStateMessage ?? "This folder is ready for your first idea."
    }

    var mascotExportHint: String {
        mascotCopy?.exportHint ?? "Your original note will stay unchanged."
    }

    var folderReadyTitle: String {
        mascotCopy?.folderReadyTitle ?? "Folder created"
    }

    var mascotAvatarImageName: String? {
        switch self {
        case .standard:
            nil
        case .bean:
            "BeanTabAvatar"
        case .blueberry:
            "BlueberryBadge"
        }
    }

    var mascotWelcomeImageName: String? {
        switch self {
        case .standard:
            nil
        case .bean:
            "BeanWelcomeImage"
        case .blueberry:
            "BlueberryVisitImage"
        }
    }

    var mascotWatermarkImageName: String? {
        mascotWelcomeImageName
    }

    var brandImageName: String? {
        switch self {
        case .standard:
            nil
        case .bean:
            "BeanBadge"
        case .blueberry:
            "BlueberryBadge"
        }
    }

    nonisolated var paperTextureImageName: String? {
        switch self {
        case .standard:
            nil
        case .bean:
            "BeanPaperTexture"
        case .blueberry:
            "BlueberryPaperTexture"
        }
    }

    var mascotCopy: MascotCopy? {
        switch self {
        case .standard:
            nil
        case .bean:
            MascotCopy(
                name: "Bean",
                themeSectionTitle: "Bean Theme",
                visitsToggleTitle: "Occasional Bean Visits",
                hintMessage: "Bean is on hand to keep your library and writing space cozy.",
                interruptionsToggleTitle: "Allow Bean Interrupts",
                interruptionsDescription: "When enabled, Bean can pop up in the library and while you are writing. When off, Bean only checks in after you return from a 3-minute break or after a longer focus session.",
                inviteTitle: "Invite Bean Now",
                paperArtworkToggleTitle: "Show Bean on Note Backgrounds",
                paperArtworkDescription: "Adds a subtle, randomly selected Bean paper design without changing your note template or color.",
                cornerTitle: "Bean's corner",
                cornerSubtitle: "Ready for your next idea",
                emptyStateTitle: "Ready for a new note?",
                emptyStateMessage: "Bean will keep this folder cozy until your first idea arrives.",
                exportHint: "Bean will help package this note without changing your original.",
                folderReadyTitle: "Folder ready"
            )
        case .blueberry:
            MascotCopy(
                name: "Blueberry",
                themeSectionTitle: "Blueberry Theme",
                visitsToggleTitle: "Occasional Blueberry Visits",
                hintMessage: "Blueberry is ready to brighten your library and writing space.",
                interruptionsToggleTitle: "Allow Blueberry Interrupts",
                interruptionsDescription: "When enabled, Blueberry can pop up in the library and while you are writing. When off, Blueberry only checks in after you return from a 3-minute break or after a longer focus session.",
                inviteTitle: "Invite Blueberry Now",
                paperArtworkToggleTitle: "Show Blueberries on Note Backgrounds",
                paperArtworkDescription: "Adds a subtle blueberry paper texture without changing your note template or color.",
                cornerTitle: "Blueberry patch",
                cornerSubtitle: "Fresh ideas are ready to grow",
                emptyStateTitle: "Ready for a fresh note?",
                emptyStateMessage: "A cheerful blueberry will keep this folder bright until your first idea arrives.",
                exportHint: "Blueberry will help package this note without changing your original.",
                folderReadyTitle: "A fresh folder ripened"
            )
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
            "Bean set up “\(folderName)” for you."
        case .blueberry:
            "\"\(folderName)\" is ready for fresh notes."
        }
    }

    var accentColor: Color {
        adaptiveColor(light: accentHex, dark: accentDarkHex)
    }

    var secondaryAccentColor: Color {
        adaptiveColor(light: secondaryAccentHex, dark: secondaryAccentDarkHex)
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
        let rawValue = defaults.string(forKey: storageKey) ?? defaultTheme.rawValue
        return BeanNotesTheme(rawValue: rawValue) ?? defaultTheme
    }

    private var accentDarkHex: String {
        switch self {
        case .standard:
            "#409CFF"
        case .bean:
            "#F3B26A"
        case .blueberry:
            "#60A5FA"
        }
    }

    private var secondaryAccentDarkHex: String {
        switch self {
        case .standard:
            "#30D158"
        case .bean:
            "#FB7185"
        case .blueberry:
            "#38BDF8"
        }
    }

    private var appBackgroundDarkHex: String {
        switch self {
        case .standard:
            "#111318"
        case .bean:
            "#1B1511"
        case .blueberry:
            "#0B1424"
        }
    }

    private var sidebarBackgroundDarkHex: String {
        switch self {
        case .standard:
            "#171A21"
        case .bean:
            "#261B14"
        case .blueberry:
            "#111C30"
        }
    }

    private var cardBackgroundDarkHex: String {
        switch self {
        case .standard:
            "#1F232B"
        case .bean:
            "#302219"
        case .blueberry:
            "#18263D"
        }
    }

    private var previewBackgroundDarkHex: String {
        switch self {
        case .standard:
            "#2B313B"
        case .bean:
            "#423023"
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

extension BeanNotesTheme {
    struct MascotCopy: Equatable, Sendable {
        let name: String
        let themeSectionTitle: String
        let visitsToggleTitle: String
        let hintMessage: String
        let interruptionsToggleTitle: String
        let interruptionsDescription: String
        let inviteTitle: String
        let paperArtworkToggleTitle: String
        let paperArtworkDescription: String
        let cornerTitle: String
        let cornerSubtitle: String
        let emptyStateTitle: String
        let emptyStateMessage: String
        let exportHint: String
        let folderReadyTitle: String
    }
}

private struct BeanNotesThemeKey: EnvironmentKey {
    static let defaultValue: BeanNotesTheme = .defaultTheme
}

extension EnvironmentValues {
    var beanNotesTheme: BeanNotesTheme {
        get { self[BeanNotesThemeKey.self] }
        set { self[BeanNotesThemeKey.self] = newValue }
    }
}
