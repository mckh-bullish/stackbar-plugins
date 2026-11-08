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

        guard case .message(let asked) = await supervisor.runCommand("stop-all", arguments: [:], source: .palette) else { return XCTFail("asks") }
        XCTAssertTrue(asked?.contains("again") == true, "stopping several timers takes a second run: \(asked ?? "")")
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

    func testFillerWordsStayOutOfTheName() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Timers")
        for text in ["tea for 3 min", "in 10 minutes pasta", "at 5 pm call"] {
            guard case .message = await supervisor.runCommand("start", arguments: ["for": text], source: .palette) else { return XCTFail("\(text) starts") }
        }
        let session = try await host.session("Timers")
        let opened = try await session.openView("list")
        XCTAssertEqual(Set(opened.root?.rows.map(\.title) ?? []), ["tea", "pasta", "call"])
        await session.stop()

        // "lunch at 12" is an alarm for the next noon, not a 12-minute timer.
        let before = Date()
        let lunch = try await Host(self).start("Timers")
        guard case .message = await lunch.runCommand("start", arguments: ["for": "lunch at 12"], source: .palette) else { return XCTFail("lunch at 12 starts") }
        _ = await waitUntil { await self.lengths(lunch).count == 1 }
        let noon = try XCTUnwrap(Calendar.current.nextDate(after: before, matching: DateComponents(hour: 12, minute: 0, second: 0), matchingPolicy: .nextTime))
        let alarm = await lengths(lunch).first ?? 0
        XCTAssertEqual(Double(alarm), noon.timeIntervalSince(before), accuracy: 3, "the alarm is the next noon: \(alarm)")
        await lunch.stop()

        // The rest of the times: "noon", and "5.30pm" with its point.
        for text in ["noon lunch", "5.30pm call"] {
            guard case .message = await supervisor.runCommand("start", arguments: ["for": text], source: .palette) else { return XCTFail("\(text) starts") }
        }
        await supervisor.stop()
    }

    func testADoneTimerOffersAgain() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Timers")
        _ = await supervisor.runCommand("start", arguments: ["for": "2s tea"], source: .palette)
        _ = await waitUntil(10) { host.notifications.all.contains { $0.title == "tea is done" } }
        let done = try XCTUnwrap(host.notifications.all.first { $0.title == "tea is done" })
        XCTAssertEqual(done.actions.compactMap(\.command), ["start", "start"])
        XCTAssertEqual(done.actions.first?.arguments?["for"], "2s tea")
        XCTAssertEqual(done.actions.last?.arguments?["for"], "5m tea")
        await supervisor.stop()
    }

    /// The seconds left on each running timer in the panel.
    private func timeLeft(_ supervisor: PluginSupervisor) async -> [Double] {
        let panel = await supervisor.views[.panel]
        return (panel?.tree ?? []).compactMap { node -> Double? in
            if case .timer(let range, _) = node { return range.end.timeIntervalSinceNow }
            return nil
        }
    }

    func testPauseKeepsTheTimeLeft() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Timers")
        _ = await supervisor.runCommand("start", arguments: ["for": "10m tea"], source: .palette)
        _ = await waitUntil { await self.lengths(supervisor).count == 1 }
        let pause = await supervisor.views[.panel]?.tree.lazy.compactMap { node -> ActionID? in
            if case .tappable(_, let action, _) = node, action.rawValue.hasPrefix("button/pause-") { return action }
            return nil
        }.first
        let action = try XCTUnwrap(pause, "no pause button")

        await supervisor.press(action)
        try await Task.sleep(for: .milliseconds(1200))
        await supervisor.refresh()
        let panel = await supervisor.views[.panel].map { TreeTextRenderer.render($0) } ?? ""
        XCTAssertTrue(panel.contains("Resume"), panel)
        let counting = await timeLeft(supervisor)
        XCTAssertTrue(counting.isEmpty, "a paused timer is not counting down: \(counting)")

        await supervisor.press(action)
        let left = await timeLeft(supervisor)
        XCTAssertEqual(left.count, 1, "resumed")
        XCTAssertTrue((597...600).contains(left.first ?? 0), "the time left is kept: \(left)")
        await supervisor.stop()
    }

    func testSeveralTimersEndingTogetherComeAsOneNotification() async throws {
        let host = Host(self)
        let began = Date().addingTimeInterval(-120).timeIntervalSinceReferenceDate
        let ended = Date().addingTimeInterval(-60).timeIntervalSinceReferenceDate
        try await host.services.storage.set("timers", """
        [{"id":"a","name":"tea","start":\(began),"end":\(ended)},{"id":"b","name":"eggs","start":\(began),"end":\(ended + 1)}]
        """, for: "io.navbytes.stackbar.plugins.timers")
        let supervisor = try await host.start("Timers")
        _ = await waitUntil { !host.notifications.all.isEmpty }
        XCTAssertEqual(host.notifications.all.map(\.title), ["2 timers are done"])
        XCTAssertEqual(host.notifications.all.first?.body, "tea, eggs")
        await supervisor.stop()
    }

    func testNoonAndMidnightDoNotStealATimer() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Timers")
        for text in ["Midnight snack 10m", "Noon walk 20m"] {
            guard case .message = await supervisor.runCommand("start", arguments: ["for": text], source: .palette) else { return XCTFail("\(text) starts") }
        }
        _ = await waitUntil { await self.lengths(supervisor).count == 2 }
        let durations = await lengths(supervisor)
        XCTAssertEqual(durations, [600, 1200], "ten minutes, then twenty")
        let session = try await host.session("Timers")
        let opened = try await session.openView("list")
        XCTAssertEqual(Set(opened.root?.rows.map(\.title) ?? []), ["Midnight snack", "Noon walk"])
        await session.stop()
        await supervisor.stop()
    }

    func testABareHourAfterAtIsTheNextOneAhead() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Timers")
        let before = Date()
        let started = await supervisor.runCommand("start", arguments: ["for": "tea at 3"], source: .palette)
        let threePM = try XCTUnwrap(Calendar.current.nextDate(after: before, matching: DateComponents(hour: 15, minute: 0, second: 0), matchingPolicy: .nextTime))
        XCTAssertEqual(started, .message("tea: ends at \(threePM.formatted(date: .omitted, time: .shortened))"), "at 3 is 3 pm, today or tomorrow")
        await supervisor.stop()
    }
}
