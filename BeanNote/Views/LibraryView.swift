//
//  LibraryView.swift
//  BeanNote
//

import SwiftData
import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @Query(sort: \NotebookFolder.name) private var folders: [NotebookFolder]
    @Query(sort: \NoteDocument.updatedAt, order: .reverse) private var recentNotes: [NoteDocument]

    @AppStorage(NoteBackground.defaultStyleRawKey) private var defaultBackgroundStyleRaw = NoteBackgroundStyle.plain.rawValue
    @AppStorage(NoteBackground.defaultColorHexKey) private var defaultBackgroundColorHex = NoteBackground.defaultColorHex

    @State private var selectedFolderID: UUID?
    @State private var searchText = ""
    @State private var openNoteTabs: [NoteDocument] = []
    @State private var selectedOpenNoteID: UUID?
    @State private var notePendingDeletion: NoteDocument?
    @State private var isShowingFolderEditor = false
    @State private var isShowingDocumentImporter = false
    @State private var isImportingDocument = false
    @State private var folderBeingEdited: NotebookFolder?
    @State private var folderPendingDeletion: NotebookFolder?
    @State private var isShowingSettings = false
    @State private var errorMessage: String?

    private var sortedFolders: [NotebookFolder] {
        folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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

        return source.filter {
            $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    private var defaultNoteBackground: NoteBackground {
        NoteBackground.fromDefaults(styleRaw: defaultBackgroundStyleRaw, colorHex: defaultBackgroundColorHex)
    }

    private var isShowingNoteEditor: Binding<Bool> {
        Binding(
            get: { selectedOpenNoteID != nil },
            set: { if !$0 { selectedOpenNoteID = nil } }
        )
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
                    Task {
                        await importPhotosAsNotes(photoItems)
                    }
                },
                isImportingDocument: isImportingDocument,
                openNote: openNote,
                deleteNote: { notePendingDeletion = $0 }
            )
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            bootstrapLibrary()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            absorbSharedInbox()
        }
        .fullScreenCover(isPresented: isShowingNoteEditor) {
            NoteTabbedEditorWorkspace(
                tabs: openNoteTabs,
                selectedNoteID: $selectedOpenNoteID,
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
                initialColorHex: folderBeingEdited?.colorHex ?? "#2563EB"
            ) { name, colorHex in
                saveFolder(name: name, colorHex: colorHex)
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
        .fileImporter(
            isPresented: $isShowingDocumentImporter,
            allowedContentTypes: ImportExportService.supportedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task {
                    await importDocumentsAsNotes(urls)
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
        .alert("BeanNote", isPresented: Binding(
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
                let inbox = NotebookFolder(name: "Inbox", colorHex: "#F59E0B")
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

    private func saveFolder(name: String, colorHex: String) {
        let changedFolder: NotebookFolder

        if let folderBeingEdited {
            folderBeingEdited.name = name
            folderBeingEdited.colorHex = colorHex
            folderBeingEdited.updatedAt = Date()
            changedFolder = folderBeingEdited
        } else {
            let folder = NotebookFolder(name: name, colorHex: colorHex)
            modelContext.insert(folder)
            selectedFolderID = folder.id
            changedFolder = folder
        }

        try? modelContext.save()
        syncSharedFolderIndex(including: [changedFolder])
        folderBeingEdited = nil
    }

    private func createNote() {
        guard let selectedFolder else { return }

        let note = NoteDocument(title: "Untitled Note", folder: selectedFolder)
        let page = NotePage(pageOrder: 0, background: defaultNoteBackground, note: note)
        note.pages.append(page)
        selectedFolder.notes.append(note)
        selectedFolder.updatedAt = Date()

        modelContext.insert(note)
        modelContext.insert(page)
        try? modelContext.save()
        openNote(note)
    }

    private func presentFileImporter(_: LibraryImportSource) {
        isShowingDocumentImporter = true
    }

    private func importDocumentsAsNotes(_ urls: [URL]) async {
        guard let selectedFolder else { return }

        isImportingDocument = true
        defer { isImportingDocument = false }

        do {
            var firstImportedNote: NoteDocument?

            for url in urls {
                let imported = try await ImportExportService().importDocumentAsNote(from: url, into: selectedFolder)
                modelContext.insert(imported.note)

                for page in imported.pages {
                    modelContext.insert(page)
                }

                for attachment in imported.attachments {
                    modelContext.insert(attachment)
                }

                firstImportedNote = firstImportedNote ?? imported.note
            }

            try modelContext.save()
            if let firstImportedNote {
                openNote(firstImportedNote)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importPhotosAsNotes(_ photoItems: [PhotosPickerItem]) async {
        guard let selectedFolder, !photoItems.isEmpty else { return }

        isImportingDocument = true
        defer { isImportingDocument = false }

        do {
            var firstImportedNote: NoteDocument?
            let service = ImportExportService()

            for (index, item) in photoItems.enumerated() {
                guard
                    let data = try await item.loadTransferable(type: Data.self),
                    let image = UIImage(data: data)
                else {
                    throw ImportExportError.unsupportedImageData
                }

                let title = photoItems.count == 1 ? "Photo" : "Photo \(index + 1)"
                let imported = try service.importImageAsNote(image, named: "\(title).jpg", into: selectedFolder)
                modelContext.insert(imported.note)

                for page in imported.pages {
                    modelContext.insert(page)
                }

                for attachment in imported.attachments {
                    modelContext.insert(attachment)
                }

                firstImportedNote = firstImportedNote ?? imported.note
            }

            try modelContext.save()
            if let firstImportedNote {
                openNote(firstImportedNote)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deletePendingNote() {
        guard let note = notePendingDeletion else { return }
        closeNoteTab(note.id)
        modelContext.delete(note)
        notePendingDeletion = nil
        try? modelContext.save()
    }

    private func deletePendingFolder() {
        guard let folder = folderPendingDeletion else { return }
        let deletingSelectedFolder = folder.id == selectedFolderID
        let deletingNoteIDs = Set(folder.notes.map(\.id))

        for noteID in deletingNoteIDs {
            closeNoteTab(noteID)
        }

        modelContext.delete(folder)
        folderPendingDeletion = nil

        if deletingSelectedFolder {
            selectedFolderID = sortedFolders.first { $0.id != folder.id }?.id
        }

        try? modelContext.save()
        syncSharedFolderIndex(excluding: [folder.id])
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

    private func refreshThumbnail(for note: NoteDocument) {
        guard let page = note.sortedPages.first else { return }

        do {
            _ = try ThumbnailService().generateThumbnail(for: page, maxDimension: 560)
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshOpenNoteThumbnails() {
        for note in openNoteTabs {
            refreshThumbnail(for: note)
        }
    }
}

private struct NoteTabbedEditorWorkspace: View {
    var tabs: [NoteDocument]
    @Binding var selectedNoteID: UUID?
    var closeTab: (UUID) -> Void
    var backToLibrary: () -> Void

    private var selectedNote: NoteDocument? {
        guard let selectedNoteID else { return tabs.first }
        return tabs.first { $0.id == selectedNoteID } ?? tabs.first
    }

    var body: some View {
        if let selectedNote {
            VStack(spacing: 0) {
                NoteEditorTabBar(
                    tabs: tabs,
                    selectedNoteID: selectedNote.id,
                    selectTab: { selectedNoteID = $0 },
                    closeTab: closeTab,
                    backToLibrary: backToLibrary
                )

                Divider()

                NavigationStack {
                    NoteEditorView(note: selectedNote)
                        .id(selectedNote.id)
                }
            }
            .background(Color(.systemBackground))
        } else {
            ContentUnavailableView("No Open Notes", systemImage: "note.text")
        }
    }
}

private struct NoteEditorTabBar: View {
    var tabs: [NoteDocument]
    var selectedNoteID: UUID
    var selectTab: (UUID) -> Void
    var closeTab: (UUID) -> Void
    var backToLibrary: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: backToLibrary) {
                Image(systemName: "chevron.left")
                    .font(.headline.weight(.semibold))
                    .frame(width: 36, height: 36)
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
                .fill(isSelected ? Color(.secondarySystemBackground) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.secondary.opacity(0.18) : Color.clear, lineWidth: 1)
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
    var folder: NotebookFolder?
    var notes: [NoteDocument]
    var searchText: String
    var createNote: () -> Void
    var importFiles: (LibraryImportSource) -> Void
    var importPhotos: ([PhotosPickerItem]) -> Void
    var isImportingDocument: Bool
    var openNote: (NoteDocument) -> Void
    var deleteNote: (NoteDocument) -> Void

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
                                deleteNote: { deleteNote(note) }
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
        .background(Color(.systemBackground))
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
                Label(isImportingDocument ? "Importing" : "Import", systemImage: "square.and.arrow.down")
                    .font(.headline)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(folder == nil || isImportingDocument)
            .accessibilityLabel("Import file or photo")

            Button(action: createNote) {
                Label("New", systemImage: "plus")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(folder == nil)
            .accessibilityLabel("Create note")
        }
    }

    private var emptyState: some View {
        let hasSearch = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return ContentUnavailableView(
            hasSearch ? "No Matching Notes" : "No Notes",
            systemImage: hasSearch ? "magnifyingglass" : "note.text",
            description: Text(hasSearch ? "Try a different search." : "Create a note in this folder.")
        )
        .frame(maxWidth: .infinity, minHeight: 360)
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

    var note: NoteDocument
    var openNote: () -> Void
    var deleteNote: () -> Void

    @State private var thumbnailImage: UIImage?
    @State private var isLoadingThumbnail = false

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
                .background(Color(.secondarySystemBackground))
            }
            .frame(maxWidth: .infinity)
            .frame(height: NoteCardLayout.totalHeight, alignment: .top)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        .onChange(of: note.updatedAt) { _, _ in
            loadThumbnail(forceRefresh: true)
        }
    }

    private var thumbnail: some View {
        ZStack {
            Color(.tertiarySystemGroupedBackground)

            if let thumbnailImage {
                Image(uiImage: thumbnailImage)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            } else if let page = note.sortedPages.first {
                NoteBackgroundSurface(background: page.background)
                    .aspectRatio(pagePreviewAspectRatio(page), contentMode: .fit)
                    .padding(12)
            } else {
                Color(.tertiarySystemGroupedBackground)
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
        guard let page = note.sortedPages.first else {
            thumbnailImage = nil
            return
        }

        if !forceRefresh,
           let relativePath = page.thumbnailFileName,
           let image = UIImage(contentsOfFile: storage.url(forRelativePath: relativePath).path) {
            thumbnailImage = image
            return
        }

        if !forceRefresh,
           let image = fallbackFirstPageImage(for: page) {
            thumbnailImage = image
        }

        guard !isLoadingThumbnail else { return }
        isLoadingThumbnail = true

        Task { @MainActor in
            defer { isLoadingThumbnail = false }

            do {
                let url = try thumbnailService.generateThumbnail(for: page, maxDimension: 520)
                thumbnailImage = UIImage(contentsOfFile: url.path)
                try? modelContext.save()
            } catch {
                thumbnailImage = nil
            }
        }
    }

    private func fallbackFirstPageImage(for page: NotePage) -> UIImage? {
        guard let attachment = page.lockedImageAttachments.first else { return nil }
        return UIImage(contentsOfFile: storage.url(forRelativePath: attachment.storedFileName).path)
    }
}
