import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class DictionaryTests: XCTestCase {
    func testARecentWordOpensItsDefinition() async throws {
        let session = try await Host(self).session("Dictionary")
        let opened = try await session.openView("define", query: CommandQuery(text: "", arguments: ["text": "serendipity"]))
        let rows = await session.commandView(opened.session)?.rows ?? opened.root?.rows ?? []
        XCTAssertTrue(rows.contains { $0.title == "serendipity" }, "the definition is shown, not the recent list: \(rows.map(\.title))")
        await session.stop()
    }

    func testThePanelLooksAWordUp() async throws {
        let supervisor = try await Host(self).start("Dictionary")
        await supervisor.press("field/Look up a word, then Return", value: .text("serendipity"))
        let shown = await waitUntil { await supervisor.views[.panel]?.plainText.contains("occurrence") == true }
        XCTAssertTrue(shown, "the definition shows in the panel")
        await supervisor.stop()
    }
}
