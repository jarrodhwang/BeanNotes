//
//  FolderListView.swift
//  BeanNotes
//

import SwiftUI
import UIKit

struct FolderListView: View {
    @Environment(\.beanNotesTheme) private var beanNotesTheme

    var folders: [NotebookFolder]
    @Binding var selectedFolderID: UUID?
    @Binding var searchText: String
    var createFolder: () -> Void
    var renameFolder: (NotebookFolder) -> Void
    var deleteFolder: (NotebookFolder) -> Void
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            topControls

            searchField

            HStack {
                HStack(spacing: 7) {
                    if beanNotesTheme == .bean {
                        BeanBadgeView(size: 20)
                    }

                    Text("Folders")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: createFolder) {
                    ZStack(alignment: .bottomTrailing) {
                        if beanNotesTheme == .bean {
                            BeanBadgeView(size: 28)
                        }

                        Image(systemName: beanNotesTheme == .bean ? "plus.circle.fill" : "plus")
                            .font(beanNotesTheme == .bean ? .caption.weight(.bold) : .title3)
                            .foregroundStyle(beanNotesTheme == .bean ? beanNotesTheme.accentColor : .secondary)
                            .background {
                                if beanNotesTheme == .bean {
                                    Circle()
                                        .fill(beanNotesTheme.cardBackground)
                                        .frame(width: 15, height: 15)
                                }
                            }
                    }
                    .frame(width: 44, height: 44)
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
        .background {
            BeanNotesPaperBackground(
                theme: beanNotesTheme,
                baseColor: beanNotesTheme.sidebarBackground,
                showsMascotWatermark: true
            )
                .ignoresSafeArea()
        }
        .navigationTitle("BeanNotes")
        .tint(beanNotesTheme.accentColor)
    }

    @ViewBuilder
    private var topControls: some View {
        if beanNotesTheme == .bean {
            HStack(spacing: 12) {
                BeanAvatarView(size: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Bean's corner")
                        .font(.headline.weight(.bold))

                    Text("Ready for your next idea")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                settingsButton
            }
        } else {
            settingsButton
        }
    }

    private var settingsButton: some View {
        Button(action: openSettings) {
            Image(systemName: "gearshape")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
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
        .background(beanNotesTheme.cardBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                FolderProjectMarker(
                    colorHex: folder.colorHex,
                    theme: beanNotesTheme,
                    size: 20
                )

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
    @Environment(\.beanNotesTheme) private var beanNotesTheme

    var title: String
    var initialName: String
    var initialColorHex: String
    var save: (String, String) -> Bool

    @State private var name: String
    @State private var colorHex: String

    private let colors = [
        "#2563EB",
        "#0EA5E9",
        "#06B6D4",
        "#14B8A6",
        "#22C55E",
        "#84CC16",
        "#EAB308",
        "#F59E0B",
        "#F97316",
        "#EF4444",
        "#F43F5E",
        "#EC4899",
        "#D946EF",
        "#A855F7",
        "#8B5CF6",
        "#6366F1",
        "#64748B",
        "#111827"
    ]

    init(
        title: String,
        initialName: String,
        initialColorHex: String,
        save: @escaping (String, String) -> Bool
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
                    HStack(spacing: 12) {
                        FolderProjectMarker(
                            colorHex: colorHex,
                            theme: beanNotesTheme,
                            size: 46
                        )
                            .accessibilityHidden(true)

                        ColorPicker(
                            "Custom Color",
                            selection: Binding(
                                get: { Color(hex: colorHex) },
                                set: { colorHex = $0.hexRGB }
                            ),
                            supportsOpacity: false
                        )
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 6), spacing: 12) {
                        ForEach(colors, id: \.self) { candidate in
                            Button {
                                colorHex = candidate
                            } label: {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(hex: candidate))
                                    .frame(width: 34, height: 34)
                                    .overlay {
                                        if colorHex.caseInsensitiveCompare(candidate) == .orderedSame {
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(readableCheckmarkColor(for: candidate))
                                        }
                                    }
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
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
                        if save(name.trimmingCharacters(in: .whitespacesAndNewlines), colorHex) {
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func readableCheckmarkColor(for colorHex: String) -> Color {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(hex: colorHex).getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        let luminance = (0.299 * red) + (0.587 * green) + (0.114 * blue)
        return luminance > 0.68 ? .black : .white
    }
}

private struct FolderProjectMarker: View {
    var colorHex: String
    var theme: BeanNotesTheme
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hex: colorHex))

            if theme == .bean {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(readableForegroundColor)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(size > 24 ? 0.1 : 0), radius: 3, y: 1)
        .accessibilityHidden(true)
    }

    private var readableForegroundColor: Color {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(hex: colorHex).getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        let luminance = (0.299 * red) + (0.587 * green) + (0.114 * blue)
        return luminance > 0.64 ? .black.opacity(0.74) : .white
    }
}
