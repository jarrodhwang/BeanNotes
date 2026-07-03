//
//  NoteBackground.swift
//  BeanNote
//

import SwiftUI
import UIKit

enum NoteBackgroundStyle: String, Codable, CaseIterable, Identifiable {
    case plain
    case grid
    case dotted
    case lined

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plain:
            "Plain"
        case .grid:
            "Grid"
        case .dotted:
            "Dotted"
        case .lined:
            "Lined"
        }
    }
}

struct NoteBackgroundColorPreset: Identifiable, Equatable {
    var name: String
    var colorHex: String

    var id: String { colorHex }
}

struct NoteBackground: Codable, Equatable {
    static let defaultStyleRawKey = "defaultNoteBackgroundStyle"
    static let defaultColorHexKey = "defaultNoteBackgroundColorHex"
    static let defaultColorHex = "#FFFFFF"

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

    static func plain(colorHex: String = "#FFFFFF") -> NoteBackground {
        NoteBackground(style: .plain, colorHex: colorHex)
    }

    static func fromDefaults(styleRaw: String, colorHex: String) -> NoteBackground {
        NoteBackground(
            style: NoteBackgroundStyle(rawValue: styleRaw) ?? .plain,
            colorHex: colorHex.isEmpty ? defaultColorHex : colorHex
        )
    }
}

extension Color {
    init(hex: String) {
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
    convenience init(hex: String) {
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
            Int(red * 255),
            Int(green * 255),
            Int(blue * 255)
        )
    }
}
