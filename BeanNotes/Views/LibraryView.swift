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
    @AppStorage(AppTheme.storageKey) private var appThemeRaw = AppTheme.system.rawValue
    @AppStorage(BeanVisitPolicy.enabledKey) private var beanVisitsEnabled = true
    @AppStorage(BeanVisitPolicy.allowsInterruptionsKey) private var beanVisitsMayInterrupt = false
    @AppStorage(BeanVisitPolicy.focusReminderIntervalKey) private var beanFocusReminderInterval = BeanVisitPolicy.defaultFocusReminderInterval

    @State private var selectedFolderID: UUID?
    @State private var searchText = ""
    @State private var openNoteTabs: [NoteDocument] = []
    @State private var selectedOpenNoteID: UUID?
    @StateObject private var editorSessionStore = NoteEditorSessionStore()
    @State private var notePendingDeletion: NoteDocument?
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
    @State private var beanVisit: BeanVisit?
    @State private var beanVisitDismissTask: Task<Void, Never>?
    @State private var focusSessionStartedAt = Date()
    @State private var awayStartedAt: Date?
    @State private var visitScheduleToken = 0
    @State private var thumbnailRefreshVersions: [UUID: Int] = [:]

    private var sortedFolders: [NotebookFolder] {
        folders.sorted { lhs, rhs in
            let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if comparison == .orderedSame {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return comparison == .orderedAscending
        }
    }

    private var selectedFolder: NotebookFolder? {
        if let selectedFolderID,
           let folder = folders.first(where: { $0.id == selectedFolderID }) {
            return folder
        }

        return sortedFolders.first
    }

    private var visibleNotes: [NoteDocument] {
        let source = selectedFolder?.sortedNotes ?? Array(recentNotes.prefix(24))
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return source }

        return source.filter { $0.matchesSearch(query) }
    }

    private var defaultNoteBackground: NoteBackground {
        NoteBackground.fromDefaults(styleRaw: defaultBackgroundStyleRaw, colorHex: defaultBackgroundColorHex)
    }

    private var defaultPaperSize: PaperSize {
        PaperSize(rawValue: paperSizeRaw) ?? PaperSize.defaultPaperSize
    }

    private var appTheme: AppTheme {
        AppTheme(rawValue: appThemeRaw) ?? .system
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
            && folderPendingDeletion == nil
            && notePendingDeletion == nil
            && errorMessage == nil
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canScheduleBeanVisit: Bool {
        let processInfo = ProcessInfo.processInfo
        return BeanVisitPolicy.canSchedule(
            theme: beanNotesTheme,
            isEnabled: beanVisitsEnabled,
            sceneIsActive: scenePhase == .active,
            isSafeSurface: isSafeForAutomaticBeanVisit,
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            thermalState: processInfo.thermalState,
            launchArguments: processInfo.arguments
        )
    }

    private var interruptibleVisitTaskID: String {
        "\(canScheduleBeanVisit)-\(beanVisitsMayInterrupt)-\(visitScheduleToken)"
    }

    private var focusVisitTaskID: String {
        "\(canScheduleBeanVisit)-\(beanVisitsMayInterrupt)-\(beanFocusReminderInterval)-\(focusSessionStartedAt.timeIntervalSinceReferenceDate)"
    }

    private var beanVisitTransition: AnyTransition {
        accessibilityReduceMotion
            ? .opacity
            : .move(edge: .trailing).combined(with: .opacity)
    }

    var body: some View {
        NavigationSplitView {
            FolderListView(
                folders: sortedFolders,
                selectedFolderID: $selectedFolderID,
                searchText: $searchText,
                createFolder: {
                    folderBeingEdited = nil
                    isShowingFolderEditor = true
                },
                renameFolder: { folder in
                    folderBeingEdited = folder
                    isShowingFolderEditor = true
                },
                deleteFolder: { folder in
                    folderPendingDeletion = folder
                },
                openSettings: {
                    isShowingSettings = true
                }
            )
        } detail: {
            NotesCardGridView(
                folder: selectedFolder,
                notes: visibleNotes,
                searchText: searchText,
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
                openNote: openNote,
                deleteNote: { notePendingDeletion = $0 },
                thumbnailRefreshVersions: thumbnailRefreshVersions
            )
        }
        .navigationSplitViewStyle(.balanced)
        .overlay(alignment: .bottomTrailing) {
            if let beanVisit {
                BeanPetVisitView(visit: beanVisit)
                    .padding(.trailing, 22)
                    .padding(.bottom, 18)
                    .transition(beanVisitTransition)
                    .zIndex(4)
            }
        }
        .overlay(alignment: .bottom) {
            if let folderCreatedToast {
                FolderCreatedToastView(toast: folderCreatedToast)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(5)
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
        .onChange(of: scenePhase) { _, phase in
            handleScenePhaseChange(phase)
            if phase == .active {
                absorbSharedInbox()
            }
        }
        .onChange(of: beanNotesTheme) { _, theme in
            if theme != .bean {
                hideBeanVisit(animated: false)
            }
        }
        .onChange(of: beanVisitsEnabled) { _, isEnabled in
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
            Text("Notes in this folder will also be deleted.")
        }
        .alert("Delete Note?", isPresented: Binding(
            get: { notePendingDeletion != nil },
            set: { if !$0 { notePendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                deletePendingNote()
            }
            Button("Cancel", role: .cancel) {
                notePendingDeletion = nil
            }
        } message: {
            Text("This note and its pages will be deleted.")
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

    private func bootstrapLibrary() {
        do {
            try LocalStorageService().prepareDirectories()

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
        guard beanVisitsMayInterrupt, canScheduleBeanVisit else { return }

        let now = Date()
        let cooldownRemaining = BeanVisitPolicy.cooldownRemaining(
            now: now,
            lastShownDate: BeanVisitPolicy.lastShownDate()
        )
        let delay = max(BeanVisitPolicy.interruptibleInitialDelay, cooldownRemaining)

        do {
            try await Task.sleep(nanoseconds: BeanVisitPolicy.nanoseconds(for: delay))
            guard !Task.isCancelled,
                  beanVisitsMayInterrupt,
                  canScheduleBeanVisit else { return }

            showBeanVisit(reason: .friendly)
        } catch {
            // Cancellation is expected when the app moves to another surface.
        }
    }

    @MainActor
    private func runFocusBeanVisitIfEligible() async {
        guard !beanVisitsMayInterrupt, canScheduleBeanVisit else { return }

        let interval = BeanVisitPolicy.normalizedFocusReminderInterval(beanFocusReminderInterval)
        let focusStartedAt = focusSessionStartedAt
        let elapsed = Date().timeIntervalSince(focusStartedAt)
        let delay = max(0, interval - elapsed)

        do {
            try await Task.sleep(nanoseconds: BeanVisitPolicy.nanoseconds(for: delay))
            guard !Task.isCancelled,
                  !beanVisitsMayInterrupt,
                  canScheduleBeanVisit,
                  focusSessionStartedAt == focusStartedAt else { return }

            let focusDuration = Date().timeIntervalSince(focusStartedAt)
            guard BeanVisitPolicy.shouldVisitAfterFocusing(
                focusDuration: focusDuration,
                reminderInterval: interval,
                allowsInterruptions: beanVisitsMayInterrupt
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
                allowsInterruptions: beanVisitsMayInterrupt
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
              BeanVisitPolicy.cooldownHasElapsed(
                now: Date(),
                lastShownDate: BeanVisitPolicy.lastShownDate()
              ) else { return }

        beanVisitDismissTask?.cancel()
        let visit = BeanVisit.make(reason: reason)
        BeanVisitPolicy.recordVisit()

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

        if beanVisitsMayInterrupt {
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
                width: defaultPaperSize.dimensions.width,
                height: defaultPaperSize.dimensions.height,
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

    private func deletePendingNote() {
        guard let note = notePendingDeletion else { return }
        let cleanupTarget = LocalStorageCleanupTarget(note: note)
        let deletingNoteID = note.id

        modelContext.delete(note)
        notePendingDeletion = nil

        if saveLibraryChanges("delete the note", rollbackOnFailure: true) {
            closeNoteTab(deletingNoteID)
            reportCleanup(LocalStorageService().removeStoredFiles(matching: cleanupTarget))
        }
    }

    private func deletePendingFolder() {
        guard let folder = folderPendingDeletion else { return }
        let cleanupTarget = LocalStorageCleanupTarget(folder: folder)
        let deletingFolderID = folder.id
        let deletingSelectedFolder = folder.id == selectedFolderID
        let deletingNoteIDs = Set(folder.notes.map(\.id))
        let nextSelectedFolderID = sortedFolders.first { $0.id != deletingFolderID }?.id

        modelContext.delete(folder)
        folderPendingDeletion = nil

        if saveLibraryChanges("delete the folder", rollbackOnFailure: true) {
            for noteID in deletingNoteIDs {
                closeNoteTab(noteID)
            }

            if deletingSelectedFolder {
                selectedFolderID = nextSelectedFolderID
            }

            reportCleanup(LocalStorageService().removeStoredFiles(matching: cleanupTarget))
            syncSharedFolderIndex(excluding: [deletingFolderID])
        }
    }

    private func reportCleanup(_ report: LocalStorageCleanupReport) {
        guard report.hasFailures else { return }
        errorMessage = "The item was deleted, but BeanNotes could not remove \(report.failedRelativePaths.count) local file(s)."
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

        let folders = foldersByID.values.filter { !excludedFolderIDs.contains($0.id) }
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

        let notes = Array(recentNotes.prefix(8))
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
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

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

    private var beanVisitTransition: AnyTransition {
        accessibilityReduceMotion
            ? .opacity
            : .move(edge: .trailing).combined(with: .opacity)
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
            .overlay(alignment: .bottomTrailing) {
                if let beanVisit {
                    BeanPetVisitView(visit: beanVisit)
                        .padding(.trailing, 22)
                        .padding(.bottom, 18)
                        .transition(beanVisitTransition)
                        .zIndex(4)
                }
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

                    if beanNotesTheme == .bean {
                        BeanAvatarView(size: 30)
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
                Text(beanNotesTheme == .bean ? "Folder ready" : "Folder created")
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
    var createNote: () -> Void
    var importFiles: (LibraryImportSource) -> Void
    var importPhotos: ([PhotosPickerItem]) -> Void
    var isImportingDocument: Bool
    var importProgress: Double?
    var importProgressMessage: String
    var cancelImport: () -> Void
    var openNote: (NoteDocument) -> Void
    var deleteNote: (NoteDocument) -> Void
    var thumbnailRefreshVersions: [UUID: Int]

    @State private var selectedPhotoItems: [PhotosPickerItem] = []

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

                if notes.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                        ForEach(notes) { note in
                            NoteCardView(
                                note: note,
                                openNote: { openNote(note) },
                                deleteNote: { deleteNote(note) },
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
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(folder?.name ?? "Recent Notes")
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text("\(notes.count) \(notes.count == 1 ? "note" : "notes")")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 7) {
                if beanNotesTheme == .bean {
                    BeanAvatarView(size: 26)
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
                    if beanNotesTheme == .bean {
                        BeanBadgeView(size: 24)
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
        } else if beanNotesTheme == .bean {
            VStack(spacing: 14) {
                Image("BeanWelcomeImage")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 152)
                    .accessibilityHidden(true)

                Text("Ready for a new note?")
                    .font(.title3.weight(.semibold))

                Text("Bean will keep this folder cozy until your first idea arrives.")
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
        } else {
            ContentUnavailableView(
                "No Notes",
                systemImage: "note.text",
                description: Text("Create a note in this folder.")
            )
            .frame(maxWidth: .infinity, minHeight: 360)
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
                    if beanNotesTheme == .bean {
                        BeanBadgeView(size: 34)
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

    var note: NoteDocument
    var openNote: () -> Void
    var deleteNote: () -> Void
    var thumbnailRefreshVersion: Int

    @State private var thumbnailImage: UIImage?
    @State private var isLoadingThumbnail = false
    @State private var errorMessage: String?
    @State private var thumbnailLoadTask: Task<Void, Never>?
    @State private var thumbnailLoadRequestID: UUID?

    private let storage = LocalStorageService()
    private let thumbnailService = ThumbnailService()

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
                        Text(note.updatedAt, style: .date)
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
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                deleteNote()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityLabel("\(note.title), \(note.pages.count) pages")
        .onAppear {
            loadThumbnail()
        }
        .onChange(of: beanNotesTheme) { _, _ in
            thumbnailImage = nil
            loadThumbnail(forceRefresh: true)
        }
        .onChange(of: showsBeanArtwork) { _, _ in
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

        if !forceRefresh,
           let relativePath = page.thumbnailFileName,
           ThumbnailService.isCurrentThumbnailPath(
               relativePath,
               pageID: page.id,
               theme: requestedTheme,
               showsBeanArtwork: showsBeanArtwork
           ),
           let thumbnailURL = try? storage.validatedURL(forRelativePath: relativePath),
           let image = ImageMemoryCache.shared.image(
                at: thumbnailURL,
                maxPixelSize: 620
           ) {
            thumbnailImage = image
            return
        }

        if !forceRefresh,
           let image = fallbackFirstPageImage(for: page) {
            thumbnailImage = image
        }

        let requestID = UUID()
        thumbnailLoadRequestID = requestID
        isLoadingThumbnail = true

        thumbnailLoadTask = Task { @MainActor in
            defer {
                if thumbnailLoadRequestID == requestID {
                    thumbnailLoadRequestID = nil
                    thumbnailLoadTask = nil
                    isLoadingThumbnail = false
                }
            }

            do {
                let url = try await thumbnailService.generateThumbnailInBackground(
                    for: page,
                    theme: requestedTheme,
                    showsBeanArtwork: showsBeanArtwork,
                    maxDimension: 360
                )
                try Task.checkCancellation()
                guard thumbnailLoadRequestID == requestID else { return }
                thumbnailImage = ImageMemoryCache.shared.image(at: url, maxPixelSize: 620)
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
        isLoadingThumbnail = false
    }

    private func fallbackFirstPageImage(for page: NotePage) -> UIImage? {
        guard let attachment = page.lockedImageAttachments.first,
              let imageURL = try? storage.validatedURL(forRelativePath: attachment.storedFileName) else {
            return nil
        }
        return ImageMemoryCache.shared.image(
            at: imageURL,
            maxPixelSize: 620
        )
    }
}
