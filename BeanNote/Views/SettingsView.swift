//
//  SettingsView.swift
//  BeanNote
//

import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
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

struct SettingsView: View {
    @AppStorage("appTheme") private var appThemeRaw = AppTheme.system.rawValue
    @AppStorage("penPaletteMode") private var penPaletteModeRaw = PenPaletteMode.custom.rawValue
    @AppStorage("pencilDoubleTapAction") private var doubleTapRaw = PencilDoubleTapAction.switchToEraser.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appThemeRaw) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.label).tag(theme.rawValue)
                        }
                    }
                }

                Section("Apple Pencil") {
                    Picker("Pen Palette", selection: $penPaletteModeRaw) {
                        ForEach(PenPaletteMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }

                    Picker("Double Tap", selection: $doubleTapRaw) {
                        ForEach(PencilDoubleTapAction.allCases) { action in
                            Text(action.label).tag(action.rawValue)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
