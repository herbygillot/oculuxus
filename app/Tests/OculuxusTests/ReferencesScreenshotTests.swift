import AppKit
import SwiftUI
import XCTest
@testable import Oculuxus

/// Shows a Workspace for the helper's own source in an on-screen window,
/// opens the references panel on each tab and a hover card, and captures
/// the screen with screencapture. Opt-in:
///
///     OCULUXUS_SCREENSHOT_DIR=/tmp/shots swift test --filter ReferencesScreenshotTests
@MainActor
final class ReferencesScreenshotTests: XCTestCase {
    private let analysis = "github.com/herbygillot/oculuxus/helper/internal/analysis"

    func testPanelAndHoverCard() async throws {
        guard let dir = ProcessInfo.processInfo.environment["OCULUXUS_SCREENSHOT_DIR"] else {
            throw XCTSkip("set OCULUXUS_SCREENSHOT_DIR to capture screenshots")
        }
        guard HelperEnvironment.helperURL() != nil else { throw XCTSkip("bin/oculuxus-helper is not built") }
        let state = AppState()
        await state.openProject(HelperEnvironment.repositoryRoot.appending(path: "helper").path, openWindow: nil)
        let session = try XCTUnwrap(state.session)
        defer { session.close() }
        XCTAssertEqual(session.status, .ready)

        let workspace = state.workspace(UUID())
        state.workspaceBecameActive(workspace.id)
        workspace.split.manualShare = 0.42
        workspace.go(to: WorkspaceLocation(packageID: analysis, declarationID: "typedPackage.identToken"))

        let view = NSHostingView(rootView: WorkspaceView(workspace: workspace).environment(state))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1500, height: 950), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Oculuxus – references"
        window.contentView = view
        window.level = .floating
        window.isReleasedWhenClosed = false
        workspace.window = window
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await settle(30)

        // References to objectRef, from the outline's context menu path.
        let subject = ReferenceSubject(symbol: OcxSymbolRef(packageID: analysis, declarationID: "objectRef"), name: "objectRef")
        workspace.showReferences(subject, tab: .references, session: session)
        let model = try XCTUnwrap(workspace.references)
        model.height = 330
        try await waitFor { model.status == .done && model.isCallable }
        XCTAssertGreaterThan(model.references.count, 3)
        // Navigate to a reference, as a click on its row does.
        let first = try XCTUnwrap(model.references.first { $0.enclosingID == "typedPackage.identToken" })
        model.selectedRow = ReferencesModel.rowID(first)
        workspace.go(to: ReferencesModel.location(of: first))
        try await settle(20)
        try capture(window, to: "\(dir)/references.png")

        model.tab = .callers
        try await waitFor { if case .loaded? = model.callers?.children { true } else { false } }
        if case let .loaded(nodes)? = model.callers?.children, let node = nodes.first(where: \.canExpand) {
            node.expand()
            try await waitFor { if case .loaded? = node.children { true } else { false } }
        }
        try await settle(10)
        try capture(window, to: "\(dir)/callers.png")

        // Callees of identToken, which calls through interfaces.
        workspace.showReferences(ReferenceSubject(symbol: OcxSymbolRef(packageID: analysis, declarationID: "typedPackage.identToken"), name: "identToken"), tab: .callees, session: session)
        try await waitFor { if case .loaded? = model.callees?.children { true } else { false } }
        try await settle(10)
        try capture(window, to: "\(dir)/callees.png")

        // A hover card on an identifier in the source viewer, through the
        // source viewer's own hover path (Hover by Position for a local,
        // by reference for a declaration).
        let textView = try XCTUnwrap(find(SourceTextView.self, in: view))
        let storage = try XCTUnwrap(textView.textStorage)
        // The first call, near the top, so the card fits in the window.
        let range = (storage.string as NSString).range(of: "objectRef(o)")
        XCTAssertNotEqual(range.location, NSNotFound)
        let token = try XCTUnwrap(storage.attribute(.sourceToken, at: range.location, effectiveRange: nil) as? SourceToken)
        HoverCardPresenter.shared.delay = .milliseconds(10)
        HoverCardPresenter.shared.dismissesWhenPointerLeaves = false
        defer { HoverCardPresenter.shared.dismissesWhenPointerLeaves = true }
        let rect = textView.firstRect(forCharacterRange: NSRange(location: range.location, length: 9), actualRange: nil)
        textView.tokenActions?.hover(token, "objectRef", rect, textView)
        try await settle(25)
        try capture(window, to: "\(dir)/hover.png")
        HoverCardPresenter.shared.dismiss()
    }

    private func settle(_ ticks: Int) async throws {
        for _ in 0..<ticks {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(condition())
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let match = find(type, in: sub) { return match } }
        return nil
    }

    /// Captures the window's area of the screen, popovers over it included.
    private func capture(_ window: NSWindow, to path: String) throws {
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        let frame = window.frame.insetBy(dx: 2, dy: 2)
        let top = screen.frame.maxY - frame.maxY
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-R\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))", path]
        try process.run()
        process.waitUntilExit()
    }
}
