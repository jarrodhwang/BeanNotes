import Foundation

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


/// Deliberately limited, local bond accounting. No conformer generation, aromaticity
/// perception, stability prediction or canonical SMILES is implied by these checks.
struct LocalChemicalToolkit: ChemicalToolkit {
    static func integrityErrors(in graph: ChemicalGraph) -> [String] {
        guard graph.atoms.count <= ChemicalGraph.maximumAtomCount,
              graph.bonds.count <= ChemicalGraph.maximumBondCount else {
            return [ChemistryServiceError.graphTooLarge.localizedDescription]
        }
        var errors: [String] = []
        let ids = Set(graph.atoms.map(\.id))
        if ids.count != graph.atoms.count { errors.append("Two atoms have the same identifier.") }
        if Set(graph.bonds.map(\.id)).count != graph.bonds.count { errors.append("Two bonds have the same identifier.") }
        if graph.atoms.contains(where: { !$0.x.isFinite || !$0.y.isFinite || abs($0.x) > 100 || abs($0.y) > 100 }) {
            errors.append("An atom has invalid drawing coordinates.")
        }
        if graph.atoms.contains(where: { !MolecularFormulaParser.elements.contains($0.element) || !(-15...15).contains($0.formalCharge) }) {
            errors.append("An atom has an unsupported element symbol or charge.")
        }
        if graph.bonds.contains(where: { !ids.contains($0.startAtomID) || !ids.contains($0.endAtomID) }) {
            errors.append("A bond points to a missing atom.")
        }
        if graph.bonds.contains(where: { $0.startAtomID == $0.endAtomID }) { errors.append("An atom cannot bond to itself.") }
        var pairs = Set<Set<UUID>>()
        if graph.bonds.contains(where: { !pairs.insert([$0.startAtomID, $0.endAtomID]).inserted }) {
            errors.append("Two atoms have duplicate bonds. Change the bond type instead.")
        }
        return errors
    }

    func validate(_ graph: ChemicalGraph) async -> [String] {
        let errors = Self.integrityErrors(in: graph)
        guard errors.isEmpty else { return errors }
        guard !graph.atoms.isEmpty else { return ["Add an atom or choose an example to start."] }
        var warnings: [String] = []
        if connectedComponentCount(graph) > 1 { warnings.append("The structure contains disconnected components. Check whether they belong together.") }
        let totals = bondOrderTotals(in: graph)
        for (index, atom) in graph.atoms.enumerated() {
            guard let valences = allowedValences(for: atom) else {
                warnings.append("Atom \(index + 1) (\(atom.element)): hydrogen count is not supported for this element or charge.")
                continue
            }
            if totals[atom.id, default: 0] > Double(valences.max() ?? 0) + 0.01 {
                warnings.append("Atom \(index + 1) (\(atom.element)) has too many bonds for its charge. Check the bonds or formal charge.")
            }
        }
        if graph.bonds.contains(where: { $0.type == .aromatic }),
           !supportsAromaticAccounting(graph) {
            warnings.append("Aromatic hydrogen counts need more information. Use alternating single and double bonds for a formula estimate.")
        }
        return warnings
    }

    func molBlock(for graph: ChemicalGraph) async throws -> String {
        try check(graph)
        guard !graph.atoms.isEmpty else { throw ChemistryServiceError.invalidGraph }
        let locale = Locale(identifier: "en_US_POSIX")
        func format(_ pattern: String, _ values: CVarArg...) -> String { String(format: pattern, locale: locale, arguments: values) }
        var lines = ["BeanNotes", "  BeanNote          2D", "", format("%3d%3d  0  0  0  0            999 V2000", graph.atoms.count, graph.bonds.count)]
        for atom in graph.atoms {
            // NSString's %@ ignores printf field width on some Foundation versions.
            // Pad the element explicitly to preserve V2000's fixed columns 32–34.
            let symbol = atom.element.padding(toLength: 3, withPad: " ", startingAt: 0)
            lines.append(format("%10.4f%10.4f%10.4f ", atom.x * 10, -atom.y * 10, 0.0) + symbol + " 0  0  0  0  0  0  0  0  0  0  0  0")
        }
        let indices = Dictionary(uniqueKeysWithValues: graph.atoms.enumerated().map { ($0.element.id, $0.offset + 1) })
        for bond in graph.bonds {
            guard let start = indices[bond.startAtomID], let end = indices[bond.endAtomID] else { throw ChemistryServiceError.invalidGraph }
            let order: Int = switch bond.type { case .single, .wedge, .dashed: 1; case .double: 2; case .triple: 3; case .aromatic: 4 }
            // V2000: the pointed end is the first atom; 1 = up, 6 = down.
            let stereo = bond.type == .wedge ? 1 : bond.type == .dashed ? 6 : 0
            lines.append(format("%3d%3d%3d%3d  0  0  0", start, end, order, stereo))
        }
        let charged = graph.atoms.enumerated().filter { $0.element.formalCharge != 0 }
        for start in stride(from: 0, to: charged.count, by: 8) {
            let chunk = charged[start..<min(start + 8, charged.count)]
            lines.append(format("M  CHG%3d", chunk.count) + chunk.map { format("%4d%4d", $0.offset + 1, $0.element.formalCharge) }.joined())
        }
        lines.append("M  END")
        return lines.joined(separator: "\n") + "\n"
    }

    func canonicalSMILES(for graph: ChemicalGraph) async throws -> String? { try check(graph); return nil }

    func molecularFormula(for graph: ChemicalGraph) async throws -> String? {
        try check(graph)
        guard !graph.atoms.isEmpty, let hydrogens = implicitHydrogenCounts(in: graph) else { return nil }
        var counts = Dictionary(grouping: graph.atoms, by: \.element).mapValues(\.count)
        counts["H", default: 0] += hydrogens.values.reduce(0, +)
        counts = counts.filter { $0.value > 0 }
        // Hill order: carbon then hydrogen for carbon-containing formulas;
        // otherwise all symbols alphabetically (e.g. H2O, ClNa).
        let order = counts["C"] != nil
            ? ["C", "H"] + counts.keys.filter { $0 != "C" && $0 != "H" }.sorted()
            : counts.keys.sorted()
        var formula = order.compactMap { element -> String? in
            guard let count = counts[element] else { return nil }
            return element + (count == 1 ? "" : String(count))
        }.joined()
        let charge = graph.atoms.reduce(0) { $0 + $1.formalCharge }
        if charge != 0 { formula += "^" + (abs(charge) == 1 ? "" : String(abs(charge))) + (charge > 0 ? "+" : "-") }
        return formula
    }

    func implicitHydrogenCounts(in graph: ChemicalGraph) -> [UUID: Int]? {
        guard Self.integrityErrors(in: graph).isEmpty, supportsAromaticAccounting(graph) else { return nil }
        let totals = bondOrderTotals(in: graph)
        var hydrogens: [UUID: Int] = [:]
        for atom in graph.atoms {
            let order = totals[atom.id, default: 0]
            guard let valences = allowedValences(for: atom),
                  let valence = valences.first(where: { Double($0) >= order }),
                  abs(order.rounded() - order) < 0.01 else { return nil }
            hydrogens[atom.id] = atom.element == "H" ? 0 : valence - Int(order)
        }
        return hydrogens
    }

    /// Reframe the existing drawing without changing connectivity, relative positions,
    /// stereobond direction or turning chains into rings.
    func beautify(_ graph: ChemicalGraph) async throws -> ChemicalGraph {
        try check(graph)
        guard let first = graph.atoms.first else { return graph }
        let minX = graph.atoms.map(\.x).min() ?? first.x, maxX = graph.atoms.map(\.x).max() ?? first.x
        let minY = graph.atoms.map(\.y).min() ?? first.y, maxY = graph.atoms.map(\.y).max() ?? first.y
        let extent = max(maxX - minX, maxY - minY)
        let scale = extent > 0.0001 ? 0.7 / extent : 1
        var result = graph
        for index in result.atoms.indices {
            result.atoms[index].x = 0.5 + (result.atoms[index].x - (minX + maxX) / 2) * scale
            result.atoms[index].y = 0.5 + (result.atoms[index].y - (minY + maxY) / 2) * scale
        }
        return result
    }

    private func check(_ graph: ChemicalGraph) throws {
        guard graph.atoms.count <= ChemicalGraph.maximumAtomCount, graph.bonds.count <= ChemicalGraph.maximumBondCount else { throw ChemistryServiceError.graphTooLarge }
        guard Self.integrityErrors(in: graph).isEmpty else { throw ChemistryServiceError.invalidGraph }
    }

    private func allowedValences(for atom: ChemicalAtom) -> [Int]? {
        switch (atom.element, atom.formalCharge) {
        case ("H", 0): [1]
        case ("H", -1), ("H", 1): [0]
        case ("C", 0), ("Si", 0): [4]
        case ("C", -1), ("C", 1): [3]
        case ("B", 0): [3]
        case ("B", -1): [4]
        case ("N", 0): [3]
        case ("N", 1): [4]
        case ("N", -1): [2]
        case ("O", 0): [2]
        case ("O", -1): [1]
        case ("O", 1): [3]
        case ("P", 0): [3, 5]
        case ("S", 0): [2, 4, 6]
        case ("F", 0), ("Cl", 0), ("Br", 0), ("I", 0): [1]
        case ("F", -1), ("Cl", -1), ("Br", -1), ("I", -1), ("Na", 1), ("K", 1), ("Mg", 2), ("Ca", 2): [0]
        default: nil
        }
    }

    private func supportsAromaticAccounting(_ graph: ChemicalGraph) -> Bool {
        let aromatic = graph.bonds.filter { $0.type == .aromatic }
        guard !aromatic.isEmpty else { return true }
        let ids = Set(aromatic.flatMap { [$0.startAtomID, $0.endAtomID] })
        return graph.atoms.filter { ids.contains($0.id) }.allSatisfy { atom in
            atom.element == "C" && atom.formalCharge == 0 && aromatic.filter { $0.startAtomID == atom.id || $0.endAtomID == atom.id }.count == 2
        }
    }

    private func bondOrderTotals(in graph: ChemicalGraph) -> [UUID: Double] {
        var totals: [UUID: Double] = [:]
        for bond in graph.bonds {
            let order: Double = switch bond.type { case .single, .wedge, .dashed: 1; case .double: 2; case .triple: 3; case .aromatic: 1.5 }
            totals[bond.startAtomID, default: 0] += order
            totals[bond.endAtomID, default: 0] += order
        }
        return totals
    }

    private func connectedComponentCount(_ graph: ChemicalGraph) -> Int {
        var adjacency: [UUID: [UUID]] = [:]
        for bond in graph.bonds {
            adjacency[bond.startAtomID, default: []].append(bond.endAtomID)
            adjacency[bond.endAtomID, default: []].append(bond.startAtomID)
        }
        var unseen = Set(graph.atoms.map(\.id)), count = 0
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
}
