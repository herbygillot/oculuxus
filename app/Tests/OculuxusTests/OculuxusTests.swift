import XCTest
@testable import Oculuxus

final class CodeTextTests: XCTestCase {
    func testReferenceURLRoundTrip() throws {
        var ref = OcxSymbolRef()
        ref.packageID = "io"
        ref.declarationID = "Reader"
        let url = try XCTUnwrap(CodeText.url(for: ref))
        XCTAssertEqual(CodeText.location(from: url), WorkspaceLocation(packageID: "io", declarationID: "Reader"))
    }

    func testByteRangesWithMultibyteText() throws {
        let text = "// héllo\nfunc F()"
        var range = OcxRange()
        range.start = 10 // "func", after 9 characters but 10 bytes
        range.end = 14
        let ns = try XCTUnwrap(CodeText.nsRange(range, in: text))
        XCTAssertEqual((text as NSString).substring(with: ns), "func")
    }
}

/// Talks to the real helper (bin/oculuxus-helper, from `make build`) on
/// the helper's own test fixture. Skipped when the helper is not built.
final class HelperClientTests: XCTestCase {
    private var client: HelperClient!

    override func setUp() async throws {
        guard let helper = HelperEnvironment.helperURL() else {
            throw XCTSkip("bin/oculuxus-helper is not built; run `make build`")
        }
        client = try HelperClient(executable: helper, environment: HelperEnvironment.environment())
        var open = OcxOpenProjectRequest()
        open.rootDir = HelperEnvironment.repositoryRoot.appending(path: "helper/internal/analysis/testdata/simple").path
        open.goBinary = GoToolchain.locate() ?? ""
        let project = try await client.openProject(open)
        XCTAssertEqual(project.modules.map(\.path), ["example.com/simple"])
    }

    override func tearDown() {
        client?.shutdown()
        XCTAssertFalse(client?.isRunning ?? false)
    }

    func testBrowseProject() async throws {
        let progress = Progress()
        let listing = try await client.listPackages { _ in progress.completedUnitCount += 1 }
        let shapes = try XCTUnwrap(listing.packages.first { $0.id == "example.com/simple/shapes" })
        XCTAssertEqual(shapes.origin, .project)
        XCTAssertTrue(listing.packages.contains { $0.id == "io" && $0.origin == .stdlib })
        XCTAssertGreaterThan(progress.completedUnitCount, 0, "expected Progress before the final response")

        let outline = try await client.packageOutline(shapes.id)
        XCTAssertEqual(outline.name, "shapes")
        let circle = try XCTUnwrap(outline.declarations.first { $0.id == "Circle" })
        XCTAssertEqual(circle.kind, .struct)
        XCTAssertTrue(circle.members.contains { $0.id == "Circle.Area" })

        // Describe's signature refers to io.Writer in another package.
        let describe = try XCTUnwrap(outline.declarations.first { $0.id == "Describe" })
        let targets = describe.signature.tokens.filter(\.hasTarget).map(\.target)
        XCTAssertTrue(targets.contains { $0.packageID == "io" && $0.declarationID == "Writer" })

        let source = try await client.declarationSource(packageID: shapes.id, declarationID: "Circle.Area")
        XCTAssertTrue(source.source.text.hasPrefix("// Area returns"))
        XCTAssertGreaterThan(source.location.line, 0)

        let file = try await client.fileSource(packageID: shapes.id, file: circle.location.file)
        let range = try XCTUnwrap(file.declarations.first { $0.declarationID == "Circle" }?.range)
        let ns = try XCTUnwrap(CodeText.nsRange(range, in: file.source.text))
        XCTAssertTrue((file.source.text as NSString).substring(with: ns).contains("type Circle struct"))

        // References load other packages' outlines on demand.
        let io = try await client.packageOutline("io")
        XCTAssertTrue(io.declarations.contains { $0.id == "Writer" })
    }

    func testConcurrentRequests() async throws {
        let client = try XCTUnwrap(self.client)
        _ = try await client.listPackages()
        async let a = client.packageOutline("example.com/simple/shapes")
        async let b = client.packageOutline("fmt")
        async let c = client.declarationSource(packageID: "example.com/simple/shapes", declarationID: "Describe")
        let (outlineA, outlineB, source) = try await (a, b, c)
        XCTAssertEqual(outlineA.name, "shapes")
        XCTAssertEqual(outlineB.name, "fmt")
        XCTAssertTrue(source.source.text.contains("func Describe"))
    }

    func testHelperErrors() async throws {
        _ = try await client.listPackages()
        do {
            _ = try await client.declarationSource(packageID: "example.com/simple/shapes", declarationID: "Nope")
            XCTFail("expected an error")
        } catch let error as HelperError {
            XCTAssertEqual(error.code, .notFound)
        }
    }

    func testCancelStopsRequest() async throws {
        _ = try await client.listPackages()
        let task = Task { [client] in try await client!.packageOutline("net/http") }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do {
            _ = try await task.value
            // The outline may finish before the Cancel arrives on a fast machine.
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        // The helper keeps serving after a cancel.
        let outline = try await client.packageOutline("example.com/simple/shapes")
        XCTAssertEqual(outline.name, "shapes")
    }
}

@MainActor
final class RequestCacheTests: XCTestCase {
    func testWaitersShareOneLoad() async throws {
        let cache = RequestCache<String, Int>()
        var loads = 0
        async let a = cache.value(for: "k") { loads += 1; try await Task.sleep(for: .milliseconds(50)); return 1 }
        async let b = cache.value(for: "k") { loads += 1; return 2 }
        let (x, y) = try await (a, b)
        XCTAssertEqual([x, y], [1, 1])
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(cache.cached("k"), 1)
    }

    func testLastWaiterCancelsLoad() async throws {
        let cache = RequestCache<String, Int>()
        let started = expectation(description: "load started")
        let cancelled = expectation(description: "load cancelled")
        let task = Task {
            try await cache.value(for: "k") {
                started.fulfill()
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    cancelled.fulfill()
                    throw error
                }
                return 1
            }
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertNil(cache.cached("k"))
    }
}

@MainActor
final class WorkspaceHistoryTests: XCTestCase {
    func testBackAndForward() {
        let ws = WorkspaceModel(id: UUID())
        ws.go(to: WorkspaceLocation(packageID: "a"))
        ws.go(to: WorkspaceLocation(packageID: "b"))
        ws.select("X")
        XCTAssertEqual(ws.location, WorkspaceLocation(packageID: "b", declarationID: "X"))
        ws.goBack()
        XCTAssertEqual(ws.location?.packageID, "a")
        XCTAssertTrue(ws.canGoForward)
        ws.go(to: WorkspaceLocation(packageID: "c"))
        XCTAssertFalse(ws.canGoForward)
        XCTAssertEqual(ws.history.map(\.packageID), ["a", "c"])
    }

    func testClosedWorkspaceStaysClosed() {
        let state = AppState()
        let id = UUID()
        _ = state.workspace(id)
        state.workspaceBecameActive(id)
        XCTAssertNotNil(state.activeWorkspace)

        state.workspaceClosed(id)
        // SwiftUI re-evaluating the closed window must not revive it.
        XCTAssertTrue(state.workspace(id).isClosed)
        state.workspaceBecameActive(id)
        XCTAssertNil(state.activeWorkspace)
        XCTAssertTrue(state.workspaces.isEmpty)
    }
}
