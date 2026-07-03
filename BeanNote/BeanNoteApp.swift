//
//  BeanNoteApp.swift
//  BeanNote
//
//  Created by Jarrod on 2026-07-02.
//

import SwiftUI
import SwiftData

@main
struct BeanNoteApp: App {
    var sharedModelContainer = BeanNoteModelContainer.make()

    init() {
        LocalNotificationService.shared.configureForegroundPresentation()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}

enum BeanNoteModelContainer {
    static func make() -> ModelContainer {
        let schema = Schema([
            NotebookFolder.self,
            NoteDocument.self,
            NotePage.self,
            Attachment.self
        ])

        do {
            return try ModelContainer(for: schema, configurations: [configuration(for: schema)])
        } catch {
            NSLog("BeanNote SwiftData store failed to open: \(error)")
            archivePersistentStore()

            do {
                return try ModelContainer(for: schema, configurations: [configuration(for: schema)])
            } catch {
                assertionFailure("BeanNote is running with in-memory SwiftData after persistent store recovery failed: \(error)")
                return try! ModelContainer(
                    for: schema,
                    configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
                )
            }
        }
    }

    private static func configuration(for schema: Schema) -> ModelConfiguration {
        ModelConfiguration(
            "BeanNote",
            schema: schema,
            url: persistentStoreURL(),
            allowsSave: true,
            cloudKitDatabase: .none
        )
    }

    private static func persistentStoreURL() -> URL {
        let fileManager = FileManager.default
        let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directoryURL = applicationSupportURL.appendingPathComponent("BeanNote", isDirectory: true)

        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL.appendingPathComponent("BeanNote.store")
    }

    private static func archivePersistentStore() {
        let fileManager = FileManager.default
        let storeURL = persistentStoreURL()
        let archiveDirectory = storeURL
            .deletingLastPathComponent()
            .appendingPathComponent("RecoveredStores", isDirectory: true)
            .appendingPathComponent(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)), isDirectory: true)

        do {
            try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)

            for url in persistentStoreSidecarURLs(for: storeURL) where fileManager.fileExists(atPath: url.path) {
                try fileManager.moveItem(
                    at: url,
                    to: archiveDirectory.appendingPathComponent(url.lastPathComponent)
                )
            }
        } catch {
            NSLog("BeanNote could not archive failed SwiftData store: \(error)")
        }
    }

    private static func persistentStoreSidecarURLs(for storeURL: URL) -> [URL] {
        [
            storeURL,
            URL(fileURLWithPath: "\(storeURL.path)-shm"),
            URL(fileURLWithPath: "\(storeURL.path)-wal")
        ]
    }
}
