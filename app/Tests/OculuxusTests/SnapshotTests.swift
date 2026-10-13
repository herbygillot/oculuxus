import AppKit
import SwiftUI
import XCTest
@testable import Oculuxus

/// Renders the Navigator and a Workspace for a real project into PNGs, to
/// look at the app without a display. Opt-in:
///
///     OCULUXUS_SNAPSHOT_DIR=/tmp/shots OCULUXUS_SNAPSHOT_PROJECT=~/src/proj \
///     OCULUXUS_SNAPSHOT_PACKAGE=example.com/proj/pkg OCULUXUS_SNAPSHOT_DECL=Type.Method \
///     swift test --filter SnapshotTests
///
/// OCULUXUS_SNAPSHOT_TESTS=1 shows test code; OCULUXUS_SNAPSHOT_SEARCH=query
/// also renders the ⌘K panel for the query.
@MainActor
final class SnapshotTests: XCTestCase {
    func testRenderProject() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["OCULUXUS_SNAPSHOT_DIR"] else { throw XCTSkip("set OCULUXUS_SNAPSHOT_DIR to render snapshots") }
        let project = env["OCULUXUS_SNAPSHOT_PROJECT"] ?? HelperEnvironment.repositoryRoot.appending(path: "helper").path

        let state = AppState()
        state.settings.showsTests = env["OCULUXUS_SNAPSHOT_TESTS"] != nil
        await state.openProject(project, openWindow: nil)
        let session = try XCTUnwrap(state.session)
        XCTAssertEqual(session.status, .ready)

        let workspace = state.workspace(UUID())
        state.workspaceBecameActive(workspace.id)
        let packageID = env["OCULUXUS_SNAPSHOT_PACKAGE"] ?? session.listing.projectPackages.first?.id ?? ""
        workspace.go(to: WorkspaceLocation(packageID: packageID, declarationID: env["OCULUXUS_SNAPSHOT_DECL"]))
        workspace.showsWholeFile = env["OCULUXUS_SNAPSHOT_FILE"] != nil

        let root = HStack(spacing: 0) {
            NavigatorView().frame(width: 320)
            Divider()
            WorkspaceView(workspace: workspace)
        }
        .environment(state)
        let view = NSHostingView(rootView: root)
        view.frame = NSRect(x: 0, y: 0, width: 1500, height: 900)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view

        // Let the outline and source requests finish.
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
        }
        let name = (project as NSString).lastPathComponent + (env["OCULUXUS_SNAPSHOT_NAME"] ?? "")
        try write(view, to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))

        if let query = env["OCULUXUS_SNAPSHOT_SEARCH"] {
            let model = SymbolSearchModel(session: session, includeDependencies: true)
            model.query = query
            for _ in 0..<100 where model.status != .done {
                try await Task.sleep(for: .milliseconds(100))
            }
            model.moveSelection(by: 1)
            let search = NSHostingView(rootView: SymbolSearchView(model: model, theme: state.settings.theme, font: state.settings.font, open: { _, _ in }, close: {}))
            search.frame = NSRect(origin: .zero, size: SymbolSearchPanel.size)
            let panel = NSWindow(contentRect: search.frame, styleMask: [.titled], backing: .buffered, defer: false)
            panel.contentView = search
            try await Task.sleep(for: .milliseconds(300))
            search.layoutSubtreeIfNeeded()
            try write(search, to: URL(fileURLWithPath: dir).appending(path: "\(name)-search.png"))
        }
        session.close()
    }

    private func write(_ view: NSView, to url: URL) throws {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
