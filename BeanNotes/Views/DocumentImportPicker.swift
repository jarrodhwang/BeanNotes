//
//  DocumentImportPicker.swift
//  BeanNotes
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Presents the system document picker as a copied import, so imports remain
/// readable after the picker closes and do not depend on a file-provider URL.
struct DocumentImportPicker: UIViewControllerRepresentable {
    let allowedContentTypes: [UTType]
    let allowsMultipleSelection: Bool
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: allowedContentTypes,
            asCopy: true
        )
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true

        // Do not restore a stale or unavailable third-party provider location after
        // Xcode reinstalls the app. The local Documents directory is always a valid
        // starting point and users can still navigate to every Files provider.
        picker.directoryURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: DocumentImportPicker

        init(parent: DocumentImportPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls)
            parent.dismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
            parent.dismiss()
        }
    }
}
