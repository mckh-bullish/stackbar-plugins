import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class StayAwakeTests: XCTestCase {
    private let id = "io.navbytes.stackbar.stay-awake"

    func testClickingTheCupStartsAndStops() async throws {
        let host = Host(self)
        let supervisor = try await host.start("StayAwake")
        let click = await supervisor.menuBarClick
        // The host sends the same click action whatever the plugin does with it.
        let action = try XCTUnwrap(click, "clicking the cup starts a session by default").action
        await supervisor.press(action)
        XCTAssertEqual(host.system.keptAwake[id]?.reason, "Stay Awake: Until you stop it")
        await supervisor.press(action)
        XCTAssertTrue(host.system.keptAwake.isEmpty, "a second click stops it")
        await supervisor.stop()
    }

    func testHoldsUntilTheBatteryIsLowAndTakesATypedDuration() async throws {
        let host = Host(self)
        let fast = BackoffPolicy(initialDelay: 0.05, multiplier: 1, maxDelay: 0.05, maxConsecutiveFailures: 3)
        let supervisor = try await host.start("StayAwake", policy: fast)
        XCTAssertTrue(host.system.keptAwake.isEmpty)

        // The durations are chips: buttons keyed by their minutes.
        let hour = await supervisor.views[.panel]?.tree.lazy.compactMap { node -> ActionID? in
            if case .tappable(_, let action) = node, action.rawValue == "button/for-60" { return action }
            return nil
        }.first
        await supervisor.press(try XCTUnwrap(hour, "no one-hour chip"))
        let held = await waitUntil(10) { host.system.keptAwake[self.id] != nil }
        XCTAssertTrue(held)
        let status = await supervisor.callTool("awake_status")
        XCTAssertTrue(status.text.contains("left"), status.text)

        // A low battery ends the hold on the next refresh.
        host.system.simulate(status: SystemStatus(batteryLevel: 0.1, onACPower: false))
        await supervisor.refresh()
        let released = await waitUntil(10) { host.system.keptAwake.isEmpty }
        XCTAssertTrue(released, "the battery floor lets the Mac sleep")
        host.system.simulate(status: SystemStatus(batteryLevel: 0.9, onACPower: true))
        await supervisor.refresh()
        let resumed = await waitUntil(10) { !host.system.keptAwake.isEmpty }
        XCTAssertTrue(resumed, "the session resumes once the battery is fine")

        // The first text field takes a duration.
        let field = await supervisor.views[.panel]?.tree.lazy.compactMap { node -> ActionID? in
            if case .textField(_, _, let action) = node { return action }
            return nil
        }.first
        await supervisor.press(try XCTUnwrap(field, "no duration field"), value: .text("1h30"))
        let custom = await waitUntil(10) {
            let status = await supervisor.callTool("awake_status").text
            return status.contains("1h 29m left") || status.contains("1h 30m left")
        }
        XCTAssertTrue(custom, "a typed duration starts a session")

        await supervisor.stop()
        XCTAssertTrue(host.system.keptAwake.isEmpty)
    }

    func testFollowsDisplaysAndDownloads() async throws {
        let host = Host(self, system: SimulatedSystem(status: SystemStatus(batteryLevel: 0.9, onACPower: true, externalDisplays: 0, networkBytesReceived: 0)))
        let supervisor = try await host.start("StayAwake")
        await supervisor.press("toggle/display", value: .bool(true))
        await supervisor.press("toggle/download", value: .bool(true))
        XCTAssertNil(host.system.keptAwake[id], "no display and no download yet")

        host.system.simulate(status: SystemStatus(batteryLevel: 0.9, onACPower: true, externalDisplays: 1, networkBytesReceived: 0))
        await supervisor.refresh()
        let held = await waitUntil(5) { host.system.keptAwake[self.id]?.reason.hasSuffix("While a display is connected") == true }
        XCTAssertTrue(held, "\(String(describing: host.system.keptAwake[id]))")

        host.system.simulate(status: SystemStatus(batteryLevel: 0.9, onACPower: true, externalDisplays: 0, networkBytesReceived: 0))
        await supervisor.refresh()
        let released = await waitUntil(5) { host.system.keptAwake[self.id] == nil }
        XCTAssertTrue(released, "unplugging the display lets the Mac sleep")

        try await Task.sleep(nanoseconds: 1_200_000_000)
        host.system.simulate(status: SystemStatus(batteryLevel: 0.9, onACPower: true, externalDisplays: 0, networkBytesReceived: 50_000_000))
        await supervisor.refresh()
        let downloading = await waitUntil(5) { host.system.keptAwake[self.id]?.reason.hasSuffix("While a download is running") == true }
        XCTAssertTrue(downloading, "a fast download keeps the Mac awake")
        await supervisor.stop()
    }

    func testChartsTheWeek() async throws {
        let host = Host(self)
        let supervisor = try await host.start("StayAwake")
        let empty = await supervisor.views[.panel]
        XCTAssertFalse(try XCTUnwrap(empty).charts.contains { $0.kind == .bar }, "no week to chart before the Mac is ever kept awake")
        // Time awake counts from one refresh to the next.
        await supervisor.press("button/for-60")
        let held = await waitUntil(10) { host.system.keptAwake[self.id] != nil }
        XCTAssertTrue(held)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        await supervisor.refresh()
        let charted = await waitUntil(10) { await supervisor.views[.panel]?.charts.contains { $0.kind == .bar && $0.values.count == 7 } == true }
        XCTAssertTrue(charted, "the panel charts hours awake per day")
        await supervisor.stop()
    }

    func testCommandsToggleAndTakeADuration() async throws {
        let host = Host(self)
        let session = try await host.session("StayAwake")
        guard case .message = try await session.runCommand("toggle") else { return XCTFail("toggle starts a session") }
        XCTAssertEqual(host.system.keptAwake[id]?.reason, "Stay Awake: Until you stop it")
        _ = try await session.runCommand("toggle")
        XCTAssertTrue(host.system.keptAwake.isEmpty, "toggling again lets the Mac sleep")

        _ = try await session.runCommand("keep-awake", arguments: ["for": "90m"])
        XCTAssertNotNil(host.system.keptAwake[id]?.reason.range(of: "Stay Awake: Until "), "a duration starts a timed session")
        guard case .failure = try await session.runCommand("keep-awake", arguments: ["for": "soon"]) else { return XCTFail("nonsense is refused") }
        _ = try await session.runCommand("allow-sleep")
        XCTAssertTrue(host.system.keptAwake.isEmpty)
    }

    func testAnAbsurdDurationDoesNotCrashTheHelper() async throws {
        let host = Host(self)
        let supervisor = try await host.start("StayAwake")
        let kept = await supervisor.callTool("keep_awake", arguments: ["minutes": .number(1e20)])
        XCTAssertFalse(kept.isError, kept.text)
        let status = await supervisor.callTool("awake_status")
        XCTAssertTrue(status.text.contains("Staying awake"), "the helper is still answering: \(status.text)")
        await supervisor.stop()

        let session = try await host.session("StayAwake")
        guard case .message = try await session.runCommand("keep-awake", arguments: ["for": "1e20"]) else { return XCTFail("a huge typed duration is capped, not a crash") }
        _ = try await session.runCommand("allow-sleep")
    }

    func testDurationsAndTimesInWords() async throws {
        let host = Host(self)
        let session = try await host.session("StayAwake")
        for text in ["2 hours", "45 mins", "1 hour 30 minutes", "for 2h", "at 5pm", "noon", "until midnight", "90 sec"] {
            guard case .message = try await session.runCommand("keep-awake", arguments: ["for": text]) else {
                return XCTFail("\(text) keeps the Mac awake")
            }
            _ = try await session.runCommand("allow-sleep")
        }
        guard case .failure = try await session.runCommand("keep-awake", arguments: ["for": "0"]) else {
            return XCTFail("0 is neither a length nor a time")
        }

        _ = try await session.runCommand("keep-awake", arguments: ["for": "2 hours"])
        let twoHours = try await session.callTool("awake_status", arguments: [:]).text
        XCTAssertTrue(twoHours.contains("2h 0m left") || twoHours.contains("1h 59m left"), twoHours)
        _ = try await session.runCommand("allow-sleep")

        _ = try await session.runCommand("keep-awake", arguments: ["for": "90 sec"])
        let ninety = try await session.callTool("awake_status", arguments: [:]).text
        XCTAssertTrue(ninety.contains("1m left"), "90 seconds is a minute and a half, not nine minutes: \(ninety)")
        _ = try await session.runCommand("allow-sleep")

        // "until 12" is the next twelve o'clock: midnight when it is late in the evening.
        let calendar = Calendar.current
        let now = Date()
        let noon = try XCTUnwrap(calendar.nextDate(after: now, matching: DateComponents(hour: 12, minute: 0, second: 0), matchingPolicy: .nextTime))
        let midnight = try XCTUnwrap(calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime))
        _ = try await session.runCommand("keep-awake", arguments: ["for": "until 12"])
        let untilTwelve = try await session.callTool("awake_status", arguments: [:]).text
        let sooner = min(noon, midnight).formatted(date: .omitted, time: .shortened)
        XCTAssertTrue(untilTwelve.contains("Until \(sooner)"), "\(untilTwelve) should end at \(sooner)")
        _ = try await session.runCommand("allow-sleep")
    }

    func testAllowSleepPausesARuleThatHoldsTheMac() async throws {
        let host = Host(self, system: SimulatedSystem(status: SystemStatus(batteryLevel: 0.9, onACPower: true)))
        let supervisor = try await host.start("StayAwake")
        await supervisor.press("toggle/Always stay awake while plugged in", value: .bool(true))
        let held = await waitUntil(10) { host.system.keptAwake[self.id]?.reason.hasSuffix("While plugged in") == true }
        XCTAssertTrue(held, "plugged in keeps the Mac awake")

        // Allow Sleep can't turn off a rule for good, so it pauses the rule for an hour.
        let allowed = await supervisor.runCommand("allow-sleep", source: .palette)
        guard case .message(let text) = allowed else { return XCTFail("allow-sleep answers") }
        XCTAssertTrue(text?.contains("paused") == true, text ?? "")
        let released = await waitUntil(10) { host.system.keptAwake[self.id] == nil }
        XCTAssertTrue(released, "the Mac can sleep while the rule is paused")
        await supervisor.stop()
    }

    func testTheEndNotificationOffersMoreTime() async throws {
        let host = Host(self)
        let supervisor = try await host.start("StayAwake")
        _ = await supervisor.runCommand("keep-awake", arguments: ["for": "2s"], source: .palette)
        try await Task.sleep(nanoseconds: 2_500_000_000)
        await supervisor.refresh()
        let ended = await waitUntil(10) { host.notifications.all.contains { $0.title == "Your Mac can sleep again" } }
        XCTAssertTrue(ended)
        let note = host.notifications.all.first { $0.title == "Your Mac can sleep again" }
        XCTAssertEqual(note?.actions.first?.command, "keep-awake", "the end offers to keep it awake")
        XCTAssertEqual(note?.actions.first?.arguments?["for"], "1h")
        await supervisor.stop()
    }

    func testAColonTimeAfterNoonIsAClockTime() async throws {
        let host = Host(self)
        let session = try await host.session("StayAwake")
        for (text, hour, minute) in [("17:30", 17, 30), ("13:00", 13, 0)] {
            let before = Date()
            guard case .message(let message) = try await session.runCommand("keep-awake", arguments: ["for": text]) else {
                return XCTFail("\(text) keeps the Mac awake")
            }
            let end = try XCTUnwrap(Calendar.current.nextDate(after: before, matching: DateComponents(hour: hour, minute: minute, second: 0), matchingPolicy: .nextTime))
            let shown = end.formatted(date: .omitted, time: .shortened).lowercased()
            XCTAssertTrue(message?.lowercased().contains("until \(shown)") == true, "\(text) is a time: \(message ?? "")")
            _ = try await session.runCommand("allow-sleep")
        }
        // "1:30" is an hour and a half, and ".5h" is half an hour.
        _ = try await session.runCommand("keep-awake", arguments: ["for": "1:30"])
        let ninety = try await session.callTool("awake_status", arguments: [:]).text
        XCTAssertTrue(ninety.contains("1h 30m left") || ninety.contains("1h 29m left"), ninety)
        _ = try await session.runCommand("allow-sleep")
        _ = try await session.runCommand("keep-awake", arguments: ["for": ".5h"])
        let half = try await session.callTool("awake_status", arguments: [:]).text
        XCTAssertTrue(half.contains("30m left"), half)
        _ = try await session.runCommand("allow-sleep")
    }

    func testAnUntilHourIsTheNextOneComing() async throws {
        let host = Host(self)
        let session = try await host.session("StayAwake")
        let before = Date()
        _ = try await session.runCommand("keep-awake", arguments: ["for": "until 5"])
        let calendar = Calendar.current
        let fiveAM = try XCTUnwrap(calendar.nextDate(after: before, matching: DateComponents(hour: 5, minute: 0, second: 0), matchingPolicy: .nextTime))
        let fivePM = try XCTUnwrap(calendar.nextDate(after: before, matching: DateComponents(hour: 17, minute: 0, second: 0), matchingPolicy: .nextTime))
        let status = try await session.callTool("awake_status", arguments: [:]).text
        XCTAssertTrue(status.contains("Until \(min(fiveAM, fivePM).formatted(date: .omitted, time: .shortened))"), "a deadline is the next five o'clock: \(status)")
        _ = try await session.runCommand("allow-sleep")
    }
}
