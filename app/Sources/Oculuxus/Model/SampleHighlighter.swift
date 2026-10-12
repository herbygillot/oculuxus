// A small Go tokenizer used only to give the sample data highlight spans.
// The real spans come from the helper, which uses go/types; this one
// guesses from spelling and from the names declared in the sample.

import Foundation

struct SampleHighlighter {
    /// What an identifier refers to, as far as the sample knows.
    struct Symbol {
        var type: OcxTokenType
        var target: OcxSymbolRef?
    }

    /// Resolves an identifier. `qualifier` is the identifier before a
    /// preceding dot, if any (the package name in `io.Reader`).
    var resolve: (_ name: String, _ qualifier: String?) -> Symbol?

    static let keywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else",
        "fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
        "map", "package", "range", "return", "select", "struct", "switch", "type", "var",
    ]

    static let builtins: Set<String> = [
        "any", "append", "bool", "byte", "cap", "close", "comparable", "complex",
        "complex128", "complex64", "copy", "delete", "error", "false", "float32",
        "float64", "imag", "int", "int16", "int32", "int64", "int8", "iota", "len",
        "make", "max", "min", "new", "nil", "panic", "print", "println", "real",
        "recover", "rune", "string", "true", "uint", "uint16", "uint32", "uint64",
        "uint8", "uintptr",
    ]

    func highlight(_ source: String) -> OcxText {
        let bytes = Array(source.utf8)
        var tokens: [OcxToken] = []
        var i = 0
        var lastIdent: (name: String, end: Int)?
        var lastKeyword = ""

        func add(_ start: Int, _ end: Int, _ type: OcxTokenType, _ modifiers: UInt32 = 0, _ target: OcxSymbolRef? = nil) {
            tokens.append(OcxToken(range: OcxRange(start: UInt32(start), end: UInt32(end)), type: type, modifiers: modifiers, target: target))
        }
        func isIdentByte(_ b: UInt8) -> Bool {
            (b >= 97 && b <= 122) || (b >= 65 && b <= 90) || (b >= 48 && b <= 57) || b == 95 || b >= 0x80
        }

        while i < bytes.count {
            let b = bytes[i]
            let next: UInt8 = i + 1 < bytes.count ? bytes[i + 1] : 0
            if b == 47, next == 47 { // line comment
                let start = i
                while i < bytes.count, bytes[i] != 10 { i += 1 }
                add(start, i, .comment)
            } else if b == 47, next == 42 { // block comment
                let start = i
                i += 2
                while i + 1 < bytes.count, !(bytes[i] == 42 && bytes[i + 1] == 47) { i += 1 }
                i = min(i + 2, bytes.count)
                add(start, i, .comment)
            } else if b == 34 || b == 96 || b == 39 { // "string", `raw`, 'rune'
                let start = i
                i += 1
                while i < bytes.count, bytes[i] != b {
                    if bytes[i] == 92, b != 96 { i += 1 }
                    i += 1
                }
                i = min(i + 1, bytes.count)
                add(start, i, .string)
            } else if b >= 48 && b <= 57 {
                let start = i
                while i < bytes.count, isIdentByte(bytes[i]) || bytes[i] == 46 { i += 1 }
                add(start, i, .number)
            } else if isIdentByte(b) {
                let start = i
                while i < bytes.count, isIdentByte(bytes[i]) { i += 1 }
                let name = String(decoding: bytes[start..<i], as: UTF8.self)
                let qualified = start > 0 && bytes[start - 1] == 46
                let qualifier = qualified && lastIdent?.end == start - 1 ? lastIdent?.name : nil
                if Self.keywords.contains(name) {
                    add(start, i, .keyword)
                    lastKeyword = name
                } else if !qualified, Self.builtins.contains(name) {
                    add(start, i, .builtin)
                } else if let symbol = resolve(name, qualifier) {
                    let isDefinition = !qualified && (lastKeyword == "func" || lastKeyword == "type")
                    add(start, i, symbol.type, isDefinition ? OcxTokenModifier.definition.rawValue : 0, symbol.target)
                } else if i < bytes.count, bytes[i] == 40, !qualified {
                    add(start, i, .function)
                }
                if !Self.keywords.contains(name) { lastKeyword = "" }
                lastIdent = (name, i)
            } else {
                if b == 10 { lastKeyword = "" }
                i += 1
            }
        }
        return OcxText(text: source, tokens: tokens)
    }
}
