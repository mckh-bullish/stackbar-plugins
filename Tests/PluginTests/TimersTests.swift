import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class TimersTests: XCTestCase {
    func testStartsNamedTimersAndListsThem() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Timers")
        guard case .message(let tea) = await supervisor.runCommand("start", arguments: ["for": "10m tea"], source: .palette) else { return XCTFail("starts") }
        XCTAssertTrue(tea?.hasPrefix("tea: ends at") == true, "\(tea ?? "")")
        guard case .message = await supervisor.runCommand("start", arguments: ["for": "eggs 5m30s"], source: .palette) else { return XCTFail("name first works too") }
        guard case .failure(let nope) = await supervisor.runCommand("start", arguments: ["for": "banana"], source: .palette) else { return XCTFail("needs a length") }
        XCTAssertTrue(nope.contains("10m"), nope)

        let session = try await host.session("Timers")
        let opened = try await session.openView("list")
        XCTAssertEqual(opened.root?.rows.map(\.title), ["eggs", "tea"], "the soonest first")
        await session.stop()

        guard case .message(let stopped) = await supervisor.runCommand("stop-all", arguments: [:], source: .palette) else { return XCTFail("stops") }
        XCTAssertEqual(stopped, "Stopped 2 timers")
        await supervisor.stop()
    }
}
