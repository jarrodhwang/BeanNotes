//
//  ImageMemoryCache.swift
//  BeanNotes
//

import ImageIO
import UIKit

final class ImageMemoryCache {
    static let shared = ImageMemoryCache()

    private let cache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default

    private init() {
        cache.countLimit = 160
        cache.totalCostLimit = 96 * 1024 * 1024

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
            return cached
        }

        let image: UIImage?
        if let maxPixelSize, maxPixelSize > 0 {
            image = downsampledImage(at: url, maxPixelSize: maxPixelSize)
        } else {
            image = UIImage(contentsOfFile: url.path)
        }

        if let image {
            cache.setObject(image, forKey: key, cost: image.cacheCost)
        }

        return image
    }

    @objc func removeAllImages() {
        cache.removeAllObjects()
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
}

private extension UIImage {
    var cacheCost: Int {
        guard let cgImage else { return 1 }
        return max(1, cgImage.bytesPerRow * cgImage.height)
    }
}
