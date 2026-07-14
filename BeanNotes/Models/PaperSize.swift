//
//  PaperSize.swift
//  BeanNotes
//

import Foundation

/// Portrait page sizes, expressed in PostScript points (72 points per inch).
enum PaperSize: String, CaseIterable, Identifiable {
    static let storageKey = "defaultPaperSize"
    static let defaultPaperSize: PaperSize = .letter

    case letter
    case legal
    case tabloid
    case a3
    case a4
    case a5
    case a6
    case b4
    case b5

    var id: String { rawValue }

    var label: String {
        switch self {
        case .letter: "Letter"
        case .legal: "Legal"
        case .tabloid: "Tabloid"
        case .a3: "A3"
        case .a4: "A4"
        case .a5: "A5"
        case .a6: "A6"
        case .b4: "B4"
        case .b5: "B5"
        }
    }

    var dimensions: CGSize {
        switch self {
        case .letter: CGSize(width: 612, height: 792)
        case .legal: CGSize(width: 612, height: 1_008)
        case .tabloid: CGSize(width: 792, height: 1_224)
        case .a3: CGSize(width: 842, height: 1_191)
        case .a4: CGSize(width: 595, height: 842)
        case .a5: CGSize(width: 420, height: 595)
        case .a6: CGSize(width: 298, height: 420)
        case .b4: CGSize(width: 709, height: 1_001)
        case .b5: CGSize(width: 499, height: 709)
        }
    }
}
