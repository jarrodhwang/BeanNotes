#!/usr/bin/env bash
# Optional independent export/formula oracle; RDKit is a developer-only dependency.
# Usage: CHEMISTRY_PYTHON=/path/to/venv/bin/python3 bash Scripts/qualify-chemistry.sh
set -euo pipefail
CHEMISTRY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHEMISTRY_PYTHON="${CHEMISTRY_PYTHON:-python3}"
"$CHEMISTRY_PYTHON" -c 'from rdkit import Chem' || {
  echo 'Install RDKit in a disposable Python virtual environment and set CHEMISTRY_PYTHON.' >&2
  exit 1
}
CHEMISTRY_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/beannotes-chemistry.XXXXXX")"
trap 'rm -rf "$CHEMISTRY_TEMP"' EXIT
cat > "$CHEMISTRY_TEMP/ExportFixtures.swift" <<'SWIFT'
import Foundation
@main struct ExportFixtures {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let data = try Data(contentsOf: root.appendingPathComponent("BeanNotes/Resources/Chemistry/MoleculeExamples.json"))
        let examples = try JSONDecoder().decode([ChemicalExample].self, from: data)
        let toolkit = LocalChemicalToolkit()
        var expected: [String: String] = [:]
        for example in examples {
            let graph = example.makeDraft().graph
            try await toolkit.molBlock(for: graph).write(to: output.appendingPathComponent(example.id + ".mol"), atomically: true, encoding: .utf8)
            expected[example.id] = try await toolkit.molecularFormula(for: graph)
        }
        for (name, atom) in [("ammonium", ChemicalAtom(element: "N", formalCharge: 1, x: 0.5, y: 0.5)), ("hydroxide", ChemicalAtom(element: "O", formalCharge: -1, x: 0.5, y: 0.5))] {
            let graph = ChemicalGraph(atoms: [atom])
            try await toolkit.molBlock(for: graph).write(to: output.appendingPathComponent(name + ".mol"), atomically: true, encoding: .utf8)
            expected[name] = try await toolkit.molecularFormula(for: graph)
        }
        try JSONEncoder().encode(expected).write(to: output.appendingPathComponent("expected.json"))
    }
}
SWIFT
swiftc "$CHEMISTRY_ROOT/BeanNotes/Models/ChemistryConfiguration.swift" \
  "$CHEMISTRY_ROOT/BeanNotes/Models/MolecularFormulaParser.swift" \
  "$CHEMISTRY_ROOT/BeanNotes/Models/ChemicalExamples.swift" \
  "$CHEMISTRY_ROOT/BeanNotes/Services/LocalChemicalToolkit.swift" \
  "$CHEMISTRY_TEMP/ExportFixtures.swift" -o "$CHEMISTRY_TEMP/export-fixtures"
"$CHEMISTRY_TEMP/export-fixtures" "$CHEMISTRY_ROOT" "$CHEMISTRY_TEMP"
"$CHEMISTRY_PYTHON" - "$CHEMISTRY_TEMP" <<'PY'
from pathlib import Path
import json
import sys
from rdkit import Chem, rdBase
from rdkit.Chem import rdMolDescriptors
folder = Path(sys.argv[1])
expected = json.loads((folder / 'expected.json').read_text())
assert len(expected) == 10, 'A fixture is missing or has no formula'
print('Independent qualification with RDKit', rdBase.rdkitVersion)
for name, formula in sorted(expected.items()):
    molecule = Chem.MolFromMolFile(str(folder / (name + '.mol')), strictParsing=True, sanitize=True)
    assert molecule is not None, f'{name}: invalid MOL export'
    actual = rdMolDescriptors.CalcMolFormula(molecule)
    assert actual == formula.replace('^', ''), (name, formula, actual)
    print(f'{name}: {actual} PASS')
PY
