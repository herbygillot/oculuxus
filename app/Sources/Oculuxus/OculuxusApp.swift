import AppKit
import SwiftUI

@main
struct OculuxusApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var state = AppState()

    var body: some Scene {
        Window("Navigator", id: WindowID.navigator) {
            NavigatorWindow()
                .environment(state)
        }
        .defaultSize(width: 320, height: 700)
        .commands {
            ProjectCommands(state: state)
            GoCommands(state: state)
            ViewCommands(settings: state.settings)
        }

        WindowGroup("Workspace", id: WindowID.workspace, for: UUID.self) { $id in
            WorkspaceWindow(workspace: state.workspace(id))
                .environment(state)
        } defaultValue: {
            UUID()
        }
        .defaultSize(width: 1000, height: 700)
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

struct ViewCommands: Commands {
    @Bindable var settings: AppSettings

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Toggle("Show Code from Tests", isOn: $settings.showsTests)
                .keyboardShortcut("t", modifiers: [.command, .shift])
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

/// The initial frames: the Navigator takes the left quarter of the screen
/// and Workspaces the remaining three quarters.
enum WindowLayout {
    static let navigatorShare: CGFloat = 0.25

    static func navigatorFrame(on screen: NSScreen?) -> NSRect? {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return nil }
        var frame = visible
        frame.size.width = (visible.width * navigatorShare).rounded()
        return frame
    }

    static func workspaceFrame(on screen: NSScreen?, cascade: Int) -> NSRect? {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return nil }
        let navigatorWidth = (visible.width * navigatorShare).rounded()
        var frame = visible
        frame.origin.x += navigatorWidth
        frame.size.width -= navigatorWidth
        // Later Workspaces step down and in so earlier ones stay visible.
        let offset = CGFloat(cascade % 8) * 24
        frame.origin.x += offset
        frame.size.width -= offset
        frame.size.height -= offset
        return frame
    }
}
