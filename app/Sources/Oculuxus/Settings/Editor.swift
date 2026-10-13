import AppKit
import os

/// A line in a source file, to open in the user's editor.
struct EditorTarget: Hashable {
    var file: String
    var line: Int
}

/// The editor Open in Editor uses.
enum EditorChoice: String, CaseIterable, Identifiable {
    /// $VISUAL or $EDITOR when it names a known editor, then the first
    /// installed one, then the file's default app.
    case automatic
    case vscode, zed, goland, sublime, xcode
    /// A command template with {file} and {line}.
    case custom
    /// The app the file opens with in Finder; no line.
    case defaultApp

    var id: String { rawValue }

    var name: String {
        switch self {
        case .automatic: "Automatic"
        case .vscode: "Visual Studio Code"
        case .zed: "Zed"
        case .goland: "GoLand"
        case .sublime: "Sublime Text"
        case .xcode: "Xcode"
        case .custom: "Custom Command"
        case .defaultApp: "Default App"
        }
    }

    /// Editors Automatic picks from when $VISUAL and $EDITOR do not say,
    /// in order. Xcode is left out: it is often installed but rarely the
    /// editor someone uses for Go.
    static let automaticOrder: [EditorChoice] = [.vscode, .zed, .goland, .sublime]

    /// The editor a $VISUAL or $EDITOR value names, if it is one with a
    /// preset: "code --wait" is VS Code. Terminal editors (vim, emacs -nw)
    /// have no window to open in, so they name none.
    static func named(byEnvironment value: String) -> EditorChoice? {
        guard let command = value.split(separator: " ").first else { return nil }
        switch (command as NSString).lastPathComponent {
        case "code", "code-insiders", "codium": return .vscode
        case "zed", "zeditor": return .zed
        case "goland": return .goland
        case "subl": return .sublime
        case "xed": return .xcode
        default: return nil
        }
    }
}

/// How an editor preset is started.
struct EditorPreset {
    /// Command-line tools to look for on PATH.
    var commands: [String]
    var bundleIDs: [String]
    /// The command-line tool inside the app bundle, used when none is on
    /// PATH. Nil runs the app with `open -na App --args`.
    var bundledCommand: String?
    var arguments: (EditorTarget) -> [String]

    static func preset(_ choice: EditorChoice) -> EditorPreset? {
        switch choice {
        case .vscode:
            EditorPreset(commands: ["code"], bundleIDs: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"],
                         bundledCommand: "Contents/Resources/app/bin/code") { ["-g", "\($0.file):\($0.line)"] }
        case .zed:
            EditorPreset(commands: ["zed"], bundleIDs: ["dev.zed.Zed", "dev.zed.Zed-Preview"],
                         bundledCommand: "Contents/MacOS/cli") { ["\($0.file):\($0.line)"] }
        case .goland:
            // JetBrains' own recommendation without the shell launcher;
            // a running GoLand takes the file over from the new instance.
            EditorPreset(commands: ["goland"], bundleIDs: ["com.jetbrains.goland", "com.jetbrains.goland-EAP"],
                         bundledCommand: nil) { ["--line", "\($0.line)", $0.file] }
        case .sublime:
            EditorPreset(commands: ["subl"], bundleIDs: ["com.sublimetext.4", "com.sublimetext.3"],
                         bundledCommand: "Contents/SharedSupport/bin/subl") { ["\($0.file):\($0.line)"] }
        case .xcode:
            // /usr/bin/xed is only a shim without Xcode, so look in Xcode first.
            EditorPreset(commands: [], bundleIDs: ["com.apple.dt.Xcode"],
                         bundledCommand: "Contents/Developer/usr/bin/xed") { ["--line", "\($0.line)", $0.file] }
        case .automatic, .custom, .defaultApp:
            nil
        }
    }
}

/// What running Open in Editor does.
enum EditorLaunch: Equatable {
    case run(executable: String, arguments: [String])
    /// A custom command line for /bin/sh.
    case shell(String)
    case defaultApp
}

/// Turns the editor setting and a target into a launch. The lookups are
/// parameters so tests can supply them.
struct EditorResolver {
    /// Directories to search for command-line tools.
    var path: [String]
    /// Where the app with a bundle identifier is installed.
    var appURL: (String) -> URL?
    var isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    /// $VISUAL and $EDITOR, as the login shell sets them.
    var environment: [String: String] = [:]

    func launch(_ choice: EditorChoice, customCommand: String, target: EditorTarget) -> EditorLaunch {
        switch choice {
        case .automatic:
            guard let editor = automaticEditor() else { return .defaultApp }
            return launch(editor, customCommand: customCommand, target: target)
        case .custom:
            let template = customCommand.trimmingCharacters(in: .whitespaces)
            return template.isEmpty ? .defaultApp : .shell(Self.expand(template, target: target))
        case .defaultApp:
            return .defaultApp
        default:
            guard let preset = EditorPreset.preset(choice) else { return .defaultApp }
            if let command = preset.commands.lazy.compactMap(find).first {
                return .run(executable: command, arguments: preset.arguments(target))
            }
            guard let app = preset.bundleIDs.lazy.compactMap(appURL).first else { return .defaultApp }
            if let bundled = preset.bundledCommand {
                let tool = app.appending(path: bundled).path
                if isExecutable(tool) { return .run(executable: tool, arguments: preset.arguments(target)) }
            }
            return .run(executable: "/usr/bin/open", arguments: ["-na", app.path, "--args"] + preset.arguments(target))
        }
    }

    /// The editor Automatic uses, or nil for the default app.
    func automaticEditor() -> EditorChoice? {
        for name in ["VISUAL", "EDITOR"] {
            if let value = environment[name], let editor = EditorChoice.named(byEnvironment: value), isInstalled(editor) {
                return editor
            }
        }
        return EditorChoice.automaticOrder.first(where: isInstalled)
    }

    func isInstalled(_ choice: EditorChoice) -> Bool {
        guard let preset = EditorPreset.preset(choice) else { return false }
        return preset.commands.contains { find($0) != nil } || preset.bundleIDs.contains { appURL($0) != nil }
    }

    private func find(_ command: String) -> String? {
        path.lazy.map { $0 + "/" + command }.first(where: isExecutable)
    }

    /// Replaces {file} and {line} in a command template, quoting the file
    /// for the shell.
    static func expand(_ template: String, target: EditorTarget) -> String {
        template
            .replacingOccurrences(of: "{file}", with: shellQuoted(target.file))
            .replacingOccurrences(of: "{line}", with: String(target.line))
    }

    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension EditorResolver {
    /// Looks on the login shell's PATH and the usual locations, and asks
    /// Launch Services for installed apps.
    static func system() -> EditorResolver {
        let env = LoginShell.variables()
        let path = HelperEnvironment.unique(
            (env["PATH"] ?? "").split(separator: ":").map(String.init)
                + ["/opt/homebrew/bin", "/usr/local/bin", FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin"]
        )
        return EditorResolver(
            path: path,
            appURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
            environment: env
        )
    }
}

/// Runs Open in Editor.
@MainActor
enum EditorLauncher {
    private static let log = Logger(subsystem: "com.herbygillot.oculuxus", category: "editor")

    static func open(_ target: EditorTarget, settings: AppSettings) {
        let choice = settings.editor
        let custom = settings.customEditorCommand
        Task.detached {
            // Reading the login shell can take a moment the first time.
            let launch = EditorResolver.system().launch(choice, customCommand: custom, target: target)
            await run(launch, target: target)
        }
    }

    private static func run(_ launch: EditorLaunch, target: EditorTarget) {
        let process = Process()
        switch launch {
        case .defaultApp:
            NSWorkspace.shared.open(URL(fileURLWithPath: target.file))
            return
        case let .run(executable, arguments):
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        case let .shell(command):
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
        }
        log.info("open in editor: \(String(describing: launch), privacy: .public)")
        process.environment = HelperEnvironment.environment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        process.terminationHandler = { process in
            guard process.terminationStatus != 0 else { return }
            let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Task { @MainActor in
                fail(command: launch, message: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        do {
            try process.run()
        } catch {
            fail(command: launch, message: error.localizedDescription)
        }
    }

    private static func fail(command: EditorLaunch, message: String) {
        let alert = NSAlert()
        alert.messageText = "Could Not Open the Editor"
        var text: String
        switch command {
        case let .run(executable, arguments): text = ([executable] + arguments).joined(separator: " ")
        case let .shell(line): text = line
        case .defaultApp: text = ""
        }
        if !message.isEmpty { text += "\n\n" + String(message.suffix(1000)) }
        alert.informativeText = text + "\n\nChoose another editor in the Font, Colors, Go and Editor popover."
        alert.runModal()
    }
}
