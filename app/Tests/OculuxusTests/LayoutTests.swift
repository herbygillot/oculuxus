import XCTest
@testable import Oculuxus

@MainActor
final class WorkspaceSplitTests: XCTestCase {
    func testAutomaticShares() {
        var split = WorkspaceSplitLayout()
        XCTAssertEqual(split.outlineShare, 0.75)
        XCTAssertEqual(split.outlineWidth(in: 1000), 750)
        split.widePane = .source
        XCTAssertEqual(split.outlineWidth(in: 1000), 250)
        // Both panes stay usable in a narrow window.
        XCTAssertEqual(split.outlineWidth(in: 600), 200)
        split.widePane = .outline
        XCTAssertEqual(split.outlineWidth(in: 600), 400)
    }

    func testManualShare() {
        var split = WorkspaceSplitLayout(widePane: .source)
        split.manualShare = WorkspaceSplitLayout.share(outlineWidth: 400, in: 1000)
        XCTAssertFalse(split.isAutomatic)
        XCTAssertEqual(split.outlineWidth(in: 1000), 400)
        XCTAssertEqual(WorkspaceSplitLayout.share(outlineWidth: 10, in: 1000), 0.2)
        XCTAssertEqual(WorkspaceSplitLayout.share(outlineWidth: 990, in: 1000), 0.8)
    }

    func testClicksWidenPanes() async throws {
        let ws = WorkspaceModel(id: UUID())
        XCTAssertEqual(ws.split.widePane, .outline)
        ws.paneClicked(.source, .down)
        XCTAssertEqual(ws.split.widePane, .source)

        // The outline widens once the click is released.
        ws.paneClicked(.outline, .down)
        XCTAssertEqual(ws.split.widePane, .source)
        ws.paneClicked(.outline, .up)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(ws.split.widePane, .outline)

        // Selecting a declaration widens the source viewer instead, even
        // after the timeout for a lost release.
        ws.paneClicked(.outline, .down)
        ws.paneClicked(.outline, .up)
        ws.declarationClicked()
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(ws.split.widePane, .source)

        // A press whose release never arrives (a scroller) still counts.
        ws.paneClicked(.outline, .down)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(ws.split.widePane, .outline)
    }

    func testDraggedSplitStays() {
        let ws = WorkspaceModel(id: UUID(), split: 0.5)
        ws.paneClicked(.source, .down)
        ws.declarationClicked()
        XCTAssertEqual(ws.split.outlineShare, 0.5)
        ws.split.manualShare = nil
        ws.declarationClicked()
        XCTAssertEqual(ws.split.outlineShare, 0.25)
    }
}

final class BuildTargetTests: XCTestCase {
    func testParseTags() {
        XCTAssertEqual(BuildTarget.parseTags(" integration, purego netgo,,integration "), ["integration", "purego", "netgo"])
        XCTAssertEqual(BuildTarget.parseTags(""), [])
    }

    func testSummaryAndPlatform() throws {
        var target = BuildTarget()
        XCTAssertTrue(target.isDefault)
        XCTAssertNil(target.summary)
        target.platform = BuildTarget.presets[0]
        target.tags = ["integration"]
        XCTAssertEqual(target.summary, "linux/amd64 +integration")
        let decoded = try JSONDecoder().decode(BuildTarget.self, from: JSONEncoder().encode(target))
        XCTAssertEqual(decoded, target)
        target.platform = nil
        XCTAssertEqual(target.goos, "")
        XCTAssertEqual(target.summary, "+integration")
    }
}
