import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(DeveloperToolsSupport)
import DeveloperToolsSupport
#endif

#if SWIFT_PACKAGE
private let resourceBundle = Foundation.Bundle.module
#else
private class ResourceBundleClass {}
private let resourceBundle = Foundation.Bundle(for: ResourceBundleClass.self)
#endif

// MARK: - Color Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ColorResource {

}

// MARK: - Image Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ImageResource {

    /// The "BeanBadge" asset catalog image resource.
    static let beanBadge = DeveloperToolsSupport.ImageResource(name: "BeanBadge", bundle: resourceBundle)

    /// The "BeanPaperTexture" asset catalog image resource.
    static let beanPaperTexture = DeveloperToolsSupport.ImageResource(name: "BeanPaperTexture", bundle: resourceBundle)

    /// The "BeanTabAvatar" asset catalog image resource.
    static let beanTabAvatar = DeveloperToolsSupport.ImageResource(name: "BeanTabAvatar", bundle: resourceBundle)

    /// The "BeanWelcomeImage" asset catalog image resource.
    static let beanWelcome = DeveloperToolsSupport.ImageResource(name: "BeanWelcomeImage", bundle: resourceBundle)

    /// The "BlueberryBadge" asset catalog image resource.
    static let blueberryBadge = DeveloperToolsSupport.ImageResource(name: "BlueberryBadge", bundle: resourceBundle)

    /// The "BlueberryPaperTexture" asset catalog image resource.
    static let blueberryPaperTexture = DeveloperToolsSupport.ImageResource(name: "BlueberryPaperTexture", bundle: resourceBundle)

    /// The "BlueberryVisitImage" asset catalog image resource.
    static let blueberryVisit = DeveloperToolsSupport.ImageResource(name: "BlueberryVisitImage", bundle: resourceBundle)

}

// MARK: - Color Symbol Extensions -

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSColor {

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIColor {

}
#endif

#if canImport(SwiftUI)
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.Color {

}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.ShapeStyle where Self == SwiftUI.Color {

}
#endif

// MARK: - Image Symbol Extensions -

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSImage {

    /// The "BeanBadge" asset catalog image.
    static var beanBadge: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .beanBadge)
#else
        .init()
#endif
    }

    /// The "BeanPaperTexture" asset catalog image.
    static var beanPaperTexture: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .beanPaperTexture)
#else
        .init()
#endif
    }

    /// The "BeanTabAvatar" asset catalog image.
    static var beanTabAvatar: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .beanTabAvatar)
#else
        .init()
#endif
    }

    /// The "BeanWelcomeImage" asset catalog image.
    static var beanWelcome: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .beanWelcome)
#else
        .init()
#endif
    }

    /// The "BlueberryBadge" asset catalog image.
    static var blueberryBadge: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .blueberryBadge)
#else
        .init()
#endif
    }

    /// The "BlueberryPaperTexture" asset catalog image.
    static var blueberryPaperTexture: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .blueberryPaperTexture)
#else
        .init()
#endif
    }

    /// The "BlueberryVisitImage" asset catalog image.
    static var blueberryVisit: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .blueberryVisit)
#else
        .init()
#endif
    }

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIImage {

    /// The "BeanBadge" asset catalog image.
    static var beanBadge: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .beanBadge)
#else
        .init()
#endif
    }

    /// The "BeanPaperTexture" asset catalog image.
    static var beanPaperTexture: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .beanPaperTexture)
#else
        .init()
#endif
    }

    /// The "BeanTabAvatar" asset catalog image.
    static var beanTabAvatar: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .beanTabAvatar)
#else
        .init()
#endif
    }

    /// The "BeanWelcomeImage" asset catalog image.
    static var beanWelcome: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .beanWelcome)
#else
        .init()
#endif
    }

    /// The "BlueberryBadge" asset catalog image.
    static var blueberryBadge: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .blueberryBadge)
#else
        .init()
#endif
    }

    /// The "BlueberryPaperTexture" asset catalog image.
    static var blueberryPaperTexture: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .blueberryPaperTexture)
#else
        .init()
#endif
    }

    /// The "BlueberryVisitImage" asset catalog image.
    static var blueberryVisit: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .blueberryVisit)
#else
        .init()
#endif
    }

}
#endif

// MARK: - Thinnable Asset Support -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@available(watchOS, unavailable)
extension DeveloperToolsSupport.ColorResource {

    private init?(thinnableName: Swift.String, bundle: Foundation.Bundle) {
#if canImport(AppKit) && os(macOS)
        if AppKit.NSColor(named: NSColor.Name(thinnableName), bundle: bundle) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#elseif canImport(UIKit) && !os(watchOS)
        if UIKit.UIColor(named: thinnableName, in: bundle, compatibleWith: nil) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIColor {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
#if !os(watchOS)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

#if canImport(SwiftUI)
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.Color {

    private init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
        if let resource = thinnableResource {
            self.init(resource)
        } else {
            return nil
        }
    }

}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.ShapeStyle where Self == SwiftUI.Color {

    private init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
        if let resource = thinnableResource {
            self.init(resource)
        } else {
            return nil
        }
    }

}
#endif

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@available(watchOS, unavailable)
extension DeveloperToolsSupport.ImageResource {

    private init?(thinnableName: Swift.String, bundle: Foundation.Bundle) {
#if canImport(AppKit) && os(macOS)
        if bundle.image(forResource: NSImage.Name(thinnableName)) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#elseif canImport(UIKit) && !os(watchOS)
        if UIKit.UIImage(named: thinnableName, in: bundle, compatibleWith: nil) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSImage {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ImageResource?) {
#if !targetEnvironment(macCatalyst)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIImage {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ImageResource?) {
#if !os(watchOS)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

