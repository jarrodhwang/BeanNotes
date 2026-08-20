//
//  ChemistryEditorView.swift
//  BeanNotes
//

import PencilKit
import SwiftUI
import UIKit
import Vision

struct ChemicalStructureEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ChemicalStructureDraft
    @State private var selectedBond: ChemicalBondType = .single
    @State private var selectedElement = "C"
    @State private var selectedAtomID: UUID?
    @State private var isErasing = false
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    @State private var undoStack: [ChemicalGraph] = []
    @State private var redoStack: [ChemicalGraph] = []
    @State private var errorMessage: String?

    private let toolkit: any ChemicalToolkit = LocalChemicalToolkit()
    private let onSave: (ChemicalStructureDraft) -> Bool
    private let commonElements = ["C", "H", "N", "O", "P", "S", "F", "Cl", "Br", "I"]

    init(initialDraft: ChemicalStructureDraft, onSave: @escaping (ChemicalStructureDraft) -> Bool) {
        _draft = State(initialValue: initialDraft)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                controls
                structureCanvas
                if let selectedAtomIndex {
                    atomInspector(index: selectedAtomIndex)
                }
                validationView
            }
            .padding(16)
            .navigationTitle("Chemical Structure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(draft.graph.atoms.isEmpty)
                }
            }
        }
        .alert("Couldn’t Save Structure", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "Unknown error") }
        .task(id: draft.graph) { await validate() }
        .presentationDetents([.large])
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Menu {
                    ForEach(ChemicalBondType.allCases) { type in Button(type.label) { selectedBond = type; isErasing = false } }
                } label: { Label(selectedBond.label, systemImage: "line.diagonal") }
                .buttonStyle(.bordered)

                Menu {
                    ForEach(commonElements, id: \.self) { element in Button(element) { selectedElement = element; isErasing = false } }
                } label: { Label(selectedElement, systemImage: "atom") }
                .buttonStyle(.bordered)

                Menu {
                    ForEach(3...6, id: \.self) { size in Button("\(size)-member ring") { insertRing(size) } }
                } label: { Label("Ring", systemImage: "hexagon") }
                .buttonStyle(.bordered)

                Button { isErasing.toggle() } label: { Image(systemName: isErasing ? "eraser.fill" : "eraser") }
                    .buttonStyle(.borderedProminent).tint(isErasing ? .red : .accentColor)
                    .accessibilityLabel("Erase atoms")
            }
            HStack {
                Button { undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.disabled(undoStack.isEmpty)
                Button { redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }.disabled(redoStack.isEmpty)
                Spacer()
                Button { beautify() } label: { Label("Beautify", systemImage: "wand.and.stars") }
                    .disabled(draft.graph.atoms.count < 3)
            }
            .buttonStyle(.bordered)
            .font(.subheadline)
        }
    }

    private var structureCanvas: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                context.withCGContext { renderer in
                    ChemistryPreviewRenderer.draw(graph: draft.graph, in: CGRect(origin: .zero, size: size), context: renderer)
                }
                if let dragStart, let dragEnd {
                    var path = Path(); path.move(to: dragStart); path.addLine(to: dragEnd)
                    context.stroke(path, with: .color(.accentColor.opacity(0.7)), lineWidth: 2)
                }
                if let selectedAtom = draft.graph.atoms.first(where: { $0.id == selectedAtomID }) {
                    let point = point(for: selectedAtom, size: size)
                    context.stroke(Path(ellipseIn: CGRect(x: point.x - 14, y: point.y - 14, width: 28, height: 28)), with: .color(.accentColor), lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in dragStart = value.startLocation; dragEnd = value.location }
                    .onEnded { value in addBond(from: value.startLocation, to: value.location, size: proxy.size); dragStart = nil; dragEnd = nil }
            )
            .simultaneousGesture(SpatialTapGesture().onEnded { value in handleTap(value.location, size: proxy.size) })
        }
        .frame(minHeight: 360)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.35)) }
        .accessibilityLabel("Chemical structure editor")
        .accessibilityHint("Drag to create bonds or tap to place and select atoms")
    }

    private func atomInspector(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Selected atom").font(.subheadline.weight(.semibold))
                Picker("Element", selection: Binding(get: { draft.graph.atoms[index].element }, set: { updateSelectedAtom(element: $0) })) {
                    ForEach(commonElements, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Charge \(draft.graph.atoms[index].formalCharge)", value: Binding(get: { draft.graph.atoms[index].formalCharge }, set: { updateSelectedAtom(charge: $0) }), in: -4...4)
            }
            TextField(
                "Optional atom label",
                text: Binding(
                    get: { draft.graph.atoms[index].label ?? "" },
                    set: { updateSelectedAtom(label: $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder private var validationView: some View {
        if draft.validationWarnings.isEmpty {
            Label("Structure is ready to save", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(draft.validationWarnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle") }
            }.font(.caption).foregroundStyle(.orange)
        }
    }

    private var selectedAtomIndex: Int? { draft.graph.atoms.firstIndex { $0.id == selectedAtomID } }

    private func point(for atom: ChemicalAtom, size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(atom.x) * size.width, y: CGFloat(atom.y) * size.height)
    }

    private func normalized(_ point: CGPoint, size: CGSize) -> (Double, Double) {
        (Double(min(max(point.x / max(size.width, 1), 0.02), 0.98)), Double(min(max(point.y / max(size.height, 1), 0.02), 0.98)))
    }

    private func nearestAtom(to point: CGPoint, size: CGSize, threshold: CGFloat = 28) -> ChemicalAtom? {
        draft.graph.atoms.min { hypot(self.point(for: $0, size: size).x - point.x, self.point(for: $0, size: size).y - point.y) < hypot(self.point(for: $1, size: size).x - point.x, self.point(for: $1, size: size).y - point.y) }
            .flatMap { hypot(self.point(for: $0, size: size).x - point.x, self.point(for: $0, size: size).y - point.y) <= threshold ? $0 : nil }
    }

    private func addBond(from start: CGPoint, to end: CGPoint, size: CGSize) {
        let snappedEnd = snappedBondEnd(from: start, to: end)
        let existingStart = nearestAtom(to: start, size: size)
        let existingEnd = nearestAtom(to: snappedEnd, size: size)
        let requiredAtoms = (existingStart == nil ? 1 : 0) + (existingEnd == nil ? 1 : 0)
        guard !isErasing,
              draft.graph.bonds.count < ChemicalGraph.maximumBondCount,
              draft.graph.atoms.count + requiredAtoms <= ChemicalGraph.maximumAtomCount else { return }
        checkpoint()
        guard let startAtom = existingStart ?? addAtom(at: start, size: size),
              let endAtom = existingEnd ?? addAtom(at: snappedEnd, size: size) else {
            undoStack.removeLast()
            return
        }
        guard startAtom.id != endAtom.id,
              !draft.graph.bonds.contains(where: { Set([$0.startAtomID, $0.endAtomID]) == Set([startAtom.id, endAtom.id]) }) else { undoStack.removeLast(); return }
        draft.graph.bonds.append(.init(startAtomID: startAtom.id, endAtomID: endAtom.id, type: selectedBond))
    }

    @discardableResult private func addAtom(at point: CGPoint, size: CGSize) -> ChemicalAtom? {
        guard draft.graph.atoms.count < ChemicalGraph.maximumAtomCount else { return nil }
        let value = normalized(point, size: size)
        let atom = ChemicalAtom(element: selectedElement, x: value.0, y: value.1)
        draft.graph.atoms.append(atom)
        return atom
    }

    private func handleTap(_ location: CGPoint, size: CGSize) {
        if let atom = nearestAtom(to: location, size: size) {
            if isErasing {
                checkpoint(); draft.graph.atoms.removeAll { $0.id == atom.id }; draft.graph.bonds.removeAll { $0.startAtomID == atom.id || $0.endAtomID == atom.id }; selectedAtomID = nil
            } else { selectedAtomID = atom.id }
        } else if !isErasing {
            checkpoint()
            if let atom = addAtom(at: location, size: size) { selectedAtomID = atom.id }
            else { undoStack.removeLast() }
        }
    }

    private func insertRing(_ count: Int) {
        guard draft.graph.atoms.count + count <= ChemicalGraph.maximumAtomCount else { return }
        checkpoint()
        let atoms = (0..<count).map { index -> ChemicalAtom in
            let angle = Double(index) / Double(count) * .pi * 2 - .pi / 2
            return ChemicalAtom(x: 0.5 + cos(angle) * 0.25, y: 0.5 + sin(angle) * 0.25)
        }
        draft.graph.atoms.append(contentsOf: atoms)
        for index in atoms.indices { draft.graph.bonds.append(.init(startAtomID: atoms[index].id, endAtomID: atoms[(index + 1) % count].id, type: selectedBond)) }
    }

    private func updateSelectedAtom(element: String? = nil, charge: Int? = nil, label: String? = nil) {
        guard let index = selectedAtomIndex else { return }
        checkpoint()
        if let element { draft.graph.atoms[index].element = element }
        if let charge { draft.graph.atoms[index].formalCharge = charge }
        if let label { draft.graph.atoms[index].label = label.isEmpty ? nil : String(label.prefix(32)) }
    }

    private func snappedBondEnd(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        let step = CGFloat.pi / 6
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    private func checkpoint() { undoStack.append(draft.graph); if undoStack.count > 50 { undoStack.removeFirst() }; redoStack.removeAll() }
    private func undo() { guard let previous = undoStack.popLast() else { return }; redoStack.append(draft.graph); draft.graph = previous }
    private func redo() { guard let next = redoStack.popLast() else { return }; undoStack.append(draft.graph); draft.graph = next }

    private func validate() async { draft.validationWarnings = await toolkit.validate(draft.graph) }
    private func beautify() { checkpoint(); Task { do { draft.graph = try await toolkit.beautify(draft.graph) } catch { errorMessage = error.localizedDescription } } }

    private func save() {
        Task {
            do {
                draft.validationWarnings = await toolkit.validate(draft.graph)
                draft.molBlock = try await toolkit.molBlock(for: draft.graph)
                draft.canonicalSMILES = try await toolkit.canonicalSMILES(for: draft.graph)
                draft.molecularFormula = try await toolkit.molecularFormula(for: draft.graph)
                if onSave(draft) { dismiss() }
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

struct MolecularFormulaEditorSheet: View {
    private enum InputMode: String, CaseIterable, Identifiable { case pencil, keyboard; var id: String { rawValue }; var label: String { rawValue.capitalized } }
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MolecularFormulaDraft
    @State private var inputMode: InputMode = .keyboard
    @State private var drawing = PKDrawing()
    @State private var isRecognizing = false
    @State private var recognitionError: String?
    private let onSave: (MolecularFormulaDraft) -> Bool

    init(initialDraft: MolecularFormulaDraft, onSave: @escaping (MolecularFormulaDraft) -> Bool) { _draft = State(initialValue: initialDraft); self.onSave = onSave }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Picker("Input method", selection: $inputMode) { ForEach(InputMode.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                if inputMode == .keyboard { TextField("e.g. C6H12O6 or SO4^2-", text: $draft.sourceText).textFieldStyle(.roundedBorder).font(.title3.monospaced()) }
                else { handwritingEditor }
                formulaPreview
                Spacer()
            }
            .padding(18)
            .navigationTitle("Molecular Formula")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isRecognizing) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(parsedResult == nil || isRecognizing) }
            }
        }
        .alert("Couldn’t Recognize Formula", isPresented: Binding(get: { recognitionError != nil }, set: { if !$0 { recognitionError = nil } })) { Button("OK", role: .cancel) {} } message: { Text(recognitionError ?? "Unknown error") }
        .presentationDetents([.large])
    }

    private var handwritingEditor: some View {
        VStack(spacing: 10) {
            FormulaHandwritingCanvas(drawing: $drawing).frame(minHeight: 300).background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay { RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.35)) }
            HStack {
                Button("Clear", role: .destructive) { drawing = PKDrawing() }.disabled(drawing.strokes.isEmpty || isRecognizing)
                Spacer()
                Button { recognize() } label: { if isRecognizing { ProgressView() } else { Label("Convert Formula", systemImage: "text.viewfinder") } }.buttonStyle(.borderedProminent).disabled(drawing.strokes.isEmpty || isRecognizing)
            }
        }
    }

    @ViewBuilder private var formulaPreview: some View {
        switch MolecularFormulaParser.parse(draft.sourceText) {
        case .success(let result):
            VStack(spacing: 8) { Text(result.formatted).font(.system(size: 38, weight: .medium)); Text("Editable source: \(result.normalized)").font(.caption).foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, minHeight: 120).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        case .failure(let error):
            Label(error.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).frame(maxWidth: .infinity, minHeight: 80)
        }
    }

    private var parsedResult: MolecularFormulaParseResult? { try? MolecularFormulaParser.parse(draft.sourceText).get() }
    private func save() { guard let result = parsedResult else { return }; draft.normalizedFormula = result.normalized; if onSave(draft) { dismiss() } }

    private func recognize() {
        guard let image = handwritingImage(), let cgImage = image.cgImage else { recognitionError = "BeanNotes could not prepare the handwriting."; return }
        isRecognizing = true
        Task {
            defer { isRecognizing = false }
            do { draft.sourceText = try await FormulaHandwritingRecognizer.recognize(cgImage); draft.recognitionConfidence = nil; inputMode = .keyboard }
            catch { recognitionError = error.localizedDescription }
        }
    }

    private func handwritingImage() -> UIImage? {
        guard !drawing.strokes.isEmpty else { return nil }
        let bounds = drawing.bounds.insetBy(dx: -16, dy: -16)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return drawing.image(from: bounds, scale: 2)
    }
}

private struct FormulaHandwritingCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> PKCanvasView {
        let view = PKCanvasView(); view.delegate = context.coordinator; view.drawingPolicy = .anyInput; view.tool = PKInkingTool(.pen, color: .black, width: 3); view.drawing = drawing; view.accessibilityLabel = "Handwritten molecular formula canvas"; return view
    }
    func updateUIView(_ view: PKCanvasView, context: Context) { context.coordinator.parent = self; if view.drawing.dataRepresentation() != drawing.dataRepresentation() { view.drawing = drawing } }
    final class Coordinator: NSObject, PKCanvasViewDelegate { var parent: FormulaHandwritingCanvas; init(parent: FormulaHandwritingCanvas) { self.parent = parent }; func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { parent.drawing = canvasView.drawing } }
}

private enum FormulaHandwritingRecognizer {
    static func recognize(_ image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = false; request.minimumTextHeight = 0.01
            try VNImageRequestHandler(cgImage: image).perform([request])
            let text = (request.results ?? []).sorted { $0.boundingBox.minX < $1.boundingBox.minX }.compactMap { $0.topCandidates(1).first?.string }.joined()
            guard !text.isEmpty else { throw ChemistryServiceError.invalidGraph }
            return text
        }.value
    }
}
