//
//  ContentView.swift
//  BeanNote
//
//  Created by Jarrod on 2026-07-02.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @AppStorage("appTheme") private var appThemeRaw = AppTheme.system.rawValue

    var body: some View {
        LibraryView()
            .preferredColorScheme((AppTheme(rawValue: appThemeRaw) ?? .system).colorScheme)
    }
}

#Preview {
    ContentView()
        .modelContainer(
            for: [
                NotebookFolder.self,
                NoteDocument.self,
                NotePage.self,
                Attachment.self
            ],
            inMemory: true
        )
}
