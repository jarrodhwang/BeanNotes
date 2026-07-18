//
//  ImagePasteService.swift
//  BeanNotes
//

import Foundation
import UIKit
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

enum NoteCaptureError: LocalizedError {
    case renderFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .renderFailed:
            "BeanNotes could not render the selected note area."
        case .encodingFailed:
            "BeanNotes could not create a high-quality clipboard image."
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

@MainActor
enum NoteCapturePasteboard {
    static let imageChangedNotification = Notification.Name("BeanNotesCapturePasteboardImageChanged")

    static var containsImage: Bool {
        UIPasteboard.general.hasImages
    }

    static func copyPNGData(_ data: Data) {
        guard !data.isEmpty else { return }
        UIPasteboard.general.setData(data, forPasteboardType: UTType.png.identifier)
        NotificationCenter.default.post(name: imageChangedNotification, object: nil)
    }
}
