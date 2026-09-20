//
//  ChemistryConfiguration.swift
//  BeanNotes
//

import CoreGraphics
import Foundation

enum ChemicalBondType: String, CaseIterable, Codable, Identifiable, Sendable {
    case single, double, triple, aromatic, wedge, dashed
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct ChemicalAtom: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var element: String = "C"
    var formalCharge = 0
    var label: String?
    var x: Double
    var y: Double
}

struct ChemicalBond: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var startAtomID: UUID
    var endAtomID: UUID
    var type: ChemicalBondType = .single
}

struct ChemicalGraph: Codable, Equatable, Sendable {
    static let maximumAtomCount = 256
    static let maximumBondCount = 512

    var atoms: [ChemicalAtom] = []
    var bonds: [ChemicalBond] = []
}

struct ChemicalStructureDraft: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var graph = ChemicalGraph()
    var molBlock: String?
    var canonicalSMILES: String?
    var molecularFormula: String?
    var validationWarnings: [String] = []
    var reference: ChemicalStructureReference?
}

struct ChemicalStructurePayload: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion = currentSchemaVersion
    var draft: ChemicalStructureDraft
}

struct MolecularFormulaDraft: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var sourceText = ""
    var normalizedFormula = ""
    var recognitionConfidence: Double?
}

struct MolecularFormulaPayload: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion = currentSchemaVersion
    var draft: MolecularFormulaDraft
}

protocol ChemicalToolkit: Sendable {
    func validate(_ graph: ChemicalGraph) async -> [String]
    func molBlock(for graph: ChemicalGraph) async throws -> String
    func canonicalSMILES(for graph: ChemicalGraph) async throws -> String?
    func molecularFormula(for graph: ChemicalGraph) async throws -> String?
    func beautify(_ graph: ChemicalGraph) async throws -> ChemicalGraph
}

struct ChemicalRecognitionCandidate: Identifiable, Equatable, Sendable {
    var id = UUID()
    var graph: ChemicalGraph
    var confidence: Double
    var warnings: [String]
}

protocol ChemicalStructureRecognizer: Sendable {
    func recognize(imageData: Data) async throws -> [ChemicalRecognitionCandidate]
}

enum ChemicalSemanticPayload {
    private static let maximumPayloadSize = 1_048_576
    static func encode(_ payload: ChemicalStructurePayload) throws -> Data { try JSONEncoder().encode(payload) }
    static func encode(_ payload: MolecularFormulaPayload) throws -> Data { try JSONEncoder().encode(payload) }
    static func structure(from data: Data?) -> ChemicalStructurePayload? {
        guard let data, data.count <= maximumPayloadSize,
              let payload = try? JSONDecoder().decode(ChemicalStructurePayload.self, from: data),
              payload.schemaVersion == ChemicalStructurePayload.currentSchemaVersion else { return nil }
        return payload
    }
    static func formula(from data: Data?) -> MolecularFormulaPayload? {
        guard let data, data.count <= maximumPayloadSize,
              let payload = try? JSONDecoder().decode(MolecularFormulaPayload.self, from: data),
              payload.schemaVersion == MolecularFormulaPayload.currentSchemaVersion else { return nil }
        return payload
    }
}
