import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol
@testable import Plugin_UpNext

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
        // Join runs join-event, so the join is counted and auto-join won't open it again.
        XCTAssertEqual(host.notifications.all.first?.actions.first, NotificationAction("Join on Google Meet", command: "join-event", arguments: ["event": "soon"]))
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
        let lunch = try await addFromView("Lunch with Sam tomorrow 1pm for 45m", session, system)
        assertAdded(lunch, "Lunch with Sam", at(13, 0, day: 1, from: now), minutes: 45, "Lunch with Sam tomorrow 1pm for 45m")

        let offsite = try await addFromView("Offsite fri", session, system)
        XCTAssertEqual(offsite?.title, "Offsite")
        XCTAssertEqual(offsite?.isAllDay, true, "a day without a time is all day")
        let untitled = try await addFromView("tomorrow 3pm", session, system)
        XCTAssertNil(untitled, "a time without a title adds nothing")

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

        // The meeting's row can call in: its Call in action opens the number.
        let rows = await supervisor.views[.panel]?.rows ?? []
        let row = try XCTUnwrap(rows.first { $0.title == "Board call" })
        let callIn = try XCTUnwrap(row.actions.first { $0.title.hasPrefix("Call in") })
        await supervisor.press(callIn.id)
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
        XCTAssertEqual(host.alerts.all.first?.actions.first, NotificationAction("Join on Zoom", command: "join-event", arguments: ["event": "z"]))
        XCTAssertEqual(host.alerts.all.first?.actions.last?.url, dial, "then call in")
        // The alert's Join runs join-event, which opens the Zoom app.
        _ = await supervisor.runCommand("join-event", arguments: ["event": "z"], source: .palette)
        XCTAssertTrue(host.opened.all.contains { $0.url == "zoommtg://acme.zoom.us/join?action=join&confno=123456789" }, "\(host.opened.all)")
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

    // MARK: Add event

    func testAddEventShowsEachCalendarDefaultFirstAndSavesToThePickedOne() async throws {
        let now = Date()
        let system = SimulatedSystem(events: [])
        let session = try await Host(self, system: system).session("UpNext")
        let opened = try await session.openView("add-event", query: CommandQuery(text: "Lunch tomorrow 1pm"))
        XCTAssertEqual(opened.root?.rows.map(\.key), ["work", "home"], "one row per writable calendar, the default first")
        XCTAssertTrue(opened.root?.rows.first?.title.contains("· Work") == true, "each row previews the event on its calendar")
        let home = try XCTUnwrap(opened.root?.rows.last?.actions.first?.id)
        try await session.event(home)
        await session.closeView(opened.session)
        let saved = try await system.calendarEvents(from: now, to: now.addingTimeInterval(3 * 86_400)).first { $0.title == "Lunch" }
        XCTAssertEqual(saved?.calendar, "Home", "the row's calendar gets the event")
    }

    func testTheAddEventViewReadsTheTextFromALinkAndSavesNothingYet() async throws {
        let system = SimulatedSystem(events: [])
        let session = try await Host(self, system: system).session("UpNext")
        // An old link passes its text as an argument, not as typed text.
        let opened = try await session.openView("add-event", query: CommandQuery(arguments: ["text": "Dentist tomorrow 9am"]))
        XCTAssertEqual(opened.root?.rows.first?.title.hasPrefix("Dentist — Tomorrow "), true, "the link's text is previewed")
        let from = Date().addingTimeInterval(-86_400)
        let to = Date().addingTimeInterval(60 * 86_400)
        let saved = try await system.calendarEvents(from: from, to: to)
        XCTAssertTrue(saved.isEmpty, "opening the view saves nothing until a row is chosen")
        await session.closeView(opened.session)
    }

    func testTheAddViewSaysWhenThereIsNoCalendar() async throws {
        let system = SimulatedSystem(events: [])
        system.simulatedCalendars = []
        let session = try await Host(self, system: system).session("UpNext")
        let opened = try await session.openView("add-event", query: CommandQuery(text: "Lunch tomorrow 1pm"))
        XCTAssertEqual(opened.root?.rows.count, 0, "no row without a calendar to add to")
        XCTAssertEqual(emptyTitles(opened.root), ["No calendar to add to"])
        await session.closeView(opened.session)
    }

    func testASecondAddDoesNotRepeatTheEvent() async throws {
        let system = SimulatedSystem(events: [])
        let session = try await Host(self, system: system).session("UpNext")
        let opened = try await session.openView("add-event", query: CommandQuery(text: "Lunch tomorrow 1pm"))
        let add = try XCTUnwrap(opened.root?.rows.first?.actions.first?.id)
        try await session.event(add)
        let shown = await session.commandView(opened.session)
        XCTAssertEqual(emptyTitles(shown), ["Added Lunch to Work"], "the view says what was added")
        do {
            try await session.event(add)
            XCTFail("the row is gone once it has added the event")
        } catch {}
        let from = Date().addingTimeInterval(-86_400)
        let to = Date().addingTimeInterval(60 * 86_400)
        let saved = try await system.calendarEvents(from: from, to: to).filter { $0.title == "Lunch" }
        XCTAssertEqual(saved.count, 1, "one event, however often Return is pressed")
        await session.closeView(opened.session)
    }

    // MARK: Auto-join

    func testAutoJoinOpensTheMeetingYoureInInItsApp() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "soon", title: "Sync", start: now.addingTimeInterval(10), end: now.addingTimeInterval(1800), location: "https://acme.zoom.us/j/111222333", calendar: "Work", participation: .accepted, attendees: 3),
        ]))
        let supervisor = try await host.start("UpNext")
        try await turnOn(supervisor, "Open the call when it starts")
        await reread(supervisor)
        let joined = await waitUntil(5) { !host.opened.all.isEmpty }
        XCTAssertTrue(joined, "the meeting starting in ten seconds is joined")
        XCTAssertEqual(host.opened.all.first?.url, "zoommtg://acme.zoom.us/join?action=join&confno=111222333", "in the Zoom app, as the Open Zoom setting says")
        await supervisor.stop()
    }

    func testAutoJoinSkipsATentativeOrPendingMeeting() async throws {
        for participation in [CalendarEvent.Participation.tentative, .pending] {
            let now = Date()
            let host = Host(self, system: SimulatedSystem(events: [
                CalendarEvent(id: "maybe", title: "Maybe", start: now.addingTimeInterval(10), end: now.addingTimeInterval(1800), location: "https://acme.zoom.us/j/111", calendar: "Work", participation: participation, attendees: 3),
            ]))
            let supervisor = try await host.start("UpNext")
            try await turnOn(supervisor, "Open the call when it starts")
            await reread(supervisor)
            XCTAssertTrue(host.opened.all.isEmpty, "a \(participation) meeting is never joined for you")
            await supervisor.stop()
        }
    }

    func testAManualJoinHoldsBackAutoJoinForAMinute() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "later", title: "Later", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200), location: "https://acme.zoom.us/j/222", calendar: "Work", participation: .accepted, attendees: 3),
            CalendarEvent(id: "soon", title: "Soon", start: now.addingTimeInterval(10), end: now.addingTimeInterval(1800), location: "https://acme.zoom.us/j/333", calendar: "Work", participation: .accepted, attendees: 3),
        ]))
        let supervisor = try await host.start("UpNext")
        try await turnOn(supervisor, "Open the call when it starts")
        // Join the later one by hand; the next one starts in ten seconds.
        try await pressAction("Join on Zoom", onRow: "Later", supervisor)
        await reread(supervisor)
        XCTAssertEqual(host.opened.all.map(\.url), ["zoommtg://acme.zoom.us/join?action=join&confno=222"], "Soon isn't joined a moment after a join")
        await supervisor.stop()
    }

    func testAJoinFromAReminderCountsAsJoined() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "soon", title: "Sync", start: now.addingTimeInterval(10), end: now.addingTimeInterval(1800), location: "https://acme.zoom.us/j/111222333", calendar: "Work", participation: .accepted, attendees: 3),
        ]))
        let supervisor = try await host.start("UpNext")
        // A reminder's Join button runs join-event.
        guard case .message = await supervisor.runCommand("join-event", arguments: ["event": "soon"], source: .palette) else {
            return XCTFail("join-event joins the meeting")
        }
        XCTAssertEqual(host.opened.all.map(\.url), ["zoommtg://acme.zoom.us/join?action=join&confno=111222333"])
        try await turnOn(supervisor, "Open the call when it starts")
        await reread(supervisor)
        XCTAssertEqual(host.opened.all.count, 1, "auto-join doesn't open a call that was already joined")
        await supervisor.stop()
    }

    func testARestartDoesNotOpenACallAgain() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "soon", title: "Sync", start: now.addingTimeInterval(10), end: now.addingTimeInterval(1800), location: "https://acme.zoom.us/j/111222333", calendar: "Work", participation: .accepted, attendees: 3),
        ]))
        let first = try await host.start("UpNext")
        _ = await first.runCommand("join-event", arguments: ["event": "soon"], source: .palette)
        try await turnOn(first, "Open the call when it starts")
        await first.stop()
        // A new process reads the saved joins, so auto-join leaves that call alone.
        let second = try await host.start("UpNext")
        await reread(second)
        XCTAssertEqual(host.opened.all.count, 1, "the call joined before the restart isn't opened again")
        await second.stop()
    }

    func testJoinEventNeedsAKnownMeetingWithALinkToOpenAnything() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "soon", title: "Sync", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1800), location: "https://acme.zoom.us/j/111222333", calendar: "Work", participation: .accepted, attendees: 3),
            CalendarEvent(id: "plain", title: "Plain", start: now.addingTimeInterval(900), end: now.addingTimeInterval(2400), calendar: "Work", participation: .accepted, attendees: 1),
        ]))
        let session = try await host.session("UpNext")
        guard case .failure(let missing) = try await session.runCommand("join-event") else { return XCTFail("a join without a meeting fails") }
        XCTAssertEqual(missing, "That meeting is no longer on your calendar")
        guard case .failure(let unknown) = try await session.runCommand("join-event", arguments: ["event": "gone"]) else { return XCTFail("an unknown meeting fails") }
        XCTAssertEqual(unknown, "That meeting is no longer on your calendar")
        guard case .failure(let nolink) = try await session.runCommand("join-event", arguments: ["event": "plain"]) else { return XCTFail("a meeting without a link fails") }
        XCTAssertEqual(nolink, "That meeting has no call link")
        XCTAssertTrue(host.opened.all.isEmpty, "none of them opens anything")
    }

    func testJoinNextOpensAWebLinkAndNothingElse() async throws {
        let now = Date()
        let web = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "agenda", title: "Review", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1800), url: "https://docs.example.com/agenda", calendar: "Work", participation: .accepted, attendees: 3),
        ]))
        let webSession = try await web.session("UpNext")
        guard case .message = try await webSession.runCommand("join-next") else { return XCTFail("a web link is opened") }
        XCTAssertEqual(web.opened.all.map(\.url), ["https://docs.example.com/agenda"])

        let other = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "share", title: "Share", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1800), url: "ftp://files.example.com/x", calendar: "Work", participation: .accepted, attendees: 3),
        ]))
        let otherSession = try await other.session("UpNext")
        guard case .failure = try await otherSession.runCommand("join-next") else { return XCTFail("only a web link is opened") }
        XCTAssertTrue(other.opened.all.isEmpty)
    }

    // MARK: Alerts, reminders and links

    func testMeetingsStartingTogetherShareOneFullScreenAlert() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "a", title: "Board call", start: now.addingTimeInterval(20), end: now.addingTimeInterval(1800), location: "https://acme.zoom.us/j/444", calendar: "Work", participation: .accepted, attendees: 5),
            CalendarEvent(id: "b", title: "Design review", start: now.addingTimeInterval(40), end: now.addingTimeInterval(1800), location: "https://meet.google.com/abc-defg-hij", calendar: "Work", participation: .accepted, attendees: 4),
        ]))
        let supervisor = try await host.start("UpNext")
        try await turnOn(supervisor, "Cover the screen")
        await reread(supervisor)
        let shown = await waitUntil(5) { !host.alerts.all.isEmpty }
        XCTAssertTrue(shown, "two meetings starting within a minute cover the screen")
        XCTAssertEqual(host.alerts.all.count, 1, "one alert for both: the host allows one a minute")
        XCTAssertEqual(host.alerts.all.first?.title, "2 meetings starting")
        let body = host.alerts.all.first?.body ?? ""
        XCTAssertTrue(body.contains("Board call") && body.contains("Design review"), "the body lists each meeting: \(body)")
        XCTAssertEqual(host.alerts.all.first?.actions, [
            NotificationAction("Join Board call", command: "join-event", arguments: ["event": "a"]),
            NotificationAction("Join Design review", command: "join-event", arguments: ["event": "b"]),
        ], "a Join for each, named by its meeting")
        await supervisor.stop()
    }

    func testLaunchingJustBeforeAStartGivesOneNudge() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "now", title: "Stand-in", start: now.addingTimeInterval(15), end: now.addingTimeInterval(1800), location: "https://acme.zoom.us/j/999", calendar: "Work", participation: .accepted, attendees: 3),
        ]))
        let supervisor = try await host.start("UpNext")
        let posted = await waitUntil(5) { !host.notifications.all.isEmpty }
        XCTAssertTrue(posted)
        await reread(supervisor)
        XCTAssertEqual(host.notifications.all.map(\.title), ["Stand-in is starting"], "the nudge replaces the 'in 1 min' reminder when both are due")
        await supervisor.stop()
    }

    func testWrappedAndSchemeLessLinksJoin() async throws {
        let now = Date()
        let links: [(title: String, notes: String, confno: String)] = [
            ("Safe Links", "https://nam04.safelinks.protection.outlook.com/?url=https%3A%2F%2Facme.zoom.us%2Fj%2F111%3Fpwd%3Dabc&data=05%7C01&reserved=0", "111"),
            ("urldefense v3", "https://urldefense.com/v3/__https://acme.zoom.us/j/222__;!!ABC!xyz$", "222"),
            ("urldefense v2", "https://urldefense.proofpoint.com/v2/url?u=https-3A__acme.zoom.us_j_333&d=DwMFAg&c=abc", "333"),
            ("Google redirect", "https://www.google.com/url?q=https%3A%2F%2Facme.zoom.us%2Fj%2F444&sa=D", "444"),
            ("Bare Zoom", "Dial in: acme.zoom.us/j/555", "555"),
        ]
        var events = links.enumerated().map { index, link in
            CalendarEvent(id: link.title, title: link.title, start: now.addingTimeInterval(TimeInterval(3600 * (index + 1))), end: now.addingTimeInterval(TimeInterval(3600 * (index + 1) + 1800)), notes: link.notes, calendar: "Work", participation: .accepted, attendees: 3)
        }
        events.append(CalendarEvent(id: "meet", title: "Bare Meet", start: now.addingTimeInterval(3600 * 9), end: now.addingTimeInterval(3600 * 9 + 1800), location: "meet.google.com/abc-defg-hij", calendar: "Work", participation: .accepted, attendees: 3))
        let host = Host(self, system: SimulatedSystem(events: events))
        let supervisor = try await host.start("UpNext")
        for link in links {
            try await pressAction("Join on Zoom", onRow: link.title, supervisor)
            XCTAssertTrue(host.opened.all.contains { $0.url.contains("confno=\(link.confno)") }, "\(link.title) joins its meeting: \(host.opened.all)")
        }
        try await pressAction("Join on Google Meet", onRow: "Bare Meet", supervisor)
        XCTAssertTrue(host.opened.all.contains { $0.url == "https://meet.google.com/abc-defg-hij" }, "\(host.opened.all)")
        await supervisor.stop()
    }

    func testAHiddenMeetingLeavesTheCountdownUntilShownAgain() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "near", title: "Near", start: now.addingTimeInterval(20 * 60), end: now.addingTimeInterval(50 * 60), location: "https://acme.zoom.us/j/555", calendar: "Work", participation: .accepted, attendees: 3),
            CalendarEvent(id: "later", title: "Later", start: now.addingTimeInterval(50 * 60), end: now.addingTimeInterval(80 * 60), calendar: "Work", participation: .accepted, attendees: 3),
        ]))
        let supervisor = try await host.start("UpNext")
        let before = await supervisor.views[.menuBar]?.plainText ?? ""
        XCTAssertTrue(before.contains("Near"), before)

        try await pressAction("Hide from Countdown", onRow: "Near", supervisor)
        let hidden = await supervisor.views[.menuBar]?.plainText ?? ""
        XCTAssertTrue(hidden.contains("Later") && !hidden.contains("Near"), "the countdown moves on: \(hidden)")
        let rows = await supervisor.views[.panel]?.rows.map(\.title) ?? []
        XCTAssertTrue(rows.contains("Near"), "the meeting is still in the list")

        try await pressAction("Show Again", onRow: "Near", supervisor)
        let shown = await supervisor.views[.menuBar]?.plainText ?? ""
        XCTAssertTrue(shown.contains("Near"), "shown again: \(shown)")
        await supervisor.stop()
    }

    func testTheWidgetJoinsTheFocusedMeeting() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "soon", title: "Sync", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1800), location: "https://acme.zoom.us/j/888", calendar: "Work", participation: .accepted, attendees: 3),
        ]))
        let supervisor = try await host.start("UpNext")
        let widgetTree = await supervisor.views[.widget]
        let widget = try XCTUnwrap(widgetTree)
        XCTAssertTrue(widget.actions.contains(ActionID("button/join-widget")), "the widget has a Join button")
        await supervisor.press(ActionID("button/join-widget"))
        let joined = await waitUntil(5) { !host.opened.all.isEmpty }
        XCTAssertTrue(joined)
        XCTAssertEqual(host.opened.all.first?.url, "zoommtg://acme.zoom.us/join?action=join&confno=888")
        await supervisor.stop()
    }

    func testAMeetingPastMidnightIsListedOnce() async throws {
        let now = Date()
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now) ?? now)
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "late", title: "Late call", start: midnight.addingTimeInterval(-30 * 60), end: midnight.addingTimeInterval(30 * 60), location: "https://acme.zoom.us/j/777", calendar: "Work", participation: .accepted, attendees: 3),
        ]))
        let supervisor = try await host.start("UpNext")
        let rows = await supervisor.views[.panel]?.rows ?? []
        XCTAssertEqual(rows.filter { $0.key == "late" }.count, 1, "under Today only: Tomorrow lists what starts that day")
        await supervisor.stop()
    }

    // MARK: Today's meetings, snooze, commands and tools

    func testTodaysMeetingsSortTimedFirstAndSearchEveryField() async throws {
        let now = Date()
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "allday", title: "Offsite", start: dayStart, end: calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart, isAllDay: true, calendar: "Work", participation: .none),
            CalendarEvent(id: "planning", title: "Planning", start: now.addingTimeInterval(30 * 60), end: now.addingTimeInterval(60 * 60), location: "Room 4", notes: "https://acme.zoom.us/j/666", calendar: "Work", participation: .accepted, attendees: 3),
            CalendarEvent(id: "standup", title: "Standup", start: now.addingTimeInterval(5 * 60), end: now.addingTimeInterval(20 * 60), calendar: "Home", participation: .accepted, attendees: 2),
            CalendarEvent(id: "cafe", title: "Café review", start: now.addingTimeInterval(15 * 60), end: now.addingTimeInterval(25 * 60), calendar: "Team", participation: .accepted, attendees: 2),
        ]))
        let session = try await host.session("UpNext")
        func titles(_ query: String) async throws -> [String] {
            let opened = try await session.openView("agenda", query: CommandQuery(text: query))
            await session.closeView(opened.session)
            return opened.root?.rows.map(\.title) ?? []
        }
        let all = try await titles("")
        let room = try await titles("room")
        let home = try await titles("home")
        let zoom = try await titles("zoom")
        let cafe = try await titles("CAFE")
        let accented = try await titles("café")
        XCTAssertEqual(all, ["Standup", "Café review", "Planning", "Offsite"], "timed meetings first, by start, then all-day")
        XCTAssertEqual(room, ["Planning"], "matches the place")
        XCTAssertEqual(home, ["Standup"], "matches the calendar")
        XCTAssertEqual(zoom, ["Planning"], "matches the call service")
        XCTAssertEqual(cafe, ["Café review"], "ignores case and accents")
        XCTAssertEqual(accented, ["Café review"], "and accents in the query")
    }

    func testTodaysMeetingsReadsTheCalendarAtMostEvery30Seconds() async throws {
        let now = Date()
        let system = SimulatedSystem(events: [
            CalendarEvent(id: "soon", title: "Sync", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1800), calendar: "Work", participation: .accepted, attendees: 3),
        ])
        let session = try await Host(self, system: system).session("UpNext")
        // A meeting added after the launch read, that the search would find: typing mustn't read the calendar again.
        system.simulate(events: [
            CalendarEvent(id: "soon", title: "Sync", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1800), calendar: "Work", participation: .accepted, attendees: 3),
            CalendarEvent(id: "late", title: "Late add", start: now.addingTimeInterval(90), end: now.addingTimeInterval(1800), calendar: "Work", participation: .accepted, attendees: 3),
        ])
        let opened = try await session.openView("agenda", query: CommandQuery(text: ""))
        let first = try await session.updateView(opened.session, query: CommandQuery(text: "l"))
        XCTAssertEqual(first?.rows.map(\.key) ?? [], [], "the first keystroke doesn't read the calendar again")
        let second = try await session.updateView(opened.session, query: CommandQuery(text: "la"))
        XCTAssertEqual(second?.rows.map(\.key) ?? [], [], "nor does the next one, within 30 seconds of the read")
        await session.closeView(opened.session)
    }

    func testSnoozingAMeetingThatIsGoneChangesNothing() async throws {
        let host = Host(self, system: SimulatedSystem(events: []))
        let session = try await host.session("UpNext")
        guard case .failure(let message) = try await session.runCommand("snooze", arguments: ["event": "gone"]) else {
            return XCTFail("a meeting that's gone can't be snoozed")
        }
        XCTAssertEqual(message, "That meeting is no longer on your calendar")
    }

    func testTheJoinHotkeyJoinsTheNextMeeting() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "soon", title: "Sync", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1800), location: "https://acme.zoom.us/j/999", calendar: "Work", participation: .accepted, attendees: 3),
        ]))
        let session = try await host.session("UpNext")
        let manifest = await session.manifest
        XCTAssertEqual(manifest?.hotkey, "ctrl+option+j")
        XCTAssertEqual(manifest?.hotkeyCommand, "join-next", "the hotkey runs join-next, with no arguments")
        guard case .message = try await session.runCommand("join-next") else { return XCTFail("join-next joins") }
        XCTAssertEqual(host.opened.all.first?.url, "zoommtg://acme.zoom.us/join?action=join&confno=999")
    }

    func testAgentToolsWaitForPermission() async throws {
        let session = try await Host(self, system: SimulatedSystem(events: [])).session("UpNext")
        let tools = await session.tools()
        XCTAssertEqual(Set(tools.map(\.name)), ["next_meeting", "agenda", "join_next"])
        XCTAssertTrue(tools.allSatisfy(\.optIn), "agents only get them once the user allows it")
    }

    // MARK: Parsing, at a fixed moment

    /// The calendar and the moments the quick-add tests use, so they parse the
    /// same on every day. 9 November 2026 is a Monday.
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    /// November 2026 at the time, in UTC.
    private func moment(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)) ?? Date(timeIntervalSince1970: 0)
    }

    /// Parses `text` as the add-event view does, at `now`.
    @MainActor private func parse(_ text: String, now: Date) throws -> CalendarEventDraft {
        try XCTUnwrap(UpNext.quickAdd(text, now: now, calendar: utc), "no event from \"\(text)\"")
    }

    @MainActor func testAnHourWithoutAMeridiemTakesTheWayTheDayIsGoing() async throws {
        let cases: [(text: String, now: Date, start: Date)] = [
            ("Call at 1", moment(9, 8), moment(9, 13)),
            ("Call at 3", moment(9, 8), moment(9, 15)),
            ("Call at 9", moment(9, 8), moment(9, 9)),
            ("Call at 9", moment(9, 10), moment(9, 21)),
            ("Call at 9", moment(9, 22), moment(10, 9)),
            ("Call tomorrow at 9", moment(9, 8), moment(10, 9)),
            ("Call at 12", moment(9, 8), moment(9, 12)),
            ("Call at 0", moment(8, 22), moment(9, 0)),
            ("Call at 08:00", moment(9, 7), moment(9, 8)),
            ("Call at 10.30", moment(9, 8), moment(9, 10, 30)),
            ("Call at 1", moment(9, 14), moment(10, 13)),
        ]
        for (text, now, start) in cases {
            let draft = try parse(text, now: now)
            XCTAssertEqual(draft.title, "Call", text)
            XCTAssertEqual(draft.start, start, "\(text), with now \(now)")
        }
    }

    @MainActor func testEverydayTimesAreTakenOutOfTheTitle() async throws {
        let now = moment(9, 8)
        let cases: [(text: String, title: String, start: Date)] = [
            ("Call with Ana at 5 pm", "Call with Ana", moment(9, 17)),
            ("Call Ana at 5pm", "Call Ana", moment(9, 17)),
            ("Lunch at 12", "Lunch", moment(9, 12)),
            ("Standup 10.30am", "Standup", moment(9, 10, 30)),
            ("Dentist 12/11 9:30am", "Dentist 12/11", moment(9, 9, 30)),
            ("Call at the office tomorrow 3pm", "Call at the office", moment(10, 15)),
            ("Dentist fri 9:30", "Dentist", moment(13, 9, 30)),
        ]
        for (text, title, start) in cases {
            let draft = try parse(text, now: now)
            XCTAssertEqual(draft.title, title, text)
            XCTAssertEqual(draft.start, start, text)
        }
    }

    @MainActor func testLengthsAreMinutesAndHours() async throws {
        let now = moment(9, 8)
        let cases: [(text: String, title: String, start: Date, minutes: Double)] = [
            ("Sync tomorrow 3pm for 30 minutes", "Sync", moment(10, 15), 30),
            ("Workshop tomorrow 9am for 1h30", "Workshop", moment(10, 9), 90),
            ("Call Ana tomorrow 2pm 45 min", "Call Ana", moment(10, 14), 45),
            ("Call tomorrow 2pm for 1 hour", "Call", moment(10, 14), 60),
            ("Demo tomorrow 4pm for 1.5 hours", "Demo", moment(10, 16), 90),
            ("Call tomorrow 2pm 30min", "Call", moment(10, 14), 30),
            ("Lunch with Sam tomorrow 1pm for 45m", "Lunch with Sam", moment(10, 13), 45),
            ("Call Ana at 9:30 for 2 hrs", "Call Ana", moment(9, 9, 30), 120),
            ("3D printing review tomorrow 3pm", "3D printing review", moment(10, 15), 60),
            ("Lunch fri at 12 for 30 minutes", "Lunch", moment(13, 12), 30),
        ]
        for (text, title, start, minutes) in cases {
            let draft = try parse(text, now: now)
            XCTAssertEqual(draft.title, title, text)
            XCTAssertEqual(draft.start, start, text)
            XCTAssertEqual(draft.end.timeIntervalSince(draft.start), minutes * 60, text)
            XCTAssertFalse(draft.isAllDay, text)
        }
    }

    @MainActor func testForDaysMakesAnAllDayEventThatSpansThem() async throws {
        let draft = try parse("Offsite fri for 3 days", now: moment(9, 8))
        XCTAssertEqual(draft.title, "Offsite")
        XCTAssertTrue(draft.isAllDay)
        XCTAssertEqual(draft.start, moment(13, 0), "the Friday, from midnight")
        XCTAssertEqual(draft.end, moment(16, 0), "three days on, the Monday")
        XCTAssertTrue(UpNext.whenText(draft).contains("–") && UpNext.whenText(draft).hasSuffix("all day"), "the preview shows the span")
    }

    @MainActor func testFullWeekdayNamesCountAnywhereButShortOnesOnlyAtTheEnd() async throws {
        let now = moment(9, 8)
        let friday = try parse("Lunch friday with Sam at 1", now: now)
        XCTAssertEqual(friday.title, "Lunch with Sam")
        XCTAssertEqual(friday.start, moment(13, 13), "Friday at one in the afternoon")
        let scores = try parse("Review sat scores tomorrow 9am", now: now)
        XCTAssertEqual(scores.title, "Review sat scores")
        XCTAssertEqual(scores.start, moment(10, 9))
        let saturday = try parse("Dentist sat 9am", now: now)
        XCTAssertEqual(saturday.title, "Dentist")
        XCTAssertEqual(saturday.start, moment(14, 9))
        let next = try parse("Offsite next friday", now: now)
        XCTAssertEqual(next.title, "Offsite")
        XCTAssertTrue(next.isAllDay)
        XCTAssertEqual(next.start, moment(13, 0))
    }

    @MainActor func testTomorrowWinsOverToday() async throws {
        let draft = try parse("Call today tomorrow 3pm", now: moment(9, 8))
        XCTAssertEqual(draft.title, "Call")
        XCTAssertEqual(draft.start, moment(10, 15))
    }

    @MainActor func testANumberWithADotIsNotATimeWithoutAMeridiem() async throws {
        let draft = try parse("Review 3.14 tomorrow 3pm", now: moment(9, 8))
        XCTAssertEqual(draft.title, "Review 3.14")
        XCTAssertEqual(draft.start, moment(10, 15))
    }

    @MainActor func testTheTitleKeepsItsWordsAsTyped() async throws {
        let doctor = try parse("Dr. Lee checkup tomorrow 3pm", now: moment(9, 8))
        XCTAssertEqual(doctor.title, "Dr. Lee checkup")
        let comma = try parse("Call Ana, tomorrow 3pm", now: moment(9, 8))
        XCTAssertEqual(comma.title, "Call Ana")
    }

    @MainActor func testAWeekdayWhoseTimeHasPassedRollsAWeekForward() async throws {
        let draft = try parse("Dentist mon 9am", now: moment(9, 10))
        XCTAssertEqual(draft.start, moment(16, 9), "Monday's nine has passed, so the Monday after")
    }

    @MainActor func testThePreviewShowsTheDayATimedEventEnds() async {
        // Two moments a minute apart share a day, and two days apart never do, in any time zone.
        let sameDay = CalendarEventDraft(title: "Call", start: moment(13, 0), end: moment(13, 1))
        XCTAssertTrue(UpNext.whenText(sameDay).contains("–") && !UpNext.whenText(sameDay).contains(" – "), UpNext.whenText(sameDay))
        let overnight = CalendarEventDraft(title: "Call", start: moment(13, 0), end: moment(15, 0))
        XCTAssertTrue(UpNext.whenText(overnight).contains(" – "), "the end's day is shown: \(UpNext.whenText(overnight))")
    }

    @MainActor func testOnlyARealMeetingHostMakesAJoinLink() async {
        func service(_ location: String) -> String? {
            UpNext.meetingLink(for: CalendarEvent(id: "x", title: "x", start: Date(), end: Date(), location: location))?.service
        }
        let genuine: [(url: String, service: String)] = [
            ("https://acme.zoom.us/j/123456789?pwd=abc", "Zoom"),
            ("https://zoom.us/my/room", "Zoom"),
            ("https://meet.google.com/abc-defg-hij", "Google Meet"),
            ("https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0", "Teams"),
            ("https://teams.live.com/meet/9876543210", "Teams"),
            ("https://acme.webex.com/meet/jane", "Webex"),
            ("https://acme.webex.com/join/jane", "Webex"),
            ("https://app.slack.com/huddle/T1/C1", "Slack huddle"),
            ("https://facetime.apple.com/join#v=1", "FaceTime"),
            ("https://chime.aws/1234", "Chime"),
            ("https://meet.goto.com/123", "GoTo Meeting"),
            ("https://whereby.com/room", "Whereby"),
            ("https://meet.jit.si/Room", "Jitsi"),
            ("https://bluejeans.com/123", "BlueJeans"),
            ("https://around.co/abc", "Around"),
            ("https://tuple.app/c/abc", "Tuple"),
            ("https://app.gather.town/app/x", "Gather"),
            ("https://join.skype.com/abc", "Skype"),
            ("https://discord.gg/abc", "Discord"),
            ("https://meeting.zoho.com/join?key=1", "Zoho Meeting"),
            ("https://app.livestorm.co/x/event", "Livestorm"),
        ]
        for (url, name) in genuine {
            XCTAssertEqual(service(url), name, url)
        }
        // Look-alikes: the service's name sits in the query, or in a host that only ends the same way.
        for url in ["https://evil.com/?r=zoom.us/j/1", "https://evilzoom.us/j/1", "https://zoom.us.evil.com/j/1", "https://evil.com/x.zoom.us/j/1"] {
            XCTAssertNil(service(url), url)
        }
        // Wrapped in a Safe Link, the look-alike still gets nothing, and a real Zoom link still joins.
        XCTAssertNil(service("https://nam04.safelinks.protection.outlook.com/?url=https%3A%2F%2Fevil.com%2F%3Fr%3Dzoom.us%2Fj%2F1&data=05"))
        XCTAssertEqual(service("https://nam04.safelinks.protection.outlook.com/?url=https%3A%2F%2Facme.zoom.us%2Fj%2F1&data=05"), "Zoom")
        // A host can hide a slash, a backslash, a hash, a question mark or a null in encoded form.
        // URLComponents decodes it, so the host it finds ends in zoom.us; the address is refused all the same.
        for url in ["https://evil.com%2f.zoom.us/j/1", "https://evil.com%5c.zoom.us/j/1", "https://evil.com%23.zoom.us/j/1", "https://evil.com%3f.zoom.us/j/1", "https://evil.com%00.zoom.us/j/1"] {
            XCTAssertNil(service(url), url)
        }
        for inner in ["https%3A%2F%2Fevil.com%252f.zoom.us%2Fj%2F1", "https%3A%2F%2Fevil.com%255c.zoom.us%2Fj%2F1", "https%3A%2F%2Fevil.com%2523.zoom.us%2Fj%2F1"] {
            XCTAssertNil(service("https://nam04.safelinks.protection.outlook.com/?url=\(inner)&data=05"), inner)
        }
        // A dot-dot or an encoded dot in the path, and a look-alike letter in the host, get nothing either.
        for url in ["https://acme.zoom.us/j/1/../../evil", "https://acme.zoom.us/%2e%2e/evil", "https://z\u{043E}om.us/j/1"] {
            XCTAssertNil(service(url), url)
        }
    }

    // MARK: Helpers

    /// Adds `text` through the add-event view as the palette does: the row's
    /// first action saves it to the default calendar. Returns the event saved,
    /// or nil when the view had no row.
    private func addFromView(_ text: String, _ session: PluginSession, _ system: SimulatedSystem) async throws -> CalendarEvent? {
        let from = Date().addingTimeInterval(-86_400)
        let to = Date().addingTimeInterval(60 * 86_400)
        let before = Set(try await system.calendarEvents(from: from, to: to).map(\.id))
        let opened = try await session.openView("add-event", query: CommandQuery(text: text))
        if let action = opened.root?.rows.first?.actions.first?.id {
            try await session.event(action)
        }
        await session.closeView(opened.session)
        return try await system.calendarEvents(from: from, to: to).first { !before.contains($0.id) }
    }

    private func assertAdded(_ added: CalendarEvent?, _ title: String, _ start: Date, minutes: Double, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let added else { return XCTFail("nothing was added for \"\(text)\"", file: file, line: line) }
        XCTAssertEqual(added.title, title, text, file: file, line: line)
        XCTAssertEqual(added.start, start, text, file: file, line: line)
        XCTAssertEqual(added.end.timeIntervalSince(added.start), minutes * 60, text, file: file, line: line)
    }

    /// `hour`:`minute` on the day `dayOffset` days from `now` (0 is today).
    private func at(_ hour: Int, _ minute: Int, day dayOffset: Int = 0, from now: Date) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: dayOffset, to: now) ?? now
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? now
    }

    /// Switches on the settings toggle whose title contains `text`.
    private func turnOn(_ supervisor: PluginSupervisor, _ text: String) async throws {
        let toggle = await supervisor.views[.settings]?.toggles.first { $0.title.contains(text) }
        await supervisor.press(try XCTUnwrap(toggle, "no \(text) toggle in settings").action, value: .bool(true))
    }

    /// Presses the action titled `title` on the panel row titled `row`.
    private func pressAction(_ title: String, onRow row: String, _ supervisor: PluginSupervisor) async throws {
        let rows = await supervisor.views[.panel]?.rows ?? []
        let node = try XCTUnwrap(rows.first { $0.title == row }, "no row \(row) in the panel")
        let action = try XCTUnwrap(node.actions.first { $0.title == title }, "no \(title) action on \(row)")
        await supervisor.press(action.id)
    }

    /// The titles of the empty states in a view: how a view says there's nothing to show.
    private func emptyTitles(_ root: ViewNode?) -> [String] {
        (root?.tree ?? []).compactMap { node in
            if case .empty(let title, _, _) = node { return title }
            return nil
        }
    }

    /// Reads the calendar again and waits until the plugin has handled it.
    private func reread(_ supervisor: PluginSupervisor) async {
        let before = await supervisor.settledCount
        await supervisor.refresh()
        _ = await waitUntil { await supervisor.settledCount > before }
    }
}
