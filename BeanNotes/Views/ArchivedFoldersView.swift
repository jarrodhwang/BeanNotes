//
//  ArchivedFoldersView.swift
//  BeanNotes
//

import SwiftUI

struct ArchivedFolderYearSection: Identifiable {
    var year: Int
    var folders: [NotebookFolder]

    var id: Int { year }
}

enum ArchivedFolderOrganizer {
    @MainActor
    static func sections(
        from folders: [NotebookFolder],
        calendar: Calendar = .current
    ) -> [ArchivedFolderYearSection] {
        let archivedFolders = folders
            .filter(\.isArchived)
            .sorted(by: NotebookFolder.archivedOrder)
        let foldersByYear = Dictionary(grouping: archivedFolders) { folder in
            calendar.component(.year, from: folder.archivedAt ?? .distantPast)
        }

        return foldersByYear.keys.sorted(by: >).map { year in
            ArchivedFolderYearSection(year: year, folders: foldersByYear[year] ?? [])
        }
    }
}

struct ArchivedFoldersView: View {
    @Environment(\.beanNotesTheme) private var beanNotesTheme

    var folders: [NotebookFolder]
    var searchText: String
    var openFolder: (NotebookFolder) -> Void
    var renameFolder: (NotebookFolder) -> Void
    var unarchiveFolder: (NotebookFolder) -> Void
    var deleteFolder: (NotebookFolder) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 132, maximum: 184), spacing: 30, alignment: .top)
    ]

    private var filteredFolders: [NotebookFolder] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return folders }
        return folders.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var sections: [ArchivedFolderYearSection] {
        ArchivedFolderOrganizer.sections(from: filteredFolders)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header

                if sections.isEmpty {
                    emptyState
                } else {
                    ForEach(sections) { section in
                        yearSection(section)
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Archived")
                .font(.system(size: 38, weight: .black, design: .rounded))

            Text("\(folders.count) \(folders.count == 1 ? "folder" : "folders")")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private func yearSection(_ section: ArchivedFolderYearSection) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Text(section.year.formatted(.number.grouping(.never)))
                    .font(.title3.weight(.bold))

                Rectangle()
                    .fill(Color.secondary.opacity(0.24))
                    .frame(height: 1)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                ForEach(section.folders) { folder in
                    folderButton(folder)
                }
            }
        }
    }

    private func folderButton(_ folder: NotebookFolder) -> some View {
        Button {
            openFolder(folder)
        } label: {
            VStack(spacing: 9) {
                Image(systemName: "folder.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 72, weight: .regular))
                    .foregroundStyle(Color(hex: folder.colorHex))
                    .frame(height: 76)

                Text(folder.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                if let archivedAt = folder.archivedAt {
                    Text(archivedAt, format: .dateTime.month(.abbreviated).day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renameFolder(folder)
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                unarchiveFolder(folder)
            } label: {
                Label("Unarchive", systemImage: "arrow.uturn.backward")
            }

            Divider()

            Button(role: .destructive) {
                deleteFolder(folder)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: folder))
        .accessibilityHint("Opens the notes in this archived folder")
    }

    private func accessibilityLabel(for folder: NotebookFolder) -> String {
        let noteCount = folder.activeNoteCount
        guard let archivedAt = folder.archivedAt else {
            return "\(folder.name), \(noteCount) \(noteCount == 1 ? "note" : "notes")"
        }
        return "\(folder.name), archived \(archivedAt.formatted(date: .abbreviated, time: .omitted)), \(noteCount) \(noteCount == 1 ? "note" : "notes")"
    }

    @ViewBuilder
    private var emptyState: some View {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                "No Archived Folders",
                systemImage: "archivebox",
                description: Text("Archived folders and their notes will appear here.")
            )
        } else {
            ContentUnavailableView(
                "No Matching Folders",
                systemImage: "magnifyingglass",
                description: Text("Try a different search.")
            )
        }
    }
}
