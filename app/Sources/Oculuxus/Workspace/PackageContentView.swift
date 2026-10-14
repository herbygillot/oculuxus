import AppKit
import SwiftUI

/// The package's doc comment and its declarations, signatures only,
/// grouped by kind like godoc.
struct PackageContentView: View {
    var outline: OcxPackageOutline
    var package: OcxPackage?
    var selectedID: String?
    var theme: CodeTheme
    var font: NSFont
    var select: (String) -> Void
    var openReference: (WorkspaceLocation, Bool) -> Void
    var openInEditor: (EditorTarget) -> Void
    /// A clickable target other than a declaration row was clicked.
    var targetClicked: () -> Void = {}
    /// The pointer rests on a reference in a signature, at a rect on screen.
    var hoverCard: (OcxSymbolRef, NSRect) -> Void = { _, _ in }
    var findReferences: (OcxDeclaration, ReferencesTab) -> Void = { _, _ in }

    /// Section order: vars, consts, interfaces, structs, funcs, other types.
    private static let sections: [(String, OcxSymbolKind)] = [
        ("Variables", .var), ("Constants", .const), ("Interfaces", .interface),
        ("Structs", .struct), ("Functions", .func), ("Types", .type),
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    ForEach(Self.sections, id: \.0) { title, kind in
                        let decls = Self.ordered(outline.declarations.filter { $0.kind == kind && !$0.test })
                        if !decls.isEmpty {
                            SectionHeader(title: title)
                            ForEach(decls) { decl in
                                DeclarationView(declaration: decl, context: rowContext)
                            }
                        }
                    }
                    // Everything declared in _test.go files, when shown.
                    let tests = Self.ordered(outline.declarations.filter(\.test))
                    if !tests.isEmpty {
                        SectionHeader(title: "Tests")
                        ForEach(tests) { decl in
                            DeclarationView(declaration: decl, context: rowContext)
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            .task(id: ScrollTarget(packageID: outline.packageID, declarationID: selectedID)) {
                // Also on first appearance, for a declaration opened from
                // ⌘K or a reference; not on reloads, which keep the scroll.
                guard let id = selectedID else { return }
                // A member's row only exists once its type's row is laid
                // out in the lazy stack: scroll to the type first.
                let root = String(id.split(separator: ".").first ?? "")
                if root != id, outline.declarations.contains(where: { $0.id == root }) {
                    proxy.scrollTo(root, anchor: .top)
                    try? await Task.sleep(for: .milliseconds(50))
                } else {
                    await Task.yield()
                }
                // Row heights are estimates until laid out; settle twice.
                proxy.scrollTo(id, anchor: .center)
                try? await Task.sleep(for: .milliseconds(50))
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .background(Color(nsColor: theme.background))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .environment(\.openURL, OpenURLAction { url in
            guard let location = CodeText.location(from: url) else { return .systemAction }
            openReference(location, ClickModifiers.opensNewWorkspace)
            return .handled
        })
    }

    private struct ScrollTarget: Hashable {
        var packageID: String
        var declarationID: String?
    }

    private var rowContext: DeclarationView.Context {
        .init(selectedID: selectedID, theme: theme, font: font, select: select, openInEditor: openInEditor, targetClicked: targetClicked, hoverCard: hoverCard, findReferences: findReferences)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("package ").foregroundStyle(Color(nsColor: theme.color(for: .keyword)))
                    + Text(outline.name).bold()
                Spacer()
                if let package {
                    Text(package.importPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
            }
            .font(Font(font).weight(.regular))
            if !outline.doc.isEmpty {
                Text(outline.doc)
                    .font(.body)
                    .foregroundStyle(Color(nsColor: theme.text))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !outline.externalTestPackageID.isEmpty {
                Button {
                    openReference(WorkspaceLocation(packageID: outline.externalTestPackageID), ClickModifiers.opensNewWorkspace)
                } label: {
                    Label("External tests: package \(outline.externalTestPackageID.split(separator: "/").last ?? "")", systemImage: "testtube.2")
                }
                .buttonStyle(.link)
                .help("Open \(outline.externalTestPackageID), the package's tests in package \(outline.name)_test")
            }
            ForEach(outline.errors, id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        .padding(12)
    }

    /// Exported declarations first, each group in source order.
    static func ordered(_ decls: [OcxDeclaration]) -> [OcxDeclaration] {
        decls.filter(\.exported) + decls.filter { !$0.exported }
    }
}

private struct SectionHeader: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }
}

/// One declaration, with its members: struct fields and interface members
/// in a collapsed group, methods nested below their type.
struct DeclarationView: View {
    struct Context {
        var selectedID: String?
        var theme: CodeTheme
        var font: NSFont
        var select: (String) -> Void
        var openInEditor: (EditorTarget) -> Void
        var targetClicked: () -> Void
        var hoverCard: (OcxSymbolRef, NSRect) -> Void
        var findReferences: (OcxDeclaration, ReferencesTab) -> Void
    }

    var declaration: OcxDeclaration
    var context: Context
    var depth = 0
    @State private var membersExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SignatureRow(declaration: declaration, context: context, depth: depth)
            if !collapsible.isEmpty {
                DisclosureGroup(isExpanded: $membersExpanded) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(collapsible) { member in
                            SignatureRow(declaration: member, context: context, depth: depth + 2)
                        }
                    }
                } label: {
                    Text(collapsibleLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation { membersExpanded.toggle() } }
                }
                .padding(.leading, CGFloat(depth + 1) * 16 + 12)
                .padding(.trailing, 12)
                // The label or the disclosure triangle was clicked.
                .onChange(of: membersExpanded) { context.targetClicked() }
                .onChange(of: context.selectedID, initial: true) { _, id in
                    // Show a field or interface member that was navigated to.
                    if let id, collapsible.contains(where: { $0.id == id }) { membersExpanded = true }
                }
            }
            ForEach(methods) { method in
                DeclarationView(declaration: method, context: context, depth: depth + 1)
            }
        }
    }

    /// Fields of a struct, or every member of an interface.
    private var collapsible: [OcxDeclaration] {
        declaration.kind == .interface
            ? declaration.members
            : PackageContentView.ordered(declaration.members.filter { $0.kind == .field })
    }

    private var methods: [OcxDeclaration] {
        declaration.kind == .interface
            ? []
            : PackageContentView.ordered(declaration.members.filter { $0.kind == .method })
    }

    private var collapsibleLabel: String {
        let n = collapsible.count
        if declaration.kind == .interface { return n == 1 ? "1 member" : "\(n) members" }
        return n == 1 ? "1 field" : "\(n) fields"
    }
}

private struct SignatureRow: View {
    var declaration: OcxDeclaration
    var context: DeclarationView.Context
    var depth: Int
    /// The index of the token under the pointer.
    @State private var hovered: Int?

    var body: some View {
        let selected = context.selectedID == declaration.id
        Text(signature)
            .tint(Color(nsColor: context.theme.color(for: .typeName)))
            .lineLimit(1)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case let .active(point): pointer(at: point)
                case .ended: endHover()
                }
            }
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
            .padding(.leading, CGFloat(depth) * 16 + 12)
            .padding(.trailing, 12)
            .background(selected ? Color.accentColor.opacity(0.18) : .clear)
            .contentShape(Rectangle())
            .onTapGesture { context.select(declaration.id) }
            .contextMenu {
                Button("Find References") { context.findReferences(declaration, .references) }
                if declaration.kind == .func || declaration.kind == .method {
                    Button("Find Callers") { context.findReferences(declaration, .callers) }
                    Button("Find Callees") { context.findReferences(declaration, .callees) }
                }
                Divider()
                Button("Open in Editor") {
                    context.openInEditor(EditorTarget(file: declaration.location.file, line: max(Int(declaration.location.line), 1)))
                }
                .disabled(declaration.location.file.isEmpty)
            }
            .id(declaration.id)
    }

    /// Shows the hover card for the reference under the pointer. The card
    /// is anchored to the token: its offset in the line is measured with
    /// Core Text, which lays out the same attributed string as the row.
    private func pointer(at point: CGPoint) {
        let text = CodeText.attributed(declaration.signature, theme: context.theme, font: context.font)
        let line = CTLineCreateWithAttributedString(text)
        for (i, token) in declaration.signature.tokens.enumerated() where token.hasTarget {
            guard let range = CodeText.nsRange(token.range, in: declaration.signature.text) else { continue }
            let x0 = CTLineGetOffsetForStringIndex(line, range.location, nil)
            let x1 = CTLineGetOffsetForStringIndex(line, NSMaxRange(range), nil)
            guard point.x >= x0, point.x < x1 else { continue }
            if hovered == i { return }
            hovered = i
            let mouse = NSEvent.mouseLocation
            let height = NSLayoutManager().defaultLineHeight(for: context.font)
            let rect = NSRect(x: mouse.x - (point.x - x0), y: mouse.y + point.y - height, width: x1 - x0, height: height)
            context.hoverCard(token.target, rect)
            return
        }
        endHover()
    }

    private func endHover() {
        guard hovered != nil else { return }
        hovered = nil
        HoverCardPresenter.shared.leave()
    }

    private var signature: AttributedString {
        let ns = CodeText.attributed(declaration.signature, theme: context.theme, font: context.font)
        return (try? AttributedString(ns, including: \.appKit)) ?? AttributedString(declaration.signature.text)
    }
}
