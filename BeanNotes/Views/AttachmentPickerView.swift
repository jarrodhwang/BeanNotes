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

                    Button {
                        pasteImage()
                    } label: {
                        Label("Paste Image", systemImage: "doc.on.clipboard")
                    }
                    .disabled(!UIPasteboard.general.hasImages)
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
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: ImportExportService.supportedContentTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    importFiles(urls)
                    dismiss()
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
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

    private func pasteImage() {
        guard let image = UIPasteboard.general.image else { return }

        Task {
            do {
                guard let data = await Task.detached(priority: .userInitiated, operation: {
                    image.pngData()
                }).value else {
                    throw ImportExportError.unsupportedImageData
                }

                await MainActor.run {
                    importImageData(data, "Pasted Image.png")
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
