import XCTest
@testable import Oculuxus

/// Copies the helper's `simple` fixture to a temporary folder that tests
/// may edit, and keeps the helper's index cache there too.
private func makeScratchProject() throws -> URL {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "oculuxus-tests-\(UUID().uuidString)")
    let project = tmp.appending(path: "simple")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: HelperEnvironment.repositoryRoot.appending(path: "helper/internal/analysis/testdata/simple"), to: project)
    setenv("OCULUXUS_CACHE_DIR", tmp.appending(path: "cache").path, 1)
    return project
}

private func requireHelper() throws -> URL {
    guard let helper = HelperEnvironment.helperURL() else {
        throw XCTSkip("bin/oculuxus-helper is not built; run `make build`")
    }
    return helper
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
private func waitUntil(timeout: Duration = .seconds(10), _ what: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            XCTFail("timed out waiting for \(what)")
            return
        }
        try await Task.sleep(for: .milliseconds(50))
    }
}

/// Search and test code over the protocol, against the real helper.
final class HelperSearchTests: XCTestCase {
    private var client: HelperClient!

    override func setUp() async throws {
        let helper = try requireHelper()
        let project = try makeScratchProject()
        client = try HelperClient(executable: helper, environment: HelperEnvironment.environment())
        var open = OcxOpenProjectRequest()
        open.rootDir = project.path
        open.goBinary = GoToolchain.locate() ?? ""
        _ = try await client.openProject(open)
    }

    override func tearDown() {
        client?.shutdown()
    }

    func testSearch() async throws {
        var request = OcxSearchRequest()
        request.query = "circle.area"
        let response = try await client.search(request)
        XCTAssertTrue(response.complete)
        let first = try XCTUnwrap(response.matches.first)
        XCTAssertEqual(first.packageID, "example.com/simple/shapes")
        XCTAssertEqual(first.declarationID, "Circle.Area")
        XCTAssertEqual(first.kind, .method)
        XCTAssertEqual(first.signature, "func (c Circle) Area() float64")
        XCTAssertEqual(first.origin, .project)
        XCTAssertEqual(first.matched.map { [$0.start, $0.end] }, [[0, 11]])

        // Dependencies and the standard library, once indexed.
        request.query = "Writer"
        request.includeDependencies = true
        request.wait = true
        let deps = try await client.search(request)
        XCTAssertTrue(deps.complete)
        XCTAssertGreaterThan(deps.totalPackages, 10)
        XCTAssertTrue(deps.matches.contains { $0.packageID == "io" && $0.declarationID == "Writer" && $0.origin == .stdlib })

        request.query = "shapes"
        let packages = try await client.search(request)
        XCTAssertEqual(packages.matches.first?.kind, .package)
        XCTAssertEqual(packages.matches.first?.packageID, "example.com/simple/shapes")
    }

    func testOutlineWithTests() async throws {
        _ = try await client.listPackages()
        let plain = try await client.packageOutline("example.com/simple/shapes")
        XCTAssertFalse(plain.declarations.contains { $0.id == "TestArea" })
        XCTAssertEqual(plain.externalTestPackageID, "")

        let withTests = try await client.packageOutline("example.com/simple/shapes", includeTests: true)
        let test = try XCTUnwrap(withTests.declarations.first { $0.id == "TestArea" })
        XCTAssertTrue(test.test)
        XCTAssertTrue(withTests.files.contains { $0.name == "shapes_test.go" && $0.test })
        XCTAssertEqual(withTests.externalTestPackageID, "example.com/simple/shapes_test")

        let xtest = try await client.packageOutline(withTests.externalTestPackageID, includeTests: true)
        XCTAssertEqual(xtest.name, "shapes_test")
        XCTAssertTrue(xtest.declarations.contains { $0.id == "ExampleDescribe" })
        let source = try await client.declarationSource(packageID: "example.com/simple/shapes", declarationID: "TestArea", includeTests: true)
        XCTAssertTrue(source.source.text.hasPrefix("func TestArea"))
    }
}

/// Live reload end to end: the session watches the folder, tells the
/// helper what changed, and refreshes what it cached.
@MainActor
final class LiveReloadTests: XCTestCase {
    private var session: ProjectSession!
    private var project: URL!

    override func setUp() async throws {
        _ = try requireHelper()
        project = try makeScratchProject()
        session = ProjectSession(rootDir: project.path, goBinary: GoToolchain.locate())
        await session.open()
        XCTAssertEqual(session.status, .ready)
    }

    override func tearDown() async throws {
        session?.close()
        if let project { try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
    }

    private let shapes = "example.com/simple/shapes"

    func testEditRefreshesPackage() async throws {
        let before = try await session.outline(shapes)
        XCTAssertFalse(before.declarations.contains { $0.id == "Octagon" })
        _ = try await session.declarationSource(WorkspaceLocation(packageID: shapes, declarationID: "Describe"))

        let file = project.appending(path: "shapes/extra.go")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n// Octagon has eight sides.\nfunc Octagon() int { return 8 }\n".utf8))
        try handle.close()

        // FSEvents → coalesced Reload → the package's revision goes up.
        try await waitUntil("the shapes package to reload") { session.revision(of: shapes) > 0 }
        let after = try await session.outline(shapes)
        XCTAssertTrue(after.declarations.contains { $0.id == "Octagon" }, "the cached outline was not refreshed")

        // The index follows.
        let search = try await session.search("Octagon", includeDependencies: false)
        XCTAssertEqual(search.matches.first?.declarationID, "Octagon")
    }

    func testNewPackageRelists() async throws {
        XCTAssertNil(session.package("example.com/simple/solids"))
        let dir = project.appending(path: "solids")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("package solids\n\n// Cube is a solid.\ntype Cube struct{ Side float64 }\n".utf8).write(to: dir.appending(path: "cube.go"))

        try await waitUntil("the package list to include solids") { session.package("example.com/simple/solids") != nil }
        XCTAssertTrue(session.listing.projectPackages.contains { $0.id == "example.com/simple/solids" })
        let outline = try await session.outline("example.com/simple/solids")
        XCTAssertTrue(outline.declarations.contains { $0.id == "Cube" })
    }

    func testTestFileEditDoesNotRelist() async throws {
        _ = try await session.outline(shapes, tests: true)
        let listing = session.listing.packages.map(\.id)
        let file = project.appending(path: "shapes/shapes_test.go")
        try (String(contentsOf: file, encoding: .utf8) + "\nfunc TestPerimeter(t *testing.T) {}\n").write(to: file, atomically: true, encoding: .utf8)

        try await waitUntil("the shapes package to reload") { session.revision(of: shapes) > 0 }
        XCTAssertEqual(session.listing.packages.map(\.id), listing)
        let outline = try await session.outline(shapes, tests: true)
        XCTAssertTrue(outline.declarations.contains { $0.id == "TestPerimeter" && $0.test })
    }

    func testSymbolSearchModel() async throws {
        let model = SymbolSearchModel(session: session, includeDependencies: true)
        model.query = "circ"
        try await waitUntil("search results") { model.status == .done }
        XCTAssertEqual(model.selected?.declarationID, "Circle")
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selection, 1)
        model.moveSelection(by: -5)
        XCTAssertEqual(model.selection, 0)

        model.query = "shapes.Describe"
        try await waitUntil("new results") { model.status == .done && model.selected?.declarationID == "Describe" }
        XCTAssertEqual(SymbolSearchModel.location(of: try XCTUnwrap(model.selected)), WorkspaceLocation(packageID: shapes, declarationID: "Describe"))

        model.query = "  "
        XCTAssertEqual(model.status, .idle)
        XCTAssertTrue(model.matches.isEmpty)
    }

    func testReopenForTarget() async throws {
        try Data("package shapes\n\nfunc OnWindows() {}\n".utf8).write(to: project.appending(path: "shapes/only_windows.go"))
        try Data("//go:build extra\n\npackage shapes\n\nfunc Tagged() {}\n".utf8).write(to: project.appending(path: "shapes/tagged.go"))
        // Let the watcher's reload of the new files settle first.
        try await Task.sleep(for: .seconds(1))
        let before = try await session.outline(shapes)
        XCTAssertFalse(before.declarations.contains { $0.id == "OnWindows" || $0.id == "Tagged" })
        let revision = session.revision(of: shapes)

        await session.reopen(target: BuildTarget(tags: ["extra"], goos: "windows", goarch: "amd64"))
        XCTAssertEqual(session.status, .ready)
        XCTAssertGreaterThan(session.revision(of: shapes), revision)
        let after = try await session.outline(shapes)
        XCTAssertTrue(after.declarations.contains { $0.id == "OnWindows" })
        XCTAssertTrue(after.declarations.contains { $0.id == "Tagged" })
        let search = try await session.search("Tagged", includeDependencies: false)
        XCTAssertEqual(search.matches.first?.declarationID, "Tagged")

        await session.reopen(target: BuildTarget())
        let reset = try await session.outline(shapes)
        XCTAssertFalse(reset.declarations.contains { $0.id == "Tagged" })
    }

    func testJumpToSymbolOpensWorkspace() async throws {
        let state = AppState()
        await state.openProject(project.path, openWindow: nil)
        let session = try XCTUnwrap(state.session)
        defer { session.close() }
        let response = try await session.search("Circle.Scale", includeDependencies: false)
        let match = try XCTUnwrap(response.matches.first)
        state.show(SymbolSearchModel.location(of: match), newWindow: false, openWindow: nil)
        XCTAssertEqual(state.activeWorkspace?.location, WorkspaceLocation(packageID: shapes, declarationID: "Circle.Scale"))
        state.show(WorkspaceLocation(packageID: shapes), newWindow: true, openWindow: nil)
        XCTAssertEqual(state.workspaces.count, 2)
    }
}

@MainActor
final class ProjectWatcherTests: XCTestCase {
    func testRelevantPaths() {
        let root = "/p"
        XCTAssertTrue(ProjectWatcher.isRelevant("/p/a.go", root: root))
        XCTAssertTrue(ProjectWatcher.isRelevant("/p/x/y/a_test.go", root: root))
        XCTAssertTrue(ProjectWatcher.isRelevant("/p/go.mod", root: root))
        XCTAssertTrue(ProjectWatcher.isRelevant("/p/sub/go.sum", root: root))
        XCTAssertTrue(ProjectWatcher.isRelevant("/p/vendor/x/a.go", root: root))
        XCTAssertFalse(ProjectWatcher.isRelevant("/p/README.md", root: root))
        XCTAssertFalse(ProjectWatcher.isRelevant("/p/.git/index", root: root))
        XCTAssertFalse(ProjectWatcher.isRelevant("/p/.hidden/a.go", root: root))
        XCTAssertFalse(ProjectWatcher.isRelevant("/p/x/testdata/a.go", root: root))
        XCTAssertFalse(ProjectWatcher.isRelevant("/p/_old/a.go", root: root))
        XCTAssertFalse(ProjectWatcher.isRelevant("/p/.#a.go", root: root))
        XCTAssertFalse(ProjectWatcher.isRelevant("/p/a.go~", root: root))
        XCTAssertFalse(ProjectWatcher.isRelevant("/pq/a.go", root: root))
    }

    func testCoalescesChanges() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "oculuxus-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "pkg"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var batches: [[String]] = []
        let watcher = ProjectWatcher(root: dir.path, quiet: .milliseconds(300)) { batches.append($0) }
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(200)) // let the stream settle

        for name in ["a.go", "b.go", "notes.txt"] {
            try Data("package pkg\n".utf8).write(to: dir.appending(path: "pkg/\(name)"))
            try await Task.sleep(for: .milliseconds(30))
        }
        try await waitUntil("a batch of changes") { !batches.isEmpty }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(batches.count, 1, "changes in quick succession should arrive together: \(batches)")
        let real = ProjectWatcher.realPath(dir.path)
        XCTAssertEqual(batches.first, [real + "/pkg/a.go", real + "/pkg/b.go"])
    }
}
