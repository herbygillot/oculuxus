import Foundation

/// The build configuration a project is loaded for: build tags and a
/// GOOS/GOARCH pair. Empty fields mean the default: no tags, and the
/// platform Go targets on this Mac.
struct BuildTarget: Codable, Hashable {
    var tags: [String] = []
    var goos = ""
    var goarch = ""

    struct Platform: Hashable, Identifiable {
        var goos: String
        var goarch: String
        var id: String { "\(goos)/\(goarch)" }
    }

    /// The platforms offered besides the current one.
    static let presets = [
        Platform(goos: "linux", goarch: "amd64"),
        Platform(goos: "darwin", goarch: "arm64"),
        Platform(goos: "windows", goarch: "amd64"),
    ]

    var isDefault: Bool { tags.isEmpty && platform == nil }

    /// The chosen platform, or nil for the current one.
    var platform: Platform? {
        get { goos.isEmpty && goarch.isEmpty ? nil : Platform(goos: goos, goarch: goarch) }
        set {
            goos = newValue?.goos ?? ""
            goarch = newValue?.goarch ?? ""
        }
    }

    /// Tags as typed: separated by commas or spaces, as `go build -tags`
    /// accepts. Duplicates and empty entries are dropped.
    static func parseTags(_ text: String) -> [String] {
        var seen: Set<String> = []
        return text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
            .filter { seen.insert($0).inserted }
    }

    /// A short description, such as "linux/amd64 +integration", or nil for
    /// the default.
    var summary: String? {
        guard !isDefault else { return nil }
        let parts = [platform?.id] + tags.map { "+" + $0 }
        return parts.compactMap { $0 }.joined(separator: " ")
    }
}
