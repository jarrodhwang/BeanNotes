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

    var dimensionsLabel: String {
        switch self {
        case .letter: "8.5 × 11 in"
        case .legal: "8.5 × 14 in"
        case .tabloid: "11 × 17 in"
        case .a3: "297 × 420 mm"
        case .a4: "210 × 297 mm"
        case .a5: "148 × 210 mm"
        case .a6: "105 × 148 mm"
        case .b4: "250 × 353 mm"
        case .b5: "176 × 250 mm"
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

    static func matching(_ dimensions: CGSize, tolerance: CGFloat = 0.5) -> PaperSize? {
        allCases.first { paperSize in
            abs(paperSize.dimensions.width - dimensions.width) <= tolerance
                && abs(paperSize.dimensions.height - dimensions.height) <= tolerance
        }
    }
}
