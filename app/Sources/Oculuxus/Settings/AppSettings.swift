import AppKit
import Observation
import SwiftUI

/// A color scheme for source text and signatures.
struct CodeTheme: Identifiable, Hashable {
    var id: String
    var name: String
    var isDark: Bool
    var background: NSColor
    var text: NSColor
    var colors: [OcxTokenType: NSColor]

    func color(for type: OcxTokenType) -> NSColor {
        colors[type] ?? text
    }

    static func == (a: CodeTheme, b: CodeTheme) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static let light = CodeTheme(
        id: "light", name: "Light", isDark: false,
        background: rgb(0xFFFFFF), text: rgb(0x1F1F24),
        colors: [
            .keyword: rgb(0x9B2393), .comment: rgb(0x5D6C79), .string: rgb(0xC41A16),
            .number: rgb(0x1C00CF), .builtin: rgb(0x6C36A9), .namespace: rgb(0x3E6D74),
            .typeName: rgb(0x0B4F79), .structName: rgb(0x0B4F79), .interfaceName: rgb(0x0B4F79),
            .typeParameter: rgb(0x0B4F79), .function: rgb(0x326D74), .methodName: rgb(0x326D74),
            .constant: rgb(0x1C00CF), .property: rgb(0x3E6D74),
        ]
    )

    static let dark = CodeTheme(
        id: "dark", name: "Dark", isDark: true,
        background: rgb(0x1F1F24), text: rgb(0xDFDFE0),
        colors: [
            .keyword: rgb(0xFF7AB2), .comment: rgb(0x7F8C98), .string: rgb(0xFF8170),
            .number: rgb(0xD9C97C), .builtin: rgb(0xB281EB), .namespace: rgb(0x78C2B3),
            .typeName: rgb(0x6BDFFF), .structName: rgb(0x6BDFFF), .interfaceName: rgb(0x6BDFFF),
            .typeParameter: rgb(0x6BDFFF), .function: rgb(0x67B7A4), .methodName: rgb(0x67B7A4),
            .constant: rgb(0xD9C97C), .property: rgb(0x78C2B3),
        ]
    )

    static let solarizedLight = CodeTheme(
        id: "solarized-light", name: "Solarized Light", isDark: false,
        background: rgb(0xFDF6E3), text: rgb(0x586E75),
        colors: [
            .keyword: rgb(0x859900), .comment: rgb(0x93A1A1), .string: rgb(0x2AA198),
            .number: rgb(0xD33682), .builtin: rgb(0xB58900), .namespace: rgb(0x6C71C4),
            .typeName: rgb(0xB58900), .structName: rgb(0xB58900), .interfaceName: rgb(0xB58900),
            .typeParameter: rgb(0xB58900), .function: rgb(0x268BD2), .methodName: rgb(0x268BD2),
            .constant: rgb(0xCB4B16), .property: rgb(0x6C71C4),
        ]
    )

    static let all = [light, dark, solarizedLight]
}

/// Settings shared by every window, persisted in user defaults.
@Observable
@MainActor
final class AppSettings {
    static let fontFamilies: [String] = {
        let fixed = NSFontManager.shared.availableFontFamilies.filter { family in
            NSFont(name: family, size: 12)?.isFixedPitch ?? false
        }
        return ["System Monospaced"] + fixed
    }()

    var fontFamily: String { didSet { save() } }
    var fontSize: Double { didSet { save() } }
    var themeID: String { didSet { save() } }
    /// The Go binary the user picked, or nil to find one automatically.
    var goBinary: String? { didSet { save() } }
    /// Show declarations from _test.go files in Workspaces.
    var showsTests: Bool { didSet { save() } }
    /// ⌘K searches dependencies and the standard library as well.
    var searchesDependencies: Bool { didSet { save() } }
    /// The Navigator lists packages as a tree or a flat list.
    var navigatorLayout: NavigatorLayout { didSet { save() } }
    /// Recently opened project folders, most recent first.
    private(set) var recentProjects: [String] { didSet { save() } }

    init() {
        let defaults = UserDefaults.standard
        fontFamily = defaults.string(forKey: "fontFamily") ?? "System Monospaced"
        let size = defaults.double(forKey: "fontSize")
        fontSize = size > 0 ? size : 13
        themeID = defaults.string(forKey: "theme") ?? CodeTheme.light.id
        goBinary = defaults.string(forKey: "goBinary")
        recentProjects = defaults.stringArray(forKey: "recentProjects") ?? []
        showsTests = defaults.bool(forKey: "showsTests")
        searchesDependencies = defaults.object(forKey: "searchesDependencies") as? Bool ?? true
        navigatorLayout = defaults.string(forKey: "navigatorLayout").flatMap(NavigatorLayout.init(rawValue:)) ?? .tree
    }

    func addRecentProject(_ rootDir: String) {
        recentProjects = Array(([rootDir] + recentProjects.filter { $0 != rootDir }).prefix(10))
    }

    func removeRecentProject(_ rootDir: String) {
        recentProjects.removeAll { $0 == rootDir }
    }

    var theme: CodeTheme {
        CodeTheme.all.first { $0.id == themeID } ?? .light
    }

    var font: NSFont {
        if fontFamily != "System Monospaced", let font = NSFont(name: fontFamily, size: fontSize) {
            return font
        }
        return .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(fontFamily, forKey: "fontFamily")
        defaults.set(fontSize, forKey: "fontSize")
        defaults.set(themeID, forKey: "theme")
        defaults.set(goBinary, forKey: "goBinary")
        defaults.set(recentProjects, forKey: "recentProjects")
        defaults.set(showsTests, forKey: "showsTests")
        defaults.set(searchesDependencies, forKey: "searchesDependencies")
        defaults.set(navigatorLayout.rawValue, forKey: "navigatorLayout")
    }
}

struct SettingsPopover: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Picker("Font", selection: $settings.fontFamily) {
                ForEach(AppSettings.fontFamilies, id: \.self) { Text($0).tag($0) }
            }
            LabeledContent("Size") {
                Stepper(value: $settings.fontSize, in: 9...32, step: 1) {
                    Text("\(Int(settings.fontSize)) pt").monospacedDigit()
                }
            }
            Picker("Colors", selection: $settings.themeID) {
                ForEach(CodeTheme.all) { Text($0.name).tag($0.id) }
            }
            LabeledContent("Go") {
                HStack {
                    Text(settings.goBinary ?? "Automatic")
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(settings.goBinary == nil ? .secondary : .primary)
                        .help(settings.goBinary ?? "The first go on your login shell's PATH or in a common location")
                    Spacer()
                    Button("Choose…") {
                        if let path = GoBinaryPanel.choose(message: "Choose the Go binary Oculuxus uses. It applies the next time a project is opened.") {
                            settings.goBinary = path
                        }
                    }
                    if settings.goBinary != nil {
                        Button("Reset") { settings.goBinary = nil }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }
}
