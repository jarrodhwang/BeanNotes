//
//  DrawingZoomPreset.swift
//  BeanNotes
//

import CoreGraphics

enum DrawingZoomPreset: CaseIterable, Identifiable {
    case actualSize
    case detail
    case closeDetail
    case fineDetail
    case ultraFineDetail

    var id: String { label }

    var scale: CGFloat {
        switch self {
        case .actualSize:
            1
        case .detail:
            2
        case .closeDetail:
            3
        case .fineDetail:
            4
        case .ultraFineDetail:
            6
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
        case .fineDetail:
            "Set zoom to 400 percent"
        case .ultraFineDetail:
            "Set zoom to 600 percent"
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
        case .fineDetail:
            "viewfinder"
        case .ultraFineDetail:
            "scope"
        }
    }

    static func quickPresets(for renderQuality: DrawingRenderQuality) -> [DrawingZoomPreset] {
        allCases.filter { $0.scale <= renderQuality.maximumZoomScale }
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

    static func doubleTapTargetScale(
        current: CGFloat,
        fitScale: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        let boundedMinimum = max(minimum, 0.01)
        let boundedMaximum = max(maximum, boundedMinimum)
        let fit = clampedScale(fitScale, minimum: boundedMinimum, maximum: boundedMaximum)
        let detail = clampedScale(max(2, fit * 2.2), minimum: boundedMinimum, maximum: boundedMaximum)

        guard detail > fit + 0.001 else { return fit }

        let currentScale = current.isFinite && current > 0 ? current : fit
        let midpoint = fit + (detail - fit) * 0.5
        return currentScale >= midpoint ? fit : detail
    }

    static func isScale(_ scale: CGFloat, closeTo target: CGFloat) -> Bool {
        abs(scale - target) <= presetSelectionTolerance
    }
}
