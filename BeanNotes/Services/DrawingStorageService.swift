//
//  DrawingStorageService.swift
//  BeanNotes
//

import Foundation
import PencilKit
import UIKit

struct DrawingStorageService {
    private struct PrefetchState {
        var token: UUID
        var cacheVersion: UInt = 0
    }

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
        qos: .utility
    )
    private static let prefetchLock = NSLock()
    private static var prefetchStates: [String: PrefetchState] = [:]

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
            // Reads do not need to create the drawings directory. This avoids a
            // filesystem mutation and directory check on every cold page load.
            let url = storage.rootURL
                .appendingPathComponent(StorageDirectory.drawings.rawValue, isDirectory: true)
                .appendingPathComponent(page.drawingFileName)
            guard storage.fileManager.fileExists(atPath: url.path) else {
                return PKDrawing()
            }

            let data = try Data(contentsOf: url)
            let drawing = try PKDrawing(data: data)
            Self.cache(
                drawing,
                fileName: page.drawingFileName,
                rootURL: storage.rootURL,
                approximateBytes: data.count
            )
            return drawing
        } catch {
            return PKDrawing()
        }
    }

    static func cachedDrawing(fileName: String, rootURL: URL) -> PKDrawing? {
        ensureMemoryWarningObservation()
        let cacheKey = Self.cacheKey(rootURL: rootURL, fileName: fileName)
        return drawingCache.object(forKey: cacheKey)?.drawing
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
        let key = cacheKey(rootURL: rootURL, fileName: fileName)
        let cost = max(approximateBytes ?? 1, 1)

        prefetchLock.lock()
        if var state = prefetchStates[key as String] {
            state.cacheVersion &+= 1
            prefetchStates[key as String] = state
        }
        drawingCache.setObject(
            CachedDrawing(drawing),
            forKey: key,
            cost: cost
        )
        prefetchLock.unlock()
    }

    static func removeCachedDrawing(fileName: String, rootURL: URL) {
        let key = cacheKey(rootURL: rootURL, fileName: fileName)
        prefetchLock.lock()
        if var state = prefetchStates[key as String] {
            state.cacheVersion &+= 1
            prefetchStates[key as String] = state
        }
        drawingCache.removeObject(forKey: key)
        prefetchLock.unlock()
    }

    static func clearCache() {
        prefetchLock.lock()
        prefetchStates.removeAll()
        drawingCache.removeAllObjects()
        prefetchLock.unlock()
    }

    static func prefetchDrawing(fileName: String, rootURL: URL) {
        ensureMemoryWarningObservation()
        let key = cacheKey(rootURL: rootURL, fileName: fileName)
        guard drawingCache.object(forKey: key) == nil else { return }

        let stringKey = key as String
        prefetchLock.lock()
        guard prefetchStates[stringKey] == nil else {
            prefetchLock.unlock()
            return
        }
        let prefetchState = PrefetchState(token: UUID())
        prefetchStates[stringKey] = prefetchState
        prefetchLock.unlock()

        prefetchQueue.async {
            autoreleasepool {
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
                guard let currentState = prefetchStates[stringKey],
                      currentState.token == prefetchState.token else {
                    prefetchLock.unlock()
                    return
                }
                let shouldCache = currentState.cacheVersion == prefetchState.cacheVersion
                    && drawingCache.object(forKey: key) == nil
                prefetchStates[stringKey] = nil
                if shouldCache {
                    drawingCache.setObject(
                        CachedDrawing(drawing),
                        forKey: key,
                        cost: max(approximateBytes, 1)
                    )
                }
                prefetchLock.unlock()
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
