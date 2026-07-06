//
//  HiddenKeyboardShortcutButton.swift
//  BeanNotes
//

import SwiftUI

struct HiddenKeyboardShortcutButton: View {
    var title: String
    var key: KeyEquivalent
    var modifiers: EventModifiers = [.command]
    var action: () -> Void

    var body: some View {
        Button(title, action: action)
            .keyboardShortcut(key, modifiers: modifiers)
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .accessibilityHidden(true)
    }
}
