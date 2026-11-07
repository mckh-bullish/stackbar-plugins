import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class UpNextTests: XCTestCase {
    func testFindsTheMeetingAndItsLink() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "a", title: "Planning", start: now.addingTimeInterval(600), end: now.addingTimeInterval(2400), notes: "Join Zoom Meeting\nhttps://acme.zoom.us/j/987654321?pwd=xyz.", calendar: "Work", participation: .accepted, attendees: 3),
            CalendarEvent(id: "b", title: "Declined thing", start: now.addingTimeInterval(300), end: now.addingTimeInterval(900), location: "https://meet.google.com/aaa-bbbb-ccc", calendar: "Work", participation: .declined),
        ]))
        let supervisor = try await host.start("UpNext")
        let menu = await supervisor.views[.menuBar]?.plainText ?? ""
        XCTAssertTrue(menu.contains("Planning") && !menu.contains("Declined thing"), "a declined meeting is skipped even when it's sooner: \(menu)")
        let next = await supervisor.callTool("next_meeting")
        XCTAssertTrue(next.text.contains("https://acme.zoom.us/j/987654321?pwd=xyz"), "trailing punctuation is trimmed: \(next.text)")
        let rows = await supervisor.views[.panel]?.rows.map(\.title) ?? []
        XCTAssertEqual(rows.first, "Planning", "the next meeting is the first row, so Return joins it: \(rows)")
        XCTAssertFalse(rows.contains("Declined thing"))
        await supervisor.stop()
    }

    func testAReminderHasAJoinButton() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "soon", title: "Sync", start: now.addingTimeInterval(90), end: now.addingTimeInterval(1800), location: "https://meet.google.com/abc-defg-hij", calendar: "Work", participation: .accepted, attendees: 3),
        ]))
        let supervisor = try await host.start("UpNext")
        let posted = await waitUntil(5) { !host.notifications.all.isEmpty }
        XCTAssertTrue(posted, "a meeting in 90 seconds is reminded about")
        XCTAssertEqual(host.notifications.all.first?.actions.map(\.url), ["https://meet.google.com/abc-defg-hij", ""])
        XCTAssertEqual(host.notifications.all.first?.actions.last, NotificationAction("Snooze 5 Min", command: "snooze", arguments: ["event": "soon"]))
        await supervisor.stop()
    }

    func testQuickAddAndSnooze() async throws {
        let now = Date()
        let system = SimulatedSystem(events: [
            CalendarEvent(id: "soon", title: "Sync", start: now.addingTimeInterval(90), end: now.addingTimeInterval(1800), calendar: "Work", participation: .accepted, attendees: 3),
        ])
        let host = Host(self, system: system)
        let session = try await host.session("UpNext")
        guard case .message(let added) = try await session.runCommand("add-event", arguments: ["text": "Lunch with Sam tomorrow 1pm for 45m"]) else { return XCTFail("add-event adds") }
        XCTAssertEqual(added?.hasPrefix("Added Lunch with Sam, "), true, added ?? "")
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
        let events = try await system.calendarEvents(from: Calendar.current.startOfDay(for: tomorrow), to: Calendar.current.startOfDay(for: tomorrow).addingTimeInterval(86400))
        let lunch = try XCTUnwrap(events.first { $0.title == "Lunch with Sam" })
        XCTAssertEqual(Calendar.current.component(.hour, from: lunch.start), 13)
        XCTAssertEqual(lunch.end.timeIntervalSince(lunch.start), 45 * 60)

        guard case .message = try await session.runCommand("add-event", arguments: ["text": "Offsite fri"]) else { return XCTFail("an all-day event") }
        let week = try await system.calendarEvents(from: now, to: now.addingTimeInterval(8 * 86400))
        XCTAssertEqual(week.first { $0.title == "Offsite" }?.isAllDay, true)
        guard case .failure = try await session.runCommand("add-event", arguments: ["text": "tomorrow 3pm"]) else { return XCTFail("a title is needed") }

        guard case .message(let snoozed) = try await session.runCommand("snooze", arguments: ["event": "soon"]) else { return XCTFail("snooze answers") }
        XCTAssertEqual(snoozed, "Reminding you about Sync in 5 min")
    }

    func testDialsInAndCoversTheScreen() async throws {
        let now = Date()
        let notes = "Join Zoom Meeting\nhttps://acme.zoom.us/j/123456789\n\nOne tap mobile\n+16465588656,,123456789# US (New York)"
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "z", title: "Board call", start: now.addingTimeInterval(30), end: now.addingTimeInterval(1800), notes: notes, calendar: "Work", participation: .accepted, attendees: 5),
        ]))
        let supervisor = try await host.start("UpNext")
        let dial = "tel:+16465588656,,123456789%23"

        // The meeting's row can call in: one of its actions opens the number.
        let rows = await supervisor.views[.panel]?.rows ?? []
        let row = try XCTUnwrap(rows.first { $0.title == "Board call" })
        for action in row.actions { await supervisor.press(action.id) }
        XCTAssertTrue(host.opened.all.contains { $0.url == dial }, "\(host.opened.all)")
        XCTAssertTrue(host.alerts.all.isEmpty, "the full-screen alert is off by default")

        // The setting has no key, so its title is the only way to find it.
        let toggle = await supervisor.views[.settings]?.toggles.first { $0.title.contains("Cover the screen") }
        await supervisor.press(try XCTUnwrap(toggle, "no full-screen toggle in settings").action, value: .bool(true))
        let before = await supervisor.settledCount
        await supervisor.refresh()
        _ = await waitUntil { await supervisor.settledCount > before }
        let shown = await waitUntil(5) { !host.alerts.all.isEmpty }
        XCTAssertTrue(shown, "a meeting starting within a minute covers the screen")
        XCTAssertEqual(host.alerts.all.first?.title, "Board call")
        XCTAssertEqual(host.alerts.all.first?.actions.map(\.url), ["zoommtg://acme.zoom.us/join?action=join&confno=123456789", dial], "join in the Zoom app, then call in")
        await supervisor.stop()
    }

    func testCountsMeetingHoursOnceAndChartsTheWeek() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "a", title: "Planning", start: now.addingTimeInterval(600), end: now.addingTimeInterval(4200), calendar: "Work", participation: .accepted, attendees: 3),
            CalendarEvent(id: "b", title: "Overlapping", start: now.addingTimeInterval(2400), end: now.addingTimeInterval(6000), calendar: "Home", participation: .accepted, attendees: 2),
        ]))
        let supervisor = try await host.start("UpNext")
        // 10 min → 100 min overlapping 40 → 100 min: 1.5 hours once, not 2.
        let today = Calendar.current.isDate(now.addingTimeInterval(6000), inSameDayAs: now)
        let rendered = await supervisor.views[.window]
        let window = try XCTUnwrap(rendered)
        let week = try XCTUnwrap(window.charts.first { $0.kind == .bar }, "the window charts the week's meeting load")
        XCTAssertEqual(week.values.count, 7)
        if today {
            XCTAssertEqual(week.values.first, 1.5)
            let header = await supervisor.views[.panel]?.tree.contains { node in
                if case .text(let text, _, _) = node { return text.contains("· 1h 30m · Free until ") }
                return false
            }
            XCTAssertEqual(header, true, "the panel's header says today's hours, and how long you're free")
            let clashes = await supervisor.views[.panel]?.tree.filter { node in
                if case .row(let row) = node { return row.accessories.contains(.badge("Clashes", role: .warning)) }
                return false
            }.count
            XCTAssertEqual(clashes, 2, "both overlapping meetings are flagged")
            let byCalendar = window.charts.first { $0.kind == .donut }
            XCTAssertEqual(byCalendar?.values.sorted(), [1, 1], "today split by calendar")
        }
        await supervisor.stop()
    }

    func testAPlainHttpLinkBeforeAnHttpsOneIsFound() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "a", title: "Planning", start: now.addingTimeInterval(600), end: now.addingTimeInterval(2400), notes: "Join http://acme.zoom.us/j/987654321 (agenda: https://example.com/agenda)", calendar: "Work", participation: .accepted, attendees: 3),
        ]))
        let supervisor = try await host.start("UpNext")
        let next = await supervisor.callTool("next_meeting")
        XCTAssertTrue(next.text.contains("http://acme.zoom.us/j/987654321"), next.text)
        await supervisor.stop()
    }
}
