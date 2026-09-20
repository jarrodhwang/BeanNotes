# Chemistry editing and 3D examples

Enable **Settings → Focus Features → Enable Chemistry & MBB Features**, then use the flask in the pencil palette or **Page actions → Add Chemical Structure / Add Molecular Formula**.

The structure editor provides eight named examples, 2D drawing with atom and bond editing, moving, erasing, undo/redo, and a layout-preserving **Fit drawing** command. Carbon labels can be shown for learning or hidden for skeletal drawings. Heteroatom labels include inferred hydrogens when the whole graph supports the local valence rules. Captions are annotations; they do not change an atom's element.

The formula editor supports the 118 element symbols, nested parentheses and square brackets, hydrate dots, leading coefficients, Unicode subscripts and charge superscripts, and explicit charges such as `SO4^2-`. It reports total atoms, each element's count, and overall charge. `Fe3+` means three Fe atoms with charge +1; use `Fe^3+` for a single iron ion with charge +3. Formula syntax cannot identify a unique molecule or prove chemical stability. OCR output always needs human review.

## 3D scope and provenance

Water, methane, ammonia, carbon dioxide, ethanol, benzene, neutral glycine, and caffeine have bundled 2D and computed 3D coordinates from [PubChem PUG REST](https://pubchem.ncbi.nlm.nih.gov/docs/pug-rest). Each example records its compound CID, conformer ID, retrieval date, explicit atoms, and bonds in `BeanNotes/Resources/Chemistry/MoleculeExamples.json`. `Scripts/refresh-chemistry-examples.py` refreshes this small library; inspect the diff and rerun qualification after a refresh.

[PubChem3D](https://pubchem.ncbi.nlm.nih.gov/docs/pubchem3d) supplies theoretical conformers. An example is one possible pose, not experimental coordinates, a molecular dynamics simulation, or a prediction of shape under particular solution/binding conditions. The UI links to the compound source. A molecule's charge/protonation can depend on its environment; glycine is deliberately identified as the neutral form.

RealityKit renders sphere and bond meshes through Metal in a non-AR view; no camera permission, camera feed, network request, physics simulation, or web renderer is used. Meshes are shared within the viewer and materials within a molecule. The scene exists only while its 3D panel is visible and the app is active. There is no automatic rotation. Drag/pinch and explicit rotate, zoom, reset, and atom inspection controls support touch and accessibility. Space filling uses approximate conventional H/C/N/O van der Waals radii ([Bondi, 1964](https://pubs.acs.org/doi/abs/10.1021/j100785a001)); ball-and-stick uses reduced radii and illustrative bond thickness.

A reference contains the original graph and the example identifier. Coordinates are shown only when atom identity, elements, charges, directed bonds, and the bundled example's topology still match. Moving atoms or adding captions preserves the reference. Chemical edits invalidate it immediately; undo can restore it. Saving a changed structure drops its stale reference. Existing schema-1 attachments remain readable because the reference is optional.

Custom drawings remain editable and saveable, but **do not receive invented 3D coordinates**. Arbitrary SMILES/MOL import, protein structures, force fields, reaction balancing, and canonical SMILES generation are outside this implementation.

## Accuracy, reliability, and bounds

The local toolkit performs limited valence accounting for common atoms and charge states. It estimates hydrogens and uses Hill ordering for formula output. Unsupported elements/charges, excess bonds, or ambiguous aromatic hydrogen counts suppress the formula instead of producing a partial answer. Aromatic carbon rings can be counted; other aromatic patterns require explicit single/double bond notation. Passing these checks does not establish aromaticity, chemical existence, stereochemistry, or stability. Disconnected components and specific problematic atoms receive readable feedback.

Graph integrity checks reject duplicate identifiers, missing endpoints, self/duplicate bonds, unknown elements, nonfinite/extreme coordinates, and oversized structures before export or dictionary construction. Graphs are limited to 256 atoms and 512 bonds; history to 50 edits. Formula input is limited to 512 UTF-16 units, 16 nested groups, and one million counted atoms. Handwriting rasterization has a 2,048-pixel edge cap. Async validation discards stale results and saving takes an immutable snapshot.

MOL V2000 export preserves directed wedge/down bonds and formal charges (`M  CHG`, at most eight pairs per line), uses fixed-width element columns and a decimal-point locale. Exported coordinates are drawing coordinates, not physical bond-length measurements. The saved note preview remains a normal 2D image, so existing PDF/image export and backups continue to work without an active 3D scene.

## Validation

Focused simulator command (choose an available simulator ID):

```sh
xcodebuild test -project BeanNotes.xcodeproj -scheme BeanNotes \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M4),OS=17.5' \
  -parallel-testing-enabled NO \
  -only-testing:BeanNotesTests/ChemistryTests \
  -only-testing:BeanNotesUITests/ChemistryUITests
```

`ChemistryTests` covers malformed notation, overflow/depth limits, Unicode round trips, nested/hydrate atom counts, charge rules, bad graph references, MOL columns/charges/stereo, layout preservation, all eight examples' formulas and bond-length sanity, reference invalidation, old payload decoding, and preview rendering. The UI suite exercises formula entry/save, 3D exploration and persistence, and edit/undo behavior.

For an independent developer-only oracle, install RDKit in a disposable Python virtual environment, then run:

```sh
CHEMISTRY_PYTHON=/path/to/venv/bin/python3 bash Scripts/qualify-chemistry.sh
```

This compiles the actual Swift models and toolkit, exports all eight examples plus ammonium and hydroxide, and checks each MOL using RDKit's strict parser, sanitization, and formula calculator. No RDKit code ships in the app. On 2026-09-20, all ten fixtures passed using RDKit 2025.09.2. This is targeted interoperability evidence, not general qualification of the toolkit for arbitrary chemistry.

Physical iPad release check: rotate/zoom caffeine, switch styles and hydrogen visibility repeatedly, background/foreground, and close/reopen the editor. Use Instruments Metal System Trace, Animation Hitches, and Energy Log to check sustained interaction and idle power. Simulator tests cannot establish actual iPad frame rates, GPU energy use, or Pencil feel.

### Simulator results — 2026-09-20

Xcode 26.6; Debug builds. The original unit lane passed 307 tests before chemistry changes. After the changes:

- iPadOS 26.5, iPad Pro 13-inch (M5): all 331 tests in `BeanNotesTests` and `ChemistryTests` passed, including the original rendering/import/export correctness tests. All three chemistry UI scenarios also passed.
- iPadOS 17.5, iPad Pro 11-inch (M4): the 13 chemistry tests (40 cases with parameterized inputs) passed. All three chemistry UI scenarios passed, including saving, terminating the app, and reopening the sourced 3D model. Finger drawing/undo and focus-mode regression checks also passed. Ball-and-stick and space-filling screenshots were visually inspected.
- Independent RDKit checks: all ten actual Swift-exported fixtures passed strict MOL parsing, sanitization, and formula comparison.

A broader iPadOS 17.5 run did **not** pass: the existing trash-deletion tests reported cleanup/fetch failures, the long-file-name test reported missing extensions, and the run restarted around PDF/canvas tests. That run was stopped; these non-chemistry failures remain outside this change. Passing the focused chemistry checks does not imply that the entire app is qualified on iPadOS 17.5. Simulator runs also encountered test-runner termination during bootstrapping; affected UI scenarios were rerun on a fresh simulator.
