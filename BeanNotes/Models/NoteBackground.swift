//
//  NoteBackground.swift
//  BeanNotes
//

import SwiftUI
import UIKit

enum NoteBackgroundStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case plain
    case grid
    case dotted
    case lined
    case cornell
    case musicStaff
    case planner

    nonisolated var id: String { rawValue }

    nonisolated var label: String {
        switch self {
        case .plain:
            "Plain"
        case .grid:
            "Grid"
        case .dotted:
            "Dotted"
        case .lined:
            "Lined"
        case .cornell:
            "Cornell"
        case .musicStaff:
            "Music Staff"
        case .planner:
            "Planner"
        }
    }

    nonisolated var supportsSpacing: Bool {
        switch self {
        case .plain:
            false
        case .grid, .dotted, .lined, .cornell, .musicStaff, .planner:
            true
        }
    }

    nonisolated var supportsMargin: Bool {
        switch self {
        case .plain, .musicStaff:
            false
        case .grid, .dotted, .lined, .cornell, .planner:
            true
        }
    }

    nonisolated var defaultSpacing: Double {
        switch self {
        case .plain:
            0
        case .grid:
            32
        case .dotted:
            28
        case .lined, .cornell:
            36
        case .musicStaff:
            10
        case .planner:
            44
        }
    }

    nonisolated var spacingRange: ClosedRange<Double> {
        switch self {
        case .musicStaff:
            7...16
        case .planner:
            32...72
        case .plain:
            0...0
        case .grid, .dotted, .lined, .cornell:
            18...64
        }
    }

    nonisolated var defaultMarginWidth: Double {
        switch self {
        case .plain, .grid, .dotted, .musicStaff:
            0
        case .lined:
            72
        case .cornell:
            228
        case .planner:
            92
        }
    }

    nonisolated var marginRange: ClosedRange<Double> {
        switch self {
        case .cornell:
            140...320
        case .planner:
            64...140
        case .grid, .dotted, .lined:
            0...160
        case .plain, .musicStaff:
            0...0
        }
    }
}

struct NoteBackgroundColorPreset: Identifiable, Equatable, Sendable {
    var name: String
    var colorHex: String

    var id: String { colorHex }
}

struct NoteBackground: Codable, Equatable, Sendable {
    nonisolated static let defaultStyleRawKey = "defaultNoteBackgroundStyle"
    nonisolated static let defaultColorHexKey = "defaultNoteBackgroundColorHex"
    nonisolated static let defaultColorHex = "#FFFFFF"

    static let colorPresets: [NoteBackgroundColorPreset] = [
        NoteBackgroundColorPreset(name: "White", colorHex: "#FFFFFF"),
        NoteBackgroundColorPreset(name: "Yellow", colorHex: "#FFF7BF"),
        NoteBackgroundColorPreset(name: "Beige", colorHex: "#F3E7CF"),
        NoteBackgroundColorPreset(name: "Cream", colorHex: "#FFF4DF"),
        NoteBackgroundColorPreset(name: "Pink", colorHex: "#FFE1E8"),
        NoteBackgroundColorPreset(name: "Blue", colorHex: "#DDEBFF"),
        NoteBackgroundColorPreset(name: "Green", colorHex: "#DFF3E4"),
        NoteBackgroundColorPreset(name: "Gray", colorHex: "#F2F4F7")
    ]

    var style: NoteBackgroundStyle
    var colorHex: String
    var spacing: Double?
    var marginWidth: Double?

    nonisolated init(
        style: NoteBackgroundStyle,
        colorHex: String,
        spacing: Double? = nil,
        marginWidth: Double? = nil
    ) {
        self.style = style
        self.colorHex = colorHex
        self.spacing = spacing
        self.marginWidth = marginWidth
    }

    nonisolated static func plain(colorHex: String = "#FFFFFF") -> NoteBackground {
        NoteBackground(style: .plain, colorHex: colorHex)
    }

    nonisolated static func fromDefaults(styleRaw: String, colorHex: String) -> NoteBackground {
        let decoded = decodeStyleRaw(styleRaw)
        return NoteBackground(
            style: decoded.style,
            colorHex: colorHex.isEmpty ? defaultColorHex : colorHex,
            spacing: decoded.spacing,
            marginWidth: decoded.marginWidth
        )
    }

    nonisolated var storageStyleRaw: String {
        var components = [style.rawValue]

        if let spacing, style.supportsSpacing {
            components.append("spacing=\(Self.encodedNumber(clampedSpacing(spacing)))")
        }

        if let marginWidth, style.supportsMargin {
            components.append("margin=\(Self.encodedNumber(clampedMarginWidth(marginWidth)))")
        }

        return components.joined(separator: ";")
    }

    nonisolated var resolvedSpacing: Double {
        guard style.supportsSpacing else { return 0 }
        return clampedSpacing(spacing ?? style.defaultSpacing)
    }

    nonisolated var resolvedMarginWidth: Double {
        guard style.supportsMargin else { return 0 }
        return clampedMarginWidth(marginWidth ?? style.defaultMarginWidth)
    }

    nonisolated func changingStyle(to style: NoteBackgroundStyle) -> NoteBackground {
        NoteBackground(
            style: style,
            colorHex: colorHex,
            spacing: style.supportsSpacing ? clamped(spacing ?? style.defaultSpacing, to: style.spacingRange) : nil,
            marginWidth: style.supportsMargin ? clamped(marginWidth ?? style.defaultMarginWidth, to: style.marginRange) : nil
        )
    }

    nonisolated func changingSpacing(to spacing: Double) -> NoteBackground {
        NoteBackground(
            style: style,
            colorHex: colorHex,
            spacing: style.supportsSpacing ? clamped(spacing, to: style.spacingRange) : nil,
            marginWidth: marginWidth
        )
    }

    nonisolated func changingMarginWidth(to marginWidth: Double) -> NoteBackground {
        NoteBackground(
            style: style,
            colorHex: colorHex,
            spacing: spacing,
            marginWidth: style.supportsMargin ? clamped(marginWidth, to: style.marginRange) : nil
        )
    }

    nonisolated private static func decodeStyleRaw(_ styleRaw: String) -> (style: NoteBackgroundStyle, spacing: Double?, marginWidth: Double?) {
        let components = styleRaw.split(separator: ";", omittingEmptySubsequences: true)
        let style = components.first
            .flatMap { NoteBackgroundStyle(rawValue: String($0)) } ?? .plain
        var spacing: Double?
        var marginWidth: Double?

        for component in components.dropFirst() {
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }

            let key = String(pair[0])
            let value = Double(pair[1])

            switch key {
            case "spacing":
                spacing = value
            case "margin":
                marginWidth = value
            default:
                continue
            }
        }

        return (
            style,
            style.supportsSpacing ? spacing.map { clamped($0, to: style.spacingRange) } : nil,
            style.supportsMargin ? marginWidth.map { clamped($0, to: style.marginRange) } : nil
        )
    }

    nonisolated private func clampedSpacing(_ value: Double) -> Double {
        Self.clamped(value, to: style.spacingRange)
    }

    nonisolated private func clampedMarginWidth(_ value: Double) -> Double {
        Self.clamped(value, to: style.marginRange)
    }

    nonisolated private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        if value.isNaN {
            return range.lowerBound
        }

        if value == .infinity {
            return range.upperBound
        }

        if value == -.infinity {
            return range.lowerBound
        }

        return min(max(value, range.lowerBound), range.upperBound)
    }

    nonisolated private func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        Self.clamped(value, to: range)
    }

    nonisolated private static func encodedNumber(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded.rounded() == rounded {
            return String(Int(rounded))
        } else {
            return String(format: "%.1f", rounded)
        }
    }
}

extension Color {
    nonisolated init(hex: String) {
        let hexString = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&value)

        let red: Double
        let green: Double
        let blue: Double

        switch hexString.count {
        case 3:
            red = Double((value >> 8) & 0xF) / 15
            green = Double((value >> 4) & 0xF) / 15
            blue = Double(value & 0xF) / 15
        default:
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
        }

        self.init(red: red, green: green, blue: blue)
    }

    var hexRGB: String {
        UIColor(self).hexRGB
    }
}

extension UIColor {
    nonisolated convenience init(hex: String) {
        let hexString = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&value)

        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        switch hexString.count {
        case 3:
            red = CGFloat((value >> 8) & 0xF) / 15
            green = CGFloat((value >> 4) & 0xF) / 15
            blue = CGFloat(value & 0xF) / 15
        default:
            red = CGFloat((value >> 16) & 0xFF) / 255
            green = CGFloat((value >> 8) & 0xFF) / 255
            blue = CGFloat(value & 0xFF) / 255
        }

        self.init(red: red, green: green, blue: blue, alpha: 1)
    }

    var hexRGB: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "#%02X%02X%02X",
            Self.hexComponent(red),
            Self.hexComponent(green),
            Self.hexComponent(blue)
        )
    }

    private static func hexComponent(_ value: CGFloat) -> Int {
        let clamped = min(max(value, 0), 1)
        return Int((clamped * 255).rounded())
    }
}
