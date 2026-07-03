//
//  AttachmentViews.swift
//  BeanNote
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
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: attachment.width, height: attachment.height)
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
            .position(x: attachment.x + attachment.width / 2, y: attachment.y + attachment.height / 2)
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

    var body: some View {
        List(attachments.sorted { $0.createdAt < $1.createdAt }) { attachment in
            HStack(spacing: 12) {
                Image(systemName: icon(for: attachment.kind))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(attachment.displayName)
                        .lineLimit(1)
                    Text(attachment.kind.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            }
            .padding(.vertical, 4)
        }
        .listStyle(.plain)
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

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.document = PDFDocument(url: url)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        if pdfView.document?.documentURL != url {
            pdfView.document = PDFDocument(url: url)
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
