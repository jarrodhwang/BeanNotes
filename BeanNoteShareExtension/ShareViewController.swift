//
//  ShareViewController.swift
//  BeanNoteShareExtension
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

    private let fileManager = FileManager.default
    private let appGroupIdentifier = "group.com.snowfox.BeanNote"

    private let titleField = UITextField()
    private let folderButton = UIButton(type: .system)
    private let modeControl = UISegmentedControl(items: ["Note Pages", "Attachments"])
    private let itemSummaryLabel = UILabel()
    private let statusLabel = UILabel()
    private let importButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    private var providers: [NSItemProvider] = []
    private var folders: [FolderSummary] = []
    private var selectedFolder: FolderSummary?

    override func viewDidLoad() {
        super.viewDidLoad()
        providers = sharedItemProviders()
        folders = loadFolders()
        selectedFolder = folders.first

        configureView()
        updateFolderMenu()
        updateSharedItemSummary()
    }

    private func configureView() {
        view.backgroundColor = .systemBackground

        let titleLabel = makeLabel("Title")
        titleField.borderStyle = .roundedRect
        titleField.placeholder = "Shared Import"
        titleField.text = suggestedTitle()
        titleField.clearButtonMode = .whileEditing

        let folderLabel = makeLabel("Folder")
        folderButton.contentHorizontalAlignment = .leading
        folderButton.showsMenuAsPrimaryAction = true
        folderButton.changesSelectionAsPrimaryAction = false
        folderButton.configuration = .bordered()

        let modeLabel = makeLabel("Import As")
        modeControl.selectedSegmentIndex = ImportMode.notePages.rawValue

        itemSummaryLabel.font = .preferredFont(forTextStyle: .footnote)
        itemSummaryLabel.textColor = .secondaryLabel
        itemSummaryLabel.numberOfLines = 0

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        importButton.setTitle("Import", for: .normal)
        importButton.configuration = .filled()
        importButton.addTarget(self, action: #selector(importTapped), for: .touchUpInside)
        importButton.isEnabled = !providers.isEmpty

        let buttonStack = UIStackView(arrangedSubviews: [cancelButton, importButton])
        buttonStack.axis = .horizontal
        buttonStack.spacing = 12
        buttonStack.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [
            makeHeader(),
            titleLabel,
            titleField,
            folderLabel,
            folderButton,
            modeLabel,
            modeControl,
            itemSummaryLabel,
            statusLabel,
            buttonStack
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            titleField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            folderButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            modeControl.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            importButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    private func makeHeader() -> UILabel {
        let label = UILabel()
        label.text = "Share to BeanNote"
        label.font = .preferredFont(forTextStyle: .title2)
        label.adjustsFontForContentSizeCategory = true
        return label
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

    private func loadFolders() -> [FolderSummary] {
        guard
            let indexURL = sharedFolderIndexURL(),
            let data = try? Data(contentsOf: indexURL),
            let index = try? JSONDecoder().decode(FolderIndex.self, from: data),
            !index.folders.isEmpty
        else {
            return [FolderSummary(id: nil, name: "Inbox", colorHex: "#E5B94E")]
        }

        return index.folders
    }

    private func updateFolderMenu() {
        let actions = folders.map { folder in
            UIAction(
                title: folder.name,
                state: folder == selectedFolder ? .on : .off
            ) { [weak self] _ in
                self?.selectedFolder = folder
                self?.updateFolderMenu()
            }
        }

        folderButton.setTitle(selectedFolder?.name ?? "Inbox", for: .normal)
        folderButton.menu = UIMenu(children: actions)
    }

    @objc private func cancelTapped() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    @objc private func importTapped() {
        titleField.resignFirstResponder()
        importButton.isEnabled = false
        cancelButton.isEnabled = false
        statusLabel.text = "Saving..."

        saveSharedItems()
    }

    private func saveSharedItems() {
        guard let requestRootURL = sharedRequestsURL() else {
            finish(message: "Open BeanNote to finish setup.")
            return
        }

        let requestID = UUID()
        let requestURL = requestRootURL.appendingPathComponent(requestID.uuidString, isDirectory: true)

        do {
            try fileManager.createDirectory(at: requestURL, withIntermediateDirectories: true)
        } catch {
            finish(message: "BeanNote could not save this item.")
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var savedFiles: [String] = []

        for provider in providers {
            group.enter()
            save(provider, into: requestURL) { fileName in
                defer { group.leave() }
                guard let fileName else { return }
                lock.lock()
                savedFiles.append(fileName)
                lock.unlock()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }

            guard !savedFiles.isEmpty else {
                self.finish(message: "No supported item found.")
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
                self.finish(message: "Saved to BeanNote.")
            } catch {
                self.finish(message: "BeanNote could not save this item.")
            }
        }
    }

    private func selectedImportMode() -> ImportMode {
        ImportMode(rawValue: modeControl.selectedSegmentIndex) ?? .notePages
    }

    private func save(_ provider: NSItemProvider, into requestURL: URL, completion: @escaping (String?) -> Void) {
        if let typeIdentifier = preferredFileTypeIdentifier(for: provider) {
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] sourceURL, _ in
                guard let self, let sourceURL else {
                    completion(nil)
                    return
                }

                completion(self.copySharedFile(from: sourceURL, to: requestURL, typeIdentifier: typeIdentifier))
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                guard let self else {
                    completion(nil)
                    return
                }

                completion(self.saveFileURLItem(item, to: requestURL))
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, _ in
                guard let self else {
                    completion(nil)
                    return
                }

                completion(self.saveURLItem(item, to: requestURL))
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] item, _ in
                guard let self else {
                    completion(nil)
                    return
                }

                completion(self.saveTextItem(item, to: requestURL))
            }
        } else if provider.canLoadObject(ofClass: UIImage.self) {
            provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                guard
                    let self,
                    let image = object as? UIImage,
                    let data = image.pngData()
                else {
                    completion(nil)
                    return
                }

                completion(self.saveData(data, preferredName: "Shared Image.png", to: requestURL))
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { [weak self] sourceURL, _ in
                guard let self, let sourceURL else {
                    completion(nil)
                    return
                }

                completion(self.copySharedFile(from: sourceURL, to: requestURL, typeIdentifier: UTType.data.identifier))
            }
        } else {
            completion(nil)
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

    private func saveFileURLItem(_ item: NSSecureCoding?, to requestURL: URL) -> String? {
        if let url = item as? URL {
            return copySharedFile(from: url, to: requestURL, typeIdentifier: UTType.data.identifier)
        }

        if let url = item as? NSURL,
           let fileURL = url as URL? {
            return copySharedFile(from: fileURL, to: requestURL, typeIdentifier: UTType.data.identifier)
        }

        if let data = item as? Data,
           let url = URL(dataRepresentation: data, relativeTo: nil) {
            return copySharedFile(from: url, to: requestURL, typeIdentifier: UTType.data.identifier)
        }

        return nil
    }

    private func copySharedFile(from sourceURL: URL, to requestURL: URL, typeIdentifier: String) -> String? {
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
            return nil
        }
    }

    private func saveURLItem(_ item: NSSecureCoding?, to requestURL: URL) -> String? {
        if let url = item as? URL {
            return saveText(url.absoluteString, preferredName: "Shared Link.txt", to: requestURL)
        }

        if let url = item as? NSURL {
            return saveText(url.absoluteString ?? "", preferredName: "Shared Link.txt", to: requestURL)
        }

        if let string = item as? String {
            return saveText(string, preferredName: "Shared Link.txt", to: requestURL)
        }

        if let data = item as? Data,
           let string = String(data: data, encoding: .utf8) {
            return saveText(string, preferredName: "Shared Link.txt", to: requestURL)
        }

        return nil
    }

    private func saveTextItem(_ item: NSSecureCoding?, to requestURL: URL) -> String? {
        if let text = item as? String {
            return saveText(text, preferredName: "Shared Text.txt", to: requestURL)
        }

        if let attributedText = item as? NSAttributedString {
            return saveText(attributedText.string, preferredName: "Shared Text.txt", to: requestURL)
        }

        if let data = item as? Data,
           let text = String(data: data, encoding: .utf8) {
            return saveText(text, preferredName: "Shared Text.txt", to: requestURL)
        }

        return nil
    }

    private func saveText(_ text: String, preferredName: String, to requestURL: URL) -> String? {
        saveData(Data(text.utf8), preferredName: preferredName, to: requestURL)
    }

    private func saveData(_ data: Data, preferredName: String, to requestURL: URL) -> String? {
        let fileName = uniqueFileName(preferredName)
        let fileURL = requestURL.appendingPathComponent(fileName)

        do {
            try data.write(to: fileURL, options: [.atomic])
            return fileName
        } catch {
            return nil
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

    private func finish(message: String) {
        statusLabel.text = message

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
