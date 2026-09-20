import Foundation

struct MolecularFormulaParseResult: Equatable, Sendable {
    var normalized: String
    var formatted: String
    var elementCounts: [String: Int] = [:]
    var charge: Int = 0
    var atomCount: Int { elementCounts.values.reduce(0, +) }
}

struct MolecularFormulaParseError: LocalizedError, Equatable, Sendable {
    var position: Int
    var message: String
    var errorDescription: String? { message }
}

/// A bounded notation parser, not a test of chemical existence or stability.
/// Supports nested ()/[] groups, hydrate components, coefficients and one overall charge.
enum MolecularFormulaParser {
    static let maximumInputLength = 512
    static let maximumAtomCount = 1_000_000
    static let elements = Set(("H He Li Be B C N O F Ne Na Mg Al Si P S Cl Ar K Ca Sc Ti V Cr Mn Fe Co Ni Cu Zn Ga Ge As Se Br Kr " +
        "Rb Sr Y Zr Nb Mo Tc Ru Rh Pd Ag Cd In Sn Sb Te I Xe Cs Ba La Ce Pr Nd Pm Sm Eu Gd Tb Dy Ho Er Tm Yb Lu " +
        "Hf Ta W Re Os Ir Pt Au Hg Tl Pb Bi Po At Rn Fr Ra Ac Th Pa U Np Pu Am Cm Bk Cf Es Fm Md No Lr Rf Db Sg Bh Hs Mt Ds Rg Cn Nh Fl Mc Lv Ts Og").split(separator: " ").map(String.init))
    private static let digits = Array("0123456789")
    private static let subscripts = Array("₀₁₂₃₄₅₆₇₈₉")
    private static let superscripts = Array("⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻")

    static func parse(_ raw: String) -> Result<MolecularFormulaParseResult, MolecularFormulaParseError> {
        guard raw.utf16.count <= maximumInputLength else {
            return .failure(.init(position: maximumInputLength, message: "Formula is limited to \(maximumInputLength) characters."))
        }
        var input: [Character] = []
        var inSuperscript = false
        for character in raw where !character.isWhitespace {
            if let index = subscripts.firstIndex(of: character) {
                input.append(digits[index])
            } else if let index = superscripts.firstIndex(of: character) {
                if !inSuperscript, input.last != "^" { input.append("^") }
                inSuperscript = true
                input.append(Array("0123456789+-")[index])
            } else {
                input.append(character == "−" ? "-" : character == "." ? "·" : character)
                inSuperscript = false
            }
        }
        do {
            var parser = Parser(input: input)
            return .success(try parser.parse())
        } catch let error as MolecularFormulaParseError {
            return .failure(error)
        } catch {
            return .failure(.init(position: 0, message: "Could not read this formula."))
        }
    }

    private struct Parser {
        var input: [Character]
        var index = 0
        var normalized = ""
        var formatted = ""
        var current: Character? { index < input.count ? input[index] : nil }
        func isDigit(_ character: Character?) -> Bool { character.map { MolecularFormulaParser.digits.contains($0) } ?? false }
        func failure(_ message: String) -> MolecularFormulaParseError { .init(position: index, message: message) }

        mutating func parse() throws -> MolecularFormulaParseResult {
            guard !input.isEmpty else { throw failure("Enter a formula, such as H2O.") }
            var counts: [String: Int] = [:]
            while true {
                let coefficient = try number(asSubscript: false)
                let component = try terms(closing: nil, depth: 0)
                try add(component, multiplier: coefficient, to: &counts)
                if current != "·" { break }
                append("·")
            }
            var charge = 0
            if current == "^" || current == "+" || current == "-" {
                if current == "^" {
                    index += 1
                    normalized += "^"
                    charge = try number(asSubscript: false, asSuperscript: true)
                } else { charge = 1 }
                guard current == "+" || current == "-" else {
                    throw failure("End the charge with + or −, for example SO4^2-.")
                }
                guard charge <= 99 else { throw failure("Charge magnitude must be between 1 and 99.") }
                let sign = current!
                charge *= sign == "-" ? -1 : 1
                normalized.append(sign)
                formatted.append(sign == "-" ? "⁻" : "⁺")
                index += 1
            }
            guard index == input.count else {
                throw failure("Unexpected character. Use element symbols, counts, groups, and a trailing charge.")
            }
            return .init(normalized: normalized, formatted: formatted, elementCounts: counts, charge: charge)
        }

        mutating func terms(closing: Character?, depth: Int) throws -> [String: Int] {
            guard depth <= 16 else { throw failure("Use no more than 16 nested groups.") }
            var counts: [String: Int] = [:]
            var termCount = 0
            while let character = current {
                if character == ")" || character == "]" {
                    guard character == closing else { throw failure("The closing bracket does not match its group.") }
                    break
                }
                if character == "·" || character == "^" || character == "+" || character == "-" { break }
                var term: [String: Int]
                if character == "(" || character == "[" {
                    let end: Character = character == "(" ? ")" : "]"
                    append(character)
                    term = try terms(closing: end, depth: depth + 1)
                    guard current == end else { throw failure("Close every group before adding a hydrate or charge.") }
                    append(end)
                } else {
                    guard character >= "A", character <= "Z" else {
                        throw failure("Expected an element symbol, such as C, H, or Na. Counts follow atoms or groups.")
                    }
                    var symbol = String(character)
                    index += 1
                    if let next = current, next >= "a", next <= "z" { symbol.append(next); index += 1 }
                    guard MolecularFormulaParser.elements.contains(symbol) else { throw failure("Unknown element symbol \(symbol). Check capitalization.") }
                    normalized += symbol
                    formatted += symbol
                    term = [symbol: 1]
                }
                let count = try number(asSubscript: true)
                try add(term, multiplier: count, to: &counts)
                termCount += 1
            }
            guard termCount > 0 else { throw failure("Every group or hydrate component needs at least one element.") }
            if closing != nil, current != closing { throw failure("Close every group with its matching bracket.") }
            return counts
        }

        mutating func number(asSubscript: Bool, asSuperscript: Bool = false) throws -> Int {
            guard isDigit(current) else { return 1 }
            guard current != "0" else { throw failure("Counts and charge magnitudes cannot start with zero.") }
            var value = 0
            while let character = current, let digit = MolecularFormulaParser.digits.firstIndex(of: character) {
                guard value <= (MolecularFormulaParser.maximumAtomCount - digit) / 10 else { throw failure("This formula has too many atoms.") }
                value = value * 10 + digit
                normalized.append(character)
                formatted.append(asSuperscript ? MolecularFormulaParser.superscripts[digit] : asSubscript ? MolecularFormulaParser.subscripts[digit] : character)
                index += 1
            }
            return value
        }

        func add(_ source: [String: Int], multiplier: Int, to destination: inout [String: Int]) throws {
            for (element, count) in source {
                guard count <= MolecularFormulaParser.maximumAtomCount / multiplier else { throw failure("This formula has too many atoms.") }
                destination[element, default: 0] += count * multiplier
            }
            guard destination.values.reduce(0, +) <= MolecularFormulaParser.maximumAtomCount else { throw failure("This formula has too many atoms.") }
        }

        mutating func append(_ character: Character) {
            normalized.append(character); formatted.append(character); index += 1
        }
    }
}
