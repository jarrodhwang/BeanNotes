//
//  BeanNotesApp.swift
//  BeanNotes
//
//  Created by Jarrod on 2026-07-02.
//

import SwiftUI
import SwiftData

@main
struct BeanNotesApp: App {
    var sharedModelContainer = BeanNotesModelContainer.make()

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

enum BeanNotesModelContainer {
    static func make() -> ModelContainer {
        BeanNotesLaunchConfiguration.prepareIfNeeded(persistentStoreURL: persistentStoreURL())

        let schema = Schema([
            NotebookFolder.self,
            NoteDocument.self,
            NotePage.self,
            Attachment.self
        ])

        do {
            return try ModelContainer(for: schema, configurations: [configuration(for: schema)])
        } catch {
            NSLog("BeanNotes SwiftData store failed to open: \(error)")
            archivePersistentStore()

            do {
                return try ModelContainer(for: schema, configurations: [configuration(for: schema)])
            } catch {
                NSLog("BeanNotes persistent store recovery failed; opening temporary in-memory store: \(error)")
                return inMemoryFallbackContainer(for: schema)
            }
        }
    }

    private static func configuration(for schema: Schema) -> ModelConfiguration {
        ModelConfiguration(
            "BeanNotes",
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
        let directoryURL = applicationSupportURL.appendingPathComponent("BeanNotes", isDirectory: true)

        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL.appendingPathComponent("BeanNotes.store")
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
            NSLog("BeanNotes could not archive failed SwiftData store: \(error)")
        }
    }

    private static func inMemoryFallbackContainer(for schema: Schema) -> ModelContainer {
        do {
            return try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
        } catch {
            fatalError("BeanNotes could not create a SwiftData container: \(error)")
        }
    }

    static func persistentStoreSidecarURLs(for storeURL: URL) -> [URL] {
        [
            storeURL,
            URL(fileURLWithPath: "\(storeURL.path)-shm"),
            URL(fileURLWithPath: "\(storeURL.path)-wal")
        ]
    }
}

enum BeanNotesLaunchConfiguration {
    static let uiTestingArgument = "--beannotes-ui-testing"
    static let resetStorageArgument = "--beannotes-reset-storage"
    static let skipWelcomeArgument = "--beannotes-skip-welcome"

    private static var didPrepare = false

    static func prepareIfNeeded(persistentStoreURL: URL) {
        let arguments = ProcessInfo.processInfo.arguments
        let defaults = UserDefaults.standard

        guard arguments.contains(uiTestingArgument),
              !didPrepare else {
            return
        }

        if arguments.contains(resetStorageArgument) {
            resetAppState(persistentStoreURL: persistentStoreURL)
        }

        if arguments.contains(skipWelcomeArgument) {
            defaults.set(true, forKey: ContentView.welcomeSeenKey)
            defaults.set(ContentView.currentWelcomeContentVersion, forKey: ContentView.welcomeContentVersionKey)
        }

        didPrepare = true
    }

    private static func resetAppState(persistentStoreURL: URL) {
        let defaults = UserDefaults.standard
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: bundleIdentifier)
        }

        let fileManager = FileManager.default
        for url in BeanNotesModelContainer.persistentStoreSidecarURLs(for: persistentStoreURL) {
            removeItemIfPresent(at: url, fileManager: fileManager)
        }

        removeItemIfPresent(at: LocalStorageService(fileManager: fileManager).rootURL, fileManager: fileManager)

        if let sharedInboxURL = LocalStorageService.sharedInboxURL(fileManager: fileManager) {
            removeItemIfPresent(at: sharedInboxURL, fileManager: fileManager)
        }

        if let sharedFolderIndexURL = LocalStorageService.sharedFolderIndexURL(fileManager: fileManager) {
            removeItemIfPresent(at: sharedFolderIndexURL.deletingLastPathComponent(), fileManager: fileManager)
        }

        DrawingStorageService.clearCache()
    }

    private static func removeItemIfPresent(at url: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: url.path) else { return }

        do {
            try fileManager.removeItem(at: url)
        } catch {
            NSLog("BeanNotes UI test reset could not remove \(url.path): \(error)")
        }
    }
}
