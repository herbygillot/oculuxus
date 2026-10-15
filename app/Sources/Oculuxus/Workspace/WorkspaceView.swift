import AppKit
import SwiftUI

/// A Workspace window: the Navigator as a leading sidebar, pinned or
/// collapsed, and the Workspace. Tracks which Workspace was last active.
struct WorkspaceWindow: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    /// The Workspace this window shows, fixed when the window first
    /// appears. SwiftUI can later hand the window a value it saved in an
    /// earlier run (the app bundle restores the launch window's value after
    /// it is first shown); that id has no state, so it is ignored.
    @State private var id: UUID

    init(id: UUID) {
        _id = State(initialValue: id)
    }

    private var workspace: WorkspaceModel { state.workspace(id) }

    var body: some View {
        let workspace = workspace
        NavigatorSidebarLayout(sidebar: workspace.sidebar, window: workspace.window) {
            WorkspaceView(workspace: workspace)
        }
        .environment(\.navigatorWorkspace, workspace)
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
                    workspace.isFullScreen = false
                    state.workspaceClosed(workspace.id)
                }
                if let observer { NotificationCenter.default.removeObserver(observer) }
            }
            let cascade = max(state.workspaces.count - 1, 0)
            if let frame = WindowLayout.workspaceFrame(on: window.screen, cascade: cascade) {
                window.setFrame(frame, display: true)
            }
            state.openLaunchProject(openWindow: openWindow)
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if isOwnWindow(note) { state.workspaceBecameActive(workspace.id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
            if isOwnWindow(note) { setFullScreen(true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if isOwnWindow(note) { setFullScreen(false) }
        }
    }

    private func isOwnWindow(_ note: Notification) -> Bool {
        guard let window = workspace.window else { return false }
        return note.object as? NSWindow === window
    }

    private func setFullScreen(_ fullScreen: Bool) {
        workspace.isFullScreen = fullScreen
        workspace.sidebar.fullScreenChanged(fullScreen)
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
                VStack(spacing: 0) {
                    PackagePanes(session: session, workspace: workspace, location: location, open: open)
                    if let references = workspace.references {
                        ReferencesPanel(model: references, theme: state.settings.theme, font: state.settings.font, open: open, close: workspace.closeReferences)
                    }
                }
            } else {
                ContentUnavailableView("No Package", systemImage: "shippingbox", description: Text("Pick a package in the Navigator."))
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                SidebarToggle(sidebar: workspace.sidebar)
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
                Button {
                    if let target = workspace.editorTarget { EditorLauncher.open(target, settings: state.settings) }
                } label: {
                    Label("Open in Editor", systemImage: "arrow.up.forward.app")
                }
                .disabled(workspace.editorTarget == nil)
                .help("Open the declaration or file in your editor (⇧⌘E)")
            }
            ToolbarItem(placement: .primaryAction) {
                @Bindable var settings = state.settings
                Toggle(isOn: $settings.showsTests) {
                    Label("Tests", systemImage: "testtube.2")
                }
                .help(state.settings.showsTests ? "Hide code from _test.go files" : "Show code from _test.go files")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings.toggle() } label: { Image(systemName: "textformat.size") }
                    .help("Font, Colors, Go and Editor")
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

    /// The project, and its build target when not the default.
    private var subtitle: String {
        guard let session = state.session else { return "" }
        return [session.name, session.target.summary].compactMap { $0 }.joined(separator: " · ")
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

    /// What the outline depends on: reloading files bumps the revision.
    private struct OutlineRequest: Hashable {
        var packageID: String
        var tests: Bool
        var revision: Int
    }

    private var tests: Bool { session.includesTests(location.packageID, showsTests: state.settings.showsTests) }

    var body: some View {
        let settings = state.settings
        WorkspaceSplit(workspace: workspace, settings: settings) {
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
                        docDisplay: settings.docDisplay,
                        select: {
                            workspace.select($0)
                            workspace.declarationClicked()
                        },
                        openReference: { location, newWindow in
                            // A declaration clicked by name is for reading too.
                            if location.declarationID != nil, !newWindow {
                                workspace.declarationClicked()
                            } else {
                                workspace.targetClicked()
                            }
                            open(location, newWindow)
                        },
                        openInEditor: { EditorLauncher.open($0, settings: settings) },
                        targetClicked: workspace.targetClicked,
                        hoverCard: { symbol, rect in showHoverCard(symbol, rect) },
                        findReferences: { declaration, tab in
                            let subject = ReferenceSubject(symbol: OcxSymbolRef(packageID: outline.packageID, declarationID: declaration.id), name: declaration.name, tests: tests)
                            workspace.showReferences(subject, tab: tab, session: session)
                        }
                    )
                }
            }
        } source: {
            SourcePane(
                session: session,
                location: location,
                outline: outline.value,
                wholeFile: workspace.showsWholeFile,
                tests: tests,
                workspace: workspace,
                open: open
            )
        }
        .onChange(of: session.reloads) { workspace.references?.refresh() }
        .task(id: OutlineRequest(packageID: location.packageID, tests: tests, revision: session.revision(of: location.packageID))) {
            // Keep showing the current outline while the same package reloads.
            if outline.value?.packageID != location.packageID { outline = .loading }
            do {
                outline = .loaded(try await session.outline(location.packageID, tests: tests))
            } catch is CancellationError {
            } catch {
                outline = .failed(error.localizedDescription)
            }
        }
    }
}

extension PackagePanes {
    /// Shows the hover card for a declaration from an outline signature.
    private func showHoverCard(_ symbol: OcxSymbolRef, _ rect: NSRect) {
        guard let window = workspace.window else { return }
        let session = session
        let tests = session.includesTests(symbol.packageID, showsTests: state.settings.showsTests)
        HoverCardPresenter.shared.hover(
            key: "outline:\(symbol.packageID)#\(symbol.declarationID)@\(rect.origin.x),\(rect.origin.y)",
            anchor: rect,
            window: window,
            load: { try? await session.hover(symbol, tests: tests) },
            content: hoverCard
        )
    }

    private func hoverCard(_ hover: OcxHover, dismiss: @escaping () -> Void) -> HoverCardView {
        HoverCardView(hover: hover, theme: state.settings.theme, font: state.settings.font, open: open, dismiss: dismiss)
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
    var tests: Bool
    var workspace: WorkspaceModel
    var open: (WorkspaceLocation, Bool) -> Void

    /// What is shown, with the file and line it starts at.
    private struct Shown {
        var source: OcxFileSourceResponse
        var file: String
        var line: UInt32
        /// The byte offset of the text in its file.
        var fileOffset: UInt32 = 0
        /// The declaration or file shown, the same across reloads.
        var document: String
    }

    private struct Request: Hashable {
        var packageID: String
        var declarationID: String?
        var file: String?
        var tests: Bool
        var revision: Int

        var document: String { file ?? packageID + "#" + (declarationID ?? "") }
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
                    document: shown?.document,
                    highlightedDeclarationID: request?.file != nil ? location.declarationID : nil,
                    selectedLine: selectedLine,
                    theme: settings.theme,
                    font: settings.font,
                    firstLine: shown.map { EditorTarget(file: $0.file, line: max(Int($0.line), 1)) },
                    openReference: { location, newWindow in
                        workspace.targetClicked()
                        open(location, newWindow)
                    },
                    openInEditor: { EditorLauncher.open($0, settings: settings) },
                    linkDoubleClicked: workspace.targetClicked,
                    tokenActions: tokenActions
                )
            }
        }
        .task(id: request) { await load() }
        .onChange(of: location) { pickedFile = nil }
        .onChange(of: editorTarget, initial: true) { workspace.editorTarget = editorTarget }
        .onDisappear { workspace.editorTarget = nil }
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

    /// Where Open in Editor goes: the declaration's first line, or in a
    /// whole file the selected declaration when it is in that file.
    private var editorTarget: EditorTarget? {
        guard let shown else { return nil }
        if let line = location.line, location.file == shown.file { return EditorTarget(file: shown.file, line: line) }
        if shown.line > 0 { return EditorTarget(file: shown.file, line: Int(shown.line)) }
        if let outline, let id = location.declarationID, let decl = find(id, in: outline.declarations), decl.location.file == shown.file {
            return EditorTarget(file: shown.file, line: max(Int(decl.location.line), 1))
        }
        return EditorTarget(file: shown.file, line: 1)
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
        let revision = session.revision(of: location.packageID)
        if let declaration, !wholeFile, pickedFile == nil {
            return Request(packageID: location.packageID, declarationID: declaration.id, tests: tests, revision: revision)
        }
        let picked = pickedFile.flatMap { path in outline.files.contains { $0.path == path } ? path : nil }
        guard let file = picked ?? location.file ?? declaration?.location.file ?? outline.files.first?.path else { return nil }
        return Request(packageID: location.packageID, file: file, tests: tests, revision: revision)
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
                let source = try await session.fileSource(packageID: request.packageID, file: file, tests: request.tests)
                shown = Shown(source: source, file: file, line: 0, document: request.document)
            } else {
                let decl = try await session.declarationSource(WorkspaceLocation(packageID: request.packageID, declarationID: request.declarationID), tests: request.tests)
                if let file = location.file, let line = location.line, !Self.contains(decl, file: file, line: line) {
                    // A reference outside the declaration: show its file.
                    let source = try await session.fileSource(packageID: request.packageID, file: file, tests: request.tests)
                    shown = Shown(source: source, file: file, line: 0, document: file)
                } else {
                    var source = OcxFileSourceResponse()
                    source.source = decl.source
                    shown = Shown(source: source, file: decl.location.file, line: decl.location.line, fileOffset: decl.fileOffset, document: request.document)
                }
            }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Whether a declaration's source contains a line of `file`.
    static func contains(_ decl: OcxDeclarationSourceResponse, file: String, line: Int) -> Bool {
        guard decl.location.file == file else { return false }
        let first = Int(decl.location.line)
        let lines = decl.source.text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        return line >= first && line < first + lines
    }

    /// The reference's line within the shown text.
    private var selectedLine: Int? {
        guard let shown, let line = location.line, location.file == shown.file else { return nil }
        return shown.line > 0 ? line - Int(shown.line) + 1 : line
    }

    private var tokenActions: SourceTokenActions {
        SourceTokenActions(
            hover: { token, name, rect, view in showHoverCard(token, name: name, rect: rect, view: view) },
            endHover: { token in HoverCardPresenter.shared.leave(ObjectIdentifier(token)) },
            find: { token, name, tab in
                guard let subject = subject(for: token, name: name) else { return }
                workspace.showReferences(subject, tab: tab, session: session)
            },
            register: { tokenAtInsertionPoint in
                workspace.sourceSubject = { [self] in
                    tokenAtInsertionPoint().flatMap { subject(for: $0.0, name: $0.1) }
                }
            }
        )
    }

    /// The declaration a token refers to, or its position for a local.
    private func subject(for token: SourceToken, name: String) -> ReferenceSubject? {
        guard let shown else { return nil }
        if let target = token.target, !target.declarationID.isEmpty {
            return ReferenceSubject(symbol: target, name: name, tests: session.includesTests(target.packageID, showsTests: state.settings.showsTests))
        }
        var position = OcxPosition()
        position.file = shown.file
        position.offset = shown.fileOffset + token.start
        return ReferenceSubject(position: position, packageID: location.packageID, name: name, tests: tests)
    }

    private func showHoverCard(_ token: SourceToken, name: String, rect: NSRect, view: NSView) {
        guard let window = view.window, let subject = subject(for: token, name: name) else { return }
        let session = session
        // A package name or a declaration: by reference, cached; anything
        // else by its position.
        let load: @MainActor () async -> OcxHover?
        if let target = token.target {
            let tests = session.includesTests(target.packageID, showsTests: state.settings.showsTests)
            load = { try? await session.hover(target, tests: tests) }
        } else if let position = subject.position {
            load = { try? await session.hover(at: position, packageID: subject.packageID, tests: subject.tests) }
        } else {
            return
        }
        let settings = state.settings
        HoverCardPresenter.shared.hover(key: ObjectIdentifier(token), anchor: rect, window: window, load: load) { hover, dismiss in
            HoverCardView(hover: hover, theme: settings.theme, font: settings.font, open: open, dismiss: dismiss)
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
