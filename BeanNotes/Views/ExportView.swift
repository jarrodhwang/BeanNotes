//
//  ExportView.swift
//  BeanNotes
//

import SwiftUI
import UIKit

struct ExportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.beanNotesTheme) private var beanNotesTheme

    var note: NoteDocument
    var page: NotePage
    var service = ImportExportService()

    @State private var path: [ExportRoute] = []
    @State private var standardFormat = ExportFormat.pdf
    @State private var advancedScope = ExportScope.currentPage
    @State private var advancedFormat = ExportFormat.pdf
    @State private var sharePayload: ExportSharePayload?
    @State private var savePayload: ExportSavePayload?
    @State private var isExporting = false
    @State private var exportProgress: Double?
    @State private var exportProgressMessage = "Preparing export..."
    @State private var exportTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var didPrepareAdvancedExport = false
    @State private var pageBackgroundMode = ExportPageBackgroundMode.original
    @State private var customBackgroundStyleRaw = NoteBackgroundStyle.plain.rawValue
    @State private var customBackgroundColorHex = NoteBackground.defaultColorHex
    @State private var themeArtworkOverride: Bool?
    @State private var pdfQuality = ExportPDFQuality.best
    @State private var imageResolution = ExportImageResolution.threeX
    @State private var jpegQuality = ExportJPEGQuality.best

    private enum ExportRoute: Hashable {
        case standard(ExportScope)
        case advanced
    }

    private enum ExportScope: String, CaseIterable, Hashable, Identifiable {
        case currentPage
        case allPages

        var id: String { rawValue }

        var label: String {
            switch self {
            case .currentPage:
                "Current Page"
            case .allPages:
                "All Pages"
            }
        }

        var navigationTitle: String {
            switch self {
            case .currentPage:
                "Export Current Page"
            case .allPages:
                "Export All Pages"
            }
        }
    }

    private enum ExportDestination {
        case share
        case saveToFiles

        var progressMessage: String {
            switch self {
            case .share:
                "Opening share sheet..."
            case .saveToFiles:
                "Opening Files..."
            }
        }
    }

    private var pageOriginalAttachments: [Attachment] {
        page.attachments
            .filter { !$0.rendersBehindDrawing && $0.isVisibleInCurrentDocumentVersion }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private var noteOriginalAttachments: [Attachment] {
        note.sortedPages
            .flatMap(\.attachments)
            .filter { !$0.rendersBehindDrawing && $0.isVisibleInCurrentDocumentVersion }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        NavigationStack(path: $path) {
            exportMenu
                .navigationDestination(for: ExportRoute.self) { route in
                    switch route {
                    case .standard(let scope):
                        standardExportPage(scope: scope)
                    case .advanced:
                        advancedExportPage
                    }
                }
        }
        .sheet(item: $sharePayload) { payload in
            ActivityView(activityItems: payload.urls) {
                finishPresentation(payload)
            }
        }
        .sheet(item: $savePayload) { payload in
            ExportDocumentPicker(urls: payload.urls) {
                finishPresentation(payload)
            }
        }
        .alert("Export Failed", isPresented: errorAlertIsPresented) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "BeanNotes could not create the export.")
        }
        .onAppear {
            prepareAdvancedExportIfNeeded()
        }
        .onDisappear {
            exportTask?.cancel()
        }
        .overlay {
            if isExporting {
                BeanNotesProgressOverlay(
                    title: "Exporting",
                    message: exportProgressMessage,
                    progress: exportProgress,
                    cancel: cancelExport
                )
            }
        }
    }

    private var exportMenu: some View {
        List {
            if beanNotesTheme.supportsFriendlyVisits {
                Section {
                    ThemeHintView(
                        theme: beanNotesTheme,
                        message: beanNotesTheme.mascotExportHint
                    )
                }
            }

            Section("Export") {
                NavigationLink(value: ExportRoute.standard(.currentPage)) {
                    Label("Current Page", systemImage: "doc")
                }
                .accessibilityIdentifier("export.scope.currentPage")

                NavigationLink(value: ExportRoute.standard(.allPages)) {
                    Label("All Pages", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("export.scope.allPages")

                NavigationLink(value: ExportRoute.advanced) {
                    Label("Advanced Export", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("export.advanced")
            }

            if !pageOriginalAttachments.isEmpty {
                Section("Current Page Originals") {
                    ForEach(pageOriginalAttachments) { attachment in
                        Button {
                            shareOriginals([attachment])
                        } label: {
                            Label(originalLabel(for: attachment), systemImage: icon(for: attachment))
                        }
                    }
                }
            }

            if noteOriginalAttachments.count > pageOriginalAttachments.count {
                Section("All Original Files") {
                    Button {
                        shareOriginals(noteOriginalAttachments)
                    } label: {
                        Label("Share All Originals", systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .navigationTitle("Export")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            doneToolbar
        }
    }

    private func standardExportPage(scope: ExportScope) -> some View {
        List {
            formatSection(selection: $standardFormat, scope: scope)
            destinationSection(
                scope: scope,
                format: standardFormat,
                options: .standard
            )
        }
        .navigationTitle(scope.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            doneToolbar
        }
    }

    private var advancedExportPage: some View {
        List {
            Section("Pages") {
                Picker("Pages", selection: $advancedScope) {
                    ForEach(ExportScope.allCases) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Pages to export")
                .accessibilityIdentifier("export.advanced.scope")
            }

            formatSection(selection: $advancedFormat, scope: advancedScope)

            Section("Page Appearance") {
                Picker("Page Background", selection: $pageBackgroundMode) {
                    ForEach(ExportPageBackgroundMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .accessibilityIdentifier("export.pageBackground")

                if pageBackgroundMode == .custom {
                    NoteBackgroundPickerView(
                        styleRaw: $customBackgroundStyleRaw,
                        colorHex: $customBackgroundColorHex,
                        artworkVisibilityOverride: includesThemeArtwork
                    )
                }

                if beanNotesTheme.supportsFriendlyVisits {
                    Toggle(themeArtworkLabel, isOn: includesThemeArtworkBinding)
                        .disabled(pageBackgroundMode == .none)
                        .accessibilityIdentifier("export.themeArtwork")
                }

                if pageBackgroundMode == .none {
                    Text("PNG keeps the page background transparent. PDF and JPEG use white where transparency is unavailable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            qualitySection

            Section {
                Button("Reset Advanced Options", action: resetAdvancedExport)
                    .accessibilityIdentifier("export.resetAdvanced")
            }

            destinationSection(
                scope: advancedScope,
                format: advancedFormat,
                options: advancedExportOptions
            )
        }
        .navigationTitle("Advanced Export")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            doneToolbar
        }
    }

    @ToolbarContentBuilder
    private var doneToolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func formatSection(selection: Binding<ExportFormat>, scope: ExportScope) -> some View {
        Section {
            ForEach(ExportFormat.allCases) { format in
                Button {
                    selection.wrappedValue = format
                } label: {
                    HStack {
                        Label(format.label, systemImage: icon(for: format))
                        Spacer()
                        if selection.wrappedValue == format {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .foregroundStyle(.primary)
                .accessibilityAddTraits(selection.wrappedValue == format ? .isSelected : [])
                .accessibilityIdentifier("export.format.\(format.rawValue)")
            }
        } header: {
            Text("File Format")
        } footer: {
            if scope == .allPages {
                Text("PDF combines all pages into one file. PNG and JPEG create one image per page.")
            }
        }
    }

    @ViewBuilder
    private var qualitySection: some View {
        switch advancedFormat {
        case .pdf:
            Section("PDF Quality") {
                Picker("Quality", selection: $pdfQuality) {
                    ForEach(ExportPDFQuality.allCases) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("export.pdfQuality")
            }
        case .png:
            imageResolutionSection
        case .jpeg:
            imageResolutionSection
            Section("JPEG Quality") {
                Picker("Quality", selection: $jpegQuality) {
                    ForEach(ExportJPEGQuality.allCases) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("export.jpegQuality")
            }
        }
    }

    private var imageResolutionSection: some View {
        Section("Image Resolution") {
            Picker("Resolution", selection: $imageResolution) {
                ForEach(ExportImageResolution.allCases) { resolution in
                    Text(resolution.label).tag(resolution)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("export.imageResolution")
        }
    }

    private func destinationSection(
        scope: ExportScope,
        format: ExportFormat,
        options: ExportOptions
    ) -> some View {
        Section {
            Button {
                export(scope: scope, format: format, options: options, destination: .share)
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("export.destination.share")

            Button {
                export(scope: scope, format: format, options: options, destination: .saveToFiles)
            } label: {
                Label("Save to Files", systemImage: "folder")
            }
            .accessibilityIdentifier("export.destination.files")
        } header: {
            Text("Destination")
        } footer: {
            Text("Share sends the export to another app or service. Save to Files lets you choose a folder on this device or in iCloud Drive.")
        }
        .disabled(isExporting)
    }

    private var customPageBackground: NoteBackground {
        NoteBackground.fromDefaults(
            styleRaw: customBackgroundStyleRaw,
            colorHex: customBackgroundColorHex
        )
    }

    private var advancedExportOptions: ExportOptions {
        ExportOptions(
            pageBackgroundMode: pageBackgroundMode,
            customPageBackground: customPageBackground,
            includesThemeArtwork: themeArtworkOverride,
            pdfQuality: pdfQuality,
            imageResolution: imageResolution,
            jpegQuality: jpegQuality
        )
    }

    private var includesThemeArtwork: Bool {
        pageBackgroundMode != .none
            && (themeArtworkOverride ?? NoteBackground.showsArtwork(for: beanNotesTheme))
    }

    private var includesThemeArtworkBinding: Binding<Bool> {
        Binding(
            get: { includesThemeArtwork },
            set: { themeArtworkOverride = $0 }
        )
    }

    private var themeArtworkLabel: String {
        switch beanNotesTheme {
        case .standard:
            "Include Theme Background Art"
        case .bean:
            "Include Bean Background Art"
        case .blueberry:
            "Include Blueberry Background Art"
        }
    }

    private var errorAlertIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func prepareAdvancedExportIfNeeded() {
        guard !didPrepareAdvancedExport else { return }
        didPrepareAdvancedExport = true
        customBackgroundStyleRaw = page.backgroundStyleRaw
        customBackgroundColorHex = page.backgroundColorHex
    }

    private func resetAdvancedExport() {
        advancedScope = .currentPage
        advancedFormat = .pdf
        pageBackgroundMode = .original
        customBackgroundStyleRaw = page.backgroundStyleRaw
        customBackgroundColorHex = page.backgroundColorHex
        themeArtworkOverride = nil
        pdfQuality = .best
        imageResolution = .threeX
        jpegQuality = .best
    }

    private func export(
        scope: ExportScope,
        format: ExportFormat,
        options: ExportOptions,
        destination: ExportDestination
    ) {
        exportItems(destination: destination, cleanupGeneratedFiles: true) { progress in
            switch scope {
            case .currentPage:
                return [try await service.exportPageForSharing(
                    page,
                    format: format,
                    options: options,
                    progress: progress
                )]
            case .allPages:
                return try await service.exportNoteForSharing(
                    note,
                    format: format,
                    options: options,
                    progress: progress
                )
            }
        }
    }

    private func shareOriginals(_ attachments: [Attachment]) {
        exportItems(destination: .share, cleanupGeneratedFiles: false) {
            $0?(nil, "Preparing original files...")
            await Task.yield()
            return try attachments.map { try service.originalFileURL(for: $0) }
        }
    }

    private func exportItems(
        destination: ExportDestination,
        cleanupGeneratedFiles: Bool,
        _ makeURLs: @escaping (ImportExportProgressHandler?) async throws -> [URL]
    ) {
        guard !isExporting else { return }
        isExporting = true
        exportProgress = 0
        exportProgressMessage = "Preparing export..."

        exportTask?.cancel()
        exportTask = Task { @MainActor in
            var exportedURLs: [URL] = []

            defer {
                isExporting = false
                exportProgress = nil
                exportProgressMessage = "Preparing export..."
                exportTask = nil
            }

            do {
                try Task.checkCancellation()
                let urls = try await makeURLs { fraction, message in
                    exportProgress = fraction
                    exportProgressMessage = message
                }
                exportedURLs = urls
                try Task.checkCancellation()
                guard !urls.isEmpty else { throw ImportExportError.exportFailed }
                exportProgress = 1
                exportProgressMessage = destination.progressMessage
                await Task.yield()
                try Task.checkCancellation()

                switch destination {
                case .share:
                    sharePayload = ExportSharePayload(
                        urls: urls,
                        cleanupWhenFinished: cleanupGeneratedFiles
                    )
                case .saveToFiles:
                    savePayload = ExportSavePayload(urls: urls)
                }
                errorMessage = nil
            } catch is CancellationError {
                if cleanupGeneratedFiles {
                    service.removeTemporaryExportFiles(exportedURLs)
                }
                errorMessage = nil
            } catch {
                if cleanupGeneratedFiles {
                    service.removeTemporaryExportFiles(exportedURLs)
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func finishPresentation(_ payload: ExportSharePayload) {
        if payload.cleanupWhenFinished {
            service.removeTemporaryExportFiles(payload.urls)
        }
        sharePayload = nil
    }

    private func finishPresentation(_ payload: ExportSavePayload) {
        service.removeTemporaryExportFiles(payload.urls)
        savePayload = nil
    }

    private func cancelExport() {
        exportProgressMessage = "Canceling export..."
        exportTask?.cancel()
    }

    private func originalLabel(for attachment: Attachment) -> String {
        let ext = attachment.fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ext.isEmpty else { return attachment.displayName }
        return "\(attachment.displayName).\(ext)"
    }

    private func icon(for format: ExportFormat) -> String {
        switch format {
        case .pdf:
            "doc.richtext"
        case .png:
            "photo"
        case .jpeg:
            "photo.fill"
        }
    }

    private func icon(for attachment: Attachment) -> String {
        switch attachment.kind {
        case .pdf:
            "doc.richtext"
        case .image:
            "photo"
        case .codeSnippet:
            "curlybraces.square"
        case .docx:
            "doc.text"
        case .csv:
            "tablecells"
        case .presentation:
            "rectangle.on.rectangle"
        case .other:
            "doc"
        }
    }
}

struct ExportSharePayload: Identifiable {
    let id = UUID()
    var urls: [URL]
    var cleanupWhenFinished = false
}

private struct ExportSavePayload: Identifiable {
    let id = UUID()
    var urls: [URL]
}

struct ActivityView: UIViewControllerRepresentable {
    var activityItems: [URL]
    var completion: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async {
                completion?()
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct ExportDocumentPicker: UIViewControllerRepresentable {
    var urls: [URL]
    var completion: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private var completion: (() -> Void)?

        init(completion: @escaping () -> Void) {
            self.completion = completion
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish()
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish()
        }

        private func finish() {
            guard let completion else { return }
            self.completion = nil
            completion()
        }
    }
}
