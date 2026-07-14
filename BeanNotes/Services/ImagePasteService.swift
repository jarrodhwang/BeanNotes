//
//  ImagePasteService.swift
//  BeanNotes
//

import Foundation
import UniformTypeIdentifiers

struct PastedImage: Sendable {
    var data: Data
    var originalFileName: String
}

enum ImagePasteError: LocalizedError {
    case noImageProvider
    case imageDataUnavailable

    var errorDescription: String? {
        switch self {
        case .noImageProvider:
            "The clipboard does not contain an image."
        case .imageDataUnavailable:
            "BeanNotes could not read the image from the clipboard."
        }
    }
}

@MainActor
struct ImagePasteService {
    static let supportedContentTypes: [UTType] = [.image]

    func loadFirstImage(from itemProviders: [NSItemProvider]) async throws -> PastedImage {
        guard let provider = itemProviders.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }) else {
            throw ImagePasteError.noImageProvider
        }

        let typeIdentifier = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) ?? UTType.image.identifier
        let originalFileName = provider.suggestedName.flatMap { name in
            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name
        } ?? "Pasted Image"

        let data: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: ImagePasteError.imageDataUnavailable)
                }
            }
        }

        return PastedImage(data: data, originalFileName: originalFileName)
    }
}
