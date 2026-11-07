import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class SystemCommandsTests: XCTestCase {
    /// SystemCommands.armWindow.
    static let window = 10.0


    func testADestructiveRowAsksTwiceAndForgetsTheFirstClick() async throws {
        let host = Host(self)
        let supervisor = try await host.start("SystemCommands")
        func restartRow() async -> RowNode? { await supervisor.views[.panel]?.rows.first { $0.title.hasSuffix("estart") || $0.title.hasPrefix("Click again to restart") } }

        let firstRow = await restartRow()
        let first = try XCTUnwrap(firstRow)
        XCTAssertEqual(first.title, "Restart")
        await supervisor.press(try XCTUnwrap(first.actions.first).id)
        let armedRow = await restartRow()
        let armed = try XCTUnwrap(armedRow)
        XCTAssertEqual(armed.title, "Click again to restart")
        XCTAssertTrue(host.system.performed.isEmpty, "one click only asks")

        // Left alone, the first click is forgotten: reopening the panel shows the plain row.
        try await Task.sleep(for: .seconds(SystemCommandsTests.window + 0.5))
        await supervisor.setVisible(.panel, true)
        let reset = await waitUntil { await restartRow()?.title == "Restart" }
        XCTAssertTrue(reset, "the armed row never resets")
        XCTAssertTrue(host.system.performed.isEmpty)

        let again = await restartRow()
        await supervisor.press(try XCTUnwrap(again?.actions.first).id)
        let confirm = await restartRow()
        await supervisor.press(try XCTUnwrap(confirm?.actions.first).id)
        XCTAssertEqual(host.system.performed, [.restart], "two clicks in time run it")
        await supervisor.stop()
    }
}
