//
//  DocumentImportPicker.swift
//  BeanNotes
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Presents the system document picker as a copied import, so imports remain
/// readable after the picker closes and do not depend on a file-provider URL.
struct DocumentImportPicker: View {
    let allowedContentTypes: [UTType]
    let allowsMultipleSelection: Bool
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var didComplete = false

    var body: some View {
        VStack(spacing: 0) {
            // iPadOS 17 can omit UIKit's Cancel button when the document picker is
            // hosted in a SwiftUI full-screen cover. Keep an independent exit visible.
            HStack {
                Button("Cancel") { finish(with: nil) }
                    .accessibilityIdentifier("documentImport.cancel")
                Spacer()
            }
            .padding()
            .background(.bar)
            Divider()
            NativeDocumentImportPicker(
                allowedContentTypes: allowedContentTypes,
                allowsMultipleSelection: allowsMultipleSelection,
                onPick: { finish(with: $0) },
                onCancel: { finish(with: nil) }
            )
        }
    }

    private func finish(with urls: [URL]?) {
        guard !didComplete else { return }
        didComplete = true
        if let urls { onPick(urls) } else { onCancel() }
        dismiss()
    }
}

private struct NativeDocumentImportPicker: UIViewControllerRepresentable {
    let allowedContentTypes: [UTType]
    let allowsMultipleSelection: Bool
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

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
        private let parent: NativeDocumentImportPicker

        init(parent: NativeDocumentImportPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
