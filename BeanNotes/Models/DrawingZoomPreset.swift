//
//  DrawingZoomPreset.swift
//  BeanNotes
//

import CoreGraphics

enum DrawingZoomPreset: CaseIterable, Identifiable {
    case actualSize
    case detail
    case closeDetail

    var id: String { label }

    var scale: CGFloat {
        switch self {
        case .actualSize:
            1
        case .detail:
            2
        case .closeDetail:
            3
        }
    }

    var label: String {
        DrawingZoomLevel.percentageText(for: scale)
    }

    var accessibilityLabel: String {
        switch self {
        case .actualSize:
            "Set zoom to 100 percent"
        case .detail:
            "Set zoom to 200 percent"
        case .closeDetail:
            "Set zoom to 300 percent"
        }
    }

    var systemImage: String {
        switch self {
        case .actualSize:
            "magnifyingglass"
        case .detail:
            "plus.magnifyingglass"
        case .closeDetail:
            "scope"
        }
    }
}

enum DrawingZoomLevel {
    static let presetSelectionTolerance: CGFloat = 0.035

    static func percentageText(for scale: CGFloat) -> String {
        guard scale.isFinite, scale > 0 else { return "0%" }
        return "\(Int((scale * 100).rounded()))%"
    }

    static func clampedScale(_ scale: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        guard scale.isFinite, scale > 0 else { return minimum }
        return min(max(scale, minimum), maximum)
    }

    static func isScale(_ scale: CGFloat, closeTo target: CGFloat) -> Bool {
        abs(scale - target) <= presetSelectionTolerance
    }
}
