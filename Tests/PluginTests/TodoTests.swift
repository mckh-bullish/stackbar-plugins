import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class TodoTests: XCTestCase {
    private let id = "io.navbytes.stackbar.plugins.todo"
    private let calendar = Calendar.current

    private func day(_ offset: Int, hour: Int? = nil, minute: Int = 0) -> String {
        let start = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date()))!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let hour else {
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: start)
        }
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start)!)
    }

    /// The next `weekday` (1 is Sunday) strictly after today, as an offset.
    private func offset(to weekday: Int) -> Int {
        let current = calendar.component(.weekday, from: Date())
        let offset = (weekday - current + 7) % 7
        return offset == 0 ? 7 : offset
    }

    /// The moment `hour` o'clock, `offset` days from today.
    private func at(_ offset: Int, _ hour: Int) -> Date {
        let start = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date()))!
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: start)!
    }

    /// Days from today to the next 14 November, on or after today.
    private func daysToNextNovember14() -> Int {
        let today = calendar.startOfDay(for: Date())
        var parts = calendar.dateComponents([.year], from: today)
        parts.month = 11
        parts.day = 14
        var date = calendar.date(from: parts)!
        if date < today { date = calendar.date(byAdding: .year, value: 1, to: date)! }
        return calendar.dateComponents([.day], from: today, to: date).day!
    }

    private func taskLines(_ supervisor: PluginSupervisor) async -> [String] {
        await supervisor.callTool("tasks").text.split(separator: "\n").map(String.init)
    }

    /// Whether a task line has `title`, due at `due`, whatever else it says.
    private func isDue(_ lines: [String], _ title: String, _ due: String) -> Bool {
        lines.contains { $0.hasPrefix("- \(title) (due \(due)") }
    }

    func testDatesTypedInTheTaskAreUnderstood() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Todo")
        func add(_ text: String) async -> CommandResult { await supervisor.runCommand("add", arguments: ["task": text], source: .palette) }

        guard case .message(let added) = await add("Call the dentist tomorrow at 2pm") else { return XCTFail("add adds") }
        XCTAssertEqual(added?.hasPrefix("Added “Call the dentist” for Tomorrow"), true, added ?? "")
        _ = await add("Water the plants every friday")
        _ = await add("Pay rent on the day after tomorrow !")
        _ = await add("Read \"Monday\" newsletter")
        _ = await add("Book flights in 3 days")
        _ = await add("Pick up the kids friday at 3:30")
        guard case .failure = await add("tomorrow at 9") else { return XCTFail("a date with nothing to do is refused") }

        let tasks = await supervisor.callTool("tasks").text
        XCTAssertTrue(tasks.contains("- Call the dentist (due \(day(1, hour: 14)))"), tasks)
        XCTAssertTrue(tasks.contains("- Water the plants (due \(day(offset(to: 6) == 7 ? 0 : offset(to: 6))), repeats weekly)"), tasks)
        XCTAssertTrue(tasks.contains("- Pay rent (due \(day(2)), important)"), tasks)
        XCTAssertTrue(tasks.contains("- Read Monday newsletter\n") || tasks.hasSuffix("- Read Monday newsletter"), "quoted words stay in the title: \(tasks)")
        XCTAssertTrue(tasks.contains("- Book flights (due \(day(3)))"), tasks)
        XCTAssertTrue(tasks.contains("- Pick up the kids (due \(day(offset(to: 6), hour: 15, minute: 30)))"), tasks)

        // The agent tool shows private tasks only once the user turns it on.
        let tools = await supervisor.tools
        XCTAssertEqual(tools.first { $0.name == "tasks" }?.optIn, true)
        XCTAssertEqual(tools.first { $0.name == "add" }?.optIn, false)
        await supervisor.stop()
    }

    func testPartsOfTheDayMoveTheTime() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Todo")
        for text in ["Call mum this evening at 7", "call mum tonight at 9", "Dinner tomorrow evening at 8", "Drinks friday night at 9"] {
            _ = await supervisor.runCommand("add", arguments: ["task": text], source: .palette)
        }
        let lines = await taskLines(supervisor)
        // With no day given, a time already gone today rolls to tomorrow.
        let sevenPM = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: Date())!
        XCTAssertTrue(isDue(lines, "Call mum", day(Date() < sevenPM ? 0 : 1, hour: 19)), "\(lines)")
        XCTAssertTrue(isDue(lines, "call mum", day(0, hour: 21)), "\(lines)")
        XCTAssertTrue(isDue(lines, "Dinner", day(1, hour: 20)), "\(lines)")
        XCTAssertTrue(isDue(lines, "Drinks", day(offset(to: 6), hour: 21)), "\(lines)")
        await supervisor.stop()
    }

    func testNumericDates() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Todo")
        for text in ["dentist 14/11", "vet 11/14", "Read 1/2 the book", "Pay 1/2 of the bill by 14/11"] {
            _ = await supervisor.runCommand("add", arguments: ["task": text], source: .palette)
        }
        let lines = await taskLines(supervisor)
        let nov14 = day(daysToNextNovember14())
        XCTAssertTrue(isDue(lines, "dentist", nov14), "\(lines)")
        XCTAssertTrue(isDue(lines, "vet", nov14), "\(lines)")
        XCTAssertTrue(lines.contains("- Read 1/2 the book"), "a fraction is not a date: \(lines)")
        XCTAssertTrue(isDue(lines, "Pay 1/2 of the bill", nov14), "a date after a fraction still counts: \(lines)")
        await supervisor.stop()
    }

    func testByAndOrdinals() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Todo")
        for text in ["Finish report by 5", "Submit by midnight", "pay bills on 3rd", "Lose 2 kg by 5 kg"] {
            _ = await supervisor.runCommand("add", arguments: ["task": text], source: .palette)
        }
        let lines = await taskLines(supervisor)
        let fivePM = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: Date())!
        let lastMinute = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: Date())!
        XCTAssertTrue(isDue(lines, "Finish report", day(Date() < fivePM ? 0 : 1, hour: 17)), "\(lines)")
        XCTAssertTrue(isDue(lines, "Submit", day(Date() < lastMinute ? 0 : 1, hour: 23, minute: 59)), "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("- pay bills (due ") && $0.hasSuffix("-03)") }, "\(lines)")
        XCTAssertTrue(lines.contains("- Lose 2 kg by 5 kg"), "\"by 5 kg\" is a quantity: \(lines)")
        await supervisor.stop()
    }

    func testABareHourIsTheNextOneComing() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Todo")
        let before = Date()
        _ = await supervisor.runCommand("add", arguments: ["task": "Book table at 8"], source: .palette)
        // 8 am today, 8 pm today, then 8 am tomorrow: the first one still to come.
        let (offset, hour) = [(0, 8), (0, 20), (1, 8)].first { at($0.0, $0.1) > before }!
        let lines = await taskLines(supervisor)
        XCTAssertTrue(isDue(lines, "Book table", day(offset, hour: hour)), "\(lines)")
        await supervisor.stop()
    }

    func testADueTaskNotificationCanBeDoneOrSnoozed() async throws {
        let host = Host(self)
        let due = Date().addingTimeInterval(-60).timeIntervalSinceReferenceDate
        let created = Date().addingTimeInterval(-3600).timeIntervalSinceReferenceDate
        try await host.services.storage.set("storage", #""This Mac only""#, for: id)
        try await host.services.storage.set("tasks", """
        [{"id":"a","title":"Call mum","due":\(due),"hasTime":true,"important":false,"created":\(created),"reminded":false}]
        """, for: id)
        let supervisor = try await host.start("Todo")
        _ = await waitUntil { !host.notifications.all.isEmpty }
        let notification = try XCTUnwrap(host.notifications.all.first)
        XCTAssertEqual(notification.actions.map(\.command), ["complete", "snooze"])

        // Each button runs its command with the task's id.
        let snooze = notification.actions[1]
        guard case .message = await supervisor.runCommand(snooze.command ?? "", arguments: snooze.arguments ?? [:], source: .palette) else {
            return XCTFail("Snooze 1 Hour moves the task")
        }
        let lines = await taskLines(supervisor)
        XCTAssertTrue(lines.contains { $0.hasPrefix("- Call mum (due ") }, "\(lines)")
        let done = notification.actions[0]
        guard case .message = await supervisor.runCommand(done.command ?? "", arguments: done.arguments ?? [:], source: .palette) else {
            return XCTFail("Done ticks the task off")
        }
        let remaining = await supervisor.callTool("tasks").text
        XCTAssertEqual(remaining, "No open tasks")

        // A button for a task that has since gone says so, rather than showing its id.
        let gone = await supervisor.runCommand("complete", arguments: ["task": UUID().uuidString], source: .palette)
        XCTAssertEqual(gone, .failure("That task is no longer open"))
        await supervisor.stop()
    }

    func testByCountsOnlyAtTheEndOfATask() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Todo")
        for text in ["Divide by 2", "Written by 3 authors", "Finish report by 5"] {
            _ = await supervisor.runCommand("add", arguments: ["task": text], source: .palette)
        }
        let lines = await taskLines(supervisor)
        XCTAssertTrue(lines.contains("- Divide by 2"), "a sum is not a time: \(lines)")
        XCTAssertTrue(lines.contains("- Written by 3 authors"), "\(lines)")
        let fivePM = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: Date())!
        XCTAssertTrue(isDue(lines, "Finish report", day(Date() < fivePM ? 0 : 1, hour: 17)), "\(lines)")
        await supervisor.stop()
    }

    func testNumbersThatAreNotDates() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Todo")
        for text in ["Gym 24/7 support", "PR #12/13", "Pay 31/4"] {
            _ = await supervisor.runCommand("add", arguments: ["task": text], source: .palette)
        }
        let lines = await taskLines(supervisor)
        XCTAssertTrue(lines.contains("- Gym 24/7 support"), "24/7 means always: \(lines)")
        XCTAssertTrue(lines.contains("- PR #12/13"), "a reference is not a date: \(lines)")
        XCTAssertTrue(lines.contains("- Pay 31/4"), "April has no 31st, and the date is not rolled into May: \(lines)")
        await supervisor.stop()
    }

    func testTonightAndEveningHoursAfterMidnight() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Todo")
        for text in ["Party tonight at 12", "Call the bank tonight at 1am", "Gym every evening at 7"] {
            _ = await supervisor.runCommand("add", arguments: ["task": text], source: .palette)
        }
        let lines = await taskLines(supervisor)
        // Tonight at 12 is the midnight at the end of today.
        XCTAssertTrue(isDue(lines, "Party", day(1, hour: 0)), "\(lines)")
        // Tonight at 1am is tomorrow's 1 am once today's has passed.
        let oneAM = calendar.date(bySettingHour: 1, minute: 0, second: 0, of: Date())!
        XCTAssertTrue(isDue(lines, "Call the bank", day(Date() < oneAM ? 0 : 1, hour: 1)), "\(lines)")
        // A repeat with an explicit time keeps the part of the day: every evening at 7 is 7 pm.
        let sevenPM = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: Date())!
        XCTAssertTrue(isDue(lines, "Gym", day(Date() < sevenPM ? 0 : 1, hour: 19)) && lines.contains { $0.hasPrefix("- Gym") && $0.hasSuffix("repeats daily)") }, "\(lines)")
        await supervisor.stop()
    }

    func testAPartOfTheDayStaysInTheTitleUnlessItIsUsed() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Todo")
        _ = await supervisor.runCommand("add", arguments: ["task": "Evening class at 6"], source: .palette)
        let lines = await taskLines(supervisor)
        let sixPM = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: Date())!
        XCTAssertTrue(isDue(lines, "Evening class", day(Date() < sixPM ? 0 : 1, hour: 18)), "the title keeps evening: \(lines)")
        await supervisor.stop()
    }

    func testSearchListsEveryOpenTask() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Todo")
        _ = await supervisor.runCommand("add", arguments: ["task": "Buy milk"], source: .palette)
        _ = await supervisor.runCommand("add", arguments: ["task": "Call the bank tomorrow"], source: .palette)
        let session = try await host.session("Todo")
        let opened = try await session.openView("search")
        XCTAssertEqual(opened.root?.rows.count, 2, "\(String(describing: opened.root))")
        await supervisor.stop()
    }

    func testCompletingARepeatingTaskMovesItOn() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Todo")
        _ = await supervisor.runCommand("add", arguments: ["task": "Stretch every day"], source: .palette)
        _ = await supervisor.runCommand("add", arguments: ["task": "Buy milk"], source: .palette)

        guard case .message(let done) = await supervisor.runCommand("complete", arguments: ["task": "stretch"], source: .palette) else {
            return XCTFail("complete finds a task by the start of its title")
        }
        XCTAssertEqual(done, "Done: “Stretch”. Next: Tomorrow")
        guard case .message = await supervisor.runCommand("complete", arguments: ["task": "milk"], source: .palette) else {
            return XCTFail("complete finds a task by a word in its title")
        }
        guard case .failure = await supervisor.runCommand("complete", arguments: ["task": "milk"], source: .palette) else {
            return XCTFail("a done task is not open any more")
        }
        let tasks = await supervisor.callTool("tasks").text
        XCTAssertEqual(tasks, "- Stretch (due \(day(1)), repeats daily)")

        // Undo in the panel brings the milk back.
        await supervisor.press("button/undo")
        let after = await supervisor.callTool("tasks").text
        XCTAssertTrue(after.contains("- Buy milk"), after)
        await supervisor.stop()
    }

    func testSnoozeMovesATaskLater() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Todo")
        _ = await supervisor.runCommand("add", arguments: ["task": "Send the invoice today"], source: .palette)
        guard case .message(let snoozed) = await supervisor.runCommand("snooze", arguments: ["task": "invoice"], source: .palette) else {
            return XCTFail("snooze snoozes")
        }
        XCTAssertEqual(snoozed, "Snoozed “Send the invoice” to Tomorrow")
        _ = await supervisor.runCommand("snooze", arguments: ["task": "invoice", "until": "in 4 days at 10:30"], source: .palette)
        let tasks = await supervisor.callTool("tasks").text
        XCTAssertEqual(tasks, "- Send the invoice (due \(day(4, hour: 10, minute: 30)))")
        await supervisor.stop()
    }

    /// Off Reminders (here: not available), Todo sends its own notification.
    func testATimedTaskRemindsOnceWhenDue() async throws {
        let system = SimulatedSystem()
        system.simulate(reminders: SimulatedReminders(access: .unavailable))
        let host = Host(self, system: system)
        let due = Date().addingTimeInterval(-60).timeIntervalSinceReferenceDate
        let created = Date().addingTimeInterval(-3600).timeIntervalSinceReferenceDate
        let slept = Date().addingTimeInterval(-86400 * 2).timeIntervalSinceReferenceDate
        try await host.services.storage.set("tasks", """
        [{"id":"a","title":"Call mum","due":\(due),"hasTime":true,"important":false,"created":\(created),"reminded":false},
         {"id":"b","title":"Long gone","due":\(slept),"hasTime":true,"important":false,"created":\(slept),"reminded":false},
         {"id":"c","title":"Someday","hasTime":false,"important":false,"created":\(created),"reminded":false}]
        """, for: id)
        let supervisor = try await host.start("Todo")
        _ = await waitUntil { !host.notifications.all.isEmpty }
        await supervisor.press("button/show-done")
        XCTAssertEqual(host.notifications.all.map(\.title), ["Call mum"], "only the task that just came due, and only once")
        let tasks = await supervisor.callTool("tasks").text
        XCTAssertTrue(tasks.contains("- Call mum (due") && tasks.contains("overdue"), tasks)
        await supervisor.stop()
    }

    // MARK: Reminders

    private func refreshed(_ supervisor: PluginSupervisor) async {
        let before = await supervisor.settledCount
        await supervisor.refresh()
        _ = await waitUntil { await supervisor.settledCount > before }
    }

    func testTasksLiveInRemindersWithListsAndSteps() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Todo")
        func add(_ text: String) async -> CommandResult { await supervisor.runCommand("add", arguments: ["task": text], source: .palette) }

        guard case .message(let milk) = await add("Buy oat milk #groceries") else { return XCTFail("add adds") }
        XCTAssertEqual(milk, "Added “Buy oat milk” in Groceries")
        guard case .message(let offsite) = await add("Plan the offsite friday: book a venue; send invites") else { return XCTFail("add adds") }
        XCTAssertEqual(offsite?.contains("with 2 steps"), true, offsite ?? "")
        _ = await add("Stretch every day at 7am")

        var reminders = host.system.simulatedReminders.reminders
        XCTAssertEqual(reminders.map(\.title).sorted(), ["Buy oat milk", "Plan the offsite", "Stretch"])
        XCTAssertEqual(reminders.first { $0.title == "Buy oat milk" }?.list, "list-2", "#groceries files it in Groceries")
        XCTAssertEqual(reminders.first { $0.title == "Plan the offsite" }?.notes, "☐ book a venue\n☐ send invites", "steps are a checklist in the notes")
        let stretch = reminders.first { $0.title == "Stretch" }
        XCTAssertEqual(stretch?.recurrence, ReminderRecurrence(.daily))
        XCTAssertEqual(stretch?.alarm, stretch?.due, "Reminders alerts at the time, on every device")

        // Finishing a repeating task: a done copy, and the reminder moves on.
        _ = await supervisor.runCommand("complete", arguments: ["task": "stretch"], source: .palette)
        reminders = host.system.simulatedReminders.reminders
        XCTAssertEqual(reminders.filter { $0.title == "Stretch" }.count, 2)
        XCTAssertEqual(reminders.filter { $0.title == "Stretch" && $0.completed != nil }.count, 1)
        XCTAssertTrue(host.notifications.all.isEmpty, "Reminders does the alerting")
        await supervisor.stop()
    }

    func testChangesFromOtherDevicesComeIn() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Todo")
        _ = await supervisor.runCommand("add", arguments: ["task": "Call the bank"], source: .palette)
        _ = await supervisor.runCommand("add", arguments: ["task": "Water the plants"], source: .palette)

        // On the iPhone: rename one, delete the other, add a new one with a step ticked.
        var state = host.system.simulatedReminders
        guard let bank = state.reminders.firstIndex(where: { $0.title == "Call the bank" }) else { return XCTFail("not in Reminders") }
        state.reminders[bank].title = "Call the bank about the card"
        state.reminders.removeAll { $0.title == "Water the plants" }
        state.reminders.append(Reminder(id: "phone-1", externalID: "phone-1", list: "list-2", title: "Eggs", notes: "Free range\n\n☑ check the fridge\n☐ buy a dozen", priority: .high))
        host.system.simulate(reminders: state)
        await supervisor.remindersChanged()
        _ = await waitUntil { await supervisor.callTool("tasks").text.contains("Eggs") }

        let tasks = await supervisor.callTool("tasks").text
        XCTAssertTrue(tasks.contains("- Call the bank about the card"), tasks)
        XCTAssertFalse(tasks.contains("Water the plants"), "deleted on the phone: \(tasks)")
        XCTAssertTrue(tasks.contains("- Eggs (important, 1 of 2 steps done, list Groceries)"), tasks)

        // Then this Mac changes only the title; the phone's notes stay.
        var notes = host.system.simulatedReminders
        notes.reminders[notes.reminders.firstIndex { $0.title == "Call the bank about the card" }!].notes = "Card ending 4242"
        host.system.simulate(reminders: notes)
        await supervisor.remindersChanged()
        _ = await waitUntil { host.system.simulatedReminders.reminders.contains { $0.notes == "Card ending 4242" } }
        await refreshed(supervisor)
        _ = await supervisor.runCommand("snooze", arguments: ["task": "call the bank", "until": "tomorrow 9am"], source: .palette)
        let saved = host.system.simulatedReminders.reminders.first { $0.title == "Call the bank about the card" }
        XCTAssertEqual(saved?.notes, "Card ending 4242")
        XCTAssertNotNil(saved?.due)
        await supervisor.stop()
    }

    /// One task Reminders refuses (its list is gone) must not make the next
    /// sync add the tasks before it to Reminders again.
    func testAFailedSaveDoesNotDuplicateEarlierTasks() async throws {
        let system = SimulatedSystem()
        system.simulate(reminders: .sample())
        let host = Host(self, system: system)
        let created = Date().addingTimeInterval(-3600).timeIntervalSinceReferenceDate
        try await host.services.storage.set("tasks", """
        [{"id":"good","title":"Good one","hasTime":false,"important":false,"created":\(created),"reminded":false},
         {"id":"bad","title":"Bad list","list":"deleted-list","hasTime":false,"important":false,"created":\(created),"reminded":false}]
        """, for: id)
        let supervisor = try await host.start("Todo")
        await refreshed(supervisor)
        await refreshed(supervisor)
        await refreshed(supervisor)
        let titles = host.system.simulatedReminders.reminders.map(\.title)
        XCTAssertEqual(titles.filter { $0 == "Good one" }.count, 1, "saved once, then remembered: \(titles)")
        let tasks = await supervisor.callTool("tasks").text
        XCTAssertTrue(tasks.contains("- Good one") && tasks.contains("- Bad list"), "the refused task stays local: \(tasks)")
        await supervisor.stop()
    }

    /// A save Reminders refuses must not let the pull replace the local edit
    /// with Reminders' older copy.
    func testAFailedPushKeepsTheLocalEdit() async throws {
        let system = SimulatedSystem()
        system.simulate(reminders: .sample())
        let host = Host(self, system: system)
        let supervisor = try await host.start("Todo")
        _ = await supervisor.runCommand("add", arguments: ["task": "Send the invoice"], source: .palette)
        _ = await waitUntil { host.system.simulatedReminders.reminders.contains { $0.title == "Send the invoice" } }
        let created = host.system.simulatedReminders.reminders.first { $0.title == "Send the invoice" }
        XCTAssertNotNil(created, "the task reached Reminders")
        // Its list disappears, so the next save is refused.
        var state = host.system.simulatedReminders
        state.lists.removeAll { $0.id == created?.list }
        host.system.simulate(reminders: state)
        _ = await supervisor.runCommand("snooze", arguments: ["task": "invoice"], source: .palette)
        await refreshed(supervisor)
        await refreshed(supervisor)
        let tasks = await supervisor.callTool("tasks").text
        XCTAssertTrue(tasks.contains("- Send the invoice (due \(day(1)))"), "the snooze survives the failed push: \(tasks)")
        await supervisor.stop()
    }

    func testDeclinedRemindersKeepsTasksOnThisMac() async throws {
        let system = SimulatedSystem()
        system.simulate(reminders: SimulatedReminders(access: .notDetermined, grantWhenAsked: false))
        let host = Host(self, system: system)
        let supervisor = try await host.start("Todo")
        _ = await supervisor.runCommand("add", arguments: ["task": "Buy stamps"], source: .palette)
        XCTAssertTrue(system.simulatedReminders.reminders.isEmpty)
        let tasks = await supervisor.callTool("tasks").text
        XCTAssertTrue(tasks.contains("- Buy stamps"), tasks)
        let panel = await supervisor.views[.panel].map { TreeTextRenderer.render($0) } ?? ""
        XCTAssertTrue(panel.contains("tasks stay on this Mac"), panel)
        await supervisor.stop()
    }

    func testTasksFromBeforeMoveIntoReminders() async throws {
        let host = Host(self)
        let created = Date().addingTimeInterval(-3600).timeIntervalSinceReferenceDate
        try await host.services.storage.set("tasks", """
        [{"id":"a","title":"Renew passport","hasTime":false,"important":true,"created":\(created),"reminded":false}]
        """, for: id)
        let supervisor = try await host.start("Todo")
        _ = await waitUntil { !host.system.simulatedReminders.reminders.isEmpty }
        let moved = host.system.simulatedReminders.reminders
        XCTAssertEqual(moved.map(\.title), ["Renew passport"])
        XCTAssertEqual(moved.first?.priority, .high)
        await refreshed(supervisor)
        XCTAssertEqual(host.system.simulatedReminders.reminders.count, 1, "moved once, not again on every refresh")
        await supervisor.stop()
    }

    func testTickingTheLastStepFinishesTheTaskAndANudgeNamesASmallStep() async throws {
        let system = SimulatedSystem()
        system.simulate(reminders: SimulatedReminders(access: .unavailable))
        let host = Host(self, system: system)
        let created = Date().addingTimeInterval(-3600).timeIntervalSinceReferenceDate
        try await host.services.storage.set("tasks", """
        [{"id":"a","title":"Clean the garage","hasTime":false,"important":false,"created":\(created),"reminded":false,
          "steps":[{"id":"s1","title":"Sort the boxes","size":"B","done":false},{"id":"s2","title":"Bin the old paint","size":"S","done":false}]}]
        """, for: id)
        // The nudge fires in the four hours from the chosen one, so choose this hour.
        try await host.services.storage.set("nudgeHour", "\(calendar.component(.hour, from: Date()))", for: id)
        let supervisor = try await host.start("Todo")
        _ = await waitUntil { !host.notifications.all.isEmpty }
        XCTAssertEqual(host.notifications.all.first?.title, "One small thing?")
        XCTAssertEqual(host.notifications.all.first?.body, "Bin the old paint (for “Clean the garage”)", "the nudge picks a small step")

        let panel = await supervisor.views[.panel].map { TreeTextRenderer.render($0) } ?? ""
        XCTAssertTrue(panel.contains("Next: Bin the old paint"), "small steps first: \(panel)")
        await supervisor.press("button/next-step-a")
        var tasks = await supervisor.callTool("tasks").text
        XCTAssertTrue(tasks.contains("- Clean the garage (1 of 2 steps done)"), tasks)
        await supervisor.press("button/next-step-a")
        tasks = await supervisor.callTool("tasks").text
        XCTAssertEqual(tasks, "No open tasks", "the last step finishes the task")
        await supervisor.stop()
    }

    func testABrainDumpAddsATaskPerLine() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Todo")
        guard case .message(let added) = await supervisor.runCommand("add", arguments: ["task": "Buy milk\n\nCall mum tomorrow\n  Fix the bike !"], source: .palette) else { return XCTFail("add adds") }
        XCTAssertEqual(added, "Added 3 tasks")
        let tasks = await supervisor.callTool("tasks").text
        XCTAssertTrue(tasks.contains("- Fix the bike (important)") && tasks.contains("- Call mum (due") && tasks.contains("- Buy milk"), tasks)
        await supervisor.stop()
    }
}
