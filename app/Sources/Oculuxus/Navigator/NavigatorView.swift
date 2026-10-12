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
            ProjectPicker()
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

/// Project packages, dependencies by module, and the standard library.
private struct PackageList: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    var listing: PackageListing
    @State private var stdlibExpanded = false
    @State private var collapsedModules: Set<String> = []
    @State private var selectedPackageID: String?

    var body: some View {
        List(selection: $selectedPackageID) {
            Section("Project") {
                ForEach(listing.projectPackages) { pkg in
                    PackageRow(package: pkg, label: relativePath(pkg))
                }
            }
            Section("Dependencies") {
                ForEach(listing.dependencies) { group in
                    DisclosureGroup(isExpanded: moduleExpanded(group.module)) {
                        ForEach(group.packages) { pkg in
                            PackageRow(package: pkg, label: relativePath(pkg))
                        }
                    } label: {
                        ModuleLabel(module: group.module)
                    }
                }
                DisclosureGroup(isExpanded: $stdlibExpanded) {
                    ForEach(listing.stdlibPackages) { pkg in
                        PackageRow(package: pkg, label: pkg.importPath)
                    }
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
            if let pkg = listing.byID[id] {
                if pkg.origin == .stdlib { stdlibExpanded = true }
                collapsedModules.remove(moduleKey(pkg.modulePath, pkg.moduleVersion))
            }
        }
    }

    private var activePackageID: String? {
        state.activeWorkspace?.location?.packageID
    }

    private func show(_ packageID: String, newWindow: Bool) {
        state.show(WorkspaceLocation(packageID: packageID), newWindow: newWindow, openWindow: openWindow)
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

    /// The import path below the module, or the module's last element for
    /// its root package.
    private func relativePath(_ pkg: OcxPackage) -> String {
        guard !pkg.modulePath.isEmpty, pkg.importPath.hasPrefix(pkg.modulePath) else { return pkg.importPath }
        let rest = pkg.importPath.dropFirst(pkg.modulePath.count).drop { $0 == "/" }
        return rest.isEmpty ? String(pkg.modulePath.split(separator: "/").last ?? "") : String(rest)
    }
}

private struct PackageRow: View {
    var package: OcxPackage
    var label: String

    var body: some View {
        Label(label, systemImage: "shippingbox")
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
