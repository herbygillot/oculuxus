import AppKit
import SwiftUI

/// The ⌘K panel: a search field over the symbol index and the matches.
/// Return opens the selected match in the active Workspace; ⌘-Return or
/// ⌘-click opens it in a new one; Escape closes the panel.
struct SymbolSearchView: View {
    @Bindable var model: SymbolSearchModel
    var theme: CodeTheme
    var font: NSFont
    var open: (OcxSymbolMatch, _ newWindow: Bool) -> Void
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.title3)
                SearchField(
                    text: $model.query,
                    placeholder: "Jump to symbol in \(model.session.name)",
                    onMove: { model.moveSelection(by: $0) },
                    onSubmit: { newWindow in
                        if let match = model.selected { open(match, newWindow) }
                    },
                    onCancel: close
                )
                Picker("Scope", selection: $model.includeDependencies) {
                    Text("Project").tag(false)
                    Text("All").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Search only the project, or its dependencies and the standard library too")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()
            results
            Divider()
            footer
        }
        .frame(width: SymbolSearchPanel.size.width, height: SymbolSearchPanel.size.height)
        .background(.regularMaterial)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.matches.enumerated()), id: \.offset) { index, match in
                        SymbolMatchRow(match: match, selected: index == model.selection, theme: theme, font: font)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selection = index
                                open(match, ClickModifiers.opensNewWorkspace)
                            }
                    }
                }
            }
            .frame(height: 360)
            .onChange(of: model.selection) { _, index in
                proxy.scrollTo(index)
            }
            .overlay {
                if model.matches.isEmpty {
                    switch model.status {
                    case .idle:
                        VStack(spacing: 6) {
                            Text("Type part of a name: Server, srvmux, http.Server, Server.Serve, net/http")
                            Text("Exported symbols and the project's own come first.")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    case .done, .partial:
                        Text("No symbols match “\(model.query)”").foregroundStyle(.secondary)
                    case let .failed(message):
                        Text(message).foregroundStyle(.secondary).padding()
                    default:
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            switch model.status {
            case let .indexing(message):
                ProgressView().controlSize(.mini)
                Text(message)
            case let .partial(indexed, total):
                ProgressView().controlSize(.mini)
                Text("Indexing dependencies, \(indexed) of \(total) packages")
            case .idle:
                Text(" ")
            default:
                Text(model.matches.count == 1 ? "1 match" : "\(model.matches.count) matches")
            }
            Spacer()
            Text("↩ Open   ⌘↩ Open in New Workspace")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

/// One match: a kind badge, the declaration with the matched characters
/// in bold, its package, and its signature.
private struct SymbolMatchRow: View {
    var match: OcxSymbolMatch
    var selected: Bool
    var theme: CodeTheme
    var font: NSFont

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            KindBadge(kind: match.kind)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Text(match.packageID)
                        .font(.caption)
                        .foregroundStyle(selected ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if match.kind != .package {
                    Text(match.signature)
                        .font(Font(NSFont.monospacedSystemFont(ofSize: max(font.pointSize - 2, 9), weight: .regular)))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.25) : .clear)
        .help(match.location.file.isEmpty ? match.packageID : "\(match.location.file):\(match.location.line)")
    }

    /// The declaration id (or a package's import path) with the parts that
    /// matched the query in bold.
    private var title: AttributedString {
        let text = match.kind == .package ? match.packageID : match.declarationID
        var result = AttributedString(text)
        for range in match.matched {
            guard let ns = CodeText.nsRange(range, in: text), let r = Range(ns, in: result) else { continue }
            result[r].inlinePresentationIntent = .stronglyEmphasized
        }
        return result
    }
}

struct KindBadge: View {
    var kind: OcxSymbolKind

    var body: some View {
        Group {
            if kind == .package {
                Image(systemName: "shippingbox.fill").font(.system(size: 10))
            } else {
                Text(letter).font(.system(size: 11, weight: .bold, design: .rounded))
            }
        }
        .foregroundStyle(.white)
        .frame(width: 18, height: 18)
        .background(color, in: RoundedRectangle(cornerRadius: 4))
        .padding(.top, 1)
        .help(String(describing: kind))
    }

    private var letter: String {
        switch kind {
        case .struct: "S"
        case .interface: "I"
        case .type: "T"
        case .func: "F"
        case .method: "M"
        case .const: "C"
        case .var: "V"
        case .field: "f"
        default: "?"
        }
    }

    private var color: Color {
        switch kind {
        case .struct, .interface, .type: .purple
        case .func, .method: .teal
        case .const, .var: .orange
        case .package: .green
        default: .gray
        }
    }
}

/// A plain text field that reports arrow keys, Return and Escape, which
/// SwiftUI's TextField keeps to itself.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onMove: (Int) -> Void
    var onSubmit: (_ newWindow: Bool) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField

        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
            case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
                parent.onMove(-10)
            case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
                parent.onMove(10)
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(ClickModifiers.opensNewWorkspace)
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            default:
                return false
            }
            return true
        }
    }
}

/// A floating panel for the symbol search, like Xcode's Open Quickly. It
/// closes when it loses focus.
final class SymbolSearchPanel: NSPanel {
    static let size = NSSize(width: 680, height: 470)

    /// Called for ⌘-Return, which the text field never sees as a command.
    var onCommandReturn: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isFloatingPanel = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        level = .floating
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.contains(.command) { // Return, Enter
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func resignKey() {
        super.resignKey()
        close()
    }

    /// Places the panel in the upper part of `window`, or of the main screen.
    func position(over window: NSWindow?) {
        let area = window?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        let size = frame.size
        let origin = NSPoint(x: area.midX - size.width / 2, y: area.maxY - area.height * 0.2 - size.height)
        setFrameTopLeftPoint(NSPoint(x: origin.x, y: origin.y + size.height))
    }
}
