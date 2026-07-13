//
//  SettingsView.swift
//  BeanNotes
//

import SwiftData
import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @Query(sort: \NotebookFolder.name) private var folders: [NotebookFolder]
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @AppStorage(AppTheme.storageKey) private var appThemeRaw = AppTheme.system.rawValue
    @AppStorage(BeanNotesTheme.storageKey) private var beanNotesThemeRaw = BeanNotesTheme.defaultTheme.rawValue
    @AppStorage(LocalNotificationService.folderNotificationsEnabledKey) private var folderNotificationsEnabled = false
    @AppStorage(BeanVisitPolicy.enabledKey) private var beanVisitsEnabled = true
    @AppStorage("penPaletteMode") private var penPaletteModeRaw = PenPaletteMode.custom.rawValue
    @AppStorage(DrawingInputMode.storageKey) private var drawingInputModeRaw = DrawingInputMode.defaultMode.rawValue
    @AppStorage("pencilDoubleTapAction") private var doubleTapRaw = PencilDoubleTapAction.switchToEraser.rawValue
    @AppStorage(NoteEditorPageLayoutMode.storageKey) private var pageLayoutModeRaw = NoteEditorPageLayoutMode.scroll.rawValue
    @AppStorage(NoteEditorPageCreationMode.storageKey) private var pageCreationModeRaw = NoteEditorPageCreationMode.manual.rawValue
    @AppStorage(NoteBackground.defaultStyleRawKey) private var defaultBackgroundStyleRaw = NoteBackgroundStyle.plain.rawValue
    @AppStorage(NoteBackground.defaultColorHexKey) private var defaultBackgroundColorHex = BeanNotesTheme.defaultTheme.defaultNoteBackgroundHex

    @State private var storageUsage: LocalStorageUsageSnapshot?
    @State private var isLoadingStorageUsage = false
    @State private var isCleaningOldExports = false
    @State private var isConfirmingExportCleanup = false
    @State private var isConfirmingThemePaperBackground = false
    @State private var storageMessage: String?
    @State private var storageErrorMessage: String?
    @State private var backupSharePayload: SettingsSharePayload?
    @State private var isCreatingBackup = false
    @State private var backupProgress: Double?
    @State private var backupProgressMessage = "Preparing backup..."
    @State private var backupStatusMessage: String?
    @State private var backupErrorMessage: String?
    @State private var backupTask: Task<Void, Never>?
    @State private var notificationAuthorizationStatus = UNAuthorizationStatus.notDetermined
    @State private var isRequestingNotificationAuthorization = false
    @State private var notificationErrorMessage: String?
    @State private var isPreviewingBeanVisit = false
    @State private var beanVisitPreviewTask: Task<Void, Never>?

    private let oldExportAgeDays = 7

    private var selectedMoodTheme: BeanNotesTheme {
        BeanNotesTheme(rawValue: beanNotesThemeRaw) ?? .defaultTheme
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

    private var selectedDrawingInputMode: DrawingInputMode {
        DrawingInputMode(rawValue: drawingInputModeRaw) ?? DrawingInputMode.defaultMode
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

                    Button("Use Theme Paper Background") {
                        isConfirmingThemePaperBackground = true
                    }
                    .accessibilityIdentifier("settings.themePaperBackgroundButton")
                }

                Section("Notifications") {
                    Toggle("Folder Welcomes", isOn: $folderNotificationsEnabled)
                        .disabled(isRequestingNotificationAuthorization)

                    Text(notificationDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if notificationAuthorizationStatus == .denied {
                        Button("Open System Settings", action: openSystemSettings)
                    }

                    if let notificationErrorMessage {
                        Label(notificationErrorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                }

                if selectedMoodTheme == .bean {
                    Section("Bean Theme") {
                        Toggle("Occasional Bean Visits", isOn: $beanVisitsEnabled)

                        Text("When this is on, Bean may quietly peek into the main library after you have been there for a while. Visits never interrupt the note editor.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button(action: previewBeanVisit) {
                            Label("Invite Bean Now", systemImage: "pawprint.fill")
                        }
                        .disabled(isPreviewingBeanVisit)
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

                    Picker("Drawing Input", selection: $drawingInputModeRaw) {
                        ForEach(DrawingInputMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }

                    Text(selectedDrawingInputMode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Drawing uses one native PencilKit high-detail canvas at every zoom level.")
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
            .background {
                BeanNotesPaperBackground(theme: selectedMoodTheme, baseColor: selectedMoodTheme.appBackground)
                    .ignoresSafeArea()
            }
            .navigationTitle("Settings")
            .tint(selectedMoodTheme.accentColor)
            .onAppear(perform: migrateLegacyPaginationSettingIfNeeded)
            .task {
                await refreshStorageUsage()
                await refreshNotificationAuthorizationStatus()
            }
            .onChange(of: beanNotesThemeRaw) { _, rawValue in
                let theme = BeanNotesTheme(rawValue: rawValue) ?? .defaultTheme
                applyThemePaperBackground(for: theme)
                if theme != .bean {
                    hideBeanVisitPreview(animated: false)
                }
            }
            .onChange(of: folderNotificationsEnabled) { _, isEnabled in
                guard isEnabled else { return }

                Task {
                    await enableFolderNotifications()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }

                Task {
                    await refreshNotificationAuthorizationStatus()
                }
            }
            .alert(
                "Use \(selectedMoodTheme.label) paper background?",
                isPresented: $isConfirmingThemePaperBackground
            ) {
                Button("Cancel", role: .cancel) {}

                Button("Use \(selectedMoodTheme.label) Paper") {
                    applyThemePaperBackground(for: selectedMoodTheme)
                }
            } message: {
                Text(themePaperConfirmationMessage)
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
            .overlay(alignment: .bottomTrailing) {
                if isPreviewingBeanVisit {
                    BeanPetVisitView()
                        .padding(.trailing, 20)
                        .padding(.bottom, 14)
                        .transition(beanVisitPreviewTransition)
                        .zIndex(4)
                }
            }
            .onDisappear {
                backupTask?.cancel()
                beanVisitPreviewTask?.cancel()
                isPreviewingBeanVisit = false
            }
        }
        .environment(\.beanNotesTheme, selectedMoodTheme)
        .preferredColorScheme(selectedAppTheme.colorScheme)
        .presentationBackground(selectedMoodTheme.appBackground)
    }

    private var beanVisitPreviewTransition: AnyTransition {
        accessibilityReduceMotion
            ? .opacity
            : .move(edge: .trailing).combined(with: .opacity)
    }

    private var beanVisitPreviewAnimation: Animation {
        accessibilityReduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(response: 0.42, dampingFraction: 0.86)
    }

    private var themePaperConfirmationMessage: String {
        "Bean says, “Fresh paper coming right up!” New notes will use \(selectedMoodTheme.label)’s plain paper background. Existing notes will stay as they are."
    }

    private func applyThemePaperBackground(for theme: BeanNotesTheme) {
        let background = theme.defaultNoteBackground
        defaultBackgroundStyleRaw = background.storageStyleRaw
        defaultBackgroundColorHex = background.colorHex
    }

    @MainActor
    private func previewBeanVisit() {
        beanVisitPreviewTask?.cancel()
        BeanVisitPolicy.recordVisit()

        withAnimation(beanVisitPreviewAnimation) {
            isPreviewingBeanVisit = true
        }

        beanVisitPreviewTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: BeanVisitPolicy.displayDurationNanoseconds)
                guard !Task.isCancelled else { return }
                hideBeanVisitPreview(animated: true)
            } catch {
                guard !Task.isCancelled else { return }
                hideBeanVisitPreview(animated: false)
            }
        }
    }

    @MainActor
    private func hideBeanVisitPreview(animated: Bool) {
        beanVisitPreviewTask?.cancel()
        beanVisitPreviewTask = nil
        guard isPreviewingBeanVisit else { return }

        if animated {
            withAnimation(beanVisitPreviewAnimation) {
                isPreviewingBeanVisit = false
            }
        } else {
            isPreviewingBeanVisit = false
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

    private var notificationDescription: String {
        switch notificationAuthorizationStatus {
        case .authorized, .provisional, .ephemeral:
            folderNotificationsEnabled
                ? "BeanNotes will welcome newly created folders with a local notification."
                : "Turn this on if you want a local notification when a folder is created."
        case .denied:
            "Notifications are disabled for BeanNotes in System Settings."
        case .notDetermined:
            "This optional alert is requested only when you turn it on."
        @unknown default:
            "Notification availability could not be determined."
        }
    }

    @MainActor
    private func enableFolderNotifications() async {
        guard !isRequestingNotificationAuthorization else { return }

        isRequestingNotificationAuthorization = true
        notificationErrorMessage = nil
        defer { isRequestingNotificationAuthorization = false }

        do {
            let status = await LocalNotificationService.shared.authorizationStatus()
            let isAuthorized: Bool

            switch status {
            case .authorized, .provisional, .ephemeral:
                isAuthorized = true
            case .notDetermined:
                isAuthorized = try await LocalNotificationService.shared.requestAuthorization()
            case .denied:
                isAuthorized = false
            @unknown default:
                isAuthorized = false
            }

            notificationAuthorizationStatus = await LocalNotificationService.shared.authorizationStatus()
            guard folderNotificationsEnabled else { return }
            folderNotificationsEnabled = isAuthorized
        } catch {
            folderNotificationsEnabled = false
            notificationErrorMessage = error.localizedDescription
            await refreshNotificationAuthorizationStatus()
        }
    }

    @MainActor
    private func refreshNotificationAuthorizationStatus() async {
        notificationAuthorizationStatus = await LocalNotificationService.shared.authorizationStatus()

        switch notificationAuthorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        case .denied, .notDetermined:
            folderNotificationsEnabled = false
        @unknown default:
            folderNotificationsEnabled = false
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
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
            Group {
                if let brandImageName = theme.brandImageName {
                    Image(brandImageName)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(theme.accentColor)

                        Image(systemName: theme.symbolName)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.secondaryAccentColor.opacity(0.55), lineWidth: 2)
            }
            .accessibilityHidden(true)

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
        .background {
            BeanNotesPaperBackground(theme: theme, baseColor: theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
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
