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
    @AppStorage("noteEditorPageFlowMode") private var pageFlowModeRaw = NoteEditorPageFlowMode.continuous.rawValue
    @AppStorage(NoteBackground.defaultStyleRawKey) private var defaultBackgroundStyleRaw = NoteBackgroundStyle.plain.rawValue
    @AppStorage(NoteBackground.defaultColorHexKey) private var defaultBackgroundColorHex = NoteBackground.defaultColorHex

    @State private var selectedPageID: UUID?
    @State private var isShowingAttachmentPicker = false
    @State private var isShowingExport = false
    @State private var isShowingAttachments = false
    @State private var isShowingBackgroundPicker = false
    @State private var previewAttachment: Attachment?
    @State private var saveNowSignal = 0
    @State private var fitToPageSignal = 0
    @State private var errorMessage: String?

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

    private var pageFlowMode: NoteEditorPageFlowMode {
        NoteEditorPageFlowMode(rawValue: pageFlowModeRaw) ?? .continuous
    }

    private var editorPages: [NotePage] {
        let pages = note.sortedPages

        switch pageFlowMode {
        case .singlePage:
            if let selectedPage {
                return [selectedPage]
            } else {
                return Array(pages.prefix(1))
            }
        case .continuous, .infinite:
            return pages
        }
    }

    private var currentPageIndex: Int? {
        guard let selectedPageID else { return nil }
        return note.sortedPages.firstIndex { $0.id == selectedPageID }
    }

    private var pageStatusText: String {
        guard let currentPageIndex else {
            return "Page 1 / \(max(note.sortedPages.count, 1))"
        }

        return "Page \(currentPageIndex + 1) / \(max(note.sortedPages.count, 1))"
    }

    private var defaultNoteBackground: NoteBackground {
        NoteBackground.fromDefaults(styleRaw: defaultBackgroundStyleRaw, colorHex: defaultBackgroundColorHex)
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
        .sheet(isPresented: $isShowingBackgroundPicker) {
            if let page = selectedPage {
                PageBackgroundEditorSheet(
                    styleRaw: Binding(
                        get: { page.backgroundStyleRaw },
                        set: {
                            page.backgroundStyleRaw = $0
                            page.touch()
                            try? modelContext.save()
                        }
                    ),
                    colorHex: Binding(
                        get: { page.backgroundColorHex },
                        set: {
                            page.backgroundColorHex = $0
                            page.touch()
                            try? modelContext.save()
                        }
                    ),
                    applyToAllPages: {
                        applyBackgroundToAllPages(from: page)
                    }
                )
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
                DrawingCanvasView(
                    pages: editorPages,
                    selectedPageID: $selectedPageID,
                    toolState: toolState,
                    paletteMode: penPaletteMode,
                    pageFlowMode: pageFlowMode,
                    doubleTapAction: doubleTapAction,
                    saveNowSignal: saveNowSignal,
                    fitToPageSignal: fitToPageSignal,
                    attachmentChanged: {
                        try? modelContext.save()
                    },
                    addPageAtBottom: addPageAtBottom
                )
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
            Button {
                goToPreviousPage()
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(currentPageIndex == nil || currentPageIndex == 0)
            .accessibilityLabel("Previous page")

            Text(pageStatusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 82)

            Button {
                goToNextPage()
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(currentPageIndex == nil || currentPageIndex == note.sortedPages.count - 1)
            .accessibilityLabel("Next page")

            Button {
                addPage(after: page)
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .accessibilityLabel("Add page")

            Button {
                fitToPageSignal += 1
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityLabel("Fit page to screen")

            Button {
                isShowingBackgroundPicker = true
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

        let page = NotePage(pageOrder: 0, background: defaultNoteBackground, note: note)
        note.pages.append(page)
        modelContext.insert(page)
        selectedPageID = page.id
        try? modelContext.save()
    }

    private func addPage(after page: NotePage, shouldSelect: Bool = true) {
        let nextOrder = (note.pages.map(\.pageOrder).max() ?? -1) + 1
        let newPage = NotePage(pageOrder: nextOrder, background: page.background, note: note)
        note.pages.append(newPage)
        note.touch()
        modelContext.insert(newPage)

        if shouldSelect {
            selectedPageID = newPage.id
        }

        try? modelContext.save()
    }

    private func addPageAtBottom() {
        guard pageFlowMode.autoAddsPages, let lastPage = note.sortedPages.last else { return }
        addPage(after: lastPage, shouldSelect: false)
    }

    private func goToPreviousPage() {
        guard let currentPageIndex, currentPageIndex > 0 else { return }
        selectedPageID = note.sortedPages[currentPageIndex - 1].id
    }

    private func goToNextPage() {
        guard let currentPageIndex, currentPageIndex < note.sortedPages.count - 1 else { return }
        selectedPageID = note.sortedPages[currentPageIndex + 1].id
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

    private func applyBackgroundToAllPages(from sourcePage: NotePage) {
        let background = sourcePage.background

        for page in note.pages {
            page.background = background
        }

        note.touch()
        try? modelContext.save()
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
}

private struct PageBackgroundEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var styleRaw: String
    @Binding var colorHex: String
    var applyToAllPages: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Page Background") {
                    NoteBackgroundPickerView(styleRaw: $styleRaw, colorHex: $colorHex)
                        .padding(.vertical, 6)
                }

                Section {
                    Button {
                        applyToAllPages()
                    } label: {
                        Label("Apply to All Pages", systemImage: "square.stack.3d.up")
                    }
                }
            }
            .navigationTitle("Background")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
