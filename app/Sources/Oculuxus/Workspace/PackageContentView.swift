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
                        let decls = Self.ordered(outline.declarations.filter { $0.kind == kind })
                        if !decls.isEmpty {
                            SectionHeader(title: title)
                            ForEach(decls) { decl in
                                DeclarationView(declaration: decl, context: rowContext)
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            .onChange(of: selectedID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id) } }
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

    private var rowContext: DeclarationView.Context {
        .init(selectedID: selectedID, theme: theme, font: font, select: select)
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

    var body: some View {
        let selected = context.selectedID == declaration.id
        Text(signature)
            .tint(Color(nsColor: context.theme.color(for: .typeName)))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
            .padding(.leading, CGFloat(depth) * 16 + 12)
            .padding(.trailing, 12)
            .background(selected ? Color.accentColor.opacity(0.18) : .clear)
            .contentShape(Rectangle())
            .onTapGesture { context.select(declaration.id) }
            .help(declaration.doc)
            .id(declaration.id)
    }

    private var signature: AttributedString {
        let ns = CodeText.attributed(declaration.signature, theme: context.theme, font: context.font)
        return (try? AttributedString(ns, including: \.appKit)) ?? AttributedString(declaration.signature.text)
    }
}
