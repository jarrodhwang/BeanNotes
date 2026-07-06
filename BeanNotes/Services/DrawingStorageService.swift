//
//  DrawingStorageService.swift
//  BeanNotes
//

import Foundation
import PencilKit

struct DrawingStorageService {
    var storage = LocalStorageService()

    private static let drawingCache: NSCache<NSString, CachedDrawing> = {
        let cache = NSCache<NSString, CachedDrawing>()
        cache.countLimit = 48
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    func drawingURL(for page: NotePage) throws -> URL {
        try storage.directoryURL(for: .drawings)
            .appendingPathComponent(page.drawingFileName)
    }

    func loadDrawing(for page: NotePage) -> PKDrawing {
        let cacheKey = page.drawingFileName as NSString
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
            Self.cache(drawing, fileName: page.drawingFileName, approximateBytes: data.count)
            return drawing
        } catch {
            return PKDrawing()
        }
    }

    func save(_ drawing: PKDrawing, for page: NotePage) throws {
        let url = try drawingURL(for: page)
        let data = drawing.dataRepresentation()
        try data.write(to: url, options: [.atomic])
        Self.cache(drawing, fileName: page.drawingFileName, approximateBytes: data.count)
        page.touch()
    }

    static func cache(_ drawing: PKDrawing, fileName: String, approximateBytes: Int? = nil) {
        let cost = max(approximateBytes ?? 1, 1)
        drawingCache.setObject(CachedDrawing(drawing), forKey: fileName as NSString, cost: cost)
    }

    static func removeCachedDrawing(fileName: String) {
        drawingCache.removeObject(forKey: fileName as NSString)
    }

    static func clearCache() {
        drawingCache.removeAllObjects()
    }
}

private final class CachedDrawing {
    let drawing: PKDrawing

    init(_ drawing: PKDrawing) {
        self.drawing = drawing
    }
}
