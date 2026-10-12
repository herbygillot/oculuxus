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
                if state.workspaces.isEmpty {
                    state.show(state.initialLocation, newWindow: true, openWindow: openWindow)
                }
            })
    }
}

/// The project picker and the package list.
struct NavigatorView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @State private var stdlibExpanded = false
    @State private var collapsedModules: Set<String> = []
    @State private var selectedPackageID: String?

    var body: some View {
        VStack(spacing: 0) {
            projectPicker
                .padding(8)
            Divider()
            List(selection: $selectedPackageID) {
                Section("Project") {
                    ForEach(projectPackages) { pkg in
                        PackageRow(package: pkg, label: relativePath(pkg))
                    }
                }
                Section("Dependencies") {
                    ForEach(dependencyModules, id: \.self) { module in
                        DisclosureGroup(isExpanded: moduleExpanded(module.path)) {
                            ForEach(packages(in: module)) { pkg in
                                PackageRow(package: pkg, label: relativePath(pkg))
                            }
                        } label: {
                            ModuleLabel(module: module)
                        }
                    }
                    DisclosureGroup(isExpanded: $stdlibExpanded) {
                        ForEach(stdlibPackages) { pkg in
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
                if let id { selectedPackageID = id }
            }
        }
    }

    private var activePackageID: String? {
        state.activeWorkspace?.location?.packageID
    }

    private func show(_ packageID: String, newWindow: Bool) {
        state.show(WorkspaceLocation(packageID: packageID), newWindow: newWindow, openWindow: openWindow)
    }

    private var projectPicker: some View {
        Picker(selection: Binding(
            get: { state.projectID },
            set: { state.switchProject(to: $0, openWindow: openWindow) }
        )) {
            ForEach(state.projects) { project in
                Text(project.name).tag(project.id)
            }
            // Opening real folders arrives with the helper in step 3.
        } label: {
            Image(systemName: "folder")
        }
        .help(state.project.rootDir)
    }

    private func moduleExpanded(_ path: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedModules.contains(path) },
            set: { expanded in
                if expanded { collapsedModules.remove(path) } else { collapsedModules.insert(path) }
            }
        )
    }

    private var listing: OcxListPackagesResponse { state.project.listing }

    private var projectPackages: [OcxPackage] {
        listing.packages.filter { $0.origin == .project }.sorted { $0.importPath < $1.importPath }
    }

    private var stdlibPackages: [OcxPackage] {
        listing.packages.filter { $0.origin == .stdlib }.sorted { $0.importPath < $1.importPath }
    }

    private var dependencyModules: [OcxModule] {
        listing.modules.filter { !$0.main }.sorted { $0.path < $1.path }
    }

    private func packages(in module: OcxModule) -> [OcxPackage] {
        listing.packages
            .filter { $0.origin == .dependency && $0.modulePath == module.path && $0.moduleVersion == module.version }
            .sorted { $0.importPath < $1.importPath }
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
