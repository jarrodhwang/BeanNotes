//
//  LibraryView.swift
//  BeanNote
//

import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @Query(sort: \NotebookFolder.name) private var folders: [NotebookFolder]
    @Query(sort: \NoteDocument.updatedAt, order: .reverse) private var recentNotes: [NoteDocument]

    @State private var selectedFolderID: UUID?
    @State private var searchText = ""
    @State private var noteBeingEdited: NoteDocument?
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

    private var isShowingNoteEditor: Binding<Bool> {
        Binding(
            get: { noteBeingEdited != nil },
            set: { if !$0 { noteBeingEdited = nil } }
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
                importDocument: {
                    isShowingDocumentImporter = true
                },
                isImportingDocument: isImportingDocument,
                openNote: { noteBeingEdited = $0 },
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
            if let note = noteBeingEdited {
                NavigationStack {
                    NoteEditorView(note: note)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    noteBeingEdited = nil
                                } label: {
                                    Image(systemName: "chevron.left")
                                }
                                .accessibilityLabel("Back to library")
                            }
                        }
                }
                .onDisappear {
                    refreshThumbnail(for: note)
                }
            }
        }
        .sheet(isPresented: $isShowingFolderEditor) {
            FolderEditorView(
                title: folderBeingEdited == nil ? "New Folder" : "Edit Folder",
                initialName: folderBeingEdited?.name ?? "",
                initialColorHex: folderBeingEdited?.colorHex ?? "#5B8DEF"
            ) { name, colorHex in
                saveFolder(name: name, colorHex: colorHex)
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
        .fileImporter(
            isPresented: $isShowingDocumentImporter,
            allowedContentTypes: [
                .pdf,
                ImportExportService.wordDocument,
                ImportExportService.legacyWordDocument
            ],
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
                let inbox = NotebookFolder(name: "Inbox", colorHex: "#E5B94E")
                modelContext.insert(inbox)
                try modelContext.save()
                selectedFolderID = inbox.id
            } else if selectedFolderID == nil {
                selectedFolderID = selectedFolder?.id
            }

            absorbSharedInbox()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func absorbSharedInbox() {
        do {
            try ImportExportService().absorbSharedInbox(into: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveFolder(name: String, colorHex: String) {
        if let folderBeingEdited {
            folderBeingEdited.name = name
            folderBeingEdited.colorHex = colorHex
            folderBeingEdited.updatedAt = Date()
        } else {
            let folder = NotebookFolder(name: name, colorHex: colorHex)
            modelContext.insert(folder)
            selectedFolderID = folder.id
        }

        try? modelContext.save()
        folderBeingEdited = nil
    }

    private func createNote() {
        guard let selectedFolder else { return }

        let note = NoteDocument(title: "Untitled Note", folder: selectedFolder)
        let page = NotePage(pageOrder: 0, note: note)
        note.pages.append(page)
        selectedFolder.notes.append(note)
        selectedFolder.updatedAt = Date()

        modelContext.insert(note)
        modelContext.insert(page)
        try? modelContext.save()
        noteBeingEdited = note
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
            noteBeingEdited = firstImportedNote
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deletePendingNote() {
        guard let note = notePendingDeletion else { return }
        modelContext.delete(note)
        notePendingDeletion = nil
        try? modelContext.save()
    }

    private func deletePendingFolder() {
        guard let folder = folderPendingDeletion else { return }
        let deletingSelectedFolder = folder.id == selectedFolderID

        modelContext.delete(folder)
        folderPendingDeletion = nil

        if deletingSelectedFolder {
            selectedFolderID = sortedFolders.first { $0.id != folder.id }?.id
        }

        try? modelContext.save()
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
}

private struct NotesCardGridView: View {
    var folder: NotebookFolder?
    var notes: [NoteDocument]
    var searchText: String
    var createNote: () -> Void
    var importDocument: () -> Void
    var isImportingDocument: Bool
    var openNote: (NoteDocument) -> Void
    var deleteNote: (NoteDocument) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 230, maximum: 340), spacing: 28, alignment: .top)
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
                        }
                    }
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 38)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemBackground))
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

            Button(action: importDocument) {
                Label(isImportingDocument ? "Importing" : "Import", systemImage: "square.and.arrow.down")
                    .font(.headline)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(folder == nil || isImportingDocument)
            .accessibilityLabel("Import PDF or Word document")

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
                .background(Color(.secondarySystemBackground))
            }
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
            if let thumbnailImage {
                Image(uiImage: thumbnailImage)
                    .resizable()
                    .scaledToFill()
            } else if let page = note.sortedPages.first {
                NoteBackgroundSurface(background: page.background)
            } else {
                Color(.tertiarySystemGroupedBackground)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1.05, contentMode: .fit)
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
}
