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
            // Observed on the window itself: SwiftUI can tear this view down
            // before willClose is posted, and onReceive would miss it.
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated {
                    if workspace.isFullScreen { setDocked(false) }
                    state.workspaceClosed(workspace.id)
                }
                if let observer { NotificationCenter.default.removeObserver(observer) }
            }
            let cascade = max(state.workspaces.count - 1, 0)
            if let frame = WindowLayout.workspaceFrame(on: window.screen, cascade: cascade) {
                window.setFrame(frame, display: true)
            }
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if isOwnWindow(note) { state.workspaceBecameActive(workspace.id) }
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
        Group {
            if let session = state.session, let location = workspace.location {
                PackagePanes(session: session, workspace: workspace, location: location, open: open)
            } else {
                ContentUnavailableView("No Package", systemImage: "shippingbox", description: Text("Pick a package in the Navigator."))
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(state.session?.name ?? "")
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
                @Bindable var workspace = workspace
                Picker("Source", selection: $workspace.showsWholeFile) {
                    Text("Declaration").tag(false)
                    Text("File").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Show the selected declaration or its whole file")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings.toggle() } label: { Image(systemName: "textformat.size") }
                    .help("Font, Colors and Go")
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                        SettingsPopover(settings: state.settings)
                    }
            }
        }
    }

    private var title: String {
        guard let location = workspace.location else { return "Workspace" }
        return state.session?.package(location.packageID)?.importPath ?? location.packageID
    }

    private func open(_ location: WorkspaceLocation, newWindow: Bool) {
        if newWindow {
            state.show(location, newWindow: true, openWindow: openWindow)
        } else {
            workspace.go(to: location)
        }
    }
}

/// Something loaded from the helper.
enum Loadable<Value> {
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case let .loaded(value) = self { return value }
        return nil
    }
}

/// The outline of the Workspace's package and the source viewer. The
/// outline loads when the package changes; leaving the package before it
/// arrives cancels the request.
private struct PackagePanes: View {
    @Environment(AppState.self) private var state
    var session: ProjectSession
    var workspace: WorkspaceModel
    var location: WorkspaceLocation
    var open: (WorkspaceLocation, Bool) -> Void
    @State private var outline: Loadable<OcxPackageOutline> = .loading

    var body: some View {
        let settings = state.settings
        HSplitView {
            Group {
                switch outline {
                case .loading:
                    Placeholder(theme: settings.theme) {
                        ProgressView("Type-checking \(location.packageID)…").controlSize(.small)
                    }
                case let .failed(message):
                    Placeholder(theme: settings.theme) {
                        ContentUnavailableView("Could Not Load Package", systemImage: "exclamationmark.triangle", description: Text(message))
                    }
                case let .loaded(outline):
                    PackageContentView(
                        outline: outline,
                        package: session.package(location.packageID),
                        selectedID: location.declarationID,
                        theme: settings.theme,
                        font: settings.font,
                        select: { workspace.select($0) },
                        openReference: open
                    )
                }
            }
            .frame(minWidth: 280, idealWidth: 460)

            SourcePane(
                session: session,
                location: location,
                outline: outline.value,
                wholeFile: workspace.showsWholeFile,
                open: open
            )
            .frame(minWidth: 280)
        }
        .task(id: location.packageID) {
            if outline.value?.packageID != location.packageID { outline = .loading }
            do {
                outline = .loaded(try await session.outline(location.packageID))
            } catch is CancellationError {
            } catch {
                outline = .failed(error.localizedDescription)
            }
        }
    }
}

/// The source of the selected declaration, or of a whole file with the
/// declaration highlighted. With nothing selected it shows the package's
/// first file.
private struct SourcePane: View {
    @Environment(AppState.self) private var state
    var session: ProjectSession
    var location: WorkspaceLocation
    var outline: OcxPackageOutline?
    var wholeFile: Bool
    var open: (WorkspaceLocation, Bool) -> Void

    /// What is shown, with the file and line it starts at.
    private struct Shown {
        var source: OcxFileSourceResponse
        var file: String
        var line: UInt32
    }

    private struct Request: Hashable {
        var packageID: String
        var declarationID: String?
        var file: String?
    }

    @State private var shown: Shown?
    @State private var error: String?
    @State private var loading = false
    /// A file picked from the file menu; cleared when the selection changes.
    @State private var pickedFile: String?

    var body: some View {
        let settings = state.settings
        VStack(spacing: 0) {
            header
            Divider()
            if let error {
                Placeholder(theme: settings.theme) {
                    ContentUnavailableView("Could Not Load Source", systemImage: "exclamationmark.triangle", description: Text(error))
                }
            } else {
                SourceView(
                    file: shown?.source,
                    highlightedDeclarationID: request?.file != nil ? location.declarationID : nil,
                    theme: settings.theme,
                    font: settings.font,
                    openReference: open
                )
            }
        }
        .task(id: request) { await load() }
        .onChange(of: location) { pickedFile = nil }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let outline, request?.file != nil, outline.files.count > 1 {
                Menu {
                    ForEach(outline.files, id: \.path) { file in
                        Button(file.name) { pickedFile = file.path }
                    }
                } label: {
                    Text(headerTitle)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Text(headerTitle)
            }
            Spacer()
            if loading { ProgressView().controlSize(.mini) }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Color(nsColor: state.settings.theme.background))
        .environment(\.colorScheme, state.settings.theme.isDark ? .dark : .light)
    }

    private var headerTitle: String {
        guard let shown else { return " " }
        let name = (shown.file as NSString).lastPathComponent
        return shown.line > 0 ? "\(name):\(shown.line)" : name
    }

    /// What to load: a declaration, or a file when the whole file is wanted,
    /// nothing is selected, or a file was picked.
    private var request: Request? {
        guard let outline, outline.packageID == location.packageID else { return nil }
        let declaration = location.declarationID.flatMap { find($0, in: outline.declarations) }
        if let declaration, !wholeFile, pickedFile == nil {
            return Request(packageID: location.packageID, declarationID: declaration.id)
        }
        guard let file = pickedFile ?? declaration?.location.file ?? outline.files.first?.path else { return nil }
        return Request(packageID: location.packageID, file: file)
    }

    private func load() async {
        guard let request else {
            if outline != nil { shown = nil }
            return
        }
        loading = true
        defer { loading = false }
        do {
            if let file = request.file {
                let source = try await session.fileSource(packageID: request.packageID, file: file)
                shown = Shown(source: source, file: file, line: 0)
            } else {
                let decl = try await session.declarationSource(WorkspaceLocation(packageID: request.packageID, declarationID: request.declarationID))
                var source = OcxFileSourceResponse()
                source.source = decl.source
                shown = Shown(source: source, file: decl.location.file, line: decl.location.line)
            }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func find(_ id: String, in decls: [OcxDeclaration]) -> OcxDeclaration? {
        for decl in decls {
            if decl.id == id { return decl }
            if let found = find(id, in: decl.members) { return found }
        }
        return nil
    }
}

/// Centers `content` on the theme's background.
private struct Placeholder<Content: View>: View {
    var theme: CodeTheme
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: theme.background))
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }
}
