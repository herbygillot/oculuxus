import AppKit
import SwiftUI

@main
struct OculuxusApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("Workspace", id: WindowID.workspace, for: UUID.self) { $id in
            WorkspaceWindow(id: id)
                .environment(state)
        } defaultValue: {
            UUID()
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            ProjectCommands(state: state)
            GoCommands(state: state)
            ViewCommands(settings: state.settings)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Windows are laid out fresh on every launch.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        // Run as a regular app when launched as a bare executable (swift run).
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Send every helper Shutdown and wait briefly for it to exit.
        HelperClient.shutdownAll()
    }
}

struct FocusedWorkspaceKey: FocusedValueKey {
    typealias Value = WorkspaceModel
}

extension FocusedValues {
    var workspace: WorkspaceModel? {
        get { self[FocusedWorkspaceKey.self] }
        set { self[FocusedWorkspaceKey.self] = newValue }
    }
}

struct ProjectCommands: Commands {
    var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") { state.chooseProject(openWindow: openWindow) }
                .keyboardShortcut("o", modifiers: .command)
            Menu("Open Recent") {
                ForEach(state.settings.recentProjects, id: \.self) { dir in
                    Button((dir as NSString).abbreviatingWithTildeInPath) {
                        Task { await state.openProject(dir, openWindow: openWindow) }
                    }
                }
            }
            .disabled(state.settings.recentProjects.isEmpty)
        }
    }
}

struct GoCommands: Commands {
    var state: AppState
    @FocusedValue(\.workspace) private var workspace
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Go") {
            Button("Jump to Symbol…") { state.showSymbolSearch(openWindow: openWindow) }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(state.session?.status != .ready)
            Button("Open in Editor") {
                if let target = workspace?.editorTarget { EditorLauncher.open(target, settings: state.settings) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(workspace?.editorTarget == nil)
            Divider()
            Button("Find References") { find(.references) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!canFind)
            Button("Find Callers") { find(.callers) }
                .keyboardShortcut("h", modifiers: [.command, .control, .shift])
                .disabled(!canFind)
            Button("Find Callees") { find(.callees) }
                .disabled(!canFind)
            Button(workspace?.references == nil ? "Show References Panel" : "Hide References Panel") {
                if workspace?.references != nil { workspace?.closeReferences() } else { find(.references) }
            }
            .disabled(workspace == nil)
            Divider()
            Button("Back") { workspace?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!(workspace?.canGoBack ?? false))
            Button("Forward") { workspace?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!(workspace?.canGoForward ?? false))
        }
    }
}

extension GoCommands {
    private var canFind: Bool {
        workspace?.location != nil && state.session?.status == .ready
    }

    /// Finds references to, or callers or callees of, the identifier at
    /// the source viewer's insertion point or the selected declaration.
    private func find(_ tab: ReferencesTab) {
        guard let workspace, let session = state.session, let location = workspace.location,
              let subject = workspace.currentSubject(tests: session.includesTests(location.packageID, showsTests: state.settings.showsTests))
        else {
            NSSound.beep()
            return
        }
        workspace.showReferences(subject, tab: tab, session: session)
    }
}

struct ViewCommands: Commands {
    @Bindable var settings: AppSettings
    @FocusedValue(\.workspace) private var workspace

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button(workspace?.sidebar.isCollapsed ?? false ? "Show Navigator" : "Hide Navigator") {
                workspace?.sidebar.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(workspace == nil)
        }
        CommandGroup(after: .toolbar) {
            Toggle("Show Code from Tests", isOn: $settings.showsTests)
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Picker("Documentation", selection: $settings.docDisplay) {
                ForEach(DocDisplay.allCases) { Text($0.title).tag($0) }
            }
            Picker("Show Packages", selection: $settings.navigatorLayout) {
                Text("Packages as Tree").tag(NavigatorLayout.tree)
                    .keyboardShortcut("1", modifiers: [.command, .control])
                Text("Packages as List").tag(NavigatorLayout.flat)
                    .keyboardShortcut("2", modifiers: [.command, .control])
            }
            .pickerStyle(.inline)
            Divider()
        }
    }
}

/// Hands the hosting NSWindow to `configure` once the view is in a window.
struct WindowAccessor: NSViewRepresentable {
    var configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = AccessorView()
        view.configure = configure
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class AccessorView: NSView {
        var configure: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let configure else { return }
            self.configure = nil
            DispatchQueue.main.async { configure(window) }
        }
    }
}

/// The initial frame of a Workspace window: the screen's visible area,
/// stepped down and in for later ones.
enum WindowLayout {
    static func workspaceFrame(on screen: NSScreen?, cascade: Int) -> NSRect? {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return nil }
        var frame = visible
        // Later Workspaces step down and in so earlier ones stay visible.
        let offset = CGFloat(cascade % 8) * 24
        frame.origin.x += offset
        frame.size.width -= offset
        frame.size.height -= offset
        return frame
    }
}
