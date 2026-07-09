//
//  AttachmentViews.swift
//  BeanNotes
//

import PDFKit
import QuickLook
import SwiftUI

struct ImageAttachmentView: View {
    @Bindable var attachment: Attachment
    var image: UIImage

    @State private var dragStart: CGRect?
    @State private var resizeStart: CGRect?

    var body: some View {
        let attachmentFrame = attachment.frame

        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: attachmentFrame.width, height: attachmentFrame.height)
            .background {
                if !attachment.isLocked {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: attachment.isLocked ? 0 : 6))
            .overlay(alignment: .bottomTrailing) {
                if !attachment.isLocked {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.62), in: Circle())
                        .padding(4)
                        .gesture(resizeGesture)
                        .accessibilityLabel("Resize image")
                }
            }
            .overlay {
                if !attachment.isLocked {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.blue.opacity(0.65), lineWidth: 1.5)
                }
            }
            .position(x: attachmentFrame.midX, y: attachmentFrame.midY)
            .gesture(moveGesture)
            .allowsHitTesting(!attachment.isLocked)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(attachment.displayName)
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil {
                    dragStart = attachment.frame
                }

                guard let dragStart else { return }
                attachment.x = max(0, dragStart.origin.x + value.translation.width)
                attachment.y = max(0, dragStart.origin.y + value.translation.height)
            }
            .onEnded { _ in
                attachment.touch()
                dragStart = nil
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if resizeStart == nil {
                    resizeStart = attachment.frame
                }

                guard let resizeStart else { return }
                attachment.width = max(120, resizeStart.width + value.translation.width)
                attachment.height = max(90, resizeStart.height + value.translation.height)
            }
            .onEnded { _ in
                attachment.touch()
                resizeStart = nil
            }
    }
}

struct AttachmentListView: View {
    var attachments: [Attachment]
    var openPreview: (Attachment) -> Void
    var originalURL: (Attachment) -> URL?
    var renameAttachment: (Attachment, String) -> Void
    var deleteAttachment: (Attachment) -> Void
    var toggleLock: (Attachment) -> Void
    var setDrawingLayer: (Attachment, Bool) -> Void

    @State private var renamingAttachment: Attachment?
    @State private var renameDraft = ""
    @State private var deletingAttachment: Attachment?

    var body: some View {
        List(attachments.sorted { $0.createdAt < $1.createdAt }) { attachment in
            row(for: attachment)
        }
        .listStyle(.plain)
        .alert("Rename Attachment", isPresented: Binding(
            get: { renamingAttachment != nil },
            set: { if !$0 { renamingAttachment = nil } }
        )) {
            TextField("Name", text: $renameDraft)
            Button("Save") {
                guard let attachment = renamingAttachment else { return }
                renameAttachment(attachment, renameDraft)
                renamingAttachment = nil
            }
            Button("Cancel", role: .cancel) {
                renamingAttachment = nil
            }
        }
        .alert("Delete Attachment?", isPresented: Binding(
            get: { deletingAttachment != nil },
            set: { if !$0 { deletingAttachment = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let attachment = deletingAttachment else { return }
                deletingAttachment = nil
                deleteAttachment(attachment)
            }
            Button("Cancel", role: .cancel) {
                deletingAttachment = nil
            }
        } message: {
            Text("This removes the attachment and its local file if no other note is using it.")
        }
    }

    private func row(for attachment: Attachment) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: attachment.kind))
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.displayName)
                    .lineLimit(1)
                Text(metadata(for: attachment))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let url = originalURL(attachment) {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Share original")
            }

            Button {
                openPreview(attachment)
            } label: {
                Image(systemName: "eye")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Preview")

            Menu {
                Button {
                    renameDraft = attachment.displayName
                    renamingAttachment = attachment
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Button {
                    toggleLock(attachment)
                } label: {
                    Label(attachment.isLocked ? "Unlock" : "Lock", systemImage: attachment.isLocked ? "lock.open" : "lock")
                }

                if attachment.kind == .image {
                    if attachment.rendersBehindDrawing {
                        Button {
                            setDrawingLayer(attachment, false)
                        } label: {
                            Label("Bring Above Drawing", systemImage: "arrow.up.to.line")
                        }
                    } else {
                        Button {
                            setDrawingLayer(attachment, true)
                        } label: {
                            Label("Send Behind Drawing", systemImage: "arrow.down.to.line")
                        }
                    }
                }

                Button(role: .destructive) {
                    deletingAttachment = attachment
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Attachment actions")
        }
        .padding(.vertical, 4)
    }

    private func metadata(for attachment: Attachment) -> String {
        var parts = [attachment.kind.displayName]

        parts.append(attachment.isLocked ? "Locked" : "Unlocked")

        if attachment.kind == .image {
            parts.append(attachment.rendersBehindDrawing ? "Behind drawing" : "Above drawing")
        }

        return parts.joined(separator: " · ")
    }

    private func icon(for kind: AttachmentKind) -> String {
        switch kind {
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

struct DocumentPreviewSheet: View {
    var attachment: Attachment
    var fileURL: URL

    var body: some View {
        NavigationStack {
            Group {
                if attachment.kind == .pdf {
                    PDFPreviewView(url: fileURL)
                } else {
                    QuickLookPreview(url: fileURL)
                }
            }
            .navigationTitle(attachment.displayName)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct PDFPreviewView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        context.coordinator.load(url: url, into: pdfView)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.load(url: url, into: pdfView)
        }
    }

    static func dismantleUIView(_ pdfView: PDFView, coordinator: Coordinator) {
        coordinator.cancelLoad()
        pdfView.document = nil
    }

    final class Coordinator {
        var url: URL?
        private var loadTask: Task<Void, Never>?

        deinit {
            cancelLoad()
        }

        func load(url: URL, into pdfView: PDFView) {
            self.url = url
            pdfView.document = nil
            loadTask?.cancel()

            loadTask = Task { [weak self, weak pdfView] in
                let document = await Task.detached(priority: .userInitiated) {
                    PDFDocument(url: url)
                }.value

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.url == url, let pdfView else { return }
                    pdfView.document = document
                }
            }
        }

        func cancelLoad() {
            loadTask?.cancel()
            loadTask = nil
            url = nil
        }
    }
}

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
