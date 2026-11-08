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

    func testLengthsTakeUnits() async throws {
        let host = Host(self)
        let session = try await host.session("Pomodoro")
        guard case .message(let forty) = try await session.runCommand("start-focus", arguments: ["minutes": "45 minutes"]) else {
            return XCTFail("a length with a unit starts a session")
        }
        XCTAssertTrue(forty?.hasPrefix("Focusing") == true && (forty?.contains("45:00") == true || forty?.contains("44:5") == true), forty ?? "")
        // Under a minute in, so the second start replaces the first without asking.
        guard case .message(let hour) = try await session.runCommand("start-focus", arguments: ["minutes": "1h"]) else {
            return XCTFail("an hour starts a session")
        }
        XCTAssertTrue(hour?.contains("60:00") == true || hour?.contains("59:5") == true, hour ?? "")
        guard case .failure = try await session.runCommand("start-focus", arguments: ["minutes": "forever"]) else {
            return XCTFail("a length that is not a length is refused")
        }
    }

    func testResetFromThePaletteAsksFirst() async throws {
        let host = Host(self)
        // Fifteen minutes into a 25-minute focus session, paused.
        try await host.services.storage.set("session", #"{"mode":"Focus","minutes":25,"tag":"Deep Work","remaining":600}"#, for: id)
        let supervisor = try await host.start("Pomodoro")
        let asked = await supervisor.runCommand("reset", source: .palette)
        guard case .message(let text) = asked else { return XCTFail("reset answers instead of resetting") }
        XCTAssertTrue(text?.contains("again") == true, text ?? "")
        var status = await supervisor.callTool("status").text
        XCTAssertTrue(status.hasPrefix("Paused on Deep Work, 10:00 left"), "the first run keeps the session: \(status)")

        let reset = await supervisor.runCommand("reset", source: .palette)
        XCTAssertEqual(reset, .message("Pomodoro reset"))
        status = await supervisor.callTool("status").text
        XCTAssertTrue(status.hasPrefix("Idle"), status)
        await supervisor.stop()
    }

    func testAHugeLengthIsRefusedNotACrash() async throws {
        let host = Host(self)
        let session = try await host.session("Pomodoro")
        guard case .failure = try await session.runCommand("start-focus", arguments: ["minutes": "1e30"]) else {
            return XCTFail("a length beyond any session is refused")
        }
        // A crash would leave every later command failing, so the helper must still answer.
        let status = try await session.callTool("status", arguments: [:])
        XCTAssertFalse(status.isError, status.text)
        XCTAssertTrue(status.text.hasPrefix("Idle"), status.text)
        await session.stop()
    }

    func testDailyGoalShowsInStatus() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Pomodoro")
        await supervisor.press("picker/daily-goal", value: .text("6"))
        let status = await supervisor.callTool("status").text
        XCTAssertTrue(status.hasSuffix("Goal: 6 sessions."), status)
        await supervisor.stop()
    }
}
