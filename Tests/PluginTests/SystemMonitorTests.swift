#if os(macOS)
import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

/// The plugin reads this Mac's real `ps`, `sysctl` and `kill`, so these tests
/// check what the panel shows and how a quit goes, not the numbers. The only
/// process a quit may end is a `sleep` the test starts itself.
final class SystemMonitorTests: XCTestCase {
    private func startSleep() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["31337"]
        try process.run()
        return process
    }

    /// How many values the panel's CPU chart draws, if it draws one.
    private func cpuReadings(_ panel: ViewNode?) -> Int? {
        (panel?.tree ?? []).lazy.compactMap { node -> Int? in
            if case .chart(let values, _, let label, _, _) = node, label == "CPU over time" { return values.count }
            return nil
        }.first
    }

    /// The panel's process rows, which are the ones with Copy PID.
    private func processRows(_ panel: ViewNode?) -> [RowNode] {
        (panel?.rows ?? []).filter { row in row.actions.contains { $0.title == "Copy PID" } }
    }

    func testOpeningTopProcessesTwiceAddsNoReadings() async throws {
        let host = Host(self)
        let session = try await host.session("SystemMonitor")
        // The launch reading and two refreshes make the chart.
        try await session.refresh()
        try await session.refresh()
        let before = cpuReadings(await session.view(.panel))
        XCTAssertGreaterThanOrEqual(before ?? 0, 3, "the chart needs three readings")

        for _ in 0..<2 {
            let opened = try await session.openView("top")
            await session.closeView(opened.session)
        }
        let after = cpuReadings(await session.view(.panel))
        XCTAssertEqual(after, before, "looking at the list doesn't add a reading")
        await session.stop()
    }

    func testThePanelKeepsEightProcessesAndTopProcessesListsAll() async throws {
        let host = Host(self)
        let session = try await host.session("SystemMonitor")
        let panel = await session.view(.panel)
        XCTAssertEqual(processRows(panel).count, 8, "the panel shows the first eight")
        let opened = try await session.openView("top")
        XCTAssertGreaterThan(opened.root?.rows.count ?? 0, 8, "Top Processes lists every process")
        await session.closeView(opened.session)
        await session.stop()
    }

    func testQuitInTopProcessesTakesTwoPresses() async throws {
        let sleeper = try startSleep()
        defer { if sleeper.isRunning { sleeper.terminate() } }
        let pid = Int(sleeper.processIdentifier)
        let host = Host(self)
        let session = try await host.session("SystemMonitor")
        try await session.refresh()
        let opened = try await session.openView("top")
        let row = try XCTUnwrap(opened.root?.rows.first { $0.key == "\(pid)" }, "the test's sleep is listed")
        XCTAssertEqual(row.title, "sleep")
        let quit = try XCTUnwrap(row.actions.first { $0.title == "Quit Process" })
        XCTAssertEqual(quit.role, .critical)

        try await session.event(quit.id)
        XCTAssertTrue(sleeper.isRunning, "the first press only asks again")
        let asked = await session.commandView(opened.session)?.rows.first { $0.key == "\(pid)" }
        XCTAssertEqual(asked?.subtitle, "Press again to quit sleep")

        try await session.event(quit.id)
        let ended = await waitUntil(5) { !sleeper.isRunning }
        XCTAssertTrue(ended, "the second press ends it")
        let rows = await session.commandView(opened.session)?.rows ?? []
        XCTAssertFalse(rows.contains { $0.key == "\(pid)" }, "and it is gone from the list")
        await session.closeView(opened.session)
        await session.stop()
    }
}
#endif
