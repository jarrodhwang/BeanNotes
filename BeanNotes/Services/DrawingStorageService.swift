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
    private static let prefetchQueue = DispatchQueue(
        label: "com.snowfox.BeanNotes.drawing-prefetch",
        qos: .userInitiated
    )
    private static let prefetchLock = NSLock()
    private static var prefetchedOrInFlightKeys: Set<String> = []
    private static var prefetchGeneration: UInt = 0

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
        prefetchLock.lock()
        prefetchGeneration &+= 1
        prefetchedOrInFlightKeys.removeAll()
        prefetchLock.unlock()
    }

    static func prefetchDrawing(fileName: String, rootURL: URL) {
        ensureMemoryWarningObservation()
        let key = cacheKey(rootURL: rootURL, fileName: fileName)
        guard drawingCache.object(forKey: key) == nil else { return }

        let stringKey = key as String
        prefetchLock.lock()
        let inserted = prefetchedOrInFlightKeys.insert(stringKey).inserted
        let generation = prefetchGeneration
        prefetchLock.unlock()
        guard inserted else { return }

        prefetchQueue.async {
            let url = rootURL
                .appendingPathComponent(StorageDirectory.drawings.rawValue, isDirectory: true)
                .appendingPathComponent(fileName)
            let drawing: PKDrawing
            let approximateBytes: Int

            if let data = try? Data(contentsOf: url),
               let storedDrawing = try? PKDrawing(data: data) {
                drawing = storedDrawing
                approximateBytes = data.count
            } else {
                drawing = PKDrawing()
                approximateBytes = 1
            }

            prefetchLock.lock()
            let shouldCache = generation == prefetchGeneration
            prefetchedOrInFlightKeys.remove(stringKey)
            prefetchLock.unlock()

            if shouldCache {
                cache(drawing, fileName: fileName, rootURL: rootURL, approximateBytes: approximateBytes)
            }
        }
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
