//
//  FolderListView.swift
//  BeanNote
//

import SwiftUI

struct FolderListView: View {
    var folders: [NotebookFolder]
    @Binding var selectedFolderID: UUID?
    @Binding var searchText: String
    var createFolder: () -> Void
    var renameFolder: (NotebookFolder) -> Void
    var deleteFolder: (NotebookFolder) -> Void
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")

            searchField

            HStack {
                Text("Folders")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: createFolder) {
                    Image(systemName: "plus")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Create folder")
            }
            .padding(.horizontal, 10)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(folders) { folder in
                        folderRow(folder)
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground))
        .navigationTitle("BeanNote")
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search", text: $searchText)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
        }
        .font(.headline)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
    }

    private func folderRow(_ folder: NotebookFolder) -> some View {
        let isSelected = selectedFolderID == folder.id
        let folderColor = Color(hex: folder.colorHex)

        return Button {
            selectedFolderID = folder.id
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(folderColor)
                    .frame(width: 16, height: 16)

                Text(folder.name)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .primary : .secondary)

                Spacer()

                Text("\(folder.notes.count)")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(
                folderColor.opacity(isSelected ? 0.24 : 0.17),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(folderColor)
                        .frame(width: 4)
                        .padding(.vertical, 7)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? folderColor.opacity(0.65) : Color.clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renameFolder(folder)
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button(role: .destructive) {
                deleteFolder(folder)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityLabel("\(folder.name), \(folder.notes.count) notes")
    }
}

struct FolderEditorView: View {
    @Environment(\.dismiss) private var dismiss

    var title: String
    var initialName: String
    var initialColorHex: String
    var save: (String, String) -> Void

    @State private var name: String
    @State private var colorHex: String

    private let colors = [
        "#5B8DEF",
        "#51A37A",
        "#E5B94E",
        "#D96B6B",
        "#8D79D6",
        "#48A9A6",
        "#E1864A"
    ]

    init(
        title: String,
        initialName: String,
        initialColorHex: String,
        save: @escaping (String, String) -> Void
    ) {
        self.title = title
        self.initialName = initialName
        self.initialColorHex = initialColorHex
        self.save = save
        _name = State(initialValue: initialName)
        _colorHex = State(initialValue: initialColorHex)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                }

                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 7), spacing: 12) {
                        ForEach(colors, id: \.self) { candidate in
                            Button {
                                colorHex = candidate
                            } label: {
                                Circle()
                                    .fill(Color(hex: candidate))
                                    .frame(width: 34, height: 34)
                                    .overlay {
                                        if colorHex == candidate {
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(candidate)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(name.trimmingCharacters(in: .whitespacesAndNewlines), colorHex)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
