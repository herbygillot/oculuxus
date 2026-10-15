import AppKit
import Observation
import SwiftUI

/// Where a Workspace is looking: a package, and optionally one of its
/// declarations. A reference or a call site adds a file and line, which
/// the source viewer shows selected, in the declaration when it contains
/// the line and in the whole file otherwise.
struct WorkspaceLocation: Hashable, Codable {
    var packageID: String
    var declarationID: String?
    var file: String?
    var line: Int?
}

/// One Workspace window: a package content pane and a source viewer, with
/// its own back/forward history.
@Observable
@MainActor
final class WorkspaceModel: Identifiable {
    let id: UUID
    private(set) var history: [WorkspaceLocation] = []
    private(set) var index = -1
    var isFullScreen = false
    /// The source viewer shows the selected declaration's whole file.
    var showsWholeFile = false
    /// The file and line the source viewer shows, for Open in Editor.
    var editorTarget: EditorTarget?
    weak var window: NSWindow?
    /// Set once the window is closed. SwiftUI may still evaluate a closed
    /// window's content, so a closed model must never be shown in again.
    var isClosed = false
    /// How the panes share the width.
    var split = WorkspaceSplitLayout()
    /// The Navigator sidebar: pinned or collapsed, its width, and its peek.
    let sidebar: NavigatorSidebar
    /// The references and call hierarchy panel at the bottom, once opened.
    var references: ReferencesModel?
    /// The identifier at the source viewer's insertion point, when the
    /// source viewer has focus; set by the source viewer.
    @ObservationIgnored var sourceSubject: (() -> ReferenceSubject?)?
    /// A press that has not resized the panes yet: an outline click, or a
    /// double-click in either pane, which waits until clickable targets
    /// under it have had their say.
    private struct PendingClick {
        var id: Int
        var pane: WorkspacePane
        var double: Bool
    }

    /// The pane last pressed in: Find References uses the source viewer's
    /// insertion point only after a press there.
    @ObservationIgnored private(set) var lastPane: WorkspacePane?
    @ObservationIgnored private var clicks = 0
    @ObservationIgnored private var pending: PendingClick?

    init(id: UUID, split: Double? = nil, sidebar: SidebarState = SidebarState()) {
        self.id = id
        self.sidebar = NavigatorSidebar(sidebar)
        self.split.manualShare = split
    }

    /// Gives `pane` the wide share, animated. After a drag only a
    /// double-click does, and the split stays manual.
    func widen(_ pane: WorkspacePane, doubleClick: Bool = false) {
        var next = split
        next.widen(pane, doubleClick: doubleClick)
        guard next != split else { return }
        withAnimation(.easeInOut(duration: 0.25)) { split = next }
    }

    /// A press in a pane, with its click count. A single click in the
    /// source viewer widens it at once. Everything else waits for the
    /// release, so that a press on a declaration row (`declarationClicked`)
    /// or another clickable target (`targetClicked`) can claim it. Releases
    /// lost to a tracking loop (a scroller) are covered by a timeout.
    func paneClicked(_ pane: WorkspacePane, _ phase: MousePhase, clicks count: Int = 1) {
        switch phase {
        case .down:
            lastPane = pane
            pending = nil
            if pane == .source, count < 2 {
                widen(.source)
                return
            }
            clicks += 1
            let click = PendingClick(id: clicks, pane: pane, double: count >= 2)
            pending = click
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.finishClick(click.id) }
        case .up:
            guard let click = pending, click.pane == pane else { return }
            // After the views have handled the release, which may select.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.finishClick(click.id) }
        }
    }

    func finishClick(_ id: Int) {
        guard let click = pending, click.id == id else { return }
        pending = nil
        if click.double {
            paneDoubleClicked(click.pane)
        } else {
            widen(click.pane)
        }
    }

    /// A double-click on a pane that no clickable target claimed: that pane
    /// gets the wide share, and a dragged split goes back to automatic
    /// sizing, as when the divider is double-clicked.
    func paneDoubleClicked(_ pane: WorkspacePane) {
        withAnimation(.easeInOut(duration: 0.25)) {
            split.manualShare = nil
            split.widePane = pane
        }
    }

    /// A declaration was clicked in the outline: the user wants to read it.
    /// A double-click on its row widens the source viewer even over a
    /// dragged split, which stays manual.
    func declarationClicked() {
        let doubleClick = pending?.double == true && pending?.pane == .outline
        pending = nil
        widen(.source, doubleClick: doubleClick)
    }

    /// A clickable target (a link, a disclosure toggle, a button) handled
    /// the click: a double-click on it leaves the panes alone. A single
    /// click still widens its pane.
    func targetClicked() {
        if pending?.double == true { pending = nil }
    }

    var location: WorkspaceLocation? {
        history.indices.contains(index) ? history[index] : nil
    }

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < history.count }

    func go(to location: WorkspaceLocation) {
        guard location != self.location else { return }
        history.removeSubrange((index + 1)...)
        history.append(location)
        index = history.count - 1
    }

    /// Selects a declaration without adding a history entry, so history
    /// steps between packages and followed references, not every click.
    func select(_ declarationID: String?) {
        guard var location else { return }
        location.declarationID = declarationID
        location.file = nil
        location.line = nil
        history[index] = location
    }

    func goBack() { if canGoBack { index -= 1 } }
    func goForward() { if canGoForward { index += 1 } }

    /// Forgets the history; used when another project is opened.
    func reset() {
        history = []
        index = -1
        references?.cancel()
        references = nil
    }

    /// What Find References applies to: the identifier at the insertion
    /// point in the source viewer, or the selected declaration.
    func currentSubject(tests: Bool) -> ReferenceSubject? {
        if lastPane == .source, let subject = sourceSubject?() { return subject }
        guard let location, let id = location.declarationID else { return nil }
        return ReferenceSubject(symbol: OcxSymbolRef(packageID: location.packageID, declarationID: id), name: id, tests: tests)
    }

    /// Opens the panel on `subject`'s references, callers or callees.
    func showReferences(_ subject: ReferenceSubject, tab: ReferencesTab = .references, session: ProjectSession) {
        if let references, references.session === session {
            references.show(subject, tab: tab)
        } else {
            references?.cancel()
            let model = ReferencesModel(session: session)
            model.show(subject, tab: tab)
            references = model
        }
    }

    func closeReferences() {
        references?.cancel()
        references = nil
    }
}

@Observable
@MainActor
final class AppState {
    let settings: AppSettings
    /// The open project, if any.
    private(set) var session: ProjectSession?

    private(set) var workspaces: [UUID: WorkspaceModel] = [:]
    /// Workspaces whose windows have closed. SwiftUI can still evaluate a
    /// closed window's content, which must not bring its Workspace back.
    @ObservationIgnored private var closedWorkspaceIDs: Set<UUID> = []
    /// The Workspace that was most recently key.
    private(set) var lastActiveWorkspaceID: UUID?
    /// Whether the project from the command line, or the last one, was
    /// opened at launch.
    @ObservationIgnored private var openedLaunchProject = false

    init(settings: AppSettings? = nil) {
        self.settings = settings ?? AppSettings()
    }

    /// A new Workspace takes the last active one's sidebar state, or the
    /// one saved last.
    func workspace(_ id: UUID) -> WorkspaceModel {
        if let model = workspaces[id] { return model }
        let model = WorkspaceModel(id: id, split: settings.workspaceSplit, sidebar: activeWorkspace?.sidebar.savedState ?? settings.navigatorSidebar)
        model.sidebar.onChange = { [weak settings] in settings?.navigatorSidebar = $0 }
        if closedWorkspaceIDs.contains(id) {
            model.isClosed = true
        } else {
            workspaces[id] = model
        }
        return model
    }

    func workspaceBecameActive(_ id: UUID) {
        guard !closedWorkspaceIDs.contains(id) else { return }
        lastActiveWorkspaceID = id
        // The active Workspace's sidebar is the default for the next launch.
        if let model = workspaces[id] { settings.navigatorSidebar = model.sidebar.savedState }
    }

    func workspaceClosed(_ id: UUID) {
        closedWorkspaceIDs.insert(id)
        if let model = workspaces[id] {
            model.isClosed = true
            model.window = nil
        }
        workspaces[id] = nil
        if lastActiveWorkspaceID == id {
            lastActiveWorkspaceID = workspaces.values.first { !$0.isClosed && $0.window != nil }?.id
        }
    }

    /// The last active Workspace, or nil when no Workspace window is open.
    var activeWorkspace: WorkspaceModel? {
        guard let id = lastActiveWorkspaceID, let model = workspaces[id], !model.isClosed else { return nil }
        return model
    }

    /// Shows `location` in the last active Workspace, or in a new one when
    /// `newWindow` is set or no Workspace is open. Without `openWindow`
    /// (in tests) the new Workspace gets no window.
    func show(_ location: WorkspaceLocation, newWindow: Bool, openWindow: OpenWindowAction?) {
        if !newWindow, let workspace = activeWorkspace {
            workspace.go(to: location)
            workspace.window?.makeKeyAndOrderFront(nil)
            return
        }
        let workspace = workspace(UUID())
        workspace.go(to: location)
        lastActiveWorkspaceID = workspace.id
        openWindow?(id: WindowID.workspace, value: workspace.id)
    }

    /// Opens the Go project in `rootDir`, replacing the open one. Once its
    /// packages are listed, the active Workspace (or a new one) shows the
    /// first project package.
    func openProject(_ rootDir: String, openWindow: OpenWindowAction?) async {
        if let session, session.rootDir == rootDir, session.status == .ready {
            // Already open: show it again if every Workspace was closed.
            settings.addRecentProject(rootDir)
            await showFirstPackage(of: session, openWindow: openWindow)
            return
        }
        session?.close()
        searchPanel?.close()
        searchModel = nil
        let session = ProjectSession(rootDir: rootDir, goBinary: settings.goBinary, target: settings.buildTarget(for: rootDir))
        self.session = session
        settings.addRecentProject(rootDir)
        for workspace in workspaces.values { workspace.reset() }
        await session.open()
        await showFirstPackage(of: session, openWindow: openWindow)
    }

    /// Opens the session again with a Go binary the user picked, and
    /// remembers the choice.
    func retry(_ session: ProjectSession, goBinary: String?, openWindow: OpenWindowAction?) async {
        if let goBinary { settings.goBinary = goBinary }
        await session.open(goBinary: goBinary)
        await showFirstPackage(of: session, openWindow: openWindow)
        if goBinary != nil, case .needsGoToolchain = session.status {
            // The pick did not work; do not keep it.
            settings.goBinary = nil
        }
    }

    /// Loads the open project again with other build tags or another
    /// platform, and remembers them for the project. Workspaces keep their
    /// places and reload what they show.
    func setBuildTarget(_ target: BuildTarget, openWindow: OpenWindowAction?) async {
        guard let session, target != session.target else { return }
        settings.setBuildTarget(target, for: session.rootDir)
        await session.reopen(target: target)
        await showFirstPackage(of: session, openWindow: openWindow)
    }

    private func showFirstPackage(of session: ProjectSession, openWindow: OpenWindowAction?) async {
        guard session === self.session, session.status == .ready else { return }
        if activeWorkspace?.location != nil { return }
        if let first = session.listing.projectPackages.first {
            show(WorkspaceLocation(packageID: first.id), newWindow: false, openWindow: openWindow)
        }
    }

    // MARK: Symbol search

    @ObservationIgnored private var searchPanel: SymbolSearchPanel?
    @ObservationIgnored private(set) var searchModel: SymbolSearchModel?

    /// Shows the ⌘K panel over the active Workspace. It keeps the last
    /// query for the same project.
    func showSymbolSearch(openWindow: OpenWindowAction?) {
        guard let session, session.status == .ready else {
            NSSound.beep()
            return
        }
        let previousKey = NSApp.keyWindow
        let model = searchModel?.session === session ? searchModel! : SymbolSearchModel(session: session, includeDependencies: settings.searchesDependencies)
        searchModel = model
        let panel = searchPanel ?? SymbolSearchPanel()
        searchPanel = panel
        let open: (OcxSymbolMatch, Bool) -> Void = { [weak self, weak panel] match, newWindow in
            panel?.close()
            self?.show(SymbolSearchModel.location(of: match), newWindow: newWindow, openWindow: openWindow)
        }
        panel.onCommandReturn = { [weak model] in
            if let match = model?.selected { open(match, true) }
        }
        let view = SymbolSearchView(
            model: model,
            theme: settings.theme,
            font: settings.font,
            open: open,
            close: { [weak panel] in
                panel?.close()
                previousKey?.makeKeyAndOrderFront(nil)
            }
        )
        .onChange(of: model.includeDependencies) { [weak self] _, value in self?.settings.searchesDependencies = value }
        panel.contentView = NSHostingView(rootView: view)
        panel.position(over: activeWorkspace?.window ?? previousKey)
        panel.makeKeyAndOrderFront(nil)
        if !model.query.isEmpty { model.search(keepSelection: true) }
    }

    /// A folder passed on the command line (`swift run Oculuxus DIR`).
    static var launchProject: String? {
        var isDir: ObjCBool = false
        return CommandLine.arguments.dropFirst()
            .first { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue }
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    /// Opens the folder given on the command line, or the last project,
    /// when the first Workspace appears.
    func openLaunchProject(openWindow: OpenWindowAction?) {
        guard !openedLaunchProject else { return }
        openedLaunchProject = true
        guard session == nil, let dir = Self.launchProject ?? settings.recentProjects.first,
              FileManager.default.fileExists(atPath: dir) else { return }
        Task { await openProject(dir, openWindow: openWindow) }
    }

    /// Asks for a project folder and opens it.
    func chooseProject(openWindow: OpenWindowAction) {
        guard let dir = ProjectPanel.choose() else { return }
        Task { await openProject(dir, openWindow: openWindow) }
    }
}

enum WindowID {
    static let workspace = "workspace"
}

/// Decides whether a click should open a new Workspace.
enum ClickModifiers {
    static var opensNewWorkspace: Bool {
        NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
    }
}
