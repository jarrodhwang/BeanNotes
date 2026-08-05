//
//  LocalStorageService.swift
//  BeanNotes
//

import Foundation
import OSLog
import UniformTypeIdentifiers

/// Serializes filesystem mutations that must be observed as one operation. A
/// recursive lock keeps the existing synchronous storage API source-compatible
/// while preventing independent service values from racing on the same files.
enum StorageMutationCoordinator {
    nonisolated private static let lock = NSRecursiveLock()
    nonisolated(unsafe) private static var activeImportDirectories: Set<String> = []

    nonisolated static func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    nonisolated static func registerImport(_ directoryURL: URL) {
        _ = withLock {
            activeImportDirectories.insert(directoryURL.standardizedFileURL.path)
        }
    }

    nonisolated static func unregisterImport(_ directoryURL: URL) {
        _ = withLock {
            activeImportDirectories.remove(directoryURL.standardizedFileURL.path)
        }
    }

    nonisolated static func isImportActive(_ directoryURL: URL) -> Bool {
        withLock {
            activeImportDirectories.contains(directoryURL.standardizedFileURL.path)
        }
    }
}

/// Lets UI-facing storage work stop waiting even when a synchronous Foundation
/// file operation is stuck inside a file-provider extension. Cancelling a Swift
/// task cannot interrupt `FileManager` while it is blocked in that extension,
/// so the first completion (result, timeout, or cancellation) wins.
nonisolated private final class StorageOperationResultGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

enum StorageOperationRunner {
    nonisolated static func run<Value: Sendable>(
        priority: TaskPriority = .utility,
        timeout: TimeInterval,
        timeoutError: @autoclosure @escaping @Sendable () -> Error,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let gate = StorageOperationResultGate<Value>()
        let worker = Task.detached(priority: priority) {
            do {
                gate.resolve(.success(try await operation()))
            } catch {
                gate.resolve(.failure(error))
            }
        }
        let timeoutWorker = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                gate.resolve(.failure(timeoutError()))
                worker.cancel()
            } catch {
                // The operation completed before its deadline.
            }
        }

        defer { timeoutWorker.cancel() }
        return try await withTaskCancellationHandler {
            try await gate.wait()
        } onCancel: {
            worker.cancel()
            gate.resolve(.failure(CancellationError()))
        }
    }
}

struct StoredFile: Equatable, Sendable {
    var relativePath: String
    var fileName: String
    var contentTypeIdentifier: String
}

struct ImportStagingTransaction: Sendable {
    nonisolated let rootURL: URL
    nonisolated let id: UUID

    nonisolated private var importsURL: URL {
        rootURL.appendingPathComponent(StorageDirectory.imports.rawValue, isDirectory: true)
    }

    nonisolated private var pendingRootURL: URL {
        importsURL.appendingPathComponent(".Pending", isDirectory: true)
    }

    nonisolated var stagingDirectoryURL: URL {
        pendingRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    nonisolated var finalRelativeDirectoryPath: String {
        "\(StorageDirectory.imports.rawValue)/\(id.uuidString)"
    }

    nonisolated var finalDirectoryURL: URL {
        rootURL.appendingPathComponent(finalRelativeDirectoryPath, isDirectory: true)
    }

    nonisolated init(rootURL: URL, id: UUID = UUID()) {
        self.rootURL = rootURL
        self.id = id
        StorageMutationCoordinator.registerImport(stagingDirectoryURL)
    }

    nonisolated func copyFile(from sourceURL: URL, preferredName: String? = nil) throws -> StoredFile {
        let isScoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw LocalStorageError.fileMissing(sourceURL)
        }

        let fileName = uniqueFileName(preferredName ?? sourceURL.lastPathComponent)
        let incomingURL = stagingDirectoryURL.appendingPathComponent(
            ".Incoming-\(UUID().uuidString)",
            isDirectory: false
        )
        try fileManager.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: true)
        do {
            // Never hold the app-wide mutation lock while a third-party file
            // provider is servicing this read. It may need network access or
            // user authentication and can block for an unbounded amount of time.
            try fileManager.copyItem(at: sourceURL, to: incomingURL)
            try Task.checkCancellation()
            return try StorageMutationCoordinator.withLock {
                let destinationURL = stagingDirectoryURL.appendingPathComponent(fileName)
                try fileManager.moveItem(at: incomingURL, to: destinationURL)
                let contentType = UTType(filenameExtension: destinationURL.pathExtension) ?? .data
                return storedFile(fileName: fileName, contentType: contentType)
            }
        } catch {
            try? fileManager.removeItem(at: incomingURL)
            throw error
        }
    }

    nonisolated func saveData(_ data: Data, preferredName: String, contentType: UTType) throws -> StoredFile {
        try StorageMutationCoordinator.withLock {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: true)
            let fileName = uniqueFileName(preferredName)
            try data.write(to: stagingDirectoryURL.appendingPathComponent(fileName), options: [.atomic])
            return storedFile(fileName: fileName, contentType: contentType)
        }
    }

    nonisolated func stagedURL(for storedFile: StoredFile) -> URL {
        stagingDirectoryURL.appendingPathComponent(storedFile.fileName)
    }

    nonisolated func finalURL(for storedFile: StoredFile) -> URL {
        rootURL.appendingPathComponent(storedFile.relativePath)
    }

    nonisolated func stagedFileNames() -> Set<String> {
        StorageMutationCoordinator.withLock {
            guard
                let contents = try? FileManager.default.contentsOfDirectory(
                    at: stagingDirectoryURL,
                    includingPropertiesForKeys: nil
                )
            else {
                return []
            }

            return Set(contents.map(\.lastPathComponent))
        }
    }

    nonisolated func removeStagedFiles(excluding retainedFileNames: Set<String>) {
        StorageMutationCoordinator.withLock {
            let fileManager = FileManager.default
            guard
                let contents = try? fileManager.contentsOfDirectory(
                    at: stagingDirectoryURL,
                    includingPropertiesForKeys: nil
                )
            else {
                return
            }

            for url in contents where !retainedFileNames.contains(url.lastPathComponent) {
                do {
                    try fileManager.removeItem(at: url)
                } catch {
                    LocalStorageService.logStorageFailure(
                        operation: "staging_prune",
                        relativePath: url.lastPathComponent,
                        rootURL: rootURL,
                        itemURL: url,
                        error: error
                    )
                }
            }
        }
    }

    nonisolated func commit() throws {
        try StorageMutationCoordinator.withLock {
            let fileManager = FileManager.default
            let stagingExists = fileManager.fileExists(atPath: stagingDirectoryURL.path)
            let finalExists = fileManager.fileExists(atPath: finalDirectoryURL.path)

            if !stagingExists {
                StorageMutationCoordinator.unregisterImport(stagingDirectoryURL)
                if finalExists {
                    return
                }
                throw LocalStorageError.missingImportStagingData(id)
            }

            guard !finalExists else {
                throw LocalStorageError.importDestinationAlreadyExists(id)
            }

            let stagedItems = try fileManager.contentsOfDirectory(
                at: stagingDirectoryURL,
                includingPropertiesForKeys: nil
            )
            guard !stagedItems.isEmpty else {
                throw LocalStorageError.missingImportStagingData(id)
            }

            try fileManager.createDirectory(at: importsURL, withIntermediateDirectories: true)
            try fileManager.moveItem(at: stagingDirectoryURL, to: finalDirectoryURL)
            StorageMutationCoordinator.unregisterImport(stagingDirectoryURL)
        }
    }

    nonisolated func rollback() {
        StorageMutationCoordinator.withLock {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: stagingDirectoryURL.path) {
                do {
                    try fileManager.removeItem(at: stagingDirectoryURL)
                } catch {
                    LocalStorageService.logStorageFailure(
                        operation: "staging_rollback",
                        relativePath: id.uuidString,
                        rootURL: rootURL,
                        itemURL: stagingDirectoryURL,
                        error: error
                    )
                }
            }
            StorageMutationCoordinator.unregisterImport(stagingDirectoryURL)
        }
    }

    /// Removes files from a transaction that committed successfully but whose
    /// corresponding model save failed. It never touches another transaction.
    nonisolated func removeCommittedFiles() throws {
        try StorageMutationCoordinator.withLock {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: finalDirectoryURL.path) else { return }
            try fileManager.removeItem(at: finalDirectoryURL)
        }
    }

    nonisolated func discardCommittedFilesAfterModelFailure() {
        do {
            try removeCommittedFiles()
        } catch {
            LocalStorageService.logStorageFailure(
                operation: "committed_import_cleanup",
                relativePath: finalRelativeDirectoryPath,
                rootURL: rootURL,
                itemURL: finalDirectoryURL,
                error: error
            )
        }
    }

    nonisolated private func storedFile(fileName: String, contentType: UTType) -> StoredFile {
        StoredFile(
            relativePath: "\(finalRelativeDirectoryPath)/\(fileName)",
            fileName: fileName,
            contentTypeIdentifier: contentType.identifier
        )
    }

    nonisolated private func uniqueFileName(_ preferredName: String) -> String {
        let sanitized = preferredName.sanitizedFileName
        let url = URL(fileURLWithPath: sanitized)
        let baseName = url.deletingPathExtension().lastPathComponent
        let pathExtension = url.pathExtension
        let suffix = UUID().uuidString

        if pathExtension.isEmpty {
            return "\(baseName)-\(suffix)"
        } else {
            return "\(baseName)-\(suffix).\(pathExtension)"
        }
    }

}

struct LocalStorageCleanupReport: Equatable, Sendable {
    var removedRelativePaths: [String] = []
    var failedRelativePaths: [String] = []

    nonisolated init(
        removedRelativePaths: [String] = [],
        failedRelativePaths: [String] = []
    ) {
        self.removedRelativePaths = removedRelativePaths
        self.failedRelativePaths = failedRelativePaths
    }

    var hasFailures: Bool {
        !failedRelativePaths.isEmpty
    }
}

struct LocalStorageDirectoryUsage: Equatable, Identifiable, Sendable {
    var directory: StorageDirectory
    var byteCount: Int64
    var fileCount: Int

    var id: StorageDirectory { directory }
}

struct LocalStorageUsageSnapshot: Equatable, Sendable {
    var directories: [LocalStorageDirectoryUsage]

    var totalByteCount: Int64 {
        directories.reduce(0) { $0 + $1.byteCount }
    }

    var totalFileCount: Int {
        directories.reduce(0) { $0 + $1.fileCount }
    }

    func usage(for directory: StorageDirectory) -> LocalStorageDirectoryUsage? {
        directories.first { $0.directory == directory }
    }
}

struct LocalStorageExportCleanupReport: Equatable, Sendable {
    var removedFileCount = 0
    var removedByteCount: Int64 = 0
    var failedFileCount = 0

    nonisolated init(
        removedFileCount: Int = 0,
        removedByteCount: Int64 = 0,
        failedFileCount: Int = 0
    ) {
        self.removedFileCount = removedFileCount
        self.removedByteCount = removedByteCount
        self.failedFileCount = failedFileCount
    }

    var hasFailures: Bool {
        failedFileCount > 0
    }
}

enum LocalStorageExportCleanupScope: Sendable {
    case renderedExports
    case backups
    case all

    nonisolated func includes(pathExtension: String) -> Bool {
        let normalizedExtension = pathExtension.lowercased()
        switch self {
        case .renderedExports:
            return Self.renderedExtensions.contains(normalizedExtension)
        case .backups:
            return normalizedExtension == "beannotes"
        case .all:
            return Self.renderedExtensions.contains(normalizedExtension)
                || normalizedExtension == "beannotes"
        }
    }

    nonisolated private static let renderedExtensions = Set(["pdf", "png", "jpg", "jpeg"])
}

struct LocalStorageCleanupTarget: Equatable, Sendable {
    var relativePaths: Set<String> = []
    var drawingFileNames: Set<String> = []
    var exportedNoteIDs: Set<UUID> = []

    init(note: NoteDocument) {
        insert(note)
    }

    init(notes: [NoteDocument]) {
        for note in notes {
            insert(note)
        }
    }

    init(page: NotePage) {
        insert(page)
    }

    init(attachment: Attachment) {
        insert(attachment)
    }

    init(attachments: [Attachment]) {
        for attachment in attachments {
            insert(attachment)
        }
    }

    init(folder: NotebookFolder) {
        for note in folder.notes {
            insert(note)
        }
    }

    private mutating func insert(_ note: NoteDocument) {
        exportedNoteIDs.insert(note.id)

        for page in note.pages {
            insert(page)
        }
    }

    private mutating func insert(_ page: NotePage) {
        if let drawingPath = LocalStorageService.managedRelativePath(
            forFileName: page.drawingFileName,
            in: .drawings
        ) {
            drawingFileNames.insert(page.drawingFileName)
            relativePaths.insert(drawingPath)
        }

        if let thumbnailFileName = page.thumbnailFileName,
           let thumbnailPath = LocalStorageService.normalizedThumbnailRelativePath(thumbnailFileName) {
            relativePaths.insert(thumbnailPath)
        }

        for attachment in page.attachments {
            insert(attachment)
        }
    }

    private mutating func insert(_ attachment: Attachment) {
        if LocalStorageService.isValidManagedRelativePath(attachment.storedFileName) {
            relativePaths.insert(attachment.storedFileName)
        }
        if let vectorSourceStoredFileName = attachment.vectorSourceStoredFileName,
           LocalStorageService.isValidManagedRelativePath(vectorSourceStoredFileName) {
            relativePaths.insert(vectorSourceStoredFileName)
        }
    }
}

enum StorageDirectory: String, CaseIterable, Sendable {
    case drawings = "Drawings"
    case imports = "Imports"
    case thumbnails = "Thumbnails"
    case exports = "Exports"
}

enum LocalStorageError: LocalizedError {
    case missingDocumentsDirectory
    case fileMissing(URL)
    case invalidRelativePath(String)
    case missingImportStagingData(UUID)
    case importDestinationAlreadyExists(UUID)
    case storageScanTimedOut
    case storageOperationTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .missingDocumentsDirectory:
            "BeanNotes could not locate the app documents directory."
        case .fileMissing(let url):
            "The file could not be found: \(url.lastPathComponent)"
        case .invalidRelativePath(let path):
            "The file path is not inside BeanNotes storage: \(path)"
        case .missingImportStagingData:
            "The imported files are no longer available. Please try the import again."
        case .importDestinationAlreadyExists:
            "The import destination already exists. Your existing files were not changed."
        case .storageScanTimedOut:
            "Storage calculation took too long. Your notes remain available; try again after current saves finish."
        case .storageOperationTimedOut(let operation):
            "\(operation) could not finish because a file or storage provider stopped responding. Reopen Files, confirm the file is downloaded, and try again."
        }
    }
}

struct LocalStorageService {
    static let appGroupIdentifier = "group.com.snowfox.BeanNotes"
    nonisolated static let logger = Logger(
        subsystem: "com.snowfox.BeanNotes",
        category: "LocalStorage"
    )

    nonisolated static func logStorageFailure(
        operation: String,
        relativePath: String,
        rootURL: URL,
        itemURL: URL,
        error: Error
    ) {
        let nsError = error as NSError
        let availableCapacity = (try? rootURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage) ?? -1
        let existed = FileManager.default.fileExists(atPath: itemURL.path)
        logger.error(
            "operation=\(operation, privacy: .public) path=\(relativePath, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) available=\(availableCapacity, privacy: .public) existed=\(existed, privacy: .public) main=\(Thread.isMainThread, privacy: .public)"
        )
    }

    nonisolated private static func isExecutingOnMainThread() -> Bool {
        Thread.isMainThread
    }

    nonisolated(unsafe) let fileManager: FileManager
    nonisolated let rootURL: URL

    nonisolated init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager

        if let rootURL {
            self.rootURL = rootURL
        } else {
            let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            // FileManager's canonical Documents lookup should always succeed in the
            // app sandbox. If it does not, remain in the persistent sandbox instead
            // of silently redirecting user data to purgeable temporary storage.
            let persistentDocumentsURL = documentsURL
                ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                    .appendingPathComponent("Documents", isDirectory: true)
            if documentsURL == nil {
                Self.logger.fault("documents_lookup_failed using_persistent_sandbox_fallback=true")
            }
            self.rootURL = persistentDocumentsURL
                .appendingPathComponent("BeanNotes", isDirectory: true)
        }
    }

    nonisolated static func production(
        fileManager: FileManager = .default,
        documentsDirectoryProvider: @Sendable (FileManager) -> URL? = {
            $0.urls(for: .documentDirectory, in: .userDomainMask).first
        }
    ) throws -> LocalStorageService {
        guard let documentsURL = documentsDirectoryProvider(fileManager) else {
            throw LocalStorageError.missingDocumentsDirectory
        }
        return LocalStorageService(
            fileManager: fileManager,
            rootURL: documentsURL.appendingPathComponent("BeanNotes", isDirectory: true)
        )
    }

    nonisolated func prepareDirectories() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        for directory in StorageDirectory.allCases {
            _ = try directoryURL(for: directory)
        }
    }

    nonisolated func directoryURL(for directory: StorageDirectory) throws -> URL {
        var url = rootURL.appendingPathComponent(directory.rawValue, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)

        if directory == .thumbnails {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            do {
                try url.setResourceValues(values)
            } catch {
                Self.logStorageFailure(
                    operation: "exclude_thumbnails_from_device_backup",
                    relativePath: StorageDirectory.thumbnails.rawValue,
                    rootURL: rootURL,
                    itemURL: url,
                    error: error
                )
            }
        }

        return url
    }

    nonisolated func url(forRelativePath relativePath: String) -> URL {
        rootURL.appendingPathComponent(relativePath)
    }

    nonisolated func validatedURL(forRelativePath relativePath: String) throws -> URL {
        let trimmedPath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPath == relativePath,
              Self.isValidManagedRelativePath(trimmedPath) else {
            throw LocalStorageError.invalidRelativePath(relativePath)
        }

        let suppliedComponents = trimmedPath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)

        let fileURL = rootURL
            .appendingPathComponent(trimmedPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let relativeComponents = try relativePathComponents(for: fileURL, invalidPathDescription: relativePath)
        guard relativeComponents == suppliedComponents,
              Self.areValidManagedPathComponents(relativeComponents) else {
            throw LocalStorageError.invalidRelativePath(relativePath)
        }

        return fileURL
    }

    nonisolated func relativePath(for fileURL: URL) throws -> String {
        let relativeComponents = try relativePathComponents(
            for: fileURL,
            invalidPathDescription: fileURL.standardizedFileURL.path
        )
        guard Self.areValidManagedPathComponents(relativeComponents) else {
            throw LocalStorageError.invalidRelativePath(fileURL.standardizedFileURL.path)
        }
        return relativeComponents.joined(separator: "/")
    }

    /// Converts legacy thumbnail values that stored only the final filename into
    /// the managed `Thumbnails/<filename>` representation used by current notes.
    nonisolated static func normalizedThumbnailRelativePath(_ storedPath: String) -> String? {
        let trimmedPath = storedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty, !trimmedPath.contains("\\") else { return nil }

        if trimmedPath.contains("/") {
            let components = trimmedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard components.count == 2,
                  components.first == StorageDirectory.thumbnails.rawValue,
                  areValidManagedPathComponents(components) else {
                return nil
            }
            return components.joined(separator: "/")
        }

        return managedRelativePath(forFileName: trimmedPath, in: .thumbnails)
    }

    nonisolated static func managedRelativePath(
        forFileName fileName: String,
        in directory: StorageDirectory
    ) -> String? {
        let trimmedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName == fileName,
              !trimmedName.isEmpty,
              trimmedName != ".",
              trimmedName != "..",
              !trimmedName.contains("/"),
              !trimmedName.contains("\\") else {
            return nil
        }
        return "\(directory.rawValue)/\(trimmedName)"
    }

    nonisolated static func isValidManagedRelativePath(_ relativePath: String) -> Bool {
        let trimmedPath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPath == relativePath,
              !trimmedPath.isEmpty,
              !trimmedPath.hasPrefix("/"),
              !trimmedPath.contains("\\") else {
            return false
        }
        let components = trimmedPath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        return areValidManagedPathComponents(components)
    }

    nonisolated private static func areValidManagedPathComponents(_ components: [String]) -> Bool {
        guard components.count >= 2,
              let directory = components.first.flatMap(StorageDirectory.init(rawValue:)),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !components.dropFirst().contains(".Pending") else {
            return false
        }

        // Drawings, thumbnails, and exports are flat managed directories. Imports
        // may additionally contain a committed transaction directory.
        return directory == .imports || components.count == 2
    }

    nonisolated func copyFile(
        from sourceURL: URL,
        preferredName: String? = nil,
        to directory: StorageDirectory = .imports
    ) throws -> StoredFile {
        let isScoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw LocalStorageError.fileMissing(sourceURL)
        }

        let destinationDirectoryURL = try directoryURL(for: directory)
        let fileName = uniqueFileName(preferredName ?? sourceURL.lastPathComponent)
        let incomingURL = destinationDirectoryURL.appendingPathComponent(
            ".Incoming-\(UUID().uuidString)",
            isDirectory: false
        )

        do {
            // Reading the source can enter an external file-provider process.
            // Keep it outside the global mutation lock so the rest of storage
            // remains usable if that provider is unavailable.
            try fileManager.copyItem(at: sourceURL, to: incomingURL)
            try Task.checkCancellation()
            return try StorageMutationCoordinator.withLock {
                let destinationURL = destinationDirectoryURL.appendingPathComponent(fileName)
                try fileManager.moveItem(at: incomingURL, to: destinationURL)
                let contentType = UTType(filenameExtension: destinationURL.pathExtension) ?? .data
                return StoredFile(
                    relativePath: try relativePath(for: destinationURL),
                    fileName: fileName,
                    contentTypeIdentifier: contentType.identifier
                )
            }
        } catch {
            try? fileManager.removeItem(at: incomingURL)
            throw error
        }
    }

    nonisolated func beginImportStagingTransaction() -> ImportStagingTransaction {
        ImportStagingTransaction(rootURL: rootURL)
    }

    nonisolated func saveData(
        _ data: Data,
        preferredName: String,
        contentType: UTType,
        to directory: StorageDirectory = .imports
    ) throws -> StoredFile {
        try StorageMutationCoordinator.withLock {
            let directoryURL = try directoryURL(for: directory)
            let fileName = uniqueFileName(preferredName)
            let destinationURL = directoryURL.appendingPathComponent(fileName)
            try data.write(to: destinationURL, options: [.atomic])
            invalidateCaches(for: destinationURL, directory: directory)

            return StoredFile(
                relativePath: try relativePath(for: destinationURL),
                fileName: fileName,
                contentTypeIdentifier: contentType.identifier
            )
        }
    }

    nonisolated func saveData(
        _ data: Data,
        fileName: String,
        contentType: UTType,
        to directory: StorageDirectory,
        replacingExisting _: Bool
    ) throws -> StoredFile {
        try StorageMutationCoordinator.withLock {
            let directoryURL = try directoryURL(for: directory)
            let sanitizedName = fileName.sanitizedFileName
            let destinationURL = directoryURL.appendingPathComponent(sanitizedName)

            // Atomic writes replace an existing file themselves. Removing it first leaves
            // a visible gap for preview readers and can make an otherwise valid preview
            // briefly appear missing while it is being refreshed.
            try data.write(to: destinationURL, options: [.atomic])
            invalidateCaches(for: destinationURL, directory: directory)

            return StoredFile(
                relativePath: try relativePath(for: destinationURL),
                fileName: sanitizedName,
                contentTypeIdentifier: contentType.identifier
            )
        }
    }

    /// Atomically replaces a file already owned by BeanNotes while preserving its
    /// relative path. This is useful for derived previews whose model references
    /// must remain stable while readers may still have the prior image open.
    nonisolated func replaceStoredData(_ data: Data, relativePath: String) throws {
        try StorageMutationCoordinator.withLock {
            let destinationURL = try validatedURL(forRelativePath: relativePath)
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destinationURL, options: [.atomic])
            invalidateCaches(for: destinationURL, directory: storageDirectory(for: relativePath))
        }
    }

    @discardableResult
    nonisolated func removeFile(relativePath: String) throws -> Bool {
        try StorageMutationCoordinator.withLock {
            let fileURL = try validatedURL(forRelativePath: relativePath)
            guard fileManager.fileExists(atPath: fileURL.path) else { return false }
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw LocalStorageError.invalidRelativePath(relativePath)
            }
            try fileManager.removeItem(at: fileURL)
            invalidateCaches(for: fileURL, directory: storageDirectory(for: relativePath))
            return true
        }
    }

    nonisolated func copyStoredFileIfPresent(
        relativePath: String,
        preferredFileName: String? = nil
    ) throws -> String? {
        try StorageMutationCoordinator.withLock {
            let sourceURL = try validatedURL(forRelativePath: relativePath)
            guard fileManager.fileExists(atPath: sourceURL.path) else { return nil }
            let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw LocalStorageError.invalidRelativePath(relativePath)
            }

            let destinationDirectoryURL = sourceURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: destinationDirectoryURL, withIntermediateDirectories: true)

            let destinationFileName = uniqueFileName(preferredFileName ?? sourceURL.lastPathComponent)
            let destinationURL = destinationDirectoryURL.appendingPathComponent(destinationFileName)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return try self.relativePath(for: destinationURL)
        }
    }

    @discardableResult
    nonisolated func removeStoredFiles(
        matching target: LocalStorageCleanupTarget
    ) -> LocalStorageCleanupReport {
        var report = LocalStorageCleanupReport()
        var relativePaths = target.relativePaths
        relativePaths.formUnion(exportRelativePaths(matchingNoteIDs: target.exportedNoteIDs))

        for relativePath in relativePaths.sorted() {
            do {
                if try removeFile(relativePath: relativePath) {
                    report.removedRelativePaths.append(relativePath)
                }
            } catch {
                report.failedRelativePaths.append(relativePath)
                Self.logStorageFailure(
                    operation: "remove_managed_file",
                    relativePath: relativePath,
                    rootURL: rootURL,
                    itemURL: url(forRelativePath: relativePath),
                    error: error
                )
            }
        }

        for drawingFileName in target.drawingFileNames {
            DrawingStorageService.removeCachedDrawing(fileName: drawingFileName, rootURL: rootURL)
        }

        return report
    }

    nonisolated func storageUsageSnapshot(maximumDuration: TimeInterval = 12) throws -> LocalStorageUsageSnapshot {
        try Task.checkCancellation()
        try prepareDirectories()
        let deadline = Date().addingTimeInterval(max(maximumDuration, 0))

        let directories = try StorageDirectory.allCases.map { directory in
            try Task.checkCancellation()
            guard Date() <= deadline else {
                throw LocalStorageError.storageScanTimedOut
            }
            let usage = try directoryUsage(at: directoryURL(for: directory), deadline: deadline)
            return LocalStorageDirectoryUsage(
                directory: directory,
                byteCount: usage.byteCount,
                fileCount: usage.fileCount
            )
        }

        return LocalStorageUsageSnapshot(directories: directories)
    }

    nonisolated func storageUsageSnapshotInBackground(
        maximumDuration: TimeInterval = 12,
        executionObserver: (@Sendable (Bool) -> Void)? = nil
    ) async throws -> LocalStorageUsageSnapshot {
        let rootURL = rootURL
        return try await StorageOperationRunner.run(
            timeout: maximumDuration + 2,
            timeoutError: LocalStorageError.storageScanTimedOut
        ) {
            executionObserver?(Self.isExecutingOnMainThread())
            return try LocalStorageService(rootURL: rootURL).storageUsageSnapshot(
                maximumDuration: maximumDuration
            )
        }
    }

    @discardableResult
    nonisolated func removeExports(
        olderThan cutoffDate: Date,
        scope: LocalStorageExportCleanupScope = .renderedExports
    ) throws -> LocalStorageExportCleanupReport {
        try Task.checkCancellation()
        let exportDirectory = try directoryURL(for: .exports)
        let exportURLs = try fileManager.contentsOfDirectory(
            at: exportDirectory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .contentModificationDateKey,
                .fileSizeKey
            ],
            options: []
        )

        var report = LocalStorageExportCleanupReport()

        for url in exportURLs {
            try Task.checkCancellation()
            guard scope.includes(pathExtension: url.pathExtension) else {
                continue
            }

            do {
                let values = try url.resourceValues(
                    forKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
                )
                let isBackup = url.pathExtension.lowercased() == "beannotes"
                guard values.isRegularFile == true || (isBackup && values.isDirectory == true),
                      let modificationDate = values.contentModificationDate,
                      modificationDate < cutoffDate else {
                    continue
                }

                let byteCount = values.isDirectory == true
                    ? try itemUsage(at: url).byteCount
                    : Int64(values.fileSize ?? 0)

                let didRemove = try StorageMutationCoordinator.withLock {
                    // Re-check existence while holding the mutation lock. The URL is
                    // a direct child returned by the managed Exports directory.
                    guard fileManager.fileExists(atPath: url.path) else { return false }
                    try fileManager.removeItem(at: url)
                    ImageMemoryCache.shared.removeImages(for: url)
                    return true
                }
                if didRemove {
                    report.removedFileCount += 1
                    report.removedByteCount += byteCount
                }
            } catch {
                report.failedFileCount += 1
                Self.logStorageFailure(
                    operation: "export_cleanup",
                    relativePath: "Exports/\(url.lastPathComponent)",
                    rootURL: rootURL,
                    itemURL: url,
                    error: error
                )
            }
        }

        return report
    }

    nonisolated func removeExportsInBackground(
        olderThan cutoffDate: Date,
        scope: LocalStorageExportCleanupScope = .renderedExports,
        executionObserver: (@Sendable (Bool) -> Void)? = nil
    ) async throws -> LocalStorageExportCleanupReport {
        let rootURL = rootURL
        return try await StorageOperationRunner.run(
            timeout: 30,
            timeoutError: LocalStorageError.storageOperationTimedOut("Storage cleanup")
        ) {
            executionObserver?(Self.isExecutingOnMainThread())
            return try LocalStorageService(rootURL: rootURL).removeExports(
                olderThan: cutoffDate,
                scope: scope
            )
        }
    }

    /// Removes only inactive, UUID-named staging directories older than the
    /// supplied cutoff. The shared `.Pending` parent is intentionally retained.
    @discardableResult
    nonisolated func removeAbandonedImportStaging(
        olderThan cutoffDate: Date
    ) throws -> LocalStorageCleanupReport {
        try Task.checkCancellation()
        let importsDirectory = try directoryURL(for: .imports)
        let pendingDirectory = importsDirectory.appendingPathComponent(".Pending", isDirectory: true)
        guard fileManager.fileExists(atPath: pendingDirectory.path) else {
            return LocalStorageCleanupReport()
        }

        let candidates = try fileManager.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: []
        )
        var report = LocalStorageCleanupReport()

        for candidate in candidates {
            try Task.checkCancellation()
            let relativePath = "\(StorageDirectory.imports.rawValue)/.Pending/\(candidate.lastPathComponent)"
            do {
                guard UUID(uuidString: candidate.lastPathComponent) != nil,
                      !StorageMutationCoordinator.isImportActive(candidate) else {
                    continue
                }
                let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                guard values.isDirectory == true,
                      let modificationDate = values.contentModificationDate,
                      modificationDate < cutoffDate else {
                    continue
                }

                let didRemove = try StorageMutationCoordinator.withLock {
                    guard !StorageMutationCoordinator.isImportActive(candidate),
                          fileManager.fileExists(atPath: candidate.path) else {
                        return false
                    }
                    try fileManager.removeItem(at: candidate)
                    return true
                }
                if didRemove {
                    report.removedRelativePaths.append(relativePath)
                }
            } catch {
                report.failedRelativePaths.append(relativePath)
                Self.logStorageFailure(
                    operation: "staging_cleanup",
                    relativePath: relativePath,
                    rootURL: rootURL,
                    itemURL: candidate,
                    error: error
                )
            }
        }

        return report
    }

    nonisolated func removeAbandonedImportStagingInBackground(
        olderThan cutoffDate: Date
    ) async throws -> LocalStorageCleanupReport {
        let rootURL = rootURL
        return try await StorageOperationRunner.run(
            timeout: 5,
            timeoutError: LocalStorageError.storageOperationTimedOut("Import maintenance")
        ) {
            try LocalStorageService(rootURL: rootURL).removeAbandonedImportStaging(
                olderThan: cutoffDate
            )
        }
    }

    nonisolated func uniqueFileName(_ preferredName: String) -> String {
        let sanitized = preferredName.sanitizedFileName
        let url = URL(fileURLWithPath: sanitized)
        let baseName = url.deletingPathExtension().lastPathComponent
        let pathExtension = url.pathExtension
        let suffix = UUID().uuidString

        if pathExtension.isEmpty {
            return "\(baseName)-\(suffix)"
        } else {
            return "\(baseName)-\(suffix).\(pathExtension)"
        }
    }

    static func sharedInboxURL(fileManager: FileManager = .default) -> URL? {
        fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("SharedInbox", isDirectory: true)
    }

    static func sharedFolderIndexURL(fileManager: FileManager = .default) -> URL? {
        fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("FolderIndex", isDirectory: true)
            .appendingPathComponent("folders.json")
    }

    nonisolated private func relativePathComponents(
        for fileURL: URL,
        invalidPathDescription: String
    ) throws -> [String] {
        let rootComponents = rootURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let fileComponents = fileURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents

        guard fileComponents.starts(with: rootComponents) else {
            throw LocalStorageError.invalidRelativePath(invalidPathDescription)
        }

        return Array(fileComponents.dropFirst(rootComponents.count))
    }

    nonisolated private func exportRelativePaths(matchingNoteIDs noteIDs: Set<UUID>) -> Set<String> {
        guard !noteIDs.isEmpty,
              let exportDirectory = try? directoryURL(for: .exports),
              let exportURLs = try? fileManager.contentsOfDirectory(
                at: exportDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let exportExtensions = Set(["pdf", "png", "jpg", "jpeg"])

        return Set(exportURLs.compactMap { url in
            guard exportExtensions.contains(url.pathExtension.lowercased()) else {
                return nil
            }

            let fileName = url.lastPathComponent
            guard noteIDs.contains(where: { fileName.hasPrefix("\($0.uuidString)-") }) else {
                return nil
            }

            return try? relativePath(for: url)
        })
    }

    nonisolated private func directoryUsage(
        at directoryURL: URL,
        deadline: Date
    ) throws -> (byteCount: Int64, fileCount: Int) {
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return (0, 0)
        }

        var byteCount: Int64 = 0
        var fileCount = 0

        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard Date() <= deadline else {
                throw LocalStorageError.storageScanTimedOut
            }
            // Autosave and thumbnail refreshes can atomically replace a file after it
            // has been enumerated. Storage usage is informational, so skip that one
            // transient entry rather than failing the whole calculation.
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
                continue
            }
            guard values.isRegularFile == true else { continue }

            fileCount += 1
            byteCount += Int64(values.fileSize ?? 0)
        }

        return (byteCount, fileCount)
    }

    nonisolated private func itemUsage(at itemURL: URL) throws -> (byteCount: Int64, fileCount: Int) {
        let values = try itemURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
        if values.isRegularFile == true {
            return (Int64(values.fileSize ?? 0), 1)
        }
        guard values.isDirectory == true,
              let enumerator = fileManager.enumerator(
                at: itemURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: []
              ) else {
            return (0, 0)
        }

        var byteCount: Int64 = 0
        var fileCount = 0
        for case let url as URL in enumerator {
            guard let itemValues = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  itemValues.isRegularFile == true else {
                continue
            }
            byteCount += Int64(itemValues.fileSize ?? 0)
            fileCount += 1
        }
        return (byteCount, fileCount)
    }

    nonisolated private func storageDirectory(for relativePath: String) -> StorageDirectory? {
        let firstComponent = relativePath.split(separator: "/", omittingEmptySubsequences: true).first
        return firstComponent.flatMap { StorageDirectory(rawValue: String($0)) }
    }

    nonisolated private func invalidateCaches(for fileURL: URL, directory: StorageDirectory?) {
        ImageMemoryCache.shared.removeImages(for: fileURL)
        if directory == .drawings {
            DrawingStorageService.removeCachedDrawing(
                fileName: fileURL.lastPathComponent,
                rootURL: rootURL
            )
        }
    }
}

extension String {
    nonisolated var sanitizedFileName: String {
        let maximumUTF8ByteCount = 180
        let illegalCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)
        let components = components(separatedBy: illegalCharacters)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var sanitized = components.joined(separator: "-")
        if sanitized.isEmpty || sanitized == "." || sanitized == ".." {
            sanitized = "BeanNotes-File"
        }

        let fileURL = URL(fileURLWithPath: sanitized)
        let pathExtension = fileURL.pathExtension
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        guard !pathExtension.isEmpty else {
            return baseName.utf8Prefix(maxByteCount: maximumUTF8ByteCount)
        }

        let extensionSuffix = ".\(pathExtension)"
        let baseBudget = max(1, maximumUTF8ByteCount - extensionSuffix.utf8.count)
        return "\(baseName.utf8Prefix(maxByteCount: baseBudget))\(extensionSuffix)"
    }

    nonisolated fileprivate func utf8Prefix(maxByteCount: Int) -> String {
        guard utf8.count > maxByteCount else { return self }
        var result = ""
        result.reserveCapacity(maxByteCount)
        var byteCount = 0
        for character in self {
            let characterString = String(character)
            let characterByteCount = characterString.utf8.count
            guard byteCount + characterByteCount <= maxByteCount else { break }
            result.append(character)
            byteCount += characterByteCount
        }
        return result.isEmpty ? "BeanNotes-File" : result
    }
}
