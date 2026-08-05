//
//  DrawingStorageService.swift
//  BeanNotes
//

import Foundation
import PencilKit
import UIKit

struct DrawingStorageService {
    enum LoadResult {
        case loaded(PKDrawing, archiveData: Data?)
        case missing
        case unavailable(Error)

        nonisolated var drawing: PKDrawing {
            switch self {
            case let .loaded(drawing, _):
                drawing
            case .missing, .unavailable:
                PKDrawing()
            }
        }

        nonisolated var error: Error? {
            guard case let .unavailable(error) = self else { return nil }
            return error
        }

        nonisolated var archiveData: Data? {
            guard case let .loaded(_, archiveData) = self else { return nil }
            return archiveData
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

    private struct CacheVersionSnapshot {
        var epoch: UInt
        var keyVersion: UInt
    }

    private struct PrefetchRequest {
        var fileName: String
        var rootURL: URL
        var cacheKey: String
        var interestedScopeKeys: Set<String>
        var priorityScopeKey: String
        var state: PrefetchState
    }

    private enum DiskLoadOutcome {
        case resolved(LoadResult)
        case superseded
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
    nonisolated private static let maximumPendingPrefetchCount = 24
    nonisolated(unsafe) private static var pendingPrefetchRequests: [String: PrefetchRequest] = [:]
    nonisolated(unsafe) private static var pendingPrefetchOrder: [String] = []
    nonisolated(unsafe) private static var pendingPrefetchScopeOrder: [String] = []
    nonisolated(unsafe) private static var isPrefetchWorkerScheduled = false
    nonisolated(unsafe) private static var activePrefetchKey: String?
    nonisolated(unsafe) private static var activePrefetchScopeKey: String?
    nonisolated(unsafe) private static var activePrefetchInterestedScopeKeys: Set<String> = []
    nonisolated private static let maximumTrackedCacheVersionCount = 1_024
    nonisolated(unsafe) private static var cacheVersionEpoch: UInt = 0
    nonisolated(unsafe) private static var cacheVersions: [String: UInt] = [:]
    nonisolated private static let maximumMissingDrawingCount = 512
    /// Imported and newly-created pages usually have no drawing file yet. Remembering
    /// that absence prevents viewport prefetching from repeatedly issuing the same
    /// failed disk read until a drawing is written or the cache state is invalidated.
    /// Access is serialized with `prefetchStates` so a concurrent successful cache
    /// write always supersedes a previously observed missing file.
    nonisolated(unsafe) private static var missingDrawingKeys: Set<String> = []
    nonisolated(unsafe) private static var missingDrawingKeyOrder: [String] = []
#if DEBUG
    nonisolated(unsafe) private static var diskLoadPublicationHookForTesting: (@Sendable (String) -> Void)?
#endif

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
        let stringKey = cacheKey as String
        let maximumSupersessionRetries = 2

        for _ in 0...maximumSupersessionRetries {
            prefetchLock.lock()
            let cached = drawingCache.object(forKey: cacheKey)
            let isKnownMissing = missingDrawingKeys.contains(stringKey)
            let cacheVersionSnapshot = currentCacheVersionLocked(for: stringKey)
            prefetchLock.unlock()

            if let cached {
                return .loaded(cached.drawing, archiveData: cached.archiveData)
            }
            if isKnownMissing {
                return .missing
            }

            switch Self.loadDrawingFromDisk(
                fileName: fileName,
                rootURL: rootURL,
                cacheKey: cacheKey,
                expectedCacheVersion: cacheVersionSnapshot
            ) {
            case .resolved(let result):
                return result
            case .superseded:
                continue
            }
        }

        prefetchLock.lock()
        let finalCachedDrawing = drawingCache.object(forKey: cacheKey)
        let isFinallyKnownMissing = missingDrawingKeys.contains(stringKey)
        let fallbackVersion = currentCacheVersionLocked(for: stringKey)
        prefetchLock.unlock()
        if let finalCachedDrawing {
            return .loaded(
                finalCachedDrawing.drawing,
                archiveData: finalCachedDrawing.archiveData
            )
        }
        if isFinallyKnownMissing {
            return .missing
        }

        // Sustained invalidation should not grow the stack or repeatedly decode
        // forever. Decode outside the lock, then linearize the result against the
        // cache/version state once more so a writer that completed during this final
        // read still wins. At most one additional uncached decode is needed when a
        // cache reset/removal changed the version without publishing a drawing.
        let fallbackResult = loadDrawingFromDiskWithoutCaching(fileName: fileName, rootURL: rootURL)
        return resolveUncachedFallback(
            fallbackResult,
            fileName: fileName,
            rootURL: rootURL,
            cacheKey: cacheKey,
            expectedCacheVersion: fallbackVersion
        )
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
            approximateBytes: data.count,
            archiveData: data
        )
        return data
    }

    nonisolated static func cache(
        _ drawing: PKDrawing,
        fileName: String,
        rootURL: URL,
        approximateBytes: Int? = nil,
        archiveData: Data? = nil
    ) {
        ensureMemoryWarningObservation()
        let key = cacheKey(rootURL: rootURL, fileName: fileName)
        // The cache retains both PencilKit's decoded model and, for disk-backed
        // entries, the exact archive used as the save baseline. Account for both so
        // avoiding a registration-time serialization does not silently double memory.
        let cost = max(approximateBytes ?? 1, 1) + (archiveData?.count ?? 0)

        prefetchLock.lock()
        advanceCacheVersionLocked(for: key as String)
        if var state = prefetchStates[key as String] {
            state.cacheVersion &+= 1
            prefetchStates[key as String] = state
        }
        removeMissingDrawingKeyLocked(key as String)
        drawingCache.setObject(
            CachedDrawing(drawing, archiveData: archiveData),
            forKey: key,
            cost: cost
        )
        prefetchLock.unlock()
    }

    nonisolated static func removeCachedDrawing(fileName: String, rootURL: URL) {
        let key = cacheKey(rootURL: rootURL, fileName: fileName)
        prefetchLock.lock()
        advanceCacheVersionLocked(for: key as String)
        if var state = prefetchStates[key as String] {
            state.cacheVersion &+= 1
            prefetchStates[key as String] = state
        }
        removeMissingDrawingKeyLocked(key as String)
        drawingCache.removeObject(forKey: key)
        prefetchLock.unlock()
    }

    nonisolated static func clearCache() {
        prefetchLock.lock()
        cacheVersionEpoch &+= 1
        cacheVersions.removeAll(keepingCapacity: true)
        prefetchStates.removeAll()
        pendingPrefetchRequests.removeAll()
        pendingPrefetchOrder.removeAll()
        pendingPrefetchScopeOrder.removeAll()
        missingDrawingKeys.removeAll()
        missingDrawingKeyOrder.removeAll()
        drawingCache.removeAllObjects()
        prefetchLock.unlock()
    }

    nonisolated static func prefetchDrawing(fileName: String, rootURL: URL) {
        prefetchDrawings(fileNames: [fileName], rootURL: rootURL)
    }

    /// Coalesces viewport prefetches into one bounded serial worker. Callers should
    /// provide file names in priority order (visible pages first) and a stable scope
    /// per canvas. Pending work is interleaved fairly across scopes so multiple editor
    /// scenes cannot repeatedly evict one another's visible-page requests.
    nonisolated static func prefetchDrawings(
        fileNames: [String],
        rootURL: URL,
        scopeID: UUID? = nil
    ) {
        ensureMemoryWarningObservation()
        let scopeKey = prefetchScopeKey(scopeID)

        var uniqueFileNames: [String] = []
        var seenFileNames = Set<String>()
        for fileName in fileNames where seenFileNames.insert(fileName).inserted {
            uniqueFileNames.append(fileName)
        }

        prefetchLock.lock()
        var prioritizedKeys: [String] = []
        for fileName in uniqueFileNames {
            let cacheKey = cacheKey(rootURL: rootURL, fileName: fileName)
            let stringKey = cacheKey as String
            guard drawingCache.object(forKey: cacheKey) == nil,
                  !missingDrawingKeys.contains(stringKey) else {
                continue
            }

            if activePrefetchKey == stringKey,
               prefetchStates[stringKey] != nil {
                activePrefetchInterestedScopeKeys.insert(scopeKey)
                continue
            } else if var request = pendingPrefetchRequests[stringKey] {
                request.interestedScopeKeys.insert(scopeKey)
                request.priorityScopeKey = scopeKey
                pendingPrefetchRequests[stringKey] = request
            } else if prefetchStates[stringKey] == nil {
                let state = PrefetchState(token: UUID())
                prefetchStates[stringKey] = state
                pendingPrefetchRequests[stringKey] = PrefetchRequest(
                    fileName: fileName,
                    rootURL: rootURL,
                    cacheKey: stringKey,
                    interestedScopeKeys: [scopeKey],
                    priorityScopeKey: scopeKey,
                    state: state
                )
            }
            if pendingPrefetchRequests[stringKey] != nil {
                prioritizedKeys.append(stringKey)
                if prioritizedKeys.count == maximumPendingPrefetchCount {
                    break
                }
            }
        }
        if scopeID != nil {
            removePrefetchScopeInterestLocked(
                scopeKey,
                retainingKeys: Set(prioritizedKeys)
            )
        }

        rebalancePendingPrefetchesLocked(
            preferredScopeKey: scopeKey,
            preferredKeys: prioritizedKeys
        )

        let shouldScheduleWorker = !isPrefetchWorkerScheduled && !pendingPrefetchOrder.isEmpty
        if shouldScheduleWorker {
            isPrefetchWorkerScheduled = true
        }
        prefetchLock.unlock()

        guard shouldScheduleWorker else { return }
        prefetchQueue.async {
            drainPrefetchRequests()
        }
    }

    nonisolated static func cancelPrefetches(scopeID: UUID) {
        let scopeKey = prefetchScopeKey(scopeID)
        prefetchLock.lock()
        removePrefetchScopeInterestLocked(scopeKey, retainingKeys: [])
        if let activePrefetchKey,
           activePrefetchInterestedScopeKeys.remove(scopeKey) != nil,
           activePrefetchInterestedScopeKeys.isEmpty {
            // The filesystem read itself is not interruptible, but invalidating its
            // token lets the worker stop before PencilKit performs a potentially
            // expensive archive decode or publishes speculative data to the cache.
            prefetchStates[activePrefetchKey] = nil
        }
        rebalancePendingPrefetchesLocked(preferredScopeKey: nil, preferredKeys: [])
        prefetchLock.unlock()
    }

#if DEBUG
    nonisolated static func waitForPendingPrefetchesForTesting() {
        prefetchQueue.sync {}
    }

    nonisolated static func isKnownMissingForTesting(fileName: String, rootURL: URL) -> Bool {
        let key = cacheKey(rootURL: rootURL, fileName: fileName)
        prefetchLock.lock()
        defer { prefetchLock.unlock() }
        return missingDrawingKeys.contains(key as String)
    }

    nonisolated static func setDiskLoadPublicationHookForTesting(
        _ hook: (@Sendable (String) -> Void)?
    ) {
        prefetchLock.lock()
        diskLoadPublicationHookForTesting = hook
        prefetchLock.unlock()
    }

    nonisolated static func queuedPrefetchFileNamesForTesting() -> [String] {
        prefetchLock.lock()
        defer { prefetchLock.unlock() }
        return pendingPrefetchOrder.compactMap { pendingPrefetchRequests[$0]?.fileName }
    }

    nonisolated static var maximumPendingPrefetchCountForTesting: Int {
        maximumPendingPrefetchCount
    }
#endif

    nonisolated private static func prefetchScopeKey(_ scopeID: UUID?) -> String {
        scopeID?.uuidString ?? "__unscoped__"
    }

    /// Must only be called while `prefetchLock` is held.
    nonisolated private static func removePrefetchScopeInterestLocked(
        _ scopeKey: String,
        retainingKeys: Set<String>
    ) {
        let interestedRequests = pendingPrefetchRequests.filter {
            $0.value.interestedScopeKeys.contains(scopeKey) && !retainingKeys.contains($0.key)
        }
        for (key, existingRequest) in interestedRequests {
            var request = existingRequest
            request.interestedScopeKeys.remove(scopeKey)
            if request.interestedScopeKeys.isEmpty {
                pendingPrefetchRequests[key] = nil
                if prefetchStates[key]?.token == request.state.token {
                    prefetchStates[key] = nil
                }
            } else {
                if request.priorityScopeKey == scopeKey {
                    request.priorityScopeKey = request.interestedScopeKeys.sorted().first ?? "__unscoped__"
                }
                pendingPrefetchRequests[key] = request
            }
        }
    }

    /// Must only be called while `prefetchLock` is held. The global cap bounds disk
    /// work, while round-robin flattening gives every live canvas a visible-first slot
    /// before any canvas receives its next speculative slot.
    nonisolated private static func rebalancePendingPrefetchesLocked(
        preferredScopeKey: String?,
        preferredKeys: [String]
    ) {
        var keysByScope: [String: [String]] = [:]
        var assignedKeys = Set<String>()

        if let preferredScopeKey {
            for key in preferredKeys {
                guard let request = pendingPrefetchRequests[key],
                      request.priorityScopeKey == preferredScopeKey,
                      assignedKeys.insert(key).inserted else {
                    continue
                }
                keysByScope[preferredScopeKey, default: []].append(key)
            }
        }

        for key in pendingPrefetchOrder {
            guard let request = pendingPrefetchRequests[key],
                  assignedKeys.insert(key).inserted else {
                continue
            }
            keysByScope[request.priorityScopeKey, default: []].append(key)
        }

        for (key, request) in pendingPrefetchRequests.sorted(by: { $0.key < $1.key })
        where assignedKeys.insert(key).inserted {
            keysByScope[request.priorityScopeKey, default: []].append(key)
        }

        var scopeOrder: [String] = []
        for scopeKey in pendingPrefetchScopeOrder
        where keysByScope[scopeKey]?.isEmpty == false
            && !scopeOrder.contains(scopeKey) {
            scopeOrder.append(scopeKey)
        }
        if let preferredScopeKey,
           keysByScope[preferredScopeKey]?.isEmpty == false,
           !scopeOrder.contains(preferredScopeKey) {
            scopeOrder.append(preferredScopeKey)
        }
        for scopeKey in keysByScope.keys.sorted() where !scopeOrder.contains(scopeKey) {
            scopeOrder.append(scopeKey)
        }
        if let activePrefetchScopeKey,
           scopeOrder.count > 1,
           let activeIndex = scopeOrder.firstIndex(of: activePrefetchScopeKey) {
            scopeOrder.remove(at: activeIndex)
            scopeOrder.append(activePrefetchScopeKey)
        }

        var nextIndexByScope: [String: Int] = [:]
        var balancedOrder: [String] = []
        while balancedOrder.count < maximumPendingPrefetchCount {
            var appendedRequest = false
            for scopeKey in scopeOrder {
                let nextIndex = nextIndexByScope[scopeKey, default: 0]
                guard let keys = keysByScope[scopeKey], nextIndex < keys.count else { continue }
                balancedOrder.append(keys[nextIndex])
                nextIndexByScope[scopeKey] = nextIndex + 1
                appendedRequest = true
                if balancedOrder.count == maximumPendingPrefetchCount {
                    break
                }
            }
            if !appendedRequest {
                break
            }
        }

        let retainedKeys = Set(balancedOrder)
        let evictedRequests = pendingPrefetchRequests.filter { !retainedKeys.contains($0.key) }
        for (key, request) in evictedRequests {
            pendingPrefetchRequests[key] = nil
            if prefetchStates[key]?.token == request.state.token {
                prefetchStates[key] = nil
            }
        }
        pendingPrefetchOrder = balancedOrder
        let retainedScopes = Set(balancedOrder.compactMap {
            pendingPrefetchRequests[$0]?.priorityScopeKey
        })
        pendingPrefetchScopeOrder = scopeOrder.filter { retainedScopes.contains($0) }
    }

    nonisolated private static func cacheKey(rootURL: URL, fileName: String) -> NSString {
        "\(rootURL.standardizedFileURL.path)/\(StorageDirectory.drawings.rawValue)/\(fileName)" as NSString
    }

    nonisolated private static func drainPrefetchRequests() {
        while true {
            prefetchLock.lock()
            guard !pendingPrefetchOrder.isEmpty else {
                isPrefetchWorkerScheduled = false
                activePrefetchKey = nil
                activePrefetchScopeKey = nil
                activePrefetchInterestedScopeKeys.removeAll(keepingCapacity: true)
                pendingPrefetchScopeOrder.removeAll(keepingCapacity: true)
                prefetchLock.unlock()
                return
            }

            let stringKey = pendingPrefetchOrder.removeFirst()
            guard let request = pendingPrefetchRequests.removeValue(forKey: stringKey) else {
                prefetchLock.unlock()
                continue
            }
            guard let currentState = prefetchStates[stringKey],
                  currentState.token == request.state.token,
                  currentState.cacheVersion == request.state.cacheVersion,
                  drawingCache.object(forKey: request.cacheKey as NSString) == nil,
                  !missingDrawingKeys.contains(stringKey) else {
                if prefetchStates[stringKey]?.token == request.state.token {
                    prefetchStates[stringKey] = nil
                }
                prefetchLock.unlock()
                continue
            }
            activePrefetchKey = stringKey
            activePrefetchScopeKey = request.priorityScopeKey
            activePrefetchInterestedScopeKeys = request.interestedScopeKeys
            if let scopeIndex = pendingPrefetchScopeOrder.firstIndex(of: request.priorityScopeKey) {
                let consumedScopeKey = pendingPrefetchScopeOrder.remove(at: scopeIndex)
                if pendingPrefetchRequests.values.contains(where: {
                    $0.priorityScopeKey == consumedScopeKey
                }) {
                    pendingPrefetchScopeOrder.append(consumedScopeKey)
                }
            }
            prefetchLock.unlock()

            autoreleasepool {
                _ = loadDrawingFromDisk(
                    fileName: request.fileName,
                    rootURL: request.rootURL,
                    cacheKey: request.cacheKey as NSString,
                    expectedPrefetchState: request.state
                )
            }

            prefetchLock.lock()
            if prefetchStates[stringKey]?.token == request.state.token {
                prefetchStates[stringKey] = nil
            }
            if activePrefetchKey == stringKey {
                activePrefetchKey = nil
                activePrefetchScopeKey = nil
                activePrefetchInterestedScopeKeys.removeAll(keepingCapacity: true)
            }
            prefetchLock.unlock()
        }
    }

    nonisolated private static func loadDrawingFromDisk(
        fileName: String,
        rootURL: URL,
        cacheKey: NSString,
        expectedPrefetchState: PrefetchState? = nil,
        expectedCacheVersion: CacheVersionSnapshot? = nil
    ) -> DiskLoadOutcome {
        do {
            // Reads do not need to create the drawings directory. This avoids a
            // filesystem mutation and directory check on every cold page load.
            let url = rootURL
                .appendingPathComponent(StorageDirectory.drawings.rawValue, isDirectory: true)
                .appendingPathComponent(fileName)
            let data = try Data(contentsOf: url)
            if let expectedPrefetchState,
               !isPrefetchStateCurrent(expectedPrefetchState, for: cacheKey as String) {
                return .superseded
            }
            let drawing = try PKDrawing(data: data)
            invokeDiskLoadPublicationHookForTesting(fileName: fileName)
            if let expectedPrefetchState {
                guard isPrefetchStateCurrent(
                    expectedPrefetchState,
                    for: cacheKey as String
                ) else {
                    return .superseded
                }
                cachePrefetchedDrawing(
                    drawing,
                    cacheKey: cacheKey,
                    expectedState: expectedPrefetchState,
                    approximateBytes: data.count,
                    archiveData: data
                )
                return .resolved(.loaded(drawing, archiveData: data))
            } else {
                guard let expectedCacheVersion else {
                    return .resolved(.loaded(drawing, archiveData: data))
                }
                guard let resolvedDrawing = cacheDiskDrawingUnlessSuperseded(
                    drawing,
                    cacheKey: cacheKey,
                    expectedCacheVersion: expectedCacheVersion,
                    approximateBytes: data.count,
                    archiveData: data
                ) else {
                    return .superseded
                }
                return .resolved(.loaded(
                    resolvedDrawing.drawing,
                    archiveData: resolvedDrawing.archiveData
                ))
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            let recorded = recordMissingDrawing(
                cacheKey,
                expectedPrefetchState: expectedPrefetchState,
                expectedCacheVersion: expectedCacheVersion
            )
            if expectedPrefetchState == nil, !recorded {
                return .superseded
            }
            return .resolved(.missing)
        } catch {
            if let expectedCacheVersion,
               !isCacheVersionCurrent(expectedCacheVersion, for: cacheKey as String) {
                return .superseded
            }
            return .resolved(.unavailable(DrawingLoadError(underlyingError: error)))
        }
    }

    nonisolated private static func loadDrawingFromDiskWithoutCaching(
        fileName: String,
        rootURL: URL
    ) -> LoadResult {
        do {
            let url = rootURL
                .appendingPathComponent(StorageDirectory.drawings.rawValue, isDirectory: true)
                .appendingPathComponent(fileName)
            let data = try Data(contentsOf: url)
            let drawing = try PKDrawing(data: data)
            invokeDiskLoadPublicationHookForTesting(fileName: fileName)
            return .loaded(drawing, archiveData: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .unavailable(DrawingLoadError(underlyingError: error))
        }
    }

    nonisolated private static func resolveUncachedFallback(
        _ fallbackResult: LoadResult,
        fileName: String,
        rootURL: URL,
        cacheKey: NSString,
        expectedCacheVersion: CacheVersionSnapshot
    ) -> LoadResult {
        let stringKey = cacheKey as String
        prefetchLock.lock()
        let cachedDrawing = drawingCache.object(forKey: cacheKey)
        let isKnownMissing = missingDrawingKeys.contains(stringKey)
        let currentVersion = currentCacheVersionLocked(for: stringKey)
        prefetchLock.unlock()

        if let cachedDrawing {
            return .loaded(cachedDrawing.drawing, archiveData: cachedDrawing.archiveData)
        }
        if isKnownMissing {
            return .missing
        }
        guard currentVersion.epoch != expectedCacheVersion.epoch
            || currentVersion.keyVersion != expectedCacheVersion.keyVersion else {
            return fallbackResult
        }

        let refreshedResult = loadDrawingFromDiskWithoutCaching(
            fileName: fileName,
            rootURL: rootURL
        )
        prefetchLock.lock()
        let refreshedCachedDrawing = drawingCache.object(forKey: cacheKey)
        let isFinallyKnownMissing = missingDrawingKeys.contains(stringKey)
        prefetchLock.unlock()

        if let refreshedCachedDrawing {
            return .loaded(
                refreshedCachedDrawing.drawing,
                archiveData: refreshedCachedDrawing.archiveData
            )
        }
        return isFinallyKnownMissing ? .missing : refreshedResult
    }

    nonisolated private static func invokeDiskLoadPublicationHookForTesting(fileName: String) {
#if DEBUG
        prefetchLock.lock()
        let hook = diskLoadPublicationHookForTesting
        prefetchLock.unlock()
        hook?(fileName)
#endif
    }

    nonisolated private static func cacheDiskDrawingUnlessSuperseded(
        _ drawing: PKDrawing,
        cacheKey: NSString,
        expectedCacheVersion: CacheVersionSnapshot,
        approximateBytes: Int,
        archiveData: Data
    ) -> CachedDrawing? {
        let stringKey = cacheKey as String
        prefetchLock.lock()
        defer { prefetchLock.unlock() }

        let currentVersion = currentCacheVersionLocked(for: stringKey)
        guard currentVersion.epoch == expectedCacheVersion.epoch,
              currentVersion.keyVersion == expectedCacheVersion.keyVersion else {
            return drawingCache.object(forKey: cacheKey)
        }

        // A matching disk load may have populated the cache while this archive was
        // being decoded. Reuse it instead of doing another NSCache replacement.
        if let cached = drawingCache.object(forKey: cacheKey) {
            return cached
        }
        if var state = prefetchStates[stringKey] {
            state.cacheVersion &+= 1
            prefetchStates[stringKey] = state
        }
        removeMissingDrawingKeyLocked(stringKey)
        let cachedDrawing = CachedDrawing(drawing, archiveData: archiveData)
        drawingCache.setObject(
            cachedDrawing,
            forKey: cacheKey,
            cost: max(approximateBytes, 1) + archiveData.count
        )
        return cachedDrawing
    }

    nonisolated private static func cachePrefetchedDrawing(
        _ drawing: PKDrawing,
        cacheKey: NSString,
        expectedState: PrefetchState,
        approximateBytes: Int,
        archiveData: Data
    ) {
        let stringKey = cacheKey as String
        prefetchLock.lock()
        defer { prefetchLock.unlock() }
        guard let currentState = prefetchStates[stringKey],
              currentState.token == expectedState.token,
              currentState.cacheVersion == expectedState.cacheVersion else {
            return
        }

        removeMissingDrawingKeyLocked(stringKey)
        drawingCache.setObject(
            CachedDrawing(drawing, archiveData: archiveData),
            forKey: cacheKey,
            cost: max(approximateBytes, 1) + archiveData.count
        )
    }

    nonisolated private static func recordMissingDrawing(
        _ key: NSString,
        expectedPrefetchState: PrefetchState?,
        expectedCacheVersion: CacheVersionSnapshot?
    ) -> Bool {
        let stringKey = key as String
        prefetchLock.lock()
        defer { prefetchLock.unlock() }
        if let expectedPrefetchState {
            guard let currentState = prefetchStates[stringKey],
                  currentState.token == expectedPrefetchState.token,
                  currentState.cacheVersion == expectedPrefetchState.cacheVersion else {
                return false
            }
        }
        if let expectedCacheVersion {
            let currentVersion = currentCacheVersionLocked(for: stringKey)
            guard currentVersion.epoch == expectedCacheVersion.epoch,
                  currentVersion.keyVersion == expectedCacheVersion.keyVersion else {
                return false
            }
        }

        // A writer may have populated the in-memory cache while this disk read was
        // failing. Never let that stale miss hide the successfully written drawing.
        if drawingCache.object(forKey: key) == nil,
           missingDrawingKeys.insert(stringKey).inserted {
            missingDrawingKeyOrder.append(stringKey)
            if missingDrawingKeyOrder.count > maximumMissingDrawingCount {
                let evictedKey = missingDrawingKeyOrder.removeFirst()
                missingDrawingKeys.remove(evictedKey)
            }
        }
        return true
    }

    /// Must only be called while `prefetchLock` is held.
    nonisolated private static func currentCacheVersionLocked(for key: String) -> CacheVersionSnapshot {
        CacheVersionSnapshot(epoch: cacheVersionEpoch, keyVersion: cacheVersions[key] ?? 0)
    }

    /// Must only be called while `prefetchLock` is held. The epoch bounds bookkeeping
    /// without weakening in-flight read validation: rotating it invalidates every
    /// outstanding snapshot before per-key versions are discarded.
    nonisolated private static func advanceCacheVersionLocked(for key: String) {
        if cacheVersions[key] == nil,
           cacheVersions.count >= maximumTrackedCacheVersionCount {
            cacheVersionEpoch &+= 1
            cacheVersions.removeAll(keepingCapacity: true)
        }
        cacheVersions[key, default: 0] &+= 1
    }

    nonisolated private static func isCacheVersionCurrent(
        _ snapshot: CacheVersionSnapshot,
        for key: String
    ) -> Bool {
        prefetchLock.lock()
        defer { prefetchLock.unlock() }
        let currentVersion = currentCacheVersionLocked(for: key)
        return currentVersion.epoch == snapshot.epoch
            && currentVersion.keyVersion == snapshot.keyVersion
    }

    nonisolated private static func isPrefetchStateCurrent(
        _ expectedState: PrefetchState,
        for key: String
    ) -> Bool {
        prefetchLock.lock()
        defer { prefetchLock.unlock() }
        guard let currentState = prefetchStates[key] else { return false }
        return currentState.token == expectedState.token
            && currentState.cacheVersion == expectedState.cacheVersion
    }

    /// Must only be called while `prefetchLock` is held.
    nonisolated private static func removeMissingDrawingKeyLocked(_ key: String) {
        guard missingDrawingKeys.remove(key) != nil else { return }
        missingDrawingKeyOrder.removeAll { $0 == key }
    }

    nonisolated private static func ensureMemoryWarningObservation() {
        _ = memoryWarningObserver
    }
}

private final class CachedDrawing {
    let drawing: PKDrawing
    let archiveData: Data?

    nonisolated init(_ drawing: PKDrawing, archiveData: Data? = nil) {
        self.drawing = drawing
        self.archiveData = archiveData
    }
}
