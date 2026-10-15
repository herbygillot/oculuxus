import XCTest
@testable import Oculuxus

@MainActor
final class SidebarTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "OculuxusSidebarTests"

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testWidth() {
        var state = SidebarState()
        XCTAssertEqual(state.resolvedWidth(in: 1600), 400)
        // A quarter of a narrow window is too narrow; of a wide one, too wide.
        XCTAssertEqual(state.resolvedWidth(in: 600), 200)
        XCTAssertEqual(state.resolvedWidth(in: 2400), 480)
        state.width = 300
        XCTAssertEqual(state.resolvedWidth(in: 1600), 300)
        // At most half the window.
        XCTAssertEqual(SidebarState.clamp(400, in: 700), 350)
    }

    func testNewWorkspaceCopiesLastActive() {
        let state = AppState(settings: AppSettings(defaults: defaults))
        let first = state.workspace(UUID())
        XCTAssertFalse(first.sidebar.isCollapsed)
        state.workspaceBecameActive(first.id)
        first.sidebar.toggle()
        first.sidebar.setWidth(320)

        let second = state.workspace(UUID())
        XCTAssertEqual(second.sidebar.state, SidebarState(isCollapsed: true, width: 320))

        // Changing the second does not change the first; the last change
        // is the default.
        second.sidebar.toggle()
        XCTAssertTrue(first.sidebar.isCollapsed)
        XCTAssertEqual(state.settings.navigatorSidebar, SidebarState(isCollapsed: false, width: 320))

        // The active Workspace's state wins over the last saved one.
        let third = state.workspace(UUID())
        XCTAssertTrue(third.sidebar.isCollapsed)
        state.workspaceBecameActive(first.id)
        XCTAssertEqual(state.settings.navigatorSidebar, SidebarState(isCollapsed: true, width: 320))
    }

    func testSavedForNextLaunch() {
        let state = AppState(settings: AppSettings(defaults: defaults))
        let workspace = state.workspace(UUID())
        state.workspaceBecameActive(workspace.id)
        workspace.sidebar.setWidth(260)
        workspace.sidebar.toggle()

        let relaunched = AppState(settings: AppSettings(defaults: defaults))
        XCTAssertEqual(relaunched.settings.navigatorSidebar, SidebarState(isCollapsed: true, width: 260))
        XCTAssertEqual(relaunched.workspace(UUID()).sidebar.state, SidebarState(isCollapsed: true, width: 260))
    }

    private func collapsedSidebar() -> NavigatorSidebar {
        let sidebar = NavigatorSidebar(SidebarState(isCollapsed: true))
        sidebar.showDelay = .milliseconds(30)
        sidebar.hideDelay = .milliseconds(40)
        return sidebar
    }

    func testPeekOnHover() async throws {
        let sidebar = collapsedSidebar()
        sidebar.hoverButton(true)
        XCTAssertEqual(sidebar.peek, .pending)
        await sidebar.awaitTimer()
        XCTAssertEqual(sidebar.peek, .shown)

        // Moving from the button onto the Navigator keeps it.
        sidebar.hoverButton(false)
        sidebar.hoverPeek(true)
        await sidebar.awaitTimer()
        XCTAssertTrue(sidebar.isPeeking)

        // Leaving both hides it after the grace period.
        sidebar.hoverPeek(false)
        XCTAssertTrue(sidebar.isPeeking)
        await sidebar.awaitTimer()
        XCTAssertEqual(sidebar.peek, .hidden)
        XCTAssertTrue(sidebar.isCollapsed)
    }

    func testPassingOverTheButtonDoesNotPeek() async throws {
        let sidebar = collapsedSidebar()
        sidebar.hoverButton(true)
        sidebar.hoverButton(false)
        await sidebar.awaitTimer()
        XCTAssertEqual(sidebar.peek, .hidden)
    }

    func testPickOrEscapeEndsPeek() async throws {
        let sidebar = collapsedSidebar()
        sidebar.hoverButton(true)
        await sidebar.awaitTimer()
        sidebar.hoverButton(false)
        sidebar.hoverPeek(true)
        sidebar.dismissPeek()
        XCTAssertEqual(sidebar.peek, .hidden)
        XCTAssertTrue(sidebar.isCollapsed)
    }

    func testClickWhilePeekingPins() async throws {
        let sidebar = collapsedSidebar()
        sidebar.hoverButton(true)
        await sidebar.awaitTimer()
        XCTAssertTrue(sidebar.isPeeking)
        sidebar.toggle()
        XCTAssertFalse(sidebar.isCollapsed)
        XCTAssertEqual(sidebar.peek, .hidden)

        // Collapsing with the pointer still on the button does not peek
        // until the pointer leaves and comes back.
        sidebar.toggle()
        XCTAssertTrue(sidebar.isCollapsed)
        await sidebar.awaitTimer()
        XCTAssertEqual(sidebar.peek, .hidden)
        sidebar.hoverButton(false)
        sidebar.hoverButton(true)
        await sidebar.awaitTimer()
        XCTAssertTrue(sidebar.isPeeking)
    }

    func testPinnedDoesNotPeek() async throws {
        let sidebar = NavigatorSidebar()
        sidebar.showDelay = .milliseconds(10)
        sidebar.hoverButton(true)
        await sidebar.awaitTimer()
        XCTAssertEqual(sidebar.peek, .hidden)
    }

    func testFullScreenPins() {
        var saved: SidebarState?
        let sidebar = NavigatorSidebar(SidebarState(isCollapsed: true))
        sidebar.onChange = { saved = $0 }
        sidebar.fullScreenChanged(true)
        XCTAssertFalse(sidebar.isCollapsed)
        // Full screen's pin is not the user's choice.
        XCTAssertTrue(sidebar.savedState.isCollapsed)
        sidebar.fullScreenChanged(false)
        XCTAssertTrue(sidebar.isCollapsed)
        XCTAssertNil(saved)

        // Toggling in full screen is kept after it.
        sidebar.fullScreenChanged(true)
        sidebar.toggle()
        XCTAssertTrue(sidebar.isCollapsed)
        sidebar.toggle()
        sidebar.fullScreenChanged(false)
        XCTAssertFalse(sidebar.isCollapsed)
        XCTAssertEqual(saved?.isCollapsed, false)
    }
}
