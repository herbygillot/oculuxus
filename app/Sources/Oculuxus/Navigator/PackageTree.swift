import Foundation

/// How the Navigator lists packages.
enum NavigatorLayout: String, CaseIterable, Identifiable {
    /// Packages nested by import-path segments under their module.
    case tree
    /// One row per package, labeled with its full import path.
    case flat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tree: "Tree"
        case .flat: "List"
        }
    }

    var systemImage: String {
        switch self {
        case .tree: "list.bullet.indent"
        case .flat: "list.bullet"
        }
    }
}

/// A row in the Navigator: a package, a folder of packages, or both (a
/// package with packages below it).
struct PackageNode: Identifiable, Equatable {
    /// Unique across the Navigator; not the package ID, which is the
    /// selection tag.
    var id: String
    var name: String
    var package: OcxPackage?
    var children: [PackageNode] = []
}

/// The Navigator's three groups laid out as a tree or a flat list.
struct NavigatorOutline {
    struct Module: Identifiable {
        var group: PackageListing.ModuleGroup
        var nodes: [PackageNode]
        var id: String { group.id }
    }

    var project: [PackageNode]
    var dependencies: [Module]
    var stdlib: [PackageNode]

    init(_ listing: PackageListing, layout: NavigatorLayout) {
        switch layout {
        case .flat:
            project = Self.flat(listing.projectPackages, scope: "project")
            dependencies = listing.dependencies.map { Module(group: $0, nodes: Self.flat($0.packages, scope: "dep:" + $0.id)) }
            stdlib = Self.flat(listing.stdlibPackages, scope: "std")
        case .tree:
            // With several project modules (go.work), each gets a folder so
            // their relative paths cannot collide.
            let byModule = Dictionary(grouping: listing.projectPackages, by: \.modulePath)
            if byModule.count > 1 {
                project = byModule.keys.sorted().map { module in
                    let scope = "project:" + module
                    return PackageNode(id: scope, name: module, children: Self.tree(byModule[module]!, scope: scope))
                }
            } else {
                project = Self.tree(listing.projectPackages, scope: "project")
            }
            dependencies = listing.dependencies.map { Module(group: $0, nodes: Self.tree($0.packages, scope: "dep:" + $0.id)) }
            stdlib = Self.tree(listing.stdlibPackages, scope: "std")
        }
    }

    /// The IDs of the nodes that contain `packageID`, outermost first, or
    /// nil when no node shows it.
    func ancestors(of packageID: String) -> [String]? {
        for nodes in [project, stdlib] + dependencies.map(\.nodes) {
            if let path = Self.ancestors(of: packageID, in: nodes) { return path }
        }
        return nil
    }

    private static func ancestors(of packageID: String, in nodes: [PackageNode]) -> [String]? {
        for node in nodes {
            if node.package?.id == packageID { return [] }
            if let path = ancestors(of: packageID, in: node.children) { return [node.id] + path }
        }
        return nil
    }

    private static func flat(_ packages: [OcxPackage], scope: String) -> [PackageNode] {
        packages.map { PackageNode(id: scope + ":" + $0.id, name: $0.importPath, package: $0) }
    }

    /// Nests packages by the segments of their import path below their
    /// module. A module's root package comes first, named after the
    /// module's last element. Folders that hold a single folder and no
    /// package are merged into one row ("internal/server").
    private static func tree(_ packages: [OcxPackage], scope: String) -> [PackageNode] {
        let root = Trie()
        var rootPackages: [PackageNode] = []
        for pkg in packages {
            let rest = relativePath(pkg)
            if rest.isEmpty {
                let name = pkg.modulePath.split(separator: "/").last.map(String.init) ?? pkg.importPath
                rootPackages.append(PackageNode(id: scope + ":", name: name, package: pkg))
                continue
            }
            var trie = root
            for segment in rest.split(separator: "/") {
                trie = trie.child(String(segment))
            }
            trie.package = pkg
        }
        return rootPackages + root.nodes(scope: scope, prefix: "")
    }

    /// The import path below the package's module; the whole import path
    /// for the standard library.
    private static func relativePath(_ pkg: OcxPackage) -> String {
        guard !pkg.modulePath.isEmpty, pkg.importPath.hasPrefix(pkg.modulePath) else { return pkg.importPath }
        return String(pkg.importPath.dropFirst(pkg.modulePath.count).drop { $0 == "/" })
    }

    private final class Trie {
        var package: OcxPackage?
        var children: [String: Trie] = [:]

        func child(_ segment: String) -> Trie {
            if let child = children[segment] { return child }
            let child = Trie()
            children[segment] = child
            return child
        }

        func nodes(scope: String, prefix: String) -> [PackageNode] {
            children.keys.sorted().map { segment in
                let path = prefix.isEmpty ? segment : prefix + "/" + segment
                let trie = children[segment]!
                var node = PackageNode(id: scope + ":" + path, name: segment, package: trie.package, children: trie.nodes(scope: scope, prefix: path))
                while node.package == nil, node.children.count == 1 {
                    let only = node.children[0]
                    node = PackageNode(id: only.id, name: node.name + "/" + only.name, package: only.package, children: only.children)
                }
                return node
            }
        }
    }
}
