//
//  LibraryView.swift
//  BeanNotes
//

import SwiftData
import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.beanNotesTheme) private var beanNotesTheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @Query(sort: \NotebookFolder.name) private var folders: [NotebookFolder]
    @Query(sort: [
        SortDescriptor(\NoteDocument.createdAt, order: .reverse),
        SortDescriptor(\NoteDocument.id, order: .forward)
    ]) private var recentNotes: [NoteDocument]

    @AppStorage(NoteBackground.defaultStyleRawKey) private var defaultBackgroundStyleRaw = NoteBackgroundStyle.plain.rawValue
    @AppStorage(NoteBackground.defaultColorHexKey) private var defaultBackgroundColorHex = NoteBackground.defaultColorHex
    @AppStorage(PaperSize.storageKey) private var paperSizeRaw = PaperSize.defaultPaperSize.rawValue
    @AppStorage(CustomPaperSize.widthStorageKey) private var customPaperWidth = Double(CustomPaperSize.defaultDimensions.width)
    @AppStorage(CustomPaperSize.heightStorageKey) private var customPaperHeight = Double(CustomPaperSize.defaultDimensions.height)
    @AppStorage(AppTheme.storageKey) private var appThemeRaw = AppTheme.system.rawValue
    @AppStorage(BeanVisitPolicy.enabledKey) private var beanVisitsEnabled = true
    @AppStorage(BeanVisitPolicy.allowsInterruptionsKey) private var beanVisitsMayInterrupt = false
    @AppStorage(BeanVisitPolicy.focusReminderIntervalKey) private var beanFocusReminderInterval = BeanVisitPolicy.defaultFocusReminderInterval
    @AppStorage(BeanVisitPolicy.blueberryEnabledKey) private var blueberryVisitsEnabled = true
    @AppStorage(BeanVisitPolicy.blueberryAllowsInterruptionsKey) private var blueberryVisitsMayInterrupt = false
    @AppStorage(BeanVisitPolicy.blueberryFocusReminderIntervalKey) private var blueberryFocusReminderInterval = BeanVisitPolicy.defaultFocusReminderInterval

    @State private var selectedFolderID: UUID?
    @State private var selectedArchivedFolderID: UUID?
    @State private var isArchivedSelected = false
    @State private var isTrashSelected = false
    @State private var searchText = ""
    @State private var openNoteTabs: [NoteDocument] = []
    @State private var selectedOpenNoteID: UUID?
    @StateObject private var editorSessionStore = NoteEditorSessionStore()
    @State private var notesPendingTrash: [NoteDocument] = []
    @State private var notesPendingRestore: [NoteDocument] = []
    @State private var notePendingTrashRestoreAndOpen: NoteDocument?
    @State private var notePendingOpenAfterRestore: NoteDocument?
    @State private var notesPendingPermanentDeletion: [NoteDocument] = []
    @State private var isShowingFolderEditor = false
    @State private var isShowingDocumentImporter = false
    @State private var isImportingDocument = false
    @State private var importProgress: Double?
    @State private var importProgressMessage = "Preparing import..."
    @State private var importTask: Task<Void, Never>?
    @State private var folderBeingEdited: NotebookFolder?
    @State private var folderPendingDeletion: NotebookFolder?
    @State private var isShowingSettings = false
    @State private var errorMessage: String?
    @State private var searchIndexRefreshTask: Task<Void, Never>?
    @State private var folderCreatedToast: FolderCreatedToast?
    @State private var folderCreatedToastDismissTask: Task<Void, Never>?
    @State private var trashUndoToast: TrashUndoToast?
    @State private var trashUndoToastDismissTask: Task<Void, Never>?
    @State private var beanVisit: BeanVisit?
    @State private var beanVisitDismissTask: Task<Void, Never>?
    @State private var focusSessionStartedAt = Date()
    @State private var awayStartedAt: Date?
    @State private var visitScheduleToken = 0
    @State private var thumbnailRefreshVersions: [UUID: Int] = [:]
    @State private var exportSharePayload: ExportSharePayload?
    @State private var isExportingNotes = false
    @State private var exportProgress: Double?
    @State private var exportProgressMessage = "Preparing export..."
    @State private var exportTask: Task<Void, Never>?

    private var sortedFolders: [NotebookFolder] {
        folders.filter { !$0.isArchived }.sorted { lhs, rhs in
            let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if comparison == .orderedSame {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return comparison == .orderedAscending
        }
    }

    private var archivedFolders: [NotebookFolder] {
        folders.filter(\.isArchived).sorted(by: NotebookFolder.archivedOrder)
    }

    private var selectedFolder: NotebookFolder? {
        if let selectedFolderID,
           let folder = sortedFolders.first(where: { $0.id == selectedFolderID }) {
            return folder
        }

        return sortedFolders.first
    }

    private var selectedArchivedFolder: NotebookFolder? {
        guard let selectedArchivedFolderID else { return nil }
        return archivedFolders.first { $0.id == selectedArchivedFolderID }
    }

    private var trashedNotes: [NoteDocument] {
        recentNotes
            .filter(\.isInTrash)
            .sorted { lhs, rhs in
                let lhsDate = lhs.trashedAt ?? .distantPast
                let rhsDate = rhs.trashedAt ?? .distantPast
                if lhsDate == rhsDate {
                    return NoteDocument.libraryOrder(lhs, rhs)
                }
                return lhsDate > rhsDate
            }
    }

    private var activeRecentNotes: [NoteDocument] {
        recentNotes.filter { !$0.isInTrash && $0.folder?.isArchived != true }
    }

    private var nextTrashExpiration: Date? {
        trashedNotes.compactMap(\.trashExpirationDate).min()
    }

    private var trashPurgeTaskID: TimeInterval {
        nextTrashExpiration?.timeIntervalSinceReferenceDate ?? -1
    }

    private var visibleNotes: [NoteDocument] {
        let source: [NoteDocument]
        if isTrashSelected {
            source = trashedNotes
        } else if isArchivedSelected {
            source = selectedArchivedFolder?.activeSortedNotes ?? []
        } else {
            source = selectedFolder?.activeSortedNotes ?? Array(activeRecentNotes.prefix(24))
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return source }

        return source.filter { $0.matchesSearch(query) }
    }

    private var defaultNoteBackground: NoteBackground {
        NoteBackground.fromDefaults(styleRaw: defaultBackgroundStyleRaw, colorHex: defaultBackgroundColorHex)
    }

    private var defaultPageSize: CGSize {
        if paperSizeRaw == CustomPaperSize.selectionRawValue {
            return CustomPaperSize.dimensions(width: customPaperWidth, height: customPaperHeight)
        }

        return (PaperSize(rawValue: paperSizeRaw) ?? PaperSize.defaultPaperSize).dimensions
    }

    private var appTheme: AppTheme {
        AppTheme(rawValue: appThemeRaw) ?? .system
    }

    private var visitsEnabled: Bool {
        switch beanNotesTheme {
        case .standard:
            false
        case .bean:
            beanVisitsEnabled
        case .blueberry:
            blueberryVisitsEnabled
        }
    }

    private var visitsMayInterrupt: Bool {
        switch beanNotesTheme {
        case .standard:
            false
        case .bean:
            beanVisitsMayInterrupt
        case .blueberry:
            blueberryVisitsMayInterrupt
        }
    }

    private var focusReminderInterval: TimeInterval {
        switch beanNotesTheme {
        case .standard:
            BeanVisitPolicy.defaultFocusReminderInterval
        case .bean:
            beanFocusReminderInterval
        case .blueberry:
            blueberryFocusReminderInterval
        }
    }

    private var isShowingNoteEditor: Binding<Bool> {
        Binding(
            get: { selectedOpenNoteID != nil },
            set: { if !$0 { selectedOpenNoteID = nil } }
        )
    }

    private var isSafeForAutomaticBeanVisit: Bool {
        !isShowingFolderEditor
            && !isShowingSettings
            && !isShowingDocumentImporter
            && !isImportingDocument
            && folderCreatedToast == nil
            && trashUndoToast == nil
            && folderPendingDeletion == nil
            && notesPendingTrash.isEmpty
            && notesPendingRestore.isEmpty
            && notesPendingPermanentDeletion.isEmpty
            && !isExportingNotes
            && errorMessage == nil
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canScheduleBeanVisit: Bool {
        let processInfo = ProcessInfo.processInfo
        return BeanVisitPolicy.canSchedule(
            theme: beanNotesTheme,
            isEnabled: visitsEnabled,
            sceneIsActive: scenePhase == .active,
            isSafeSurface: isSafeForAutomaticBeanVisit,
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            thermalState: processInfo.thermalState,
            launchArguments: processInfo.arguments
        )
    }

    private var interruptibleVisitTaskID: String {
        "\(beanNotesTheme.rawValue)-\(canScheduleBeanVisit)-\(visitsMayInterrupt)-\(visitScheduleToken)"
    }

    private var focusVisitTaskID: String {
        "\(beanNotesTheme.rawValue)-\(canScheduleBeanVisit)-\(visitsMayInterrupt)-\(focusReminderInterval)-\(focusSessionStartedAt.timeIntervalSinceReferenceDate)"
    }

    var body: some View {
        NavigationSplitView {
            FolderListView(
                folders: sortedFolders,
                selectedFolderID: $selectedFolderID,
                isArchivedSelected: $isArchivedSelected,
                isTrashSelected: $isTrashSelected,
                searchText: $searchText,
                archivedFolderCount: archivedFolders.count,
                trashNoteCount: trashedNotes.count,
                createFolder: {
                    folderBeingEdited = nil
                    isShowingFolderEditor = true
                },
                renameFolder: { folder in
                    folderBeingEdited = folder
                    isShowingFolderEditor = true
                },
                archiveFolder: archiveFolder,
                deleteFolder: { folder in
                    folderPendingDeletion = folder
                },
                openArchived: {
                    selectedArchivedFolderID = nil
                    isArchivedSelected = true
                    isTrashSelected = false
                },
                openSettings: {
                    isShowingSettings = true
                }
            )
        } detail: {
            libraryDetail
        }
        .navigationSplitViewStyle(.balanced)
        .overlay {
            BeanVisitOverlayView(visit: beanVisit)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 12) {
                if let folderCreatedToast {
                    FolderCreatedToastView(toast: folderCreatedToast)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if let trashUndoToast {
                    TrashUndoToastView(toast: trashUndoToast, undo: undoTrashMove)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
            .zIndex(5)
        }
        .overlay {
            if isExportingNotes {
                BeanNotesProgressOverlay(
                    title: "Exporting",
                    message: exportProgressMessage,
                    progress: exportProgress,
                    cancel: cancelNotesExport
                )
            }
        }
        .onAppear {
            bootstrapLibrary()
        }
        .task(id: interruptibleVisitTaskID) {
            await runInterruptibleBeanVisitIfEligible()
        }
        .task(id: focusVisitTaskID) {
            await runFocusBeanVisitIfEligible()
        }
        .task(id: trashPurgeTaskID) {
            await waitForNextTrashExpiration()
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhaseChange(phase)
            if phase == .active {
                purgeExpiredTrash()
                absorbSharedInbox()
            }
        }
        .onChange(of: beanNotesTheme) { _, _ in
            hideBeanVisit(animated: false)
            focusSessionStartedAt = Date()
            visitScheduleToken += 1
        }
        .onChange(of: visitsEnabled) { _, isEnabled in
            if !isEnabled {
                hideBeanVisit(animated: false)
            }
        }
        .onChange(of: searchText) { _, query in
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            refreshSearchIndexesIfNeeded()
        }
        .fullScreenCover(isPresented: isShowingNoteEditor) {
            NoteTabbedEditorWorkspace(
                tabs: openNoteTabs,
                selectedNoteID: $selectedOpenNoteID,
                editorSessionStore: editorSessionStore,
                beanVisit: beanVisit,
                createNote: createNote,
                closeTab: closeNoteTab,
                backToLibrary: closeWorkspace
            )
            .onDisappear {
                refreshOpenNoteThumbnails()
            }
        }
        .sheet(isPresented: $isShowingFolderEditor) {
            FolderEditorView(
                title: folderBeingEdited == nil ? "New Folder" : "Edit Folder",
                initialName: folderBeingEdited?.name ?? "",
                initialColorHex: folderBeingEdited?.colorHex ?? beanNotesTheme.defaultFolderColorHex
            ) { name, colorHex in
                saveFolder(name: name, colorHex: colorHex)
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
                .environment(\.beanNotesTheme, beanNotesTheme)
                .preferredColorScheme(appTheme.colorScheme)
                .presentationBackground(beanNotesTheme.appBackground)
        }
        .sheet(item: $exportSharePayload) { payload in
            ActivityView(activityItems: payload.urls)
        }
        .fileImporter(
            isPresented: $isShowingDocumentImporter,
            allowedContentTypes: ImportExportService.supportedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                importTask?.cancel()
                importTask = Task { @MainActor in
                    await importDocumentsAsNotes(urls)
                    importTask = nil
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .alert("Delete Folder?", isPresented: Binding(
            get: { folderPendingDeletion != nil },
            set: { if !$0 { folderPendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                deletePendingFolder()
            }
            Button("Cancel", role: .cancel) {
                folderPendingDeletion = nil
            }
        } message: {
            Text("The folder will be deleted and its notes will be moved to Trash. Notes remain recoverable until their 30-day retention periods end.")
        }
        .alert(notesPendingTrash.count == 1 ? "Move Note to Trash?" : "Move Notes to Trash?", isPresented: Binding(
            get: { !notesPendingTrash.isEmpty },
            set: { if !$0 { notesPendingTrash = [] } }
        )) {
            Button("Move to Trash", role: .destructive) {
                movePendingNotesToTrash()
            }
            Button("Cancel", role: .cancel) {
                notesPendingTrash = []
            }
        } message: {
            Text("You can restore \(notesPendingTrash.count == 1 ? "this note" : "these notes") for 30 days before permanent deletion.")
        }
        .modifier(RestoreDestinationDialog(
            folders: sortedFolders,
            notes: $notesPendingRestore,
            restore: restoreNotes(_:to:)
        ))
        .modifier(TrashRestoreConfirmation(
            note: $notePendingTrashRestoreAndOpen,
            revertAndOpen: revertPendingNoteAndOpen
        ))
        .alert(
            notesPendingPermanentDeletion.count == 1 ? "Permanently Delete Note?" : "Permanently Delete Notes?",
            isPresented: Binding(
                get: { !notesPendingPermanentDeletion.isEmpty },
                set: { if !$0 { notesPendingPermanentDeletion = [] } }
            )
        ) {
            Button("Delete Permanently", role: .destructive) {
                permanentlyDeletePendingNotes()
            }
            Button("Cancel", role: .cancel) {
                notesPendingPermanentDeletion = []
            }
        } message: {
            Text("This permanently removes \(notesPendingPermanentDeletion.count == 1 ? "the note and its local files" : "the selected notes and their local files"). This cannot be undone.")
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

    @ViewBuilder
    private var libraryDetail: some View {
        if isArchivedSelected {
            if let selectedArchivedFolder {
                notesGrid(
                    folder: selectedArchivedFolder,
                    isTrash: false,
                    isArchived: true
                )
            } else {
                ArchivedFoldersView(
                    folders: archivedFolders,
                    searchText: searchText,
                    openFolder: { folder in
                        selectedArchivedFolderID = folder.id
                        searchText = ""
                    },
                    renameFolder: { folder in
                        folderBeingEdited = folder
                        isShowingFolderEditor = true
                    },
                    unarchiveFolder: unarchiveFolder,
                    deleteFolder: { folderPendingDeletion = $0 }
                )
            }
        } else {
            notesGrid(
                folder: isTrashSelected ? nil : selectedFolder,
                isTrash: isTrashSelected,
                isArchived: false
            )
        }
    }

    private func notesGrid(
        folder: NotebookFolder?,
        isTrash: Bool,
        isArchived: Bool
    ) -> some View {
        NotesCardGridView(
            folder: folder,
            notes: visibleNotes,
            searchText: searchText,
            isTrash: isTrash,
            isArchived: isArchived,
            backToArchivedFolders: { selectedArchivedFolderID = nil },
            createNote: createNote,
            importFiles: presentFileImporter,
            importPhotos: { photoItems in
                importTask?.cancel()
                importTask = Task { @MainActor in
                    await importPhotosAsNotes(photoItems)
                    importTask = nil
                }
            },
            isImportingDocument: isImportingDocument,
            importProgress: importProgress,
            importProgressMessage: importProgressMessage,
            cancelImport: cancelImport,
            openNote: requestToOpenNote,
            exportNotes: exportNotes,
            moveNotesToTrash: { notesPendingTrash = $0 },
            restoreNotes: restoreNotes,
            permanentlyDeleteNotes: { notesPendingPermanentDeletion = $0 },
            thumbnailRefreshVersions: thumbnailRefreshVersions
        )
    }

    private func bootstrapLibrary() {
        do {
            try LocalStorageService().prepareDirectories()
            let purgeResult = try NoteTrashService().purgeExpiredNotes(in: modelContext)
            reportCleanup(purgeResult.cleanupReport)

            if folders.isEmpty {
                let inbox = NotebookFolder(name: "Inbox", colorHex: beanNotesTheme.defaultFolderColorHex)
                modelContext.insert(inbox)
                try modelContext.save()
                selectedFolderID = inbox.id
                syncSharedFolderIndex(including: [inbox])
            } else if selectedFolderID == nil {
                selectedFolderID = selectedFolder?.id
                syncSharedFolderIndex()
            }

            absorbSharedInbox()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func absorbSharedInbox() {
        Task { @MainActor in
            do {
                try await ImportExportService().absorbSharedInbox(into: modelContext)
                syncSharedFolderIndex()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    private func saveFolder(name: String, colorHex: String) -> Bool {
        let changedFolder: NotebookFolder
        let createdToast: FolderCreatedToast?

        if let folderBeingEdited {
            folderBeingEdited.name = name
            folderBeingEdited.colorHex = colorHex
            folderBeingEdited.updatedAt = Date()
            changedFolder = folderBeingEdited
            createdToast = nil
        } else {
            let folder = NotebookFolder(name: name, colorHex: colorHex)
            modelContext.insert(folder)
            selectedFolderID = folder.id
            isArchivedSelected = false
            isTrashSelected = false
            changedFolder = folder
            createdToast = FolderCreatedToast(
                folderName: name,
                colorHex: colorHex,
                message: beanNotesTheme.folderCreatedBody(folderName: name)
            )
        }

        guard saveLibraryChanges("save the folder", rollbackOnFailure: true) else {
            return false
        }

        syncSharedFolderIndex(including: [changedFolder])
        folderBeingEdited = nil
        if let createdToast {
            showFolderCreatedToast(createdToast)
            LocalNotificationService.shared.notifyFolderCreated(named: createdToast.folderName)
        }
        return true
    }

    private func archiveFolder(_ folder: NotebookFolder) {
        let wasSelected = selectedFolderID == folder.id
        let nextFolderID = sortedFolders.first { $0.id != folder.id }?.id

        do {
            guard try FolderArchiveService().archive(folder, in: modelContext) else { return }
            if wasSelected {
                selectedFolderID = nextFolderID
            }
            syncSharedFolderIndex(excluding: [folder.id])
        } catch {
            errorMessage = "BeanNotes could not archive the folder. \(error.localizedDescription)"
        }
    }

    private func unarchiveFolder(_ folder: NotebookFolder) {
        do {
            guard try FolderArchiveService().unarchive(folder, in: modelContext) else { return }
            selectedArchivedFolderID = nil
            selectedFolderID = folder.id
            isArchivedSelected = false
            isTrashSelected = false
            syncSharedFolderIndex(including: [folder])
        } catch {
            errorMessage = "BeanNotes could not unarchive the folder. \(error.localizedDescription)"
        }
    }

    private func showFolderCreatedToast(_ toast: FolderCreatedToast) {
        folderCreatedToastDismissTask?.cancel()

        withAnimation(.snappy(duration: 0.22)) {
            folderCreatedToast = toast
        }

        folderCreatedToastDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }

            withAnimation(.snappy(duration: 0.2)) {
                if folderCreatedToast?.id == toast.id {
                    folderCreatedToast = nil
                }
            }
        }
    }

    @MainActor
    private func runInterruptibleBeanVisitIfEligible() async {
        guard visitsMayInterrupt, canScheduleBeanVisit else { return }

        let now = Date()
        let scheduledTheme = beanNotesTheme
        let cooldownRemaining = BeanVisitPolicy.cooldownRemaining(for: scheduledTheme, now: now)
        let delay = max(BeanVisitPolicy.interruptibleInitialDelay, cooldownRemaining)

        do {
            try await Task.sleep(nanoseconds: BeanVisitPolicy.nanoseconds(for: delay))
            guard !Task.isCancelled,
                  beanNotesTheme == scheduledTheme,
                  visitsMayInterrupt,
                  canScheduleBeanVisit else { return }

            showBeanVisit(reason: .friendly)
        } catch {
            // Cancellation is expected when the app moves to another surface.
        }
    }

    @MainActor
    private func runFocusBeanVisitIfEligible() async {
        guard !visitsMayInterrupt, canScheduleBeanVisit else { return }

        let scheduledTheme = beanNotesTheme
        let interval = BeanVisitPolicy.normalizedFocusReminderInterval(focusReminderInterval)
        let focusStartedAt = focusSessionStartedAt
        let elapsed = Date().timeIntervalSince(focusStartedAt)
        let delay = max(0, interval - elapsed)

        do {
            try await Task.sleep(nanoseconds: BeanVisitPolicy.nanoseconds(for: delay))
            guard !Task.isCancelled,
                  beanNotesTheme == scheduledTheme,
                  !visitsMayInterrupt,
                  canScheduleBeanVisit,
                  focusSessionStartedAt == focusStartedAt else { return }

            let focusDuration = Date().timeIntervalSince(focusStartedAt)
            guard BeanVisitPolicy.shouldVisitAfterFocusing(
                focusDuration: focusDuration,
                reminderInterval: interval,
                allowsInterruptions: visitsMayInterrupt
            ) else { return }

            showBeanVisit(reason: .focusBreak)
        } catch {
            // Cancellation is expected when focus is interrupted by an app transition.
        }
    }

    @MainActor
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        let now = Date()

        switch phase {
        case .active:
            let awayDuration = awayStartedAt.map { now.timeIntervalSince($0) } ?? 0
            awayStartedAt = nil
            focusSessionStartedAt = now

            guard BeanVisitPolicy.shouldVisitAfterReturning(
                awayDuration: awayDuration,
                allowsInterruptions: visitsMayInterrupt
            ), canScheduleBeanVisit else { return }

            showBeanVisit(reason: .returnFromBreak)
        case .inactive, .background:
            awayStartedAt = awayStartedAt ?? now
        @unknown default:
            break
        }
    }

    @MainActor
    private func showBeanVisit(reason: BeanVisitPolicy.VisitReason) {
        guard beanVisit == nil,
              canScheduleBeanVisit,
              BeanVisitPolicy.cooldownHasElapsed(for: beanNotesTheme, now: Date()) else { return }

        beanVisitDismissTask?.cancel()
        let visit = BeanVisit.make(reason: reason, theme: beanNotesTheme)
        BeanVisitPolicy.recordVisit(for: beanNotesTheme)

        withAnimation(beanVisitAnimation) {
            beanVisit = visit
        }

        beanVisitDismissTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: BeanVisitPolicy.displayDurationNanoseconds)
                guard !Task.isCancelled, beanVisit?.id == visit.id else { return }
                hideBeanVisit(animated: true)
            } catch {
                // The next visit replaces this dismissal task.
            }
        }
    }

    @MainActor
    private func hideBeanVisit(animated: Bool) {
        beanVisitDismissTask?.cancel()
        beanVisitDismissTask = nil
        guard beanVisit != nil else { return }

        if animated {
            withAnimation(beanVisitAnimation) {
                beanVisit = nil
            }
        } else {
            beanVisit = nil
        }

        if visitsMayInterrupt {
            visitScheduleToken += 1
        } else {
            focusSessionStartedAt = Date()
        }
    }

    private var beanVisitAnimation: Animation {
        accessibilityReduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(response: 0.42, dampingFraction: 0.86)
    }

    private func createNote() {
        do {
            let folder = try folderForNewContent()
            let now = Date()
            let note = NoteDocument(title: "Untitled Note", createdAt: now, updatedAt: now)
            let page = NotePage(
                pageOrder: 0,
                background: defaultNoteBackground,
                width: defaultPageSize.width,
                height: defaultPageSize.height,
                createdAt: now,
                updatedAt: now
            )

            modelContext.insert(note)
            modelContext.insert(page)

            folder.notes.append(note)
            note.pages.append(page)
            folder.updatedAt = now
            selectedFolderID = folder.id

            try modelContext.save()
            syncSharedFolderIndex(including: [folder])
            openNote(note)
        } catch {
            errorMessage = "BeanNotes could not create a new note. \(error.localizedDescription)"
        }
    }

    private func folderForNewContent() throws -> NotebookFolder {
        if let selectedFolder {
            return selectedFolder
        }

        if let fallbackFolder = sortedFolders.first {
            selectedFolderID = fallbackFolder.id
            return fallbackFolder
        }

        let inbox = NotebookFolder(name: "Inbox", colorHex: beanNotesTheme.defaultFolderColorHex)
        modelContext.insert(inbox)
        selectedFolderID = inbox.id
        return inbox
    }

    private func presentFileImporter(_: LibraryImportSource) {
        isShowingDocumentImporter = true
    }

    private func cancelImport() {
        importProgressMessage = "Canceling import..."
        importTask?.cancel()
    }

    private func importDocumentsAsNotes(_ urls: [URL]) async {
        guard let selectedFolder else { return }

        isImportingDocument = true
        importProgress = 0
        importProgressMessage = "Preparing import..."

        defer {
            isImportingDocument = false
            importProgress = nil
            importProgressMessage = "Preparing import..."
        }

        let service = ImportExportService()
        let staging = service.storage.beginImportStagingTransaction()
        var didSave = false

        do {
            try await Task.sleep(nanoseconds: 80_000_000)
            try Task.checkCancellation()

            var firstImportedNote: NoteDocument?
            let total = max(urls.count, 1)

            for (index, url) in urls.enumerated() {
                try Task.checkCancellation()
                let displayName = url.deletingPathExtension().lastPathComponent
                importProgressMessage = "Importing \(displayName)..."
                importProgress = Double(index) / Double(total)
                await Task.yield()
                try Task.checkCancellation()

                let imported = try await service.importDocumentAsNote(
                    from: url,
                    into: selectedFolder,
                    staging: staging
                ) { fraction, message in
                    let itemProgress = fraction ?? 0
                    importProgress = (Double(index) + itemProgress) / Double(total)
                    importProgressMessage = message
                }
                try Task.checkCancellation()
                firstImportedNote = firstImportedNote ?? imported.note
                importProgress = Double(index + 1) / Double(total)
                await Task.yield()
            }

            try Task.checkCancellation()
            try modelContext.save()
            didSave = true
            try staging.commit()
            syncSharedFolderIndex(including: [selectedFolder])

            if let firstImportedNote {
                openNote(firstImportedNote)
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

    private func importPhotosAsNotes(_ photoItems: [PhotosPickerItem]) async {
        guard let selectedFolder, !photoItems.isEmpty else { return }

        isImportingDocument = true
        importProgress = 0
        importProgressMessage = "Preparing photos..."

        defer {
            isImportingDocument = false
            importProgress = nil
            importProgressMessage = "Preparing import..."
        }

        let service = ImportExportService()
        let staging = service.storage.beginImportStagingTransaction()
        var didSave = false

        do {
            try await Task.sleep(nanoseconds: 80_000_000)
            try Task.checkCancellation()

            var firstImportedNote: NoteDocument?
            let total = max(photoItems.count, 1)

            for (index, item) in photoItems.enumerated() {
                try Task.checkCancellation()
                importProgress = Double(index) / Double(total)
                importProgressMessage = "Importing photo \(index + 1) of \(total)..."
                await Task.yield()
                try Task.checkCancellation()

                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw ImportExportError.unsupportedImageData
                }
                try Task.checkCancellation()

                let title = photoItems.count == 1 ? "Photo" : "Photo \(index + 1)"
                let imported = try await service.importImageDataAsNote(
                    data,
                    named: "\(title).jpg",
                    into: selectedFolder,
                    staging: staging
                )
                firstImportedNote = firstImportedNote ?? imported.note
                importProgress = Double(index + 1) / Double(total)
            }

            try Task.checkCancellation()
            try modelContext.save()
            didSave = true
            try staging.commit()
            syncSharedFolderIndex(including: [selectedFolder])

            if let firstImportedNote {
                openNote(firstImportedNote)
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

    private func movePendingNotesToTrash() {
        let notes = notesPendingTrash
        notesPendingTrash = []

        do {
            let movedNoteIDs = try NoteTrashService().moveToTrash(notes, in: modelContext)
            closeNoteTabs(movedNoteIDs)
            let movedNotes = notes.filter { movedNoteIDs.contains($0.id) }
            if !movedNotes.isEmpty {
                showTrashUndoToast(for: movedNotes)
            }
            syncSharedFolderIndex()
        } catch {
            errorMessage = "BeanNotes could not move the selected notes to Trash. \(error.localizedDescription)"
        }
    }

    private func showTrashUndoToast(for notes: [NoteDocument]) {
        trashUndoToastDismissTask?.cancel()
        let toast = TrashUndoToast(notes: notes)

        withAnimation(.snappy(duration: 0.22)) {
            trashUndoToast = toast
        }

        trashUndoToastDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            dismissTrashUndoToast(id: toast.id)
        }
    }

    private func undoTrashMove() {
        guard let toast = trashUndoToast else { return }
        trashUndoToastDismissTask?.cancel()

        do {
            try NoteTrashService().undoMoveToTrash(toast.notes, in: modelContext)
            syncSharedFolderIndex()
            dismissTrashUndoToast(id: toast.id)
        } catch {
            errorMessage = "BeanNotes could not undo moving the selected notes to Trash. \(error.localizedDescription)"
        }
    }

    private func dismissTrashUndoToast(id: UUID) {
        withAnimation(.snappy(duration: 0.2)) {
            if trashUndoToast?.id == id {
                trashUndoToast = nil
            }
        }
    }

    private func restoreNotes(_ notes: [NoteDocument]) {
        let notesWithPreviousFolders = notes.filter { $0.isInTrash && $0.folder != nil }
        let notesNeedingDestination = notes.filter { $0.isInTrash && $0.folder == nil }

        guard !notesWithPreviousFolders.isEmpty || !notesNeedingDestination.isEmpty else { return }

        if !notesWithPreviousFolders.isEmpty {
            do {
                try NoteTrashService().undoMoveToTrash(notesWithPreviousFolders, in: modelContext)
            } catch {
                errorMessage = "BeanNotes could not revert the selected notes. \(error.localizedDescription)"
                return
            }
        }

        if notesNeedingDestination.isEmpty {
            syncSharedFolderIndex()
            openRestoredNoteIfNeeded(in: notesWithPreviousFolders)
        } else {
            notesPendingRestore = notesNeedingDestination
        }
    }

    private func restoreNotes(_ notes: [NoteDocument], to folder: NotebookFolder) {
        do {
            try NoteTrashService().restore(notes, to: folder, in: modelContext)
            syncSharedFolderIndex(including: [folder])
            openRestoredNoteIfNeeded(in: notes)
        } catch {
            errorMessage = "BeanNotes could not restore the selected notes. \(error.localizedDescription)"
        }
    }

    private func requestToOpenNote(_ note: NoteDocument) {
        if note.isInTrash {
            notePendingTrashRestoreAndOpen = note
        } else {
            openNote(note)
        }
    }

    private func revertPendingNoteAndOpen() {
        guard let note = notePendingTrashRestoreAndOpen else { return }
        notePendingTrashRestoreAndOpen = nil
        notePendingOpenAfterRestore = note
        restoreNotes([note])
    }

    private func openRestoredNoteIfNeeded(in restoredNotes: [NoteDocument]) {
        guard let note = notePendingOpenAfterRestore,
              restoredNotes.contains(where: { $0.id == note.id }) else { return }

        notePendingOpenAfterRestore = nil
        openNote(note)
    }

    private func permanentlyDeletePendingNotes() {
        let notes = notesPendingPermanentDeletion
        notesPendingPermanentDeletion = []

        do {
            let result = try NoteTrashService().permanentlyDelete(notes, in: modelContext)
            closeNoteTabs(result.deletedNoteIDs)
            reportCleanup(result.cleanupReport)
            syncSharedFolderIndex()
        } catch {
            errorMessage = "BeanNotes could not permanently delete the selected notes. \(error.localizedDescription)"
        }
    }

    private func purgeExpiredTrash() {
        do {
            let result = try NoteTrashService().purgeExpiredNotes(in: modelContext)
            closeNoteTabs(result.deletedNoteIDs)
            reportCleanup(result.cleanupReport)
            syncSharedFolderIndex()
        } catch {
            errorMessage = "BeanNotes could not finish cleaning up expired Trash items. \(error.localizedDescription)"
        }
    }

    private func waitForNextTrashExpiration() async {
        guard let nextTrashExpiration else { return }
        let delay = max(0, nextTrashExpiration.timeIntervalSinceNow)

        do {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            purgeExpiredTrash()
        } catch {
            // The task is expected to be canceled when the next expiration changes.
        }
    }

    private func closeNoteTabs(_ noteIDs: Set<UUID>) {
        for noteID in noteIDs {
            editorSessionStore.removeSession(for: noteID)
            closeNoteTab(noteID)
        }
    }

    private func deletePendingFolder() {
        guard let folder = folderPendingDeletion else { return }
        trashUndoToastDismissTask?.cancel()
        trashUndoToast = nil
        let deletingFolderID = folder.id
        let deletingSelectedFolder = folder.id == selectedFolderID
        let deletingSelectedArchivedFolder = folder.id == selectedArchivedFolderID
        let nextSelectedFolderID = sortedFolders.first { $0.id != deletingFolderID }?.id
        folderPendingDeletion = nil

        do {
            let movedNoteIDs = try NoteTrashService().moveContentsToTrashAndDelete(
                folder,
                in: modelContext
            )
            closeNoteTabs(movedNoteIDs)

            if deletingSelectedFolder {
                selectedFolderID = nextSelectedFolderID
            }
            if deletingSelectedArchivedFolder {
                selectedArchivedFolderID = nil
            }

            syncSharedFolderIndex(excluding: [deletingFolderID])
        } catch {
            errorMessage = "BeanNotes could not delete the folder. \(error.localizedDescription)"
        }
    }

    private func reportCleanup(_ report: LocalStorageCleanupReport) {
        guard report.hasFailures else { return }
        errorMessage = "The notes were deleted, but BeanNotes could not remove \(report.failedRelativePaths.count) local file(s)."
    }

    private func exportNotes(_ notes: [NoteDocument], format: ExportFormat) {
        guard !isExportingNotes else { return }

        var seenIDs: Set<UUID> = []
        let notes = notes.filter { seenIDs.insert($0.id).inserted }
        guard !notes.isEmpty else { return }

        isExportingNotes = true
        exportProgress = 0
        exportProgressMessage = "Preparing export..."
        exportTask?.cancel()

        exportTask = Task { @MainActor in
            let service = ImportExportService()
            var exportedURLs: [URL] = []

            defer {
                isExportingNotes = false
                exportProgress = nil
                exportProgressMessage = "Preparing export..."
                exportTask = nil
            }

            do {
                let total = max(notes.count, 1)
                for (index, note) in notes.enumerated() {
                    try Task.checkCancellation()
                    let noteNumber = index + 1
                    exportProgress = Double(index) / Double(total)
                    exportProgressMessage = "Exporting note \(noteNumber) of \(total)..."

                    let noteURLs = try await service.exportNoteForSharing(note, format: format) { fraction, message in
                        let noteProgress = fraction ?? 0
                        exportProgress = (Double(index) + noteProgress) / Double(total)
                        exportProgressMessage = total == 1 ? message : "\(message) Note \(noteNumber) of \(total)."
                    }
                    exportedURLs.append(contentsOf: noteURLs)
                    await Task.yield()
                }

                try Task.checkCancellation()
                guard !exportedURLs.isEmpty else { throw ImportExportError.exportFailed }
                exportProgress = 1
                exportProgressMessage = "Opening share sheet..."
                await Task.yield()
                try Task.checkCancellation()
                exportSharePayload = ExportSharePayload(urls: exportedURLs)
            } catch is CancellationError {
                service.removeTemporaryExportFiles(exportedURLs)
            } catch {
                service.removeTemporaryExportFiles(exportedURLs)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancelNotesExport() {
        exportProgressMessage = "Canceling export..."
        exportTask?.cancel()
    }

    @discardableResult
    private func saveLibraryChanges(_ action: String, rollbackOnFailure: Bool = false) -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            if rollbackOnFailure {
                modelContext.rollback()
            }
            errorMessage = "BeanNotes could not \(action). \(error.localizedDescription)"
            return false
        }
    }

    private func syncSharedFolderIndex(
        including extraFolders: [NotebookFolder] = [],
        excluding excludedFolderIDs: Set<UUID> = []
    ) {
        var foldersByID = Dictionary(uniqueKeysWithValues: sortedFolders.map { ($0.id, $0) })

        for folder in extraFolders {
            foldersByID[folder.id] = folder
        }

        let folders = foldersByID.values.filter {
            !$0.isArchived && !excludedFolderIDs.contains($0.id)
        }
        try? ImportExportService().writeSharedFolderIndex(folders: Array(folders))
    }

    private func openNote(_ note: NoteDocument) {
        if !openNoteTabs.contains(where: { $0.id == note.id }) {
            openNoteTabs.append(note)
        }

        selectedOpenNoteID = note.id
    }

    private func closeWorkspace() {
        selectedOpenNoteID = nil
    }

    private func closeNoteTab(_ noteID: UUID) {
        guard let index = openNoteTabs.firstIndex(where: { $0.id == noteID }) else { return }

        openNoteTabs.remove(at: index)

        if selectedOpenNoteID == noteID {
            if openNoteTabs.isEmpty {
                selectedOpenNoteID = nil
            } else {
                let nextIndex = min(index, openNoteTabs.count - 1)
                selectedOpenNoteID = openNoteTabs[nextIndex].id
            }
        }
    }

    private func refreshThumbnail(for note: NoteDocument) async {
        guard let page = note.sortedPages.first else { return }

        do {
            _ = try await ThumbnailService().generateThumbnailInBackground(
                for: page,
                theme: .currentFromDefaults(),
                maxDimension: 420
            )
            try modelContext.save()
            thumbnailRefreshVersions[page.id, default: 0] &+= 1
        } catch is CancellationError {
            // A concurrent theme change will let the newly visible note card
            // regenerate the appearance-specific thumbnail.
        } catch {
            errorMessage = error.localizedDescription
        }

        do {
            try await NoteSearchIndexService().indexIfNeeded(note: note, modelContext: modelContext)
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshOpenNoteThumbnails() {
        let notes = openNoteTabs

        Task { @MainActor in
            for note in notes {
                await refreshThumbnail(for: note)
                await Task.yield()
            }
        }
    }

    private func refreshSearchIndexesIfNeeded() {
        searchIndexRefreshTask?.cancel()

        let notes = Array(activeRecentNotes.prefix(8))
        guard !notes.isEmpty else { return }

        searchIndexRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let service = NoteSearchIndexService()

            for note in notes {
                guard !Task.isCancelled else { return }

                do {
                    try await service.indexIfNeeded(note: note, modelContext: modelContext)
                } catch {
                    guard !Task.isCancelled else { return }
                    errorMessage = "BeanNotes could not refresh searchable text. \(error.localizedDescription)"
                    return
                }

                await Task.yield()
            }
        }
    }
}

private struct NoteTabbedEditorWorkspace: View {
    @Environment(\.beanNotesTheme) private var beanNotesTheme

    var tabs: [NoteDocument]
    @Binding var selectedNoteID: UUID?
    @ObservedObject var editorSessionStore: NoteEditorSessionStore
    var beanVisit: BeanVisit?
    var createNote: () -> Void
    var closeTab: (UUID) -> Void
    var backToLibrary: () -> Void

    @State private var isFocusModeEnabled = false

    private var selectedNote: NoteDocument? {
        guard let selectedNoteID else { return tabs.first }
        return tabs.first { $0.id == selectedNoteID } ?? tabs.first
    }

    var body: some View {
        if let selectedNote {
            VStack(spacing: 0) {
                if !isFocusModeEnabled {
                    NoteEditorTabBar(
                        tabs: tabs,
                        selectedNoteID: selectedNote.id,
                        selectTab: selectTab,
                        closeTab: { noteID in
                            editorSessionStore.removeSession(for: noteID)
                            closeTab(noteID)
                        },
                        backToLibrary: backToLibrary
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))

                    Divider()
                        .transition(.opacity)
                }

                NavigationStack {
                    NoteEditorView(
                        note: selectedNote,
                        isWorkspaceFocusModeEnabled: $isFocusModeEnabled,
                        editorSession: editorSessionStore.session(for: selectedNote.id)
                    )
                        .id(selectedNote.id)
                }
            }
            .background(beanNotesTheme.appBackground.ignoresSafeArea())
            .tint(beanNotesTheme.accentColor)
            .overlay {
                BeanVisitOverlayView(visit: beanVisit)
            }
            .animation(.snappy(duration: 0.18), value: isFocusModeEnabled)
            .onChange(of: selectedNote.id) { _, _ in
                isFocusModeEnabled = false
            }
            .background {
                HiddenKeyboardShortcutButton(title: "New Note", key: "n", action: createNote)
            }
        } else {
            ContentUnavailableView("No Open Notes", systemImage: "note.text")
        }
    }

    private func selectTab(_ noteID: UUID) {
        guard noteID != selectedNoteID else { return }

        isFocusModeEnabled = false
        selectedNoteID = noteID
    }
}

private struct NoteEditorTabBar: View {
    @Environment(\.beanNotesTheme) private var beanNotesTheme

    var tabs: [NoteDocument]
    var selectedNoteID: UUID
    var selectTab: (UUID) -> Void
    var closeTab: (UUID) -> Void
    var backToLibrary: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: backToLibrary) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.headline.weight(.semibold))

                    if beanNotesTheme.supportsFriendlyVisits {
                        ThemeAvatarView(theme: beanNotesTheme, size: 30)
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to library")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tabs) { note in
                        tabButton(for: note)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .background(.regularMaterial)
    }

    private func tabButton(for note: NoteDocument) -> some View {
        let isSelected = selectedNoteID == note.id
        let folderColor = Color(hex: note.folder?.colorHex ?? beanNotesTheme.defaultFolderColorHex)
        let tabColorOpacity = isSelected ? 0.20 : 0.08
        let tabBorderOpacity = isSelected ? 0.36 : 0.16

        return HStack(spacing: 8) {
            Button {
                selectTab(note.id)
            } label: {
                Text(note.title.isEmpty ? "Untitled Note" : note.title)
                    .font(.subheadline.weight(isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 180, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(note.title.isEmpty ? "Untitled Note" : note.title)

            Button {
                closeTab(note.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(note.title.isEmpty ? "Untitled Note" : note.title)")
        }
        .foregroundStyle(isSelected ? .primary : .secondary)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .frame(height: 38)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(folderColor.opacity(tabColorOpacity))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(folderColor.opacity(tabBorderOpacity), lineWidth: 1)
        }
    }
}

private struct FolderCreatedToast: Identifiable, Equatable {
    let id = UUID()
    var folderName: String
    var colorHex: String
    var message: String
}

private struct FolderCreatedToastView: View {
    @Environment(\.beanNotesTheme) private var beanNotesTheme

    var toast: FolderCreatedToast

    var body: some View {
        HStack(spacing: 12) {
            if let brandImageName = beanNotesTheme.brandImageName {
                Image(brandImageName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 38, height: 38)
                    .clipShape(Circle())
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(Color(hex: toast.colorHex))
                            .frame(width: 13, height: 13)
                            .overlay {
                                Circle()
                                    .stroke(beanNotesTheme.cardBackground, lineWidth: 2)
                            }
                    }
                    .accessibilityHidden(true)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(hex: toast.colorHex))

                    Image(systemName: "folder.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                }
                .frame(width: 36, height: 30)
                .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(beanNotesTheme.folderReadyTitle)
                    .font(.subheadline.weight(.semibold))

                Text(toast.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(beanNotesTheme.accentColor.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Folder created. \(toast.message)")
    }
}

private struct TrashUndoToast: Identifiable {
    let id = UUID()
    var notes: [NoteDocument]

    var message: String {
        notes.count == 1 ? "Note moved to Trash" : "\(notes.count) notes moved to Trash"
    }
}

private struct TrashUndoToastView: View {
    @Environment(\.beanNotesTheme) private var beanNotesTheme

    var toast: TrashUndoToast
    var undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .font(.headline)
                .foregroundStyle(beanNotesTheme.accentColor)
                .accessibilityHidden(true)

            Text(toast.message)
                .font(.subheadline.weight(.semibold))

            Spacer(minLength: 8)

            Button("Undo", action: undo)
                .font(.subheadline.weight(.bold))
                .buttonStyle(.bordered)
                .accessibilityHint("Returns the notes to their previous folders")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(beanNotesTheme.accentColor.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
    }
}

private struct RestoreDestinationDialog: ViewModifier {
    var folders: [NotebookFolder]
    @Binding var notes: [NoteDocument]
    var restore: ([NoteDocument], NotebookFolder) -> Void

    func body(content: Content) -> some View {
        let notesToRestore = notes

        content.confirmationDialog(
            notes.count == 1 ? "Restore Note" : "Restore Notes",
            isPresented: Binding(
                get: { !notes.isEmpty },
                set: { if !$0 { notes = [] } }
            ),
            titleVisibility: .visible
        ) {
            ForEach(folders) { folder in
                Button {
                    notes = []
                    restore(notesToRestore, folder)
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color(hex: folder.colorHex))
                            .frame(width: 14, height: 14)
                            .overlay {
                                Circle()
                                    .stroke(Color.primary.opacity(0.16), lineWidth: 1)
                            }

                        Text(folder.name)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                notes = []
            }
        } message: {
            if folders.isEmpty {
                Text("Create a folder before restoring notes.")
            } else {
                Text("Choose a folder for \(notes.count == 1 ? "this note" : "these notes").")
            }
        }
    }
}

private struct TrashRestoreConfirmation: ViewModifier {
    @Binding var note: NoteDocument?
    var revertAndOpen: () -> Void

    func body(content: Content) -> some View {
        content.alert("Revert Note?", isPresented: Binding(
            get: { note != nil },
            set: { if !$0 { note = nil } }
        )) {
            Button("Revert and Open") {
                revertAndOpen()
            }
            Button("Cancel", role: .cancel) {
                note = nil
            }
        } message: {
            Text("This note must be reverted from Trash before it can be opened.")
        }
    }
}

private enum LibraryImportSource {
    case files
    case googleDrive
    case oneDrive

    var systemImage: String {
        switch self {
        case .files:
            "folder"
        case .googleDrive:
            "externaldrive"
        case .oneDrive:
            "cloud"
        }
    }
}

private struct NotesCardGridView: View {
    @Environment(\.beanNotesTheme) private var beanNotesTheme

    var folder: NotebookFolder?
    var notes: [NoteDocument]
    var searchText: String
    var isTrash: Bool
    var isArchived: Bool
    var backToArchivedFolders: () -> Void
    var createNote: () -> Void
    var importFiles: (LibraryImportSource) -> Void
    var importPhotos: ([PhotosPickerItem]) -> Void
    var isImportingDocument: Bool
    var importProgress: Double?
    var importProgressMessage: String
    var cancelImport: () -> Void
    var openNote: (NoteDocument) -> Void
    var exportNotes: ([NoteDocument], ExportFormat) -> Void
    var moveNotesToTrash: ([NoteDocument]) -> Void
    var restoreNotes: ([NoteDocument]) -> Void
    var permanentlyDeleteNotes: ([NoteDocument]) -> Void
    var thumbnailRefreshVersions: [UUID: Int]

    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isSelecting = false
    @State private var selectedNoteIDs: Set<UUID> = []

    private var selectedNotes: [NoteDocument] {
        notes.filter { selectedNoteIDs.contains($0.id) }
    }

    private let columns = [
        GridItem(
            .adaptive(minimum: NoteCardLayout.minWidth, maximum: NoteCardLayout.maxWidth),
            spacing: 26,
            alignment: .top
        )
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header

                if isSelecting {
                    selectionActions
                }

                if notes.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                        ForEach(notes) { note in
                            NoteCardView(
                                note: note,
                                isTrash: isTrash,
                                isSelecting: isSelecting,
                                isSelected: selectedNoteIDs.contains(note.id),
                                openNote: {
                                    if isSelecting {
                                        toggleSelection(note)
                                    } else {
                                        openNote(note)
                                    }
                                },
                                moveToTrash: { moveNotesToTrash([note]) },
                                restore: { restoreNotes([note]) },
                                permanentlyDelete: { permanentlyDeleteNotes([note]) },
                                thumbnailRefreshVersion: note.sortedPages.first.map {
                                    thumbnailRefreshVersions[$0.id] ?? 0
                                } ?? 0
                            )
                            .frame(height: NoteCardLayout.totalHeight)
                        }
                    }
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 38)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            if isImportingDocument {
                BeanNotesProgressOverlay(
                    title: "Importing",
                    message: importProgressMessage,
                    progress: importProgress,
                    cancel: cancelImport
                )
            }
        }
        .onChange(of: selectedPhotoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            importPhotos(newItems)
            selectedPhotoItems = []
        }
        .onChange(of: notes.map(\.id)) { _, visibleNoteIDs in
            selectedNoteIDs.formIntersection(visibleNoteIDs)
            if visibleNoteIDs.isEmpty {
                isSelecting = false
            }
        }
        .onChange(of: isTrash) { _, _ in
            endSelection()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            if isArchived {
                Button(action: backToArchivedFolders) {
                    Image(systemName: "chevron.left")
                        .font(.headline.weight(.bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityLabel("Back to archived folders")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(isTrash ? "Trash" : (folder?.name ?? "Recent Notes"))
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text("\(notes.count) \(notes.count == 1 ? "note" : "notes")")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isSelecting {
                Button("Done") {
                    endSelection()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityLabel("Finish selecting notes")
            } else {
                HStack(spacing: 8) {
                    if beanNotesTheme.supportsFriendlyVisits {
                        ThemeAvatarView(theme: beanNotesTheme, size: 26)
                    } else {
                        Image(systemName: beanNotesTheme.symbolName)
                            .font(.subheadline.weight(.semibold))
                    }

                    Text(beanNotesTheme.label)
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(beanNotesTheme.accentColor)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(beanNotesTheme.cardBackground, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(beanNotesTheme.accentColor.opacity(0.18), lineWidth: 1)
                }
                .accessibilityLabel("\(beanNotesTheme.label) theme")

                if !notes.isEmpty {
                    Button {
                        isSelecting = true
                    } label: {
                        Image(systemName: "checkmark.circle")
                            .font(.headline)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityLabel("Select notes")
                }

                if !isTrash && !isArchived {
                    Menu {
                        Button {
                            importFiles(.files)
                        } label: {
                            Label("File", systemImage: LibraryImportSource.files.systemImage)
                        }

                        PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 12, matching: .images) {
                            Label("Photo", systemImage: "photo.on.rectangle")
                        }

                        Button {
                            importFiles(.googleDrive)
                        } label: {
                            Label("Google Drive", systemImage: LibraryImportSource.googleDrive.systemImage)
                        }

                        Button {
                            importFiles(.oneDrive)
                        } label: {
                            Label("OneDrive", systemImage: LibraryImportSource.oneDrive.systemImage)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if isImportingDocument {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            Label(isImportingDocument ? "Importing" : "Import", systemImage: "square.and.arrow.down")
                        }
                        .font(.headline)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(folder == nil || isImportingDocument)
                    .keyboardShortcut("i", modifiers: [.command])
                    .accessibilityLabel("Import file or photo")

                    Button(action: createNote) {
                        HStack(spacing: 7) {
                            if beanNotesTheme.supportsFriendlyVisits {
                                ThemeBadgeView(theme: beanNotesTheme, size: 24)
                            } else {
                                Image(systemName: "plus")
                            }

                            Text("New")
                        }
                        .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut("n", modifiers: [.command])
                    .accessibilityLabel("Create note")
                }
            }
        }
    }

    private var selectionActions: some View {
        HStack(spacing: 12) {
            Button(selectedNoteIDs.count == notes.count ? "Deselect All" : "Select All") {
                if selectedNoteIDs.count == notes.count {
                    selectedNoteIDs.removeAll()
                } else {
                    selectedNoteIDs = Set(notes.map(\.id))
                }
            }
            .buttonStyle(.bordered)

            Text("\(selectedNoteIDs.count) selected")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer()

            if isTrash {
                Button {
                    let notes = selectedNotes
                    endSelection()
                    restoreNotes(notes)
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .disabled(selectedNoteIDs.isEmpty)

                Button(role: .destructive) {
                    let notes = selectedNotes
                    endSelection()
                    permanentlyDeleteNotes(notes)
                } label: {
                    Label("Delete", systemImage: "trash.slash")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedNoteIDs.isEmpty)
            } else {
                Menu {
                    ForEach(ExportFormat.allCases) { format in
                        Button {
                            let notes = selectedNotes
                            endSelection()
                            exportNotes(notes, format)
                        } label: {
                            Label(format.label, systemImage: exportIcon(for: format))
                        }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .disabled(selectedNoteIDs.isEmpty)

                Button(role: .destructive) {
                    let notes = selectedNotes
                    endSelection()
                    moveNotesToTrash(notes)
                } label: {
                    Label("Trash", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedNoteIDs.isEmpty)
            }
        }
        .padding(14)
        .background(beanNotesTheme.cardBackground.opacity(0.94), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let hasSearch = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if hasSearch {
            ContentUnavailableView(
                "No Matching Notes",
                systemImage: "magnifyingglass",
                description: Text("Try a different search.")
            )
            .frame(maxWidth: .infinity, minHeight: 360)
        } else if isTrash {
            ContentUnavailableView(
                "Trash is Empty",
                systemImage: "trash",
                description: Text("Deleted notes stay here for 30 days before they are permanently removed.")
            )
            .frame(maxWidth: .infinity, minHeight: 360)
        } else if isArchived {
            ContentUnavailableView(
                "No Notes",
                systemImage: "archivebox",
                description: Text("This archived folder is empty.")
            )
            .frame(maxWidth: .infinity, minHeight: 360)
        } else if beanNotesTheme == .bean {
            VStack(spacing: 14) {
                Image("BeanWelcomeImage")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 152)
                    .accessibilityHidden(true)

                Text(beanNotesTheme.mascotEmptyStateTitle)
                    .font(.title3.weight(.semibold))

                Text(beanNotesTheme.mascotEmptyStateMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(action: createNote) {
                    Label("Create Note", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, minHeight: 390)
            .padding(.horizontal, 24)
        } else if beanNotesTheme == .blueberry {
            VStack(spacing: 14) {
                Image("BlueberryVisitImage")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 158)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .accessibilityHidden(true)

                Text(beanNotesTheme.mascotEmptyStateTitle)
                    .font(.title3.weight(.semibold))

                Text(beanNotesTheme.mascotEmptyStateMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(action: createNote) {
                    HStack(spacing: 8) {
                        ThemeBadgeView(theme: beanNotesTheme, size: 24)
                        Text("Create Note")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, minHeight: 390)
            .padding(.horizontal, 24)
        } else {
            ContentUnavailableView(
                "No Notes",
                systemImage: "note.text",
                description: Text("Create a note in this folder.")
            )
            .frame(maxWidth: .infinity, minHeight: 360)
        }
    }

    private func toggleSelection(_ note: NoteDocument) {
        if selectedNoteIDs.contains(note.id) {
            selectedNoteIDs.remove(note.id)
        } else {
            selectedNoteIDs.insert(note.id)
        }
    }

    private func endSelection() {
        isSelecting = false
        selectedNoteIDs.removeAll()
    }

    private func exportIcon(for format: ExportFormat) -> String {
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

struct BeanNotesProgressOverlay: View {
    @Environment(\.beanNotesTheme) private var beanNotesTheme

    var title: String
    var message: String
    var progress: Double?
    var cancel: (() -> Void)? = nil

    private var clampedProgress: Double? {
        progress.map { min(max($0, 0), 1) }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    if beanNotesTheme.supportsFriendlyVisits {
                        ThemeBadgeView(theme: beanNotesTheme, size: 34)
                    }

                    ProgressView()
                        .controlSize(.large)
                        .tint(beanNotesTheme.accentColor)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.headline.weight(.semibold))

                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let clampedProgress {
                        Text(clampedProgress, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                if let clampedProgress {
                    ProgressView(value: clampedProgress)
                        .progressViewStyle(.linear)
                        .tint(beanNotesTheme.accentColor)
                        .animation(.snappy(duration: 0.16), value: clampedProgress)
                }

                if let cancel {
                    Button(role: .cancel) {
                        cancel()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .accessibilityLabel("Cancel \(title.lowercased())")
                }
            }
            .frame(width: 320)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 14)
        }
        .transition(.opacity)
    }
}

private struct CompactProgressBanner: View {
    @Environment(\.beanNotesTheme) private var beanNotesTheme

    var message: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(beanNotesTheme.accentColor)

            Text(message)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.14), radius: 16, x: 0, y: 8)
    }
}

private enum NoteCardLayout {
    static let minWidth: CGFloat = 238
    static let maxWidth: CGFloat = 286
    static let previewHeight: CGFloat = 278
    static let footerHeight: CGFloat = 76
    static let totalHeight = previewHeight + footerHeight
}

private struct NoteCardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.beanNotesTheme) private var beanNotesTheme
    @AppStorage(NoteBackground.showsBeanArtworkKey) private var showsBeanArtwork = false
    @AppStorage(NoteBackground.showsBlueberryArtworkKey) private var showsBlueberryArtwork = true

    var note: NoteDocument
    var isTrash: Bool
    var isSelecting: Bool
    var isSelected: Bool
    var openNote: () -> Void
    var moveToTrash: () -> Void
    var restore: () -> Void
    var permanentlyDelete: () -> Void
    var thumbnailRefreshVersion: Int

    @State private var thumbnailImage: UIImage?
    @State private var errorMessage: String?
    @State private var thumbnailLoadTask: Task<Void, Never>?
    @State private var thumbnailLoadRequestID: UUID?

    private let storage = LocalStorageService()
    private let thumbnailService = ThumbnailService()

    private var showsThemeArtwork: Bool {
        switch beanNotesTheme {
        case .standard:
            false
        case .bean:
            showsBeanArtwork
        case .blueberry:
            showsBlueberryArtwork
        }
    }

    var body: some View {
        Button(action: openNote) {
            VStack(alignment: .leading, spacing: 0) {
                thumbnail
                    .frame(height: NoteCardLayout.previewHeight)

                VStack(alignment: .leading, spacing: 5) {
                    Text(note.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        if isTrash {
                            Text(trashExpirationLabel)
                        } else {
                            Text(note.updatedAt, style: .date)
                        }
                        Text("\(note.pages.count) \(note.pages.count == 1 ? "page" : "pages")")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: NoteCardLayout.footerHeight, alignment: .center)
                .background(beanNotesTheme.cardBackground)
            }
            .frame(maxWidth: .infinity)
            .frame(height: NoteCardLayout.totalHeight, alignment: .top)
            .background(beanNotesTheme.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isSelected ? beanNotesTheme.accentColor : Color.secondary.opacity(0.12),
                        lineWidth: isSelected ? 3 : 1
                    )
            }
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(isSelected ? beanNotesTheme.accentColor : .secondary)
                        .background(beanNotesTheme.cardBackground, in: Circle())
                        .padding(12)
                        .accessibilityHidden(true)
                }
            }
            .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !isSelecting {
                if isTrash {
                    Button {
                        restore()
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }

                    Button(role: .destructive) {
                        permanentlyDelete()
                    } label: {
                        Label("Delete Permanently", systemImage: "trash.slash")
                    }
                } else {
                    Button(role: .destructive) {
                        moveToTrash()
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                }
            }
        }
        .accessibilityLabel("\(note.title), \(note.pages.count) pages")
        .accessibilityValue(isSelecting ? (isSelected ? "Selected" : "Not selected") : "")
        .onAppear {
            loadThumbnail()
        }
        .onChange(of: beanNotesTheme) { _, _ in
            thumbnailImage = nil
            loadThumbnail(forceRefresh: true)
        }
        .onChange(of: showsThemeArtwork) { _, _ in
            thumbnailImage = nil
            loadThumbnail(forceRefresh: true)
        }
        .onChange(of: thumbnailRefreshVersion) { _, _ in
            thumbnailImage = nil
            loadThumbnail()
        }
        .onDisappear {
            cancelThumbnailLoad()
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

    private var trashExpirationLabel: String {
        guard let days = NoteTrashPolicy.remainingDays(trashedAt: note.trashedAt) else {
            return "In Trash"
        }
        if days == 0 {
            return "Deletes today"
        }
        return "Deletes in \(days)d"
    }

    private var thumbnail: some View {
        ZStack {
            beanNotesTheme.previewBackground

            if let thumbnailImage {
                Image(uiImage: thumbnailImage)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            } else if let page = note.sortedPages.first {
                NoteBackgroundSurface(background: page.background, pageID: page.id)
                    .aspectRatio(pagePreviewAspectRatio(page), contentMode: .fit)
                    .padding(12)
            } else {
                beanNotesTheme.previewBackground
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            if note.pages.count > 1 {
                Text("\(note.pages.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(10)
            }
        }
        .clipped()
    }

    private func pagePreviewAspectRatio(_ page: NotePage) -> CGFloat {
        page.pageSize.width / max(page.pageSize.height, 1)
    }

    private func loadThumbnail(forceRefresh: Bool = false) {
        cancelThumbnailLoad()

        guard let page = note.sortedPages.first else {
            thumbnailImage = nil
            return
        }

        let requestedTheme = beanNotesTheme
        let storedThumbnailURL = currentThumbnailURL(
            for: page,
            theme: requestedTheme,
            forceRefresh: forceRefresh
        )
        let fallbackImageURL = forceRefresh ? nil : fallbackFirstPageImageURL(for: page)

        let requestID = UUID()
        thumbnailLoadRequestID = requestID

        thumbnailLoadTask = Task { @MainActor in
            defer {
                if thumbnailLoadRequestID == requestID {
                    thumbnailLoadRequestID = nil
                    thumbnailLoadTask = nil
                }
            }

            do {
                if let storedThumbnailURL {
                    let image = await ImageMemoryCache.shared.imageInBackground(
                        at: storedThumbnailURL,
                        maxPixelSize: 620
                    )
                    try Task.checkCancellation()
                    guard thumbnailLoadRequestID == requestID else { return }
                    if let image {
                        thumbnailImage = image
                        return
                    }
                }

                if let fallbackImageURL {
                    let image = await ImageMemoryCache.shared.imageInBackground(
                        at: fallbackImageURL,
                        maxPixelSize: 620
                    )
                    try Task.checkCancellation()
                    guard thumbnailLoadRequestID == requestID else { return }
                    if let image {
                        thumbnailImage = image
                    }
                }

                let url = try await thumbnailService.generateThumbnailInBackground(
                    for: page,
                    theme: requestedTheme,
                    showsBeanArtwork: showsThemeArtwork,
                    maxDimension: 360
                )
                try Task.checkCancellation()
                guard thumbnailLoadRequestID == requestID else { return }
                let generatedImage = await ImageMemoryCache.shared.imageInBackground(
                    at: url,
                    maxPixelSize: 620
                )
                try Task.checkCancellation()
                guard thumbnailLoadRequestID == requestID else { return }
                thumbnailImage = generatedImage
                try modelContext.save()
            } catch is CancellationError {
                return
            } catch {
                guard thumbnailLoadRequestID == requestID else { return }
                thumbnailImage = nil
                errorMessage = "BeanNotes could not save the note preview. \(error.localizedDescription)"
            }
        }
    }

    private func cancelThumbnailLoad() {
        thumbnailLoadTask?.cancel()
        thumbnailLoadTask = nil
        thumbnailLoadRequestID = nil
    }

    private func currentThumbnailURL(
        for page: NotePage,
        theme: BeanNotesTheme,
        forceRefresh: Bool
    ) -> URL? {
        guard !forceRefresh,
              let relativePath = page.thumbnailFileName,
              ThumbnailService.isCurrentThumbnailPath(
                  relativePath,
                  pageID: page.id,
                  theme: theme,
                  showsBeanArtwork: showsThemeArtwork
              ) else {
            return nil
        }

        return try? storage.validatedURL(forRelativePath: relativePath)
    }

    private func fallbackFirstPageImageURL(for page: NotePage) -> URL? {
        guard let attachment = page.lockedImageAttachments.first else { return nil }
        return try? storage.validatedURL(forRelativePath: attachment.storedFileName)
    }
}
