//
//  CodeSnippetConfiguration.swift
//  BeanNotes
//

import Foundation
import UIKit

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
            ["section", "global", "extern", "mov", "lea", "push", "pop", "call", "ret", "jmp", "cmp", "test", "je", "jne", "jg", "jl", "add", "sub", "mul", "div", "and", "or", "xor", "not", "shl", "shr"]
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
        Array(keywords.prefix(80))
    }

    private static let cKeywords = [
        "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "true", "false", "NULL"
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
    static let handwritingByDefaultKey = "codeSnippet.handwritingToCodeByDefault"

    static let defaultLanguage: CodeSnippetLanguage = .python
    static let defaultFont: CodeSnippetFontChoice = .systemMono
    static let defaultFontSize: Double = 16
    static let defaultBackgroundStyle: CodeSnippetBackgroundStyle = .automatic
    static let defaultHandwritingByDefault = true
    static let supportedFontSize = 10.0...32.0

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
        let fontSize = defaults.object(forKey: defaultFontSizeKey) == nil
            ? defaultFontSize
            : normalizedFontSize(defaults.double(forKey: defaultFontSizeKey))
        let usesHandwriting = defaults.object(forKey: handwritingByDefaultKey) == nil
            ? defaultHandwritingByDefault
            : defaults.bool(forKey: handwritingByDefaultKey)

        return CodeSnippetDraft(
            code: "",
            language: language,
            font: font,
            fontSize: fontSize,
            backgroundStyle: background,
            preferredInputMode: usesHandwriting ? .handwriting : .text
        )
    }

    static func normalizePersistedValues(in defaults: UserDefaults = .standard) {
        let draft = defaultDraft(in: defaults)
        defaults.set(draft.language.rawValue, forKey: defaultLanguageKey)
        defaults.set(draft.font.rawValue, forKey: defaultFontKey)
        defaults.set(draft.fontSize, forKey: defaultFontSizeKey)
        defaults.set(draft.backgroundStyle.rawValue, forKey: defaultBackgroundStyleKey)
        if defaults.object(forKey: handwritingByDefaultKey) == nil {
            defaults.set(defaultHandwritingByDefault, forKey: handwritingByDefaultKey)
        }
    }

    static func normalizedFontSize(_ value: Double) -> Double {
        guard value.isFinite else { return defaultFontSize }
        return min(max(value, supportedFontSize.lowerBound), supportedFontSize.upperBound)
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
    var preferredInputMode: CodeSnippetInputMode

    init(
        id: UUID = UUID(),
        code: String,
        language: CodeSnippetLanguage,
        font: CodeSnippetFontChoice,
        fontSize: Double,
        backgroundStyle: CodeSnippetBackgroundStyle,
        preferredInputMode: CodeSnippetInputMode
    ) {
        self.id = id
        self.code = code
        self.language = language
        self.font = font
        self.fontSize = CodeSnippetPreferences.normalizedFontSize(fontSize)
        self.backgroundStyle = backgroundStyle
        self.preferredInputMode = preferredInputMode
    }

    init(editing attachment: Attachment, defaults: CodeSnippetDraft) {
        self.init(
            id: attachment.id,
            code: attachment.codeSnippetText ?? "",
            language: CodeSnippetLanguage(rawValue: attachment.codeSnippetLanguageRaw ?? "")
                ?? defaults.language,
            font: CodeSnippetFontChoice(rawValue: attachment.codeSnippetFontRaw ?? "")
                ?? defaults.font,
            fontSize: attachment.codeSnippetFontSize ?? defaults.fontSize,
            backgroundStyle: CodeSnippetBackgroundStyle(
                rawValue: attachment.codeSnippetBackgroundRaw ?? ""
            ) ?? defaults.backgroundStyle,
            preferredInputMode: .text
        )
    }
}

enum CodeSyntaxHighlighter {
    static let maximumHighlightedUTF16Length = 60_000

    static func attributedString(
        for code: String,
        language: CodeSnippetLanguage,
        font: UIFont,
        foregroundColor: UIColor
    ) -> NSAttributedString {
        let base = NSMutableAttributedString(
            string: code,
            attributes: [
                .font: font,
                .foregroundColor: foregroundColor
            ]
        )
        guard base.length > 0, base.length <= maximumHighlightedUTF16Length else { return base }

        let palette = Palette(foregroundColor: foregroundColor)
        apply(pattern: #"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"#, color: palette.number, to: base)

        if !language.keywords.isEmpty {
            let escaped = language.keywords.map(NSRegularExpression.escapedPattern(for:))
            let keywordOptions: NSRegularExpression.Options =
                language == .visualBasic || language == .assembly ? [.caseInsensitive] : []
            apply(
                pattern: "\\b(?:\(escaped.joined(separator: "|")))\\b",
                options: keywordOptions,
                color: palette.keyword,
                to: base
            )
        }

        switch language {
        case .html, .xml:
            apply(pattern: #"</?[A-Za-z][^>]*>"#, color: palette.keyword, to: base)
            apply(pattern: #"\b[A-Za-z_:][-A-Za-z0-9_:.]*(?=\s*=)"#, color: palette.attribute, to: base)
        case .css:
            apply(pattern: #"[-A-Za-z]+(?=\s*:)"#, color: palette.attribute, to: base)
            apply(pattern: #"[#.][-_A-Za-z][-_A-Za-z0-9]*"#, color: palette.keyword, to: base)
        case .markdown:
            apply(pattern: #"(?m)^#{1,6}\s.*$"#, color: palette.keyword, to: base)
            apply(pattern: #"`{1,3}[^`]+`{1,3}"#, color: palette.string, to: base)
            apply(pattern: #"\[[^\]]+\]\([^\)]+\)"#, color: palette.attribute, to: base)
        case .ini:
            apply(pattern: #"(?m)^\s*\[[^\]]+\]"#, color: palette.keyword, to: base)
            apply(pattern: #"(?m)^\s*[^=;#\n]+(?=\s*=)"#, color: palette.attribute, to: base)
        default:
            break
        }

        let stringRanges = matchingRanges(
            pattern: #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#,
            in: base.string
        )
        let commentRanges = commentPatterns(for: language).flatMap { pattern in
            matchingRanges(
                pattern: pattern,
                in: base.string
            ).filter { !contains($0.location, in: stringRanges) }
        }

        apply(color: palette.comment, to: commentRanges, in: base)
        apply(
            color: palette.string,
            to: stringRanges.filter { !contains($0.location, in: commentRanges) },
            in: base
        )
        return base
    }

    private static func commentPatterns(for language: CodeSnippetLanguage) -> [String] {
        switch language {
        case .python, .ruby:
            [#"(?m)#.*$"#]
        case .matlab:
            [#"(?m)%.*$"#]
        case .assembly:
            [#"(?m);.*$"#, #"(?m)^\s*#.*$"#]
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

    private static func apply(
        pattern: String,
        options: NSRegularExpression.Options = [],
        color: UIColor,
        to text: NSMutableAttributedString
    ) {
        apply(color: color, to: matchingRanges(pattern: pattern, options: options, in: text.string), in: text)
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

    private static func apply(
        color: UIColor,
        to ranges: [NSRange],
        in text: NSMutableAttributedString
    ) {
        for range in ranges where NSMaxRange(range) <= text.length {
            text.addAttribute(.foregroundColor, value: color, range: range)
        }
    }

    private struct Palette {
        var keyword: UIColor
        var string: UIColor
        var number: UIColor
        var comment: UIColor
        var attribute: UIColor

        init(foregroundColor: UIColor) {
            var white: CGFloat = 0
            let isDarkSurface = foregroundColor.getWhite(&white, alpha: nil) && white > 0.55
            if isDarkSurface {
                keyword = UIColor(red: 0.78, green: 0.58, blue: 1, alpha: 1)
                string = UIColor(red: 0.62, green: 0.86, blue: 0.56, alpha: 1)
                number = UIColor(red: 1, green: 0.72, blue: 0.47, alpha: 1)
                comment = UIColor(red: 0.52, green: 0.61, blue: 0.67, alpha: 1)
                attribute = UIColor(red: 0.47, green: 0.78, blue: 1, alpha: 1)
            } else {
                keyword = UIColor(red: 0.45, green: 0.16, blue: 0.7, alpha: 1)
                string = UIColor(red: 0.08, green: 0.45, blue: 0.16, alpha: 1)
                number = UIColor(red: 0.75, green: 0.28, blue: 0.08, alpha: 1)
                comment = UIColor(red: 0.37, green: 0.45, blue: 0.48, alpha: 1)
                attribute = UIColor(red: 0.02, green: 0.38, blue: 0.7, alpha: 1)
            }
        }
    }
}
