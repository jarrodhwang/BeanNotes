//
//  BeanNotesApp.swift
//  BeanNotes
//
//  Created by Jarrod on 2026-07-02.
//

import Foundation
import SwiftData
import SwiftUI

@main
struct BeanNotesApp: App {
    @State private var sharedModelContainer: ModelContainer?
    @State private var modelContainerErrorDescription: String?

    init() {
        LocalNotificationService.shared.configureForegroundPresentation()

        switch BeanNotesModelContainer.make() {
        case .success(let container):
            _sharedModelContainer = State(initialValue: container)
            _modelContainerErrorDescription = State(initialValue: nil)
        case .failure(let error):
            _sharedModelContainer = State(initialValue: nil)
            _modelContainerErrorDescription = State(initialValue: error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let sharedModelContainer {
                ContentView()
                    .modelContainer(sharedModelContainer)
            } else {
                ModelContainerUnavailableView(
                    errorDescription: modelContainerErrorDescription,
                    retry: reloadModelContainer
                )
            }
        }
    }

    private func reloadModelContainer() {
        switch BeanNotesModelContainer.make() {
        case .success(let container):
            sharedModelContainer = container
            modelContainerErrorDescription = nil
        case .failure(let error):
            sharedModelContainer = nil
            modelContainerErrorDescription = error.localizedDescription
        }
    }
}

enum BeanNotesModelContainer {
    private static let storeOpenRetryDelays: [TimeInterval] = [0.15, 0.35]

    static func make() -> Result<ModelContainer, Error> {
        BeanNotesLaunchConfiguration.prepareIfNeeded(persistentStoreURL: persistentStoreURL())

        let schema = Schema([
            NotebookFolder.self,
            NoteDocument.self,
            NotePage.self,
            Attachment.self
        ])

        let result: Result<ModelContainer, Error> = loadWithRetries(
            retryDelays: storeOpenRetryDelays,
            load: {
                try ModelContainer(for: schema, configurations: [configuration(for: schema)])
            }
        )
        if case .failure(let error) = result {
            // A temporary lock or protected-data delay must never move the user's
            // database aside or replace the library with an empty in-memory store.
            NSLog("BeanNotes SwiftData store is temporarily unavailable; preserving it for retry: \(error)")
        }
        return result
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

    static func loadWithRetries<T>(
        retryDelays: [TimeInterval],
        wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        load: () throws -> T
    ) -> Result<T, Error> {
        for attempt in 0...retryDelays.count {
            do {
                return .success(try load())
            } catch {
                guard attempt < retryDelays.count else {
                    return .failure(error)
                }
                wait(max(retryDelays[attempt], 0))
            }
        }
        fatalError("BeanNotes store retry loop completed without a result.")
    }

    static func persistentStoreSidecarURLs(for storeURL: URL) -> [URL] {
        [
            storeURL,
            URL(fileURLWithPath: "\(storeURL.path)-shm"),
            URL(fileURLWithPath: "\(storeURL.path)-wal")
        ]
    }
}

private struct ModelContainerUnavailableView: View {
    var errorDescription: String?
    var retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Notes Storage Unavailable", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(
                "BeanNotes kept your existing library unchanged. Unlock the iPad if needed, then try opening it again."
            )
        } actions: {
            Button("Try Again", systemImage: "arrow.clockwise", action: retry)
                .buttonStyle(.borderedProminent)

            if let errorDescription, !errorDescription.isEmpty {
                Text(errorDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        }
        .padding()
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
