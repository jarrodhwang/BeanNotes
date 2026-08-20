//
//  FocusFeatureConfiguration.swift
//  BeanNotes
//

import Foundation

enum FocusFeatureSector: String, CaseIterable, Codable, Identifiable, Sendable {
    case computerScience
    case chemistryMBB

    var id: String { rawValue }

    var label: String {
        switch self {
        case .computerScience: "Computer Science"
        case .chemistryMBB: "Chemistry & MBB"
        }
    }
}

enum FocusFeature: String, CaseIterable, Codable, Identifiable, Sendable {
    case codeSnippets
    case chemicalStructure
    case molecularFormula

    var id: String { rawValue }

    var sector: FocusFeatureSector {
        switch self {
        case .codeSnippets: .computerScience
        case .chemicalStructure, .molecularFormula: .chemistryMBB
        }
    }
}

enum ChemicalStructureInputMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case smartEditor
    // Do not add on-device recognition to allCases until a qualified model ships.
    case onDeviceRecognition

    var id: String { rawValue }

    var label: String {
        switch self {
        case .smartEditor: "Smart Editor"
        case .onDeviceRecognition: "On-Device Recognition"
        }
    }
}

enum FocusFeaturePreferences {
    static let computerScienceEnabledKey = "focusFeatures.computerScience.enabled"
    static let chemistryEnabledKey = "focusFeatures.chemistryMBB.enabled"
    static let codeSnippetsEnabledKey = "focusFeatures.codeSnippets.enabled"
    static let chemicalStructureEnabledKey = "focusFeatures.chemicalStructure.enabled"
    static let molecularFormulaEnabledKey = "focusFeatures.molecularFormula.enabled"
    static let chemicalStructureInputModeKey = "focusFeatures.chemicalStructure.inputMode"

    static let defaultComputerScienceEnabled = true
    static let defaultChemistryEnabled = false
    static let defaultCodeSnippetsEnabled = true
    static let defaultChemicalStructureEnabled = true
    static let defaultMolecularFormulaEnabled = true

    /// Remains false until a bundled model passes the documented qualification gate.
    static let isChemicalStructureRecognitionQualified = false

    static func bool(
        forKey key: String,
        default defaultValue: Bool,
        in defaults: UserDefaults = .standard
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    static func isSectorEnabled(
        _ sector: FocusFeatureSector,
        in defaults: UserDefaults = .standard
    ) -> Bool {
        switch sector {
        case .computerScience:
            bool(forKey: computerScienceEnabledKey, default: defaultComputerScienceEnabled, in: defaults)
        case .chemistryMBB:
            bool(forKey: chemistryEnabledKey, default: defaultChemistryEnabled, in: defaults)
        }
    }

    static func isFeatureEnabled(
        _ feature: FocusFeature,
        in defaults: UserDefaults = .standard
    ) -> Bool {
        guard isSectorEnabled(feature.sector, in: defaults) else { return false }
        switch feature {
        case .codeSnippets:
            return bool(forKey: codeSnippetsEnabledKey, default: defaultCodeSnippetsEnabled, in: defaults)
        case .chemicalStructure:
            return bool(forKey: chemicalStructureEnabledKey, default: defaultChemicalStructureEnabled, in: defaults)
        case .molecularFormula:
            return bool(forKey: molecularFormulaEnabledKey, default: defaultMolecularFormulaEnabled, in: defaults)
        }
    }

    static func normalizePersistedValues(in defaults: UserDefaults = .standard) {
        let values: [(String, Bool)] = [
            (computerScienceEnabledKey, bool(forKey: computerScienceEnabledKey, default: defaultComputerScienceEnabled, in: defaults)),
            (chemistryEnabledKey, bool(forKey: chemistryEnabledKey, default: defaultChemistryEnabled, in: defaults)),
            (codeSnippetsEnabledKey, bool(forKey: codeSnippetsEnabledKey, default: defaultCodeSnippetsEnabled, in: defaults)),
            (chemicalStructureEnabledKey, bool(forKey: chemicalStructureEnabledKey, default: defaultChemicalStructureEnabled, in: defaults)),
            (molecularFormulaEnabledKey, bool(forKey: molecularFormulaEnabledKey, default: defaultMolecularFormulaEnabled, in: defaults))
        ]
        values.forEach { defaults.set($0.1, forKey: $0.0) }

        let requested = ChemicalStructureInputMode(
            rawValue: defaults.string(forKey: chemicalStructureInputModeKey) ?? ""
        ) ?? .smartEditor
        let available = requested == .onDeviceRecognition && !isChemicalStructureRecognitionQualified
            ? ChemicalStructureInputMode.smartEditor
            : requested
        defaults.set(available.rawValue, forKey: chemicalStructureInputModeKey)
    }
}
