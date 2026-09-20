import Foundation
import simd

struct ChemicalStructureReference: Codable, Equatable, Sendable {
    var exampleID: String
    var originalGraph: ChemicalGraph

    /// Moving atoms or editing captions does not change chemistry. Every atom,
    /// charge and directed bond must still match before showing sourced coordinates.
    func matches(_ graph: ChemicalGraph) -> Bool {
        guard LocalChemicalToolkit.integrityErrors(in: graph).isEmpty,
              LocalChemicalToolkit.integrityErrors(in: originalGraph).isEmpty,
              graph.atoms.count == originalGraph.atoms.count,
              graph.bonds.count == originalGraph.bonds.count else { return false }
        let atoms = Dictionary(uniqueKeysWithValues: originalGraph.atoms.map { ($0.id, $0) })
        let bonds = Dictionary(uniqueKeysWithValues: originalGraph.bonds.map { ($0.id, $0) })
        return graph.atoms.allSatisfy { atoms[$0.id]?.element == $0.element && atoms[$0.id]?.formalCharge == $0.formalCharge }
            && graph.bonds.allSatisfy { bonds[$0.id] == $0 }
    }
}

extension ChemicalStructureDraft {
    var matchingExample: ChemicalExample? {
        guard let reference, reference.matches(graph) else { return nil }
        return ChemicalExampleLibrary.examples.first { $0.id == reference.exampleID && $0.matchesReferenceGraph(reference.originalGraph) }
    }
}

struct ChemicalExample: Decodable, Identifiable, Equatable, Sendable {
    struct Atom: Decodable, Identifiable, Equatable, Sendable {
        var id: Int
        var element: String
        var charge: Int
        var x2: Double
        var y2: Double
        var x: Float
        var y: Float
        var z: Float
        var position: SIMD3<Float> { [x, y, z] }
    }
    struct Bond: Decodable, Equatable, Sendable {
        var start: Int
        var end: Int
        var order: Int
    }
    var id: String
    var name: String
    var cid: Int
    var detail: String
    var formula: String
    var showHydrogensInDrawing: Bool
    var conformerID: String
    var retrieved: String
    var atoms: [Atom]
    var bonds: [Bond]
    var sourceURL: URL { URL(string: "https://pubchem.ncbi.nlm.nih.gov/compound/\(cid)#section=3D-Conformer")! }
    var formattedFormula: String { (try? MolecularFormulaParser.parse(formula).get().formatted) ?? formula }

    var isValid: Bool {
        let ids = Set(atoms.map(\.id))
        return !atoms.isEmpty && atoms.count <= ChemicalGraph.maximumAtomCount
            && bonds.count <= ChemicalGraph.maximumBondCount && ids.count == atoms.count
            && atoms.allSatisfy { MolecularFormulaParser.elements.contains($0.element) && $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite && simd_length($0.position) < 100 && $0.x2.isFinite && $0.y2.isFinite }
            && bonds.allSatisfy { ids.contains($0.start) && ids.contains($0.end) && $0.start != $0.end && (1...3).contains($0.order) }
    }

    func matchesReferenceGraph(_ graph: ChemicalGraph) -> Bool {
        let visible = atoms.filter { showHydrogensInDrawing || $0.element != "H" }
        guard visible.count == graph.atoms.count else { return false }
        let atomIDs = Set(visible.map(\.id))
        let expectedBonds = bonds.filter { atomIDs.contains($0.start) && atomIDs.contains($0.end) }
        guard expectedBonds.count == graph.bonds.count else { return false }
        let identifiers = Dictionary(uniqueKeysWithValues: zip(visible, graph.atoms).map { ($0.0.id, $0.1.id) })
        return zip(visible, graph.atoms).allSatisfy { $0.0.element == $0.1.element && $0.0.charge == $0.1.formalCharge }
            && zip(expectedBonds, graph.bonds).allSatisfy {
                identifiers[$0.0.start] == $0.1.startAtomID && identifiers[$0.0.end] == $0.1.endAtomID
                    && ($0.0.order == 2 ? ChemicalBondType.double : $0.0.order == 3 ? .triple : .single) == $0.1.type
            }
    }

    func makeDraft() -> ChemicalStructureDraft {
        let visible = atoms.filter { showHydrogensInDrawing || $0.element != "H" }
        let minX = visible.map(\.x2).min() ?? 0, maxX = visible.map(\.x2).max() ?? 0
        let minY = visible.map(\.y2).min() ?? 0, maxY = visible.map(\.y2).max() ?? 0
        let scale = 0.7 / max(maxX - minX, maxY - minY, 1)
        let ids = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, UUID()) })
        let graph = ChemicalGraph(atoms: visible.map {
            ChemicalAtom(id: ids[$0.id]!, element: $0.element, formalCharge: $0.charge,
                         x: 0.5 + ($0.x2 - (minX + maxX) / 2) * scale,
                         y: 0.5 - ($0.y2 - (minY + maxY) / 2) * scale)
        }, bonds: bonds.compactMap {
            guard let start = ids[$0.start], let end = ids[$0.end] else { return nil }
            return ChemicalBond(startAtomID: start, endAtomID: end, type: $0.order == 2 ? .double : $0.order == 3 ? .triple : .single)
        })
        return ChemicalStructureDraft(graph: graph, molecularFormula: formula, reference: .init(exampleID: id, originalGraph: graph))
    }
}

enum ChemicalExampleLibrary {
    static let examples: [ChemicalExample] = {
        guard let url = Bundle.main.url(forResource: "MoleculeExamples", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let examples = try? JSONDecoder().decode([ChemicalExample].self, from: data),
              Set(examples.map(\.id)).count == examples.count,
              examples.allSatisfy(\.isValid) else { return [] }
        return examples
    }()
}
