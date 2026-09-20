//
//  ChemistryService.swift
//  BeanNotes
//

import CoreGraphics
import Foundation
import UIKit

@MainActor
enum ChemistryPreviewRenderer {
    static let currentVersion = 2
    nonisolated static let defaultStructureSize = CGSize(width: 420, height: 300)
    nonisolated static let defaultFormulaSize = CGSize(width: 360, height: 140)
    private static let renderScale: CGFloat = 2

    static func structurePNG(for draft: ChemicalStructureDraft, size: CGSize = defaultStructureSize) -> Data? {
        guard LocalChemicalToolkit.integrityErrors(in: draft.graph).isEmpty else { return nil }
        let size = safeSize(size, fallback: defaultStructureSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = renderScale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            drawCard(in: context.cgContext, size: size, title: draft.matchingExample.map { "\($0.name) · \($0.formattedFormula)" } ?? "Chemical Structure")
            let rect = CGRect(x: 18, y: 42, width: size.width - 36, height: size.height - 58)
            draw(graph: draft.graph, in: rect, context: context.cgContext)
        }
        return image.pngData()
    }

    static func formulaPNG(for result: MolecularFormulaParseResult, size: CGSize = defaultFormulaSize) -> Data? {
        let size = safeSize(size, fallback: defaultFormulaSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = renderScale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            drawCard(in: context.cgContext, size: size, title: "Molecular Formula")
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byCharWrapping
            let textRect = CGRect(x: 12, y: 48, width: size.width - 24, height: size.height - 56)
            var fontSize = min(36, max(20, size.height * 0.25))
            while fontSize > 8 {
                let bounds = NSString(string: result.formatted).boundingRect(with: CGSize(width: textRect.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: UIFont.systemFont(ofSize: fontSize, weight: .medium), .paragraphStyle: paragraph], context: nil)
                if bounds.height <= textRect.height { break }
                fontSize -= 1
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraph
            ]
            NSString(string: result.formatted).draw(
                in: textRect,
                withAttributes: attributes
            )
        }
        return image.pngData()
    }

    static func drawingRect(in bounds: CGRect) -> CGRect {
        let edge = min(bounds.width, bounds.height)
        return CGRect(x: bounds.midX - edge / 2, y: bounds.midY - edge / 2, width: edge, height: edge)
    }

    static func draw(graph: ChemicalGraph, in bounds: CGRect, context: CGContext, showAtomLabels: Bool = false) {
        guard LocalChemicalToolkit.integrityErrors(in: graph).isEmpty else { return }
        let rect = drawingRect(in: bounds)
        let atoms = Dictionary(uniqueKeysWithValues: graph.atoms.map { ($0.id, $0) })
        context.saveGState()
        context.setStrokeColor(UIColor.label.cgColor)
        context.setLineCap(.round)
        context.setLineWidth(2)
        for bond in graph.bonds {
            guard let start = atoms[bond.startAtomID], let end = atoms[bond.endAtomID] else { continue }
            let a = CGPoint(x: rect.minX + CGFloat(start.x) * rect.width, y: rect.minY + CGFloat(start.y) * rect.height)
            let b = CGPoint(x: rect.minX + CGFloat(end.x) * rect.width, y: rect.minY + CGFloat(end.y) * rect.height)
            drawBond(from: a, to: b, type: bond.type, context: context)
        }
        let bonded = Set(graph.bonds.flatMap { [$0.startAtomID, $0.endAtomID] })
        let hydrogens = LocalChemicalToolkit().implicitHydrogenCounts(in: graph) ?? [:]
        for atom in graph.atoms where showAtomLabels || atom.element != "C" || !bonded.contains(atom.id) || atom.formalCharge != 0 || atom.label?.isEmpty == false {
            let point = CGPoint(x: rect.minX + CGFloat(atom.x) * rect.width, y: rect.minY + CGFloat(atom.y) * rect.height)
            let hydrogenCount = hydrogens[atom.id, default: 0]
            let hydrogen = hydrogenCount > 0 ? "H" + (hydrogenCount == 1 ? "" : String(hydrogenCount)) : ""
            let formula = atom.element + hydrogen + (atom.formalCharge == 0 ? "" : "^" + (abs(atom.formalCharge) == 1 ? "" : String(abs(atom.formalCharge))) + (atom.formalCharge > 0 ? "+" : "-"))
            let text = atom.label.flatMap { $0.isEmpty ? nil : String($0.prefix(32)) }
                ?? (try? MolecularFormulaParser.parse(formula).get().formatted) ?? atom.element
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: UIColor.label, .backgroundColor: UIColor.systemBackground]
            let measured = NSString(string: text).size(withAttributes: attributes)
            NSString(string: text).draw(at: CGPoint(x: point.x - measured.width / 2, y: point.y - measured.height / 2), withAttributes: attributes)
        }
        context.restoreGState()
    }

    private static func drawCard(in context: CGContext, size: CGSize, title: String) {
        let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1), cornerRadius: 12)
        UIColor.secondarySystemBackground.setFill()
        path.fill()
        UIColor.separator.setStroke()
        path.lineWidth = 1
        path.stroke()
        NSString(string: title).draw(at: CGPoint(x: 16, y: 13), withAttributes: [.font: UIFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: UIColor.secondaryLabel])
    }

    private static func drawBond(from a: CGPoint, to b: CGPoint, type: ChemicalBondType, context: CGContext) {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(hypot(dx, dy), 1)
        let offset = CGPoint(x: -dy / length * 3.5, y: dx / length * 3.5)
        func line(_ shift: CGFloat = 0) {
            context.move(to: CGPoint(x: a.x + offset.x * shift, y: a.y + offset.y * shift))
            context.addLine(to: CGPoint(x: b.x + offset.x * shift, y: b.y + offset.y * shift))
            context.strokePath()
        }
        switch type {
        case .single: line()
        case .double: line(-1); line(1)
        case .triple: line(-1.6); line(); line(1.6)
        case .aromatic:
            line(-1); context.saveGState(); context.setLineDash(phase: 0, lengths: [4, 4]); line(1); context.restoreGState()
        case .dashed:
            // Hashed wedge: narrow at the first atom, wide at the second.
            for index in 1...7 {
                let fraction = CGFloat(index) / 8
                let center = CGPoint(x: a.x + dx * fraction, y: a.y + dy * fraction)
                context.move(to: CGPoint(x: center.x - offset.x * fraction * 1.5, y: center.y - offset.y * fraction * 1.5))
                context.addLine(to: CGPoint(x: center.x + offset.x * fraction * 1.5, y: center.y + offset.y * fraction * 1.5))
                context.strokePath()
            }
        case .wedge:
            context.beginPath(); context.move(to: a); context.addLine(to: CGPoint(x: b.x + offset.x * 1.5, y: b.y + offset.y * 1.5)); context.addLine(to: CGPoint(x: b.x - offset.x * 1.5, y: b.y - offset.y * 1.5)); context.closePath(); context.setFillColor(UIColor.label.cgColor); context.fillPath()
        }
    }

    private static func safeSize(_ size: CGSize, fallback: CGSize) -> CGSize {
        CGSize(width: min(max(size.width.isFinite ? size.width : fallback.width, 180), 900), height: min(max(size.height.isFinite ? size.height : fallback.height, 100), 700))
    }
}
