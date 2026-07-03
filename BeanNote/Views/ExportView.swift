//
//  ExportView.swift
//  BeanNote
//

import SwiftUI

struct ExportView: View {
    @Environment(\.dismiss) private var dismiss

    var note: NoteDocument
    var page: NotePage
    var service = ImportExportService()

    @State private var exportURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Page") {
                    ForEach(ExportFormat.allCases) { format in
                        Button {
                            export(format)
                        } label: {
                            Label(format.label, systemImage: icon(for: format))
                        }
                    }
                }

                if let exportURL {
                    Section {
                        ShareLink(item: exportURL) {
                            Label("Share Export", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                if !page.attachments.isEmpty {
                    Section("Originals") {
                        ForEach(page.attachments.sorted { $0.createdAt < $1.createdAt }) { attachment in
                            if let url = try? service.originalFileURL(for: attachment) {
                                ShareLink(item: url) {
                                    Label(attachment.displayName, systemImage: "doc")
                                }
                            }
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func export(_ format: ExportFormat) {
        do {
            exportURL = try service.exportPage(page, format: format)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
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
}
