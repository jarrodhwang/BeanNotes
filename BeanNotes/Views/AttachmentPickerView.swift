//
//  AttachmentPickerView.swift
//  BeanNotes
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct AttachmentPickerView: View {
    @Environment(\.dismiss) private var dismiss

    var importFiles: ([URL]) -> Void
    var importImageData: (Data, String) -> Void

    @State private var photoItem: PhotosPickerItem?
    @State private var isShowingFileImporter = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Photos", systemImage: "photo.on.rectangle")
                    }

                    Button {
                        isShowingFileImporter = true
                    } label: {
                        Label("Files", systemImage: "folder")
                    }

                    PasteButton(supportedContentTypes: ImagePasteService.supportedContentTypes) { itemProviders in
                        pasteImage(from: itemProviders)
                    }
                    .accessibilityLabel("Paste Image")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Attachment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onChange(of: photoItem) { _, newValue in
                guard let newValue else { return }
                Task {
                    await loadPhotoItem(newValue)
                }
            }
            .sheet(isPresented: $isShowingFileImporter) {
                DocumentImportPicker(
                    allowedContentTypes: ImportExportService.supportedContentTypes,
                    allowsMultipleSelection: true,
                    onPick: { urls in
                        importFiles(urls)
                        dismiss()
                    },
                    onCancel: {}
                )
            }
        }
    }

    private func loadPhotoItem(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ImportExportError.unsupportedImageData
            }

            await MainActor.run {
                importImageData(data, "Photo")
                dismiss()
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func pasteImage(from itemProviders: [NSItemProvider]) {
        errorMessage = nil
        Task { @MainActor in
            do {
                let pastedImage = try await ImagePasteService().loadFirstImage(from: itemProviders)
                importImageData(pastedImage.data, pastedImage.originalFileName)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
