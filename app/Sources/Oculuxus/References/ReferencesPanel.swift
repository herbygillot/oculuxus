import AppKit
import SwiftUI

/// The collapsible panel at the bottom of a Workspace: references to the
/// subject grouped by package and file and, for a function or method, its
/// callers and callees. A click on a row shows it in the Workspace;
/// ⌘-click opens a new one.
struct ReferencesPanel: View {
    @Bindable var model: ReferencesModel
    var theme: CodeTheme
    var font: NSFont
    var open: (WorkspaceLocation, _ newWindow: Bool) -> Void
    var close: () -> Void

    /// The panel's height when the drag started.
    @State private var dragStart: CGFloat?
    @State private var hoveringEdge = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay { resizeHandle }
            header
            if !model.isCollapsed {
                Divider()
                content
                    .frame(height: model.height)
            }
        }
        // Signatures and lines use the code theme's colors.
        .background(Color(nsColor: theme.background))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { model.isCollapsed.toggle() }
            } label: {
                Image(systemName: model.isCollapsed ? "chevron.up" : "chevron.down")
                    .frame(width: 14)
            }
            .buttonStyle(.borderless)
            .help(model.isCollapsed ? "Show the panel" : "Collapse the panel")

            if model.isCallable {
                Picker("Show", selection: $model.tab) {
                    Text("References").tag(ReferencesTab.references)
                    Text("Callers").tag(ReferencesTab.callers)
                    Text("Callees").tag(ReferencesTab.callees)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            } else {
                Text("References").font(.headline)
            }

            subjectTitle
                .layoutPriority(-1)

            Spacer(minLength: 8)

            statusView
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if model.tab != .callees {
                Toggle("Dependencies", isOn: $model.includeDependencies)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Also look in dependencies and the standard library")
            }

            Button(action: close) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close the panel")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    /// The subject's signature from its hover card, or its name.
    @ViewBuilder private var subjectTitle: some View {
        if let hover = model.hover, !hover.signature.text.isEmpty {
            Text(attributed(hover.signature))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(hover.signature.text)
        } else if let subject = model.subject {
            Text(subject.name)
                .font(Font(font))
                .lineLimit(1)
        }
    }

    @ViewBuilder private var statusView: some View {
        switch model.tab {
        case .references:
            switch model.status {
            case let .loading(message):
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text(message ?? "Finding references…")
                }
            case let .partial(message):
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("\(model.summary) · \(message)")
                }
            case .done:
                Text(model.summary)
            case .failed, .idle:
                EmptyView()
            }
        case .callers, .callees:
            let node = model.tab == .callers ? model.callers : model.callees
            switch node?.children {
            case let .loading(message)?:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text(message ?? "Loading…")
                }
            case let .loaded(nodes)?:
                Text(callCount(nodes.count))
            default:
                EmptyView()
            }
        }
    }

    private func callCount(_ n: Int) -> String {
        switch model.tab {
        case .callers: n == 1 ? "1 caller" : "\(n) callers"
        default: n == 1 ? "1 callee" : "\(n) callees"
        }
    }

    /// Drags the top edge to resize the panel.
    private var resizeHandle: some View {
        Color.clear
            .frame(height: 7)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != hoveringEdge else { return }
                hoveringEdge = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if hoveringEdge { NSCursor.pop() }
                hoveringEdge = false
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = dragStart ?? model.height
                        dragStart = start
                        model.isCollapsed = false
                        model.height = min(max(start - drag.translation.height, 80), 700)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch model.tab {
        case .references:
            referencesList
        case .callers:
            callTree(model.callers)
        case .callees:
            callTree(model.callees)
        }
    }

    private var referencesList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.groups) { group in
                    PackageHeader(group: group, theme: theme)
                    ForEach(group.files) { file in
                        FileHeader(file: file)
                        ForEach(file.references, id: \.self) { ref in
                            let id = ReferencesModel.rowID(ref)
                            ReferenceRow(reference: ref, selected: model.selectedRow == id, theme: theme, font: font)
                                .onTapGesture {
                                    model.selectedRow = id
                                    open(ReferencesModel.location(of: ref), ClickModifiers.opensNewWorkspace)
                                }
                        }
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .overlay {
            if model.groups.isEmpty {
                switch model.status {
                case .done:
                    Text("No references to \(model.subject?.name ?? "this") in \(model.includeDependencies ? "the project or its dependencies" : "the project")")
                        .foregroundStyle(.secondary)
                case let .failed(message):
                    Text(message).foregroundStyle(.secondary).padding()
                case let .loading(message):
                    VStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    }
                case let .partial(message):
                    VStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                default:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder private func callTree(_ root: CallNode?) -> some View {
        if let root {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    CallChildren(node: root, depth: 0, context: callContext)
                }
                .padding(.vertical, 4)
            }
        } else {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var callContext: CallRow.Context {
        CallRow.Context(theme: theme, font: font, selectedRow: model.selectedRow) { node in
            model.selectedRow = node.id.uuidString
            if let location = ReferencesModel.location(of: node.item, direction: node.direction) {
                open(location, ClickModifiers.opensNewWorkspace)
            }
        } openSite: { site in
            model.selectedRow = ReferencesModel.rowID(site)
            open(ReferencesModel.location(of: site), ClickModifiers.opensNewWorkspace)
        }
    }

    private func attributed(_ text: OcxText) -> AttributedString {
        let ns = CodeText.attributed(text, theme: theme, font: font)
        return (try? AttributedString(ns, including: \.appKit)) ?? AttributedString(text.text)
    }
}

private struct PackageHeader: View {
    var group: ReferenceGroup
    var theme: CodeTheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: group.origin == .project ? "shippingbox" : "shippingbox.fill")
                .foregroundStyle(.secondary)
            Text(group.packageID).bold()
            if group.origin != .project {
                Text(group.origin == .stdlib ? "standard library" : "dependency")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(group.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

private struct FileHeader: View {
    var file: ReferenceGroup.FileGroup

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text(file.name)
            Text("\(file.references.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 26)
        .padding(.vertical, 2)
        .help(file.file)
    }
}

/// One reference: its line number and the line, with the identifier
/// highlighted, and "via Interface" for a use through an interface.
private struct ReferenceRow: View {
    var reference: OcxReference
    var selected: Bool
    var theme: CodeTheme
    var font: NSFont

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(reference.location.line)")
                .font(Font(lineNumberFont))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Text(ReferenceRow.line(reference, theme: theme, font: font))
                .lineLimit(1)
                .truncationMode(.tail)
            if reference.viaInterface {
                ViaLabel(text: reference.via.isEmpty ? "via interface" : "via \(reference.via)")
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.22) : .clear)
        .contentShape(Rectangle())
        .help("\(reference.location.file):\(reference.location.line)")
    }

    private var lineNumberFont: NSFont {
        .monospacedDigitSystemFont(ofSize: max(font.pointSize - 2, 9), weight: .regular)
    }

    /// The source line with the identifier in bold on a tinted background.
    static func line(_ ref: OcxReference, theme: CodeTheme, font: NSFont) -> AttributedString {
        var result = AttributedString(ref.lineText)
        result.font = Font(font)
        result.foregroundColor = Color(nsColor: theme.text)
        if let ns = CodeText.nsRange(ref.range, in: ref.lineText), let range = Range(ns, in: result) {
            result[range].font = Font(NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask))
            result[range].backgroundColor = Color.accentColor.opacity(theme.isDark ? 0.35 : 0.2)
        }
        return result
    }
}

private struct ViaLabel: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .fixedSize()
    }
}

/// The children of a call hierarchy node: rows for the loaded callers or
/// callees, each with its own children when expanded.
private struct CallChildren: View {
    var node: CallNode
    var depth: Int
    var context: CallRow.Context

    var body: some View {
        switch node.children {
        case let .loaded(nodes)?:
            if nodes.isEmpty {
                Message(text: node.direction == .callers ? "No callers" : "No callees", depth: depth)
            }
            ForEach(nodes) { child in
                CallRow(node: child, depth: depth, context: context)
                if child.isExpanded {
                    CallChildren(node: child, depth: depth + 1, context: context)
                }
            }
        case let .loading(message)?:
            Message(text: message ?? "Loading…", depth: depth, progress: true)
        case let .failed(message)?:
            Message(text: message, depth: depth)
        case nil:
            EmptyView()
        }
    }

    private struct Message: View {
        var text: String
        var depth: Int
        var progress = false

        var body: some View {
            HStack(spacing: 6) {
                if progress { ProgressView().controlSize(.mini) }
                Text(text)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, CGFloat(depth) * 18 + 30)
            .padding(.vertical, 3)
        }
    }
}

/// A caller or callee: a disclosure triangle, its kind, its signature, its
/// package, how it is called, and the first call site.
private struct CallRow: View {
    struct Context {
        var theme: CodeTheme
        var font: NSFont
        var selectedRow: String?
        var open: (CallNode) -> Void
        var openSite: (OcxReference) -> Void
    }

    var node: CallNode
    var depth: Int
    var context: Context

    var body: some View {
        let item = node.item
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button {
                node.toggle()
            } label: {
                Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .frame(width: 14)
            }
            .buttonStyle(.borderless)
            .opacity(node.canExpand ? 1 : 0)
            .disabled(!node.canExpand)
            .help(node.direction == .callers ? "Show who calls this" : "Show what this calls")

            KindBadge(kind: item.kind == .unspecified ? .func : item.kind)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.signature)
                        .font(Font(context.font))
                        .foregroundStyle(Color(nsColor: context.theme.text))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let label = node.callLabel {
                        ViaLabel(text: label)
                    }
                    Spacer(minLength: 8)
                    Text(item.symbol.packageID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if let site = node.firstSite {
                    siteLine(site, count: item.sites.count)
                }
            }
        }
        .padding(.leading, CGFloat(depth) * 18 + 8)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(context.selectedRow == node.id.uuidString ? Color.accentColor.opacity(0.22) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { context.open(node) }
        .help(item.location.file.isEmpty ? item.signature : "\(item.location.file):\(item.location.line)")
    }

    /// "highlight.go:88  return …objectRef(o)", and a menu of every call
    /// when there are more.
    private func siteLine(_ site: OcxReference, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\((site.location.file as NSString).lastPathComponent):\(site.location.line)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(ReferenceRow.line(site, theme: context.theme, font: smallFont))
                .lineLimit(1)
                .truncationMode(.tail)
            if count > 1 {
                Menu("\(count) calls") {
                    ForEach(node.item.sites, id: \.self) { site in
                        Button("\((site.location.file as NSString).lastPathComponent):\(site.location.line)   \(site.lineText)") {
                            context.openSite(site)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .font(.caption)
                .fixedSize()
            }
        }
    }

    private var smallFont: NSFont {
        NSFontManager.shared.convert(context.font, toSize: max(context.font.pointSize - 2, 9))
    }
}
