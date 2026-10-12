import AppKit
import Foundation

/// Turns protocol text into attributed strings, and references into URLs
/// that views can hand back when a reference is clicked.
enum CodeText {
    static let scheme = "oculuxus"

    static func url(for ref: OcxSymbolRef) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "ref"
        components.queryItems = [
            URLQueryItem(name: "package", value: ref.packageID),
            URLQueryItem(name: "declaration", value: ref.declarationID),
        ]
        return components.url
    }

    static func location(from url: URL) -> WorkspaceLocation? {
        guard url.scheme == scheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let packageID = items.first(where: { $0.name == "package" })?.value
        else { return nil }
        let declarationID = items.first { $0.name == "declaration" }?.value
        return WorkspaceLocation(packageID: packageID, declarationID: declarationID?.isEmpty == false ? declarationID : nil)
    }

    /// Converts a UTF-8 byte range of `string` to an NSRange.
    static func nsRange(_ range: OcxRange, in string: String) -> NSRange? {
        let utf8 = string.utf8
        guard range.start <= range.end, Int(range.end) <= utf8.count else { return nil }
        let start = utf8.index(utf8.startIndex, offsetBy: Int(range.start))
        let end = utf8.index(start, offsetBy: Int(range.end - range.start))
        return NSRange(start..<end, in: string)
    }

    static func attributed(_ text: OcxText, theme: CodeTheme, font: NSFont) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: text.text, attributes: [
            .font: font,
            .foregroundColor: theme.text,
        ])
        for token in text.tokens {
            guard let range = nsRange(token.range, in: text.text) else { continue }
            result.addAttribute(.foregroundColor, value: theme.color(for: token.type), range: range)
            if token.modifiers & OcxTokenModifier.definition.rawValue != 0 {
                result.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: range)
            }
            if token.hasTarget, let url = url(for: token.target) {
                result.addAttribute(.link, value: url, range: range)
            }
        }
        return result
    }
}
