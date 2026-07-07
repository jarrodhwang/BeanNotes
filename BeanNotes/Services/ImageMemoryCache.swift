//
//  ImageMemoryCache.swift
//  BeanNotes
//

import ImageIO
import UIKit

final class ImageMemoryCache: NSObject, NSCacheDelegate {
    static let shared = ImageMemoryCache()

    private let cache = NSCache<NSString, CachedImage>()
    private let fileManager = FileManager.default
    private let keyIndexLock = NSLock()
    private var cacheKeysByPath: [String: Set<NSString>] = [:]

    private override init() {
        super.init()
        cache.countLimit = 80
        cache.totalCostLimit = 48 * 1024 * 1024
        cache.delegate = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(removeAllImages),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    func image(at url: URL, maxPixelSize: CGFloat? = nil) -> UIImage? {
        let key = cacheKey(for: url, maxPixelSize: maxPixelSize)
        if let cached = cache.object(forKey: key) {
            return cached.image
        }

        let image: UIImage?
        if let maxPixelSize, maxPixelSize > 0 {
            image = downsampledImage(at: url, maxPixelSize: maxPixelSize)
        } else {
            image = UIImage(contentsOfFile: url.path)
        }

        if let image {
            let path = standardizedPath(for: url)
            cache.setObject(
                CachedImage(image: image, key: key, path: path),
                forKey: key,
                cost: image.cacheCost
            )
            recordCachedKey(key, path: path)
        }

        return image
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

    private func downsampledImage(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let options = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary

        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
            return UIImage(contentsOfFile: url.path)
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize.rounded()))
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return UIImage(contentsOfFile: url.path)
        }

        return UIImage(cgImage: cgImage)
    }

    private func cacheKey(for url: URL, maxPixelSize: CGFloat?) -> NSString {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let pixelSize = Int((maxPixelSize ?? 0).rounded())
        return "\(url.path)|\(modified)|\(size)|\(pixelSize)" as NSString
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
