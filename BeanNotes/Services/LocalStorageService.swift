//
//  LocalStorageService.swift
//  BeanNotes
//

import Foundation
import UniformTypeIdentifiers

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

        try fileManager.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: true)
        let fileName = uniqueFileName(preferredName ?? sourceURL.lastPathComponent)
        let destinationURL = stagingDirectoryURL.appendingPathComponent(fileName)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        let contentType = UTType(filenameExtension: destinationURL.pathExtension) ?? .data
        return storedFile(fileName: fileName, contentType: contentType)
    }

    nonisolated func saveData(_ data: Data, preferredName: String, contentType: UTType) throws -> StoredFile {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: true)
        let fileName = uniqueFileName(preferredName)
        try data.write(to: stagingDirectoryURL.appendingPathComponent(fileName), options: [.atomic])
        return storedFile(fileName: fileName, contentType: contentType)
    }

    nonisolated func url(for storedFile: StoredFile) -> URL {
        stagingDirectoryURL.appendingPathComponent(storedFile.fileName)
    }

    nonisolated func finalURL(for storedFile: StoredFile) -> URL {
        rootURL.appendingPathComponent(storedFile.relativePath)
    }

    nonisolated func stagedFileNames() -> Set<String> {
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

    nonisolated func removeStagedFiles(excluding retainedFileNames: Set<String>) {
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
            try? fileManager.removeItem(at: url)
        }

        removePendingRootIfEmpty()
    }

    nonisolated func commit() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: stagingDirectoryURL.path) else { return }

        try fileManager.createDirectory(at: importsURL, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: finalDirectoryURL.path) {
            try fileManager.removeItem(at: finalDirectoryURL)
        }

        try fileManager.moveItem(at: stagingDirectoryURL, to: finalDirectoryURL)
        removePendingRootIfEmpty()
    }

    nonisolated func rollback() {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: stagingDirectoryURL.path) {
            try? fileManager.removeItem(at: stagingDirectoryURL)
        }
        removePendingRootIfEmpty()
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

    nonisolated private func removePendingRootIfEmpty() {
        let fileManager = FileManager.default
        guard
            let contents = try? fileManager.contentsOfDirectory(at: pendingRootURL, includingPropertiesForKeys: nil),
            contents.isEmpty
        else {
            return
        }

        try? fileManager.removeItem(at: pendingRootURL)
    }
}

struct LocalStorageCleanupReport: Equatable {
    var removedRelativePaths: [String] = []
    var failedRelativePaths: [String] = []

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

    var hasFailures: Bool {
        failedFileCount > 0
    }
}

struct LocalStorageCleanupTarget: Equatable {
    var relativePaths: Set<String> = []
    var drawingFileNames: Set<String> = []
    var exportedNoteTitlePrefixes: Set<String> = []

    init(note: NoteDocument) {
        insert(note)
    }

    init(page: NotePage) {
        insert(page)
    }

    init(attachment: Attachment) {
        insert(attachment)
    }

    init(folder: NotebookFolder) {
        for note in folder.notes {
            insert(note)
        }
    }

    private mutating func insert(_ note: NoteDocument) {
        exportedNoteTitlePrefixes.insert(note.title.sanitizedFileName)

        for page in note.pages {
            insert(page)
        }
    }

    private mutating func insert(_ page: NotePage) {
        drawingFileNames.insert(page.drawingFileName)
        relativePaths.insert("\(StorageDirectory.drawings.rawValue)/\(page.drawingFileName)")

        if let thumbnailFileName = page.thumbnailFileName {
            relativePaths.insert(thumbnailFileName)
        }

        for attachment in page.attachments {
            insert(attachment)
        }
    }

    private mutating func insert(_ attachment: Attachment) {
        relativePaths.insert(attachment.storedFileName)
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

    var errorDescription: String? {
        switch self {
        case .missingDocumentsDirectory:
            "BeanNotes could not locate the app documents directory."
        case .fileMissing(let url):
            "The file could not be found: \(url.lastPathComponent)"
        case .invalidRelativePath(let path):
            "The file path is not inside BeanNotes storage: \(path)"
        }
    }
}

struct LocalStorageService {
    static let appGroupIdentifier = "group.com.snowfox.BeanNotes"

    nonisolated(unsafe) let fileManager: FileManager
    nonisolated let rootURL: URL

    nonisolated init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager

        if let rootURL {
            self.rootURL = rootURL
        } else {
            let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            self.rootURL = (documentsURL ?? URL(fileURLWithPath: NSTemporaryDirectory()))
                .appendingPathComponent("BeanNotes", isDirectory: true)
        }
    }

    nonisolated func prepareDirectories() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        for directory in StorageDirectory.allCases {
            _ = try directoryURL(for: directory)
        }
    }

    nonisolated func directoryURL(for directory: StorageDirectory) throws -> URL {
        let url = rootURL.appendingPathComponent(directory.rawValue, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated func url(forRelativePath relativePath: String) -> URL {
        rootURL.appendingPathComponent(relativePath)
    }

    nonisolated func validatedURL(forRelativePath relativePath: String) throws -> URL {
        let trimmedPath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw LocalStorageError.invalidRelativePath(relativePath)
        }

        let fileURL = rootURL.appendingPathComponent(trimmedPath).standardizedFileURL
        let relativeComponents = try relativePathComponents(for: fileURL, invalidPathDescription: relativePath)
        guard !relativeComponents.isEmpty else {
            throw LocalStorageError.invalidRelativePath(relativePath)
        }

        return fileURL
    }

    nonisolated func relativePath(for fileURL: URL) throws -> String {
        let relativeComponents = try relativePathComponents(
            for: fileURL,
            invalidPathDescription: fileURL.standardizedFileURL.path
        )
        return relativeComponents.joined(separator: "/")
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

        let directoryURL = try directoryURL(for: directory)
        let fileName = uniqueFileName(preferredName ?? sourceURL.lastPathComponent)
        let destinationURL = directoryURL.appendingPathComponent(fileName)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        let contentType = UTType(filenameExtension: destinationURL.pathExtension) ?? .data
        return StoredFile(
            relativePath: try relativePath(for: destinationURL),
            fileName: fileName,
            contentTypeIdentifier: contentType.identifier
        )
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
        let directoryURL = try directoryURL(for: directory)
        let fileName = uniqueFileName(preferredName)
        let destinationURL = directoryURL.appendingPathComponent(fileName)

        try data.write(to: destinationURL, options: [.atomic])

        return StoredFile(
            relativePath: try relativePath(for: destinationURL),
            fileName: fileName,
            contentTypeIdentifier: contentType.identifier
        )
    }

    nonisolated func saveData(
        _ data: Data,
        fileName: String,
        contentType: UTType,
        to directory: StorageDirectory,
        replacingExisting: Bool
    ) throws -> StoredFile {
        let directoryURL = try directoryURL(for: directory)
        let sanitizedName = fileName.sanitizedFileName
        let destinationURL = directoryURL.appendingPathComponent(sanitizedName)

        if replacingExisting, fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try data.write(to: destinationURL, options: [.atomic])

        return StoredFile(
            relativePath: try relativePath(for: destinationURL),
            fileName: sanitizedName,
            contentTypeIdentifier: contentType.identifier
        )
    }

    @discardableResult
    func removeFile(relativePath: String) throws -> Bool {
        let fileURL = try validatedURL(forRelativePath: relativePath)
        guard fileManager.fileExists(atPath: fileURL.path) else { return false }
        try fileManager.removeItem(at: fileURL)
        ImageMemoryCache.shared.removeImages(for: fileURL)
        return true
    }

    func copyStoredFileIfPresent(relativePath: String, preferredFileName: String? = nil) throws -> String? {
        let sourceURL = try validatedURL(forRelativePath: relativePath)
        guard fileManager.fileExists(atPath: sourceURL.path) else { return nil }

        let destinationDirectoryURL = sourceURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationDirectoryURL, withIntermediateDirectories: true)

        let destinationFileName = uniqueFileName(preferredFileName ?? sourceURL.lastPathComponent)
        let destinationURL = destinationDirectoryURL.appendingPathComponent(destinationFileName)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return try self.relativePath(for: destinationURL)
    }

    @discardableResult
    func removeStoredFiles(matching target: LocalStorageCleanupTarget) -> LocalStorageCleanupReport {
        var report = LocalStorageCleanupReport()
        var relativePaths = target.relativePaths
        relativePaths.formUnion(exportRelativePaths(matchingNoteTitlePrefixes: target.exportedNoteTitlePrefixes))

        for relativePath in relativePaths.sorted() {
            do {
                if try removeFile(relativePath: relativePath) {
                    report.removedRelativePaths.append(relativePath)
                }
            } catch {
                report.failedRelativePaths.append(relativePath)
            }
        }

        for drawingFileName in target.drawingFileNames {
            DrawingStorageService.removeCachedDrawing(fileName: drawingFileName, rootURL: rootURL)
        }

        return report
    }

    nonisolated func storageUsageSnapshot() throws -> LocalStorageUsageSnapshot {
        try prepareDirectories()

        let directories = try StorageDirectory.allCases.map { directory in
            let usage = try directoryUsage(at: directoryURL(for: directory))
            return LocalStorageDirectoryUsage(
                directory: directory,
                byteCount: usage.byteCount,
                fileCount: usage.fileCount
            )
        }

        return LocalStorageUsageSnapshot(directories: directories)
    }

    @discardableResult
    nonisolated func removeExports(olderThan cutoffDate: Date) throws -> LocalStorageExportCleanupReport {
        let exportDirectory = try directoryURL(for: .exports)
        guard let enumerator = fileManager.enumerator(
            at: exportDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return LocalStorageExportCleanupReport()
        }

        var report = LocalStorageExportCleanupReport()

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey])
            guard values.isRegularFile == true,
                  url.pathExtension.lowercased() != "beannotes",
                  let modificationDate = values.contentModificationDate,
                  modificationDate < cutoffDate else {
                continue
            }

            let byteCount = Int64(values.fileSize ?? 0)

            do {
                try fileManager.removeItem(at: url)
                report.removedFileCount += 1
                report.removedByteCount += byteCount
            } catch {
                report.failedFileCount += 1
            }
        }

        return report
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

    private func relativePathComponents(for fileURL: URL, invalidPathDescription: String) throws -> [String] {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents

        guard fileComponents.starts(with: rootComponents) else {
            throw LocalStorageError.invalidRelativePath(invalidPathDescription)
        }

        return Array(fileComponents.dropFirst(rootComponents.count))
    }

    private func exportRelativePaths(matchingNoteTitlePrefixes titlePrefixes: Set<String>) -> Set<String> {
        guard !titlePrefixes.isEmpty,
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
            guard titlePrefixes.contains(where: { fileName.hasPrefix("\($0)-") }) else {
                return nil
            }

            return try? relativePath(for: url)
        })
    }

    private func directoryUsage(at directoryURL: URL) throws -> (byteCount: Int64, fileCount: Int) {
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else {
            return (0, 0)
        }

        var byteCount: Int64 = 0
        var fileCount = 0

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }

            fileCount += 1
            byteCount += Int64(values.fileSize ?? 0)
        }

        return (byteCount, fileCount)
    }
}

extension String {
    nonisolated var sanitizedFileName: String {
        let illegalCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)
        let components = components(separatedBy: illegalCharacters)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let sanitized = components.joined(separator: "-")
        return sanitized.isEmpty ? "BeanNotes-File" : sanitized
    }
}
