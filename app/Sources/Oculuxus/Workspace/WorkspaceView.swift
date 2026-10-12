import AppKit
import SwiftUI

/// A Workspace window. Tracks which Workspace was last active, and docks
/// the Navigator as a sidebar while the window is full screen.
struct WorkspaceWindow: View {
    @Environment(AppState.self) private var state
    var workspace: WorkspaceModel

    var body: some View {
        Group {
            if workspace.isFullScreen {
                HSplitView {
                    NavigatorView()
                        .frame(minWidth: 200, idealWidth: 280, maxWidth: 480)
                    WorkspaceView(workspace: workspace)
                }
            } else {
                WorkspaceView(workspace: workspace)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .focusedSceneValue(\.workspace, workspace)
        .background(WindowAccessor { window in
            workspace.window = window
            state.workspaceBecameActive(workspace.id)
            let cascade = max(state.workspaces.count - 1, 0)
            if let frame = WindowLayout.workspaceFrame(on: window.screen, cascade: cascade) {
                window.setFrame(frame, display: true)
            }
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if isOwnWindow(note) { state.workspaceBecameActive(workspace.id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if isOwnWindow(note) {
                if workspace.isFullScreen { setDocked(false) }
                state.workspaceClosed(workspace.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
            if isOwnWindow(note) { setDocked(true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if isOwnWindow(note) { setDocked(false) }
        }
    }

    private func isOwnWindow(_ note: Notification) -> Bool {
        guard let window = workspace.window else { return false }
        return note.object as? NSWindow === window
    }

    private func setDocked(_ docked: Bool) {
        workspace.isFullScreen = docked
        state.dockedInWorkspaceID = docked ? workspace.id : nil
        if docked {
            state.navigatorWindow?.orderOut(nil)
        } else {
            state.navigatorWindow?.orderFront(nil)
        }
    }
}

/// The package content pane and the source viewer, split by a draggable
/// divider.
struct WorkspaceView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    var workspace: WorkspaceModel
    @State private var showSettings = false

    var body: some View {
        let settings = state.settings
        let project = state.project
        Group {
            if let location = workspace.location {
                let outline = project.outline(location.packageID)
                HSplitView {
                    PackageContentView(
                        outline: outline,
                        package: project.package(location.packageID),
                        selectedID: location.declarationID,
                        theme: settings.theme,
                        font: settings.font,
                        select: { workspace.select($0) },
                        openReference: open
                    )
                    .frame(minWidth: 280, idealWidth: 460)

                    SourceView(
                        file: sourceFile(outline: outline, declarationID: location.declarationID, project: project),
                        highlightedDeclarationID: location.declarationID,
                        theme: settings.theme,
                        font: settings.font,
                        openReference: open
                    )
                    .frame(minWidth: 280)
                }
            } else {
                ContentUnavailableView("No Package", systemImage: "shippingbox", description: Text("Pick a package in the Navigator."))
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(state.project.name)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { workspace.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!workspace.canGoBack)
                    .help("Back")
                Button { workspace.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!workspace.canGoForward)
                    .help("Forward")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings.toggle() } label: { Image(systemName: "textformat.size") }
                    .help("Font and Colors")
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                        SettingsPopover(settings: settings)
                    }
            }
        }
    }

    private var title: String {
        guard let location = workspace.location else { return "Workspace" }
        return state.project.package(location.packageID)?.importPath ?? location.packageID
    }

    private func open(_ location: WorkspaceLocation, newWindow: Bool) {
        if newWindow {
            state.show(location, newWindow: true, openWindow: openWindow)
        } else {
            workspace.go(to: location)
        }
    }

    /// The file that holds the selected declaration, or the package's first file.
    private func sourceFile(outline: OcxPackageOutline, declarationID: String?, project: SampleProject) -> OcxFileSourceResponse? {
        let path = declarationID.flatMap { find($0, in: outline.declarations)?.location.file } ?? outline.files.first?.path
        return path.flatMap { project.files[$0] }
    }

    private func find(_ id: String, in decls: [OcxDeclaration]) -> OcxDeclaration? {
        for decl in decls {
            if decl.id == id { return decl }
            if let found = find(id, in: decl.members) { return found }
        }
        return nil
    }
}
