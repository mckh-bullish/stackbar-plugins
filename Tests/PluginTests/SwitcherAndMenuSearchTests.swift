import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class SwitcherAndMenuSearchTests: XCTestCase {
    func testSwitchWindowsFindsByAppAndTitleAndFocuses() async throws {
        let host = Host(self)
        let session = try await host.session("WindowSwitcher")
        let opened = try await session.openView("switch")
        let all = try XCTUnwrap(opened.root).rows
        XCTAssertEqual(all.map(\.title), ["Stackbar — Windows.swift", "Stackbar docs", "Slack — navbytes", "Pull requests"], "front to back with nothing typed")
        XCTAssertEqual(all.last?.subtitle, "Safari · Minimized")
        XCTAssertEqual(all.first?.appIcon, "com.apple.dt.Xcode")

        let typed = try await session.updateView(opened.session, query: CommandQuery(text: "saf pull"))
        let rows = try XCTUnwrap(typed).rows
        XCTAssertEqual(rows.map(\.title), ["Pull requests"], "every word must match the app or the title")
        try await session.event(try XCTUnwrap(rows.first?.actions.first).id)
        XCTAssertTrue(host.system.appActions.contains("focus com.apple.Safari Pull requests"), "\(host.system.appActions)")
        let front = try XCTUnwrap(host.system.currentWindows.windows.first)
        XCTAssertEqual(front.title, "Pull requests")
        XCTAssertFalse(front.isMinimized, "a minimized window comes out of the Dock")

        let none = try await session.updateView(opened.session, query: CommandQuery(text: "zzz"))
        XCTAssertEqual(none?.rows.count, 0)
        await session.stop()
    }

    func testSearchMenuItemsRanksAndChooses() async throws {
        let host = Host(self)
        let session = try await host.session("MenuSearch")
        let opened = try await session.openView("search")
        XCTAssertEqual(opened.root?.rows.count, 10, "every item with nothing typed")

        let zoomView = try await session.updateView(opened.session, query: CommandQuery(text: "view zoom"))
        let zoom = try XCTUnwrap(zoomView).rows
        XCTAssertEqual(zoom.first?.title, "Zoom In")
        XCTAssertEqual(zoom.first?.subtitle, "View")
        XCTAssertEqual(zoom.first?.appIcon, "com.apple.Safari")

        let newView = try await session.updateView(opened.session, query: CommandQuery(text: "new"))
        let new = try XCTUnwrap(newView).rows
        XCTAssertEqual(new.map(\.title), ["New Window", "New Private Window"])
        try await session.event(try XCTUnwrap(new[1].actions.first).id)
        XCTAssertTrue(host.system.appActions.contains("press com.apple.Safari File > New Private Window"), "\(host.system.appActions)")

        let undoView = try await session.updateView(opened.session, query: CommandQuery(text: "undo"))
        let undo = try XCTUnwrap(undoView).rows
        XCTAssertEqual(undo.first?.subtitle, "Edit · dimmed")
        XCTAssertEqual(undo.first?.actions.map(\.title), ["Copy Path"], "a dimmed item can't be chosen")
        await session.stop()
    }

    func testTypingReusesTheWindowListUntilTheViewReopens() async throws {
        let host = Host(self)
        let session = try await host.session("WindowSwitcher")
        let opened = try await session.openView("switch")
        XCTAssertEqual(opened.root?.rows.count, 4)

        // Windows that vanish while typing don't trigger another read.
        host.system.simulate(windows: WindowSnapshot())
        let typed = try await session.updateView(opened.session, query: CommandQuery(text: "saf"))
        XCTAssertEqual(try XCTUnwrap(typed).rows.count, 3, "the snapshot from opening is reused (three Safari windows)")

        // Clearing the text counts as opening again.
        let cleared = try await session.updateView(opened.session, query: CommandQuery(text: ""))
        XCTAssertEqual(cleared?.rows.count, 0)
        await session.stop()
    }
}
