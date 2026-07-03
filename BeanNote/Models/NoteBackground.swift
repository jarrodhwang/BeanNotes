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

struct NoteBackground: Codable, Equatable {
    var style: NoteBackgroundStyle
    var colorHex: String

    static func plain(colorHex: String = "#FFFFFF") -> NoteBackground {
        NoteBackground(style: .plain, colorHex: colorHex)
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
