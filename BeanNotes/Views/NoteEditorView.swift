//
//  NoteEditorView.swift
//  BeanNotes
//

import SwiftData
import SwiftUI
import UIKit

struct NoteEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.beanNotesTheme) private var beanNotesTheme

    @Bindable var note: NoteDocument
    @Binding private var isWorkspaceFocusModeEnabled: Bool
    @Query(sort: \NoteDocument.updatedAt, order: .reverse) private var allNotes: [NoteDocument]
    @FocusState private var isTitleFieldFocused: Bool

    @StateObject private var toolState = DrawingToolState()
    @AppStorage("penPaletteMode") private var penPaletteModeRaw = PenPaletteMode.custom.rawValue
    @AppStorage(DrawingInputMode.storageKey) private var drawingInputModeRaw = DrawingInputMode.defaultMode.rawValue
    @AppStorage(DrawingStrokeZoomBehavior.storageKey) private var strokeZoomBehaviorRaw = DrawingStrokeZoomBehavior.defaultBehavior.rawValue
    @AppStorage("pencilDoubleTapAction") private var doubleTapRaw = PencilDoubleTapAction.switchToEraser.rawValue
    @AppStorage(NoteEditorPageLayoutMode.storageKey) private var pageLayoutModeRaw = NoteEditorPageLayoutMode.scroll.rawValue
    @AppStorage(NoteEditorPageCreationMode.storageKey) private var pageCreationModeRaw = NoteEditorPageCreationMode.manual.rawValue
    @AppStorage(NoteBackground.defaultStyleRawKey) private var defaultBackgroundStyleRaw = NoteBackgroundStyle.plain.rawValue
    @AppStorage(NoteBackground.defaultColorHexKey) private var defaultBackgroundColorHex = BeanNotesTheme.defaultTheme.defaultNoteBackgroundHex

    @State private var selectedPageID: UUID?
    @State private var isShowingAttachmentPicker = false
    @State private var isShowingExport = false
    @State private var isShowingAttachments = false
    @State private var isShowingBackgroundPicker = false
    @State private var isImportingFiles = false
    @State private var importProgress: Double?
    @State private var importProgressMessage = "Preparing import..."
    @State private var importTask: Task<Void, Never>?
    @State private var previewAttachment: Attachment?
    @State private var saveNowSignal = 0
    @State private var exportPreparationSignal = 0
    @State private var pendingExportPreparationID: Int?
    @State private var fitToPageSignal = 0
    @State private var zoomInSignal = 0
    @State private var zoomOutSignal = 0
    @State private var zoomToScaleSignal = 0
    @State private var zoomTargetScale: CGFloat = 1
    @State private var currentZoomScale: CGFloat = 1
    @State private var undoSignal = 0
    @State private var redoSignal = 0
    @State private var toolShortcutSignal = 0
    @State private var canUndoDrawing = false
    @State private var canRedoDrawing = false
    @State private var errorMessage: String?
    @State private var isEditingTitle = false
    @State private var draftTitle = ""
    @State private var autoAddedPlaceholderPageID: UUID?
    @State private var pagePendingDeletion: NotePage?
    @State private var pagePendingMove: NotePage?
    @State private var isShowingPageReorder = false
    @State private var autosaveState: AutosaveIndicatorState = .saved
    @State private var isDrawingSavePending = false
    @State private var didDrawingSaveFail = false
    @State private var isMetadataSavePending = false
    @State private var didMetadataSaveFail = false
    @State private var drawingMetadataSaveTask: Task<Void, Never>?

    private let importExportService = ImportExportService()
    private let drawingMetadataSaveDelayNanoseconds: UInt64 = 700_000_000

    init(note: NoteDocument, isWorkspaceFocusModeEnabled: Binding<Bool> = .constant(false)) {
        self.note = note
        self._isWorkspaceFocusModeEnabled = isWorkspaceFocusModeEnabled
    }

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

    private var drawingInputMode: DrawingInputMode {
        DrawingInputMode(rawValue: drawingInputModeRaw) ?? DrawingInputMode.defaultMode
    }

    private var strokeZoomBehavior: DrawingStrokeZoomBehavior {
        DrawingStrokeZoomBehavior(rawValue: strokeZoomBehaviorRaw) ?? DrawingStrokeZoomBehavior.defaultBehavior
    }

    private var pageLayoutMode: NoteEditorPageLayoutMode {
        if UserDefaults.standard.object(forKey: NoteEditorPageLayoutMode.storageKey) == nil,
           let rawValue = UserDefaults.standard.string(forKey: NoteEditorPageFlowMode.storageKey),
           let legacyMode = NoteEditorPageFlowMode(rawValue: rawValue) {
            return legacyMode.layoutMode
        }

        return NoteEditorPageLayoutMode(rawValue: pageLayoutModeRaw) ?? .scroll
    }

    private var pageCreationMode: NoteEditorPageCreationMode {
        if UserDefaults.standard.object(forKey: NoteEditorPageCreationMode.storageKey) == nil,
           let rawValue = UserDefaults.standard.string(forKey: NoteEditorPageFlowMode.storageKey),
           let legacyMode = NoteEditorPageFlowMode(rawValue: rawValue) {
            return legacyMode.creationMode
        }

        return NoteEditorPageCreationMode(rawValue: pageCreationModeRaw) ?? .manual
    }

    private var pageFlowMode: NoteEditorPageFlowMode {
        NoteEditorPageFlowMode.combined(
            layoutMode: pageLayoutMode,
            creationMode: pageCreationMode
        )
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
            return pageFlowMode.pageStatusText(currentPage: 1, totalPages: max(note.sortedPages.count, 1))
        }

        return pageFlowMode.pageStatusText(
            currentPage: currentPageIndex + 1,
            totalPages: max(note.sortedPages.count, 1)
        )
    }

    private var moveTargetNotes: [NoteDocument] {
        allNotes.filter { $0.id != note.id }
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
            migrateLegacyPaginationSettingIfNeeded()
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
                importTask?.cancel()
                importTask = Task { @MainActor in
                    await importFiles(urls)
                    importTask = nil
                }
            } importImageData: { data, name in
                Task {
                    await importImageData(data, named: name)
                }
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
                            updatePageBackground(page, styleRaw: $0)
                        }
                    ),
                    colorHex: Binding(
                        get: { page.backgroundColorHex },
                        set: {
                            updatePageBackground(page, colorHex: $0)
                        }
                    ),
                    applyToAllPages: {
                        applyBackgroundToAllPages(from: page)
                    }
                )
            }
        }
        .sheet(isPresented: $isShowingPageReorder) {
            PageReorderSheet(
                pages: note.sortedPages,
                selectedPageID: selectedPageID,
                movePages: reorderPages
            )
        }
        .sheet(item: $pagePendingMove) { page in
            PageMoveTargetSheet(
                page: page,
                targetNotes: moveTargetNotes,
                movePage: { targetNote in
                    movePage(page, to: targetNote)
                }
            )
        }
        .sheet(item: $previewAttachment) { attachment in
            if let url = try? importExportService.originalFileURL(for: attachment) {
                DocumentPreviewSheet(attachment: attachment, fileURL: url)
            } else {
                ContentUnavailableView("Missing file", systemImage: "exclamationmark.triangle")
            }
        }
        .alert("Delete Page?", isPresented: Binding(
            get: { pagePendingDeletion != nil },
            set: { if !$0 { pagePendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let page = pagePendingDeletion else { return }
                pagePendingDeletion = nil
                deletePage(page)
            }
            Button("Cancel", role: .cancel) {
                pagePendingDeletion = nil
            }
        } message: {
            Text("This removes the page, handwriting, thumbnails, and page attachments from local storage.")
        }
        .alert("BeanNotes", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func editor(page: NotePage) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                ZStack(alignment: .trailing) {
                    DrawingCanvasView(
                        pages: editorPages,
                        selectedPageID: $selectedPageID,
                        toolState: toolState,
                        paletteMode: penPaletteMode,
                        inputMode: drawingInputMode,
                        renderQuality: .ultraFine,
                        strokeZoomBehavior: strokeZoomBehavior,
                        pageFlowMode: pageFlowMode,
                        doubleTapAction: doubleTapAction,
                        saveNowSignal: saveNowSignal,
                        exportPreparationSignal: exportPreparationSignal,
                        fitToPageSignal: fitToPageSignal,
                        zoomInSignal: zoomInSignal,
                        zoomOutSignal: zoomOutSignal,
                        zoomToScaleSignal: zoomToScaleSignal,
                        zoomTargetScale: zoomTargetScale,
                        undoSignal: undoSignal,
                        redoSignal: redoSignal,
                        toolShortcutSignal: toolShortcutSignal,
                        attachmentChanged: {
                            autoAddedPlaceholderPageID = nil
                            saveEditorChanges("save attachment changes")
                        },
                        drawingChanged: handleDrawingChanged(pageID:),
                        saveStarted: markDrawingSaveStarted,
                        saveSucceeded: markDrawingSaveSucceeded,
                        saveFailed: { error in
                            markDrawingSaveFailed()
                            errorMessage = "BeanNotes could not save the drawing. \(error.localizedDescription)"
                        },
                        exportPreparationCompleted: handleExportPreparationCompleted(id:result:),
                        undoRedoAvailabilityChanged: updateUndoRedoAvailability(canUndo:canRedo:),
                        zoomScaleChanged: updateZoomScale(_:),
                        addPageAtBottom: addPageAtBottom,
                        topContent: isWorkspaceFocusModeEnabled ? nil : AnyView(editorTitleHeader(page: page)),
                        theme: beanNotesTheme
                    )
                    .ignoresSafeArea(.container, edges: .bottom)

                    if isShowingAttachments {
                        AttachmentListView(
                            attachments: page.attachments,
                            openPreview: { previewAttachment = $0 },
                            originalURL: { try? importExportService.originalFileURL(for: $0) },
                            renameAttachment: renameAttachment(_:to:),
                            deleteAttachment: deleteAttachment(_:),
                            toggleLock: toggleAttachmentLock(_:),
                            setDrawingLayer: setAttachmentDrawingLayer(_:behindDrawing:)
                        )
                        .frame(width: 340)
                        .background(.regularMaterial)
                        .transition(.move(edge: .trailing))
                    }
                }

                if penPaletteMode == .custom {
                    GeometryReader { proxy in
                        PenPaletteView(
                            toolState: toolState,
                            availableSize: proxy.size,
                            zoomScale: currentZoomScale,
                            strokeZoomBehavior: strokeZoomBehavior
                        )
                    }
                    .zIndex(2)
                }

                if isWorkspaceFocusModeEnabled {
                    focusModeQuickToolbar
                        .padding(.top, 14)
                        .padding(.trailing, 18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .zIndex(3)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                } else {
                    editorPinnedActionToolbar(page: page)
                        .padding(.top, 14)
                        .padding(.trailing, 18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .zIndex(3)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

            }
        }
        .background {
            BeanNotesPaperBackground(
                theme: beanNotesTheme,
                baseColor: beanNotesTheme.appBackground,
                showsMascotWatermark: true
            )
                .ignoresSafeArea()
        }
        .tint(beanNotesTheme.accentColor)
        .overlay {
            if isImportingFiles {
                BeanNotesProgressOverlay(
                    title: "Importing",
                    message: importProgressMessage,
                    progress: importProgress,
                    cancel: cancelImport
                )
            }
        }
        .background {
            editorKeyboardShortcuts
        }
        .animation(.snappy(duration: 0.18), value: isWorkspaceFocusModeEnabled)
    }

    private func editorTitleHeader(page: NotePage) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                if isEditingTitle {
                    TextField("Untitled Note", text: $draftTitle)
                        .font(.system(size: 32, weight: .black, design: .rounded))
                        .textFieldStyle(.plain)
                        .focused($isTitleFieldFocused)
                        .submitLabel(.done)
                        .lineLimit(1)
                        .onSubmit(commitTitleEdit)
                        .onChange(of: isTitleFieldFocused) { _, isFocused in
                            if !isFocused {
                                commitTitleEdit()
                            }
                        }
                        .onAppear {
                            isTitleFieldFocused = true
                        }
                } else {
                    Button {
                        beginTitleEdit()
                    } label: {
                        Text(displayTitle)
                            .font(.system(size: 32, weight: .black, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.68)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit note title")
                }

                HStack(spacing: 10) {
                    Text(pageStatusText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    AutosaveIndicatorView(state: autosaveState)
                }
            }
            .frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.regularMaterial)
    }

    private func editorPinnedActionToolbar(page: NotePage) -> some View {
        HStack(spacing: 8) {
            Button {
                setFocusModeEnabled(true)
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel("Focus drawing mode")
            .accessibilityHint("Hide editor controls for more drawing space")

            Divider()
                .frame(height: 24)

            Button {
                undoSignal += 1
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 34, height: 34)
            }
            .disabled(!canUndoDrawing || isEditingTitle)
            .keyboardShortcut("z", modifiers: [.command])
            .accessibilityLabel("Undo")
            .accessibilityHint("Undo the last drawing change on the current page")

            Button {
                redoSignal += 1
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 34, height: 34)
            }
            .disabled(!canRedoDrawing || isEditingTitle)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .accessibilityLabel("Redo")
            .accessibilityHint("Redo the last undone drawing change on the current page")

            Divider()
                .frame(height: 24)

            Button {
                goToPreviousPage()
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 34, height: 34)
            }
            .disabled(currentPageIndex == nil || currentPageIndex == 0)
            .keyboardShortcut(.upArrow, modifiers: [.command])
            .accessibilityLabel("Previous page")

            Button {
                goToNextPage()
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 34, height: 34)
            }
            .disabled(currentPageIndex == nil || currentPageIndex == note.sortedPages.count - 1)
            .keyboardShortcut(.downArrow, modifiers: [.command])
            .accessibilityLabel("Next page")

            Divider()
                .frame(height: 24)

            Button {
                manuallyAddPage(after: page)
            } label: {
                Image(systemName: "plus.square.on.square")
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel("Add page")

            pageActionsMenu(page: page)

            Button {
                isShowingBackgroundPicker = true
            } label: {
                Image(systemName: "rectangle.inset.filled")
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel("Page background")

            Button {
                pasteImage()
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel("Paste image")

            Button {
                isShowingAttachmentPicker = true
            } label: {
                Image(systemName: "paperclip")
                    .frame(width: 34, height: 34)
            }
            .keyboardShortcut("i", modifiers: [.command])
            .accessibilityLabel("Add attachment")

            Button {
                withAnimation(.snappy) {
                    isShowingAttachments.toggle()
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel("Attachments")

            Button(action: prepareExport) {
                Group {
                    if pendingExportPreparationID == nil {
                        Image(systemName: "square.and.arrow.up")
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(width: 34, height: 34)
            }
            .disabled(pendingExportPreparationID != nil)
            .keyboardShortcut("e", modifiers: [.command])
            .accessibilityLabel(pendingExportPreparationID == nil ? "Export" : "Preparing export")
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 16, x: 0, y: 8)
    }

    private var focusModeQuickToolbar: some View {
        HStack(spacing: 8) {
            Button {
                setFocusModeEnabled(false)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.headline.weight(.semibold))
                    .frame(width: 38, height: 38)
            }
            .accessibilityLabel("Exit focus mode")
            .accessibilityHint("Show editor controls")

            Divider()
                .frame(height: 24)

            Button {
                undoSignal += 1
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 34, height: 34)
            }
            .disabled(!canUndoDrawing || isEditingTitle)
            .keyboardShortcut("z", modifiers: [.command])
            .accessibilityLabel("Undo")
            .accessibilityHint("Undo the last drawing change on the current page")

            Button {
                redoSignal += 1
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 34, height: 34)
            }
            .disabled(!canRedoDrawing || isEditingTitle)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .accessibilityLabel("Redo")
            .accessibilityHint("Redo the last undone drawing change on the current page")

        }
        .buttonStyle(.borderless)
        .controlSize(.large)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 16, x: 0, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Focus mode drawing controls")
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button {
                zoomOutSignal += 1
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: 30, height: 34)
            }
            .keyboardShortcut("-", modifiers: [.command])
            .accessibilityLabel("Zoom out")

            zoomMenu

            Button {
                zoomInSignal += 1
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: 30, height: 34)
            }
            .keyboardShortcut("+", modifiers: [.command])
            .accessibilityLabel("Zoom in")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Zoom \(currentZoomText), native PencilKit detail, \(drawingInputMode.label) touch mode, \(strokeZoomBehavior.label) ink"
        )
    }

    private var zoomMenu: some View {
        Menu {
            Section {
                Label("Current \(currentZoomText)", systemImage: "viewfinder")
                Label("Native PencilKit canvas", systemImage: "pencil.tip")
                Label("Touch \(drawingInputMode.label)", systemImage: drawingInputMode.systemImage)
                Label("Ink \(strokeZoomBehavior.label)", systemImage: strokeZoomBehavior.systemImage)
                if penPaletteMode == .custom, toolState.selectedToolUsesInkColor {
                    Label(activeInkReadoutText, systemImage: "scribble")
                }
            }

            Section {
                Button {
                    applyDetailWritingMode()
                } label: {
                    Label(
                        DrawingDetailWritingMode.label,
                        systemImage: isDetailWritingModeActive ? "checkmark" : DrawingDetailWritingMode.systemImage
                    )
                }
                .accessibilityLabel(DrawingDetailWritingMode.accessibilityLabel)
                .accessibilityHint(DrawingDetailWritingMode.description)

                Button {
                    applyLightTouchFocusMode()
                } label: {
                    Label(
                        DrawingLightTouchFocusMode.label,
                        systemImage: isLightTouchFocusModeActive
                            ? "checkmark"
                            : DrawingLightTouchFocusMode.systemImage
                    )
                }
                .accessibilityLabel(DrawingLightTouchFocusMode.accessibilityLabel)
                .accessibilityHint(DrawingLightTouchFocusMode.description)

                Button {
                    lockCurrentPageInk()
                } label: {
                    Label("Lock Page Ink", systemImage: "lock")
                }
                .disabled(!canLockCurrentPageInk)
                .accessibilityLabel("Lock current page ink width")
                .accessibilityHint("Store the effective page ink width and keep it consistent across zoom levels")
            }

            Section {
                Button {
                    zoomInSignal += 1
                } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }

                Button {
                    zoomOutSignal += 1
                } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }

                Button {
                    fitToPageSignal += 1
                } label: {
                    Label("Fit Page", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }

            Section("Touch Mode") {
                ForEach(DrawingInputMode.allCases) { mode in
                    Button {
                        setDrawingInputMode(mode)
                    } label: {
                        Label(
                            mode.label,
                            systemImage: drawingInputMode == mode ? "checkmark" : mode.systemImage
                        )
                    }
                    .accessibilityHint(mode.description)
                }
            }

            Section("Quick Zoom") {
                ForEach(DrawingZoomPreset.quickPresets(for: .ultraFine)) { preset in
                    Button {
                        setZoomScale(preset.scale)
                    } label: {
                        Label(
                            preset.label,
                            systemImage: DrawingZoomLevel.isScale(currentZoomScale, closeTo: preset.scale)
                                ? "checkmark"
                                : preset.systemImage
                        )
                    }
                    .accessibilityLabel(preset.accessibilityLabel)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                Text(currentZoomText)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .frame(width: 38, alignment: .leading)
                Image(systemName: drawingInputMode.systemImage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 34)
            .padding(.horizontal, 3)
        }
        .accessibilityIdentifier("Zoom resolution status")
        .accessibilityLabel("Zoom \(currentZoomText), native PencilKit canvas, \(drawingInputMode.label) touch mode, \(strokeZoomBehavior.label) ink")
        .accessibilityHint("Zoom, fit the selected page, change touch mode, or ink width")
    }

    private var currentZoomText: String {
        DrawingZoomLevel.percentageText(for: currentZoomScale)
    }

    private var isDetailWritingModeActive: Bool {
        strokeZoomBehavior == DrawingDetailWritingMode.strokeZoomBehavior
            && toolState.widthMode == DrawingDetailWritingMode.widthMode
            && DrawingZoomLevel.isScale(currentZoomScale, closeTo: DrawingDetailWritingMode.zoomScale)
    }

    private var isLightTouchFocusModeActive: Bool {
        isWorkspaceFocusModeEnabled
            && drawingInputMode == DrawingLightTouchFocusMode.inputMode
            && strokeZoomBehavior == DrawingLightTouchFocusMode.strokeZoomBehavior
            && toolState.widthMode == DrawingLightTouchFocusMode.widthMode
            && DrawingZoomLevel.isScale(currentZoomScale, closeTo: DrawingLightTouchFocusMode.zoomScale)
    }

    private var activeInkReadout: DrawingStrokeWidthReadout {
        toolState.strokeWidthReadout(
            for: toolState.activeColorTool,
            zoomScale: currentZoomScale,
            zoomBehavior: strokeZoomBehavior
        )
    }

    private var activeInkReadoutText: String {
        if activeInkReadout.showsEffectiveWidth {
            return "\(toolState.activeColorTool.label) ink \(activeInkReadout.effectiveWidthText) pt on page"
        }

        return "\(toolState.activeColorTool.label) ink \(activeInkReadout.storedWidthText) pt"
    }

    private var activeInkCalibrationStatus: DrawingInkCalibrationStatus {
        DrawingInkCalibrationStatus(tool: toolState.activeColorTool, readout: activeInkReadout)
    }

    private var shouldShowInkCalibrationStrip: Bool {
        DrawingInkCalibrationStatus.shouldShow(
            readout: activeInkReadout,
            isUsingCustomPalette: penPaletteMode == .custom,
            toolUsesInk: toolState.selectedToolUsesInkColor
        )
    }

    private var canLockCurrentPageInk: Bool {
        shouldShowInkCalibrationStrip
    }

    private var inkCalibrationStrip: some View {
        let status = activeInkCalibrationStatus

        return HStack(spacing: 9) {
            HStack(spacing: 9) {
                Label {
                    Text(status.zoomText)
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "scope")
                        .foregroundStyle(beanNotesTheme.accentColor)
                }

                Divider()
                    .frame(height: 18)

                Label {
                    Text(status.pageInkText)
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "scribble")
                        .foregroundStyle(beanNotesTheme.accentColor)
                }

                Text(status.storedInkText)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)

            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.accessibilityLabel)

            Button {
                lockCurrentPageInk()
            } label: {
                Image(systemName: "lock")
                    .font(.caption.weight(.bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .background(Color(.secondarySystemBackground).opacity(0.72), in: Circle())
            .accessibilityLabel("Lock page ink width")
            .accessibilityHint("Store the current page ink width and switch to Page Width ink")

            Button {
                fitToPageSignal += 1
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .background(Color(.secondarySystemBackground).opacity(0.72), in: Circle())
            .accessibilityLabel("Fit page")
            .accessibilityHint("Reset zoom to the selected page")
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 14, x: 0, y: 8)
        .accessibilityElement(children: .contain)
    }

    private func pageActionsMenu(page: NotePage) -> some View {
        Menu {
            Button {
                duplicatePage(page)
            } label: {
                Label("Duplicate Page", systemImage: "plus.square.on.square")
            }

            Button {
                movePage(page, by: -1)
            } label: {
                Label("Move Page Up", systemImage: "arrow.up")
            }
            .disabled(currentPageIndex == nil || currentPageIndex == 0)

            Button {
                movePage(page, by: 1)
            } label: {
                Label("Move Page Down", systemImage: "arrow.down")
            }
            .disabled(currentPageIndex == nil || currentPageIndex == note.sortedPages.count - 1)

            Button {
                isShowingPageReorder = true
            } label: {
                Label("Reorder Pages", systemImage: "arrow.up.arrow.down.square")
            }
            .disabled(note.sortedPages.count < 2)

            Button {
                pagePendingMove = page
            } label: {
                Label("Move to Note", systemImage: "arrowshape.turn.up.right")
            }
            .disabled(note.sortedPages.count < 2 || moveTargetNotes.isEmpty)

            Divider()

            Button(role: .destructive) {
                pagePendingDeletion = page
            } label: {
                Label("Delete Page", systemImage: "trash")
            }
            .disabled(note.sortedPages.count < 2)
        } label: {
            Image(systemName: "square.stack.3d.down.right")
                .frame(width: 34, height: 34)
        }
        .accessibilityLabel("Page actions")
    }

    private var displayTitle: String {
        let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Note" : trimmed
    }

    private func beginTitleEdit() {
        draftTitle = displayTitle
        isEditingTitle = true
    }

    private func commitTitleEdit() {
        guard isEditingTitle else { return }

        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousTitle = note.title
        note.title = trimmed.isEmpty ? "Untitled Note" : trimmed
        note.touch()

        if saveEditorChanges("save the note title") {
            isEditingTitle = false
            isTitleFieldFocused = false
        } else {
            note.title = previousTitle
            draftTitle = previousTitle
        }
    }

    private func updateUndoRedoAvailability(canUndo: Bool, canRedo: Bool) {
        if canUndoDrawing != canUndo {
            canUndoDrawing = canUndo
        }

        if canRedoDrawing != canRedo {
            canRedoDrawing = canRedo
        }
    }

    private func updateZoomScale(_ scale: CGFloat) {
        guard abs(currentZoomScale - scale) > 0.005 else { return }
        currentZoomScale = scale
    }

    private func setZoomScale(_ scale: CGFloat) {
        zoomTargetScale = scale
        zoomToScaleSignal += 1
    }

    private func applyDetailWritingMode() {
        strokeZoomBehaviorRaw = DrawingDetailWritingMode.strokeZoomBehavior.rawValue
        toolState.selectWidthMode(DrawingDetailWritingMode.widthMode)
        setZoomScale(DrawingDetailWritingMode.zoomScale)
    }

    private func applyLightTouchFocusMode() {
        drawingInputModeRaw = DrawingLightTouchFocusMode.inputMode.rawValue
        strokeZoomBehaviorRaw = DrawingLightTouchFocusMode.strokeZoomBehavior.rawValue
        toolState.selectWidthMode(DrawingLightTouchFocusMode.widthMode)
        setZoomScale(DrawingLightTouchFocusMode.zoomScale)
        setFocusModeEnabled(true)
    }

    private func lockCurrentPageInk() {
        guard toolState.lockActiveWidthToEffectivePageInk(
            zoomScale: currentZoomScale,
            zoomBehavior: strokeZoomBehavior
        ) else {
            return
        }

        strokeZoomBehaviorRaw = DrawingStrokeZoomBehavior.pageWidth.rawValue
    }

    private func setStrokeZoomBehavior(_ behavior: DrawingStrokeZoomBehavior) {
        strokeZoomBehaviorRaw = behavior.rawValue
    }

    private func setDrawingInputMode(_ mode: DrawingInputMode) {
        drawingInputModeRaw = mode.rawValue
    }

    private func setFocusModeEnabled(_ enabled: Bool) {
        if enabled {
            if isEditingTitle {
                commitTitleEdit()
                guard !isEditingTitle else { return }
            }

            isShowingAttachments = false
        }

        isWorkspaceFocusModeEnabled = enabled
    }

    private var editorKeyboardShortcuts: some View {
        VStack {
            HiddenKeyboardShortcutButton(title: "Select Pen", key: "1") {
                selectToolFromKeyboard(.pen)
            }

            HiddenKeyboardShortcutButton(title: "Select Pencil", key: "2") {
                selectToolFromKeyboard(.pencil)
            }

            HiddenKeyboardShortcutButton(title: "Select Highlighter", key: "3") {
                selectToolFromKeyboard(.highlighter)
            }

            HiddenKeyboardShortcutButton(title: "Select Eraser", key: "4") {
                selectToolFromKeyboard(.eraser)
            }

            HiddenKeyboardShortcutButton(title: "Select Lasso", key: "5") {
                selectToolFromKeyboard(.lasso)
            }
        }
    }

    private func selectToolFromKeyboard(_ tool: DrawingTool) {
        toolState.select(tool)
        toolShortcutSignal += 1
    }

    private func ensurePage() {
        if let firstPage = note.sortedPages.first {
            selectedPageID = selectedPageID ?? firstPage.id
            return
        }

        let page = NotePage(pageOrder: 0, background: defaultNoteBackground)
        note.pages.append(page)
        selectedPageID = page.id

        if !saveEditorChanges("create the first page") {
            note.pages.removeAll { $0.id == page.id }
            modelContext.delete(page)
            selectedPageID = nil
        }
    }

    private func migrateLegacyPaginationSettingIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: NoteEditorPageLayoutMode.storageKey) == nil,
              let rawValue = defaults.string(forKey: NoteEditorPageFlowMode.storageKey),
              let legacyMode = NoteEditorPageFlowMode(rawValue: rawValue) else {
            return
        }

        pageLayoutModeRaw = legacyMode.layoutMode.rawValue
        pageCreationModeRaw = legacyMode.creationMode.rawValue
    }

    @discardableResult
    private func addPage(after page: NotePage, shouldSelect: Bool = true) -> NotePage? {
        let previousOrders = pageOrders(in: note)
        let newPage = NotePage(pageOrder: page.pageOrder + 1, background: page.background)
        note.pages.append(newPage)
        applyPageOrder(inserting: newPage, after: page)
        note.touch()

        if shouldSelect {
            selectedPageID = newPage.id
        }

        guard saveEditorChanges("add a page") else {
            restorePageOrders(previousOrders)
            note.pages.removeAll { $0.id == newPage.id }
            modelContext.delete(newPage)
            if selectedPageID == newPage.id {
                selectedPageID = page.id
            }
            return nil
        }

        return newPage
    }

    private func manuallyAddPage(after page: NotePage) {
        autoAddedPlaceholderPageID = nil
        addPage(after: page)
    }

    private func addPageAtBottom() {
        guard pageFlowMode.autoAddsPages, let lastPage = note.sortedPages.last else { return }
        guard autoAddedPlaceholderPageID != lastPage.id else { return }

        if let newPage = addPage(after: lastPage, shouldSelect: false) {
            autoAddedPlaceholderPageID = newPage.id
        }
    }

    private func handleDrawingChanged(pageID: UUID) {
        guard let page = note.pages.first(where: { $0.id == pageID }) else { return }

        page.touch()
        scheduleDrawingMetadataSave()

        guard autoAddedPlaceholderPageID == pageID else { return }
        autoAddedPlaceholderPageID = nil
    }

    private func renameAttachment(_ attachment: Attachment, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName != attachment.displayName else { return }

        let previousName = attachment.displayName
        attachment.displayName = trimmedName
        attachment.touch()

        if !saveEditorChanges("rename the attachment") {
            attachment.displayName = previousName
        }
    }

    private func deleteAttachment(_ attachment: Attachment) {
        saveNow()

        let attachmentID = attachment.id
        runAfterPendingCanvasSave {
            guard let attachment = note.pages
                .flatMap(\.attachments)
                .first(where: { $0.id == attachmentID }) else {
                return
            }

            deleteAttachmentAfterPendingSave(attachment)
        }
    }

    private func deleteAttachmentAfterPendingSave(_ attachment: Attachment) {
        var cleanupTarget = LocalStorageCleanupTarget(attachment: attachment)
        excludeStillReferencedStorage(from: &cleanupTarget, excluding: attachment)

        let page = attachment.page
        page?.attachments.removeAll { $0.id == attachment.id }
        modelContext.delete(attachment)
        page?.touch()

        if previewAttachment?.id == attachment.id {
            previewAttachment = nil
        }

        do {
            try modelContext.save()
            reportCleanup(importExportService.storage.removeStoredFiles(matching: cleanupTarget))
        } catch {
            modelContext.rollback()
            errorMessage = "BeanNotes could not delete the attachment. \(error.localizedDescription)"
        }
    }

    private func toggleAttachmentLock(_ attachment: Attachment) {
        let previousIsLocked = attachment.isLocked
        attachment.isLocked.toggle()
        attachment.touch()

        if !saveEditorChanges("save attachment lock state") {
            attachment.isLocked = previousIsLocked
        }
    }

    private func setAttachmentDrawingLayer(_ attachment: Attachment, behindDrawing: Bool) {
        guard attachment.kind == .image, attachment.rendersBehindDrawing != behindDrawing else { return }

        let previousLayer = attachment.rendersBehindDrawing
        attachment.rendersBehindDrawing = behindDrawing
        attachment.touch()

        if !saveEditorChanges("save attachment layer") {
            attachment.rendersBehindDrawing = previousLayer
        }
    }

    private func duplicatePage(_ page: NotePage) {
        saveNow()

        let pageID = page.id
        runAfterPendingCanvasSave {
            guard let page = note.pages.first(where: { $0.id == pageID }) else { return }
            duplicatePageAfterPendingSave(page)
        }
    }

    private func duplicatePageAfterPendingSave(_ sourcePage: NotePage) {
        let storage = importExportService.storage
        let previousOrders = pageOrders(in: note)
        var copiedRelativePaths: [String] = []

        do {
            let duplicatedPage = NotePage(
                pageOrder: sourcePage.pageOrder + 1,
                background: sourcePage.background,
                searchableText: sourcePage.searchableText,
                searchIndexUpdatedAt: sourcePage.searchIndexUpdatedAt,
                width: sourcePage.width,
                height: sourcePage.height
            )

            if let copiedDrawingPath = try storage.copyStoredFileIfPresent(
                relativePath: "\(StorageDirectory.drawings.rawValue)/\(sourcePage.drawingFileName)",
                preferredFileName: duplicatedPage.drawingFileName
            ) {
                copiedRelativePaths.append(copiedDrawingPath)
                duplicatedPage.drawingFileName = URL(fileURLWithPath: copiedDrawingPath).lastPathComponent
            }

            if let thumbnailFileName = sourcePage.thumbnailFileName,
               let copiedThumbnailPath = try storage.copyStoredFileIfPresent(
                relativePath: thumbnailFileName,
                preferredFileName: "\(duplicatedPage.id.uuidString).\(URL(fileURLWithPath: thumbnailFileName).pathExtension)"
               ) {
                copiedRelativePaths.append(copiedThumbnailPath)
                duplicatedPage.thumbnailFileName = copiedThumbnailPath
            }

            note.pages.append(duplicatedPage)

            for sourceAttachment in sourcePage.attachments {
                guard let copiedAttachmentPath = try storage.copyStoredFileIfPresent(
                    relativePath: sourceAttachment.storedFileName,
                    preferredFileName: sourceAttachment.originalFileName
                ) else {
                    throw LocalStorageError.fileMissing(storage.url(forRelativePath: sourceAttachment.storedFileName))
                }

                copiedRelativePaths.append(copiedAttachmentPath)

                let attachment = Attachment(
                    kind: sourceAttachment.kind,
                    displayName: sourceAttachment.displayName,
                    originalFileName: sourceAttachment.originalFileName,
                    storedFileName: copiedAttachmentPath,
                    contentTypeIdentifier: sourceAttachment.contentTypeIdentifier,
                    fileExtension: sourceAttachment.fileExtension,
                    x: sourceAttachment.x,
                    y: sourceAttachment.y,
                    width: sourceAttachment.width,
                    height: sourceAttachment.height,
                    isLocked: sourceAttachment.isLocked,
                    rendersBehindDrawing: sourceAttachment.rendersBehindDrawing,
                    vectorSourceStoredFileName: sourceAttachment.vectorSourceStoredFileName,
                    vectorSourcePageIndex: sourceAttachment.vectorSourcePageIndex
                )
                duplicatedPage.attachments.append(attachment)
            }

            applyPageOrder(inserting: duplicatedPage, after: sourcePage)
            note.touch()
            try modelContext.save()
            selectedPageID = duplicatedPage.id
        } catch {
            modelContext.rollback()
            restorePageOrders(previousOrders)
            removeCopiedFiles(copiedRelativePaths)
            errorMessage = "BeanNotes could not duplicate the page. \(error.localizedDescription)"
        }
    }

    private func deletePage(_ page: NotePage) {
        guard note.sortedPages.count > 1 else {
            errorMessage = "A note needs at least one page."
            return
        }

        saveNow()

        let pageID = page.id
        runAfterPendingCanvasSave {
            guard let page = note.pages.first(where: { $0.id == pageID }) else { return }
            deletePageAfterPendingSave(page)
        }
    }

    private func deletePageAfterPendingSave(_ page: NotePage) {
        let orderedPages = note.sortedPages
        guard orderedPages.count > 1,
              orderedPages.contains(where: { $0.id == page.id }) else {
            errorMessage = "A note needs at least one page."
            return
        }

        var cleanupTarget = LocalStorageCleanupTarget(page: page)
        excludeStillReferencedStorage(from: &cleanupTarget, excluding: page)

        let fallbackPageID = fallbackPageID(afterRemoving: page, from: orderedPages)
        let previousOrders = pageOrders(in: note)
        note.pages.removeAll { $0.id == page.id }
        modelContext.delete(page)
        applyPageOrder(note.sortedPages)
        note.touch()
        note.markSearchIndexStale()

        do {
            try modelContext.save()
            selectedPageID = fallbackPageID
            autoAddedPlaceholderPageID = autoAddedPlaceholderPageID == page.id ? nil : autoAddedPlaceholderPageID
            reportCleanup(importExportService.storage.removeStoredFiles(matching: cleanupTarget))
        } catch {
            modelContext.rollback()
            restorePageOrders(previousOrders)
            selectedPageID = page.id
            errorMessage = "BeanNotes could not delete the page. \(error.localizedDescription)"
        }
    }

    private func movePage(_ page: NotePage, by offset: Int) {
        var orderedPages = note.sortedPages
        guard let sourceIndex = orderedPages.firstIndex(where: { $0.id == page.id }) else { return }

        let destinationIndex = sourceIndex + offset
        guard orderedPages.indices.contains(destinationIndex) else { return }

        orderedPages.remove(at: sourceIndex)
        orderedPages.insert(page, at: destinationIndex)
        applyAndSavePageOrder(orderedPages, action: "reorder the pages")
    }

    private func reorderPages(from offsets: IndexSet, to destination: Int) {
        var orderedPages = note.sortedPages
        orderedPages.move(fromOffsets: offsets, toOffset: destination)
        applyAndSavePageOrder(orderedPages, action: "reorder the pages")
    }

    private func movePage(_ page: NotePage, to targetNote: NoteDocument) {
        guard targetNote.id != note.id else { return }
        guard note.sortedPages.count > 1 else {
            errorMessage = "A note needs at least one page."
            return
        }

        saveNow()

        let pageID = page.id
        let targetNoteID = targetNote.id
        runAfterPendingCanvasSave {
            guard let page = note.pages.first(where: { $0.id == pageID }),
                  let targetNote = allNotes.first(where: { $0.id == targetNoteID }) else { return }
            movePageAfterPendingSave(page, to: targetNote)
        }
    }

    private func movePageAfterPendingSave(_ page: NotePage, to targetNote: NoteDocument) {
        let sourcePages = note.sortedPages
        guard sourcePages.count > 1,
              sourcePages.contains(where: { $0.id == page.id }) else {
            errorMessage = "A note needs at least one page."
            return
        }

        let previousSourceOrders = pageOrders(in: note)
        let previousTargetOrders = pageOrders(in: targetNote)
        let fallbackPageID = fallbackPageID(afterRemoving: page, from: sourcePages)

        note.pages.removeAll { $0.id == page.id }
        targetNote.pages.append(page)
        page.pageOrder = (targetNote.pages.filter { $0.id != page.id }.map(\.pageOrder).max() ?? -1) + 1
        applyPageOrder(note.sortedPages)
        applyPageOrder(targetNote.sortedPages)
        note.touch()
        targetNote.touch()
        note.markSearchIndexStale()
        targetNote.markSearchIndexStale()

        do {
            try modelContext.save()
            selectedPageID = fallbackPageID
            autoAddedPlaceholderPageID = autoAddedPlaceholderPageID == page.id ? nil : autoAddedPlaceholderPageID
        } catch {
            modelContext.rollback()
            restorePageOrders(previousSourceOrders)
            restorePageOrders(previousTargetOrders)
            selectedPageID = page.id
            errorMessage = "BeanNotes could not move the page. \(error.localizedDescription)"
        }
    }

    private func applyAndSavePageOrder(_ orderedPages: [NotePage], action: String) {
        let previousOrders = pageOrders(in: note)
        applyPageOrder(orderedPages)
        note.touch()

        if !saveEditorChanges(action) {
            restorePageOrders(previousOrders)
        }
    }

    private func applyPageOrder(inserting insertedPage: NotePage, after sourcePage: NotePage) {
        var orderedPages = note.sortedPages.filter { $0.id != insertedPage.id }
        let insertionIndex = orderedPages.firstIndex { $0.id == sourcePage.id }
            .map { orderedPages.index(after: $0) }
            ?? orderedPages.endIndex
        orderedPages.insert(insertedPage, at: insertionIndex)
        applyPageOrder(orderedPages)
    }

    private func fallbackPageID(afterRemoving removedPage: NotePage, from orderedPages: [NotePage]) -> UUID? {
        let remainingPages = orderedPages.filter { $0.id != removedPage.id }
        guard !remainingPages.isEmpty else { return nil }

        let removedIndex = orderedPages.firstIndex { $0.id == removedPage.id } ?? 0
        return remainingPages[min(removedIndex, remainingPages.count - 1)].id
    }

    private func runAfterPendingCanvasSave(_ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func applyPageOrder(_ orderedPages: [NotePage]) {
        for (index, page) in orderedPages.enumerated() {
            page.pageOrder = index
        }
    }

    private func pageOrders(in note: NoteDocument) -> [UUID: Int] {
        Dictionary(uniqueKeysWithValues: note.pages.map { ($0.id, $0.pageOrder) })
    }

    private func restorePageOrders(_ pageOrders: [UUID: Int]) {
        for page in allNotes.flatMap(\.pages) where pageOrders.keys.contains(page.id) {
            page.pageOrder = pageOrders[page.id] ?? page.pageOrder
        }
    }

    private func removeCopiedFiles(_ relativePaths: [String]) {
        for relativePath in relativePaths {
            _ = try? importExportService.storage.removeFile(relativePath: relativePath)
        }
    }

    private func excludeStillReferencedStorage(from target: inout LocalStorageCleanupTarget, excluding deletedPage: NotePage) {
        let referencedPages = allNotes
            .flatMap(\.pages)
            .filter { $0.id != deletedPage.id }
        let referencedRelativePaths = Set(referencedPages.flatMap { page in
            var paths = ["\(StorageDirectory.drawings.rawValue)/\(page.drawingFileName)"]
            if let thumbnailFileName = page.thumbnailFileName {
                paths.append(thumbnailFileName)
            }
            paths.append(contentsOf: page.attachments.map(\.storedFileName))
            return paths
        })
        let referencedDrawingFileNames = Set(referencedPages.map(\.drawingFileName))

        target.relativePaths.subtract(referencedRelativePaths)
        target.drawingFileNames.subtract(referencedDrawingFileNames)
    }

    private func excludeStillReferencedStorage(from target: inout LocalStorageCleanupTarget, excluding deletedAttachment: Attachment) {
        let referencedRelativePaths = Set(
            allNotes
                .flatMap(\.pages)
                .flatMap(\.attachments)
                .filter { $0.id != deletedAttachment.id }
                .map(\.storedFileName)
        )

        target.relativePaths.subtract(referencedRelativePaths)
    }

    private func reportCleanup(_ report: LocalStorageCleanupReport) {
        guard report.hasFailures else { return }

        errorMessage = "The note was updated, but BeanNotes could not remove some local files."
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
        guard !urls.isEmpty else { return }

        isImportingFiles = true
        importProgress = 0
        importProgressMessage = "Preparing import..."

        defer {
            isImportingFiles = false
            importProgress = nil
            importProgressMessage = "Preparing import..."
        }

        let staging = importExportService.storage.beginImportStagingTransaction()
        var didSave = false

        do {
            try await Task.sleep(nanoseconds: 80_000_000)
            try Task.checkCancellation()

            var firstImportedPageID: UUID?
            let total = max(urls.count, 1)

            for (index, url) in urls.enumerated() {
                try Task.checkCancellation()
                importProgress = Double(index) / Double(total)
                importProgressMessage = "Importing \(url.lastPathComponent)..."
                await Task.yield()
                try Task.checkCancellation()

                if importExportService.importsAsAnnotatableDocument(url) {
                    let nextOrder = (note.pages.map(\.pageOrder).max() ?? -1) + 1
                    let imported = try await importExportService.importDocumentPages(
                        from: url,
                        into: note,
                        startingAt: nextOrder,
                        staging: staging
                    ) { fraction, message in
                        let itemProgress = fraction ?? 0
                        importProgress = (Double(index) + itemProgress) / Double(total)
                        importProgressMessage = message
                    }
                    try Task.checkCancellation()
                    firstImportedPageID = firstImportedPageID ?? imported.firstPage?.id
                } else if let page = selectedPage {
                    importProgressMessage = "Adding attachment..."
                    try Task.checkCancellation()
                    _ = try importExportService.importFile(from: url, into: page, staging: staging)
                }

                importProgress = Double(index + 1) / Double(total)
                await Task.yield()
            }

            try Task.checkCancellation()
            try modelContext.save()
            didSave = true
            try staging.commit()

            if let firstImportedPageID {
                selectedPageID = firstImportedPageID
            }
        } catch is CancellationError {
            if !didSave {
                modelContext.rollback()
                staging.rollback()
            }
        } catch {
            if !didSave {
                modelContext.rollback()
                staging.rollback()
            }
            errorMessage = error.localizedDescription
        }
    }

    private func cancelImport() {
        importProgressMessage = "Canceling import..."
        importTask?.cancel()
    }

    private func importImageData(_ data: Data, named name: String) async {
        guard let page = selectedPage else { return }

        let staging = importExportService.storage.beginImportStagingTransaction()
        var didSave = false

        do {
            _ = try await importExportService.importImageData(
                data,
                named: name,
                into: page,
                staging: staging
            )
            try modelContext.save()
            didSave = true
            try staging.commit()
        } catch {
            if !didSave {
                modelContext.rollback()
                staging.rollback()
            }
            errorMessage = error.localizedDescription
        }
    }

    private func applyBackgroundToAllPages(from sourcePage: NotePage) {
        let background = sourcePage.background
        let previousBackgrounds = note.pages.map {
            (page: $0, styleRaw: $0.backgroundStyleRaw, colorHex: $0.backgroundColorHex)
        }

        for page in note.pages {
            page.background = background
        }

        note.touch()
        if !saveEditorChanges("apply the background") {
            for previous in previousBackgrounds {
                previous.page.backgroundStyleRaw = previous.styleRaw
                previous.page.backgroundColorHex = previous.colorHex
            }
        }
    }

    private func pasteImage() {
        guard let image = UIPasteboard.general.image else {
            errorMessage = "The clipboard does not contain an image."
            return
        }

        Task {
            do {
                guard let data = await Task.detached(priority: .userInitiated, operation: {
                    image.pngData()
                }).value else {
                    throw ImportExportError.unsupportedImageData
                }

                await importImageData(data, named: "Pasted Image.png")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveNow() {
        drawingMetadataSaveTask?.cancel()
        drawingMetadataSaveTask = nil
        saveNowSignal += 1
        note.touch()
        saveEditorChanges("save the note")
    }

    private func prepareExport() {
        guard pendingExportPreparationID == nil else { return }

        drawingMetadataSaveTask?.cancel()
        drawingMetadataSaveTask = nil
        note.touch()
        guard saveEditorChanges("prepare the export") else { return }

        exportPreparationSignal &+= 1
        pendingExportPreparationID = exportPreparationSignal
    }

    private func handleExportPreparationCompleted(
        id: Int,
        result: Result<Void, Error>
    ) {
        guard pendingExportPreparationID == id else { return }
        pendingExportPreparationID = nil

        switch result {
        case .success:
            isShowingExport = true
        case .failure(let error):
            markDrawingSaveFailed()
            errorMessage = "BeanNotes could not prepare the drawing for export. \(error.localizedDescription)"
        }
    }

    private func scheduleDrawingMetadataSave() {
        drawingMetadataSaveTask?.cancel()
        isMetadataSavePending = true
        didMetadataSaveFail = false
        refreshAutosaveState()

        drawingMetadataSaveTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: drawingMetadataSaveDelayNanoseconds)
                try Task.checkCancellation()
                drawingMetadataSaveTask = nil
                _ = saveEditorChanges("save drawing metadata")
            } catch is CancellationError {
                // A newer drawing change or explicit save will own the pending metadata save.
            } catch {
                drawingMetadataSaveTask = nil
                didMetadataSaveFail = true
                isMetadataSavePending = false
                refreshAutosaveState()
            }
        }
    }

    private func updatePageBackground(_ page: NotePage, styleRaw: String? = nil, colorHex: String? = nil) {
        let previousStyleRaw = page.backgroundStyleRaw
        let previousColorHex = page.backgroundColorHex

        if let styleRaw {
            page.backgroundStyleRaw = styleRaw
        }

        if let colorHex {
            page.backgroundColorHex = colorHex
        }

        page.touch()

        if !saveEditorChanges("save the page background") {
            page.backgroundStyleRaw = previousStyleRaw
            page.backgroundColorHex = previousColorHex
        }
    }

    @discardableResult
    private func saveEditorChanges(_ action: String) -> Bool {
        isMetadataSavePending = true
        didMetadataSaveFail = false
        refreshAutosaveState()

        do {
            try modelContext.save()
            isMetadataSavePending = false
            refreshAutosaveState()
            return true
        } catch {
            isMetadataSavePending = false
            didMetadataSaveFail = true
            refreshAutosaveState()
            errorMessage = "BeanNotes could not \(action). \(error.localizedDescription)"
            return false
        }
    }

    private func markDrawingSaveStarted() {
        isDrawingSavePending = true
        didDrawingSaveFail = false
        refreshAutosaveState()
    }

    private func markDrawingSaveSucceeded() {
        isDrawingSavePending = false
        didDrawingSaveFail = false
        refreshAutosaveState()
    }

    private func markDrawingSaveFailed() {
        isDrawingSavePending = false
        didDrawingSaveFail = true
        refreshAutosaveState()
    }

    private func refreshAutosaveState() {
        if didDrawingSaveFail || didMetadataSaveFail {
            autosaveState = .failed
        } else if isDrawingSavePending || isMetadataSavePending {
            autosaveState = .saving
        } else {
            autosaveState = .saved
        }
    }
}

private enum AutosaveIndicatorState: Equatable {
    case saved
    case saving
    case failed

    var title: String {
        switch self {
        case .saved:
            "Saved"
        case .saving:
            "Saving..."
        case .failed:
            "Could not save"
        }
    }

    var systemImage: String {
        switch self {
        case .saved:
            "checkmark.circle.fill"
        case .saving:
            "arrow.triangle.2.circlepath"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .saved:
            .green
        case .saving:
            .blue
        case .failed:
            .red
        }
    }
}

private struct AutosaveIndicatorView: View {
    var state: AutosaveIndicatorState

    var body: some View {
        Label(state.title, systemImage: state.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.tint)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(state.tint.opacity(0.12), in: Capsule())
            .accessibilityLabel(state.title)
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

private struct PageReorderSheet: View {
    @Environment(\.dismiss) private var dismiss

    var pages: [NotePage]
    var selectedPageID: UUID?
    var movePages: (IndexSet, Int) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    HStack(spacing: 12) {
                        Image(systemName: selectedPageID == page.id ? "doc.fill" : "doc")
                            .foregroundStyle(selectedPageID == page.id ? .blue : .secondary)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Page \(index + 1)")
                                .font(.headline)
                            Text(page.background.style.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .accessibilityLabel("Page \(index + 1)")
                }
                .onMove(perform: movePages)
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder Pages")
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

private struct PageMoveTargetSheet: View {
    @Environment(\.dismiss) private var dismiss

    var page: NotePage
    var targetNotes: [NoteDocument]
    var movePage: (NoteDocument) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if targetNotes.isEmpty {
                    ContentUnavailableView("No Other Notes", systemImage: "doc.on.doc")
                } else {
                    List(targetNotes) { note in
                        Button {
                            movePage(note)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.blue)
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Note" : note.title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    Text(note.folder?.name ?? "No Folder")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text("\(note.sortedPages.count)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .accessibilityLabel("Move page to \(note.title)")
                    }
                }
            }
            .navigationTitle("Move Page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
