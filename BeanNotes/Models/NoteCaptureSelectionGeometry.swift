//
//  NoteCaptureSelectionGeometry.swift
//  BeanNotes
//

import CoreGraphics

enum NoteCaptureResizeHandle: CaseIterable, Hashable {
    case topLeft
    case topRight
    case bottomRight
    case bottomLeft
}

enum NoteCaptureSelectionGeometry {
    static let minimumWidth: CGFloat = 120
    static let minimumHeight: CGFloat = 90

    static func initialFrame(in bounds: CGRect) -> CGRect {
        let bounds = normalizedBounds(bounds)
        let width = min(max(bounds.width * 0.58, min(minimumWidth, bounds.width)), bounds.width)
        let height = min(max(bounds.height * 0.34, min(minimumHeight, bounds.height)), bounds.height)
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }

    static func movedFrame(
        from startFrame: CGRect,
        translation: CGPoint,
        in bounds: CGRect
    ) -> CGRect {
        let bounds = normalizedBounds(bounds)
        let frame = normalizedFrame(startFrame, in: bounds)
        let dx = translation.x.isFinite ? translation.x : 0
        let dy = translation.y.isFinite ? translation.y : 0
        return CGRect(
            x: min(max(frame.minX + dx, bounds.minX), bounds.maxX - frame.width),
            y: min(max(frame.minY + dy, bounds.minY), bounds.maxY - frame.height),
            width: frame.width,
            height: frame.height
        )
    }

    static func resizedFrame(
        from startFrame: CGRect,
        translation: CGPoint,
        handle: NoteCaptureResizeHandle,
        in bounds: CGRect
    ) -> CGRect {
        let bounds = normalizedBounds(bounds)
        let frame = normalizedFrame(startFrame, in: bounds)
        let dx = translation.x.isFinite ? translation.x : 0
        let dy = translation.y.isFinite ? translation.y : 0
        let minimumWidth = min(Self.minimumWidth, bounds.width)
        let minimumHeight = min(Self.minimumHeight, bounds.height)

        var minX = frame.minX
        var maxX = frame.maxX
        var minY = frame.minY
        var maxY = frame.maxY

        switch handle {
        case .topLeft:
            minX = min(max(frame.minX + dx, bounds.minX), frame.maxX - minimumWidth)
            minY = min(max(frame.minY + dy, bounds.minY), frame.maxY - minimumHeight)
        case .topRight:
            maxX = max(min(frame.maxX + dx, bounds.maxX), frame.minX + minimumWidth)
            minY = min(max(frame.minY + dy, bounds.minY), frame.maxY - minimumHeight)
        case .bottomRight:
            maxX = max(min(frame.maxX + dx, bounds.maxX), frame.minX + minimumWidth)
            maxY = max(min(frame.maxY + dy, bounds.maxY), frame.minY + minimumHeight)
        case .bottomLeft:
            minX = min(max(frame.minX + dx, bounds.minX), frame.maxX - minimumWidth)
            maxY = max(min(frame.maxY + dy, bounds.maxY), frame.minY + minimumHeight)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func normalizedFrame(_ frame: CGRect, in bounds: CGRect) -> CGRect {
        guard frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0 else {
            return initialFrame(in: bounds)
        }

        let width = min(max(frame.width, min(minimumWidth, bounds.width)), bounds.width)
        let height = min(max(frame.height, min(minimumHeight, bounds.height)), bounds.height)
        return CGRect(
            x: min(max(frame.minX, bounds.minX), bounds.maxX - width),
            y: min(max(frame.minY, bounds.minY), bounds.maxY - height),
            width: width,
            height: height
        )
    }

    private static func normalizedBounds(_ bounds: CGRect) -> CGRect {
        guard bounds.origin.x.isFinite,
              bounds.origin.y.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width > 0,
              bounds.height > 0 else {
            return CGRect(x: 0, y: 0, width: minimumWidth, height: minimumHeight)
        }
        return bounds.standardized
    }
}
