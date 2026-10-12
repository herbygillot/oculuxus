import AppKit
import Observation
import SwiftUI

/// Where a Workspace is looking: a package, and optionally one of its
/// declarations.
struct WorkspaceLocation: Hashable, Codable {
    var packageID: String
    var declarationID: String?
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
    weak var window: NSWindow?
    /// Set once the window is closed. SwiftUI may still evaluate a closed
    /// window's content, so a closed model must never be shown in again.
    var isClosed = false

    init(id: UUID) {
        self.id = id
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
        history[index] = location
    }

    func goBack() { if canGoBack { index -= 1 } }
    func goForward() { if canGoForward { index += 1 } }
}

@Observable
@MainActor
final class AppState {
    let projects = SampleData.projects
    var projectID: String
    let settings = AppSettings()

    private(set) var workspaces: [UUID: WorkspaceModel] = [:]
    /// Workspaces whose windows have closed. SwiftUI can still evaluate a
    /// closed window's content, which must not bring its Workspace back.
    @ObservationIgnored private var closedWorkspaceIDs: Set<UUID> = []
    /// The Workspace that was most recently key.
    private(set) var lastActiveWorkspaceID: UUID?
    /// Set while a Workspace is full screen: the Navigator is docked in it.
    var dockedInWorkspaceID: UUID?
    weak var navigatorWindow: NSWindow?

    init() {
        projectID = SampleData.projects[0].id
    }

    var project: SampleProject {
        projects.first { $0.id == projectID } ?? projects[0]
    }

    func workspace(_ id: UUID) -> WorkspaceModel {
        if let model = workspaces[id] { return model }
        let model = WorkspaceModel(id: id)
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
    /// `newWindow` is set or no Workspace is open.
    func show(_ location: WorkspaceLocation, newWindow: Bool, openWindow: OpenWindowAction) {
        if !newWindow, let workspace = activeWorkspace {
            workspace.go(to: location)
            workspace.window?.makeKeyAndOrderFront(nil)
            return
        }
        let workspace = workspace(UUID())
        workspace.go(to: location)
        lastActiveWorkspaceID = workspace.id
        openWindow(id: WindowID.workspace, value: workspace.id)
    }

    func switchProject(to id: String, openWindow: OpenWindowAction) {
        guard id != projectID else { return }
        projectID = id
        if let first = project.listing.packages.first(where: { $0.origin == .project }) {
            show(WorkspaceLocation(packageID: first.id), newWindow: false, openWindow: openWindow)
        }
    }

    /// The location to open when the app starts with no Workspace.
    var initialLocation: WorkspaceLocation {
        WorkspaceLocation(packageID: project.listing.packages.first { $0.origin == .project }?.id ?? "")
    }
}

enum WindowID {
    static let navigator = "navigator"
    static let workspace = "workspace"
}

/// Decides whether a click should open a new Workspace.
enum ClickModifiers {
    static var opensNewWorkspace: Bool {
        NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
    }
}
