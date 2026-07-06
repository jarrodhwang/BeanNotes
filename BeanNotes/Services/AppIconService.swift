//
//  AppIconService.swift
//  BeanNotes
//

import UIKit

@MainActor
enum AppIconService {
    static func applyIcon(for theme: BeanNotesTheme) {
        guard UIApplication.shared.supportsAlternateIcons else { return }

        let iconName = theme.alternateAppIconName
        guard UIApplication.shared.alternateIconName != iconName else { return }

        UIApplication.shared.setAlternateIconName(iconName) { error in
            if let error {
                debugPrint("Could not update BeanNotes app icon:", error.localizedDescription)
            }
        }
    }
}
