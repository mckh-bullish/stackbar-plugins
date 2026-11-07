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
}
