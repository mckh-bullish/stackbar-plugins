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

    /// How long each timer in the panel has to run, soonest first, in seconds.
    private func lengths(_ supervisor: PluginSupervisor) async -> [Int] {
        let panel = await supervisor.views[.panel]
        let ranges = (panel?.tree ?? []).compactMap { node -> TimeRange? in
            if case .timer(let range, _) = node { return range }
            return nil
        }
        return ranges.map { Int($0.end.timeIntervalSince($0.start).rounded()) }
    }

    func testTheUnitAfterANumberDecidesTheLength() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Timers")
        for text in ["pasta 30 seconds", "1 hour tea", "10minutes eggs", "2 hours 15 min nap", "45sec", "1h30 bread", "90", "5 minutes 30 seconds"] {
            guard case .message = await supervisor.runCommand("start", arguments: ["for": text], source: .palette) else { return XCTFail("\(text) starts") }
        }
        _ = await waitUntil { await self.lengths(supervisor).count == 8 }
        let started = await lengths(supervisor)
        XCTAssertEqual(started.sorted(), [30, 45, 330, 600, 3600, 5400, 5400, 8100].sorted(), "\(started)")
        let session = try await host.session("Timers")
        let opened = try await session.openView("list")
        let names = opened.root?.rows.map(\.title) ?? []
        XCTAssertTrue(Set(names).isSuperset(of: ["pasta", "tea", "eggs", "nap", "bread"]), "the unit words are not part of the name: \(names)")
        await session.stop()
        await supervisor.stop()
    }
}
