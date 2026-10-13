import XCTest
@testable import Oculuxus

final class PackageTreeTests: XCTestCase {
    private func listing(projectModules: [String] = ["example.com/proj"], projectPackages: [(String, String)]) -> PackageListing {
        var response = OcxListPackagesResponse()
        func module(_ path: String, _ version: String, main: Bool) -> OcxModule {
            var m = OcxModule()
            m.path = path
            m.version = version
            m.main = main
            return m
        }
        func package(_ path: String, _ origin: OcxPackageOrigin, module: String = "", version: String = "") -> OcxPackage {
            var p = OcxPackage()
            p.id = path
            p.importPath = path
            p.origin = origin
            p.modulePath = module
            p.moduleVersion = version
            return p
        }
        response.modules = projectModules.map { module($0, "", main: true) } + [module("github.com/dep/lib", "v1.2.0", main: false)]
        response.packages = projectPackages.map { package($0.0, .project, module: $0.1) } + [
            package("github.com/dep/lib", .dependency, module: "github.com/dep/lib", version: "v1.2.0"),
            package("github.com/dep/lib/internal/a/b", .dependency, module: "github.com/dep/lib", version: "v1.2.0"),
            package("fmt", .stdlib),
            package("net", .stdlib),
            package("net/http", .stdlib),
            package("net/http/httptest", .stdlib),
        ]
        return PackageListing(response)
    }

    /// Names, indented two spaces per level; a trailing "/" marks a folder
    /// that is not itself a package.
    private func render(_ nodes: [PackageNode], depth: Int = 0) -> [String] {
        nodes.flatMap { node in
            [String(repeating: "  ", count: depth) + node.name + (node.package == nil ? "/" : "")] + render(node.children, depth: depth + 1)
        }
    }

    private var single: PackageListing {
        listing(projectPackages: [
            ("example.com/proj", "example.com/proj"),
            ("example.com/proj/cmd/tool", "example.com/proj"),
            ("example.com/proj/internal/server", "example.com/proj"),
            ("example.com/proj/internal/store", "example.com/proj"),
            ("example.com/proj/internal/store/sql", "example.com/proj"),
        ])
    }

    func testTree() {
        let outline = NavigatorOutline(single, layout: .tree)
        XCTAssertEqual(render(outline.project), [
            "proj",
            "cmd/tool",
            "internal/",
            "  server",
            "  store",
            "    sql",
        ])
        XCTAssertEqual(outline.dependencies.map(\.group.module.version), ["v1.2.0"])
        XCTAssertEqual(render(outline.dependencies[0].nodes), ["lib", "internal/a/b"])
        XCTAssertEqual(render(outline.stdlib), ["fmt", "net", "  http", "    httptest"])
    }

    func testFlat() {
        let outline = NavigatorOutline(single, layout: .flat)
        XCTAssertEqual(render(outline.project), [
            "example.com/proj",
            "example.com/proj/cmd/tool",
            "example.com/proj/internal/server",
            "example.com/proj/internal/store",
            "example.com/proj/internal/store/sql",
        ])
        XCTAssertEqual(render(outline.dependencies[0].nodes), ["github.com/dep/lib", "github.com/dep/lib/internal/a/b"])
        XCTAssertEqual(render(outline.stdlib), ["fmt", "net", "net/http", "net/http/httptest"])
    }

    func testSeveralProjectModulesGetAFolderEach() {
        let listing = listing(projectModules: ["example.com/a", "example.com/b"], projectPackages: [
            ("example.com/a/util", "example.com/a"),
            ("example.com/b", "example.com/b"),
            ("example.com/b/util", "example.com/b"),
        ])
        XCTAssertEqual(render(NavigatorOutline(listing, layout: .tree).project), [
            "example.com/a/",
            "  util",
            "example.com/b/",
            "  b",
            "  util",
        ])
    }

    func testAncestorsForReveal() {
        let tree = NavigatorOutline(single, layout: .tree)
        XCTAssertEqual(tree.ancestors(of: "example.com/proj/internal/store/sql"), ["project:internal", "project:internal/store"])
        XCTAssertEqual(tree.ancestors(of: "net/http/httptest"), ["std:net", "std:net/http"])
        XCTAssertEqual(tree.ancestors(of: "github.com/dep/lib/internal/a/b"), [])
        XCTAssertEqual(tree.ancestors(of: "fmt"), [])
        XCTAssertNil(tree.ancestors(of: "missing"))

        let flat = NavigatorOutline(single, layout: .flat)
        XCTAssertEqual(flat.ancestors(of: "net/http/httptest"), [])

        // Every node ID is unique, so expansion state never leaks between rows.
        func ids(_ nodes: [PackageNode]) -> [String] { nodes.flatMap { [$0.id] + ids($0.children) } }
        for outline in [tree, flat] {
            let all = ids(outline.project) + ids(outline.stdlib) + outline.dependencies.flatMap { ids($0.nodes) }
            XCTAssertEqual(all.count, Set(all).count)
        }
    }
}
