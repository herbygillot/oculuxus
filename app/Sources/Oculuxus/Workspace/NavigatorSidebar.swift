import AppKit
import Observation
import SwiftUI

/// Whether a Workspace's Navigator sidebar is collapsed, and how wide it
/// is; copied into new Workspaces and saved as the default for the next
/// launch.
struct SidebarState: Equatable, Codable {
    var isCollapsed = false
    /// The width the user dragged the sidebar to, or nil for a quarter of
    /// the window.
    var width: Double?

    static let share = 0.25
    static let minWidth: CGFloat = 200
    static let maxWidth: CGFloat = 480

    /// The sidebar's width in a window `windowWidth` wide.
    func resolvedWidth(in windowWidth: CGFloat) -> CGFloat {
        Self.clamp(width.map { CGFloat($0) } ?? (windowWidth * Self.share).rounded(), in: windowWidth)
    }

    /// Keeps the sidebar between its limits and at most half the window.
    static func clamp(_ width: CGFloat, in windowWidth: CGFloat) -> CGFloat {
        let upper = max(minWidth, min(maxWidth, windowWidth / 2))
        return min(max(width, minWidth), upper)
    }
}

/// The Navigator sidebar of one Workspace. The toggle button pins it
/// (it takes its column and the content shrinks) or collapses it (the
/// content takes the whole width). While collapsed, resting the pointer on
/// the button peeks the Navigator over the content; it stays while the
/// pointer is on the button or the Navigator, and goes when the pointer
/// leaves both, a package is picked, or Escape is pressed. Clicking the
/// button while peeking pins the sidebar.
@Observable
@MainActor
final class NavigatorSidebar {
    enum Peek: Equatable {
        case hidden
        /// The pointer rests on the button; the Navigator peeks after
        /// `showDelay`.
        case pending
        case shown
    }

    private(set) var state: SidebarState
    private(set) var peek: Peek = .hidden
    /// Called when the user changes the state, to save it as the default.
    @ObservationIgnored var onChange: ((SidebarState) -> Void)?

    @ObservationIgnored var showDelay: Duration = .milliseconds(300)
    @ObservationIgnored var hideDelay: Duration = .milliseconds(400)
    @ObservationIgnored private var overButton = false
    @ObservationIgnored private var overPeek = false
    /// After a click collapses the sidebar, the pointer is still on the
    /// button: it peeks only once the pointer has left and come back.
    @ObservationIgnored private var waitsForExit = false
    /// The collapsed state to go back to when full screen ends, while the
    /// sidebar is pinned only because of full screen.
    @ObservationIgnored private var collapsedBeforeFullScreen: Bool?
    @ObservationIgnored private var timer: Task<Void, Never>?

    init(_ state: SidebarState = SidebarState()) {
        self.state = state
    }

    var isCollapsed: Bool { state.isCollapsed }

    /// The state to save and copy: collapsed if only full screen pins it.
    var savedState: SidebarState {
        var saved = state
        if let collapsedBeforeFullScreen { saved.isCollapsed = collapsedBeforeFullScreen }
        return saved
    }
    var isPeeking: Bool { peek == .shown }

    /// The toggle button, its menu item or ⌃⌘S: pins or collapses, and
    /// pins a peeking Navigator in place.
    func toggle() {
        collapsedBeforeFullScreen = nil
        let collapse = !state.isCollapsed
        let wasPeeking = isPeeking
        cancelTimer()
        peek = .hidden
        waitsForExit = collapse && overButton
        if wasPeeking {
            // The peeking Navigator stays where it is, now in its column.
            state.isCollapsed = collapse
        } else {
            withAnimation(.easeInOut(duration: 0.25)) { state.isCollapsed = collapse }
        }
        onChange?(savedState)
    }

    /// The width the user dragged the sidebar to.
    func setWidth(_ width: Double) {
        guard width != state.width else { return }
        state.width = width
        onChange?(savedState)
    }

    func hoverButton(_ inside: Bool) {
        overButton = inside
        if !inside { waitsForExit = false }
        hoverChanged()
    }

    func hoverPeek(_ inside: Bool) {
        overPeek = inside
        hoverChanged()
    }

    /// A package was picked in the peeking Navigator, or Escape pressed.
    func dismissPeek() {
        cancelTimer()
        guard peek != .hidden else { return }
        withAnimation(.easeOut(duration: 0.2)) { peek = .hidden }
    }

    /// Full screen pins the sidebar; the toggle still works there. Leaving
    /// full screen collapses it again unless the user toggled it meanwhile.
    func fullScreenChanged(_ fullScreen: Bool) {
        if fullScreen {
            guard state.isCollapsed else { return }
            collapsedBeforeFullScreen = true
            dismissPeek()
            state.isCollapsed = false
        } else if let collapsed = collapsedBeforeFullScreen {
            collapsedBeforeFullScreen = nil
            state.isCollapsed = collapsed
        }
    }

    private func hoverChanged() {
        guard state.isCollapsed else { return }
        let hovering = (overButton && !waitsForExit) || (overPeek && peek == .shown)
        switch (peek, hovering) {
        case (.hidden, true):
            peek = .pending
            schedule(after: showDelay) { [weak self] in
                guard let self, peek == .pending else { return }
                withAnimation(.easeOut(duration: 0.2)) { self.peek = .shown }
            }
        case (.pending, false):
            cancelTimer()
            peek = .hidden
        case (.shown, true):
            cancelTimer()
        case (.shown, false):
            schedule(after: hideDelay) { [weak self] in self?.dismissPeek() }
        default:
            break
        }
    }

    private func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) {
        cancelTimer()
        timer = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }
}

/// The leading toolbar button that pins and collapses the Navigator, and
/// peeks it while the pointer rests on it.
struct SidebarToggle: View {
    var sidebar: NavigatorSidebar

    var body: some View {
        Button { sidebar.toggle() } label: {
            Label("Navigator", systemImage: "sidebar.leading")
        }
        .help(sidebar.isCollapsed ? "Show the Navigator (⌃⌘S); rest the pointer here to peek" : "Hide the Navigator (⌃⌘S)")
        .onHover { sidebar.hoverButton($0) }
    }
}

/// A Workspace's content with the Navigator as its leading sidebar: in its
/// own column while pinned, or sliding over the content while peeking.
struct NavigatorSidebarLayout<Content: View>: View {
    var sidebar: NavigatorSidebar
    var window: NSWindow?
    @ViewBuilder var content: Content

    /// The sidebar width when the drag started.
    @State private var dragStart: CGFloat?
    @State private var hoveringDivider = false

    var body: some View {
        GeometryReader { geometry in
            let width = sidebar.state.resolvedWidth(in: geometry.size.width)
            HStack(spacing: 0) {
                if !sidebar.isCollapsed {
                    NavigatorView()
                        .frame(width: width)
                        .transition(.move(edge: .leading))
                    divider(width: width, windowWidth: geometry.size.width)
                }
                content
                    .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .leading) {
                if sidebar.isCollapsed, sidebar.isPeeking {
                    NavigatorView()
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .background(.regularMaterial)
                        .overlay(alignment: .trailing) { Divider() }
                        .shadow(color: .black.opacity(0.25), radius: 12, x: 4)
                        .onHover { sidebar.hoverPeek($0) }
                        .background(EscapeMonitor(window: window, action: sidebar.dismissPeek))
                        .transition(.move(edge: .leading))
                }
            }
            .clipped()
            .environment(\.navigatorPicked, sidebar.dismissPeek)
        }
    }

    private func divider(width: CGFloat, windowWidth: CGFloat) -> some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        guard inside != hoveringDivider else { return }
                        hoveringDivider = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = dragStart ?? width
                                dragStart = start
                                sidebar.setWidth(Double(SidebarState.clamp(start + drag.translation.width, in: windowWidth)))
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
    }
}

/// Calls `action` when Escape is pressed in `window` while this view is
/// shown.
private struct EscapeMonitor: NSViewRepresentable {
    var window: NSWindow?
    var action: () -> Void

    func makeNSView(context: Context) -> NSView { MonitorView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? MonitorView else { return }
        view.window_ = window
        view.action = action
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? MonitorView)?.stop()
    }

    private final class MonitorView: NSView {
        weak var window_: NSWindow?
        var action: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.keyCode == 53, event.window === (window_ ?? window) else { return event }
                action?()
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// Called when a package is picked in the Navigator, to end a peek.
private struct NavigatorPickedKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

/// The Workspace whose sidebar shows the Navigator: picking a package
/// shows it there.
private struct NavigatorWorkspaceKey: EnvironmentKey {
    static let defaultValue: WorkspaceModel? = nil
}

extension EnvironmentValues {
    var navigatorPicked: (@MainActor () -> Void)? {
        get { self[NavigatorPickedKey.self] }
        set { self[NavigatorPickedKey.self] = newValue }
    }

    var navigatorWorkspace: WorkspaceModel? {
        get { self[NavigatorWorkspaceKey.self] }
        set { self[NavigatorWorkspaceKey.self] = newValue }
    }
}
