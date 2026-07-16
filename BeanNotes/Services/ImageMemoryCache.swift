//
//  ImageMemoryCache.swift
//  BeanNotes
//

import ImageIO
import UIKit

struct ImageFileIdentity: Hashable {
    var standardizedPath: String
    var modifiedAt: TimeInterval
    var byteCount: Int64
}

final class ImageMemoryCache: NSObject, NSCacheDelegate {
    static let shared = ImageMemoryCache()
    private static let memoryCostLimit = 48 * 1024 * 1024
    private static let maximumDecodePixelSize = 16_384

    private nonisolated final class BackgroundDecodeToken: @unchecked Sendable {
        private let lock = NSLock()
        private var isCancelledStorage = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isCancelledStorage
        }

        func cancel() {
            lock.lock()
            isCancelledStorage = true
            lock.unlock()
        }
    }

    private static let backgroundDecodeQueue = DispatchQueue(
        label: "com.snowfox.BeanNotes.thumbnail-image-decode",
        qos: .utility
    )

    private let cache = NSCache<NSString, CachedImage>()
    private let fileManager = FileManager.default
    private let keyIndexLock = NSLock()
    private var cacheKeysByPath: [String: Set<NSString>] = [:]

    private override init() {
        super.init()
        cache.countLimit = 80
        cache.totalCostLimit = Self.memoryCostLimit
        cache.delegate = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(removeAllImages),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    func image(
        at url: URL,
        maxPixelSize: CGFloat? = nil,
        identity suppliedIdentity: ImageFileIdentity? = nil
    ) -> UIImage? {
        let normalizedPixelSize = normalizedPixelSize(maxPixelSize)
        let identity = suppliedIdentity ?? fileIdentity(for: url)
        let key = cacheKey(for: identity, maxPixelSize: normalizedPixelSize)
        if let cached = cache.object(forKey: key) {
            return cached.image
        }

        let image: UIImage?
        if let maxPixelSize = normalizedPixelSize {
            image = downsampledImage(at: url, maxPixelSize: maxPixelSize)
        } else {
            image = UIImage(contentsOfFile: url.path)
        }

        if let image {
            let cost = image.cacheCost
            if cost <= Self.memoryCostLimit {
                cache.setObject(
                    CachedImage(image: image, key: key, path: identity.standardizedPath),
                    forKey: key,
                    cost: cost
                )
                recordCachedKey(key, path: identity.standardizedPath)
            }
        }

        return image
    }

    func imageInBackground(at url: URL, maxPixelSize: CGFloat? = nil) async -> UIImage? {
        let token = BackgroundDecodeToken()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.backgroundDecodeQueue.async { [weak self] in
                    guard !token.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }

                    let image = self?.image(at: url, maxPixelSize: maxPixelSize)
                    continuation.resume(returning: token.isCancelled ? nil : image)
                }
            }
        } onCancel: {
            token.cancel()
        }
    }

    func removeImages(for url: URL) {
        let keys = removeCachedKeys(for: url)
        for key in keys {
            cache.removeObject(forKey: key)
        }
    }

    @objc func removeAllImages() {
        cache.removeAllObjects()
        removeAllCachedKeys()
    }

    func cachedVariantCount(for url: URL) -> Int {
        keyIndexLock.lock()
        defer { keyIndexLock.unlock() }
        return cacheKeysByPath[standardizedPath(for: url)]?.count ?? 0
    }

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        guard let cachedImage = obj as? CachedImage else { return }
        removeCachedKey(cachedImage.key, path: cachedImage.path)
    }

    private func downsampledImage(at url: URL, maxPixelSize: Int) -> UIImage? {
        let options = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary

        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
            return nil
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    func fileIdentity(for url: URL) -> ImageFileIdentity {
        let path = standardizedPath(for: url)
        let attributes = try? fileManager.attributesOfItem(atPath: path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return ImageFileIdentity(
            standardizedPath: path,
            modifiedAt: modified,
            byteCount: size
        )
    }

    private func cacheKey(for identity: ImageFileIdentity, maxPixelSize: Int?) -> NSString {
        let pixelSize = maxPixelSize ?? 0
        return "\(identity.standardizedPath)|\(identity.modifiedAt)|\(identity.byteCount)|\(pixelSize)" as NSString
    }

    private func normalizedPixelSize(_ maxPixelSize: CGFloat?) -> Int? {
        guard let maxPixelSize, maxPixelSize.isFinite, maxPixelSize > 0 else {
            return nil
        }
        let bounded = min(maxPixelSize.rounded(), CGFloat(Self.maximumDecodePixelSize))
        return max(1, Int(bounded))
    }

    private func recordCachedKey(_ key: NSString, path: String) {
        keyIndexLock.lock()
        cacheKeysByPath[path, default: []].insert(key)
        keyIndexLock.unlock()
    }

    private func removeCachedKeys(for url: URL) -> Set<NSString> {
        keyIndexLock.lock()
        defer { keyIndexLock.unlock() }
        return cacheKeysByPath.removeValue(forKey: standardizedPath(for: url)) ?? []
    }

    private func removeAllCachedKeys() {
        keyIndexLock.lock()
        cacheKeysByPath.removeAll()
        keyIndexLock.unlock()
    }

    private func removeCachedKey(_ key: NSString, path: String) {
        keyIndexLock.lock()
        if var keys = cacheKeysByPath[path] {
            keys.remove(key)
            cacheKeysByPath[path] = keys.isEmpty ? nil : keys
        }
        keyIndexLock.unlock()
    }

    private func standardizedPath(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}

private final class CachedImage {
    let image: UIImage
    let key: NSString
    let path: String

    init(image: UIImage, key: NSString, path: String) {
        self.image = image
        self.key = key
        self.path = path
    }
}

private extension UIImage {
    var cacheCost: Int {
        guard let cgImage else { return 1 }
        return max(1, cgImage.bytesPerRow * cgImage.height)
    }
}
