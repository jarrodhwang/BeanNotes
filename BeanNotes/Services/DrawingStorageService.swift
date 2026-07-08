//
//  DrawingStorageService.swift
//  BeanNotes
//

import Foundation
import PencilKit
import UIKit

struct DrawingStorageService {
    var storage = LocalStorageService()

    private static let memoryWarningObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification,
        object: nil,
        queue: nil
    ) { _ in
        clearCache()
    }

    private static let drawingCache: NSCache<NSString, CachedDrawing> = {
        let cache = NSCache<NSString, CachedDrawing>()
        cache.countLimit = 24
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    func drawingURL(for page: NotePage) throws -> URL {
        try storage.directoryURL(for: .drawings)
            .appendingPathComponent(page.drawingFileName)
    }

    func loadDrawing(for page: NotePage) -> PKDrawing {
        Self.ensureMemoryWarningObservation()
        let cacheKey = Self.cacheKey(rootURL: storage.rootURL, fileName: page.drawingFileName)
        if let cached = Self.drawingCache.object(forKey: cacheKey) {
            return cached.drawing
        }

        do {
            let url = try drawingURL(for: page)
            guard storage.fileManager.fileExists(atPath: url.path) else {
                return PKDrawing()
            }

            let data = try Data(contentsOf: url)
            let drawing = try PKDrawing(data: data)
            Self.cache(drawing, fileName: page.drawingFileName, rootURL: storage.rootURL, approximateBytes: data.count)
            return drawing
        } catch {
            return PKDrawing()
        }
    }

    func save(_ drawing: PKDrawing, for page: NotePage) throws {
        let url = try drawingURL(for: page)
        let data = drawing.dataRepresentation()
        try data.write(to: url, options: [.atomic])
        Self.cache(drawing, fileName: page.drawingFileName, rootURL: storage.rootURL, approximateBytes: data.count)
        page.touch()
    }

    static func cache(_ drawing: PKDrawing, fileName: String, rootURL: URL, approximateBytes: Int? = nil) {
        ensureMemoryWarningObservation()
        let cost = max(approximateBytes ?? 1, 1)
        drawingCache.setObject(
            CachedDrawing(drawing),
            forKey: cacheKey(rootURL: rootURL, fileName: fileName),
            cost: cost
        )
    }

    static func removeCachedDrawing(fileName: String, rootURL: URL) {
        drawingCache.removeObject(forKey: cacheKey(rootURL: rootURL, fileName: fileName))
    }

    static func clearCache() {
        drawingCache.removeAllObjects()
    }

    private static func cacheKey(rootURL: URL, fileName: String) -> NSString {
        "\(rootURL.standardizedFileURL.path)/\(StorageDirectory.drawings.rawValue)/\(fileName)" as NSString
    }

    private static func ensureMemoryWarningObservation() {
        _ = memoryWarningObserver
    }
}

private final class CachedDrawing {
    let drawing: PKDrawing

    init(_ drawing: PKDrawing) {
        self.drawing = drawing
    }
}
