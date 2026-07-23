//
//  DrawingStorageService.swift
//  BeanNotes
//

import Foundation
import PencilKit
import UIKit

struct DrawingStorageService {
    enum LoadResult {
        case loaded(PKDrawing)
        case missing
        case unavailable(Error)

        var drawing: PKDrawing {
            switch self {
            case let .loaded(drawing):
                drawing
            case .missing, .unavailable:
                PKDrawing()
            }
        }

        var error: Error? {
            guard case let .unavailable(error) = self else { return nil }
            return error
        }
    }

    private struct DrawingLoadError: LocalizedError {
        var underlyingError: Error

        var errorDescription: String? {
            "This drawing could not be opened. Editing is paused to protect the existing note."
        }

        var failureReason: String? {
            underlyingError.localizedDescription
        }
    }

    private struct PrefetchState {
        var token: UUID
        var cacheVersion: UInt = 0
    }

    var storage = LocalStorageService()

    nonisolated(unsafe) private static let memoryWarningObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification,
        object: nil,
        queue: nil
    ) { _ in
        clearCache()
    }

    nonisolated(unsafe) private static let drawingCache: NSCache<NSString, CachedDrawing> = {
        let cache = NSCache<NSString, CachedDrawing>()
        cache.countLimit = 24
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    nonisolated private static let prefetchQueue = DispatchQueue(
        label: "com.snowfox.BeanNotes.drawing-prefetch",
        qos: .utility
    )
    nonisolated private static let prefetchLock = NSLock()
    nonisolated(unsafe) private static var prefetchStates: [String: PrefetchState] = [:]

    func drawingURL(for page: NotePage) throws -> URL {
        try storage.directoryURL(for: .drawings)
            .appendingPathComponent(page.drawingFileName)
    }

    func loadDrawing(for page: NotePage) -> PKDrawing {
        loadDrawingResult(for: page).drawing
    }

    func loadDrawingResult(for page: NotePage) -> LoadResult {
        Self.loadDrawingResult(
            fileName: page.drawingFileName,
            rootURL: storage.rootURL
        )
    }

    nonisolated static func loadDrawingResult(fileName: String, rootURL: URL) -> LoadResult {
        Self.ensureMemoryWarningObservation()
        let cacheKey = Self.cacheKey(rootURL: rootURL, fileName: fileName)
        if let cached = Self.drawingCache.object(forKey: cacheKey) {
            return .loaded(cached.drawing)
        }

        return Self.loadDrawingFromDisk(fileName: fileName, rootURL: rootURL)
    }

    nonisolated static func cachedDrawing(fileName: String, rootURL: URL) -> PKDrawing? {
        ensureMemoryWarningObservation()
        let cacheKey = Self.cacheKey(rootURL: rootURL, fileName: fileName)
        return drawingCache.object(forKey: cacheKey)?.drawing
    }

    func save(_ drawing: PKDrawing, for page: NotePage) throws {
        _ = try Self.writeDrawing(
            drawing,
            rootURL: storage.rootURL,
            drawingFileName: page.drawingFileName
        )
        page.touch()
    }

    nonisolated static func writeDrawing(
        _ drawing: PKDrawing,
        rootURL: URL,
        drawingFileName: String
    ) throws -> Data {
        let drawingsURL = rootURL.appendingPathComponent(
            StorageDirectory.drawings.rawValue,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: drawingsURL, withIntermediateDirectories: true)
        let data = drawing.dataRepresentation()
        // Atomic replacement lets readers observe either the old complete drawing
        // or the new one, without globally blocking canvas and thumbnail loads.
        try data.write(
            to: drawingsURL.appendingPathComponent(drawingFileName),
            options: [.atomic]
        )
        cache(
            drawing,
            fileName: drawingFileName,
            rootURL: rootURL,
            approximateBytes: data.count
        )
        return data
    }

    nonisolated static func cache(
        _ drawing: PKDrawing,
        fileName: String,
        rootURL: URL,
        approximateBytes: Int? = nil
    ) {
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

    nonisolated static func removeCachedDrawing(fileName: String, rootURL: URL) {
        let key = cacheKey(rootURL: rootURL, fileName: fileName)
        prefetchLock.lock()
        if var state = prefetchStates[key as String] {
            state.cacheVersion &+= 1
            prefetchStates[key as String] = state
        }
        drawingCache.removeObject(forKey: key)
        prefetchLock.unlock()
    }

    nonisolated static func clearCache() {
        prefetchLock.lock()
        prefetchStates.removeAll()
        drawingCache.removeAllObjects()
        prefetchLock.unlock()
    }

    nonisolated static func prefetchDrawing(fileName: String, rootURL: URL) {
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
                _ = loadDrawingResult(fileName: fileName, rootURL: rootURL)

                prefetchLock.lock()
                guard let currentState = prefetchStates[stringKey],
                      currentState.token == prefetchState.token else {
                    prefetchLock.unlock()
                    return
                }
                prefetchStates[stringKey] = nil
                prefetchLock.unlock()
            }
        }
    }

#if DEBUG
    nonisolated static func waitForPendingPrefetchesForTesting() {
        prefetchQueue.sync {}
    }
#endif

    nonisolated private static func cacheKey(rootURL: URL, fileName: String) -> NSString {
        "\(rootURL.standardizedFileURL.path)/\(StorageDirectory.drawings.rawValue)/\(fileName)" as NSString
    }

    nonisolated private static func loadDrawingFromDisk(fileName: String, rootURL: URL) -> LoadResult {
        do {
            // Reads do not need to create the drawings directory. This avoids a
            // filesystem mutation and directory check on every cold page load.
            let url = rootURL
                .appendingPathComponent(StorageDirectory.drawings.rawValue, isDirectory: true)
                .appendingPathComponent(fileName)
            let data = try Data(contentsOf: url)
            let drawing = try PKDrawing(data: data)
            cache(
                drawing,
                fileName: fileName,
                rootURL: rootURL,
                approximateBytes: data.count
            )
            return .loaded(drawing)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .unavailable(DrawingLoadError(underlyingError: error))
        }
    }

    nonisolated private static func ensureMemoryWarningObservation() {
        _ = memoryWarningObserver
    }
}

private final class CachedDrawing {
    let drawing: PKDrawing

    nonisolated init(_ drawing: PKDrawing) {
        self.drawing = drawing
    }
}
