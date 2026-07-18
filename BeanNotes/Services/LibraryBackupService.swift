//
//  LibraryBackupService.swift
//  BeanNotes
//

import Foundation

typealias LibraryBackupProgressHandler = @MainActor @Sendable (_ fraction: Double?, _ message: String) -> Void

struct LibraryBackupResult: Identifiable, Sendable {
    var id = UUID()
    var url: URL
    var fileCount: Int
    var byteCount: Int64
}

enum LibraryBackupError: LocalizedError {
    case archiveTooLarge
    case tooManyArchiveEntries
    case invalidArchiveEntryPath(String)

    var errorDescription: String? {
        switch self {
        case .archiveTooLarge:
            "The BeanNotes library is too large for a single backup file."
        case .tooManyArchiveEntries:
            "The BeanNotes library has too many files for a single backup file."
        case .invalidArchiveEntryPath(let path):
            "The backup contains an invalid file path: \(path)"
        }
    }
}

struct LibraryBackupManifest: Codable, Equatable, Sendable {
    var formatVersion: Int
    var appName: String
    var archiveExtension: String
    var createdAt: Date
    var folderCount: Int
    var noteCount: Int
    var pageCount: Int
    var attachmentCount: Int
    var folders: [FolderSnapshot]

    @MainActor
    init(folders: [NotebookFolder], createdAt: Date = Date()) {
        let folderSnapshots = folders
            .sorted { lhs, rhs in
                if lhs.name == rhs.name {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map(FolderSnapshot.init(folder:))

        self.formatVersion = 4
        self.appName = "BeanNotes"
        self.archiveExtension = "beannotes"
        self.createdAt = createdAt
        self.folderCount = folderSnapshots.count
        self.noteCount = folderSnapshots.reduce(0) { $0 + $1.notes.count }
        self.pageCount = folderSnapshots.reduce(0) { count, folder in
            count + folder.notes.reduce(0) { $0 + $1.pages.count }
        }
        self.attachmentCount = folderSnapshots.reduce(0) { count, folder in
            count + folder.notes.reduce(0) { noteCount, note in
                noteCount + note.pages.reduce(0) { $0 + $1.attachments.count }
            }
        }
        self.folders = folderSnapshots
    }

    struct FolderSnapshot: Codable, Equatable, Sendable {
        var id: UUID
        var name: String
        var colorHex: String
        var createdAt: Date
        var updatedAt: Date
        var archivedAt: Date?
        var notes: [NoteSnapshot]

        init(folder: NotebookFolder) {
            self.id = folder.id
            self.name = folder.name
            self.colorHex = folder.colorHex
            self.createdAt = folder.createdAt
            self.updatedAt = folder.updatedAt
            self.archivedAt = folder.archivedAt
            self.notes = folder.sortedNotes.map(NoteSnapshot.init(note:))
        }
    }

    struct NoteSnapshot: Codable, Equatable, Sendable {
        var id: UUID
        var title: String
        var searchableText: String
        var searchIndexUpdatedAt: Date?
        var createdAt: Date
        var updatedAt: Date
        var pages: [PageSnapshot]

        init(note: NoteDocument) {
            self.id = note.id
            self.title = note.title
            self.searchableText = note.searchableText
            self.searchIndexUpdatedAt = note.searchIndexUpdatedAt
            self.createdAt = note.createdAt
            self.updatedAt = note.updatedAt
            self.pages = note.sortedPages.map(PageSnapshot.init(page:))
        }
    }

    struct PageSnapshot: Codable, Equatable, Sendable {
        var id: UUID
        var pageOrder: Int
        var drawingFileName: String
        var thumbnailFileName: String?
        var searchableText: String
        var searchIndexUpdatedAt: Date?
        var backgroundStyleRaw: String
        var backgroundColorHex: String
        var width: Double
        var height: Double
        var createdAt: Date
        var updatedAt: Date
        var attachments: [AttachmentSnapshot]

        init(page: NotePage) {
            self.id = page.id
            self.pageOrder = page.pageOrder
            self.drawingFileName = page.drawingFileName
            self.thumbnailFileName = page.thumbnailFileName
            self.searchableText = page.searchableText
            self.searchIndexUpdatedAt = page.searchIndexUpdatedAt
            self.backgroundStyleRaw = page.backgroundStyleRaw
            self.backgroundColorHex = page.backgroundColorHex
            self.width = page.width
            self.height = page.height
            self.createdAt = page.createdAt
            self.updatedAt = page.updatedAt
            self.attachments = page.attachments
                .sorted { lhs, rhs in
                    if lhs.createdAt == rhs.createdAt {
                        return lhs.id.uuidString < rhs.id.uuidString
                    }
                    return lhs.createdAt < rhs.createdAt
                }
                .map(AttachmentSnapshot.init(attachment:))
        }
    }

    struct AttachmentSnapshot: Codable, Equatable, Sendable {
        var id: UUID
        var kindRaw: String
        var displayName: String
        var originalFileName: String
        var storedFileName: String
        var contentTypeIdentifier: String
        var fileExtension: String
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var isLocked: Bool
        var rendersBehindDrawing: Bool
        var vectorSourceStoredFileName: String?
        var vectorSourcePageIndex: Int?
        var documentVersionID: UUID?
        var documentVersionName: String?
        var documentVersionCreatedAt: Date?
        var documentVersionIsCurrent: Bool?
        var documentVersionIsLatest: Bool?
        var codeSnippetText: String?
        var codeSnippetLanguageRaw: String?
        var codeSnippetFontRaw: String?
        var codeSnippetFontSize: Double?
        var codeSnippetBackgroundRaw: String?
        var createdAt: Date
        var updatedAt: Date

        init(attachment: Attachment) {
            self.id = attachment.id
            self.kindRaw = attachment.kindRaw
            self.displayName = attachment.displayName
            self.originalFileName = attachment.originalFileName
            self.storedFileName = attachment.storedFileName
            self.contentTypeIdentifier = attachment.contentTypeIdentifier
            self.fileExtension = attachment.fileExtension
            self.x = attachment.x
            self.y = attachment.y
            self.width = attachment.width
            self.height = attachment.height
            self.isLocked = attachment.isLocked
            self.rendersBehindDrawing = attachment.rendersBehindDrawing
            self.vectorSourceStoredFileName = attachment.vectorSourceStoredFileName
            self.vectorSourcePageIndex = attachment.vectorSourcePageIndex
            self.documentVersionID = attachment.documentVersionID
            self.documentVersionName = attachment.documentVersionName
            self.documentVersionCreatedAt = attachment.documentVersionCreatedAt
            self.documentVersionIsCurrent = attachment.documentVersionIsCurrent
            self.documentVersionIsLatest = attachment.documentVersionIsLatest
            self.codeSnippetText = attachment.codeSnippetText
            self.codeSnippetLanguageRaw = attachment.codeSnippetLanguageRaw
            self.codeSnippetFontRaw = attachment.codeSnippetFontRaw
            self.codeSnippetFontSize = attachment.codeSnippetFontSize
            self.codeSnippetBackgroundRaw = attachment.codeSnippetBackgroundRaw
            self.createdAt = attachment.createdAt
            self.updatedAt = attachment.updatedAt
        }
    }
}

@MainActor
struct LibraryBackupService {
    var storage = LocalStorageService()

    func exportLibraryBackup(
        folders: [NotebookFolder],
        progress: LibraryBackupProgressHandler? = nil
    ) async throws -> LibraryBackupResult {
        try storage.prepareDirectories()
        progress?(0, "Preparing library metadata...")
        try Task.checkCancellation()

        let manifest = LibraryBackupManifest(folders: folders)
        let rootURL = storage.rootURL
        let preferredFileName = Self.backupFileName(createdAt: manifest.createdAt)
        let worker = Task.detached(priority: .utility) {
            try await LibraryBackupArchiveWorker(
                rootURL: rootURL,
                preferredFileName: preferredFileName
            )
            .createArchive(manifest: manifest, progress: progress)
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func backupFileName(createdAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "BeanNotes-Library-\(formatter.string(from: createdAt)).beannotes"
    }
}

private struct LibraryBackupFileEntry: Sendable {
    var sourceURL: URL
    var archivePath: String
}

private struct LibraryBackupArchiveWorker: Sendable {
    var rootURL: URL
    var preferredFileName: String
    var fileManager = FileManager.default

    func createArchive(
        manifest: LibraryBackupManifest,
        progress: LibraryBackupProgressHandler?
    ) async throws -> LibraryBackupResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let manifestData = try encoder.encode(manifest)
        try Task.checkCancellation()
        await progress?(0.08, "Collecting library files...")

        let fileEntries = try collectStorageFiles()
        try Task.checkCancellation()
        let totalEntries = max(fileEntries.count + 1, 1)
        let temporaryDirectoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("BeanNotesBackups", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let temporaryArchiveURL = temporaryDirectoryURL.appendingPathComponent(preferredFileName)

        try fileManager.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: temporaryDirectoryURL)
        }

        await progress?(0.12, "Writing backup archive...")
        let writer = try BeanNotesZipArchiveWriter(destinationURL: temporaryArchiveURL)
        var completedEntries = 0

        try await writer.addData(manifestData, archivePath: "manifest.json")
        completedEntries += 1
        await progress?(progressFraction(completedEntries, totalEntries), "Packed library metadata...")

        for entry in fileEntries {
            try Task.checkCancellation()
            try await writer.addFile(at: entry.sourceURL, archivePath: entry.archivePath)
            completedEntries += 1
            await progress?(progressFraction(completedEntries, totalEntries), "Packed \(entry.sourceURL.lastPathComponent)...")
        }

        try await writer.finish()
        try Task.checkCancellation()
        await progress?(0.96, "Saving backup...")
        try Task.checkCancellation()

        let storage = LocalStorageService(rootURL: rootURL)
        let storedFile = try storage.copyFile(
            from: temporaryArchiveURL,
            preferredName: preferredFileName,
            to: .exports
        )
        let backupURL = storage.url(forRelativePath: storedFile.relativePath)

        do {
            try Task.checkCancellation()
            let byteCount = Int64((try? backupURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

            await progress?(1, "Backup ready to share.")
            try Task.checkCancellation()

            return LibraryBackupResult(
                url: backupURL,
                fileCount: fileEntries.count,
                byteCount: byteCount
            )
        } catch {
            try? fileManager.removeItem(at: backupURL)
            throw error
        }
    }

    private func progressFraction(_ completedEntries: Int, _ totalEntries: Int) -> Double {
        0.12 + (Double(completedEntries) / Double(totalEntries)) * 0.82
    }

    private func collectStorageFiles() throws -> [LibraryBackupFileEntry] {
        var entries: [LibraryBackupFileEntry] = []

        for directory in StorageDirectory.allCases {
            try Task.checkCancellation()
            let directoryURL = rootURL.appendingPathComponent(directory.rawValue, isDirectory: true)
            guard fileManager.fileExists(atPath: directoryURL.path),
                  let enumerator = fileManager.enumerator(
                    at: directoryURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                  ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                try Task.checkCancellation()
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                guard shouldInclude(fileURL, from: directory) else { continue }

                let relativePath = try LocalStorageService(rootURL: rootURL).relativePath(for: fileURL)
                entries.append(
                    LibraryBackupFileEntry(
                        sourceURL: fileURL,
                        archivePath: "storage/\(relativePath)"
                    )
                )
            }
        }

        return entries.sorted { $0.archivePath < $1.archivePath }
    }

    private func shouldInclude(_ fileURL: URL, from directory: StorageDirectory) -> Bool {
        guard directory == .exports else { return true }
        return fileURL.pathExtension.lowercased() != "beannotes"
    }
}

private struct BeanNotesZipCentralDirectoryEntry {
    var archivePath: String
    var crc32: UInt32
    var compressedSize: UInt32
    var uncompressedSize: UInt32
    var localHeaderOffset: UInt32
}

private final class BeanNotesZipArchiveWriter {
    private let destinationURL: URL
    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var entries: [BeanNotesZipCentralDirectoryEntry] = []

    init(destinationURL: URL) throws {
        self.destinationURL = destinationURL
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: destinationURL)
    }

    deinit {
        try? handle.close()
    }

    func addData(_ data: Data, archivePath: String) async throws {
        try Task.checkCancellation()
        try validateArchivePath(archivePath)
        let crc = BeanNotesCRC32.checksum(data)
        try writeEntryHeader(
            archivePath: archivePath,
            crc32: crc,
            compressedSize: UInt64(data.count),
            uncompressedSize: UInt64(data.count)
        )
        try write(data)
    }

    func addFile(at sourceURL: URL, archivePath: String) async throws {
        try Task.checkCancellation()
        try validateArchivePath(archivePath)

        let checksum = try await BeanNotesCRC32.checksum(fileURL: sourceURL)
        try writeEntryHeader(
            archivePath: archivePath,
            crc32: checksum.crc32,
            compressedSize: checksum.byteCount,
            uncompressedSize: checksum.byteCount
        )

        let readHandle = try FileHandle(forReadingFrom: sourceURL)
        defer {
            try? readHandle.close()
        }

        while true {
            try Task.checkCancellation()
            guard let chunk = try readHandle.read(upToCount: 1_048_576),
                  !chunk.isEmpty else {
                break
            }
            try write(chunk)
        }
    }

    func finish() async throws {
        try Task.checkCancellation()
        guard entries.count <= Int(UInt16.max) else {
            throw LibraryBackupError.tooManyArchiveEntries
        }

        let centralDirectoryStart = try UInt32.checked(offset)

        for entry in entries {
            try writeCentralDirectoryEntry(entry)
        }

        let centralDirectorySize = try UInt32.checked(offset - UInt64(centralDirectoryStart))
        try writeEndOfCentralDirectory(
            entryCount: UInt16(entries.count),
            centralDirectorySize: centralDirectorySize,
            centralDirectoryOffset: centralDirectoryStart
        )
        try handle.close()
    }

    private func writeEntryHeader(
        archivePath: String,
        crc32: UInt32,
        compressedSize: UInt64,
        uncompressedSize: UInt64
    ) throws {
        let localHeaderOffset = try UInt32.checked(offset)
        let compressedSize32 = try UInt32.checked(compressedSize)
        let uncompressedSize32 = try UInt32.checked(uncompressedSize)
        let nameData = try archivePathData(archivePath)

        try writeUInt32(0x04034B50)
        try writeUInt16(20)
        try writeUInt16(0x0800)
        try writeUInt16(0)
        try writeUInt16(0)
        try writeUInt16(33)
        try writeUInt32(crc32)
        try writeUInt32(compressedSize32)
        try writeUInt32(uncompressedSize32)
        try writeUInt16(UInt16(nameData.count))
        try writeUInt16(0)
        try write(nameData)

        entries.append(
            BeanNotesZipCentralDirectoryEntry(
                archivePath: archivePath,
                crc32: crc32,
                compressedSize: compressedSize32,
                uncompressedSize: uncompressedSize32,
                localHeaderOffset: localHeaderOffset
            )
        )
    }

    private func writeCentralDirectoryEntry(_ entry: BeanNotesZipCentralDirectoryEntry) throws {
        let nameData = try archivePathData(entry.archivePath)

        try writeUInt32(0x02014B50)
        try writeUInt16(20)
        try writeUInt16(20)
        try writeUInt16(0x0800)
        try writeUInt16(0)
        try writeUInt16(0)
        try writeUInt16(33)
        try writeUInt32(entry.crc32)
        try writeUInt32(entry.compressedSize)
        try writeUInt32(entry.uncompressedSize)
        try writeUInt16(UInt16(nameData.count))
        try writeUInt16(0)
        try writeUInt16(0)
        try writeUInt16(0)
        try writeUInt16(0)
        try writeUInt32(0)
        try writeUInt32(entry.localHeaderOffset)
        try write(nameData)
    }

    private func writeEndOfCentralDirectory(
        entryCount: UInt16,
        centralDirectorySize: UInt32,
        centralDirectoryOffset: UInt32
    ) throws {
        try writeUInt32(0x06054B50)
        try writeUInt16(0)
        try writeUInt16(0)
        try writeUInt16(entryCount)
        try writeUInt16(entryCount)
        try writeUInt32(centralDirectorySize)
        try writeUInt32(centralDirectoryOffset)
        try writeUInt16(0)
    }

    private func validateArchivePath(_ archivePath: String) throws {
        guard !archivePath.isEmpty,
              !archivePath.hasPrefix("/"),
              !archivePath.contains("../"),
              !archivePath.contains("\\") else {
            throw LibraryBackupError.invalidArchiveEntryPath(archivePath)
        }
    }

    private func archivePathData(_ archivePath: String) throws -> Data {
        let data = Data(archivePath.utf8)
        guard data.count <= Int(UInt16.max) else {
            throw LibraryBackupError.invalidArchiveEntryPath(archivePath)
        }
        return data
    }

    private func writeUInt16(_ value: UInt16) throws {
        var littleEndian = value.littleEndian
        try withUnsafeBytes(of: &littleEndian) { buffer in
            try write(Data(buffer))
        }
    }

    private func writeUInt32(_ value: UInt32) throws {
        var littleEndian = value.littleEndian
        try withUnsafeBytes(of: &littleEndian) { buffer in
            try write(Data(buffer))
        }
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }
}

private enum BeanNotesCRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ 0xEDB88320
            } else {
                crc >>= 1
            }
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        update(&crc, with: data)
        return crc ^ 0xFFFF_FFFF
    }

    static func checksum(fileURL: URL) async throws -> (crc32: UInt32, byteCount: UInt64) {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }

        var crc: UInt32 = 0xFFFF_FFFF
        var byteCount: UInt64 = 0

        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1_048_576),
                  !chunk.isEmpty else {
                break
            }

            byteCount += UInt64(chunk.count)
            update(&crc, with: chunk)
        }

        return (crc ^ 0xFFFF_FFFF, byteCount)
    }

    private static func update(_ crc: inout UInt32, with data: Data) {
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for byte in bytes {
                let index = Int((crc ^ UInt32(byte)) & 0xFF)
                crc = (crc >> 8) ^ table[index]
            }
        }
    }
}

private extension UInt32 {
    static func checked(_ value: UInt64) throws -> UInt32 {
        guard value <= UInt64(UInt32.max) else {
            throw LibraryBackupError.archiveTooLarge
        }
        return UInt32(value)
    }
}
