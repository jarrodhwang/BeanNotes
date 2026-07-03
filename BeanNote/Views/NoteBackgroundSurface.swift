//
//  NoteBackgroundSurface.swift
//  BeanNote
//

import SwiftUI

struct NoteBackgroundSurface: View {
    var background: NoteBackground

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .color(Color(hex: background.colorHex)))

            let lineColor = Color.secondary.opacity(0.24)

            switch background.style {
            case .plain:
                break
            case .grid:
                drawGrid(context: context, size: size, color: lineColor)
            case .dotted:
                drawDots(context: context, size: size, color: Color.secondary.opacity(0.36))
            case .lined:
                drawLines(context: context, size: size, color: lineColor)
            }
        }
        .accessibilityHidden(true)
    }

    private func drawGrid(context: GraphicsContext, size: CGSize, color: Color) {
        var path = Path()
        let spacing: CGFloat = 32

        stride(from: CGFloat.zero, through: size.width, by: spacing).forEach { x in
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }

        stride(from: CGFloat.zero, through: size.height, by: spacing).forEach { y in
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }

        context.stroke(path, with: .color(color), lineWidth: 1)
    }

    private func drawLines(context: GraphicsContext, size: CGSize, color: Color) {
        var path = Path()
        let spacing: CGFloat = 36

        stride(from: spacing, through: size.height, by: spacing).forEach { y in
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }

        context.stroke(path, with: .color(color), lineWidth: 1)
    }

    private func drawDots(context: GraphicsContext, size: CGSize, color: Color) {
        let spacing: CGFloat = 28
        let dot = CGSize(width: 2.6, height: 2.6)

        stride(from: spacing, through: size.width, by: spacing).forEach { x in
            stride(from: spacing, through: size.height, by: spacing).forEach { y in
                let rect = CGRect(
                    x: x - dot.width / 2,
                    y: y - dot.height / 2,
                    width: dot.width,
                    height: dot.height
                )
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
    }
}
