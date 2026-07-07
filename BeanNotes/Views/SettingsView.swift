//
//  SettingsView.swift
//  BeanNotes
//

import SwiftData
import SwiftUI
import UIKit

struct SettingsView: View {
    @Query(sort: \NotebookFolder.name) private var folders: [NotebookFolder]

    @AppStorage(AppTheme.storageKey) private var appThemeRaw = AppTheme.system.rawValue
    @AppStorage(BeanNotesTheme.storageKey) private var beanNotesThemeRaw = BeanNotesTheme.standard.rawValue
    @AppStorage("penPaletteMode") private var penPaletteModeRaw = PenPaletteMode.custom.rawValue
    @AppStorage(DrawingRenderQuality.storageKey) private var drawingRenderQualityRaw = DrawingRenderQuality.defaultQuality.rawValue
    @AppStorage("pencilDoubleTapAction") private var doubleTapRaw = PencilDoubleTapAction.switchToEraser.rawValue
    @AppStorage(NoteEditorPageLayoutMode.storageKey) private var pageLayoutModeRaw = NoteEditorPageLayoutMode.scroll.rawValue
    @AppStorage(NoteEditorPageCreationMode.storageKey) private var pageCreationModeRaw = NoteEditorPageCreationMode.manual.rawValue
    @AppStorage(NoteBackground.defaultStyleRawKey) private var defaultBackgroundStyleRaw = NoteBackgroundStyle.plain.rawValue
    @AppStorage(NoteBackground.defaultColorHexKey) private var defaultBackgroundColorHex = NoteBackground.defaultColorHex

    @State private var storageUsage: LocalStorageUsageSnapshot?
    @State private var isLoadingStorageUsage = false
    @State private var isCleaningOldExports = false
    @State private var isConfirmingExportCleanup = false
    @State private var storageMessage: String?
    @State private var storageErrorMessage: String?
    @State private var backupSharePayload: SettingsSharePayload?
    @State private var isCreatingBackup = false
    @State private var backupProgress: Double?
    @State private var backupProgressMessage = "Preparing backup..."
    @State private var backupStatusMessage: String?
    @State private var backupErrorMessage: String?
    @State private var backupTask: Task<Void, Never>?

    private let oldExportAgeDays = 7

    private var selectedMoodTheme: BeanNotesTheme {
        BeanNotesTheme(rawValue: beanNotesThemeRaw) ?? .standard
    }

    private var selectedAppTheme: AppTheme {
        AppTheme(rawValue: appThemeRaw) ?? .system
    }

    private var selectedPageLayoutMode: NoteEditorPageLayoutMode {
        NoteEditorPageLayoutMode(rawValue: pageLayoutModeRaw) ?? .scroll
    }

    private var selectedPageCreationMode: NoteEditorPageCreationMode {
        NoteEditorPageCreationMode(rawValue: pageCreationModeRaw) ?? .manual
    }

    private var selectedDrawingRenderQuality: DrawingRenderQuality {
        DrawingRenderQuality(rawValue: drawingRenderQualityRaw) ?? DrawingRenderQuality.defaultQuality
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Theme") {
                    Picker("Theme", selection: $beanNotesThemeRaw) {
                        ForEach(BeanNotesTheme.allCases) { theme in
                            Text(theme.label).tag(theme.rawValue)
                        }
                    }

                    Picker("Appearance", selection: $appThemeRaw) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.label).tag(theme.rawValue)
                        }
                    }

                    ThemePreviewCard(theme: selectedMoodTheme)
                        .padding(.vertical, 4)

                    Button("Use Theme Paper for New Notes") {
                        defaultBackgroundColorHex = selectedMoodTheme.defaultNoteBackgroundHex
                    }

                    Button("Apply Theme Icon") {
                        AppIconService.applyIcon(for: selectedMoodTheme)
                    }
                }

                Section("Default Note Background") {
                    NoteBackgroundPickerView(
                        styleRaw: $defaultBackgroundStyleRaw,
                        colorHex: $defaultBackgroundColorHex
                    )
                    .padding(.vertical, 6)
                }

                Section("Pagination") {
                    Picker("Display", selection: $pageLayoutModeRaw) {
                        ForEach(NoteEditorPageLayoutMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }

                    if selectedPageLayoutMode == .scroll {
                        Picker("New Pages", selection: $pageCreationModeRaw) {
                            ForEach(NoteEditorPageCreationMode.allCases) { mode in
                                Text(mode.label).tag(mode.rawValue)
                            }
                        }

                        Text(selectedPageCreationMode.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(selectedPageLayoutMode.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Storage") {
                    if let storageUsage {
                        StorageUsageRow(
                            title: "Total",
                            byteCount: storageUsage.totalByteCount,
                            fileCount: storageUsage.totalFileCount,
                            isTotal: true
                        )

                        ForEach(storageUsage.directories) { usage in
                            StorageUsageRow(
                                title: usage.directory.settingsLabel,
                                byteCount: usage.byteCount,
                                fileCount: usage.fileCount
                            )
                        }
                    } else if isLoadingStorageUsage {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Calculating storage")
                        }
                    }

                    if let storageMessage {
                        Text(storageMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let storageErrorMessage {
                        Text(storageErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button {
                        Task {
                            await refreshStorageUsage()
                        }
                    } label: {
                        Label("Refresh Usage", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoadingStorageUsage || isCleaningOldExports)

                    Button(role: .destructive) {
                        isConfirmingExportCleanup = true
                    } label: {
                        Label("Clean Up Old Exports", systemImage: "trash")
                    }
                    .disabled(isLoadingStorageUsage || isCleaningOldExports || (storageUsage?.usage(for: .exports)?.fileCount ?? 0) == 0)

                    if isCleaningOldExports {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Cleaning exports")
                        }
                    }
                }

                Section("Library Backup") {
                    Button {
                        exportLibraryBackup()
                    } label: {
                        Label("Export .beannotes Backup", systemImage: "externaldrive.badge.timemachine")
                    }
                    .disabled(isCreatingBackup)

                    Text("Includes folders, note metadata, drawings, imported files, thumbnails, and exports.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let backupStatusMessage {
                        Text(backupStatusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let backupErrorMessage {
                        Text(backupErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("Apple Pencil") {
                    Picker("Pen Palette", selection: $penPaletteModeRaw) {
                        ForEach(PenPaletteMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }

                    Picker("Drawing Detail", selection: $drawingRenderQualityRaw) {
                        ForEach(DrawingRenderQuality.allCases) { quality in
                            Text(quality.label).tag(quality.rawValue)
                        }
                    }

                    Text(selectedDrawingRenderQuality.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Double Tap", selection: $doubleTapRaw) {
                        ForEach(PencilDoubleTapAction.allCases) { action in
                            Text(action.label).tag(action.rawValue)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(selectedMoodTheme.appBackground)
            .navigationTitle("Settings")
            .tint(selectedMoodTheme.accentColor)
            .onAppear(perform: migrateLegacyPaginationSettingIfNeeded)
            .task {
                await refreshStorageUsage()
            }
            .onChange(of: beanNotesThemeRaw) { _, rawValue in
                let theme = BeanNotesTheme(rawValue: rawValue) ?? .standard
                defaultBackgroundColorHex = theme.defaultNoteBackgroundHex
            }
            .confirmationDialog(
                "Clean up exports older than \(oldExportAgeDays) days?",
                isPresented: $isConfirmingExportCleanup,
                titleVisibility: .visible
            ) {
                Button("Delete Old Exports", role: .destructive) {
                    Task {
                        await cleanOldExports()
                    }
                }

                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $backupSharePayload) { payload in
                SettingsActivityView(activityItems: [payload.url])
            }
            .overlay {
                if isCreatingBackup {
                    BeanNotesProgressOverlay(
                        title: "Creating Backup",
                        message: backupProgressMessage,
                        progress: backupProgress,
                        cancel: cancelLibraryBackup
                    )
                }
            }
            .onDisappear {
                backupTask?.cancel()
            }
        }
        .environment(\.beanNotesTheme, selectedMoodTheme)
        .preferredColorScheme(selectedAppTheme.colorScheme)
        .presentationBackground(selectedMoodTheme.appBackground)
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

    @MainActor
    private func refreshStorageUsage() async {
        guard !isLoadingStorageUsage else { return }

        isLoadingStorageUsage = true
        storageErrorMessage = nil

        let rootURL = LocalStorageService().rootURL

        do {
            let snapshot = try await Task.detached(priority: .utility) {
                try LocalStorageService(rootURL: rootURL).storageUsageSnapshot()
            }.value
            storageUsage = snapshot
        } catch {
            storageErrorMessage = error.localizedDescription
        }

        isLoadingStorageUsage = false
    }

    @MainActor
    private func cleanOldExports() async {
        guard !isCleaningOldExports else { return }

        isCleaningOldExports = true
        storageMessage = nil
        storageErrorMessage = nil

        let rootURL = LocalStorageService().rootURL
        let cutoffDate = Calendar.current.date(
            byAdding: .day,
            value: -oldExportAgeDays,
            to: Date()
        ) ?? Date()

        do {
            let report = try await Task.detached(priority: .utility) {
                try LocalStorageService(rootURL: rootURL).removeExports(olderThan: cutoffDate)
            }.value

            let removedSize = Self.storageByteFormatter.string(fromByteCount: report.removedByteCount)
            let cleanupErrorMessage = report.hasFailures
                ? "Some export files could not be removed."
                : nil

            await refreshStorageUsage()
            storageMessage = "Removed \(report.removedFileCount) \(report.removedFileCount == 1 ? "file" : "files") (\(removedSize))."
            storageErrorMessage = cleanupErrorMessage
        } catch {
            storageErrorMessage = error.localizedDescription
        }

        isCleaningOldExports = false
    }

    @MainActor
    private func exportLibraryBackup() {
        guard !isCreatingBackup else { return }

        isCreatingBackup = true
        backupProgress = 0
        backupProgressMessage = "Preparing backup..."
        backupStatusMessage = nil
        backupErrorMessage = nil

        let foldersSnapshot = folders

        backupTask?.cancel()
        backupTask = Task { @MainActor in
            var backupURL: URL?

            defer {
                isCreatingBackup = false
                backupProgress = nil
                backupProgressMessage = "Preparing backup..."
                backupTask = nil
            }

            do {
                try await Task.sleep(nanoseconds: 80_000_000)
                try Task.checkCancellation()

                let result = try await LibraryBackupService().exportLibraryBackup(folders: foldersSnapshot) { fraction, message in
                    backupProgress = fraction
                    backupProgressMessage = message
                }
                backupURL = result.url

                try Task.checkCancellation()
                let backupSize = Self.storageByteFormatter.string(fromByteCount: result.byteCount)
                backupStatusMessage = "Created backup with \(result.fileCount) \(result.fileCount == 1 ? "file" : "files") (\(backupSize))."
                backupSharePayload = SettingsSharePayload(url: result.url)
                await refreshStorageUsage()
            } catch is CancellationError {
                if let backupURL {
                    try? FileManager.default.removeItem(at: backupURL)
                    await refreshStorageUsage()
                }
                backupStatusMessage = "Backup canceled."
            } catch {
                backupErrorMessage = error.localizedDescription
            }
        }
    }

    private func cancelLibraryBackup() {
        backupProgressMessage = "Canceling backup..."
        backupTask?.cancel()
    }

    private static let storageByteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()
}

private struct SettingsSharePayload: Identifiable {
    let id = UUID()
    var url: URL
}

private struct SettingsActivityView: UIViewControllerRepresentable {
    var activityItems: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct ThemePreviewCard: View {
    var theme: BeanNotesTheme

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.accentColor)

                Image(systemName: theme.symbolName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 56, height: 56)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.secondaryAccentColor.opacity(0.55), lineWidth: 2)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(theme.label)
                    .font(.headline.weight(.semibold))

                Text(theme.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    ThemeSwatch(color: theme.appBackground)
                    ThemeSwatch(color: theme.sidebarBackground)
                    ThemeSwatch(color: theme.accentColor)
                    ThemeSwatch(color: theme.defaultNoteBackgroundHex)
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.accentColor.opacity(0.16), lineWidth: 1)
        }
    }
}

private struct StorageUsageRow: View {
    var title: String
    var byteCount: Int64
    var fileCount: Int
    var isTotal = false

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(isTotal ? .body.weight(.semibold) : .body)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.byteFormatter.string(fromByteCount: byteCount))
                    .font(isTotal ? .body.weight(.semibold) : .body)
                    .monospacedDigit()

                Text("\(fileCount) \(fileCount == 1 ? "file" : "files")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()
}

private extension StorageDirectory {
    var settingsLabel: String {
        switch self {
        case .drawings:
            "Drawings"
        case .imports:
            "Imports"
        case .thumbnails:
            "Thumbnails"
        case .exports:
            "Exports"
        }
    }
}

private struct ThemeSwatch: View {
    var color: Color

    init(color: Color) {
        self.color = color
    }

    init(color: String) {
        self.color = Color(hex: color)
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 18, height: 18)
            .overlay {
                Circle()
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
            }
    }
}
