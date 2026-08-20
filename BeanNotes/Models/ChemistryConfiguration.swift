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

struct MolecularFormulaParseResult: Equatable, Sendable {
    var normalized: String
    var formatted: String
}

struct MolecularFormulaParseError: LocalizedError, Equatable, Sendable {
    var position: Int
    var message: String
    var errorDescription: String? { message }
}

enum MolecularFormulaParser {
    static let maximumInputLength = 512

    private static let elements: Set<String> = [
        "H", "He", "Li", "Be", "B", "C", "N", "O", "F", "Ne", "Na", "Mg", "Al", "Si", "P", "S", "Cl", "Ar",
        "K", "Ca", "Sc", "Ti", "V", "Cr", "Mn", "Fe", "Co", "Ni", "Cu", "Zn", "Ga", "Ge", "As", "Se", "Br", "Kr",
        "Rb", "Sr", "Y", "Zr", "Nb", "Mo", "Tc", "Ru", "Rh", "Pd", "Ag", "Cd", "In", "Sn", "Sb", "Te", "I", "Xe",
        "Cs", "Ba", "La", "Ce", "Pr", "Nd", "Pm", "Sm", "Eu", "Gd", "Tb", "Dy", "Ho", "Er", "Tm", "Yb", "Lu",
        "Hf", "Ta", "W", "Re", "Os", "Ir", "Pt", "Au", "Hg", "Tl", "Pb", "Bi", "Po", "At", "Rn", "Fr", "Ra",
        "Ac", "Th", "Pa", "U", "Np", "Pu", "Am", "Cm", "Bk", "Cf", "Es", "Fm", "Md", "No", "Lr", "Rf", "Db",
        "Sg", "Bh", "Hs", "Mt", "Ds", "Rg", "Cn", "Nh", "Fl", "Mc", "Lv", "Ts", "Og"
    ]
    private static let subscriptMap: [Character: Character] = ["₀":"0", "₁":"1", "₂":"2", "₃":"3", "₄":"4", "₅":"5", "₆":"6", "₇":"7", "₈":"8", "₉":"9"]
    private static let subscriptOutput = Array("₀₁₂₃₄₅₆₇₈₉")
    private static let superscriptOutput: [Character: Character] = ["0":"⁰", "1":"¹", "2":"²", "3":"³", "4":"⁴", "5":"⁵", "6":"⁶", "7":"⁷", "8":"⁸", "9":"⁹", "+":"⁺", "-":"⁻"]

    static func parse(_ raw: String) -> Result<MolecularFormulaParseResult, MolecularFormulaParseError> {
        guard raw.utf16.count <= maximumInputLength else {
            return .failure(.init(position: maximumInputLength, message: "Formula is limited to \(maximumInputLength) characters."))
        }
        let cleaned = raw
            .filter { !$0.isWhitespace }
            .map { subscriptMap[$0] ?? ($0 == "·" ? "·" : $0) }
        guard !cleaned.isEmpty else {
            return .failure(.init(position: 0, message: "Enter a molecular formula."))
        }

        var index = 0
        var depth = 0
        var normalized = ""
        var formatted = ""
        var expectsTerm = true
        var inCharge = false

        func fail(_ message: String) -> Result<MolecularFormulaParseResult, MolecularFormulaParseError> {
            .failure(.init(position: index, message: message))
        }

        while index < cleaned.count {
            let character = cleaned[index]
            if character == "^" {
                guard !expectsTerm, !inCharge else { return fail("Charge marker is misplaced.") }
                inCharge = true
                normalized.append(character)
                index += 1
                continue
            }
            if inCharge {
                guard character.isNumber || character == "+" || character == "-" else {
                    return fail("Charge must contain a number and + or -.")
                }
                normalized.append(character)
                formatted.append(superscriptOutput[character] ?? character)
                index += 1
                continue
            }
            if character == "(" {
                depth += 1
                expectsTerm = true
                normalized.append(character)
                formatted.append(character)
                index += 1
                continue
            }
            if character == ")" {
                guard depth > 0, !expectsTerm else { return fail("Unmatched closing parenthesis.") }
                depth -= 1
                expectsTerm = false
                normalized.append(character)
                formatted.append(character)
                index += 1
                continue
            }
            if character == "." || character == "·" {
                guard depth == 0, !expectsTerm else { return fail("Hydrate separator is misplaced.") }
                normalized.append("·")
                formatted.append("·")
                expectsTerm = true
                index += 1
                continue
            }
            if character == "+" || character == "-" {
                guard depth == 0, !expectsTerm, index == cleaned.count - 1 else {
                    return fail("Use a trailing + or -, or ^2- for a charge magnitude.")
                }
                normalized.append(character)
                formatted.append(superscriptOutput[character] ?? character)
                index += 1
                continue
            }
            if character.isNumber {
                var digits = ""
                while index < cleaned.count, cleaned[index].isNumber {
                    digits.append(cleaned[index])
                    index += 1
                }
                guard digits.first != "0" else { return fail("Counts and coefficients cannot start with zero.") }
                normalized += digits
                if expectsTerm {
                    formatted += digits // leading coefficient
                } else {
                    formatted += String(digits.map { subscriptOutput[Int(String($0)) ?? 0] })
                }
                continue
            }
            guard character.isUppercase else { return fail("Expected an element symbol.") }
            var symbol = String(character)
            if index + 1 < cleaned.count, cleaned[index + 1].isLowercase {
                symbol.append(cleaned[index + 1])
                index += 1
            }
            guard elements.contains(symbol) else { return fail("Unknown element symbol \(symbol).") }
            normalized += symbol
            formatted += symbol
            expectsTerm = false
            index += 1
        }

        guard depth == 0 else { return fail("Close every parenthesis.") }
        guard !expectsTerm else { return fail("Formula ends before a molecule was entered.") }
        if inCharge {
            let suffix = normalized.split(separator: "^").last.map(String.init) ?? ""
            guard suffix.last == "+" || suffix.last == "-",
                  suffix.dropLast().allSatisfy(\.isNumber),
                  suffix.dropLast().first != "0" else {
                return fail("Charge must be +, -, or a non-zero magnitude such as 2-.")
            }
        }
        return .success(.init(normalized: normalized, formatted: formatted))
    }
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
    static func encode(_ payload: ChemicalStructurePayload) throws -> Data { try JSONEncoder().encode(payload) }
    static func encode(_ payload: MolecularFormulaPayload) throws -> Data { try JSONEncoder().encode(payload) }
    static func structure(from data: Data?) -> ChemicalStructurePayload? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(ChemicalStructurePayload.self, from: data)
    }
    static func formula(from data: Data?) -> MolecularFormulaPayload? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(MolecularFormulaPayload.self, from: data)
    }
}

private extension String {
    subscript(_ offset: Int) -> Character { self[index(startIndex, offsetBy: offset)] }
}
