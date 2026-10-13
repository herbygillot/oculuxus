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
    /// The editor Open in Editor uses.
    var editor: EditorChoice { didSet { save() } }
    /// The command for EditorChoice.custom, with {file} and {line}.
    var customEditorCommand: String { didSet { save() } }
    /// What Automatic resolves to, once known: nil for the default app.
    private(set) var automaticEditor: EditorChoice??
    /// Workspaces show the Navigator as a sidebar, not only in full screen,
    /// and the Navigator window stays hidden while one is open.
    var docksNavigator: Bool { didSet { save() } }
    /// The outline's share of a new Workspace's width, from the last time
    /// the user dragged the divider; nil to widen the pane clicked.
    var workspaceSplit: Double? { didSet { save() } }
    /// Build tags and target platform by project folder; projects with the
    /// default target are left out.
    private(set) var buildTargets: [String: BuildTarget] { didSet { save() } }
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
        editor = defaults.string(forKey: "editor").flatMap(EditorChoice.init(rawValue:)) ?? .automatic
        customEditorCommand = defaults.string(forKey: "customEditorCommand") ?? ""
        docksNavigator = defaults.bool(forKey: "docksNavigator")
        buildTargets = defaults.data(forKey: "buildTargets").flatMap { try? JSONDecoder().decode([String: BuildTarget].self, from: $0) } ?? [:]
        workspaceSplit = defaults.object(forKey: "workspaceSplit") as? Double
        Task { [weak self] in
            // Off the main thread: it may read the login shell.
            let editor = await Task.detached { EditorResolver.system().automaticEditor() }.value
            self?.automaticEditor = .some(editor)
        }
    }

    func addRecentProject(_ rootDir: String) {
        recentProjects = Array(([rootDir] + recentProjects.filter { $0 != rootDir }).prefix(10))
    }

    func removeRecentProject(_ rootDir: String) {
        recentProjects.removeAll { $0 == rootDir }
    }

    func buildTarget(for rootDir: String) -> BuildTarget {
        buildTargets[rootDir] ?? BuildTarget()
    }

    func setBuildTarget(_ target: BuildTarget, for rootDir: String) {
        buildTargets[rootDir] = target.isDefault ? nil : target
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
        defaults.set(editor.rawValue, forKey: "editor")
        defaults.set(customEditorCommand, forKey: "customEditorCommand")
        defaults.set(docksNavigator, forKey: "docksNavigator")
        defaults.set(workspaceSplit, forKey: "workspaceSplit")
        defaults.set(try? JSONEncoder().encode(buildTargets), forKey: "buildTargets")
    }
}

struct SettingsPopover: View {
    @Bindable var settings: AppSettings

    private var automaticName: String {
        guard let resolved = settings.automaticEditor else { return "Automatic" }
        return "Automatic (\((resolved ?? .defaultApp).name))"
    }

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
            Toggle("Dock Navigator in Workspace", isOn: $settings.docksNavigator)
                .help("Show the Navigator as a sidebar in each Workspace instead of in its own window (⌘0)")
            Picker("Editor", selection: $settings.editor) {
                ForEach(EditorChoice.allCases) { choice in
                    Text(choice == .automatic ? automaticName : choice.name).tag(choice)
                }
            }
            .help("Where Open in Editor (⇧⌘E) opens a declaration or file")
            if settings.editor == .custom {
                TextField("Command", text: $settings.customEditorCommand, prompt: Text("mate -l {line} {file}"))
                    .help("Run with /bin/sh. {file} is replaced by the quoted file path and {line} by the line number.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }
}
