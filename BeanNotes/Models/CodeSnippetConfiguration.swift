//
//  CodeSnippetConfiguration.swift
//  BeanNotes
//

import Foundation
import UIKit

enum CodeSnippetLayout {
    /// Keeps the saved preview, inline editor, and selection chrome visually aligned.
    static let cornerRadius: CGFloat = 10
    static let minimumFrameLongEdge: CGFloat = 120
    static let minimumFrameSize = CGSize(width: 180, height: 120)
    static let defaultFrameSize = CGSize(width: 420, height: 240)
    static let headerHeight: CGFloat = 40
    static let headerHorizontalPadding: CGFloat = 16
    static let headerControlSpacing: CGFloat = 7
    static let headerSeparatorHeight: CGFloat = 1
    static let codeIconWidth: CGFloat = 20
    static let codeIconSize: CGFloat = 14
    static let languageChipHeight: CGFloat = 24
    static let languageChipHorizontalPadding: CGFloat = 10
    static let languageChipMinimumWidth: CGFloat = 52
    static let settingsReservedWidth: CGFloat = 42
    static let codeHorizontalPadding: CGFloat = 16
    static let codeTopPadding: CGFloat = 12
    static let codeBottomPadding: CGFloat = 16

    static func codeParagraphStyle(
        font: UIFont,
        minimumMetricScale: CGFloat = 1
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byClipping
        style.lineSpacing = max(font.pointSize * 0.15, minimumMetricScale)
        style.tabStops = []
        style.defaultTabInterval = max(font.pointSize * 4 * 0.6, minimumMetricScale)
        return style
    }
}

enum CodeSnippetLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case cpp
    case c
    case header = "h"
    case assembly = "asm"
    case java
    case python
    case ruby
    case matlab
    case cSharp = "csharp"
    case javaScript = "javascript"
    case html
    case css
    case xml
    case markdown = "md"
    case typeScript = "typescript"
    case visualBasic = "visualBasic"
    case ini

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cpp: "C++"
        case .c: "C"
        case .header: "H"
        case .assembly: "Assembly"
        case .java: "Java"
        case .python: "Python"
        case .ruby: "Ruby"
        case .matlab: "MATLAB"
        case .cSharp: "C#"
        case .javaScript: "JavaScript"
        case .html: "HTML"
        case .css: "CSS"
        case .xml: "XML"
        case .markdown: "Markdown"
        case .typeScript: "TypeScript"
        case .visualBasic: "Visual Basic"
        case .ini: "INI"
        }
    }

    var keywords: [String] {
        switch self {
        case .cpp:
            Self.cKeywords + ["alignas", "alignof", "constexpr", "decltype", "namespace", "nullptr", "template", "typename", "using", "virtual"]
        case .c, .header:
            Self.cKeywords
        case .assembly:
            Self.assemblyRecognitionWords
        case .java:
            ["abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for", "if", "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "package", "private", "protected", "public", "return", "short", "static", "strictfp", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "try", "void", "volatile", "while", "null", "true", "false"]
        case .python:
            ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"]
        case .ruby:
            ["alias", "and", "begin", "break", "case", "class", "def", "defined", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield"]
        case .matlab:
            ["break", "case", "catch", "classdef", "continue", "else", "elseif", "end", "for", "function", "global", "if", "otherwise", "parfor", "persistent", "return", "spmd", "switch", "try", "while"]
        case .cSharp:
            ["abstract", "as", "async", "await", "base", "bool", "break", "byte", "case", "catch", "char", "checked", "class", "const", "continue", "decimal", "default", "delegate", "do", "double", "else", "enum", "event", "explicit", "extern", "false", "finally", "fixed", "float", "for", "foreach", "if", "implicit", "in", "int", "interface", "internal", "is", "lock", "long", "namespace", "new", "null", "object", "operator", "out", "override", "params", "private", "protected", "public", "readonly", "record", "ref", "return", "sbyte", "sealed", "short", "sizeof", "stackalloc", "static", "string", "struct", "switch", "this", "throw", "true", "try", "typeof", "uint", "ulong", "unchecked", "unsafe", "ushort", "using", "virtual", "void", "volatile", "while"]
        case .javaScript, .typeScript:
            ["async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "get", "if", "implements", "import", "in", "instanceof", "interface", "let", "new", "null", "of", "package", "private", "protected", "public", "return", "set", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "with", "yield"]
        case .visualBasic:
            ["AddHandler", "AddressOf", "And", "As", "Async", "Await", "Boolean", "ByRef", "ByVal", "Call", "Case", "Catch", "Class", "Const", "Continue", "Date", "Decimal", "Dim", "Do", "Double", "Each", "Else", "ElseIf", "End", "Enum", "Event", "Exit", "False", "Finally", "For", "Function", "Get", "Handles", "If", "Implements", "Imports", "In", "Inherits", "Integer", "Interface", "Is", "Long", "Loop", "Module", "New", "Next", "Nothing", "Not", "Object", "Of", "Or", "Private", "Property", "Protected", "Public", "RaiseEvent", "ReadOnly", "Return", "Select", "Set", "Shared", "Short", "Single", "Static", "String", "Structure", "Sub", "Then", "Throw", "To", "True", "Try", "Using", "While", "With", "WriteOnly"]
        case .html, .css, .xml, .markdown, .ini:
            []
        }
    }

    var visionCustomWords: [String] {
        if self == .assembly {
            // Vision considers earlier custom words first. Prioritize common x86
            // spellings and IBM HLASM operations that are easy to misrecognize.
            return Array(Self.assemblyRecognitionWords.prefix(80))
        }
        return Array(keywords.prefix(80))
    }

    private static let cKeywords = [
        "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "true", "false", "NULL"
    ]

    private static let assemblyRecognitionWords = [
        "mov", "movb", "movw", "movl", "movq", "imul", "imulb", "imulw", "imull", "imulq",
        "lea", "leaq", "push", "pushq", "pop", "popq", "call", "callq", "ret", "retq",
        "jmp", "cmp", "cmpq", "test", "testq", "je", "jne", "jg", "jge", "jl", "jle",
        "add", "addq", "sub", "subq", "mul", "div", "idiv", "inc", "dec", "and", "or",
        "xor", "not", "neg", "shl", "shr", "sal", "sar", "rol", "ror", "nop", "leave",
        "syscall", "section", "global", "extern", "globl", "text", "data", "bss", "align",
        "CSECT", "DSECT", "RSECT", "USING", "DROP", "MVC", "CLC", "DC", "DS", "EQU",
        "LTORG", "ORG", "START", "END", "ENTRY", "EXTRN", "L", "LA", "LR", "ST", "STM",
        "LM", "BALR", "BASR", "BR", "BCR"
    ]
}

enum CodeSnippetFontChoice: String, CaseIterable, Codable, Identifiable, Sendable {
    case systemMono
    case menlo
    case courier

    var id: String { rawValue }

    var label: String {
        switch self {
        case .systemMono: "System Mono"
        case .menlo: "Menlo"
        case .courier: "Courier"
        }
    }

    func uiFont(size: CGFloat) -> UIFont {
        let safeSize = CGFloat(CodeSnippetPreferences.normalizedFontSize(Double(size)))
        switch self {
        case .systemMono:
            return .monospacedSystemFont(ofSize: safeSize, weight: .regular)
        case .menlo:
            return UIFont(name: "Menlo-Regular", size: safeSize)
                ?? .monospacedSystemFont(ofSize: safeSize, weight: .regular)
        case .courier:
            return UIFont(name: "Courier", size: safeSize)
                ?? .monospacedSystemFont(ofSize: safeSize, weight: .regular)
        }
    }
}

enum CodeSnippetBackgroundStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "App Appearance"
        case .light: "White"
        case .dark: "Dark Gray"
        }
    }
}

/// Semantic categories emitted by the syntax scanner. Keeping these independent
/// from concrete colors lets the live editor and flattened preview share the same
/// tokenization while applying one consistently resolved theme.
enum CodeSyntaxTokenKind: String, CaseIterable, Codable, Sendable {
    case plain
    case keyword
    case type
    case function
    case string
    case number
    case literal
    case comment
    case attribute
    case directive
    case operatorSymbol
    case mnemonic
    case register
    case label
}

/// A non-overlapping UTF-16 token range suitable for `NSAttributedString` and
/// TextKit. UTF-16 offsets avoid lossy conversions at the editor boundary.
struct CodeSyntaxToken: Equatable, Sendable {
    var range: NSRange
    var kind: CodeSyntaxTokenKind
}

enum CodeSnippetAssemblyDialect: String, Codable, Sendable {
    case generic
    case x86ATT
    case x86Intel
    case ibmHLASM
}

/// Syntax presentation is stored separately from the legacy surface choice so
/// existing snippets keep decoding `automatic`, `light`, and `dark` unchanged.
enum CodeSnippetSyntaxTheme: String, CaseIterable, Codable, Identifiable, Sendable {
    case adaptive
    case light
    case dark
    case monokai
    case solarizedLight
    case solarizedDark
    case goodNight
    case githubLight
    case githubDark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .adaptive: "App Appearance"
        case .light: "Light"
        case .dark: "Dark"
        case .monokai: "Monokai"
        case .solarizedLight: "Solarized Light"
        case .solarizedDark: "Solarized Dark"
        case .goodNight: "Good Night"
        case .githubLight: "GitHub Light"
        case .githubDark: "GitHub Dark"
        }
    }

    func resolved(for interfaceStyle: UIUserInterfaceStyle) -> CodeSnippetSyntaxTheme {
        guard self == .adaptive else { return self }
        return interfaceStyle == .dark ? .dark : .light
    }

    func palette(for interfaceStyle: UIUserInterfaceStyle) -> CodeSnippetSyntaxPalette {
        switch resolved(for: interfaceStyle) {
        case .adaptive:
            // `resolved(for:)` always maps adaptive to a concrete appearance.
            return Self.light.palette(for: interfaceStyle)
        case .light:
            return CodeSnippetSyntaxPalette(
                id: "light",
                isDark: false,
                backgroundColor: UIColor(codeSnippetHex: 0xFFFFFF),
                foregroundColor: UIColor(codeSnippetHex: 0x141C2B),
                keywordColor: UIColor(codeSnippetHex: 0x7329B3),
                typeColor: UIColor(codeSnippetHex: 0x0550AE),
                functionColor: UIColor(codeSnippetHex: 0x8250DF),
                stringColor: UIColor(codeSnippetHex: 0x147329),
                numberColor: UIColor(codeSnippetHex: 0xBF4714),
                literalColor: UIColor(codeSnippetHex: 0x953800),
                commentColor: UIColor(codeSnippetHex: 0x5E737A),
                attributeColor: UIColor(codeSnippetHex: 0x0561B3),
                directiveColor: UIColor(codeSnippetHex: 0xA01864),
                operatorColor: UIColor(codeSnippetHex: 0x34495E),
                mnemonicColor: UIColor(codeSnippetHex: 0x7137A8),
                registerColor: UIColor(codeSnippetHex: 0x006D77),
                labelColor: UIColor(codeSnippetHex: 0x9A5B00)
            )
        case .dark:
            return CodeSnippetSyntaxPalette(
                id: "dark",
                isDark: true,
                backgroundColor: UIColor(codeSnippetHex: 0x24262B),
                foregroundColor: UIColor(codeSnippetHex: 0xE3E8F5),
                keywordColor: UIColor(codeSnippetHex: 0xC795FF),
                typeColor: UIColor(codeSnippetHex: 0x78C7FF),
                functionColor: UIColor(codeSnippetHex: 0xE7C978),
                stringColor: UIColor(codeSnippetHex: 0x9EDB8F),
                numberColor: UIColor(codeSnippetHex: 0xFFB878),
                literalColor: UIColor(codeSnippetHex: 0xFF8E8E),
                commentColor: UIColor(codeSnippetHex: 0x9AAAB4),
                attributeColor: UIColor(codeSnippetHex: 0x78C7FF),
                directiveColor: UIColor(codeSnippetHex: 0xFF9CCB),
                operatorColor: UIColor(codeSnippetHex: 0xC7CDD9),
                mnemonicColor: UIColor(codeSnippetHex: 0xD7A8FF),
                registerColor: UIColor(codeSnippetHex: 0x72D7D1),
                labelColor: UIColor(codeSnippetHex: 0xF3CE79)
            )
        case .monokai:
            return CodeSnippetSyntaxPalette(
                id: "monokai",
                isDark: true,
                backgroundColor: UIColor(codeSnippetHex: 0x272822),
                foregroundColor: UIColor(codeSnippetHex: 0xF8F8F2),
                keywordColor: UIColor(codeSnippetHex: 0xF92672),
                typeColor: UIColor(codeSnippetHex: 0x66D9EF),
                functionColor: UIColor(codeSnippetHex: 0xA6E22E),
                stringColor: UIColor(codeSnippetHex: 0xE6DB74),
                numberColor: UIColor(codeSnippetHex: 0xAE81FF),
                literalColor: UIColor(codeSnippetHex: 0xFD971F),
                commentColor: UIColor(codeSnippetHex: 0x9A9685),
                attributeColor: UIColor(codeSnippetHex: 0xA6E22E),
                directiveColor: UIColor(codeSnippetHex: 0xF92672),
                operatorColor: UIColor(codeSnippetHex: 0xF8F8F2),
                mnemonicColor: UIColor(codeSnippetHex: 0xF92672),
                registerColor: UIColor(codeSnippetHex: 0x66D9EF),
                labelColor: UIColor(codeSnippetHex: 0xA6E22E)
            )
        case .solarizedLight:
            return CodeSnippetSyntaxPalette(
                id: "solarizedLight",
                isDark: false,
                backgroundColor: UIColor(codeSnippetHex: 0xFDF6E3),
                foregroundColor: UIColor(codeSnippetHex: 0x586E75),
                keywordColor: UIColor(codeSnippetHex: 0x6C7100),
                typeColor: UIColor(codeSnippetHex: 0x946200),
                functionColor: UIColor(codeSnippetHex: 0x1A69A5),
                stringColor: UIColor(codeSnippetHex: 0x16756F),
                numberColor: UIColor(codeSnippetHex: 0xC02868),
                literalColor: UIColor(codeSnippetHex: 0xB64100),
                commentColor: UIColor(codeSnippetHex: 0x657B83),
                attributeColor: UIColor(codeSnippetHex: 0x1A69A5),
                directiveColor: UIColor(codeSnippetHex: 0x6C4A9A),
                operatorColor: UIColor(codeSnippetHex: 0x586E75),
                mnemonicColor: UIColor(codeSnippetHex: 0x6C7100),
                registerColor: UIColor(codeSnippetHex: 0x16756F),
                labelColor: UIColor(codeSnippetHex: 0x946200)
            )
        case .solarizedDark:
            return CodeSnippetSyntaxPalette(
                id: "solarizedDark",
                isDark: true,
                backgroundColor: UIColor(codeSnippetHex: 0x002B36),
                foregroundColor: UIColor(codeSnippetHex: 0xA7B7B7),
                keywordColor: UIColor(codeSnippetHex: 0xB5BD45),
                typeColor: UIColor(codeSnippetHex: 0xE5B94E),
                functionColor: UIColor(codeSnippetHex: 0x58A6D6),
                stringColor: UIColor(codeSnippetHex: 0x58C2B8),
                numberColor: UIColor(codeSnippetHex: 0xE56B9F),
                literalColor: UIColor(codeSnippetHex: 0xF08A55),
                commentColor: UIColor(codeSnippetHex: 0x829496),
                attributeColor: UIColor(codeSnippetHex: 0x58A6D6),
                directiveColor: UIColor(codeSnippetHex: 0xC792EA),
                operatorColor: UIColor(codeSnippetHex: 0xA7B7B7),
                mnemonicColor: UIColor(codeSnippetHex: 0xB5BD45),
                registerColor: UIColor(codeSnippetHex: 0x58C2B8),
                labelColor: UIColor(codeSnippetHex: 0xE5B94E)
            )
        case .goodNight:
            return CodeSnippetSyntaxPalette(
                id: "goodNight",
                isDark: true,
                backgroundColor: UIColor(codeSnippetHex: 0x383B42),
                foregroundColor: UIColor(codeSnippetHex: 0xE4E4E4),
                keywordColor: UIColor(codeSnippetHex: 0xAFC8E1),
                typeColor: UIColor(codeSnippetHex: 0x80CBC4),
                functionColor: UIColor(codeSnippetHex: 0xC792EA),
                stringColor: UIColor(codeSnippetHex: 0xA8D7C7),
                numberColor: UIColor(codeSnippetHex: 0xFFAC9C),
                literalColor: UIColor(codeSnippetHex: 0xF4C18B),
                commentColor: UIColor(codeSnippetHex: 0xA5A8AE),
                attributeColor: UIColor(codeSnippetHex: 0xC792EA),
                directiveColor: UIColor(codeSnippetHex: 0xF4A7C4),
                operatorColor: UIColor(codeSnippetHex: 0xD5D7DA),
                mnemonicColor: UIColor(codeSnippetHex: 0xAFC8E1),
                registerColor: UIColor(codeSnippetHex: 0x80CBC4),
                labelColor: UIColor(codeSnippetHex: 0xF4C18B)
            )
        case .githubLight:
            return CodeSnippetSyntaxPalette(
                id: "githubLight",
                isDark: false,
                backgroundColor: UIColor(codeSnippetHex: 0xFFFFFF),
                foregroundColor: UIColor(codeSnippetHex: 0x24292F),
                keywordColor: UIColor(codeSnippetHex: 0xCF222E),
                typeColor: UIColor(codeSnippetHex: 0x953800),
                functionColor: UIColor(codeSnippetHex: 0x8250DF),
                stringColor: UIColor(codeSnippetHex: 0x0A3069),
                numberColor: UIColor(codeSnippetHex: 0x0550AE),
                literalColor: UIColor(codeSnippetHex: 0x953800),
                commentColor: UIColor(codeSnippetHex: 0x57606A),
                attributeColor: UIColor(codeSnippetHex: 0x116329),
                directiveColor: UIColor(codeSnippetHex: 0x8250DF),
                operatorColor: UIColor(codeSnippetHex: 0x24292F),
                mnemonicColor: UIColor(codeSnippetHex: 0xCF222E),
                registerColor: UIColor(codeSnippetHex: 0x0550AE),
                labelColor: UIColor(codeSnippetHex: 0x8250DF)
            )
        case .githubDark:
            return CodeSnippetSyntaxPalette(
                id: "githubDark",
                isDark: true,
                backgroundColor: UIColor(codeSnippetHex: 0x0D1117),
                foregroundColor: UIColor(codeSnippetHex: 0xC9D1D9),
                keywordColor: UIColor(codeSnippetHex: 0xFF7B72),
                typeColor: UIColor(codeSnippetHex: 0xFFA657),
                functionColor: UIColor(codeSnippetHex: 0xD2A8FF),
                stringColor: UIColor(codeSnippetHex: 0xA5D6FF),
                numberColor: UIColor(codeSnippetHex: 0x79C0FF),
                literalColor: UIColor(codeSnippetHex: 0xFFA657),
                commentColor: UIColor(codeSnippetHex: 0x8B949E),
                attributeColor: UIColor(codeSnippetHex: 0x7EE787),
                directiveColor: UIColor(codeSnippetHex: 0xD2A8FF),
                operatorColor: UIColor(codeSnippetHex: 0xC9D1D9),
                mnemonicColor: UIColor(codeSnippetHex: 0xFF7B72),
                registerColor: UIColor(codeSnippetHex: 0x79C0FF),
                labelColor: UIColor(codeSnippetHex: 0xD2A8FF)
            )
        }
    }

    func palette(isDarkAppearance: Bool) -> CodeSnippetSyntaxPalette {
        palette(for: isDarkAppearance ? .dark : .light)
    }

    static func legacyTheme(for backgroundStyle: CodeSnippetBackgroundStyle) -> CodeSnippetSyntaxTheme {
        switch backgroundStyle {
        case .automatic: .adaptive
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Shared editor/preview palette. Chrome colors are derived from the same
/// surface choice so switching from a raster preview to live text is seamless.
struct CodeSnippetSyntaxPalette {
    let id: String
    let isDark: Bool
    let backgroundColor: UIColor
    let foregroundColor: UIColor
    let secondaryForegroundColor: UIColor
    let borderColor: UIColor
    let innerHighlightColor: UIColor
    let separatorColor: UIColor
    let pillColor: UIColor
    let pillBorderColor: UIColor
    let headerTextColor: UIColor
    let caretColor: UIColor
    let selectionColor: UIColor
    let keywordColor: UIColor
    let typeColor: UIColor
    let functionColor: UIColor
    let stringColor: UIColor
    let numberColor: UIColor
    let literalColor: UIColor
    let commentColor: UIColor
    let attributeColor: UIColor
    let directiveColor: UIColor
    let operatorColor: UIColor
    let mnemonicColor: UIColor
    let registerColor: UIColor
    let labelColor: UIColor

    init(
        id: String,
        isDark: Bool,
        backgroundColor: UIColor,
        foregroundColor: UIColor,
        keywordColor: UIColor,
        typeColor: UIColor,
        functionColor: UIColor,
        stringColor: UIColor,
        numberColor: UIColor,
        literalColor: UIColor,
        commentColor: UIColor,
        attributeColor: UIColor,
        directiveColor: UIColor,
        operatorColor: UIColor,
        mnemonicColor: UIColor,
        registerColor: UIColor,
        labelColor: UIColor
    ) {
        self.id = id
        self.isDark = isDark
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.secondaryForegroundColor = foregroundColor.withAlphaComponent(0.72)
        self.borderColor = (isDark ? UIColor.white : UIColor.black).withAlphaComponent(0.2)
        self.innerHighlightColor = (isDark ? UIColor.white : UIColor.black).withAlphaComponent(0.08)
        self.separatorColor = (isDark ? UIColor.white : UIColor.black).withAlphaComponent(0.12)
        self.pillColor = (isDark ? UIColor.white : UIColor.black).withAlphaComponent(0.1)
        self.pillBorderColor = (isDark ? UIColor.white : UIColor.black).withAlphaComponent(0.16)
        self.headerTextColor = foregroundColor.withAlphaComponent(0.94)
        self.caretColor = foregroundColor
        self.selectionColor = attributeColor.withAlphaComponent(0.28)
        self.keywordColor = keywordColor
        self.typeColor = typeColor
        self.functionColor = functionColor
        self.stringColor = stringColor
        self.numberColor = numberColor
        self.literalColor = literalColor
        self.commentColor = commentColor
        self.attributeColor = attributeColor
        self.directiveColor = directiveColor
        self.operatorColor = operatorColor
        self.mnemonicColor = mnemonicColor
        self.registerColor = registerColor
        self.labelColor = labelColor
    }

    var baseColor: UIColor { backgroundColor }
    var codeTextColor: UIColor { foregroundColor }

    func color(for kind: CodeSyntaxTokenKind) -> UIColor {
        switch kind {
        case .plain: foregroundColor
        case .keyword: keywordColor
        case .type: typeColor
        case .function: functionColor
        case .string: stringColor
        case .number: numberColor
        case .literal: literalColor
        case .comment: commentColor
        case .attribute: attributeColor
        case .directive: directiveColor
        case .operatorSymbol: operatorColor
        case .mnemonic: mnemonicColor
        case .register: registerColor
        case .label: labelColor
        }
    }
}

enum CodeSnippetInputMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case handwriting
    case text

    var id: String { rawValue }

    var label: String {
        switch self {
        case .handwriting: "Apple Pencil"
        case .text: "Keyboard & Paste"
        }
    }
}

enum CodeSnippetPreferences {
    static let defaultLanguageKey = "codeSnippet.defaultLanguage"
    static let defaultFontKey = "codeSnippet.defaultFont"
    static let defaultFontSizeKey = "codeSnippet.defaultFontSize"
    static let defaultBackgroundStyleKey = "codeSnippet.defaultBackgroundStyle"
    static let defaultSyntaxThemeKey = "codeSnippet.defaultSyntaxTheme"
    static let defaultWidthKey = "codeSnippet.defaultWidth"
    static let defaultHeightKey = "codeSnippet.defaultHeight"
    static let showsInPencilPaletteKey = "codeSnippet.showsInPencilPalette"

    static let defaultLanguage: CodeSnippetLanguage = .python
    static let defaultFont: CodeSnippetFontChoice = .systemMono
    static let defaultFontSize: Double = 16
    static let defaultBackgroundStyle: CodeSnippetBackgroundStyle = .automatic
    static let defaultSyntaxTheme: CodeSnippetSyntaxTheme = .adaptive
    static let defaultWidth = Double(CodeSnippetLayout.defaultFrameSize.width)
    static let defaultHeight = Double(CodeSnippetLayout.defaultFrameSize.height)
    static let defaultShowsInPencilPalette = true
    static let supportedFontSize = 10.0...32.0
    static let supportedWidth = 180.0...560.0
    static let supportedHeight = 120.0...420.0

    static var defaultSize: CGSize {
        CodeSnippetLayout.defaultFrameSize
    }

    static func defaultDraft(in defaults: UserDefaults = .standard) -> CodeSnippetDraft {
        let language = CodeSnippetLanguage(
            rawValue: defaults.string(forKey: defaultLanguageKey) ?? ""
        ) ?? defaultLanguage
        let font = CodeSnippetFontChoice(
            rawValue: defaults.string(forKey: defaultFontKey) ?? ""
        ) ?? defaultFont
        let background = CodeSnippetBackgroundStyle(
            rawValue: defaults.string(forKey: defaultBackgroundStyleKey) ?? ""
        ) ?? defaultBackgroundStyle
        let syntaxTheme = resolvedSyntaxTheme(
            rawValue: defaults.string(forKey: defaultSyntaxThemeKey),
            legacyBackgroundStyle: background
        )
        let fontSize = defaults.object(forKey: defaultFontSizeKey) == nil
            ? defaultFontSize
            : normalizedFontSize(defaults.double(forKey: defaultFontSizeKey))
        return CodeSnippetDraft(
            code: "",
            language: language,
            font: font,
            fontSize: fontSize,
            backgroundStyle: background,
            syntaxTheme: syntaxTheme,
            // Inline snippets accept Apple Pencil Scribble and keyboard input in the
            // same editor, so there is no separate creation-time input mode to persist.
            preferredInputMode: .text
        )
    }

    static func normalizePersistedValues(in defaults: UserDefaults = .standard) {
        let draft = defaultDraft(in: defaults)
        defaults.set(draft.language.rawValue, forKey: defaultLanguageKey)
        defaults.set(draft.font.rawValue, forKey: defaultFontKey)
        defaults.set(draft.fontSize, forKey: defaultFontSizeKey)
        defaults.set(draft.backgroundStyle.rawValue, forKey: defaultBackgroundStyleKey)
        defaults.set(draft.syntaxTheme.rawValue, forKey: defaultSyntaxThemeKey)
        let size = defaultSize(in: defaults)
        defaults.set(Double(size.width), forKey: defaultWidthKey)
        defaults.set(Double(size.height), forKey: defaultHeightKey)
        defaults.set(showsInPencilPalette(in: defaults), forKey: showsInPencilPaletteKey)
    }

    static func showsInPencilPalette(in defaults: UserDefaults = .standard) -> Bool {
        guard let storedValue = defaults.object(forKey: showsInPencilPaletteKey) as? Bool else {
            return defaultShowsInPencilPalette
        }
        return storedValue
    }

    static func normalizedFontSize(_ value: Double) -> Double {
        guard value.isFinite else { return defaultFontSize }
        return min(max(value, supportedFontSize.lowerBound), supportedFontSize.upperBound)
    }

    static func defaultSize(in defaults: UserDefaults = .standard) -> CGSize {
        let width = defaults.object(forKey: defaultWidthKey) == nil
            ? defaultWidth
            : normalizedWidth(defaults.double(forKey: defaultWidthKey))
        let height = defaults.object(forKey: defaultHeightKey) == nil
            ? defaultHeight
            : normalizedHeight(defaults.double(forKey: defaultHeightKey))
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    static func normalizedSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: CGFloat(normalizedWidth(Double(size.width))),
            height: CGFloat(normalizedHeight(Double(size.height)))
        )
    }

    static func normalizedWidth(_ value: Double) -> Double {
        guard value.isFinite else { return defaultWidth }
        return min(max(value, supportedWidth.lowerBound), supportedWidth.upperBound)
    }

    static func normalizedHeight(_ value: Double) -> Double {
        guard value.isFinite else { return defaultHeight }
        return min(max(value, supportedHeight.lowerBound), supportedHeight.upperBound)
    }

    static func resolvedSyntaxTheme(
        rawValue: String?,
        legacyBackgroundStyle: CodeSnippetBackgroundStyle
    ) -> CodeSnippetSyntaxTheme {
        guard let rawValue else {
            return CodeSnippetSyntaxTheme.legacyTheme(for: legacyBackgroundStyle)
        }
        return CodeSnippetSyntaxTheme(rawValue: rawValue) ?? defaultSyntaxTheme
    }
}

enum CodeSnippetSearchIndex {
    /// Search remains useful for normal snippets without duplicating extremely
    /// large sources throughout SwiftData's page and document indexes.
    nonisolated static let maximumSourceUTF16Length = 20_000

    nonisolated static func sourceProjection(_ source: String) -> String {
        let source = source as NSString
        guard source.length > maximumSourceUTF16Length else { return source as String }

        let proposedRange = NSRange(location: 0, length: maximumSourceUTF16Length)
        var safeRange = source.rangeOfComposedCharacterSequences(for: proposedRange)
        if safeRange.length > maximumSourceUTF16Length {
            let crossingSequence = source.rangeOfComposedCharacterSequence(
                at: maximumSourceUTF16Length - 1
            )
            safeRange.length = crossingSequence.location
        }
        return source.substring(with: safeRange)
    }
}

struct CodeSnippetDraft: Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var code: String
    var language: CodeSnippetLanguage
    var font: CodeSnippetFontChoice
    var fontSize: Double
    var backgroundStyle: CodeSnippetBackgroundStyle
    var syntaxTheme: CodeSnippetSyntaxTheme
    var preferredInputMode: CodeSnippetInputMode

    init(
        id: UUID = UUID(),
        code: String,
        language: CodeSnippetLanguage,
        font: CodeSnippetFontChoice,
        fontSize: Double,
        backgroundStyle: CodeSnippetBackgroundStyle,
        syntaxTheme: CodeSnippetSyntaxTheme? = nil,
        preferredInputMode: CodeSnippetInputMode
    ) {
        self.id = id
        self.code = code
        self.language = language
        self.font = font
        self.fontSize = CodeSnippetPreferences.normalizedFontSize(fontSize)
        self.backgroundStyle = backgroundStyle
        self.syntaxTheme = syntaxTheme ?? CodeSnippetSyntaxTheme.legacyTheme(for: backgroundStyle)
        self.preferredInputMode = preferredInputMode
    }

    init(editing attachment: Attachment, defaults: CodeSnippetDraft) {
        self.init(
            editing: attachment,
            defaults: defaults,
            syntaxThemeRaw: attachment.codeSnippetSyntaxThemeRaw
        )
    }

    /// Compatibility bridge for persistence layers that store the syntax theme
    /// alongside the existing background raw value. A missing value migrates from
    /// the snippet's legacy background without changing that stored background.
    init(
        editing attachment: Attachment,
        defaults: CodeSnippetDraft,
        syntaxThemeRaw: String?
    ) {
        let backgroundStyle = CodeSnippetBackgroundStyle(
            rawValue: attachment.codeSnippetBackgroundRaw ?? ""
        ) ?? defaults.backgroundStyle
        self.init(
            id: attachment.id,
            code: attachment.codeSnippetText ?? "",
            language: CodeSnippetLanguage(rawValue: attachment.codeSnippetLanguageRaw ?? "")
                ?? defaults.language,
            font: CodeSnippetFontChoice(rawValue: attachment.codeSnippetFontRaw ?? "")
                ?? defaults.font,
            fontSize: attachment.codeSnippetFontSize ?? defaults.fontSize,
            backgroundStyle: backgroundStyle,
            syntaxTheme: CodeSnippetPreferences.resolvedSyntaxTheme(
                rawValue: syntaxThemeRaw,
                legacyBackgroundStyle: backgroundStyle
            ),
            preferredInputMode: .text
        )
    }

    /// Resolves the complete live/preview palette. Adaptive syntax follows the
    /// legacy background choice so existing snippets that explicitly forced a
    /// white or dark surface keep that appearance after migration.
    func syntaxPalette(for interfaceStyle: UIUserInterfaceStyle) -> CodeSnippetSyntaxPalette {
        guard syntaxTheme == .adaptive else {
            return syntaxTheme.palette(for: interfaceStyle)
        }

        switch backgroundStyle {
        case .automatic:
            return syntaxTheme.palette(for: interfaceStyle)
        case .light:
            return CodeSnippetSyntaxTheme.light.palette(for: interfaceStyle)
        case .dark:
            return CodeSnippetSyntaxTheme.dark.palette(for: interfaceStyle)
        }
    }

    func syntaxPalette(isDarkAppearance: Bool) -> CodeSnippetSyntaxPalette {
        syntaxPalette(for: isDarkAppearance ? .dark : .light)
    }
}

enum CodeSyntaxHighlighter {
    static let maximumHighlightedUTF16Length = 60_000

    private struct Candidate {
        var range: NSRange
        var kind: CodeSyntaxTokenKind
        var priority: Int
    }

    static func tokens(
        for code: String,
        language: CodeSnippetLanguage
    ) -> [CodeSyntaxToken] {
        let source = code as NSString
        guard source.length > 0, source.length <= maximumHighlightedUTF16Length else {
            return []
        }

        var candidates: [Candidate] = []
        func add(
            _ pattern: String,
            kind: CodeSyntaxTokenKind,
            priority: Int,
            options: NSRegularExpression.Options = []
        ) {
            candidates.append(contentsOf: matchingRanges(
                pattern: pattern,
                options: options,
                in: code
            ).map { Candidate(range: $0, kind: kind, priority: priority) })
        }

        let stringRanges = stringPatterns(for: language).flatMap {
            matchingRanges(pattern: $0, in: code)
        }
        let dialect = language == .assembly ? assemblyDialect(for: code) : nil
        let commentRanges = commentPatterns(for: language, assemblyDialect: dialect).flatMap {
            matchingRanges(pattern: $0, in: code)
        }.filter { range in
            !contains(range.location, in: stringRanges)
        }
        candidates.append(contentsOf: stringRanges.map {
            Candidate(range: $0, kind: .string, priority: 900)
        })
        candidates.append(contentsOf: commentRanges.map {
            Candidate(range: $0, kind: .comment, priority: 1_000)
        })

        add(
            #"(?<![A-Za-z0-9_])(?:[$])?(?:0[xX][0-9A-Fa-f]+|0[bB][01]+|0[oO][0-7]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#,
            kind: .number,
            priority: 400
        )
        add(
            #"===|!==|==|!=|<=|>=|=>|->|::|&&|\|\||\+\+|--|<<|>>|[-+*/%=&|^!<>?:~]"#,
            kind: .operatorSymbol,
            priority: 300
        )
        add(
            #"\b[A-Za-z_][A-Za-z0-9_]*(?=\s*\()"#,
            kind: .function,
            priority: 500
        )

        let typeKeywords = typeKeywords(for: language)
        if !typeKeywords.isEmpty {
            add(
                wordPattern(for: typeKeywords),
                kind: .type,
                priority: 620,
                options: language == .visualBasic ? [.caseInsensitive] : []
            )
        }
        let literals = literalKeywords(for: language)
        if !literals.isEmpty {
            add(
                wordPattern(for: literals),
                kind: .literal,
                priority: 610,
                options: language == .visualBasic ? [.caseInsensitive] : []
            )
        }
        if !language.keywords.isEmpty {
            add(
                wordPattern(for: language.keywords),
                kind: .keyword,
                priority: 600,
                options: language == .visualBasic || language == .assembly
                    ? [.caseInsensitive]
                    : []
            )
        }

        switch language {
        case .assembly:
            addAssemblyCandidates(to: &candidates, in: code)
        case .c, .cpp, .header, .cSharp:
            add(
                #"(?m)^\s*#\s*[A-Za-z_][A-Za-z0-9_]*"#,
                kind: .directive,
                priority: 720
            )
            add(
                #"\.[A-Za-z_][A-Za-z0-9_]*"#,
                kind: .attribute,
                priority: 450
            )
        case .java, .javaScript, .typeScript, .python, .ruby, .matlab:
            add(
                #"\.[A-Za-z_][A-Za-z0-9_]*"#,
                kind: .attribute,
                priority: 450
            )
        case .html, .xml:
            add(
                #"\b[A-Za-z][A-Za-z0-9:_-]*\b(?=[^<>]*>)"#,
                kind: .keyword,
                priority: 600
            )
            add(
                #"\b[A-Za-z_:][-A-Za-z0-9_:.]*(?=\s*=)"#,
                kind: .attribute,
                priority: 560
            )
        case .css:
            add(
                #"[-A-Za-z]+(?=\s*:)"#,
                kind: .attribute,
                priority: 560
            )
            add(
                #"[#.][-_A-Za-z][-_A-Za-z0-9]*"#,
                kind: .label,
                priority: 570
            )
        case .markdown:
            add(
                #"(?m)^#{1,6}\s.*$"#,
                kind: .keyword,
                priority: 600
            )
            add(
                #"\[[^\]]+\]\([^\)]+\)"#,
                kind: .attribute,
                priority: 560
            )
        case .ini:
            add(
                #"(?m)^\s*\[[^\]]+\]"#,
                kind: .directive,
                priority: 720
            )
            add(
                #"(?m)^\s*[^=;#\n]+(?=\s*=)"#,
                kind: .attribute,
                priority: 560
            )
        case .visualBasic:
            break
        }

        return nonOverlappingTokens(from: candidates, sourceLength: source.length)
    }

    static func assemblyDialect(for code: String) -> CodeSnippetAssemblyDialect {
        let attScore = matchCount(#"(?i)%(?:r(?:1[0-5]|[0-9])|[re]?(?:ax|bx|cx|dx|si|di|bp|sp)|[xyz]mm\d+|rip)\b"#, in: code) * 3
            + matchCount(#"(?im)^\s*\.att_syntax\b"#, in: code) * 8
            + matchCount(#"(?i)\b(?:mov|imul|add|sub|cmp|test)[bwlq]\b"#, in: code) * 2
            + matchCount(#"(?<![A-Za-z0-9_])\$(?:0[xX][0-9A-Fa-f]+|\d+)"#, in: code) * 2
        let intelScore = matchCount(#"(?im)^\s*\.intel_syntax\b"#, in: code) * 8
            + matchCount(#"(?i)\b(?:byte|word|dword|qword)\s+ptr\b"#, in: code) * 3
            + matchCount(#"\[[^\]\n]+\]"#, in: code) * 2
            + matchCount(#"(?im)^\s*(?:section|global|extern)\b"#, in: code) * 3
        let ibmScore = matchCount(
            #"(?im)^(?:[A-Z@#$][A-Z0-9@#$_]*\s+)?(?:CSECT|DSECT|RSECT|USING|DROP|MVC|CLC|DC|DS|EQU|LTORG|BALR|BASR|STM|LM)\b"#,
            in: code
        ) * 4

        let bestScore = max(attScore, intelScore, ibmScore)
        guard bestScore > 0 else { return .generic }
        if ibmScore == bestScore { return .ibmHLASM }
        if attScore == bestScore { return .x86ATT }
        return .x86Intel
    }

    static func attributedString(
        for code: String,
        language: CodeSnippetLanguage,
        font: UIFont,
        palette: CodeSnippetSyntaxPalette
    ) -> NSAttributedString {
        attributedString(
            for: code,
            language: language,
            font: font,
            palette: palette,
            baseForegroundColor: palette.foregroundColor
        )
    }

    static func attributedString(
        for code: String,
        language: CodeSnippetLanguage,
        font: UIFont,
        syntaxTheme: CodeSnippetSyntaxTheme,
        interfaceStyle: UIUserInterfaceStyle
    ) -> NSAttributedString {
        attributedString(
            for: code,
            language: language,
            font: font,
            palette: syntaxTheme.palette(for: interfaceStyle)
        )
    }

    static func attributedString(
        for code: String,
        language: CodeSnippetLanguage,
        font: UIFont,
        foregroundColor: UIColor
    ) -> NSAttributedString {
        let palette = compatibilityPalette(for: foregroundColor)
        return attributedString(
            for: code,
            language: language,
            font: font,
            palette: palette,
            baseForegroundColor: foregroundColor
        )
    }

    private static func attributedString(
        for code: String,
        language: CodeSnippetLanguage,
        font: UIFont,
        palette: CodeSnippetSyntaxPalette,
        baseForegroundColor: UIColor
    ) -> NSAttributedString {
        let base = NSMutableAttributedString(
            string: code,
            attributes: [
                .font: font,
                .foregroundColor: baseForegroundColor
            ]
        )
        guard base.length > 0, base.length <= maximumHighlightedUTF16Length else {
            return base
        }

        for token in tokens(for: code, language: language)
        where token.range.location >= 0 && NSMaxRange(token.range) <= base.length {
            base.addAttribute(
                .foregroundColor,
                value: palette.color(for: token.kind),
                range: token.range
            )
        }
        return base
    }

    private static func stringPatterns(for language: CodeSnippetLanguage) -> [String] {
        var patterns = [#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#]
        if language == .python {
            patterns.insert(#"(?s)\"\"\".*?\"\"\"|'''.*?'''"#, at: 0)
        }
        if language == .javaScript || language == .typeScript {
            patterns.insert(#"(?s)`(?:\\.|[^`\\])*`"#, at: 0)
        }
        if language == .markdown {
            patterns.insert(#"`{1,3}[^`]+`{1,3}"#, at: 0)
        }
        return patterns
    }

    private static func commentPatterns(
        for language: CodeSnippetLanguage,
        assemblyDialect: CodeSnippetAssemblyDialect?
    ) -> [String] {
        switch language {
        case .python, .ruby:
            [#"(?m)#.*$"#]
        case .matlab:
            [#"(?m)%.*$"#]
        case .assembly:
            switch assemblyDialect ?? .generic {
            case .x86ATT:
                [#"(?m)#.*$"#, #"(?s)/\*.*?\*/"#]
            case .x86Intel:
                [#"(?m);.*$"#, #"(?m)//.*$"#]
            case .ibmHLASM:
                [#"(?m)^\s*\*.*$"#, #"(?m)^\s*\.\*.*$"#]
            case .generic:
                [#"(?m);.*$"#, #"(?m)^\s*#.*$"#, #"(?s)/\*.*?\*/"#]
            }
        case .visualBasic:
            [#"(?m)'.*$"#]
        case .html, .xml:
            [#"(?s)<!--.*?-->"#]
        case .css:
            [#"(?s)/\*.*?\*/"#]
        case .ini:
            [#"(?m)^\s*[;#].*$"#]
        case .markdown:
            [#"(?s)<!--.*?-->"#]
        default:
            [#"(?m)//.*?$"#, #"(?s)/\*.*?\*/"#]
        }
    }

    private static func addAssemblyCandidates(
        to candidates: inout [Candidate],
        in code: String
    ) {
        appendCandidates(
            pattern: #"(?i)(?<![A-Za-z0-9_])(?:\.(?:section|text|data|bss|globl|global|extern|align|p2align|byte|word|long|quad|ascii|asciz|intel_syntax|att_syntax)|(?:section|global|extern|CSECT|DSECT|RSECT|USING|DROP|DC|DS|EQU|LTORG|ORG|START|END|ENTRY|EXTRN))\b"#,
            kind: .directive,
            priority: 760,
            options: [.caseInsensitive],
            to: &candidates,
            in: code
        )
        appendCandidates(
            pattern: wordPattern(for: assemblyMnemonics),
            kind: .mnemonic,
            priority: 740,
            options: [.caseInsensitive],
            to: &candidates,
            in: code
        )
        appendCandidates(
            pattern: #"(?i)%(?:r(?:1[0-5]|[0-9])(?:[dwb])?|[re]?(?:ax|bx|cx|dx|si|di|bp|sp)|[abcd][lh]|[xyz]mm\d+|st(?:\(\d+\))?|[cdefgs]s|rip|eip|ip|[er]?flags|cr\d+|dr\d+)\b"#,
            kind: .register,
            priority: 730,
            to: &candidates,
            in: code
        )
        appendCandidates(
            pattern: #"(?i)\b(?:r(?:1[0-5]|[0-9])(?:[dwb])?|[re]?(?:ax|bx|cx|dx|si|di|bp|sp)|[abcd][lh]|[xyz]mm\d+|st(?:\(\d+\))?|[cdefgs]s|rip|eip|ip|[er]?flags|cr\d+|dr\d+)\b"#,
            kind: .register,
            priority: 725,
            to: &candidates,
            in: code
        )
        appendCandidates(
            pattern: #"(?m)^\s*(?:[A-Za-z_.$][A-Za-z0-9_.$]*|\d+):"#,
            kind: .label,
            priority: 750,
            to: &candidates,
            in: code
        )
        appendCandidates(
            pattern: #"(?im)^[A-Z@#$][A-Z0-9@#$_]*\s+(?=(?:CSECT|DSECT|RSECT|USING|MVC|CLC|DC|DS|EQU|L|LA|LR|ST|STM|LM|BALR|BASR|BR|BCR)\b)"#,
            kind: .label,
            priority: 750,
            to: &candidates,
            in: code
        )
    }

    private static func appendCandidates(
        pattern: String,
        kind: CodeSyntaxTokenKind,
        priority: Int,
        options: NSRegularExpression.Options = [],
        to candidates: inout [Candidate],
        in code: String
    ) {
        candidates.append(contentsOf: matchingRanges(
            pattern: pattern,
            options: options,
            in: code
        ).map { Candidate(range: $0, kind: kind, priority: priority) })
    }

    private static func matchingRanges(
        pattern: String,
        options: NSRegularExpression.Options = [],
        in text: String
    ) -> [NSRange] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return expression.matches(in: text, range: range).compactMap { match in
            match.range.location == NSNotFound ? nil : match.range
        }
    }

    private static func contains(_ location: Int, in ranges: [NSRange]) -> Bool {
        ranges.contains { NSLocationInRange(location, $0) }
    }

    private static func nonOverlappingTokens(
        from candidates: [Candidate],
        sourceLength: Int
    ) -> [CodeSyntaxToken] {
        let sorted = candidates.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.range.location != $1.range.location {
                return $0.range.location < $1.range.location
            }
            return $0.range.length > $1.range.length
        }
        var occupied = IndexSet()
        var result: [CodeSyntaxToken] = []

        for candidate in sorted {
            guard candidate.range.location >= 0,
                  candidate.range.length > 0,
                  NSMaxRange(candidate.range) <= sourceLength else {
                continue
            }
            let indexes = IndexSet(integersIn: candidate.range.location..<NSMaxRange(candidate.range))
            guard occupied.intersection(indexes).isEmpty else { continue }
            occupied.formUnion(indexes)
            result.append(CodeSyntaxToken(range: candidate.range, kind: candidate.kind))
        }
        return result.sorted { $0.range.location < $1.range.location }
    }

    private static func typeKeywords(for language: CodeSnippetLanguage) -> [String] {
        switch language {
        case .c, .cpp, .header:
            ["bool", "char", "double", "float", "int", "long", "short", "signed", "size_t", "struct", "union", "unsigned", "void", "wchar_t"]
        case .java:
            ["boolean", "byte", "char", "double", "float", "int", "long", "short", "String", "void"]
        case .python:
            ["bool", "bytes", "dict", "float", "int", "list", "set", "str", "tuple"]
        case .ruby:
            ["Array", "FalseClass", "Float", "Hash", "Integer", "String", "Symbol", "TrueClass"]
        case .matlab:
            ["cell", "char", "double", "logical", "single", "string", "struct", "table"]
        case .cSharp:
            ["bool", "byte", "char", "decimal", "double", "float", "int", "long", "object", "sbyte", "short", "string", "uint", "ulong", "ushort", "void"]
        case .javaScript:
            ["Array", "BigInt", "Boolean", "Date", "Map", "Number", "Object", "Promise", "Set", "String", "Symbol"]
        case .typeScript:
            ["any", "bigint", "boolean", "never", "number", "object", "string", "symbol", "unknown", "void"]
        case .visualBasic:
            ["Boolean", "Byte", "Char", "Date", "Decimal", "Double", "Integer", "Long", "Object", "Short", "Single", "String"]
        case .assembly, .html, .css, .xml, .markdown, .ini:
            []
        }
    }

    private static func literalKeywords(for language: CodeSnippetLanguage) -> [String] {
        switch language {
        case .python:
            ["False", "None", "True"]
        case .ruby:
            ["false", "nil", "true"]
        case .visualBasic:
            ["False", "Nothing", "True"]
        case .c, .cpp, .header, .java, .cSharp, .javaScript, .typeScript:
            ["false", "null", "nullptr", "true", "undefined"].filter {
                language.keywords.contains($0)
            }
        case .assembly, .matlab, .html, .css, .xml, .markdown, .ini:
            []
        }
    }

    private static func wordPattern(for words: [String]) -> String {
        let escaped = words.map(NSRegularExpression.escapedPattern(for:))
        guard !escaped.isEmpty else { return #"(?!)"# }
        return "\\b(?:\(escaped.joined(separator: "|")))\\b"
    }

    private static func matchCount(_ pattern: String, in code: String) -> Int {
        matchingRanges(pattern: pattern, in: code).count
    }

    private static func compatibilityPalette(
        for foregroundColor: UIColor
    ) -> CodeSnippetSyntaxPalette {
        var white: CGFloat = 0
        let usesDarkSurface = foregroundColor.getWhite(&white, alpha: nil) && white > 0.55
        return (usesDarkSurface ? CodeSnippetSyntaxTheme.dark : .light)
            .palette(for: usesDarkSurface ? .dark : .light)
    }

    private static let assemblyMnemonicBases = [
        "mov", "movs", "movz", "lea", "push", "pop", "call", "ret", "jmp", "cmp", "test",
        "add", "sub", "adc", "sbb", "mul", "imul", "div", "idiv", "inc", "dec", "and", "or",
        "xor", "not", "neg", "shl", "shr", "sal", "sar", "rol", "ror", "nop", "leave", "enter"
    ]

    private static let assemblyMnemonics: [String] = {
        let sized = assemblyMnemonicBases.flatMap { mnemonic in
            [mnemonic, "\(mnemonic)b", "\(mnemonic)w", "\(mnemonic)l", "\(mnemonic)q"]
        }
        let x86Branches = [
            "ja", "jae", "jb", "jbe", "jc", "je", "jg", "jge", "jl", "jle", "jna", "jnae",
            "jnb", "jnbe", "jnc", "jne", "jno", "jnp", "jns", "jnz", "jo", "jp", "jpe",
            "jpo", "js", "jz", "loop", "loope", "loopne", "syscall", "sysenter", "int"
        ]
        let ibm = [
            "MVC", "CLC", "L", "LA", "LR", "ST", "STM", "LM", "BALR", "BASR", "BR", "BCR",
            "AP", "SP", "MP", "DP", "ZAP", "PACK", "UNPK", "TR", "TRT", "EX", "SVC"
        ]
        return Array(Set(sized + x86Branches + ibm)).sorted()
    }()
}

private extension UIColor {
    convenience init(codeSnippetHex value: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }
}
