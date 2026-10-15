import Foundation

/// How much of each declaration's doc comment the package content pane
/// shows under its signature.
enum DocDisplay: String, CaseIterable, Identifiable {
    /// Signatures only.
    case none
    /// The first sentence of each doc comment, and the whole comment of the
    /// selected declaration.
    case firstSentence
    /// Every doc comment in full.
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .firstSentence: "First Sentence"
        case .full: "Full"
        }
    }

    /// The text shown for a declaration's doc comment, or nil for none.
    func text(for doc: String, selected: Bool) -> String? {
        let doc = doc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !doc.isEmpty else { return nil }
        switch self {
        case .none: return nil
        case .full: return DocComment.reflowed(doc)
        case .firstSentence: return selected ? DocComment.reflowed(doc) : DocComment.firstSentence(doc)
        }
    }
}

enum DocComment {
    /// The doc comment with each prose paragraph on one line, to wrap to
    /// the pane's width. Indented lines, which are code blocks and lists,
    /// keep their line breaks.
    static func reflowed(_ doc: String) -> String {
        var out: [String] = []
        var prose = false
        for line in doc.split(separator: "\n", omittingEmptySubsequences: false) {
            let indented = line.first == " " || line.first == "\t"
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append("")
                prose = false
            } else if indented {
                out.append(String(line))
                prose = false
            } else if prose {
                out[out.count - 1] += " " + line
            } else {
                out.append(String(line))
                prose = true
            }
        }
        return out.joined(separator: "\n")
    }

    /// The first sentence of a doc comment, on one line, the way go/doc's
    /// Synopsis finds it: up to the end of the first paragraph or the first
    /// period followed by a space, unless the period follows a single
    /// capital letter, as in "J. Smith".
    static func firstSentence(_ doc: String) -> String {
        var paragraph: [String] = []
        for line in doc.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if paragraph.isEmpty { continue }
                break
            }
            paragraph.append(line)
        }
        let text = Array(paragraph.joined(separator: " "))
        var pp: Character = " ", p: Character = " "
        for (i, q) in text.enumerated() {
            if q == "." || q == "。" {
                let next = i + 1 < text.count ? text[i + 1] : " "
                let initial = p.isUppercase && !pp.isLetter
                if q == "。" || (next.isWhitespace && !initial) {
                    return String(text[...i])
                }
            }
            pp = p
            p = q
        }
        return String(text)
    }
}
