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

    func testATimedTaskRemindsOnceWhenDue() async throws {
        let host = Host(self)
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
}
