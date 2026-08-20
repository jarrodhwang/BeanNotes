//
//  ChemistryService.swift
//  BeanNotes
//

import CoreGraphics
import Foundation
import UIKit

enum ChemistryServiceError: LocalizedError {
    case graphTooLarge
    case invalidGraph

    var errorDescription: String? {
        switch self {
        case .graphTooLarge: "The structure is too large to process safely."
        case .invalidGraph: "The structure contains an invalid atom or bond reference."
        }
    }
}

/// Safe local fallback used by the smart editor. The protocol boundary is also
/// the integration point for the qualified, minimal RDKit XCFramework.
struct LocalChemicalToolkit: ChemicalToolkit {
    func validate(_ graph: ChemicalGraph) async -> [String] {
        guard graph.atoms.count <= ChemicalGraph.maximumAtomCount,
              graph.bonds.count <= ChemicalGraph.maximumBondCount else {
            return [ChemistryServiceError.graphTooLarge.localizedDescription]
        }
        let atomIDs = Set(graph.atoms.map(\.id))
        var warnings: [String] = []
        if graph.atoms.isEmpty { warnings.append("Add at least one atom.") }
        if graph.bonds.contains(where: { !atomIDs.contains($0.startAtomID) || !atomIDs.contains($0.endAtomID) }) {
            warnings.append("A bond points to a missing atom.")
        }
        if graph.bonds.contains(where: { $0.startAtomID == $0.endAtomID }) {
            warnings.append("An atom cannot bond to itself.")
        }
        if graph.atoms.count > 1, connectedComponentCount(graph) > 1 {
            warnings.append("The structure contains disconnected components.")
        }
        let bondOrders = bondOrderTotals(in: graph)
        for atom in graph.atoms {
            guard let valence = typicalValence(for: atom) else { continue }
            if bondOrders[atom.id, default: 0] > valence + 0.01 {
                warnings.append("\(atom.element) has more bonds than its usual valence allows.")
            }
        }
        return warnings
    }

    func molBlock(for graph: ChemicalGraph) async throws -> String {
        try checkSizeAndReferences(graph)
        var lines = ["BeanNotes", "  BeanNotes  2D", "", String(format: "%3d%3d  0  0  0  0            999 V2000", graph.atoms.count, graph.bonds.count)]
        for atom in graph.atoms {
            lines.append(String(format: "%10.4f%10.4f%10.4f %-3@ 0  0  0  0  0  0  0  0  0  0  0  0", atom.x, -atom.y, 0.0, atom.element as NSString))
        }
        let indices = Dictionary(uniqueKeysWithValues: graph.atoms.enumerated().map { ($0.element.id, $0.offset + 1) })
        for bond in graph.bonds {
            guard let start = indices[bond.startAtomID], let end = indices[bond.endAtomID] else { throw ChemistryServiceError.invalidGraph }
            let order: Int = switch bond.type { case .single, .wedge, .dashed: 1; case .double: 2; case .triple: 3; case .aromatic: 4 }
            lines.append(String(format: "%3d%3d%3d  0  0  0  0", start, end, order))
        }
        lines.append("M  END")
        return lines.joined(separator: "\n")
    }

    func canonicalSMILES(for graph: ChemicalGraph) async throws -> String? {
        try checkSizeAndReferences(graph)
        return nil // Supplied by the qualified RDKit adapter.
    }

    func molecularFormula(for graph: ChemicalGraph) async throws -> String? {
        try checkSizeAndReferences(graph)
        guard !graph.atoms.isEmpty else { return nil }
        var counts = Dictionary(grouping: graph.atoms, by: \.element).mapValues(\.count)
        let bondOrders = bondOrderTotals(in: graph)
        for atom in graph.atoms where atom.element != "H" {
            guard let valence = typicalValence(for: atom) else { continue }
            let remaining = max(0, valence - bondOrders[atom.id, default: 0])
            counts["H", default: 0] += Int(remaining.rounded())
        }
        let order = ["C", "H"] + counts.keys.filter { $0 != "C" && $0 != "H" }.sorted()
        return order.compactMap { element in
            guard let count = counts[element] else { return nil }
            return element + (count == 1 ? "" : String(count))
        }.joined()
    }

    func beautify(_ graph: ChemicalGraph) async throws -> ChemicalGraph {
        try checkSizeAndReferences(graph)
        guard graph.atoms.count > 2 else { return graph }
        var result = graph
        let centerX = graph.atoms.map(\.x).reduce(0, +) / Double(graph.atoms.count)
        let centerY = graph.atoms.map(\.y).reduce(0, +) / Double(graph.atoms.count)
        let radius = min(0.38, max(0.18, Double(graph.atoms.count) * 0.035))
        for index in result.atoms.indices {
            let angle = Double(index) / Double(result.atoms.count) * .pi * 2 - .pi / 2
            result.atoms[index].x = centerX + cos(angle) * radius
            result.atoms[index].y = centerY + sin(angle) * radius
        }
        return result
    }

    private func checkSizeAndReferences(_ graph: ChemicalGraph) throws {
        guard graph.atoms.count <= ChemicalGraph.maximumAtomCount,
              graph.bonds.count <= ChemicalGraph.maximumBondCount else { throw ChemistryServiceError.graphTooLarge }
        let ids = Set(graph.atoms.map(\.id))
        guard graph.bonds.allSatisfy({ ids.contains($0.startAtomID) && ids.contains($0.endAtomID) && $0.startAtomID != $0.endAtomID }) else {
            throw ChemistryServiceError.invalidGraph
        }
    }

    private func connectedComponentCount(_ graph: ChemicalGraph) -> Int {
        var adjacency: [UUID: Set<UUID>] = [:]
        graph.atoms.forEach { adjacency[$0.id] = [] }
        graph.bonds.forEach {
            adjacency[$0.startAtomID, default: []].insert($0.endAtomID)
            adjacency[$0.endAtomID, default: []].insert($0.startAtomID)
        }
        var unseen = Set(graph.atoms.map(\.id))
        var count = 0
        while let first = unseen.first {
            count += 1
            var stack = [first]
            unseen.remove(first)
            while let current = stack.popLast() {
                for neighbor in adjacency[current, default: []] where unseen.remove(neighbor) != nil { stack.append(neighbor) }
            }
        }
        return count
    }

    private func bondOrderTotals(in graph: ChemicalGraph) -> [UUID: Double] {
        var totals: [UUID: Double] = [:]
        for bond in graph.bonds {
            let order: Double = switch bond.type {
            case .single, .wedge, .dashed: 1
            case .double: 2
            case .triple: 3
            case .aromatic: 1.5
            }
            totals[bond.startAtomID, default: 0] += order
            totals[bond.endAtomID, default: 0] += order
        }
        return totals
    }

    /// Conservative fallback rules for common undergraduate organic and
    /// biochemistry atoms. RDKit remains authoritative once its adapter ships.
    private func typicalValence(for atom: ChemicalAtom) -> Double? {
        switch atom.element {
        case "C": 4
        case "N": atom.formalCharge > 0 ? 4 : 3
        case "O": atom.formalCharge < 0 ? 1 : 2
        case "P": 3
        case "S": 2
        case "F", "Cl", "Br", "I": 1
        default: nil
        }
    }
}

@MainActor
enum ChemistryPreviewRenderer {
    static let currentVersion = 1
    nonisolated static let defaultStructureSize = CGSize(width: 420, height: 300)
    nonisolated static let defaultFormulaSize = CGSize(width: 360, height: 140)
    private static let renderScale: CGFloat = 2

    static func structurePNG(for draft: ChemicalStructureDraft, size: CGSize = defaultStructureSize) -> Data? {
        let size = safeSize(size, fallback: defaultStructureSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = renderScale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            drawCard(in: context.cgContext, size: size, title: "Chemical Structure")
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
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: min(36, max(20, size.height * 0.25)), weight: .medium),
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraph
            ]
            NSString(string: result.formatted).draw(
                in: CGRect(x: 12, y: 52, width: size.width - 24, height: size.height - 60),
                withAttributes: attributes
            )
        }
        return image.pngData()
    }

    static func draw(graph: ChemicalGraph, in rect: CGRect, context: CGContext) {
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
        for atom in graph.atoms where atom.element != "C" || graph.atoms.count == 1 {
            let point = CGPoint(x: rect.minX + CGFloat(atom.x) * rect.width, y: rect.minY + CGFloat(atom.y) * rect.height)
            let charge = atom.formalCharge == 0 ? "" : atom.formalCharge > 0 ? "+\(atom.formalCharge == 1 ? "" : atom.formalCharge.description)" : "−\(abs(atom.formalCharge) == 1 ? "" : abs(atom.formalCharge).description)"
            let visibleLabel = atom.label.flatMap { $0.isEmpty ? nil : $0 } ?? atom.element
            let text = visibleLabel + charge
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
            context.saveGState(); context.setLineDash(phase: 0, lengths: [4, 4]); line(); context.restoreGState()
        case .wedge:
            context.beginPath(); context.move(to: a); context.addLine(to: CGPoint(x: b.x + offset.x * 1.5, y: b.y + offset.y * 1.5)); context.addLine(to: CGPoint(x: b.x - offset.x * 1.5, y: b.y - offset.y * 1.5)); context.closePath(); context.setFillColor(UIColor.label.cgColor); context.fillPath()
        }
    }

    private static func safeSize(_ size: CGSize, fallback: CGSize) -> CGSize {
        CGSize(width: min(max(size.width.isFinite ? size.width : fallback.width, 180), 900), height: min(max(size.height.isFinite ? size.height : fallback.height, 100), 700))
    }
}
