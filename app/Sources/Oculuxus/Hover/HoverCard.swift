import AppKit
import SwiftUI

/// Shows one hover card at a time, in a popover under the identifier the
/// pointer rests on. The card appears after `delay` on the same
/// identifier, and goes away once the pointer has left both the identifier
/// and the card for a moment, so the pointer can move into the card to
/// follow its links.
@MainActor
final class HoverCardPresenter: NSObject, NSPopoverDelegate {
    static let shared = HoverCardPresenter()

    var delay: Duration = .milliseconds(500)
    /// Off only for screenshots, where no real pointer rests on the card.
    var dismissesWhenPointerLeaves = true
    /// How long the pointer may be outside the identifier and the card.
    private let grace: TimeInterval = 0.25

    private var pendingKey: AnyHashable?
    private var pendingTask: Task<Void, Never>?
    private var popover: NSPopover?
    private var shownKey: AnyHashable?
    /// The identifier's rectangle on screen.
    private var anchor: NSRect = .zero
    private var timer: Timer?
    private var lastInside = Date()

    /// The pointer came to rest on an identifier, `anchor` on screen in
    /// `window`. `load` describes it; `content` makes the card, and is
    /// given a closure that dismisses it.
    func hover<Content: View>(
        key: AnyHashable,
        anchor: NSRect,
        window: NSWindow,
        load: @escaping @MainActor () async -> OcxHover?,
        content: @escaping (OcxHover, _ dismiss: @escaping () -> Void) -> Content
    ) {
        guard key != pendingKey else { return }
        if key == shownKey {
            lastInside = Date()
            return
        }
        pendingTask?.cancel()
        pendingKey = key
        pendingTask = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            // The pointer went on into the open card: leave it.
            if self.popover != nil, self.isInsideCard(NSEvent.mouseLocation) { return }
            guard let hover = await load(), !Task.isCancelled, self.pendingKey == key, window.isVisible else { return }
            self.present(key: key, anchor: anchor, window: window, content: AnyView(content(hover) { [weak self] in self?.dismiss() }))
        }
    }

    /// The pointer left the identifier for `key`. An open card stays while
    /// the pointer moves into it.
    func leave(_ key: AnyHashable? = nil) {
        guard key == nil || key == pendingKey else { return }
        pendingTask?.cancel()
        pendingTask = nil
        pendingKey = nil
    }

    func dismiss() {
        leave()
        timer?.invalidate()
        timer = nil
        shownKey = nil
        let popover = self.popover
        self.popover = nil
        popover?.close()
    }

    private func present(key: AnyHashable, anchor: NSRect, window: NSWindow, content: AnyView) {
        dismiss()
        guard let contentView = window.contentView else { return }
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
        let rect = contentView.convert(window.convertFromScreen(anchor), from: nil)
        popover.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
        self.popover = popover
        self.shownKey = key
        self.anchor = anchor
        lastInside = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.track() }
        }
    }

    /// Dismisses the card once the pointer has been away from the
    /// identifier and the card for the grace period.
    private func track() {
        guard dismissesWhenPointerLeaves else { return }
        let mouse = NSEvent.mouseLocation
        if anchor.insetBy(dx: -3, dy: -6).contains(mouse) || isInsideCard(mouse) {
            lastInside = Date()
        } else if Date().timeIntervalSince(lastInside) > grace {
            dismiss()
        }
    }

    private func isInsideCard(_ point: NSPoint) -> Bool {
        guard let frame = popover?.contentViewController?.view.window?.frame else { return false }
        return frame.insetBy(dx: -6, dy: -6).contains(point)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let closed = notification.object as? NSPopover, closed === popover else { return }
            timer?.invalidate()
            timer = nil
            popover = nil
            shownKey = nil
        }
    }
}

/// A hover card: what the identifier is, its full signature, its
/// package, its doc comment and where it is defined. Links navigate like
/// links in the Workspace.
struct HoverCardView: View {
    var hover: OcxHover
    var theme: CodeTheme
    var font: NSFont
    var open: (WorkspaceLocation, _ newWindow: Bool) -> Void
    var dismiss: () -> Void

    static let width: CGFloat = 520

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(hover.kind)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                if !hover.packageID.isEmpty {
                    Text(hover.packageID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Text(signature)
                .tint(Color(nsColor: theme.color(for: .typeName)))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !hover.doc.isEmpty {
                Divider()
                if hover.doc.count > 900 {
                    ScrollView {
                        docText.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 240)
                } else {
                    docText
                }
            }
            if let definition {
                Divider()
                Button {
                    dismiss()
                    open(definition, ClickModifiers.opensNewWorkspace)
                } label: {
                    Label(definitionTitle, systemImage: "arrow.right.circle")
                }
                .buttonStyle(.link)
                .help(hover.location.file)
            } else if !hover.location.file.isEmpty {
                Divider()
                Text(definitionTitle).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: Self.width, alignment: .leading)
        .background(Color(nsColor: theme.background))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .environment(\.openURL, OpenURLAction { url in
            guard let location = CodeText.location(from: url) else { return .systemAction }
            dismiss()
            open(location, ClickModifiers.opensNewWorkspace)
            return .handled
        })
    }

    private var docText: some View {
        Text(hover.doc)
            .font(.body)
            .foregroundStyle(Color(nsColor: theme.text))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var signature: AttributedString {
        let ns = CodeText.attributed(hover.signature, theme: theme, font: font)
        return (try? AttributedString(ns, including: \.appKit)) ?? AttributedString(hover.signature.text)
    }

    /// Where "Defined in" leads: the declaration, or for a local the line
    /// that declares it.
    private var definition: WorkspaceLocation? {
        if hover.hasTarget {
            let id = hover.target.declarationID
            return WorkspaceLocation(packageID: hover.target.packageID, declarationID: id.isEmpty ? nil : id)
        }
        if !hover.location.file.isEmpty, !hover.packageID.isEmpty {
            return WorkspaceLocation(packageID: hover.packageID, file: hover.location.file, line: Int(hover.location.line))
        }
        return nil
    }

    private var definitionTitle: String {
        let name = (hover.location.file as NSString).lastPathComponent
        if name.isEmpty { return hover.kind == "package" ? "Open package \(hover.packageName)" : "Defined in \(hover.packageName)" }
        return "Defined in \(name):\(hover.location.line)"
    }
}
