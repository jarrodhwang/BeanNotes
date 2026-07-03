//
//  LocalStorageService.swift
//  BeanNote
//

import Foundation
import UniformTypeIdentifiers

struct StoredFile: Equatable {
    var relativePath: String
    var fileName: String
    var contentTypeIdentifier: String
}

enum StorageDirectory: String, CaseIterable {
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
            "BeanNote could not locate the app documents directory."
        case .fileMissing(let url):
            "The file could not be found: \(url.lastPathComponent)"
        case .invalidRelativePath(let path):
            "The file path is not inside BeanNote storage: \(path)"
        }
    }
}

struct LocalStorageService {
    static let appGroupIdentifier = "group.com.snowfox.BeanNote"

    let fileManager: FileManager
    let rootURL: URL

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager

        if let rootURL {
            self.rootURL = rootURL
        } else {
            let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            self.rootURL = (documentsURL ?? URL(fileURLWithPath: NSTemporaryDirectory()))
                .appendingPathComponent("BeanNote", isDirectory: true)
        }
    }

    func prepareDirectories() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        for directory in StorageDirectory.allCases {
            _ = try directoryURL(for: directory)
        }
    }

    func directoryURL(for directory: StorageDirectory) throws -> URL {
        let url = rootURL.appendingPathComponent(directory.rawValue, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func url(forRelativePath relativePath: String) -> URL {
        rootURL.appendingPathComponent(relativePath)
    }

    func relativePath(for fileURL: URL) throws -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path

        guard filePath.hasPrefix(rootPath) else {
            throw LocalStorageError.invalidRelativePath(filePath)
        }

        let start = filePath.index(filePath.startIndex, offsetBy: rootPath.count)
        return String(filePath[start...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func copyFile(
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

    func saveData(
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

    func removeFile(relativePath: String) throws {
        let fileURL = url(forRelativePath: relativePath)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    func uniqueFileName(_ preferredName: String) -> String {
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
}

extension String {
    var sanitizedFileName: String {
        let illegalCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)
        let components = components(separatedBy: illegalCharacters)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let sanitized = components.joined(separator: "-")
        return sanitized.isEmpty ? "BeanNote-File" : sanitized
    }
}
