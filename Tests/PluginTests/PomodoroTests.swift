import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class PomodoroTests: XCTestCase {
    private let id = "io.navbytes.stackbar.plugins.pomodoro"

    func testCommandsDriveTheTimer() async throws {
        let host = Host(self)
        let session = try await host.session("Pomodoro")
        guard case .message(let started) = try await session.runCommand("start-focus", arguments: ["minutes": "50", "tag": "Writing"]) else {
            return XCTFail("start-focus starts a session")
        }
        XCTAssertEqual(started?.hasPrefix("Focusing on Writing, "), true, started ?? "")
        guard case .message(let paused) = try await session.runCommand("toggle") else { return XCTFail("toggle pauses") }
        XCTAssertEqual(paused?.hasPrefix("Paused on Writing, "), true, paused ?? "")
        guard case .message(let resumed) = try await session.runCommand("start-focus") else { return XCTFail("start-focus resumes") }
        XCTAssertEqual(resumed?.hasPrefix("Focusing on Writing"), true, resumed ?? "")
        guard case .failure = try await session.runCommand("start-break", arguments: ["minutes": "forever"]) else {
            return XCTFail("a length that is not a number is refused")
        }
        guard case .message(let rest) = try await session.runCommand("start-break", arguments: ["minutes": "10"]) else {
            return XCTFail("start-break starts a break")
        }
        XCTAssertEqual(rest?.hasPrefix("On a break, 10:00") == true || rest?.hasPrefix("On a break, 9:5") == true, true, rest ?? "")
        guard case .message(let skipped) = try await session.runCommand("skip") else { return XCTFail("skip moves on") }
        XCTAssertEqual(skipped, "Up next: Focus, 25 min")
        _ = try await session.runCommand("toggle")
        guard case .message(let reset) = try await session.runCommand("reset") else { return XCTFail("reset clears the timer") }
        XCTAssertEqual(reset, "Pomodoro reset")
        guard case .message(let idle) = try await session.runCommand("toggle") else { return XCTFail("toggle starts again") }
        XCTAssertEqual(idle?.hasPrefix("Focusing on Writing"), true, "the tag given before sticks: \(idle ?? "")")
    }

    func testAStrayTapAsksBeforeEndingASessionUnderWay() async throws {
        let host = Host(self)
        // Fifteen minutes into a 25-minute focus session, paused.
        try await host.services.storage.set("session", #"{"mode":"Focus","minutes":25,"tag":"Deep Work","remaining":600}"#, for: id)
        let supervisor = try await host.start("Pomodoro")
        func status() async -> String { await supervisor.callTool("status").text }

        await supervisor.press("button/preset-50")
        var now = await status()
        XCTAssertTrue(now.hasPrefix("Paused on Deep Work, 10:00 left"), "a preset tap alone keeps the session: \(now)")
        await supervisor.press("button/keep")
        await supervisor.press("button/skip")
        now = await status()
        XCTAssertTrue(now.hasPrefix("Paused on Deep Work, 10:00 left"), "so does skip: \(now)")
        await supervisor.press("button/confirm")
        now = await status()
        XCTAssertTrue(now.hasPrefix("Idle. Next: Break, 5 min"), "confirming skips: \(now)")

        // A session that has barely started switches on the first tap.
        await supervisor.press("button/start")
        await supervisor.press("button/preset-10")
        now = await status()
        XCTAssertTrue(now.hasPrefix("Idle. Next: Break, 10 min"), now)
        await supervisor.stop()
    }

    func testAStartCommandAsksBeforeReplacingASessionUnderWay() async throws {
        let host = Host(self)
        try await host.services.storage.set("session", #"{"mode":"Focus","minutes":25,"tag":"Deep Work","remaining":600}"#, for: id)
        let supervisor = try await host.start("Pomodoro")
        func status() async -> String { await supervisor.callTool("status").text }
        _ = await supervisor.runCommand("start-break", arguments: ["minutes": "10"], source: .palette)
        var now = await status()
        XCTAssertTrue(now.hasPrefix("Paused on Deep Work, 10:00 left"), "the first run only warns: \(now)")
        _ = await supervisor.runCommand("start-break", arguments: ["minutes": "10"], source: .palette)
        now = await status()
        XCTAssertTrue(now.hasPrefix("On a break"), "run again, it replaces the session: \(now)")
        await supervisor.stop()
    }
}
