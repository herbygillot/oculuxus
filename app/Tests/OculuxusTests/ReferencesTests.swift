import XCTest
@testable import Oculuxus

final class ReferenceGroupingTests: XCTestCase {
    private func ref(_ pkg: String, _ file: String, _ line: UInt32) -> OcxReference {
        var r = OcxReference()
        r.packageID = pkg
        r.packageName = (pkg as NSString).lastPathComponent
        r.location.file = file
        r.location.line = line
        return r
    }

    func testGroupsByPackageThenFileInOrder() {
        let groups = ReferenceGroup.group([
            ref("p/a", "/a/x.go", 1), ref("p/a", "/a/x.go", 9), ref("p/a", "/a/y.go", 2), ref("p/b", "/b/z.go", 3),
        ])
        XCTAssertEqual(groups.map(\.packageID), ["p/a", "p/b"])
        XCTAssertEqual(groups[0].files.map(\.name), ["x.go", "y.go"])
        XCTAssertEqual(groups[0].files[0].references.map(\.location.line), [1, 9])
        XCTAssertEqual(groups[0].count, 3)
    }

    func testReferenceLocationUsesEnclosingDeclaration() {
        var r = ref("p/a", "/a/x.go", 12)
        r.enclosingID = "T.M"
        XCTAssertEqual(ReferencesModel.location(of: r), WorkspaceLocation(packageID: "p/a", declarationID: "T.M", file: "/a/x.go", line: 12))
        r.enclosingID = ""
        XCTAssertNil(ReferencesModel.location(of: r).declarationID)
    }

    func testLineRange() {
        let text = "one\ntwo\n\nfour"
        XCTAssertEqual(SourceView.lineRange(1, in: text), NSRange(location: 0, length: 3))
        XCTAssertEqual(SourceView.lineRange(2, in: text), NSRange(location: 4, length: 3))
        XCTAssertEqual(SourceView.lineRange(3, in: text), NSRange(location: 8, length: 0))
        XCTAssertEqual(SourceView.lineRange(4, in: text), NSRange(location: 9, length: 4))
        XCTAssertNil(SourceView.lineRange(5, in: text))
        XCTAssertNil(SourceView.lineRange(0, in: text))
    }

    func testOldLocationsStillDecode() throws {
        let data = Data(#"{"packageID":"p","declarationID":"D"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceLocation.self, from: data), WorkspaceLocation(packageID: "p", declarationID: "D"))
    }

    func testSourceTokensMarkIdentifiersOnly() {
        var text = OcxText()
        text.text = "x := f(1)"
        func token(_ s: UInt32, _ e: UInt32, _ type: OcxTokenType) -> OcxToken {
            var t = OcxToken()
            t.range.start = s
            t.range.end = e
            t.type = type
            return t
        }
        text.tokens = [token(0, 1, .variable), token(2, 4, .operator), token(5, 6, .function), token(7, 8, .number)]
        let s = CodeText.attributed(text, theme: .light, font: .monospacedSystemFont(ofSize: 12, weight: .regular), markTokens: true)
        let marked = (0..<s.length).filter { s.attribute(.sourceToken, at: $0, effectiveRange: nil) != nil }
        XCTAssertEqual(marked, [0, 5])
        XCTAssertEqual((s.attribute(.sourceToken, at: 5, effectiveRange: nil) as? SourceToken)?.start, 5)
        XCTAssertTrue((s.attribute(.sourceToken, at: 5, effectiveRange: nil) as? SourceToken)?.isCallable ?? false)
    }
}

/// The references panel's model against the real helper.
@MainActor
final class ReferencesModelTests: XCTestCase {
    private var session: ProjectSession!
    private var project: URL!
    private let shapes = "example.com/simple/shapes"
    private let draw = "example.com/simple/draw"

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

    func testReferencesWithInterfaceUses() async throws {
        let model = ReferencesModel(session: session)
        model.show(ReferenceSubject(symbol: OcxSymbolRef(packageID: shapes, declarationID: "Circle.Area"), name: "Area"), tab: .references)
        try await waitUntil("references") { model.status == .done && model.resolved }
        XCTAssertTrue(model.isCallable)
        XCTAssertEqual(model.hover?.kind, "method")
        XCTAssertEqual(model.groups.map(\.packageID), [draw])
        XCTAssertTrue(model.references.contains { $0.viaInterface && $0.via == "shapes.Shape" })
        XCTAssertTrue(model.references.contains { !$0.viaInterface && $0.lineText.contains("c.Area()") })
        XCTAssertEqual(model.total, model.references.count)
    }

    func testCallersAndCallees() async throws {
        let model = ReferencesModel(session: session)
        model.show(ReferenceSubject(symbol: OcxSymbolRef(packageID: shapes, declarationID: "Describe"), name: "Describe"), tab: .callers)
        try await waitUntil("callers") { if case .loaded? = model.callers?.children { true } else { false } }
        guard case let .loaded(callers)? = model.callers?.children else { return XCTFail() }
        XCTAssertTrue(callers.contains { $0.item.symbol.declarationID == "Print" })
        let print = try XCTUnwrap(callers.first { $0.item.symbol.declarationID == "Print" })
        XCTAssertEqual(ReferencesModel.location(of: print.item, direction: .callers)?.declarationID, "Print")
        XCTAssertNotNil(ReferencesModel.location(of: print.item, direction: .callers)?.line)

        model.tab = .callees
        try await waitUntil("callees") { if case .loaded? = model.callees?.children { true } else { false } }
        guard case let .loaded(callees)? = model.callees?.children else { return XCTFail() }
        XCTAssertFalse(callees.isEmpty)
        XCTAssertTrue(callees.contains { $0.callLabel?.hasPrefix("via ") ?? false }, "Describe calls through Shape and io.Writer")
    }

    func testLocalByPositionIsNotCallable() async throws {
        // `sum` in draw.Total is a local: found by position, no declaration.
        // The file as the helper names it, as the source viewer has it.
        let outline = try await session.outline(draw)
        let file = try XCTUnwrap(outline.files.first { $0.name == "draw.go" }?.path)
        let text = try String(contentsOfFile: file, encoding: .utf8)
        let offset = try XCTUnwrap(text.range(of: "sum +=")).lowerBound.utf16Offset(in: text)
        var position = OcxPosition()
        position.file = file
        position.offset = UInt32(offset)
        let model = ReferencesModel(session: session)
        model.show(ReferenceSubject(position: position, packageID: draw, name: "sum"), tab: .callers)
        try await waitUntil("local references") { model.status == .done && model.resolved }
        XCTAssertNil(model.symbol)
        XCTAssertFalse(model.isCallable)
        XCTAssertEqual(model.tab, .references, "the call hierarchy falls back to references")
        XCTAssertGreaterThanOrEqual(model.references.count, 2)
        XCTAssertEqual(model.hover?.kind, "local variable")
    }

    func testHoverIsCachedPerDeclaration() async throws {
        let symbol = OcxSymbolRef(packageID: shapes, declarationID: "Circle")
        let first = try await session.hover(symbol)
        XCTAssertEqual(first?.kind, "struct")
        XCTAssertFalse(first?.doc.isEmpty ?? true)
        let second = try await session.hover(symbol)
        XCTAssertEqual(first, second)
    }
}
