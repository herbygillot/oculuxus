import AppKit

/// Open panels for picking a project folder and a Go binary.
@MainActor
enum GoBinaryPanel {
    /// Asks for a Go binary under any name (go, go1.27.1, ...).
    static func choose(message: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Go Binary"
        panel.message = message
        panel.prompt = "Use"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = GoToolchain.pickerDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}

@MainActor
enum ProjectPanel {
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Open Go Project"
        panel.message = "Choose a folder with a go.work or go.mod file."
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
