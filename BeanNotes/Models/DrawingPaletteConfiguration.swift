//
//  DrawingPaletteConfiguration.swift
//  BeanNotes
//

import CoreGraphics
import Foundation
import UIKit

enum DrawingPaletteConfiguration {
    static let colorCountStorageKey = "drawingPalette.colorCount"
    static let minimumColorCount = 1
    static let maximumColorCount = 8

    private static let compactIPadDefaultColorCount = 5
    // 11-inch iPads reach at most 1,210 points on their longest edge; 12.9/13-inch models start at 1,366.
    private static let largeIPadMinimumLongestScreenSide: CGFloat = 1_280

    static var supportedColorCounts: ClosedRange<Int> {
        minimumColorCount...maximumColorCount
    }

    static var defaultColorCountForCurrentDevice: Int {
        defaultColorCount(for: UIScreen.main.fixedCoordinateSpace.bounds.size)
    }

    static func persistedColorCount(
        for screenSize: CGSize,
        in defaults: UserDefaults = .standard
    ) -> Int {
        guard defaults.object(forKey: colorCountStorageKey) != nil else {
            let defaultCount = defaultColorCount(for: screenSize)
            defaults.set(defaultCount, forKey: colorCountStorageKey)
            return defaultCount
        }

        let normalizedCount = normalizedColorCount(defaults.integer(forKey: colorCountStorageKey))
        if defaults.integer(forKey: colorCountStorageKey) != normalizedCount {
            defaults.set(normalizedCount, forKey: colorCountStorageKey)
        }
        return normalizedCount
    }

    static func persistedColorCountForCurrentDevice() -> Int {
        persistedColorCount(for: UIScreen.main.fixedCoordinateSpace.bounds.size)
    }

    static func defaultColorCount(for screenSize: CGSize) -> Int {
        max(screenSize.width, screenSize.height) >= largeIPadMinimumLongestScreenSide
            ? maximumColorCount
            : compactIPadDefaultColorCount
    }

    static func normalizedColorCount(_ colorCount: Int) -> Int {
        min(max(colorCount, minimumColorCount), maximumColorCount)
    }
}
