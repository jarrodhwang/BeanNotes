//
//  SettingsView.swift
//  BeanNotes
//

import SwiftData
import SwiftUI

struct SettingsView: View {
    private enum SettingsTab: Hashable {
        case theme
        case noteStyle
        case pencilStyle
        case backup
    }

    @Query(sort: \NotebookFolder.name) private var folders: [NotebookFolder]
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @AppStorage(AppTheme.storageKey) private var appThemeRaw = AppTheme.system.rawValue
    @AppStorage(BeanNotesTheme.storageKey) private var beanNotesThemeRaw = BeanNotesTheme.defaultTheme.rawValue
    @AppStorage(BeanVisitPolicy.enabledKey) private var beanVisitsEnabled = true
    @AppStorage(BeanVisitPolicy.allowsInterruptionsKey) private var beanVisitsMayInterrupt = false
    @AppStorage(BeanVisitPolicy.focusReminderIntervalKey) private var beanFocusReminderInterval = BeanVisitPolicy.defaultFocusReminderInterval
    @AppStorage(BeanVisitPolicy.blueberryEnabledKey) private var blueberryVisitsEnabled = true
    @AppStorage(BeanVisitPolicy.blueberryAllowsInterruptionsKey) private var blueberryVisitsMayInterrupt = false
    @AppStorage(BeanVisitPolicy.blueberryFocusReminderIntervalKey) private var blueberryFocusReminderInterval = BeanVisitPolicy.defaultFocusReminderInterval
    @AppStorage("penPaletteMode") private var penPaletteModeRaw = PenPaletteMode.custom.rawValue
    @AppStorage(DrawingPaletteConfiguration.colorCountStorageKey)
    private var paletteColorCount = DrawingPaletteConfiguration.defaultColorCountForCurrentDevice
    @AppStorage(DrawingInputMode.storageKey) private var drawingInputModeRaw = DrawingInputMode.defaultMode.rawValue
    @AppStorage("pencilDoubleTapAction") private var doubleTapRaw = PencilDoubleTapAction.switchToEraser.rawValue
    @AppStorage(NoteEditorPageLayoutMode.storageKey) private var pageLayoutModeRaw = NoteEditorPageLayoutMode.scroll.rawValue
    @AppStorage(PaperSize.storageKey) private var paperSizeRaw = PaperSize.defaultPaperSize.rawValue
    @AppStorage(CustomPaperSize.widthStorageKey) private var customPaperWidth = Double(CustomPaperSize.defaultDimensions.width)
    @AppStorage(CustomPaperSize.heightStorageKey) private var customPaperHeight = Double(CustomPaperSize.defaultDimensions.height)
    @AppStorage(NoteBackground.defaultStyleRawKey) private var defaultBackgroundStyleRaw = NoteBackgroundStyle.plain.rawValue
    @AppStorage(NoteBackground.defaultColorHexKey) private var defaultBackgroundColorHex = NoteBackground.defaultColorHex
    @AppStorage(NoteBackground.showsBeanArtworkKey) private var showsBeanArtwork = false
    @AppStorage(NoteBackground.showsBlueberryArtworkKey) private var showsBlueberryArtwork = true

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
    @State private var beanVisitPreview: BeanVisit?
    @State private var beanVisitPreviewTask: Task<Void, Never>?
    @State private var selectedTab: SettingsTab = .theme

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

    private var selectedDrawingInputMode: DrawingInputMode {
        DrawingInputMode(rawValue: drawingInputModeRaw) ?? DrawingInputMode.defaultMode
    }

    private var selectedPenPaletteMode: PenPaletteMode {
        PenPaletteMode(rawValue: penPaletteModeRaw) ?? .custom
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsTabPicker
            selectedTabContent
        }
        .background {
            BeanNotesPaperBackground(theme: selectedMoodTheme, baseColor: selectedMoodTheme.appBackground)
                .ignoresSafeArea()
        }
        .tint(selectedMoodTheme.accentColor)
        .onAppear {
            NoteBackground.migrateLegacyThemeControlledDefaultsIfNeeded()
            migrateLegacyPaginationSettingIfNeeded()
            restorePaletteColorCount()
        }
        .task {
            await refreshStorageUsage()
        }
        .onChange(of: beanNotesThemeRaw) { _, _ in
            hideBeanVisitPreview(animated: false)
        }
        .onChange(of: paletteColorCount) { _, _ in
            normalizePaletteColorCountIfNeeded()
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
        .overlay {
            BeanVisitOverlayView(visit: beanVisitPreview)
        }
        .onDisappear {
            backupTask?.cancel()
            beanVisitPreviewTask?.cancel()
            beanVisitPreview = nil
        }
        .environment(\.beanNotesTheme, selectedMoodTheme)
        .preferredColorScheme(selectedAppTheme.colorScheme)
        .presentationBackground(selectedMoodTheme.appBackground)
    }

    private var settingsTabPicker: some View {
        Picker("Settings section", selection: $selectedTab) {
            Label("Theme", systemImage: "paintpalette")
                .tag(SettingsTab.theme)
            Label("Note Style", systemImage: "doc.text")
                .tag(SettingsTab.noteStyle)
            Label("Pencil Style", systemImage: "pencil")
                .tag(SettingsTab.pencilStyle)
            Label("Backup", systemImage: "externaldrive")
                .tag(SettingsTab.backup)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("settings.sectionPicker")
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case .theme:
            themeSettings
        case .noteStyle:
            noteStyleSettings
        case .pencilStyle:
            pencilStyleSettings
        case .backup:
            backupSettings
        }
    }

    private var themeSettings: some View {
        Form {
            Section("Theme") {
                Picker("Bean Theme", selection: $beanNotesThemeRaw) {
                    ForEach(BeanNotesTheme.allCases) { theme in
                        Text(theme.label).tag(theme.rawValue)
                    }
                }

                Picker("Theme", selection: $appThemeRaw) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.label).tag(theme.rawValue)
                    }
                }

                ThemePreviewCard(theme: selectedMoodTheme)
                    .padding(.vertical, 4)

                if selectedMoodTheme == .bean {
                    Toggle("Show Bean on Note Backgrounds", isOn: $showsBeanArtwork)
                        .accessibilityIdentifier("settings.beanArtworkToggle")

                    Text(selectedMoodTheme.paperArtworkDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if selectedMoodTheme == .blueberry {
                    Toggle(selectedMoodTheme.paperArtworkToggleTitle, isOn: $showsBlueberryArtwork)
                        .accessibilityIdentifier("settings.blueberryArtworkToggle")

                    Text(selectedMoodTheme.paperArtworkDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if selectedMoodTheme == .bean {
                mascotVisitSettings(
                    theme: .bean,
                    visitsEnabled: $beanVisitsEnabled,
                    visitsMayInterrupt: $beanVisitsMayInterrupt,
                    focusReminderInterval: $beanFocusReminderInterval
                )
            } else if selectedMoodTheme == .blueberry {
                mascotVisitSettings(
                    theme: .blueberry,
                    visitsEnabled: $blueberryVisitsEnabled,
                    visitsMayInterrupt: $blueberryVisitsMayInterrupt,
                    focusReminderInterval: $blueberryFocusReminderInterval
                )
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var noteStyleSettings: some View {
        Form {
            Section("Default Note Background") {
                NoteBackgroundPickerView(
                    styleRaw: $defaultBackgroundStyleRaw,
                    colorHex: $defaultBackgroundColorHex,
                    onStyleChanged: { style in
                        if style == .chalkboard {
                            paperSizeRaw = PaperSize.chalkboard.rawValue
                        }
                    }
                )
                .padding(.vertical, 6)
            }

            Section("Pagination") {
                Picker("Display", selection: $pageLayoutModeRaw) {
                    ForEach(NoteEditorPageLayoutMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }

                Text(selectedPageLayoutMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Pages are never added automatically. Tap the plus button at the bottom to append one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Default Paper Size") {
                Picker("Paper Size", selection: $paperSizeRaw) {
                    ForEach(PaperSize.allCases) { paperSize in
                        Text("\(paperSize.label) (\(paperSize.dimensionsLabel))")
                            .tag(paperSize.rawValue)
                    }

                    Text("Custom").tag(CustomPaperSize.selectionRawValue)
                }

                if paperSizeRaw == CustomPaperSize.selectionRawValue {
                    customPaperSizeFields
                }

                Text("Applies to new notes. Existing pages keep their current size.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var pencilStyleSettings: some View {
        Form {
            Section("Apple Pencil") {
                Picker("Pen Palette", selection: $penPaletteModeRaw) {
                    ForEach(PenPaletteMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }

                if selectedPenPaletteMode == .custom {
                    Picker("Palette Colors", selection: $paletteColorCount) {
                        ForEach(DrawingPaletteConfiguration.supportedColorCounts, id: \.self) { colorCount in
                            Text("\(colorCount)").tag(colorCount)
                        }
                    }
                    .accessibilityIdentifier("settings.paletteColorCountPicker")

                    Text("Choose how many colors appear in the custom palette. Hidden colors stay saved when you show fewer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
    }

    private var backupSettings: some View {
        Form {
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
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func mascotVisitSettings(
        theme: BeanNotesTheme,
        visitsEnabled: Binding<Bool>,
        visitsMayInterrupt: Binding<Bool>,
        focusReminderInterval: Binding<TimeInterval>
    ) -> some View {
        Section(theme.visitThemeSectionTitle) {
            Toggle(theme.visitToggleTitle, isOn: visitsEnabled)

            ThemeHintView(theme: theme, message: theme.visitHintMessage)

            Toggle(theme.visitInterruptionsToggleTitle, isOn: visitsMayInterrupt)
                .disabled(!visitsEnabled.wrappedValue)
                .accessibilityIdentifier(
                    theme == .bean
                        ? "settings.beanInterruptToggle"
                        : "settings.blueberryInterruptToggle"
                )

            Text(theme.visitInterruptionsDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Focus check-in", selection: focusReminderInterval) {
                ForEach(BeanVisitPolicy.focusReminderOptions) { option in
                    Text(option.label).tag(option.interval)
                }
            }
            .disabled(!visitsEnabled.wrappedValue || visitsMayInterrupt.wrappedValue)

            Button {
                previewBeanVisit(theme: theme)
            } label: {
                if theme == .bean {
                    Label(theme.inviteVisitTitle, systemImage: "pawprint.fill")
                } else {
                    HStack(spacing: 8) {
                        ThemeBadgeView(theme: theme, size: 24)
                        Text(theme.inviteVisitTitle)
                    }
                }
            }
            .disabled(beanVisitPreview != nil)
            .accessibilityIdentifier(
                theme == .bean
                    ? "settings.inviteBeanButton"
                    : "settings.inviteBlueberryButton"
            )
        }
    }

    private var customPaperSizeFields: some View {
        Group {
            TextField("Width (pt)", value: $customPaperWidth, format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.decimalPad)
                .accessibilityIdentifier("settings.customPaperWidth")

            TextField("Height (pt)", value: $customPaperHeight, format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.decimalPad)
                .accessibilityIdentifier("settings.customPaperHeight")

            if !CustomPaperSize.isValid(width: customPaperWidth, height: customPaperHeight) {
                Text("Width and height must each be between 1 and 4096 points.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var beanVisitPreviewAnimation: Animation {
        accessibilityReduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(response: 0.42, dampingFraction: 0.86)
    }

    @MainActor
    private func previewBeanVisit(theme: BeanNotesTheme) {
        beanVisitPreviewTask?.cancel()

        withAnimation(beanVisitPreviewAnimation) {
            beanVisitPreview = BeanVisit.make(reason: .friendly, theme: theme)
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
        guard beanVisitPreview != nil else { return }

        if animated {
            withAnimation(beanVisitPreviewAnimation) {
                beanVisitPreview = nil
            }
        } else {
            beanVisitPreview = nil
        }
    }

    private func migrateLegacyPaginationSettingIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: NoteEditorPageLayoutMode.storageKey) == nil,
              let rawValue = defaults.string(forKey: NoteEditorPageFlowMode.storageKey),
              let legacyMode = NoteEditorPageFlowMode(rawValue: rawValue) else {
            return
        }

        pageLayoutModeRaw = legacyMode.migratedLayoutMode.rawValue
    }

    private func normalizePaletteColorCountIfNeeded() {
        let normalized = DrawingPaletteConfiguration.normalizedColorCount(paletteColorCount)
        guard paletteColorCount != normalized else { return }
        paletteColorCount = normalized
    }

    private func restorePaletteColorCount() {
        paletteColorCount = DrawingPaletteConfiguration.persistedColorCountForCurrentDevice()
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
                    ThemeSwatch(color: theme.notePaperPreviewHex)
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
