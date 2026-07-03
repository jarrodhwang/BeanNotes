//
//  NoteEditorView.swift
//  BeanNote
//

import SwiftData
import SwiftUI

struct NoteEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @Bindable var note: NoteDocument

    @StateObject private var toolState = DrawingToolState()
    @AppStorage("penPaletteMode") private var penPaletteModeRaw = PenPaletteMode.custom.rawValue
    @AppStorage("pencilDoubleTapAction") private var doubleTapRaw = PencilDoubleTapAction.switchToEraser.rawValue

    @State private var selectedPageID: UUID?
    @State private var isShowingAttachmentPicker = false
    @State private var isShowingExport = false
    @State private var isShowingAttachments = false
    @State private var isShowingBackgroundPicker = false
    @State private var previewAttachment: Attachment?
    @State private var saveNowSignal = 0
    @State private var errorMessage: String?

    private let storage = LocalStorageService()
    private let importExportService = ImportExportService()

    private var selectedPage: NotePage? {
        if let selectedPageID,
           let page = note.pages.first(where: { $0.id == selectedPageID }) {
            return page
        }

        return note.sortedPages.first
    }

    private var doubleTapAction: PencilDoubleTapAction {
        PencilDoubleTapAction(rawValue: doubleTapRaw) ?? .switchToEraser
    }

    private var penPaletteMode: PenPaletteMode {
        PenPaletteMode(rawValue: penPaletteModeRaw) ?? .custom
    }

    var body: some View {
        Group {
            if let page = selectedPage {
                editor(page: page)
            } else {
                ContentUnavailableView("No pages", systemImage: "doc")
            }
        }
        .onAppear {
            ensurePage()
        }
        .onDisappear {
            saveNow()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            saveNow()
        }
        .sheet(isPresented: $isShowingAttachmentPicker) {
            AttachmentPickerView { urls in
                Task {
                    await importFiles(urls)
                }
            } importImage: { image in
                importImage(image, named: "Photo")
            }
        }
        .sheet(isPresented: $isShowingExport) {
            if let page = selectedPage {
                ExportView(note: note, page: page)
            }
        }
        .sheet(item: $previewAttachment) { attachment in
            if let url = try? importExportService.originalFileURL(for: attachment) {
                DocumentPreviewSheet(attachment: attachment, fileURL: url)
            } else {
                ContentUnavailableView("Missing file", systemImage: "exclamationmark.triangle")
            }
        }
        .alert("BeanNote", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func editor(page: NotePage) -> some View {
        ZStack(alignment: .top) {
            ZStack(alignment: .trailing) {
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        NoteBackgroundSurface(background: page.background)

                        DrawingCanvasView(
                            page: page,
                            toolState: toolState,
                            paletteMode: penPaletteMode,
                            doubleTapAction: doubleTapAction,
                            saveNowSignal: saveNowSignal
                        )

                        ForEach(page.movableImageAttachments) { attachment in
                            if let image = image(for: attachment) {
                                ImageAttachmentView(attachment: attachment, image: image)
                            }
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                }
                .ignoresSafeArea(.container, edges: .bottom)

                if isShowingAttachments {
                    AttachmentListView(
                        attachments: page.attachments,
                        openPreview: { previewAttachment = $0 },
                        originalURL: { try? importExportService.originalFileURL(for: $0) }
                    )
                    .frame(width: 340)
                    .background(.regularMaterial)
                    .transition(.move(edge: .trailing))
                }
            }

            if penPaletteMode == .custom {
                PenPaletteView(
                    toolState: toolState,
                    addAttachment: { isShowingAttachmentPicker = true },
                    pasteImage: pasteImage,
                    showAttachments: {
                        withAnimation(.snappy) {
                            isShowingAttachments.toggle()
                        }
                    },
                    showBackgrounds: {
                        isShowingBackgroundPicker = true
                    }
                )
                .padding(.top, 14)
                .zIndex(2)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            editorToolbar(page: page)
        }
        .confirmationDialog("Page Background", isPresented: $isShowingBackgroundPicker, titleVisibility: .visible) {
            ForEach(NoteBackgroundStyle.allCases) { style in
                Button(style.label) {
                    page.background = NoteBackground(style: style, colorHex: page.backgroundColorHex)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private func editorToolbar(page: NotePage) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            TextField("Title", text: $note.title)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit {
                    note.touch()
                    try? modelContext.save()
                }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                ForEach(note.sortedPages) { candidate in
                    Button("Page \(candidate.pageOrder + 1)") {
                        selectedPageID = candidate.id
                    }
                }

                Button {
                    addPage(after: page)
                } label: {
                    Label("Add Page", systemImage: "plus")
                }
            } label: {
                Image(systemName: "square.stack")
            }
            .accessibilityLabel("Pages")

            Menu {
                ForEach(NoteBackgroundStyle.allCases) { style in
                    Button(style.label) {
                        page.background = NoteBackground(style: style, colorHex: page.backgroundColorHex)
                    }
                }

                ColorPicker(
                    "Color",
                    selection: Binding(
                        get: { Color(hex: page.backgroundColorHex) },
                        set: { newColor in
                            page.backgroundColorHex = newColor.hexRGB
                            page.touch()
                        }
                    )
                )
            } label: {
                Image(systemName: "rectangle.inset.filled")
            }
            .accessibilityLabel("Page background")

            Button {
                pasteImage()
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .accessibilityLabel("Paste image")

            Button {
                isShowingAttachmentPicker = true
            } label: {
                Image(systemName: "paperclip")
            }
            .accessibilityLabel("Add attachment")

            Button {
                withAnimation(.snappy) {
                    isShowingAttachments.toggle()
                }
            } label: {
                Image(systemName: "sidebar.right")
            }
            .accessibilityLabel("Attachments")

            Button {
                saveNow()
                isShowingExport = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Export")
        }
    }

    private func ensurePage() {
        if let firstPage = note.sortedPages.first {
            selectedPageID = selectedPageID ?? firstPage.id
            return
        }

        let page = NotePage(pageOrder: 0, note: note)
        note.pages.append(page)
        modelContext.insert(page)
        selectedPageID = page.id
        try? modelContext.save()
    }

    private func addPage(after page: NotePage) {
        let nextOrder = (note.pages.map(\.pageOrder).max() ?? -1) + 1
        let newPage = NotePage(pageOrder: nextOrder, background: page.background, note: note)
        note.pages.append(newPage)
        note.touch()
        modelContext.insert(newPage)
        selectedPageID = newPage.id
        try? modelContext.save()
    }

    private func importFiles(_ urls: [URL]) async {
        do {
            var firstImportedPageID: UUID?

            for url in urls {
                if importExportService.importsAsAnnotatableDocument(url) {
                    let nextOrder = (note.pages.map(\.pageOrder).max() ?? -1) + 1
                    let imported = try await importExportService.importDocumentPages(
                        from: url,
                        into: note,
                        startingAt: nextOrder
                    )
                    insertImported(imported)
                    firstImportedPageID = firstImportedPageID ?? imported.firstPage?.id
                } else if let page = selectedPage {
                    let attachment = try importExportService.importFile(from: url, into: page)
                    modelContext.insert(attachment)
                }
            }

            if let firstImportedPageID {
                selectedPageID = firstImportedPageID
            }

            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func insertImported(_ imported: ImportedDocumentPages) {
        for page in imported.pages {
            modelContext.insert(page)
        }

        for attachment in imported.attachments {
            modelContext.insert(attachment)
        }
    }

    private func importImage(_ image: UIImage, named name: String) {
        guard let page = selectedPage else { return }

        do {
            let attachment = try importExportService.importImage(image, named: name, into: page)
            modelContext.insert(attachment)
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pasteImage() {
        guard let image = UIPasteboard.general.image else {
            errorMessage = "The clipboard does not contain an image."
            return
        }

        importImage(image, named: "Pasted Image")
    }

    private func saveNow() {
        saveNowSignal += 1
        note.touch()
        try? modelContext.save()
    }

    private func image(for attachment: Attachment) -> UIImage? {
        UIImage(contentsOfFile: storage.url(forRelativePath: attachment.storedFileName).path)
    }
}
