//
//  ChemistryEditorView.swift
//  BeanNotes
//

import PencilKit
import SwiftUI
import UIKit
import Vision

struct MolecularFormulaEditorSheet: View {
    private enum InputMode: String, CaseIterable, Identifiable { case pencil, keyboard; var id: String { rawValue }; var label: String { rawValue.capitalized } }
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MolecularFormulaDraft
    @State private var inputMode: InputMode = .keyboard
    @State private var drawing = PKDrawing()
    @State private var isRecognizing = false
    @State private var needsRecognitionReview = false
    @State private var recognitionError: String?
    private let onSave: (MolecularFormulaDraft) -> Bool

    init(initialDraft: MolecularFormulaDraft, onSave: @escaping (MolecularFormulaDraft) -> Bool) { _draft = State(initialValue: initialDraft); self.onSave = onSave }

    var body: some View {
        NavigationStack {
            ScrollView {
              VStack(alignment: .leading, spacing: 16) {
                Text("Type a formula or write it with Apple Pencil. Review the symbols, counts, and charge before saving.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Picker("Input method", selection: $inputMode) { ForEach(InputMode.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                    .disabled(isRecognizing)
                if inputMode == .keyboard {
                    TextField("e.g. C6H12O6 or SO4^2-", text: $draft.sourceText)
                        .textFieldStyle(.roundedBorder).font(.title3.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Formula source").accessibilityIdentifier("chemistry.formulaInput")
                    ScrollView(.horizontal) {
                        HStack {
                            exampleButton("Water", formula: "H2O")
                            exampleButton("Glucose", formula: "C6H12O6")
                            exampleButton("Calcium hydroxide", formula: "Ca(OH)2")
                            exampleButton("Sulfate ion", formula: "SO4^2-")
                            exampleButton("Hydrate", formula: "CuSO4·5H2O")
                        }.buttonStyle(.bordered).font(.subheadline)
                    }
                }
                else { handwritingEditor }
                if needsRecognitionReview {
                    Label("Review the recognized text: O and 0, l and 1, subscripts, and charges can be confused.", systemImage: "text.badge.checkmark")
                        .font(.subheadline).foregroundStyle(.orange)
                }
                formulaPreview
                VStack(alignment: .leading, spacing: 8) {
                    Text("How to type chemistry").font(.headline)
                    Text("Use capitals carefully: Co is cobalt; CO is carbon and oxygen. Put counts after atoms or groups: H2O, Ca(OH)2. Use a dot for hydrates: CuSO4·5H2O. Put charges after ^: Fe^3+, SO4^2-. Parentheses and square brackets can be nested.")
                    Text("This checks formula notation and counts atoms. It does not identify the substance or prove that it is chemically stable. A formula does not uniquely describe a 3D molecule.")
                        .foregroundStyle(.secondary)
                }.font(.subheadline)
              }.padding(18)
            }
            .navigationTitle("Molecular Formula")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isRecognizing) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(parsedResult == nil || isRecognizing).accessibilityIdentifier("chemistry.saveFormula") }
            }
        }
        .alert("Couldn’t Recognize Formula", isPresented: Binding(get: { recognitionError != nil }, set: { if !$0 { recognitionError = nil } })) { Button("OK", role: .cancel) {} } message: { Text(recognitionError ?? "Unknown error") }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isRecognizing)
    }

    private func exampleButton(_ title: String, formula: String) -> some View {
        Button(title) { draft.sourceText = formula; draft.recognitionConfidence = nil; needsRecognitionReview = false }
    }

    private var handwritingEditor: some View {
        VStack(spacing: 10) {
            FormulaHandwritingCanvas(drawing: $drawing).frame(height: 260).background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay { RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.35)) }.disabled(isRecognizing)
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
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal) { Text(result.formatted).font(.system(size: 38, weight: .medium)).accessibilityIdentifier("chemistry.formulaPreview") }
                Text("\(result.atomCount) atoms total · Net charge: \(result.charge > 0 ? "+" : "")\(result.charge)").font(.subheadline)
                Text(result.elementCounts.keys.sorted().map { "\($0): \(result.elementCounts[$0, default: 0])" }.joined(separator: "   ·   "))
                    .font(.subheadline.monospaced()).accessibilityIdentifier("chemistry.atomCounts")
                Text("Counts include all groups and hydrate coefficients.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
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
            do { draft.sourceText = try await FormulaHandwritingRecognizer.recognize(cgImage); draft.recognitionConfidence = nil; needsRecognitionReview = true; inputMode = .keyboard }
            catch { recognitionError = error.localizedDescription }
        }
    }

    private func handwritingImage() -> UIImage? {
        guard !drawing.strokes.isEmpty else { return nil }
        let bounds = drawing.bounds.insetBy(dx: -16, dy: -16)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(2, 2048 / max(bounds.width, bounds.height))
        return drawing.image(from: bounds, scale: scale)
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
