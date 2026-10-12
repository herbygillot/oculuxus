import XCTest
@testable import Oculuxus

final class SampleDataTests: XCTestCase {
    func testSampleProjectsBuild() {
        let project = SampleData.geometry()
        let outline = project.outline("github.com/example/geometry")
        XCTAssertEqual(outline.name, "geometry")
        let circle = outline.declarations.first { $0.id == "Circle" }
        XCTAssertEqual(circle?.kind, .struct)
        XCTAssertEqual(circle?.members.map(\.id), ["Circle.Center", "Circle.Radius", "Circle.Area", "Circle.Perimeter", "Circle.String"])
        XCTAssertEqual(circle?.location.line, 34)
        XCTAssertEqual(SampleData.greeter().listing.packages.count, 2)
    }

    func testDeclarationRangesCoverSource() throws {
        let project = SampleData.geometry()
        let file = try XCTUnwrap(project.files["/Users/gopher/src/geometry/shapes.go"])
        let range = try XCTUnwrap(file.declarations.first { $0.declarationID == "Shape" }?.range)
        let ns = try XCTUnwrap(CodeText.nsRange(range, in: file.source.text))
        let text = (file.source.text as NSString).substring(with: ns)
        XCTAssertTrue(text.hasPrefix("// Shape is a closed"))
        XCTAssertTrue(text.hasSuffix("}"))
    }

    func testReferencesResolveAcrossPackages() throws {
        let project = SampleData.geometry()
        let render = project.outline("github.com/example/geometry/render")
        let draw = try XCTUnwrap(render.declarations.first { $0.id == "Renderer" }?.members.first { $0.id == "Renderer.Draw" })
        let targets = draw.signature.tokens.filter(\.hasTarget).map(\.target)
        XCTAssertTrue(targets.contains(OcxSymbolRef(packageID: "github.com/example/geometry", declarationID: "Shape")))
    }

    func testReferenceURLRoundTrip() throws {
        let url = try XCTUnwrap(CodeText.url(for: OcxSymbolRef(packageID: "io", declarationID: "Reader")))
        XCTAssertEqual(CodeText.location(from: url), WorkspaceLocation(packageID: "io", declarationID: "Reader"))
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
}
