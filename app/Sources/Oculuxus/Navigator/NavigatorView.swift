import SwiftUI

/// The Navigator window. It hides itself while a Workspace is full screen,
/// because the Navigator is docked in that Workspace then.
struct NavigatorWindow: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigatorView()
            .frame(minWidth: 220, minHeight: 300)
            .background(WindowAccessor { window in
                state.navigatorWindow = window
                if let frame = WindowLayout.navigatorFrame(on: window.screen) {
                    window.setFrame(frame, display: true)
                }
                // Open the folder given on the command line, or reopen the
                // last project.
                if state.session == nil, let dir = AppState.launchProject ?? state.settings.recentProjects.first,
                   FileManager.default.fileExists(atPath: dir) {
                    Task { await state.openProject(dir, openWindow: openWindow) }
                }
            })
    }
}

/// The project picker and the package list.
struct NavigatorView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ProjectPicker()
                if let session = state.session {
                    TargetButton(session: session)
                }
                LayoutPicker(settings: state.settings)
            }
            .padding(8)
            Divider()
            if let session = state.session {
                SessionView(session: session)
            } else {
                ContentUnavailableView {
                    Label("No Project", systemImage: "folder")
                } description: {
                    Text("Open a folder with a go.mod or go.work file.")
                } actions: {
                    Button("Open Folder…") { state.chooseProject(openWindow: openWindow) }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}

/// The open project: its packages once listed, or what is happening.
private struct SessionView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    var session: ProjectSession

    var body: some View {
        Group {
            switch session.status {
            case let .opening(message):
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(message).foregroundStyle(.secondary).font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .needsGoToolchain(message):
                ContentUnavailableView {
                    Label("Go Not Found", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Choose Go Binary…") { chooseGo(message) }
                }
                .frame(maxHeight: .infinity)
            case let .failed(message):
                ContentUnavailableView {
                    Label("Could Not Open", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message).textSelection(.enabled)
                } actions: {
                    Button("Try Again") { Task { await state.retry(session, goBinary: nil, openWindow: openWindow) } }
                }
                .frame(maxHeight: .infinity)
            case .ready:
                PackageList(listing: session.listing)
            }
        }
        .onChange(of: session.status, initial: true) { _, status in
            // Ask for a Go binary right away; the button stays for a retry.
            if case let .needsGoToolchain(message) = status {
                DispatchQueue.main.async { chooseGo(message) }
            }
        }
    }

    private func chooseGo(_ message: String) {
        guard let path = GoBinaryPanel.choose(message: "Oculuxus needs a Go toolchain to load this project. \(message)") else { return }
        Task { await state.retry(session, goBinary: path, openWindow: openWindow) }
    }
}

/// Recent projects and Open Folder.
private struct ProjectPicker: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            ForEach(state.settings.recentProjects, id: \.self) { dir in
                Toggle(isOn: Binding(
                    get: { state.session?.rootDir == dir },
                    set: { _ in Task { await state.openProject(dir, openWindow: openWindow) } }
                )) {
                    Text((dir as NSString).lastPathComponent)
                    Text((dir as NSString).abbreviatingWithTildeInPath)
                }
            }
            if !state.settings.recentProjects.isEmpty { Divider() }
            Button("Open Folder…") { state.chooseProject(openWindow: openWindow) }
        } label: {
            Label(state.session?.name ?? "Open Project", systemImage: "folder")
        }
        .help(state.session?.rootDir ?? "Open a Go project")
    }
}

/// Shows the project's build target and changes it in a popover.
private struct TargetButton: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    var session: ProjectSession
    @State private var editing = false

    var body: some View {
        Button { editing.toggle() } label: {
            Image(systemName: session.target.isDefault ? "cpu" : "cpu.fill")
        }
        .buttonStyle(.borderless)
        .help(session.target.summary.map { "Build target: \($0)" } ?? "Build tags and target platform")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            TargetEditor(target: session.target) { target in
                editing = false
                Task { await state.setBuildTarget(target, openWindow: openWindow) }
            }
        }
    }
}

/// Edits build tags and GOOS/GOARCH. Apply reopens the project.
struct TargetEditor: View {
    private enum Choice: Hashable {
        case current
        case preset(BuildTarget.Platform)
        case custom
    }

    let target: BuildTarget
    var apply: (BuildTarget) -> Void
    @State private var choice: Choice
    @State private var goos: String
    @State private var goarch: String
    @State private var tags: String

    init(target: BuildTarget, apply: @escaping (BuildTarget) -> Void) {
        self.target = target
        self.apply = apply
        let platform = target.platform
        _choice = State(initialValue: platform.map { BuildTarget.presets.contains($0) ? .preset($0) : .custom } ?? .current)
        _goos = State(initialValue: target.goos)
        _goarch = State(initialValue: target.goarch)
        _tags = State(initialValue: target.tags.joined(separator: ","))
    }

    private var edited: BuildTarget {
        var edited = BuildTarget(tags: BuildTarget.parseTags(tags))
        switch choice {
        case .current: edited.platform = nil
        case let .preset(platform): edited.platform = platform
        case .custom:
            edited.goos = goos.trimmingCharacters(in: .whitespaces)
            edited.goarch = goarch.trimmingCharacters(in: .whitespaces)
        }
        return edited
    }

    var body: some View {
        Form {
            Picker("Platform", selection: $choice) {
                Text("Current").tag(Choice.current)
                ForEach(BuildTarget.presets) { Text($0.id).tag(Choice.preset($0)) }
                Text("Custom").tag(Choice.custom)
            }
            if choice == .custom {
                TextField("GOOS", text: $goos, prompt: Text("linux"))
                TextField("GOARCH", text: $goarch, prompt: Text("arm64"))
            }
            TextField("Build Tags", text: $tags, prompt: Text("integration,purego"))
                .help("Separated by commas or spaces, as for go build -tags")
            HStack {
                Button("Reset") { apply(BuildTarget()) }
                    .disabled(target.isDefault)
                Spacer()
                Button("Apply") { apply(edited) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(edited == target)
            }
        }
        .formStyle(.grouped)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Switches the package list between a tree and a flat list.
private struct LayoutPicker: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Picker("Layout", selection: $settings.navigatorLayout) {
            ForEach(NavigatorLayout.allCases) { layout in
                Label(layout.title, systemImage: layout.systemImage)
                    .help("Show packages as a \(layout == .tree ? "tree" : "flat list")")
                    .tag(layout)
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .labelsHidden()
        .fixedSize()
    }
}

/// Project packages, dependencies by module, and the standard library, as
/// a tree or a flat list.
private struct PackageList: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    var listing: PackageListing
    @State private var stdlibExpanded = false
    @State private var collapsedModules: Set<String> = []
    /// Tree folders whose expansion differs from the default: expanded in
    /// the project, collapsed elsewhere.
    @State private var toggledNodes: Set<String> = []
    @State private var selectedPackageID: String?

    var body: some View {
        let layout = state.settings.navigatorLayout
        let outline = NavigatorOutline(listing, layout: layout)
        List(selection: $selectedPackageID) {
            Section("Project") {
                PackageNodes(nodes: outline.project, expanded: nodeExpanded)
            }
            Section("Dependencies") {
                ForEach(outline.dependencies) { module in
                    DisclosureGroup(isExpanded: moduleExpanded(module.group.module)) {
                        PackageNodes(nodes: module.nodes, expanded: nodeExpanded)
                    } label: {
                        ModuleLabel(module: module.group.module)
                    }
                }
                DisclosureGroup(isExpanded: $stdlibExpanded) {
                    PackageNodes(nodes: outline.stdlib, expanded: nodeExpanded)
                } label: {
                    Label("Standard Library", systemImage: "books.vertical")
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: String.self) { _ in
        } primaryAction: { ids in
            // Double-click or Return: show the package, opening a
            // Workspace if none is open.
            guard let id = ids.first else { return }
            show(id, newWindow: ClickModifiers.opensNewWorkspace)
        }
        .onChange(of: selectedPackageID) { _, id in
            // A single click follows along in the open Workspace; with no
            // Workspace open it only selects, and double-click opens one.
            guard let id, id != activePackageID else { return }
            if ClickModifiers.opensNewWorkspace {
                show(id, newWindow: true)
            } else if state.activeWorkspace != nil {
                show(id, newWindow: false)
            }
        }
        .onChange(of: activePackageID, initial: true) { _, id in
            guard let id else { return }
            selectedPackageID = id
            // Reveal packages that were opened by following a reference.
            reveal(id, in: outline)
        }
        .onChange(of: layout) { _, layout in
            // Keep the selected package in view in the other layout.
            if let id = selectedPackageID { reveal(id, in: NavigatorOutline(listing, layout: layout)) }
        }
    }

    private var activePackageID: String? {
        state.activeWorkspace?.location?.packageID
    }

    private func show(_ packageID: String, newWindow: Bool) {
        state.show(WorkspaceLocation(packageID: packageID), newWindow: newWindow, openWindow: openWindow)
    }

    /// Expands the groups and folders that contain the package.
    private func reveal(_ packageID: String, in outline: NavigatorOutline) {
        guard let pkg = listing.byID[packageID] else { return }
        if pkg.origin == .stdlib { stdlibExpanded = true }
        collapsedModules.remove(moduleKey(pkg.modulePath, pkg.moduleVersion))
        for id in outline.ancestors(of: packageID) ?? [] {
            nodeExpanded(id).wrappedValue = true
        }
    }

    private func moduleKey(_ path: String, _ version: String) -> String { path + "@" + version }

    private func moduleExpanded(_ module: OcxModule) -> Binding<Bool> {
        let key = moduleKey(module.path, module.version)
        return Binding(
            get: { !collapsedModules.contains(key) },
            set: { expanded in
                if expanded { collapsedModules.remove(key) } else { collapsedModules.insert(key) }
            }
        )
    }

    private func nodeExpanded(_ id: String) -> Binding<Bool> {
        let byDefault = id.hasPrefix("project:")
        return Binding(
            get: { toggledNodes.contains(id) != byDefault },
            set: { expanded in
                if expanded == byDefault { toggledNodes.remove(id) } else { toggledNodes.insert(id) }
            }
        )
    }
}

/// Package rows, with folders and packages that contain others as
/// disclosure groups.
private struct PackageNodes: View {
    var nodes: [PackageNode]
    var expanded: (String) -> Binding<Bool>

    var body: some View {
        ForEach(nodes) { node in
            if node.children.isEmpty {
                if let pkg = node.package { PackageRow(package: pkg, label: node.name) }
            } else {
                DisclosureGroup(isExpanded: expanded(node.id)) {
                    PackageNodes(nodes: node.children, expanded: expanded)
                } label: {
                    if let pkg = node.package {
                        PackageRow(package: pkg, label: node.name)
                    } else {
                        Label(node.name, systemImage: "folder")
                    }
                }
            }
        }
    }
}

private struct PackageRow: View {
    var package: OcxPackage
    var label: String

    var body: some View {
        Label(label, systemImage: "shippingbox")
            .lineLimit(1)
            .truncationMode(.middle)
            .help(package.importPath)
            .tag(package.id)
    }
}

private struct ModuleLabel: View {
    var module: OcxModule

    var body: some View {
        HStack(spacing: 4) {
            Label(module.path, systemImage: "cube")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(module.version)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help("\(module.path) \(module.version)")
    }
}
