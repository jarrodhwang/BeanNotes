//
//  PaperSize.swift
//  BeanNotes
//

import Foundation

/// Page sizes, expressed in PostScript points (72 points per inch).
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
    case chalkboard
    case hd
    case fhd
    case fhdPlus
    case qhd
    case qhdPlus
    case fourK

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
        case .chalkboard: "Chalkboard"
        case .hd: "HD"
        case .fhd: "FHD"
        case .fhdPlus: "FHD+"
        case .qhd: "QHD"
        case .qhdPlus: "QHD+"
        case .fourK: "4K"
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
        case .chalkboard: "16:9 landscape"
        case .hd: "1280 × 720"
        case .fhd: "1920 × 1080"
        case .fhdPlus: "1920 × 1200"
        case .qhd: "2560 × 1440"
        case .qhdPlus: "3200 × 1800"
        case .fourK: "3840 × 2160"
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
        case .chalkboard: CGSize(width: 960, height: 540)
        case .hd: CGSize(width: 1_280, height: 720)
        case .fhd: CGSize(width: 1_920, height: 1_080)
        case .fhdPlus: CGSize(width: 1_920, height: 1_200)
        case .qhd: CGSize(width: 2_560, height: 1_440)
        case .qhdPlus: CGSize(width: 3_200, height: 1_800)
        case .fourK: CGSize(width: 3_840, height: 2_160)
        }
    }

    func fits(minimumSize: CGSize) -> Bool {
        dimensions.width >= minimumSize.width
            && dimensions.height >= minimumSize.height
    }

    static func matching(_ dimensions: CGSize, tolerance: CGFloat = 0.5) -> PaperSize? {
        allCases.first { paperSize in
            abs(paperSize.dimensions.width - dimensions.width) <= tolerance
                && abs(paperSize.dimensions.height - dimensions.height) <= tolerance
        }
    }
}

enum CustomPaperSize {
    static let selectionRawValue = "custom"
    static let widthStorageKey = "defaultCustomPaperWidth"
    static let heightStorageKey = "defaultCustomPaperHeight"
    static let defaultDimensions = PaperSize.defaultPaperSize.dimensions

    static func dimensions(width: Double, height: Double) -> CGSize {
        CGSize(
            width: NotePage.normalizedPageDimension(
                width,
                fallback: defaultDimensions.width
            ),
            height: NotePage.normalizedPageDimension(
                height,
                fallback: defaultDimensions.height
            )
        )
    }

    static func isValid(
        width: Double,
        height: Double,
        minimumSize: CGSize = CGSize(
            width: NotePage.minimumPageDimension,
            height: NotePage.minimumPageDimension
        )
    ) -> Bool {
        width.isFinite
            && height.isFinite
            && (NotePage.minimumPageDimension...NotePage.maximumPageDimension).contains(width)
            && (NotePage.minimumPageDimension...NotePage.maximumPageDimension).contains(height)
            && width >= minimumSize.width
            && height >= minimumSize.height
    }
}
