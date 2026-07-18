//
//  ShareViewController.swift
//  BeanNotesShareExtension
//

import UniformTypeIdentifiers
import UIKit

final class ShareViewController: UIViewController {
    private struct FolderSummary: Codable, Equatable {
        var id: UUID?
        var name: String
        var colorHex: String
    }

    private struct FolderIndex: Codable {
        var folders: [FolderSummary]
    }

    private struct ImportRequest: Codable {
        var id: UUID
        var title: String
        var folderID: UUID?
        var importMode: String
        var files: [String]
    }

    private enum ImportMode: Int {
        case notePages
        case attachments

        var rawValueForRequest: String {
            switch self {
            case .notePages:
                "notePages"
            case .attachments:
                "attachments"
            }
        }
    }

    private struct SharedItemSaveFailure: Equatable {
        var itemName: String
        var reason: String

        var summary: String {
            "\(itemName): \(reason)"
        }
    }

    private enum SharedItemSaveResult {
        case success(String)
        case failure(SharedItemSaveFailure)
    }

    private enum SharedItemSaveError: LocalizedError {
        case unsupportedItem
        case unavailableItem
        case invalidFileURL
        case fileMissing(String)
        case invalidText
        case imageEncodingFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedItem:
                "Unsupported item type"
            case .unavailableItem:
                "The item could not be loaded"
            case .invalidFileURL:
                "The file URL could not be read"
            case .fileMissing(let fileName):
                "The file could not be found: \(fileName)"
            case .invalidText:
                "The text could not be read"
            case .imageEncodingFailed:
                "The image could not be encoded"
            }
        }
    }

    private let fileManager = FileManager.default
    private let appGroupIdentifier = "group.com.snowfox.BeanNotes"

    private let cardView = UIView()
    private let titleField = UITextField()
    private let folderButton = UIButton(type: .system)
    private let modeControl = UISegmentedControl(items: ["Note Pages", "Attachments"])
    private let previewImageView = UIImageView()
    private let previewTitleLabel = UILabel()
    private let previewSubtitleLabel = UILabel()
    private let previewTypeLabel = UILabel()
    private let itemSummaryLabel = UILabel()
    private let statusLabel = UILabel()
    private let openAppButton = UIButton(type: .system)
    private let importButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    private var providers: [NSItemProvider] = []
    private var folders: [FolderSummary] = []
    private var selectedFolder: FolderSummary?
    private var shouldOpenAppAfterSaving = true
    private var didCompleteRequest = false

    override func viewDidLoad() {
        super.viewDidLoad()
        providers = sharedItemProviders()
        folders = loadFolders()
        selectedFolder = folders.first

        preferredContentSize = CGSize(width: 560, height: 620)
        configureView()
        updateFolderMenu()
        updateSharedItemSummary()
        updatePreview()
    }

    private func configureView() {
        view.backgroundColor = .secondarySystemGroupedBackground

        let titleLabel = makeLabel("Title")
        titleField.borderStyle = .roundedRect
        titleField.placeholder = "Shared Import"
        titleField.text = suggestedTitle()
        titleField.clearButtonMode = .whileEditing

        let folderLabel = makeLabel("Folder")
        folderButton.contentHorizontalAlignment = .leading
        folderButton.showsMenuAsPrimaryAction = true
        folderButton.changesSelectionAsPrimaryAction = false

        let modeLabel = makeLabel("Import As")
        modeControl.selectedSegmentIndex = ImportMode.notePages.rawValue

        openAppButton.contentHorizontalAlignment = .leading
        openAppButton.addTarget(self, action: #selector(openAppButtonTapped), for: .touchUpInside)
        updateOpenAppButton()

        itemSummaryLabel.font = .preferredFont(forTextStyle: .footnote)
        itemSummaryLabel.textColor = .secondaryLabel
        itemSummaryLabel.numberOfLines = 0

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        importButton.configuration = .filled()
        importButton.configuration?.title = "Add"
        importButton.configuration?.image = UIImage(systemName: "plus.circle.fill")
        importButton.configuration?.imagePadding = 6
        importButton.addTarget(self, action: #selector(importTapped), for: .touchUpInside)
        importButton.isEnabled = !providers.isEmpty

        let buttonStack = UIStackView(arrangedSubviews: [cancelButton, importButton])
        buttonStack.axis = .horizontal
        buttonStack.spacing = 12
        buttonStack.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [
            makeHeader(),
            makePreviewCard(),
            titleLabel,
            titleField,
            folderLabel,
            folderButton,
            modeLabel,
            modeControl,
            openAppButton,
            itemSummaryLabel,
            statusLabel,
            buttonStack
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        cardView.backgroundColor = .systemBackground
        cardView.layer.cornerRadius = 24
        cardView.layer.cornerCurve = .continuous
        cardView.layer.shadowColor = UIColor.black.cgColor
        cardView.layer.shadowOpacity = 0.14
        cardView.layer.shadowRadius = 22
        cardView.layer.shadowOffset = CGSize(width: 0, height: 12)
        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(stack)
        view.addSubview(cardView)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            cardView.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            cardView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cardView.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            cardView.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            cardView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            cardView.widthAnchor.constraint(lessThanOrEqualToConstant: 560),

            stack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -20),
            titleField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            folderButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            modeControl.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            openAppButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            importButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    private func makeHeader() -> UIView {
        let iconContainer = UIView()
        iconContainer.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.13)
        iconContainer.layer.cornerRadius = 14
        iconContainer.layer.cornerCurve = .continuous
        iconContainer.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: "tray.and.arrow.down.fill"))
        icon.tintColor = .systemBlue
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(icon)

        let title = UILabel()
        title.text = "Add to BeanNotes"
        title.font = .preferredFont(forTextStyle: .title2)
        title.adjustsFontForContentSizeCategory = true

        let subtitle = UILabel()
        subtitle.text = "Pick a folder and import style."
        subtitle.font = .preferredFont(forTextStyle: .footnote)
        subtitle.textColor = .secondaryLabel
        subtitle.adjustsFontForContentSizeCategory = true

        let textStack = UIStackView(arrangedSubviews: [title, subtitle])
        textStack.axis = .vertical
        textStack.spacing = 2

        let stack = UIStackView(arrangedSubviews: [iconContainer, textStack])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 12

        NSLayoutConstraint.activate([
            iconContainer.widthAnchor.constraint(equalToConstant: 52),
            iconContainer.heightAnchor.constraint(equalTo: iconContainer.widthAnchor),
            icon.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor)
        ])

        return stack
    }

    private func makePreviewCard() -> UIView {
        let container = UIView()
        container.backgroundColor = .tertiarySystemGroupedBackground
        container.layer.cornerRadius = 18
        container.layer.cornerCurve = .continuous

        previewImageView.image = previewPlaceholderImage()
        previewImageView.tintColor = .secondaryLabel
        previewImageView.contentMode = .scaleAspectFit
        previewImageView.backgroundColor = .systemBackground
        previewImageView.layer.cornerRadius = 12
        previewImageView.layer.cornerCurve = .continuous
        previewImageView.clipsToBounds = true
        previewImageView.translatesAutoresizingMaskIntoConstraints = false

        previewTitleLabel.font = .preferredFont(forTextStyle: .headline)
        previewTitleLabel.adjustsFontForContentSizeCategory = true
        previewTitleLabel.numberOfLines = 2

        previewSubtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        previewSubtitleLabel.textColor = .secondaryLabel
        previewSubtitleLabel.adjustsFontForContentSizeCategory = true

        previewTypeLabel.font = .preferredFont(forTextStyle: .caption1)
        previewTypeLabel.textColor = .secondaryLabel
        previewTypeLabel.adjustsFontForContentSizeCategory = true
        previewTypeLabel.numberOfLines = 2

        let textStack = UIStackView(arrangedSubviews: [
            previewTitleLabel,
            previewSubtitleLabel,
            previewTypeLabel
        ])
        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.alignment = .leading

        let stack = UIStackView(arrangedSubviews: [previewImageView, textStack])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)

        NSLayoutConstraint.activate([
            previewImageView.widthAnchor.constraint(equalToConstant: 92),
            previewImageView.heightAnchor.constraint(equalToConstant: 116),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])

        return container
    }

    private func makeLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    private func sharedItemProviders() -> [NSItemProvider] {
        ((extensionContext?.inputItems as? [NSExtensionItem]) ?? [])
            .flatMap { $0.attachments ?? [] }
    }

    private func suggestedTitle() -> String {
        guard let provider = providers.first else { return "Shared Import" }
        let suggestedName = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let suggestedName, !suggestedName.isEmpty {
            return URL(fileURLWithPath: suggestedName).deletingPathExtension().lastPathComponent
        }

        return "Shared Import"
    }

    private func updateSharedItemSummary() {
        guard !providers.isEmpty else {
            itemSummaryLabel.text = "No supported item found."
            return
        }

        itemSummaryLabel.text = providers.count == 1
            ? "1 item ready to import."
            : "\(providers.count) items ready to import."
    }

    private func updatePreview() {
        previewTitleLabel.text = suggestedTitle()
        previewSubtitleLabel.text = providers.count == 1
            ? "1 item ready to import"
            : "\(providers.count) items ready to import"
        previewTypeLabel.text = sharedTypeSummary()
        previewImageView.image = previewPlaceholderImage()
        previewImageView.tintColor = .secondaryLabel
        previewImageView.contentMode = .scaleAspectFit

        guard let provider = providers.first else { return }

        provider.loadPreviewImage(options: nil) { [weak self] item, _ in
            guard let image = item as? UIImage else {
                self?.loadImagePreviewIfNeeded(from: provider)
                return
            }

            DispatchQueue.main.async {
                self?.setPreviewImage(image)
            }
        }
    }

    private func loadImagePreviewIfNeeded(from provider: NSItemProvider) {
        guard provider.canLoadObject(ofClass: UIImage.self) else { return }

        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage else { return }

            DispatchQueue.main.async {
                self?.setPreviewImage(image)
            }
        }
    }

    private func setPreviewImage(_ image: UIImage) {
        previewImageView.image = image
        previewImageView.tintColor = nil
        previewImageView.contentMode = .scaleAspectFill
    }

    private func sharedTypeSummary() -> String {
        guard !providers.isEmpty else { return "No supported item found" }

        let kinds = providers.map(displayKind(for:))
        let uniqueKinds = Array(Set(kinds)).sorted()

        if providers.count == 1 {
            return uniqueKinds.first ?? "File"
        }

        return "\(providers.count) items - \(uniqueKinds.prefix(3).joined(separator: ", "))"
    }

    private func displayKind(for provider: NSItemProvider) -> String {
        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            return "PDF"
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return "Image"
        } else if provider.hasItemConformingToTypeIdentifier(UTType(filenameExtension: "docx")?.identifier ?? "") ||
                    provider.hasItemConformingToTypeIdentifier(UTType(filenameExtension: "doc")?.identifier ?? "") {
            return "Word document"
        } else if provider.hasItemConformingToTypeIdentifier(UTType(filenameExtension: "pptx")?.identifier ?? "") ||
                    provider.hasItemConformingToTypeIdentifier(UTType(filenameExtension: "ppt")?.identifier ?? "") {
            return "Presentation"
        } else if provider.hasItemConformingToTypeIdentifier(UTType(filenameExtension: "csv")?.identifier ?? "") {
            return "CSV"
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) ||
                    provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            return "Link or text"
        } else {
            return "File"
        }
    }

    private func loadFolders() -> [FolderSummary] {
        guard
            let indexURL = sharedFolderIndexURL(),
            let data = try? Data(contentsOf: indexURL),
            let index = try? JSONDecoder().decode(FolderIndex.self, from: data),
            !index.folders.isEmpty
        else {
            return [FolderSummary(id: nil, name: "Inbox", colorHex: "#F59E0B")]
        }

        return index.folders
    }

    private func updateFolderMenu() {
        let actions = folders.map { folder in
            UIAction(
                title: folder.name,
                image: folderSwatchImage(colorHex: folder.colorHex),
                state: folder == selectedFolder ? .on : .off
            ) { [weak self] _ in
                self?.selectedFolder = folder
                self?.updateFolderMenu()
            }
        }

        var configuration = UIButton.Configuration.bordered()
        configuration.title = selectedFolder?.name ?? "Inbox"
        configuration.image = folderSwatchImage(colorHex: selectedFolder?.colorHex ?? "#F59E0B")
        configuration.imagePadding = 8
        configuration.titleAlignment = .leading
        configuration.baseForegroundColor = .label

        folderButton.configuration = configuration
        folderButton.menu = UIMenu(title: "Choose Folder", children: actions)
    }

    @objc private func cancelTapped() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    @objc private func openAppButtonTapped() {
        shouldOpenAppAfterSaving.toggle()
        updateOpenAppButton()
    }

    private func updateOpenAppButton() {
        var configuration = UIButton.Configuration.plain()
        configuration.title = "Open BeanNotes right away"
        configuration.image = UIImage(systemName: shouldOpenAppAfterSaving ? "checkmark.square.fill" : "square")
        configuration.imagePadding = 10
        configuration.baseForegroundColor = .label
        configuration.contentInsets = .zero
        openAppButton.configuration = configuration
        openAppButton.accessibilityLabel = "Open BeanNotes right away"
        openAppButton.accessibilityValue = shouldOpenAppAfterSaving ? "Checked" : "Unchecked"
        openAppButton.accessibilityTraits = shouldOpenAppAfterSaving ? [.button, .selected] : .button
    }

    @objc private func importTapped() {
        titleField.resignFirstResponder()
        importButton.isEnabled = false
        cancelButton.isEnabled = false
        statusLabel.text = "Saving..."
        statusLabel.textColor = .secondaryLabel

        saveSharedItems()
    }

    private func saveSharedItems() {
        guard let requestRootURL = sharedRequestsURL() else {
            finish(message: "Open BeanNotes to finish setup.")
            return
        }

        let requestID = UUID()
        let requestURL = requestRootURL.appendingPathComponent(requestID.uuidString, isDirectory: true)

        do {
            try fileManager.createDirectory(at: requestURL, withIntermediateDirectories: true)
        } catch {
            finish(message: "BeanNotes could not save this item.")
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var savedFiles: [String] = []
        var failures: [SharedItemSaveFailure] = []

        for provider in providers {
            group.enter()
            save(provider, into: requestURL) { result in
                defer { group.leave() }

                lock.lock()
                switch result {
                case .success(let fileName):
                    savedFiles.append(fileName)
                case .failure(let failure):
                    failures.append(failure)
                }
                lock.unlock()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }

            guard !savedFiles.isEmpty else {
                try? self.fileManager.removeItem(at: requestURL)
                self.showRecoverableFailure(message: self.failureSummary(
                    savedCount: 0,
                    totalCount: self.providers.count,
                    failures: failures
                ))
                return
            }

            do {
                let title = self.titleField.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                let request = ImportRequest(
                    id: requestID,
                    title: title?.isEmpty == false ? title ?? "Shared Import" : "Shared Import",
                    folderID: self.selectedFolder?.id,
                    importMode: self.selectedImportMode().rawValueForRequest,
                    files: savedFiles.sorted()
                )
                let data = try JSONEncoder().encode(request)
                try data.write(to: requestURL.appendingPathComponent("request.json"), options: [.atomic])
                self.finish(message: self.failureSummary(
                    savedCount: savedFiles.count,
                    totalCount: self.providers.count,
                    failures: failures
                ), openAppAfterSaving: true)
            } catch {
                self.finish(message: "BeanNotes could not save this item.")
            }
        }
    }

    private func selectedImportMode() -> ImportMode {
        ImportMode(rawValue: modeControl.selectedSegmentIndex) ?? .notePages
    }

    private func saveResult(for provider: NSItemProvider, work: () throws -> String) -> SharedItemSaveResult {
        do {
            return .success(try work())
        } catch {
            return .failure(failure(for: provider, error: error))
        }
    }

    private func failure(for provider: NSItemProvider, error: Error) -> SharedItemSaveFailure {
        SharedItemSaveFailure(
            itemName: displayName(for: provider),
            reason: readableFailureReason(for: error)
        )
    }

    private func displayName(for provider: NSItemProvider) -> String {
        if let suggestedName = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suggestedName.isEmpty {
            return suggestedName
        }

        return displayKind(for: provider)
    }

    private func readableFailureReason(for error: Error) -> String {
        let description = (error as NSError).localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !description.isEmpty else {
            return "Unknown error"
        }

        return description
    }

    private func failureSummary(
        savedCount: Int,
        totalCount: Int,
        failures: [SharedItemSaveFailure]
    ) -> String {
        guard !failures.isEmpty else {
            return savedCount == 1 ? "Saved 1 item to BeanNotes." : "Saved to BeanNotes."
        }

        let failureDetails = failures
            .prefix(3)
            .map(\.summary)
            .joined(separator: "\n")
        let remainingCount = max(failures.count - 3, 0)
        let remainingText = remainingCount > 0 ? "\n+\(remainingCount) more item(s)." : ""

        if savedCount == 0 {
            return "No items were saved. \(failures.count) of \(totalCount) item(s) failed:\n\(failureDetails)\(remainingText)"
        }

        return "Saved \(savedCount) of \(totalCount) item(s) to BeanNotes. \(failures.count) item(s) failed:\n\(failureDetails)\(remainingText)"
    }

    private func save(_ provider: NSItemProvider, into requestURL: URL, completion: @escaping (SharedItemSaveResult) -> Void) {
        if let typeIdentifier = preferredFileTypeIdentifier(for: provider) {
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] sourceURL, error in
                guard let self else {
                    completion(.failure(SharedItemSaveFailure(itemName: "Shared item", reason: "Share extension closed")))
                    return
                }

                guard let sourceURL else {
                    completion(.failure(self.failure(for: provider, error: error ?? SharedItemSaveError.unavailableItem)))
                    return
                }

                completion(self.saveResult(for: provider) {
                    try self.copySharedFile(from: sourceURL, to: requestURL, typeIdentifier: typeIdentifier)
                })
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, error in
                guard let self else {
                    completion(.failure(SharedItemSaveFailure(itemName: "Shared item", reason: "Share extension closed")))
                    return
                }

                if let error {
                    completion(.failure(self.failure(for: provider, error: error)))
                    return
                }

                completion(self.saveResult(for: provider) {
                    try self.saveFileURLItem(item, to: requestURL)
                })
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, error in
                guard let self else {
                    completion(.failure(SharedItemSaveFailure(itemName: "Shared item", reason: "Share extension closed")))
                    return
                }

                if let error {
                    completion(.failure(self.failure(for: provider, error: error)))
                    return
                }

                completion(self.saveResult(for: provider) {
                    try self.saveURLItem(item, to: requestURL)
                })
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] item, error in
                guard let self else {
                    completion(.failure(SharedItemSaveFailure(itemName: "Shared item", reason: "Share extension closed")))
                    return
                }

                if let error {
                    completion(.failure(self.failure(for: provider, error: error)))
                    return
                }

                completion(self.saveResult(for: provider) {
                    try self.saveTextItem(item, to: requestURL)
                })
            }
        } else if provider.canLoadObject(ofClass: UIImage.self) {
            provider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
                guard let self else {
                    completion(.failure(SharedItemSaveFailure(itemName: "Shared item", reason: "Share extension closed")))
                    return
                }

                if let error {
                    completion(.failure(self.failure(for: provider, error: error)))
                    return
                }

                guard let image = object as? UIImage else {
                    completion(.failure(self.failure(for: provider, error: SharedItemSaveError.unavailableItem)))
                    return
                }

                guard let data = image.pngData() else {
                    completion(.failure(self.failure(for: provider, error: SharedItemSaveError.imageEncodingFailed)))
                    return
                }

                completion(self.saveResult(for: provider) {
                    try self.saveData(data, preferredName: "Shared Image.png", to: requestURL)
                })
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { [weak self] sourceURL, error in
                guard let self else {
                    completion(.failure(SharedItemSaveFailure(itemName: "Shared item", reason: "Share extension closed")))
                    return
                }

                guard let sourceURL else {
                    completion(.failure(self.failure(for: provider, error: error ?? SharedItemSaveError.unavailableItem)))
                    return
                }

                completion(self.saveResult(for: provider) {
                    try self.copySharedFile(from: sourceURL, to: requestURL, typeIdentifier: UTType.data.identifier)
                })
            }
        } else {
            completion(.failure(failure(for: provider, error: SharedItemSaveError.unsupportedItem)))
        }
    }

    private func preferredFileTypeIdentifier(for provider: NSItemProvider) -> String? {
        let supportedIdentifiers = [
            UTType.pdf.identifier,
            UTType(filenameExtension: "docx")?.identifier,
            UTType(filenameExtension: "doc")?.identifier,
            UTType(filenameExtension: "pptx")?.identifier,
            UTType(filenameExtension: "ppt")?.identifier,
            UTType(filenameExtension: "csv")?.identifier,
            UTType.png.identifier,
            UTType.jpeg.identifier,
            UTType.image.identifier
        ].compactMap { $0 }

        return supportedIdentifiers.first { provider.hasItemConformingToTypeIdentifier($0) }
    }

    private func saveFileURLItem(_ item: NSSecureCoding?, to requestURL: URL) throws -> String {
        if let url = item as? URL {
            return try copySharedFile(from: url, to: requestURL, typeIdentifier: UTType.data.identifier)
        }

        if let url = item as? NSURL,
           let fileURL = url as URL? {
            return try copySharedFile(from: fileURL, to: requestURL, typeIdentifier: UTType.data.identifier)
        }

        if let data = item as? Data,
           let url = URL(dataRepresentation: data, relativeTo: nil) {
            return try copySharedFile(from: url, to: requestURL, typeIdentifier: UTType.data.identifier)
        }

        throw SharedItemSaveError.invalidFileURL
    }

    private func copySharedFile(from sourceURL: URL, to requestURL: URL, typeIdentifier: String) throws -> String {
        guard sourceURL.isFileURL else {
            throw SharedItemSaveError.invalidFileURL
        }

        let isScoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw SharedItemSaveError.fileMissing(sourceURL.lastPathComponent)
        }

        let pathExtension = sourceURL.pathExtension.isEmpty
            ? (UTType(typeIdentifier)?.preferredFilenameExtension ?? "data")
            : sourceURL.pathExtension
        let baseName = sourceURL.deletingPathExtension().lastPathComponent.isEmpty
            ? "Shared File"
            : sourceURL.deletingPathExtension().lastPathComponent
        let destinationName = uniqueFileName("\(baseName).\(pathExtension)")
        let destinationURL = requestURL.appendingPathComponent(destinationName)

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return destinationName
        } catch {
            throw error
        }
    }

    private func saveURLItem(_ item: NSSecureCoding?, to requestURL: URL) throws -> String {
        if let url = item as? URL {
            return try saveText(url.absoluteString, preferredName: "Shared Link.txt", to: requestURL)
        }

        if let url = item as? NSURL {
            guard let string = url.absoluteString, !string.isEmpty else {
                throw SharedItemSaveError.invalidText
            }
            return try saveText(string, preferredName: "Shared Link.txt", to: requestURL)
        }

        if let string = item as? String {
            return try saveText(string, preferredName: "Shared Link.txt", to: requestURL)
        }

        if let data = item as? Data,
           let string = String(data: data, encoding: .utf8) {
            return try saveText(string, preferredName: "Shared Link.txt", to: requestURL)
        }

        throw SharedItemSaveError.invalidText
    }

    private func saveTextItem(_ item: NSSecureCoding?, to requestURL: URL) throws -> String {
        if let text = item as? String {
            return try saveText(text, preferredName: "Shared Text.txt", to: requestURL)
        }

        if let attributedText = item as? NSAttributedString {
            return try saveText(attributedText.string, preferredName: "Shared Text.txt", to: requestURL)
        }

        if let data = item as? Data,
           let text = String(data: data, encoding: .utf8) {
            return try saveText(text, preferredName: "Shared Text.txt", to: requestURL)
        }

        throw SharedItemSaveError.invalidText
    }

    private func saveText(_ text: String, preferredName: String, to requestURL: URL) throws -> String {
        try saveData(Data(text.utf8), preferredName: preferredName, to: requestURL)
    }

    private func saveData(_ data: Data, preferredName: String, to requestURL: URL) throws -> String {
        let fileName = uniqueFileName(preferredName)
        let fileURL = requestURL.appendingPathComponent(fileName)

        do {
            try data.write(to: fileURL, options: [.atomic])
            return fileName
        } catch {
            throw error
        }
    }

    private func sharedRequestsURL() -> URL? {
        fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("SharedInbox", isDirectory: true)
            .appendingPathComponent("Requests", isDirectory: true)
    }

    private func sharedFolderIndexURL() -> URL? {
        fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("FolderIndex", isDirectory: true)
            .appendingPathComponent("folders.json")
    }

    private func uniqueFileName(_ preferredName: String) -> String {
        let sanitized = preferredName
            .components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:").union(.newlines).union(.controlCharacters))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let url = URL(fileURLWithPath: sanitized.isEmpty ? "Shared File" : sanitized)
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let suffix = UUID().uuidString

        return ext.isEmpty ? "\(baseName)-\(suffix)" : "\(baseName)-\(suffix).\(ext)"
    }

    private func finish(message: String, openAppAfterSaving: Bool = false) {
        statusLabel.text = message
        statusLabel.textColor = message.localizedCaseInsensitiveContains("failed") ? .systemOrange : .secondaryLabel

        let delay: TimeInterval = message.count > 80 ? 2.4 : 0.65
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let extensionContext else { return }

            guard openAppAfterSaving,
                  shouldOpenAppAfterSaving,
                  let appURL = URL(string: "beannotes://shared-import") else {
                completeRequestIfNeeded()
                return
            }

            extensionContext.open(appURL) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.completeRequestIfNeeded()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.completeRequestIfNeeded()
            }
        }
    }

    private func completeRequestIfNeeded() {
        guard !didCompleteRequest else { return }
        didCompleteRequest = true
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func showRecoverableFailure(message: String) {
        statusLabel.text = message
        statusLabel.textColor = .systemRed
        importButton.isEnabled = !providers.isEmpty
        cancelButton.isEnabled = true
    }

    private func previewPlaceholderImage() -> UIImage? {
        let symbolName: String

        if let provider = providers.first {
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                symbolName = "doc.richtext.fill"
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                symbolName = "photo.fill"
            } else if provider.hasItemConformingToTypeIdentifier(UTType(filenameExtension: "csv")?.identifier ?? "") {
                symbolName = "tablecells.fill"
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                symbolName = "link"
            } else {
                symbolName = "doc.fill"
            }
        } else {
            symbolName = "doc.fill"
        }

        let configuration = UIImage.SymbolConfiguration(pointSize: 34, weight: .semibold)
        return UIImage(systemName: symbolName, withConfiguration: configuration)
    }

    private func folderSwatchImage(colorHex: String) -> UIImage {
        let size = CGSize(width: 24, height: 24)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 6)
            UIColor.beanNotesColor(hex: colorHex).setFill()
            path.fill()

            UIColor.separator.withAlphaComponent(0.32).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        .withRenderingMode(.alwaysOriginal)
    }
}

private extension UIColor {
    static func beanNotesColor(hex: String) -> UIColor {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines))
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else {
            return .systemBlue
        }

        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255

        return UIColor(red: red, green: green, blue: blue, alpha: 1)
    }
}
