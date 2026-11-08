import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class ApplicationsTests: XCTestCase {
    func testASettingsPaneOpensByItsLink() async throws {
        let host = Host(self)
        let session = try await host.session("Applications")
        let opened = try await session.openView("search", query: CommandQuery(text: "wi-fi"))
        let row = try XCTUnwrap(opened.root?.rows.first)
        XCTAssertEqual(row.title, "Wi-Fi")
        try await session.event(try XCTUnwrap(row.actions.first).id)
        let arrived = await waitUntil { host.opened.all.contains { $0.url == "x-apple.systempreferences:com.apple.Wi-Fi-Settings.extension" } }
        XCTAssertTrue(arrived, "\(host.opened.all)")
        await session.stop()
    }

    func testTypingFindsTheApp() async throws {
        let host = Host(self)
        let session = try await host.session("Applications")
        let opened = try await session.openView("search", query: CommandQuery(text: "saf"))
        XCTAssertEqual(opened.root?.rows.first?.title, "Safari")
        await session.stop()
    }
}
