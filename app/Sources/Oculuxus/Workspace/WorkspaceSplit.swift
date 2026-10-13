import AppKit
import SwiftUI

/// The two panes of a Workspace.
enum WorkspacePane {
    case outline
    case source
}

/// How a Workspace divides its width between the package content pane and
/// the source viewer. Automatically, the pane last clicked gets three
/// quarters of the width. Once the user drags the divider, the split stays
/// where they put it until they double-click the divider; double-clicking
/// a pane still gives it three quarters, but leaves the split manual.
struct WorkspaceSplitLayout: Equatable {
    /// The share of the width the wide pane gets in automatic mode.
    static let wideShare = 0.75
    static let minPaneWidth: CGFloat = 200

    var widePane: WorkspacePane = .outline
    /// The outline's share of the width the user dragged to, or nil while
    /// panes widen when clicked.
    var manualShare: Double?

    var isAutomatic: Bool { manualShare == nil }

    var outlineShare: Double {
        manualShare ?? (widePane == .outline ? Self.wideShare : 1 - Self.wideShare)
    }

    /// Gives `pane` the wide share. A single click does nothing once the
    /// split was dragged; a double-click moves the dragged split there.
    mutating func widen(_ pane: WorkspacePane, doubleClick: Bool = false) {
        if isAutomatic {
            widePane = pane
        } else if doubleClick {
            manualShare = pane == .outline ? Self.wideShare : 1 - Self.wideShare
        }
    }

    /// The outline's width in `width`, keeping both panes usable.
    func outlineWidth(in width: CGFloat) -> CGFloat {
        Self.clamp(width * outlineShare, in: width)
    }

    /// The share for an outline `outlineWidth` wide, as dragged to.
    static func share(outlineWidth: CGFloat, in width: CGFloat) -> Double {
        guard width > 0 else { return wideShare }
        return Double(clamp(outlineWidth, in: width) / width)
    }

    private static func clamp(_ outlineWidth: CGFloat, in width: CGFloat) -> CGFloat {
        let minWidth = min(minPaneWidth, width / 2)
        return min(max(outlineWidth, minWidth), width - minWidth)
    }
}

/// The outline and source panes side by side, with a divider that can be
/// dragged, and double-clicked to go back to automatic sizing.
struct WorkspaceSplit<Outline: View, Source: View>: View {
    var workspace: WorkspaceModel
    var settings: AppSettings
    @ViewBuilder var outline: Outline
    @ViewBuilder var source: Source

    /// The outline width when the drag started.
    @State private var dragStart: CGFloat?
    @State private var hoveringDivider = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let outlineWidth = workspace.split.outlineWidth(in: width)
            HStack(spacing: 0) {
                outline
                    .frame(width: outlineWidth)
                    .background(PaneClickMonitor(ignoring: .trailing) { phase, clicks in workspace.paneClicked(.outline, phase, clicks: clicks) })
                Divider()
                source
                    .frame(maxWidth: .infinity)
                    .background(PaneClickMonitor(ignoring: .leading) { phase, clicks in workspace.paneClicked(.source, phase, clicks: clicks) })
            }
            .overlay(alignment: .leading) {
                dividerHandle(width: width)
                    .offset(x: outlineWidth - 3)
            }
        }
    }

    /// An invisible strip over the divider that takes drags and double-clicks.
    private func dividerHandle(width: CGFloat) -> some View {
        Color.clear
            .frame(width: 7)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != hoveringDivider else { return }
                hoveringDivider = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if hoveringDivider { NSCursor.pop() }
                hoveringDivider = false
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = dragStart ?? workspace.split.outlineWidth(in: width)
                        dragStart = start
                        workspace.split.manualShare = WorkspaceSplitLayout.share(outlineWidth: start + drag.translation.width, in: width)
                    }
                    .onEnded { _ in
                        dragStart = nil
                        settings.workspaceSplit = workspace.split.manualShare
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                withAnimation(.easeInOut(duration: 0.25)) { workspace.split.manualShare = nil }
                settings.workspaceSplit = nil
            })
            .help("Drag to keep the panes at this size. Double-click to size them automatically.")
    }
}

enum MousePhase {
    case down
    case up
}

/// Reports mouse-downs inside the view it backs, and the mouse-up that
/// follows one, with the click count of the press, without taking the
/// events from the views on top. Presses near the `ignoring` edge are left
/// to the divider.
struct PaneClickMonitor: NSViewRepresentable {
    var ignoring: HorizontalEdge
    var onMouse: (MousePhase, Int) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.ignoring = ignoring
        view.onMouse = onMouse
    }

    final class MonitorView: NSView {
        var ignoring: HorizontalEdge = .trailing
        var onMouse: ((MousePhase, Int) -> Void)?
        private var monitor: Any?
        private var pressed = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window else { return }
            switch event.type {
            case .leftMouseDown:
                let point = convert(event.locationInWindow, from: nil)
                var area = bounds
                area.size.width -= 5
                if ignoring == .leading { area.origin.x += 5 }
                pressed = area.contains(point)
                if pressed { onMouse?(.down, event.clickCount) }
            case .leftMouseUp:
                if pressed { onMouse?(.up, event.clickCount) }
                pressed = false
            default:
                break
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
