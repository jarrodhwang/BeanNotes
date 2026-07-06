//
//  NoteSearchIndexService.swift
//  BeanNotes
//

import Foundation
import SwiftData
import UIKit
import Vision

enum NoteSearchText {
    nonisolated static func join(_ pieces: [String]) -> String {
        pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    nonisolated static func normalized(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }

    nonisolated static func matches(_ rawQuery: String, in corpus: String) -> Bool {
        let tokens = normalized(rawQuery)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        guard !tokens.isEmpty else { return true }

        let normalizedCorpus = normalized(corpus)
        return tokens.allSatisfy { normalizedCorpus.contains($0) }
    }
}

struct NoteSearchIndexService {
    var storage = LocalStorageService()

    @MainActor
    func needsIndex(_ note: NoteDocument) -> Bool {
        note.searchIndexUpdatedAt == nil
            || note.sortedPages.contains { page in
                page.searchIndexUpdatedAt == nil || page.searchIndexUpdatedAt.map { $0 < page.updatedAt } == true
            }
    }

    @MainActor
    func indexIfNeeded(note: NoteDocument, modelContext: ModelContext) async throws {
        guard needsIndex(note) else { return }
        try await index(note: note, modelContext: modelContext)
    }

    @MainActor
    func index(note: NoteDocument, modelContext: ModelContext) async throws {
        let now = Date()

        for page in note.sortedPages {
            if page.searchIndexUpdatedAt == nil || page.searchIndexUpdatedAt.map({ $0 < page.updatedAt }) == true {
                let snapshot = NotePageRenderSnapshot(page: page)
                let recognizedText = try await Self.recognizePageText(
                    snapshot: snapshot,
                    rootURL: storage.rootURL
                )

                page.searchableText = NoteSearchText.join([
                    recognizedText,
                    Self.attachmentMetadata(for: page)
                ])
                page.searchIndexUpdatedAt = now
            }

            await Task.yield()
        }

        note.rebuildSearchableText()
        note.searchIndexUpdatedAt = now
        try modelContext.save()
    }

    @MainActor
    private static func attachmentMetadata(for page: NotePage) -> String {
        NoteSearchText.join(
            page.attachments.map {
                "\($0.displayName) \($0.originalFileName) \($0.kind.displayName)"
            }
        )
    }

    nonisolated private static func recognizePageText(
        snapshot: NotePageRenderSnapshot,
        rootURL: URL
    ) async throws -> String {
        let scale = recognitionScale(for: snapshot.pageSize)

        return try await Task.detached(priority: .utility) {
            let drawing = ThumbnailService.loadDrawing(fileName: snapshot.drawingFileName, rootURL: rootURL)
            let image = ThumbnailService.renderPageImage(
                snapshot: snapshot,
                drawing: drawing,
                rootURL: rootURL,
                scale: scale
            )

            guard let cgImage = image.cgImage else { return "" }
            return try recognizeText(in: cgImage)
        }.value
    }

    nonisolated private static func recognitionScale(for pageSize: CGSize) -> CGFloat {
        let longestSide = max(pageSize.width, pageSize.height)
        guard longestSide > 0 else { return 1 }
        return min(max(1500 / longestSide, 0.7), 1.6)
    }

    nonisolated private static func recognizeText(in cgImage: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = 0.01

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let lines = request.results?.compactMap { observation in
            observation.topCandidates(1).first?.string
        } ?? []

        return NoteSearchText.join(lines)
    }
}
