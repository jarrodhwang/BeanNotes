//
//  CodeSnippetEditorView.swift
//  BeanNotes
//

import Combine
import PencilKit
import SwiftUI
import UIKit
import Vision

struct CodeSnippetEditorSheet: View {
    private enum Constants {
        static let maximumCodeUTF16Length = CodeSyntaxHighlighter.maximumHighlightedUTF16Length
        static let minimumFontSize = CodeSnippetPreferences.supportedFontSize.lowerBound
        static let maximumFontSize = CodeSnippetPreferences.supportedFontSize.upperBound
        static let defaultFontSize = CodeSnippetPreferences.defaultFontSize
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var draft: CodeSnippetDraft
    @State private var handwritingDrawing = PKDrawing()
    @State private var isShowingConfiguration = false
    @State private var isConvertingHandwriting = false
    @State private var conversionErrorMessage: String?
    @State private var editorNotice: String?
    @State private var pasteRequest = 0

    private let onSave: (CodeSnippetDraft) -> Bool

    init(
        initialDraft: CodeSnippetDraft,
        onSave: @escaping (CodeSnippetDraft) -> Bool
    ) {
        var normalizedDraft = initialDraft
        normalizedDraft.code = codeSnippetText(
            initialDraft.code,
            limitedToUTF16Length: Constants.maximumCodeUTF16Length
        )
        normalizedDraft.fontSize = Self.normalizedFontSize(initialDraft.fontSize)

        _draft = State(initialValue: normalizedDraft)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                editorHeader
                inputModePicker
                editorContent
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .navigationTitle("Code Snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isConvertingHandwriting)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .sheet(isPresented: $isShowingConfiguration) {
            CodeSnippetConfigurationSheet(draft: $draft)
        }
        .alert(
            "Couldn’t Convert Handwriting",
            isPresented: Binding(
                get: { conversionErrorMessage != nil },
                set: { if !$0 { conversionErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(conversionErrorMessage ?? "The handwriting could not be converted to code.")
        }
        .interactiveDismissDisabled(isConvertingHandwriting)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var editorHeader: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(CodeSnippetLanguage.allCases) { language in
                    Button {
                        draft.language = language
                    } label: {
                        Text(language.label)

                        if draft.language == language {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            } label: {
                Label(draft.language.label, systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.headline)
                    .lineLimit(1)
            }
            .accessibilityLabel("Code language")
            .accessibilityValue(draft.language.label)

            Spacer(minLength: 8)

            Button {
                isShowingConfiguration = true
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Code snippet appearance")
            .accessibilityHint("Choose the code font, font size, and background")
        }
        .padding(.top, 8)
    }

    private var inputModePicker: some View {
        Picker("Input method", selection: $draft.preferredInputMode) {
            ForEach(CodeSnippetInputMode.allCases) { inputMode in
                Text(inputMode.label)
                    .tag(inputMode)
            }
        }
        .pickerStyle(.segmented)
        .disabled(isConvertingHandwriting)
        .accessibilityLabel("Code input method")
        .accessibilityValue(draft.preferredInputMode.label)
    }

    @ViewBuilder
    private var editorContent: some View {
        switch draft.preferredInputMode {
        case .handwriting:
            handwritingEditor
        case .text:
            textEditor
        }
    }

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Edit Code")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text("\(draft.code.utf16.count.formatted()) / \(Constants.maximumCodeUTF16Length.formatted())")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(draft.code.utf16.count) of \(Constants.maximumCodeUTF16Length) characters")

                Button {
                    requestPaste()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Pastes plain text at the insertion point")
            }

            CodeSyntaxTextView(
                text: $draft.code,
                language: draft.language,
                font: draft.font,
                fontSize: draft.fontSize,
                palette: syntaxPalette,
                maximumUTF16Length: Constants.maximumCodeUTF16Length,
                pasteRequest: pasteRequest,
                onLengthLimitReached: showLengthLimitNotice
            )
            .frame(maxWidth: .infinity, minHeight: 330)
            .codeSnippetSurface(palette: syntaxPalette)
            .clipShape(RoundedRectangle(cornerRadius: CodeSnippetLayout.cornerRadius, style: .continuous))

            if let editorNotice {
                Label(editorNotice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(editorNotice)
            } else {
                Text("Code is stored as plain text and is never executed by BeanNotes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var handwritingEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Write with Apple Pencil")
                        .font(.subheadline.weight(.semibold))

                    Text("Vision will convert the selected handwriting into editable code text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button("Clear", role: .destructive) {
                    handwritingDrawing = PKDrawing()
                    conversionErrorMessage = nil
                }
                .disabled(handwritingDrawing.strokes.isEmpty || isConvertingHandwriting)
                .accessibilityHint("Removes all handwriting from this code snippet")
            }

            CodeSnippetHandwritingCanvas(
                drawing: $handwritingDrawing,
                inkColor: codeForegroundColor
            )
            .frame(maxWidth: .infinity, minHeight: 330)
            .codeSnippetSurface(palette: syntaxPalette)
            .clipShape(RoundedRectangle(cornerRadius: CodeSnippetLayout.cornerRadius, style: .continuous))

            Button {
                convertHandwritingToCode()
            } label: {
                HStack(spacing: 8) {
                    if isConvertingHandwriting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "text.viewfinder")
                    }

                    Text(isConvertingHandwriting ? "Converting…" : "Convert to Code")
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(handwritingDrawing.strokes.isEmpty || isConvertingHandwriting)
            .accessibilityLabel(isConvertingHandwriting ? "Converting handwriting" : "Convert handwriting to code")
            .accessibilityHint("Keeps the handwriting if recognition is unsuccessful")
        }
    }

    private var canSave: Bool {
        !isConvertingHandwriting
            && !draft.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var codeForegroundColor: UIColor {
        syntaxPalette.foregroundColor
    }

    private var syntaxPalette: CodeSnippetSyntaxPalette {
        draft.syntaxPalette(for: colorScheme == .dark ? .dark : .light)
    }

    private func requestPaste() {
        guard UIPasteboard.general.hasStrings else {
            editorNotice = "The clipboard does not contain text."
            UIAccessibility.post(notification: .announcement, argument: editorNotice)
            return
        }

        editorNotice = nil
        pasteRequest &+= 1
    }

    private func showLengthLimitNotice() {
        editorNotice = "Code snippets are limited to \(Constants.maximumCodeUTF16Length.formatted()) characters."
        UIAccessibility.post(notification: .announcement, argument: editorNotice)
    }

    private func convertHandwritingToCode() {
        conversionErrorMessage = nil

        guard let image = Self.handwritingImage(from: handwritingDrawing),
              let cgImage = image.cgImage else {
            conversionErrorMessage = CodeSnippetHandwritingError.renderFailed.localizedDescription
            return
        }

        isConvertingHandwriting = true
        let imageReference = CodeSnippetCGImageReference(cgImage)
        let languageCustomWords = draft.language.visionCustomWords

        Task {
            defer { isConvertingHandwriting = false }

            do {
                let recognizedCode = try await CodeSnippetHandwritingRecognizer.recognizeCode(
                    in: imageReference,
                    customWords: languageCustomWords
                )
                let limitedCode = codeSnippetText(
                    recognizedCode,
                    limitedToUTF16Length: Constants.maximumCodeUTF16Length
                )

                if (limitedCode as NSString).length < (recognizedCode as NSString).length {
                    showLengthLimitNotice()
                }

                draft.code = limitedCode
                // Keep the source drawing in memory so switching back to Handwriting does
                // not make a successful conversion destructive.
                draft.preferredInputMode = .text
                UIAccessibility.post(notification: .announcement, argument: "Handwriting converted to editable code")
            } catch is CancellationError {
                return
            } catch {
                // Never clear or replace the PencilKit drawing when recognition fails.
                conversionErrorMessage = error.localizedDescription
                UIAccessibility.post(notification: .announcement, argument: "Handwriting conversion failed")
            }
        }
    }

    private func save() {
        draft.code = codeSnippetText(
            draft.code,
            limitedToUTF16Length: Constants.maximumCodeUTF16Length
        )
        draft.fontSize = Self.normalizedFontSize(draft.fontSize)
        if onSave(draft) {
            dismiss()
        }
    }

    private static func normalizedFontSize(_ fontSize: Double) -> Double {
        guard fontSize.isFinite else { return Constants.defaultFontSize }
        return min(max(fontSize, Constants.minimumFontSize), Constants.maximumFontSize)
    }

    fileprivate static func handwritingImage(from drawing: PKDrawing) -> UIImage? {
        let drawingBounds = drawing.bounds
        guard !drawing.strokes.isEmpty,
              !drawingBounds.isNull,
              !drawingBounds.isInfinite,
              !drawingBounds.isEmpty,
              drawingBounds.minX.isFinite,
              drawingBounds.minY.isFinite,
              drawingBounds.width.isFinite,
              drawingBounds.height.isFinite else {
            return nil
        }

        let paddedBounds = drawingBounds.insetBy(dx: -18, dy: -18)
        let longestSide = max(paddedBounds.width, paddedBounds.height)
        let scale = min(3, max(1, 4_096 / max(longestSide, 1)))
        let drawingImage = drawing.image(from: paddedBounds, scale: scale)

        // Normalize every ink color to black on white before OCR. PencilKit exports a
        // transparent image, and transparent black ink can otherwise become invisible
        // to Vision; normalization also keeps recognition stable when the user changes
        // between light and dark snippet backgrounds after writing.
        let format = UIGraphicsImageRendererFormat()
        format.scale = drawingImage.scale
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: drawingImage.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: drawingImage.size))
            drawingImage
                .withTintColor(.black, renderingMode: .alwaysTemplate)
                .draw(in: CGRect(origin: .zero, size: drawingImage.size))
        }
    }
}

/// An editor that lives inside the code attachment on the note canvas. It keeps the
/// source where the user is working instead of moving typing, paste, or Pencil input
/// into a separate sheet.
struct CodeSnippetInlineEditor: View {
    private enum Constants {
        static let maximumCodeUTF16Length = CodeSyntaxHighlighter.maximumHighlightedUTF16Length
    }

    @State private var draft: CodeSnippetDraft
    @State private var handwritingDrawing = PKDrawing()
    @State private var isConvertingHandwriting = false
    @State private var errorMessage: String?
    @State private var pasteRequest = 0

    let isDarkAppearance: Bool
    let onSave: (CodeSnippetDraft) -> Bool
    let onCancel: () -> Void

    init(
        draft: CodeSnippetDraft,
        isDarkAppearance: Bool,
        onSave: @escaping (CodeSnippetDraft) -> Bool,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: draft)
        self.isDarkAppearance = isDarkAppearance
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: 38)
                .padding(.horizontal, 8)

            Divider()
                .overlay(foregroundColor.opacity(0.18))

            Group {
                if draft.preferredInputMode == .text {
                    CodeSyntaxTextView(
                        text: $draft.code,
                        language: draft.language,
                        font: draft.font,
                        fontSize: draft.fontSize,
                        palette: syntaxPalette,
                        maximumUTF16Length: Constants.maximumCodeUTF16Length,
                        pasteRequest: pasteRequest,
                        shouldFocusOnAppear: true,
                        onLengthLimitReached: {
                            errorMessage = "Code snippets are limited to \(Constants.maximumCodeUTF16Length.formatted()) characters."
                        }
                    )
                    .accessibilityIdentifier("codeSnippet.inline.textEditor")
                } else {
                    ZStack(alignment: .bottomTrailing) {
                        CodeSnippetHandwritingCanvas(
                            drawing: $handwritingDrawing,
                            inkColor: foregroundUIColor
                        )
                        .accessibilityIdentifier("codeSnippet.inline.handwriting")

                        Button {
                            convertHandwritingToCode()
                        } label: {
                            if isConvertingHandwriting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Convert to Code", systemImage: "text.viewfinder")
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(10)
                        .disabled(handwritingDrawing.strokes.isEmpty || isConvertingHandwriting)
                        .accessibilityHint("Converts Pencil handwriting into editable code text")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(foregroundColor)
        .background(backgroundColor)
        .overlay {
            RoundedRectangle(cornerRadius: CodeSnippetLayout.cornerRadius, style: .continuous)
                .stroke(foregroundColor.opacity(0.2), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: CodeSnippetLayout.cornerRadius, style: .continuous))
        .alert(
            "Code Snippet",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unable to update the code snippet.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(CodeSnippetLanguage.allCases) { language in
                    Button {
                        draft.language = language
                    } label: {
                        if draft.language == language {
                            Label(language.label, systemImage: "checkmark")
                        } else {
                            Text(language.label)
                        }
                    }
                }
            } label: {
                Label(draft.language.label, systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.caption.weight(.semibold))
                    .imageScale(.small)
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Code language")
            .accessibilityValue(draft.language.label)
            .accessibilityIdentifier("codeSnippet.inline.language")

            Spacer(minLength: 4)

            inputButton(.handwriting, systemImage: "pencil.tip")
            inputButton(.text, systemImage: "keyboard")
            appearanceMenu

            if draft.preferredInputMode == .text {
                Button {
                    guard UIPasteboard.general.hasStrings else {
                        errorMessage = "The clipboard does not contain text."
                        return
                    }
                    pasteRequest &+= 1
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .accessibilityLabel("Paste code")
                .accessibilityHint("Pastes plain text at the insertion point")
            }

            Button(action: onCancel) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Cancel code editing")

            Button {
                let limitedCode = codeSnippetText(
                    draft.code,
                    limitedToUTF16Length: Constants.maximumCodeUTF16Length
                )
                draft.code = limitedCode
                if !onSave(draft) {
                    errorMessage = "BeanNotes could not save the code snippet."
                }
            } label: {
                Image(systemName: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isConvertingHandwriting)
            .accessibilityLabel("Save code snippet")
        }
        .font(.subheadline.weight(.semibold))
    }

    private var appearanceMenu: some View {
        Menu {
            Section("Background") {
                ForEach(CodeSnippetBackgroundStyle.allCases) { style in
                    Button {
                        draft.backgroundStyle = style
                    } label: {
                        if draft.backgroundStyle == style {
                            Label(style.label, systemImage: "checkmark")
                        } else {
                            Text(style.label)
                        }
                    }
                }
            }

            Section("Syntax Theme") {
                ForEach(CodeSnippetSyntaxTheme.allCases) { theme in
                    Button {
                        draft.syntaxTheme = theme
                    } label: {
                        if draft.syntaxTheme == theme {
                            Label(theme.label, systemImage: "checkmark")
                        } else {
                            Text(theme.label)
                        }
                    }
                }
            }

            Section("Font") {
                ForEach(CodeSnippetFontChoice.allCases) { font in
                    Button {
                        draft.font = font
                    } label: {
                        if draft.font == font {
                            Label(font.label, systemImage: "checkmark")
                        } else {
                            Text(font.label)
                        }
                    }
                }

                Menu("Font Size") {
                    ForEach(Array(stride(from: 10, through: 32, by: 2)), id: \.self) { size in
                        Button {
                            draft.fontSize = Double(size)
                        } label: {
                            if Int(draft.fontSize.rounded()) == size {
                                Label("\(size) pt", systemImage: "checkmark")
                            } else {
                                Text("\(size) pt")
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Code appearance")
        .accessibilityHint("Changes the box appearance, syntax theme, font, and font size")
    }

    private func inputButton(
        _ mode: CodeSnippetInputMode,
        systemImage: String
    ) -> some View {
        Button {
            draft.preferredInputMode = mode
        } label: {
            Image(systemName: systemImage)
                .frame(width: 20, height: 20)
                .background(
                    draft.preferredInputMode == mode
                        ? foregroundColor.opacity(0.14)
                        : .clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .accessibilityLabel(mode.label)
        .accessibilityAddTraits(draft.preferredInputMode == mode ? .isSelected : [])
    }

    private var backgroundColor: Color {
        Color(uiColor: syntaxPalette.backgroundColor)
    }

    private var foregroundColor: Color {
        Color(uiColor: syntaxPalette.foregroundColor)
    }

    private var foregroundUIColor: UIColor {
        syntaxPalette.foregroundColor
    }

    private var syntaxPalette: CodeSnippetSyntaxPalette {
        draft.syntaxPalette(for: isDarkAppearance ? .dark : .light)
    }

    private func convertHandwritingToCode() {
        guard let image = CodeSnippetEditorSheet.handwritingImage(from: handwritingDrawing),
              let cgImage = image.cgImage else {
            errorMessage = CodeSnippetHandwritingError.renderFailed.localizedDescription
            return
        }

        isConvertingHandwriting = true
        let imageReference = CodeSnippetCGImageReference(cgImage)
        let languageCustomWords = draft.language.visionCustomWords
        Task {
            defer { isConvertingHandwriting = false }
            do {
                draft.code = codeSnippetText(
                    try await CodeSnippetHandwritingRecognizer.recognizeCode(
                        in: imageReference,
                        customWords: languageCustomWords
                    ),
                    limitedToUTF16Length: Constants.maximumCodeUTF16Length
                )
                draft.preferredInputMode = .text
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "Handwriting converted to editable code"
                )
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Lightweight editor mounted directly over a selected snippet on the note canvas.
/// UITextView supplies both keyboard editing and Apple Pencil Scribble, while the
/// surrounding UIKit selection overlay owns moving, resizing, and configuration.
@MainActor
final class CodeSnippetCanvasEditingState: ObservableObject {
    @Published var draft: CodeSnippetDraft
    @Published private(set) var isDarkAppearance: Bool

    init(draft: CodeSnippetDraft, isDarkAppearance: Bool = false) {
        self.draft = draft
        self.isDarkAppearance = isDarkAppearance
    }

    func updateAppearance(isDark: Bool) {
        guard isDarkAppearance != isDark else { return }
        isDarkAppearance = isDark
    }
}

struct CodeSnippetCanvasEditor: View {
    @ObservedObject var editingState: CodeSnippetCanvasEditingState

    let onDraftChanged: (CodeSnippetDraft) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: CodeSnippetLayout.headerControlSpacing) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        width: CodeSnippetLayout.codeIconWidth,
                        height: CodeSnippetLayout.codeIconSize
                    )
                    .foregroundStyle(Color(uiColor: syntaxPalette.headerTextColor))

                Text(editingState.draft.language.label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(Color(uiColor: syntaxPalette.headerTextColor))
                    .padding(.horizontal, CodeSnippetLayout.languageChipHorizontalPadding)
                    .frame(
                        minWidth: CodeSnippetLayout.languageChipMinimumWidth,
                        minHeight: CodeSnippetLayout.languageChipHeight
                    )
                    .background(
                        Color(uiColor: syntaxPalette.pillColor),
                        in: Capsule()
                    )
                    .overlay {
                        Capsule()
                            .stroke(
                                Color(uiColor: syntaxPalette.pillBorderColor),
                                lineWidth: 1
                            )
                    }

                Spacer(minLength: 4)
            }
            .frame(height: CodeSnippetLayout.headerHeight)
            .padding(.leading, CodeSnippetLayout.headerHorizontalPadding)
            // The selection overlay draws the real settings affordance here.
            .padding(.trailing, CodeSnippetLayout.settingsReservedWidth)

            Divider()
                .frame(height: CodeSnippetLayout.headerSeparatorHeight)
                .overlay(Color(uiColor: syntaxPalette.separatorColor))

            ZStack(alignment: .topLeading) {
                CodeSyntaxTextView(
                    text: $editingState.draft.code,
                    language: editingState.draft.language,
                    font: editingState.draft.font,
                    fontSize: editingState.draft.fontSize,
                    palette: syntaxPalette,
                    maximumUTF16Length: CodeSyntaxHighlighter.maximumHighlightedUTF16Length,
                    pasteRequest: 0,
                    // The first tap selects the box only. A later tap in this text view
                    // places the cursor and presents the keyboard in the normal UIKit way.
                    shouldFocusOnAppear: false,
                    onLengthLimitReached: {
                        UIAccessibility.post(
                            notification: .announcement,
                            argument: "Code snippets are limited to \(CodeSyntaxHighlighter.maximumHighlightedUTF16Length.formatted()) characters."
                        )
                    }
                )
                .accessibilityIdentifier("codeSnippet.inline.textEditor")

                if editingState.draft.code.isEmpty {
                    Text("Tap to type or write with Apple Pencil")
                        .font(Font(editingState.draft.font.uiFont(
                            size: CGFloat(editingState.draft.fontSize)
                        )))
                        .foregroundStyle(foregroundColor.opacity(0.38))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 17)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .foregroundStyle(foregroundColor)
        .background(backgroundColor)
        .overlay {
            RoundedRectangle(cornerRadius: CodeSnippetLayout.cornerRadius, style: .continuous)
                .stroke(Color(uiColor: syntaxPalette.borderColor), lineWidth: 1)
        }
        .clipShape(
            RoundedRectangle(cornerRadius: CodeSnippetLayout.cornerRadius, style: .continuous)
        )
        .onChange(of: editingState.draft) { _, draft in
            onDraftChanged(draft)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editable \(editingState.draft.language.label) code snippet")
        .accessibilityHint("Type with the keyboard or use Apple Pencil Scribble. Drag the header to move and drag an edge to resize.")
    }

    private var backgroundColor: Color {
        Color(uiColor: syntaxPalette.backgroundColor)
    }

    private var foregroundColor: Color {
        Color(uiColor: syntaxPalette.foregroundColor)
    }

    private var syntaxPalette: CodeSnippetSyntaxPalette {
        editingState.draft.syntaxPalette(
            for: editingState.isDarkAppearance ? .dark : .light
        )
    }
}

private struct CodeSnippetConfigurationSheet: View {
    @Binding var draft: CodeSnippetDraft
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Font") {
                    Picker("Typeface", selection: $draft.font) {
                        ForEach(CodeSnippetFontChoice.allCases) { font in
                            Text(font.label)
                                .tag(font)
                        }
                    }

                    HStack {
                        Text("Font Size")
                        Spacer()
                        Text("\(Int(draft.fontSize.rounded())) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Slider(
                        value: $draft.fontSize,
                        in: CodeSnippetPreferences.supportedFontSize,
                        step: 1
                    ) {
                        Text("Font Size")
                    } minimumValueLabel: {
                        Text("\(Int(CodeSnippetPreferences.supportedFontSize.lowerBound))")
                    } maximumValueLabel: {
                        Text("\(Int(CodeSnippetPreferences.supportedFontSize.upperBound))")
                    }
                    .accessibilityValue("\(Int(draft.fontSize.rounded())) points")
                }

                Section("Box Appearance") {
                    Picker("Appearance", selection: $draft.backgroundStyle) {
                        ForEach(CodeSnippetBackgroundStyle.allCases) { style in
                            Text(style.label)
                                .tag(style)
                        }
                    }

                    Text("App Appearance follows this choice when the syntax theme is adaptive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Syntax Theme") {
                    Picker("Theme", selection: $draft.syntaxTheme) {
                        ForEach(CodeSnippetSyntaxTheme.allCases) { theme in
                            Text(theme.label)
                                .tag(theme)
                        }
                    }

                    Text("Named themes include their own editor background and token colors.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Preview") {
                    Text(previewText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .codeSnippetSurface(palette: previewPalette)
                }
            }
            .navigationTitle("Code Appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var previewPalette: CodeSnippetSyntaxPalette {
        draft.syntaxPalette(for: colorScheme == .dark ? .dark : .light)
    }

    private var previewText: AttributedString {
        AttributedString(
            CodeSyntaxHighlighter.attributedString(
                for: "let answer = 42 // syntax preview",
                language: .javaScript,
                font: draft.font.uiFont(size: CGFloat(draft.fontSize)),
                palette: previewPalette
            )
        )
    }
}

private struct CodeSyntaxTextView: UIViewRepresentable {
    @Binding var text: String

    var language: CodeSnippetLanguage
    var font: CodeSnippetFontChoice
    var fontSize: Double
    var palette: CodeSnippetSyntaxPalette
    var maximumUTF16Length: Int
    var pasteRequest: Int
    var shouldFocusOnAppear = false
    var onLengthLimitReached: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = CodeSyntaxUITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = palette.backgroundColor
        textView.isOpaque = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsEditingTextAttributes = false
        textView.dataDetectorTypes = []
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardDismissMode = .interactive
        textView.alwaysBounceVertical = true
        textView.alwaysBounceHorizontal = true
        textView.showsHorizontalScrollIndicator = true
        textView.textContainerInset = UIEdgeInsets(
            top: CodeSnippetLayout.codeTopPadding,
            left: CodeSnippetLayout.codeHorizontalPadding,
            bottom: CodeSnippetLayout.codeBottomPadding,
            right: CodeSnippetLayout.codeHorizontalPadding
        )
        textView.textContainer.lineFragmentPadding = 0
        // The flattened preview clips long code lines instead of wrapping them.
        // Match that policy while selected and let the editor scroll horizontally.
        textView.enforceNonWrappingTextContainer()
        textView.textContainer.lineBreakMode = .byClipping
        textView.semanticContentAttribute = .forceLeftToRight
        textView.textAlignment = .left
        textView.accessibilityLabel = "Code editor"
        textView.accessibilityHint = "Type, paste, or use Apple Pencil Scribble to edit plain-text code"

        context.coordinator.configure(parent: self, textView: textView)
        _ = context.coordinator.replaceTextIfNeeded(in: textView, with: text)
        context.coordinator.applyHighlighting(to: textView)
        if shouldFocusOnAppear {
            DispatchQueue.main.async {
                textView.becomeFirstResponder()
            }
        }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        (textView as? CodeSyntaxUITextView)?.enforceNonWrappingTextContainer()
        let coordinator = context.coordinator
        let configurationChanged = coordinator.configure(parent: self, textView: textView)
        let textChanged = coordinator.replaceTextIfNeeded(in: textView, with: text)
        if configurationChanged || textChanged {
            coordinator.applyHighlighting(to: textView)
        }

        guard pasteRequest != coordinator.lastHandledPasteRequest else { return }
        coordinator.lastHandledPasteRequest = pasteRequest

        DispatchQueue.main.async { [weak textView, weak coordinator] in
            guard let textView, let coordinator else { return }
            textView.becomeFirstResponder()
            textView.paste(nil)
            coordinator.publishTextAndHighlight(from: textView)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeSyntaxTextView
        var lastHandledPasteRequest: Int

        private weak var textView: UITextView?
        private var highlightingWorkItem: DispatchWorkItem?
        private var isApplyingProgrammaticText = false
        private var isApplyingHighlighting = false
        private var highlightingPendingAfterMarkedText = false
        private var configurationSignature = ""
        private let immediateHighlightMaximumUTF16Length = 12_000
        private var lastStableText: String
        private var pendingMarkedEditContext: CodeSnippetMarkedEditContext?

        init(parent: CodeSyntaxTextView) {
            self.parent = parent
            self.lastHandledPasteRequest = parent.pasteRequest
            self.lastStableText = codeSnippetText(
                parent.text,
                limitedToUTF16Length: parent.maximumUTF16Length
            )
        }

        deinit {
            highlightingWorkItem?.cancel()
        }

        @discardableResult
        func configure(parent: CodeSyntaxTextView, textView: UITextView) -> Bool {
            self.parent = parent
            self.textView = textView

            let nextSignature = [
                parent.language.rawValue,
                parent.font.rawValue,
                String(parent.fontSize),
                parent.palette.id,
                parent.palette.foregroundColor.description,
                parent.palette.backgroundColor.description
            ].joined(separator: "|")
            guard configurationSignature != nextSignature else { return false }
            configurationSignature = nextSignature

            // Do not touch these properties for text-only SwiftUI updates. Updating
            // `textColor` on every binding publish erases token colors until the
            // delayed highlighter runs, which is the white/color flicker users saw.
            let resolvedFont = parent.font.uiFont(size: CGFloat(parent.fontSize))
            let keyboardAppearance: UIKeyboardAppearance = parent.palette.isDark
                ? .dark
                : .light
            let keyboardAppearanceChanged = textView.keyboardAppearance != keyboardAppearance
            let paragraphStyle = CodeSnippetLayout.codeParagraphStyle(font: resolvedFont)
            textView.font = resolvedFont
            textView.textColor = parent.palette.foregroundColor
            textView.tintColor = parent.palette.caretColor
            textView.backgroundColor = parent.palette.backgroundColor
            textView.keyboardAppearance = keyboardAppearance
            textView.overrideUserInterfaceStyle = parent.palette.isDark ? .dark : .light
            textView.typingAttributes = [
                .font: resolvedFont,
                .foregroundColor: parent.palette.foregroundColor,
                .paragraphStyle: paragraphStyle
            ]
            if keyboardAppearanceChanged, textView.isFirstResponder {
                textView.reloadInputViews()
            }
            return true
        }

        @discardableResult
        func replaceTextIfNeeded(in textView: UITextView, with proposedText: String) -> Bool {
            // SwiftUI's binding intentionally trails active CJK/IME composition.
            // Never replace marked text with that older value during an unrelated
            // palette/layout update.
            guard textView.markedTextRange == nil else {
                if let markedRange = codeSnippetMarkedTextRange(in: textView) {
                    pendingMarkedEditContext = codeSnippetMarkedEditContext(
                        currentText: textView.text ?? "",
                        stableText: lastStableText,
                        markedRange: markedRange
                    )
                }
                return false
            }
            let limitedText = codeSnippetText(
                proposedText,
                limitedToUTF16Length: parent.maximumUTF16Length
            )
            guard textView.text != limitedText else {
                lastStableText = limitedText
                return false
            }

            isApplyingProgrammaticText = true
            let selectedRange = textView.selectedRange
            textView.text = limitedText
            textView.selectedRange = NSRange(
                location: min(selectedRange.location, textView.textStorage.length),
                length: 0
            )
            isApplyingProgrammaticText = false
            lastStableText = limitedText
            pendingMarkedEditContext = nil
            return true
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            guard textView.markedTextRange == nil else { return true }
            guard range.location <= textView.textStorage.length,
                  NSMaxRange(range) <= textView.textStorage.length else {
                return false
            }

            let replacementLength = (replacement as NSString).length
            let proposedLength = textView.textStorage.length - range.length + replacementLength
            guard proposedLength > parent.maximumUTF16Length else { return true }

            let availableLength = max(
                parent.maximumUTF16Length - (textView.textStorage.length - range.length),
                0
            )
            let limitedReplacement = codeSnippetText(
                replacement,
                limitedToUTF16Length: availableLength
            )

            if !limitedReplacement.isEmpty || range.length > 0 {
                isApplyingProgrammaticText = true
                textView.textStorage.replaceCharacters(in: range, with: limitedReplacement)
                textView.selectedRange = NSRange(
                    location: range.location + (limitedReplacement as NSString).length,
                    length: 0
                )
                isApplyingProgrammaticText = false
                publishTextAndHighlight(from: textView)
            }

            parent.onLengthLimitReached()
            return false
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingProgrammaticText,
                  !isApplyingHighlighting else {
                return
            }
            guard textView.markedTextRange == nil else {
                highlightingPendingAfterMarkedText = true
                if let markedRange = codeSnippetMarkedTextRange(in: textView) {
                    pendingMarkedEditContext = codeSnippetMarkedEditContext(
                        currentText: textView.text ?? "",
                        stableText: lastStableText,
                        markedRange: markedRange
                    )
                }
                return
            }

            if textView.textStorage.length > parent.maximumUTF16Length {
                applyLengthLimit(to: textView)
                parent.onLengthLimitReached()
            }

            publishTextAndHighlight(from: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard highlightingPendingAfterMarkedText,
                  textView.markedTextRange == nil,
                  !isApplyingProgrammaticText,
                  !isApplyingHighlighting else {
                return
            }
            highlightingPendingAfterMarkedText = false
            publishTextAndHighlight(from: textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            guard highlightingPendingAfterMarkedText || parent.text != textView.text else {
                return
            }
            highlightingPendingAfterMarkedText = false
            publishTextAndHighlight(from: textView)
        }

        func publishTextAndHighlight(from textView: UITextView) {
            guard textView.markedTextRange == nil else {
                highlightingPendingAfterMarkedText = true
                return
            }
            highlightingPendingAfterMarkedText = false
            if textView.textStorage.length > parent.maximumUTF16Length {
                applyLengthLimit(to: textView)
                parent.onLengthLimitReached()
            }
            let nextText = textView.text ?? ""
            if textView.textStorage.length <= immediateHighlightMaximumUTF16Length {
                highlightingWorkItem?.cancel()
                applyHighlighting(to: textView)
            } else {
                scheduleHighlighting(for: textView, delay: 0.06)
            }
            lastStableText = nextText
            pendingMarkedEditContext = nil
            if parent.text != nextText {
                parent.text = nextText
            }
        }

        private func applyLengthLimit(to textView: UITextView) {
            let boundedEdit: CodeSnippetBoundedEdit
            if let pendingMarkedEditContext {
                boundedEdit = codeSnippetBoundedMarkedEdit(
                    currentText: textView.text ?? "",
                    context: pendingMarkedEditContext,
                    selectedRange: textView.selectedRange,
                    maximumUTF16Length: parent.maximumUTF16Length
                )
            } else {
                boundedEdit = codeSnippetBoundedEdit(
                    currentText: textView.text ?? "",
                    stableText: lastStableText,
                    selectedRange: textView.selectedRange,
                    maximumUTF16Length: parent.maximumUTF16Length
                )
            }
            isApplyingProgrammaticText = true
            textView.text = boundedEdit.text
            textView.selectedRange = boundedEdit.selectedRange
            isApplyingProgrammaticText = false
            pendingMarkedEditContext = nil
        }

        func scheduleHighlighting(for textView: UITextView, delay: TimeInterval) {
            highlightingWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.applyHighlighting(to: textView)
            }
            highlightingWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        func applyHighlighting(to textView: UITextView) {
            guard !isApplyingProgrammaticText else { return }
            guard textView.markedTextRange == nil else {
                highlightingPendingAfterMarkedText = true
                return
            }

            let code = textView.text ?? ""
            let resolvedFont = parent.font.uiFont(size: CGFloat(parent.fontSize))
            let highlighted = CodeSyntaxHighlighter.attributedString(
                for: code,
                language: parent.language,
                font: resolvedFont,
                palette: parent.palette
            )
            guard highlighted.string == code,
                  highlighted.length == textView.textStorage.length else {
                return
            }

            let selectedRange = textView.selectedRange
            let wholeRange = NSRange(location: 0, length: textView.textStorage.length)
            isApplyingHighlighting = true
            textView.textStorage.beginEditing()
            textView.textStorage.addAttributes(
                [
                    .font: resolvedFont,
                    .foregroundColor: parent.palette.foregroundColor,
                    .paragraphStyle: CodeSnippetLayout.codeParagraphStyle(font: resolvedFont)
                ],
                range: wholeRange
            )
            highlighted.enumerateAttribute(
                .foregroundColor,
                in: NSRange(location: 0, length: highlighted.length),
                options: []
            ) { color, range, _ in
                guard let color else { return }
                textView.textStorage.addAttribute(
                    .foregroundColor,
                    value: color,
                    range: range
                )
            }
            textView.textStorage.endEditing()
            textView.selectedRange = NSRange(
                location: min(selectedRange.location, textView.textStorage.length),
                length: min(
                    selectedRange.length,
                    max(textView.textStorage.length - min(selectedRange.location, textView.textStorage.length), 0)
                )
            )
            textView.typingAttributes = [
                .font: resolvedFont,
                .foregroundColor: parent.palette.foregroundColor,
                .paragraphStyle: CodeSnippetLayout.codeParagraphStyle(font: resolvedFont)
            ]
            isApplyingHighlighting = false
        }
    }
}

private final class CodeSyntaxUITextView: UITextView {
    // A finite bound avoids TextKit normalizing `greatestFiniteMagnitude` back to
    // the viewport during layout. It comfortably contains the 60k UTF-16 source
    // limit at the largest supported font size in either direction.
    private static let nonWrappingContainerDimension: CGFloat = 4_000_000

    override func layoutSubviews() {
        super.layoutSubviews()
        enforceNonWrappingTextContainer()
    }

    func enforceNonWrappingTextContainer() {
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        let requiredSize = CGSize(
            width: Self.nonWrappingContainerDimension,
            height: Self.nonWrappingContainerDimension
        )
        if textContainer.size != requiredSize {
            textContainer.size = requiredSize
        }
    }
}

private struct CodeSnippetHandwritingCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    var inkColor: UIColor

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvasView = PKCanvasView()
        canvasView.delegate = context.coordinator
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .pencilOnly
        canvasView.tool = PKInkingTool(.pen, color: inkColor, width: 3)
        canvasView.drawing = drawing
        canvasView.accessibilityLabel = "Handwritten code canvas"
        canvasView.accessibilityHint = "Write code with Apple Pencil, then choose Convert to Code"
        canvasView.accessibilityTraits.insert(.allowsDirectInteraction)
        context.coordinator.lastPublishedDrawingData = drawing.dataRepresentation()
        return canvasView
    }

    func updateUIView(_ canvasView: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        canvasView.tool = PKInkingTool(.pen, color: inkColor, width: 3)

        let drawingData = drawing.dataRepresentation()
        guard drawingData != context.coordinator.lastPublishedDrawingData else { return }
        canvasView.drawing = drawing
        context.coordinator.lastPublishedDrawingData = drawingData
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: CodeSnippetHandwritingCanvas
        var lastPublishedDrawingData = Data()

        init(parent: CodeSnippetHandwritingCanvas) {
            self.parent = parent
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let drawing = canvasView.drawing
            lastPublishedDrawingData = drawing.dataRepresentation()
            if parent.drawing.dataRepresentation() != lastPublishedDrawingData {
                parent.drawing = drawing
            }
        }
    }
}

private struct CodeSnippetSurfaceModifier: ViewModifier {
    var palette: CodeSnippetSyntaxPalette

    func body(content: Content) -> some View {
        content
            .background(Color(uiColor: palette.backgroundColor), in: surfaceShape)
        .overlay {
            surfaceShape
                .stroke(Color(uiColor: palette.borderColor), lineWidth: 1)
        }
    }

    private var surfaceShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: CodeSnippetLayout.cornerRadius, style: .continuous)
    }

}

private extension View {
    func codeSnippetSurface(palette: CodeSnippetSyntaxPalette) -> some View {
        modifier(
            CodeSnippetSurfaceModifier(palette: palette)
        )
    }
}

private final class CodeSnippetCGImageReference: @unchecked Sendable {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

private enum CodeSnippetHandwritingRecognizer {
    nonisolated static func recognizeCode(
        in imageReference: CodeSnippetCGImageReference,
        customWords: [String]
    ) async throws -> String {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            // Natural-language correction often changes identifiers, operators, and
            // punctuation, so code conversion intentionally keeps it disabled.
            request.usesLanguageCorrection = false
            request.automaticallyDetectsLanguage = false
            request.customWords = customWords
            request.minimumTextHeight = 0.01

            let handler = VNImageRequestHandler(cgImage: imageReference.image, options: [:])
            try handler.perform([request])
            try Task.checkCancellation()

            let observations = (request.results ?? []).sorted { lhs, rhs in
                let verticalDifference = lhs.boundingBox.midY - rhs.boundingBox.midY
                if abs(verticalDifference) > 0.015 {
                    return verticalDifference > 0
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            let lines = observations.compactMap { observation in
                observation.topCandidates(1).first?.string
            }
            let recognizedCode = lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !recognizedCode.isEmpty else {
                throw CodeSnippetHandwritingError.noRecognizableText
            }
            return recognizedCode
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

private enum CodeSnippetHandwritingError: LocalizedError {
    case renderFailed
    case noRecognizableText

    var errorDescription: String? {
        switch self {
        case .renderFailed:
            "BeanNotes could not prepare the handwriting for recognition. Your drawing is unchanged."
        case .noRecognizableText:
            "No code text was recognized. Your drawing is unchanged so you can adjust it and try again."
        }
    }
}

func codeSnippetText(_ text: String, limitedToUTF16Length limit: Int) -> String {
    guard limit > 0 else { return "" }

    let text = text as NSString
    guard text.length > limit else { return text as String }

    var safeLength = limit
    let finalSequence = text.rangeOfComposedCharacterSequence(at: max(safeLength - 1, 0))
    if NSMaxRange(finalSequence) > safeLength {
        safeLength = finalSequence.location
    }
    return text.substring(to: safeLength)
}

struct CodeSnippetBoundedEdit: Equatable {
    let text: String
    let selectedRange: NSRange
}

struct CodeSnippetMarkedEditContext: Equatable {
    let stableText: String
    let replacementRange: NSRange
}

func codeSnippetMarkedTextRange(in textView: UITextView) -> NSRange? {
    guard let markedTextRange = textView.markedTextRange else { return nil }
    let location = textView.offset(
        from: textView.beginningOfDocument,
        to: markedTextRange.start
    )
    let length = textView.offset(from: markedTextRange.start, to: markedTextRange.end)
    guard location >= 0, length >= 0 else { return nil }
    return NSRange(location: location, length: length)
}

/// Recovers the exact stable range replaced by UIKit's marked text. The length
/// equation avoids ambiguous prefix/suffix diffs when inserted characters match
/// code immediately before or after the composition.
func codeSnippetMarkedEditContext(
    currentText: String,
    stableText: String,
    markedRange: NSRange
) -> CodeSnippetMarkedEditContext? {
    let currentLength = (currentText as NSString).length
    let stableLength = (stableText as NSString).length
    guard markedRange.location >= 0,
          markedRange.length >= 0,
          NSMaxRange(markedRange) <= currentLength else {
        return nil
    }
    let replacedStableLength = stableLength + markedRange.length - currentLength
    guard replacedStableLength >= 0,
          markedRange.location + replacedStableLength <= stableLength else {
        return nil
    }
    return CodeSnippetMarkedEditContext(
        stableText: stableText,
        replacementRange: NSRange(
            location: markedRange.location,
            length: replacedStableLength
        )
    )
}

/// Bounds a known marked-text replacement while preserving every stable character
/// outside that range, including a repeated or identical suffix.
func codeSnippetBoundedMarkedEdit(
    currentText: String,
    context: CodeSnippetMarkedEditContext,
    selectedRange: NSRange,
    maximumUTF16Length limit: Int
) -> CodeSnippetBoundedEdit {
    let stableText = codeSnippetText(context.stableText, limitedToUTF16Length: limit)
    let stableNSString = stableText as NSString
    let currentNSString = currentText as NSString
    let stableRange = context.replacementRange
    let currentReplacementLength = currentNSString.length
        - (stableNSString.length - stableRange.length)
    guard stableRange.location >= 0,
          stableRange.length >= 0,
          NSMaxRange(stableRange) <= stableNSString.length,
          currentReplacementLength >= 0,
          stableRange.location + currentReplacementLength <= currentNSString.length else {
        return codeSnippetBoundedEdit(
            currentText: currentText,
            stableText: stableText,
            selectedRange: selectedRange,
            maximumUTF16Length: limit
        )
    }

    let currentRange = NSRange(
        location: stableRange.location,
        length: currentReplacementLength
    )
    let replacement = currentNSString.substring(with: currentRange)
    let availableReplacementLength = max(
        limit - (stableNSString.length - stableRange.length),
        0
    )
    let boundedReplacement = codeSnippetText(
        replacement,
        limitedToUTF16Length: availableReplacementLength
    )
    let boundedReplacementLength = (boundedReplacement as NSString).length
    let mutableText = NSMutableString(string: stableText)
    mutableText.replaceCharacters(in: stableRange, with: boundedReplacement)

    func mappedSelectionLocation(_ location: Int) -> Int {
        let nonnegativeLocation = max(location, 0)
        if nonnegativeLocation <= currentRange.location {
            return nonnegativeLocation
        }
        if nonnegativeLocation <= NSMaxRange(currentRange) {
            return currentRange.location + min(
                nonnegativeLocation - currentRange.location,
                boundedReplacementLength
            )
        }
        return currentRange.location
            + boundedReplacementLength
            + min(
                nonnegativeLocation - NSMaxRange(currentRange),
                stableNSString.length - NSMaxRange(stableRange)
            )
    }

    let selectionStart = mappedSelectionLocation(selectedRange.location)
    let selectionEnd = mappedSelectionLocation(NSMaxRange(selectedRange))
    return CodeSnippetBoundedEdit(
        text: mutableText as String,
        selectedRange: clampedTextSelection(
            NSRange(
                location: min(selectionStart, selectionEnd),
                length: abs(selectionEnd - selectionStart)
            ),
            textLength: mutableText.length
        )
    )
}

/// Safe fallback for an over-limit change whose replacement range is unknown.
/// Rejecting the change preserves existing source; guessing from a text diff can
/// silently delete a repeated suffix.
func codeSnippetBoundedEdit(
    currentText: String,
    stableText: String,
    selectedRange: NSRange,
    maximumUTF16Length limit: Int
) -> CodeSnippetBoundedEdit {
    let currentLength = (currentText as NSString).length
    guard currentLength > limit else {
        return CodeSnippetBoundedEdit(
            text: currentText,
            selectedRange: clampedTextSelection(selectedRange, textLength: currentLength)
        )
    }
    let boundedText = codeSnippetText(stableText, limitedToUTF16Length: limit)
    let boundedLength = (boundedText as NSString).length
    return CodeSnippetBoundedEdit(
        text: boundedText,
        selectedRange: clampedTextSelection(
            selectedRange,
            textLength: boundedLength
        )
    )
}

private func clampedTextSelection(_ selection: NSRange, textLength: Int) -> NSRange {
    let location = min(max(selection.location, 0), textLength)
    return NSRange(
        location: location,
        length: min(max(selection.length, 0), textLength - location)
    )
}
