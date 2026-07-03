//
//  ExportView.swift
//  BeanNote
//

import SwiftUI
import UIKit

struct ExportView: View {
    @Environment(\.dismiss) private var dismiss

    var note: NoteDocument
    var page: NotePage
    var service = ImportExportService()

    @State private var sharePayload: ExportSharePayload?
    @State private var isExporting = false
    @State private var exportProgress: Double?
    @State private var exportProgressMessage = "Preparing export..."
    @State private var errorMessage: String?

    private var pageOriginalAttachments: [Attachment] {
        page.attachments
            .filter { !$0.isLocked }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private var noteOriginalAttachments: [Attachment] {
        note.sortedPages
            .flatMap(\.attachments)
            .filter { !$0.isLocked }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Current Page") {
                    ForEach(ExportFormat.allCases) { format in
                        Button {
                            exportCurrentPage(format)
                        } label: {
                            Label(format.label, systemImage: icon(for: format))
                        }
                    }
                }

                Section("Whole Note") {
                    ForEach(ExportFormat.allCases) { format in
                        Button {
                            exportWholeNote(format)
                        } label: {
                            Label(noteExportLabel(for: format), systemImage: icon(for: format))
                        }
                    }
                }

                if !pageOriginalAttachments.isEmpty {
                    Section("Page Originals") {
                        ForEach(pageOriginalAttachments) { attachment in
                            Button {
                                shareOriginals([attachment])
                            } label: {
                                Label(originalLabel(for: attachment), systemImage: icon(for: attachment))
                            }
                        }
                    }
                }

                if noteOriginalAttachments.count > pageOriginalAttachments.count {
                    Section("Note Originals") {
                        Button {
                            shareOriginals(noteOriginalAttachments)
                        } label: {
                            Label("All Originals", systemImage: "doc.on.doc")
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(isExporting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(item: $sharePayload) { payload in
                ActivityView(activityItems: payload.urls)
            }
            .overlay {
                if isExporting {
                    BeanNoteProgressOverlay(
                        title: "Exporting",
                        message: exportProgressMessage,
                        progress: exportProgress
                    )
                }
            }
        }
    }

    private func exportCurrentPage(_ format: ExportFormat) {
        exportItems {
            [try await service.exportPageForSharing(page, format: format, progress: $0)]
        }
    }

    private func exportWholeNote(_ format: ExportFormat) {
        exportItems {
            try await service.exportNoteForSharing(note, format: format, progress: $0)
        }
    }

    private func shareOriginals(_ attachments: [Attachment]) {
        exportItems {
            $0?(nil, "Preparing original files...")
            await Task.yield()
            return try attachments.map { try service.originalFileURL(for: $0) }
        }
    }

    private func exportItems(_ makeURLs: @escaping (ImportExportProgressHandler?) async throws -> [URL]) {
        guard !isExporting else { return }
        isExporting = true
        exportProgress = 0
        exportProgressMessage = "Preparing export..."

        Task { @MainActor in
            defer {
                isExporting = false
                exportProgress = nil
                exportProgressMessage = "Preparing export..."
            }

            do {
                await Task.yield()
                let urls = try await makeURLs { fraction, message in
                    exportProgress = fraction
                    exportProgressMessage = message
                }
                guard !urls.isEmpty else { throw ImportExportError.exportFailed }
                exportProgress = 1
                exportProgressMessage = "Opening share sheet..."
                await Task.yield()
                sharePayload = ExportSharePayload(urls: urls)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func noteExportLabel(for format: ExportFormat) -> String {
        switch format {
        case .pdf:
            "PDF"
        case .png:
            "PNG Pages"
        case .jpeg:
            "JPEG Pages"
        }
    }

    private func originalLabel(for attachment: Attachment) -> String {
        let ext = attachment.fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ext.isEmpty else { return attachment.displayName }
        return "\(attachment.displayName).\(ext)"
    }

    private func icon(for format: ExportFormat) -> String {
        switch format {
        case .pdf:
            "doc.richtext"
        case .png:
            "photo"
        case .jpeg:
            "photo.fill"
        }
    }

    private func icon(for attachment: Attachment) -> String {
        switch attachment.kind {
        case .pdf:
            "doc.richtext"
        case .image:
            "photo"
        case .docx:
            "doc.text"
        case .csv:
            "tablecells"
        case .presentation:
            "rectangle.on.rectangle"
        case .other:
            "doc"
        }
    }
}

private struct ExportSharePayload: Identifiable {
    let id = UUID()
    var urls: [URL]
}

private struct ActivityView: UIViewControllerRepresentable {
    var activityItems: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
