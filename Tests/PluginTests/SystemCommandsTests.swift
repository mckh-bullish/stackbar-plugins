import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class SystemCommandsTests: XCTestCase {
    func testADestructiveRowAsksStackbarForASecondClick() async throws {
        let host = Host(self)
        let supervisor = try await host.start("SystemCommands")
        let panel = await supervisor.views[.panel]
        let row = try XCTUnwrap(panel?.rows.first { $0.title == "Restart" })
        let action = try XCTUnwrap(row.actions.first)
        XCTAssertEqual(action.role, .critical)
        XCTAssertEqual(action.confirm, "restart the Mac", "Stackbar holds the first click and asks")
        let lock = try XCTUnwrap(panel?.rows.first { $0.title == "Lock Screen" })
        XCTAssertNil(lock.actions.first?.confirm, "harmless commands run at once")

        // The press Stackbar lets through, the second, runs it.
        await supervisor.press(action.id)
        XCTAssertEqual(host.system.performed, [.restart])
        await supervisor.stop()
    }
}
