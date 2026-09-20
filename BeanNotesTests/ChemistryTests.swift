import Foundation
import Testing
import UIKit
@testable import BeanNotes

@Suite(.serialized)
@MainActor
struct ChemistryTests {
    private let toolkit = LocalChemicalToolkit()

    @Test(arguments: ["", "2", "H0", "H01", "C(2H)", "H()", "[H)", "H]", "Ca(OH2", "H·", "H··O", "H^", "H^0+", "H^2", "H^+-", "H+^2-", "H^2+O", "(H^+)", "H٢", "Xx2", "h2O", "Na^100+", "H2·03O"])
    func rejectsInvalidNotation(_ input: String) {
        if case .success(let result) = MolecularFormulaParser.parse(input) {
            Issue.record("Accepted invalid formula \(input): \(result)")
        }
    }

    @Test func countsNestedGroupsHydratesAndCoefficients() throws {
        let ferricyanide = try MolecularFormulaParser.parse("K3[Fe(CN)6]").get()
        #expect(ferricyanide.elementCounts == ["K": 3, "Fe": 1, "C": 6, "N": 6])
        #expect(ferricyanide.atomCount == 16)
        let hydrate = try MolecularFormulaParser.parse("CuSO4 · 5H2O").get()
        #expect(hydrate.elementCounts == ["Cu": 1, "S": 1, "O": 9, "H": 10])
        #expect(hydrate.formatted == "CuSO₄·5H₂O")
        #expect(try MolecularFormulaParser.parse("2(NH4)2SO4").get().elementCounts == ["N": 4, "H": 16, "S": 2, "O": 8])
    }

    @Test(arguments: ["SO4^2-", "[Fe(CN)6]^3-", "NH4+", "Fe^3+", "Ca(OH)2", "CuSO4·5H2O"])
    func formattedOutputCanBePastedBack(_ input: String) throws {
        let parsed = try MolecularFormulaParser.parse(input).get()
        let roundTrip = try MolecularFormulaParser.parse(parsed.formatted).get()
        #expect(parsed.formatted == roundTrip.formatted)
        #expect(parsed.elementCounts == roundTrip.elementCounts)
        #expect(parsed.charge == roundTrip.charge)
    }

    @Test func boundsWorkAndPreventIntegerOverflow() throws {
        #expect(try MolecularFormulaParser.parse("H1000000").get().atomCount == 1_000_000)
        for input in ["H1000001", "1000000H2", "H99999999999999999999999", String(repeating: "(", count: 17) + "H" + String(repeating: ")", count: 17), String(repeating: "H", count: 513)] {
            if case .success = MolecularFormulaParser.parse(input) { Issue.record("Accepted oversized input") }
        }
    }

    @Test func respectsElementCaseAndChargeMagnitude() throws {
        #expect(try MolecularFormulaParser.parse("Co").get().elementCounts == ["Co": 1])
        #expect(try MolecularFormulaParser.parse("CO").get().elementCounts == ["C": 1, "O": 1])
        #expect(try MolecularFormulaParser.parse("Fe^3+").get().charge == 3)
        #expect(try MolecularFormulaParser.parse("SO₄²⁻").get().charge == -2)
    }

    @Test func malformedGraphsReturnErrorsInsteadOfTrapping() async throws {
        let a = ChemicalAtom(x: 0.3, y: 0.5), b = ChemicalAtom(element: "O", x: 0.7, y: 0.5)
        let bond = ChemicalBond(startAtomID: a.id, endAtomID: b.id)
        let invalid = [
            ChemicalGraph(atoms: [a, a]),
            ChemicalGraph(atoms: [a], bonds: [bond]),
            ChemicalGraph(atoms: [a], bonds: [.init(startAtomID: a.id, endAtomID: a.id)]),
            ChemicalGraph(atoms: [a, b], bonds: [bond, .init(startAtomID: b.id, endAtomID: a.id)]),
            ChemicalGraph(atoms: [.init(element: "Xx", x: 0, y: 0)]),
            ChemicalGraph(atoms: [.init(x: .nan, y: 0)]),
            ChemicalGraph(atoms: [.init(x: 0, y: .infinity)]),
            ChemicalGraph(atoms: [.init(formalCharge: Int.min, x: 0, y: 0)]),
            ChemicalGraph(atoms: (0...ChemicalGraph.maximumAtomCount).map { _ in .init(x: 0, y: 0) })
        ]
        for graph in invalid {
            #expect(!LocalChemicalToolkit.integrityErrors(in: graph).isEmpty)
            #expect(!(await toolkit.validate(graph)).isEmpty)
            do { _ = try await toolkit.molBlock(for: graph); Issue.record("Exported invalid graph") } catch {}
            do { _ = try await toolkit.molecularFormula(for: graph); Issue.record("Calculated invalid graph") } catch {}
        }
    }

    @Test func computesHydrogensAndChargeConservatively() async throws {
        #expect(try await toolkit.molecularFormula(for: .init(atoms: [.init(element: "N", formalCharge: 1, x: 0.5, y: 0.5)])) == "H4N^+")
        #expect(try await toolkit.molecularFormula(for: .init(atoms: [.init(element: "O", formalCharge: -1, x: 0.5, y: 0.5)])) == "HO^-")
        #expect(try await toolkit.molecularFormula(for: .init(atoms: [.init(element: "Fe", x: 0, y: 0)])) == nil)
        let oxygen = [ChemicalAtom(element: "O", x: 0.3, y: 0.5), ChemicalAtom(element: "O", x: 0.7, y: 0.5)]
        let graph = ChemicalGraph(atoms: oxygen, bonds: [.init(startAtomID: oxygen[0].id, endAtomID: oxygen[1].id, type: .double)])
        #expect(try await toolkit.molecularFormula(for: graph) == "O2") // Never emit H0.
        var invalid = graph
        invalid.bonds[0].type = .triple
        #expect(try await toolkit.molecularFormula(for: invalid) == nil)
        #expect(!(await toolkit.validate(invalid)).isEmpty)
    }

    @Test func exportsFormalChargesAndDirectedStereoBonds() async throws {
        let a = ChemicalAtom(element: "N", formalCharge: 1, x: 0.25, y: 0.5)
        let b = ChemicalAtom(element: "O", formalCharge: -1, x: 0.75, y: 0.5)
        for (type, code) in [(ChemicalBondType.wedge, 1), (.dashed, 6)] {
            let graph = ChemicalGraph(atoms: [a, b], bonds: [.init(startAtomID: a.id, endAtomID: b.id, type: type)])
            let lines = try await toolkit.molBlock(for: graph).components(separatedBy: "\n")
            #expect(lines[6].split(separator: " ").prefix(4).map(String.init) == ["1", "2", "1", String(code)])
            #expect(lines.contains("M  CHG  2   1   1   2  -1"))
            #expect(lines[4].contains("2.5000"))
            #expect(String(lines[4].dropFirst(31).prefix(3)) == "N  ")
            #expect(String(lines[1].dropFirst(20).prefix(2)) == "2D")
        }
        let manyCharged = (0..<10).map { ChemicalAtom(element: "Na", formalCharge: 1, x: Double($0) / 10, y: 0.5) }
        let mol = try await toolkit.molBlock(for: .init(atoms: manyCharged))
        #expect(mol.components(separatedBy: "\n").filter { $0.hasPrefix("M  CHG") }.count == 2)
    }

    @Test func fittingDrawingPreservesShapeAndConnectivity() async throws {
        let atoms = [ChemicalAtom(x: 0.1, y: 0.2), ChemicalAtom(x: 0.2, y: 0.2), ChemicalAtom(x: 0.3, y: 0.4)]
        let graph = ChemicalGraph(atoms: atoms, bonds: [.init(startAtomID: atoms[0].id, endAtomID: atoms[1].id)])
        let fitted = try await toolkit.beautify(graph)
        #expect(fitted.bonds == graph.bonds)
        #expect(fitted.atoms.map(\.id) == graph.atoms.map(\.id))
        #expect(abs(fitted.atoms[0].y - fitted.atoms[1].y) < 0.00001)
        #expect(abs((fitted.atoms[2].x - fitted.atoms[0].x) / (fitted.atoms[1].x - fitted.atoms[0].x) - 2) < 0.00001)
        #expect(fitted.atoms.allSatisfy { (0.149...0.851).contains($0.x) && (0.149...0.851).contains($0.y) })
    }

    @Test func bundledExamplesMatchPublishedFormulasAndBondLengths() async throws {
        let examples = ChemicalExampleLibrary.examples
        #expect(examples.count == 8)
        for example in examples {
            #expect(example.isValid)
            let expected = try MolecularFormulaParser.parse(example.formula).get().elementCounts
            #expect(Dictionary(grouping: example.atoms, by: \.element).mapValues(\.count) == expected)
            let draft = example.makeDraft()
            #expect(await toolkit.validate(draft.graph).isEmpty)
            let calculated = try #require(await toolkit.molecularFormula(for: draft.graph))
            #expect(try MolecularFormulaParser.parse(calculated).get().elementCounts == expected)
            #expect(draft.matchingExample?.id == example.id)
            let atoms = Dictionary(uniqueKeysWithValues: example.atoms.map { ($0.id, $0) })
            for bond in example.bonds {
                let a = try #require(atoms[bond.start]), b = try #require(atoms[bond.end])
                let squaredLength = pow(a.x - b.x, 2) + pow(a.y - b.y, 2) + pow(a.z - b.z, 2)
                #expect((0.64...3.25).contains(squaredLength))
            }
        }
    }

    @Test func sourceLinkSurvivesLayoutButNotChemicalEdits() throws {
        var draft = try #require(ChemicalExampleLibrary.examples.first { $0.id == "ethanol" }).makeDraft()
        draft.graph.atoms[0].x += 0.1
        draft.graph.atoms[0].label = "Alcohol group"
        #expect(draft.matchingExample != nil)
        let unchanged = draft
        draft.graph.atoms[0].formalCharge += 1
        #expect(draft.matchingExample == nil)
        draft = unchanged
        draft.graph.bonds[0].type = .double
        #expect(draft.matchingExample == nil)
        draft = unchanged
        draft.reference?.exampleID = "water"
        #expect(draft.matchingExample == nil)
    }

    @Test func roundTripsSourceAndOpensLegacyPayloads() throws {
        let example = try #require(ChemicalExampleLibrary.examples.first)
        let data = try ChemicalSemanticPayload.encode(ChemicalStructurePayload(draft: example.makeDraft()))
        let decoded = try #require(ChemicalSemanticPayload.structure(from: data))
        #expect(decoded.draft.matchingExample?.id == example.id)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var legacyDraft = try #require(object["draft"] as? [String: Any])
        legacyDraft.removeValue(forKey: "reference")
        object["draft"] = legacyDraft
        let legacy = try #require(ChemicalSemanticPayload.structure(from: JSONSerialization.data(withJSONObject: object)))
        #expect(legacy.draft.reference == nil)
        #expect(legacy.draft.graph == decoded.draft.graph)
        object["schemaVersion"] = 99
        #expect(ChemicalSemanticPayload.structure(from: try JSONSerialization.data(withJSONObject: object)) == nil)
        #expect(ChemicalSemanticPayload.structure(from: Data(repeating: 32, count: 1_048_577)) == nil)
    }

    @Test @MainActor func drawsPreviewsAndToleratesCorruptGraph() throws {
        for example in ChemicalExampleLibrary.examples {
            let data = try #require(ChemistryPreviewRenderer.structurePNG(for: example.makeDraft()))
            #expect(UIImage(data: data)?.size.width == 840)
        }
        let a = ChemicalAtom(x: 0.5, y: 0.5)
        _ = ChemistryPreviewRenderer.structurePNG(for: .init(graph: .init(atoms: [a, a])))
        let formula = try MolecularFormulaParser.parse("[Fe(CN)6]^3-").get()
        #expect(ChemistryPreviewRenderer.formulaPNG(for: formula) != nil)
    }
}
