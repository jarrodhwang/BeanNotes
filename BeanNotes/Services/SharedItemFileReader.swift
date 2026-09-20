import Foundation
import ImageIO
import UniformTypeIdentifiers

enum SharedItemFileReader {
    /// The provider's temporary URL is only valid inside its callback. Copy it
    /// there, and try data when the provider cannot vend a file (e.g. screenshots).
    @MainActor static func writeRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String,
        into directory: URL,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let suggestedName = provider.suggestedName
        let loadData: @MainActor @Sendable () -> Void = {
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                completion(Result {
                    guard let data else { throw error ?? CocoaError(.fileReadUnknown) }
                    let imageType = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) }
                    let actualType = imageType.map { $0 as String } ?? typeIdentifier
                    let name = SharedDocumentName.fileName(sourceURL: nil, suggestedName: suggestedName,
                                                          typeIdentifier: actualType)
                    try data.write(to: directory.appendingPathComponent(name), options: .atomic)
                    return name
                })
            }
        }
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { sourceURL, _ in
            if let sourceURL {
                completion(Result {
                    try copyFile(sourceURL, suggestedName: suggestedName,
                                 typeIdentifier: typeIdentifier, into: directory)
                })
            } else {
                Task { @MainActor in loadData() }
            }
        }
    }

    nonisolated static func copyFile(_ source: URL, suggestedName: String? = nil,
                         typeIdentifier: String, into directory: URL) throws -> String {
        guard source.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let imageType = source.pathExtension.isEmpty
            ? CGImageSourceCreateWithURL(source as CFURL, nil).flatMap { CGImageSourceGetType($0) }
            : nil
        let actualType = imageType.map { $0 as String } ?? typeIdentifier
        let name = SharedDocumentName.fileName(sourceURL: source, suggestedName: suggestedName, typeIdentifier: actualType)
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
        return name
    }
}
