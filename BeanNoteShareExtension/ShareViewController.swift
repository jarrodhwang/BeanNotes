//
//  ShareViewController.swift
//  BeanNoteShareExtension
//

import UniformTypeIdentifiers
import UIKit

final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let fileManager = FileManager.default
    private let appGroupIdentifier = "group.com.snowfox.BeanNote"

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        saveSharedItems()
    }

    private func configureView() {
        view.backgroundColor = .systemBackground

        statusLabel.text = "Saving to BeanNote..."
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func saveSharedItems() {
        guard let inboxURL = sharedInboxURL() else {
            finish(message: "Open BeanNote to finish importing.")
            return
        }

        do {
            try fileManager.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        } catch {
            finish(message: "BeanNote could not save this item.")
            return
        }

        let providers = ((extensionContext?.inputItems as? [NSExtensionItem]) ?? [])
            .flatMap { $0.attachments ?? [] }

        guard !providers.isEmpty else {
            finish(message: "No supported item found.")
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var savedCount = 0

        for provider in providers {
            if let typeIdentifier = preferredTypeIdentifier(for: provider) {
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] sourceURL, _ in
                    defer { group.leave() }
                    guard let self, let sourceURL else { return }

                    if self.copySharedFile(from: sourceURL, to: inboxURL, typeIdentifier: typeIdentifier) {
                        lock.lock()
                        savedCount += 1
                        lock.unlock()
                    }
                }
            } else if provider.canLoadObject(ofClass: UIImage.self) {
                group.enter()
                provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                    defer { group.leave() }
                    guard
                        let self,
                        let image = object as? UIImage,
                        let data = image.pngData()
                    else {
                        return
                    }

                    let fileURL = inboxURL.appendingPathComponent(self.uniqueFileName("Shared Image.png"))

                    do {
                        try data.write(to: fileURL, options: [.atomic])
                        lock.lock()
                        savedCount += 1
                        lock.unlock()
                    } catch {
                        return
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.finish(message: savedCount == 0 ? "No supported item found." : "Saved to BeanNote.")
        }
    }

    private func preferredTypeIdentifier(for provider: NSItemProvider) -> String? {
        let supportedIdentifiers = [
            UTType.pdf.identifier,
            UTType.png.identifier,
            UTType.jpeg.identifier,
            UTType(filenameExtension: "docx")?.identifier,
            UTType(filenameExtension: "doc")?.identifier,
            UTType(filenameExtension: "csv")?.identifier,
            UTType(filenameExtension: "ppt")?.identifier,
            UTType(filenameExtension: "pptx")?.identifier,
            UTType.data.identifier
        ].compactMap { $0 }

        return supportedIdentifiers.first { provider.hasItemConformingToTypeIdentifier($0) }
    }

    private func copySharedFile(from sourceURL: URL, to inboxURL: URL, typeIdentifier: String) -> Bool {
        let pathExtension = sourceURL.pathExtension.isEmpty
            ? (UTType(typeIdentifier)?.preferredFilenameExtension ?? "data")
            : sourceURL.pathExtension
        let baseName = sourceURL.deletingPathExtension().lastPathComponent.isEmpty
            ? "Shared File"
            : sourceURL.deletingPathExtension().lastPathComponent
        let destinationURL = inboxURL.appendingPathComponent(uniqueFileName("\(baseName).\(pathExtension)"))

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return true
        } catch {
            return false
        }
    }

    private func sharedInboxURL() -> URL? {
        fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("SharedInbox", isDirectory: true)
    }

    private func uniqueFileName(_ preferredName: String) -> String {
        let sanitized = preferredName
            .components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:").union(.newlines))
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
