import Foundation
import UniformTypeIdentifiers

/// Shared by the app and its extension so either import entry point remembers
/// the last successful destination. Missing/archived folders are resolved by callers.
enum DocumentImportPreferences {
    nonisolated static let appGroupIdentifier = "group.com.snowfox.BeanNotes"
    nonisolated static let lastFolderKey = "lastDocumentImportFolderID"

    nonisolated static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: appGroupIdentifier) }

    nonisolated static func lastFolderID(in defaults: UserDefaults? = sharedDefaults) -> UUID? {
        defaults?.string(forKey: lastFolderKey).flatMap(UUID.init(uuidString:))
    }

    nonisolated static func remember(folderID: UUID?, in defaults: UserDefaults? = sharedDefaults) {
        if let folderID {
            defaults?.set(folderID.uuidString, forKey: lastFolderKey)
        } else {
            defaults?.removeObject(forKey: lastFolderKey)
        }
    }

    nonisolated static func initialFolderID(available: [UUID], defaults: UserDefaults? = sharedDefaults) -> UUID? {
        if let last = lastFolderID(in: defaults), available.contains(last) { return last }
        return available.first
    }
}

enum SharedDocumentName {
    nonisolated static func title(for fileName: String?) -> String? {
        guard let fileName, !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let name = URL(fileURLWithPath: fileName).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        // A provider's suggestedName can be a title containing dots, not a filename.
        let url = URL(fileURLWithPath: name)
        let hasKnownExtension = UTType(filenameExtension: url.pathExtension)?.isDeclared == true
        return hasKnownExtension ? url.deletingPathExtension().lastPathComponent : name
    }

    nonisolated static func fileName(sourceURL: URL?, suggestedName: String?, typeIdentifier: String) -> String {
        let suggested = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = sourceURL?.lastPathComponent ?? ""
        let genericNames = ["shared notes", "shared import", "shared file"]
        let preferred = suggested.flatMap {
            $0.isEmpty || (!source.isEmpty && genericNames.contains($0.lowercased())) ? nil : $0
        } ?? (source.isEmpty ? "Shared File" : source)
        let clean = preferred.components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:").union(.controlCharacters))
            .filter { !$0.isEmpty }.joined(separator: "-")
        var name = clean.isEmpty || clean == "." || clean == ".." ? "Shared File" : clean
        let type = UTType(typeIdentifier)
        let existingExtension = URL(fileURLWithPath: name).pathExtension
        let sourceExtension = sourceURL?.pathExtension
        let ext: String?
        if let representationExtension = type?.preferredFilenameExtension {
            // Providers sometimes vend a .tmp file. The requested representation
            // is authoritative, while equivalent filename aliases can be retained.
            if let sourceExtension, UTType(filenameExtension: sourceExtension) == type {
                ext = sourceExtension
            } else if UTType(filenameExtension: existingExtension) == type {
                ext = existingExtension
            } else {
                ext = representationExtension
            }
        } else {
            ext = UTType(filenameExtension: existingExtension)?.isDeclared == true
                ? existingExtension : sourceExtension
        }
        if let ext, let sourceType = UTType(filenameExtension: ext),
           let nameType = UTType(filenameExtension: existingExtension), nameType.isDeclared,
           sourceType != nameType {
            return URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent + "." + ext
        }
        if let ext, !ext.isEmpty,
           existingExtension.isEmpty || UTType(filenameExtension: existingExtension)?.isDeclared != true {
            name += ".\(ext)"
        }
        return name
    }
}
