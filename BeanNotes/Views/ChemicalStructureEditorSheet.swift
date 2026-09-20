import SwiftUI

struct ChemicalStructureEditorSheet: View {
    private enum Mode: String, CaseIterable { case drawing = "2D drawing", model = "3D model" }
    private enum Tool: String, CaseIterable { case draw = "Draw", move = "Move", erase = "Erase" }
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ChemicalStructureDraft
    @State private var mode: Mode = .drawing
    @State private var tool: Tool = .draw
    @State private var selectedBond: ChemicalBondType = .single
    @State private var selectedElement = "C"
    @State private var selectedAtomID: UUID?
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    @State private var undoStack: [ChemicalStructureDraft] = []
    @State private var redoStack: [ChemicalStructureDraft] = []
    @State private var errorMessage: String?
    @State private var showAtomLabels = true
    @State private var isSaving = false
    @State private var isChecking = true

    private let toolkit = LocalChemicalToolkit()
    private let onSave: (ChemicalStructureDraft) -> Bool
    private let commonElements = ["C", "H", "N", "O", "P", "S", "F", "Cl", "Br", "I", "Na", "K", "Ca", "Mg"]

    init(initialDraft: ChemicalStructureDraft, onSave: @escaping (ChemicalStructureDraft) -> Bool) {
        _draft = State(initialValue: initialDraft)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    exampleChooser
                    Picker("Structure view", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("chemistry.viewMode")
                    if mode == .drawing {
                        controls
                        structureCanvas
                        Toggle("Show carbon labels", isOn: $showAtomLabels).font(.subheadline)
                        Text(instructions).font(.caption).foregroundStyle(.secondary)
                        if selectedAtom != nil { atomInspector }
                    } else if let example = draft.matchingExample {
                        Molecule3DView(example: example).id(example.id)
                    } else {
                        ContentUnavailableView("Choose an example for 3D", systemImage: "cube.transparent", description: Text("The examples above include computed 3D coordinates. A drawing alone does not determine a molecule’s shape. Editing atoms, charges, or bonds removes the link to that example’s 3D model."))
                            .accessibilityIdentifier("chemistry.no3D")
                    }
                    historyControls
                    validationView
                }
                .padding(18)
                .disabled(isSaving)
            }
            .navigationTitle("Chemical Structure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .disabled(draft.graph.atoms.isEmpty || isSaving || !LocalChemicalToolkit.integrityErrors(in: draft.graph).isEmpty)
                        .accessibilityIdentifier("chemistry.saveStructure")
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .alert("Chemistry Editor", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "Could not complete this action.") }
        .task(id: draft.graph) { await validate() }
        .presentationDetents([.large])
    }

    private var exampleChooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Start with a molecule", systemImage: "atom").font(.headline)
            Text("Explore an example in 2D and 3D, or draw your own structure.")
                .font(.subheadline).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(ChemicalExampleLibrary.examples) { example in
                        Button { load(example) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(example.name).font(.subheadline.weight(.semibold))
                                Text(example.formattedFormula).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }.padding(.vertical, 5)
                        }.buttonStyle(.bordered)
                            .accessibilityIdentifier("chemistry.example.\(example.id)")
                    }
                }
            }
            if ChemicalExampleLibrary.examples.isEmpty {
                Text("The example library could not be loaded. You can still draw and save structures.").font(.caption).foregroundStyle(.orange)
            } else if !draft.graph.atoms.isEmpty {
                Text("Loading an example replaces the drawing. Undo restores it.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("Drawing tool", selection: $tool) {
                ForEach(Tool.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            ScrollView(.horizontal) {
                HStack {
                    Menu {
                        ForEach(ChemicalBondType.allCases) { type in Button(type.label) { selectedBond = type; tool = .draw } }
                    } label: { Label(selectedBond.label, systemImage: "line.diagonal") }
                    Menu {
                        ForEach(commonElements, id: \.self) { element in Button(element) { selectedElement = element; tool = .draw } }
                    } label: { Label("Atom: \(selectedElement)", systemImage: "atom") }
                    Menu {
                        ForEach(3...6, id: \.self) { size in Button("\(size)-member carbon ring") { insertRing(size) } }
                    } label: { Label("Ring", systemImage: "hexagon") }
                    Button("Clear", systemImage: "trash", role: .destructive) { changeGraph { $0 = ChemicalGraph() }; selectedAtomID = nil }
                        .disabled(draft.graph.atoms.isEmpty)
                }.buttonStyle(.bordered).font(.subheadline)
            }
        }
    }

    private var historyControls: some View {
        HStack {
            Button("Undo", systemImage: "arrow.uturn.backward") { undo() }.disabled(undoStack.isEmpty)
                .accessibilityIdentifier("chemistry.undo")
            Button("Redo", systemImage: "arrow.uturn.forward") { redo() }.disabled(redoStack.isEmpty)
                .accessibilityIdentifier("chemistry.redo")
            Spacer()
            if mode == .drawing {
                Button("Fit drawing", systemImage: "arrow.up.left.and.arrow.down.right") { fitDrawing() }.disabled(draft.graph.atoms.isEmpty)
            }
        }.buttonStyle(.bordered).font(.subheadline)
    }

    private var instructions: String {
        switch tool {
        case .draw: "Tap to add or select an atom. Drag between atoms to bond them. Tap a bond to apply the chosen bond type. Hydrogens are filled in using common valences."
        case .move: "Drag an atom to move it without changing its bonds."
        case .erase: "Tap an atom to remove it and its bonds, or tap a bond to remove only that bond. Undo restores your work."
        }
    }

    private var structureCanvas: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                context.withCGContext { renderer in
                    ChemistryPreviewRenderer.draw(graph: draft.graph, in: CGRect(origin: .zero, size: size), context: renderer, showAtomLabels: showAtomLabels)
                }
                if let dragStart, let dragEnd, tool == .draw {
                    var path = Path(); path.move(to: dragStart); path.addLine(to: dragEnd)
                    context.stroke(path, with: .color(.accentColor.opacity(0.7)), lineWidth: 2)
                }
                if let atom = selectedAtom {
                    let center = point(for: atom, size: size)
                    context.stroke(Path(ellipseIn: CGRect(x: center.x - 21, y: center.y - 21, width: 42, height: 42)), with: .color(.accentColor), lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 8)
                .onChanged { value in dragStart = value.startLocation; dragEnd = value.location }
                .onEnded { value in
                    if tool == .move, let atom = nearestAtom(to: value.startLocation, size: proxy.size) {
                        let position = normalized(value.location, size: proxy.size)
                        changeGraph { graph in
                            guard let index = graph.atoms.firstIndex(where: { $0.id == atom.id }) else { return }
                            graph.atoms[index].x = position.0; graph.atoms[index].y = position.1
                        }
                        selectedAtomID = atom.id
                    } else if tool == .draw { addBond(from: value.startLocation, to: value.location, size: proxy.size) }
                    dragStart = nil; dragEnd = nil
                })
            .simultaneousGesture(SpatialTapGesture().onEnded { handleTap($0.location, size: proxy.size) })
            .overlay {
                if draft.graph.atoms.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "pencil.and.outline").font(.largeTitle)
                        Text("Choose an example above,\nor tap here to add your first atom.").multilineTextAlignment(.center)
                    }.foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
        }
        .frame(height: 350)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.35)) }
        .accessibilityLabel("Chemical structure drawing")
        .accessibilityIdentifier("chemistry.canvas")
    }

    private var selectedAtom: ChemicalAtom? { draft.graph.atoms.first { $0.id == selectedAtomID } }

    private var atomInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selected atom").font(.subheadline.bold())
            HStack {
                Picker("Element", selection: Binding(get: { selectedAtom?.element ?? "C" }, set: { updateSelectedAtom(element: $0) })) {
                    ForEach(commonElements, id: \.self) { Text($0).tag($0) }
                }.accessibilityIdentifier("chemistry.atomElement")
                Stepper("Charge: \(selectedAtom?.formalCharge ?? 0)", value: Binding(get: { selectedAtom?.formalCharge ?? 0 }, set: { updateSelectedAtom(charge: $0) }), in: -4...4)
            }
            TextField("Optional caption (does not change the element)", text: Binding(get: { selectedAtom?.label ?? "" }, set: { updateSelectedAtom(label: $0) }))
                .textFieldStyle(.roundedBorder)
        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var validationView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isChecking { ProgressView("Checking bonds…").font(.caption) }
            else if !draft.graph.atoms.isEmpty {
                if let formula = draft.molecularFormula {
                    LabeledContent("Formula estimate", value: (try? MolecularFormulaParser.parse(formula).get().formatted) ?? formula)
                        .font(.headline).accessibilityIdentifier("chemistry.formulaEstimate")
                } else {
                    Text("Formula unavailable for this bonding or charge pattern.").font(.subheadline)
                }
                if draft.validationWarnings.isEmpty {
                    Label("Basic bond checks passed", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
            }
            ForEach(Array(draft.validationWarnings.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Text("Formulas assume common valences and include implied hydrogens. These checks do not establish chemical stability, aromaticity, or stereochemistry. A formula alone cannot identify a unique structure.")
                .font(.caption).foregroundStyle(.secondary)
        }.font(.subheadline)
    }

    private func load(_ example: ChemicalExample) {
        checkpoint()
        let id = draft.id
        draft = example.makeDraft()
        draft.id = id
        selectedAtomID = nil
    }

    private func point(for atom: ChemicalAtom, size: CGSize) -> CGPoint {
        let rect = ChemistryPreviewRenderer.drawingRect(in: CGRect(origin: .zero, size: size))
        return CGPoint(x: rect.minX + atom.x * rect.width, y: rect.minY + atom.y * rect.height)
    }

    private func normalized(_ point: CGPoint, size: CGSize) -> (Double, Double) {
        let rect = ChemistryPreviewRenderer.drawingRect(in: CGRect(origin: .zero, size: size))
        return (Double(min(max((point.x - rect.minX) / max(rect.width, 1), 0.05), 0.95)),
                Double(min(max((point.y - rect.minY) / max(rect.height, 1), 0.05), 0.95)))
    }

    private func nearestAtom(to location: CGPoint, size: CGSize) -> ChemicalAtom? {
        draft.graph.atoms.min { distance(point(for: $0, size: size), location) < distance(point(for: $1, size: size), location) }
            .flatMap { distance(point(for: $0, size: size), location) <= 24 ? $0 : nil }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private func nearestBond(to location: CGPoint, size: CGSize) -> ChemicalBond? {
        let atoms = Dictionary(draft.graph.atoms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return draft.graph.bonds.compactMap { bond -> (ChemicalBond, CGFloat)? in
            guard let first = atoms[bond.startAtomID], let second = atoms[bond.endAtomID] else { return nil }
            let a = point(for: first, size: size), b = point(for: second, size: size)
            let dx = b.x - a.x, dy = b.y - a.y, squared = dx * dx + dy * dy
            guard squared > 1 else { return nil }
            let t = min(1, max(0, ((location.x - a.x) * dx + (location.y - a.y) * dy) / squared))
            return (bond, distance(location, CGPoint(x: a.x + t * dx, y: a.y + t * dy)))
        }.filter { $0.1 <= 12 }.min { $0.1 < $1.1 }?.0
    }

    private func addBond(from start: CGPoint, to end: CGPoint, size: CGSize) {
        let first = nearestAtom(to: start, size: size)
        let origin = first.map { point(for: $0, size: size) } ?? start
        let angle = (atan2(end.y - origin.y, end.x - origin.x) / (.pi / 6)).rounded() * (.pi / 6)
        let length = distance(origin, end)
        let snapped = CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
        // Snap to a real target before snapping the free end to a 30-degree angle.
        let last = nearestAtom(to: end, size: size) ?? nearestAtom(to: snapped, size: size)
        let a = normalized(origin, size: size), b = normalized(snapped, size: size)
        let startAtom = first ?? ChemicalAtom(element: selectedElement, x: a.0, y: a.1)
        let endAtom = last ?? ChemicalAtom(element: selectedElement, x: b.0, y: b.1)
        guard startAtom.id != endAtom.id, hypot(startAtom.x - endAtom.x, startAtom.y - endAtom.y) > 0.025 else { return }
        changeGraph { graph in
            if first == nil { graph.atoms.append(startAtom) }
            if last == nil { graph.atoms.append(endAtom) }
            if let index = graph.bonds.firstIndex(where: { Set([$0.startAtomID, $0.endAtomID]) == Set([startAtom.id, endAtom.id]) }) {
                graph.bonds[index].type = selectedBond
                graph.bonds[index].startAtomID = startAtom.id
                graph.bonds[index].endAtomID = endAtom.id
            } else { graph.bonds.append(.init(startAtomID: startAtom.id, endAtomID: endAtom.id, type: selectedBond)) }
        }
        selectedAtomID = endAtom.id
    }

    private func handleTap(_ location: CGPoint, size: CGSize) {
        if let atom = nearestAtom(to: location, size: size) {
            if tool == .erase {
                changeGraph { graph in
                    graph.atoms.removeAll { $0.id == atom.id }
                    graph.bonds.removeAll { $0.startAtomID == atom.id || $0.endAtomID == atom.id }
                }
                selectedAtomID = nil
            } else { selectedAtomID = atom.id }
        } else if let bond = nearestBond(to: location, size: size), tool != .move {
            changeGraph { graph in
                if tool == .erase { graph.bonds.removeAll { $0.id == bond.id } }
                else if let index = graph.bonds.firstIndex(where: { $0.id == bond.id }) { graph.bonds[index].type = selectedBond }
            }
        } else if tool == .draw {
            let position = normalized(location, size: size)
            let atom = ChemicalAtom(element: selectedElement, x: position.0, y: position.1)
            changeGraph { $0.atoms.append(atom) }
            selectedAtomID = atom.id
        } else { selectedAtomID = nil }
    }

    private func insertRing(_ count: Int) {
        let atoms = (0..<count).map { index -> ChemicalAtom in
            let angle = Double(index) / Double(count) * .pi * 2 - .pi / 2
            return ChemicalAtom(x: 0.5 + cos(angle) * 0.28, y: 0.5 + sin(angle) * 0.28)
        }
        changeGraph { graph in
            graph.atoms.append(contentsOf: atoms)
            for index in atoms.indices { graph.bonds.append(.init(startAtomID: atoms[index].id, endAtomID: atoms[(index + 1) % count].id)) }
        }
    }

    private func updateSelectedAtom(element: String? = nil, charge: Int? = nil, label: String? = nil) {
        changeGraph { graph in
            guard let index = graph.atoms.firstIndex(where: { $0.id == selectedAtomID }) else { return }
            if let element { graph.atoms[index].element = element }
            if let charge { graph.atoms[index].formalCharge = charge }
            if let label { graph.atoms[index].label = label.isEmpty ? nil : String(label.prefix(32)) }
        }
    }

    private func changeGraph(_ change: (inout ChemicalGraph) -> Void) {
        var proposed = draft.graph
        change(&proposed)
        guard proposed != draft.graph else { return }
        guard LocalChemicalToolkit.integrityErrors(in: proposed).isEmpty else { errorMessage = LocalChemicalToolkit.integrityErrors(in: proposed).joined(separator: "\n"); return }
        checkpoint()
        draft.graph = proposed
        draft.molBlock = nil; draft.canonicalSMILES = nil; draft.molecularFormula = nil
    }

    private func checkpoint() {
        undoStack.append(draft)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }
    private func undo() { guard let previous = undoStack.popLast() else { return }; redoStack.append(draft); draft = previous; selectedAtomID = nil }
    private func redo() { guard let next = redoStack.popLast() else { return }; undoStack.append(draft); draft = next; selectedAtomID = nil }

    private func validate() async {
        isChecking = true
        let graph = draft.graph
        let warnings = await toolkit.validate(graph)
        let formula = try? await toolkit.molecularFormula(for: graph)
        guard !Task.isCancelled, graph == draft.graph else { return }
        draft.validationWarnings = warnings
        draft.molecularFormula = formula
        isChecking = false
    }

    private func fitDrawing() {
        let graph = draft.graph
        Task {
            do {
                let fitted = try await toolkit.beautify(graph)
                guard graph == draft.graph, !isSaving else { return }
                changeGraph { $0 = fitted }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        let snapshot = draft
        Task {
            defer { isSaving = false }
            do {
                var result = snapshot
                result.validationWarnings = await toolkit.validate(snapshot.graph)
                result.molBlock = try await toolkit.molBlock(for: snapshot.graph)
                result.canonicalSMILES = nil
                result.molecularFormula = try await toolkit.molecularFormula(for: snapshot.graph)
                if result.matchingExample == nil { result.reference = nil }
                if onSave(result) { dismiss() }
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
