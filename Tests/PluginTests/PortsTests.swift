import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

#if os(macOS)
/// Drives a real `nc` listener through lsof and kill, which is the Mac's job;
/// like Kill Process's process tests, it runs on the macOS job only.
final class PortsTests: XCTestCase {
    /// Kill Port shows what holds the port and stops it only on Return.
    func testKillPortAsksBeforeStopping() async throws {
        let port = 54931
        let listener = Process()
        listener.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        listener.arguments = ["-l", "127.0.0.1", "\(port)"]
        try listener.run()
        defer { if listener.isRunning { listener.terminate() } }

        let session = try await Host(self).session("Ports")
        let holder = "confirm-\(listener.processIdentifier)"
        var opened: (session: Int, root: ViewNode?)?
        var rows: [RowNode] = []
        let found = await waitUntil(10) {
            if let earlier = opened { await session.closeView(earlier.session) }
            // A fresh scan, so the view doesn't reuse a list from before nc was listening.
            _ = try? await session.refresh()
            opened = try? await session.openView("kill-port", query: CommandQuery(arguments: ["port": "\(port)"]))
            rows = opened?.root?.rows ?? []
            return rows.contains { $0.key == holder }
        }
        XCTAssertTrue(found, "the holder is listed")
        XCTAssertTrue(listener.isRunning, "opening the command stops nothing")

        let row = try XCTUnwrap(rows.first { $0.key == holder })
        try await session.event(try XCTUnwrap(row.actions.first).id)
        let stopped = await waitUntil(5) { !listener.isRunning }
        XCTAssertTrue(stopped, "Return stops it")

        let empty = try await session.openView("kill-port", query: CommandQuery(arguments: ["port": "54932"])).root?.rows ?? []
        XCTAssertTrue(empty.isEmpty)
        await session.stop()
    }
}
#endif
