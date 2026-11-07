import StackbarKit
import Foundation

/// A calm to-do list for the menu bar. Type a task the way you would say it
/// ("Call the dentist tomorrow at 2pm", "Water the plants every Sunday") and
/// the date, time and repeat come out of the words. Today's tasks sit on
/// top, the rest wait below, and a timed task taps you on the shoulder when
/// it is due. Ticking off a repeating task moves it to its next day. Every
/// tick, delete and reschedule can be undone.
///
/// Tasks live in Apple Reminders by default, so they reach the iPhone, iPad
/// and Watch, and Reminders lists are the categories. If Reminders access
/// is declined, or Settings says "This Mac only", they stay on this Mac.
/// A big task breaks into small, medium and big steps.
@main
final class Todo: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.todo",
        name: "Todo",
        version: "2.1.1",
        summary: "A calm to-do list that understands dates as you type them, kept in Apple Reminders so it's on all your devices.",
        surfaces: [.menuBar, .panel, .settings, .widget],
        triggers: [.launch, .every(.seconds(30)), .wake, .reminders],
        capabilities: [.reminders],
        minimumStackbar: "0.20.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/Todo",
        accent: .orange,
        symbol: "checklist"
    )

    // MARK: Previews

    static let previews: [PreviewScene<Todo>] = [
        PreviewScene("hero", "Type it the way you'd say it; dates are understood") { plugin in
            plugin.tasks = samples(now: plugin.now)
        },
        PreviewScene("widget", "Today's list on your desktop", surface: .widget) { plugin in
            plugin.tasks = samples(now: plugin.now)
        },
    ]

    static func samples(now: Date) -> [Item] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func at(_ days: Int, _ hour: Int?) -> Date? {
            let day = calendar.date(byAdding: .day, value: days, to: today) ?? today
            return hour.flatMap { calendar.date(bySettingHour: $0, minute: 0, second: 0, of: day) } ?? day
        }
        let list: [(String, Int?, Int?, Repeat?, Bool, Bool)] = [
            ("Send the invoice to Northwind", -1, nil, nil, true, false),
            ("Call mum", 0, 18, nil, false, false),
            ("Review Priya's checkout PR", 0, 15, nil, true, false),
            ("Water the plants", 0, nil, .weekly, false, false),
            ("Book flights for the offsite", 1, nil, nil, false, false),
            ("Stand-up notes", 1, 9, .weekdays, false, false),
            ("Renew passport", 12, nil, nil, false, false),
            ("Read the SwiftUI layout chapter", nil, nil, nil, false, false),
            ("Buy coffee beans", 0, nil, nil, false, true),
        ]
        return list.enumerated().map { index, entry in
            let (title, days, hour, repeats, important, finished) = entry
            var item = Item(id: "sample-\(index)", title: title, due: days.flatMap { at($0, hour) }, hasTime: hour != nil,
                            repeats: repeats, important: important, created: now.addingTimeInterval(-86400 * 3))
            if finished { item.done = now.addingTimeInterval(-3600) }
            if title.hasPrefix("Book flights") {
                item.steps = [Step(id: "s1", title: "Pick the dates with the team", done: true), Step(id: "s2", title: "Compare two airlines"), Step(id: "s3", title: "Book and share the plan", size: .medium)]
            }
            return item
        }
    }

    /// Warm and quiet: the earthy orange of the shared design system.
    let theme = Theme.orange

    @Stored("tasks") var tasks: [Item] = []
    @Stored("menuBarShows") var menuBarShows = MenuBarShows.today.rawValue
    @Stored("reminders") var reminders = true
    @Stored("sound") var sound = false
    @Stored("summaryHour") var summaryHour = -1
    @Stored("lastSummary") var lastSummary = ""
    @Stored("keepDoneDays") var keepDoneDays = 7
    @Stored("showDone") var showDone = false
    @Stored("storage") var storage = Storage.reminders.rawValue
    /// Each task as it was last written to or read from Reminders, by id:
    /// what a change is measured against, so only changed fields are sent.
    @Stored("mirror") var mirror: [String: Item] = [:]
    /// The Reminders list the panel shows; empty for all.
    @Stored("listFilter") var listFilter = ""
    @Stored("nudgeHour") var nudgeHour = -1
    @Stored("lastNudge") var lastNudge = ""

    /// Whether Reminders said yes, as of the last refresh.
    var access: ReminderAccess?
    var lists: [ReminderList] = []
    /// The last thing that went wrong talking to Reminders.
    var syncProblem: String?
    /// The task whose step field is open.
    var breaking: String?

    var now = Date()
    /// The task open in the inline editor.
    var editing: String?
    /// What just happened, with the list as it was before, for Undo.
    var notice: Notice?

    struct Notice {
        var text: String
        var before: [Item]?
        var at: Date
    }

    enum Storage: String, CaseIterable {
        case reminders = "Reminders"
        case local = "This Mac only"
    }

    /// Tasks go to and come from Reminders right now.
    var syncing: Bool { storage == Storage.reminders.rawValue && access == .granted }

    enum MenuBarShows: String, CaseIterable {
        case today = "Count for today"
        case next = "Next task"
        case open = "Count of all open"
        case icon = "Icon only"
    }

    /// The 30-second tick only needs to be a safety net for Reminders: changes
    /// on other devices arrive through the `.reminders` trigger, and this
    /// Mac's own go out when they're made. The tick still checks what is due.
    static let tickSyncEvery: TimeInterval = 300

    /// After a failed sync, the next 30-second tick tries again.
    static let retrySyncEvery: TimeInterval = 25

    private var lastSync = Date.distantPast
    /// Tasks whose last push failed: the pull must not replace their local
    /// edits with Reminders' older copy.
    private var unpushed: Set<String> = []
    /// How often a delete has failed, by task id, so one that can never
    /// succeed is given up on.
    private var deleteFailures: [String: Int] = [:]
    static let deleteAttempts = 5

    func refresh() async throws {
        now = Date()
        if Stackbar.refreshReason != .interval || now.timeIntervalSince(lastSync) >= (syncProblem == nil ? Self.tickSyncEvery : Self.retrySyncEvery) {
            lastSync = now
            await sync()
        }
        remind()
        summarize()
        nudge()
        tidy()
        if let notice, now.timeIntervalSince(notice.at) > 20, editing == nil { self.notice = nil }
    }

    // MARK: - Surfaces

    var menuBar: ViewContent {
        switch MenuBarShows(rawValue: menuBarShows) ?? .today {
        case .today:
            Label(dueToday.isEmpty ? "" : "\(dueToday.count)", symbol: dueToday.isEmpty ? "checklist.checked" : "checklist").role(.secondary)
        case .open:
            Label(open.isEmpty ? "" : "\(open.count)", symbol: open.isEmpty ? "checklist.checked" : "checklist").role(.secondary)
        case .next:
            if let next = dueToday.first {
                Label(Self.clip(next.nextStep?.title ?? next.title, 22) + (next.hasTime ? " · " + Self.time(next.due ?? now) : ""), symbol: "checklist").role(.secondary)
            } else {
                Label("", symbol: "checklist.checked").role(.secondary)
            }
        case .icon:
            Label("", symbol: "checklist").role(.secondary)
        }
    }

    var panel: ViewContent {
        PanelHeader(headline, subtitle: subtitle, symbol: open.isEmpty ? "leaf.fill" : "checklist", theme: theme) {
            if todayTotal > 0 {
                Gauge(value: Double(doneToday.count), total: Double(todayTotal), theme: theme, size: 30, lineWidth: 4, label: "\(doneToday.count) of \(todayTotal) done today")
            }
            IconButton(showDone ? "eye.slash" : "checkmark.circle", label: showDone ? "Hide done" : "Show done", theme: theme, prominence: showDone ? .tinted : .plain, key: "show-done") {
                self.showDone.toggle()
            }
        }
        TextField("Add a task, like “Call mum tomorrow 6pm”", text: "", key: "add") { text in
            self.add(text)
            await self.save()
        }
        if syncing && lists.count > 1 {
            Picker("List", options: ["All lists"] + lists.map(\.title), selection: lists.first { $0.id == listFilter }?.title ?? "All lists", key: "list-filter") { title in
                self.listFilter = self.lists.first { $0.title == title }?.id ?? ""
            }
        }
        if storage == Storage.reminders.rawValue, let access, access != .granted, access != .notDetermined {
            Banner(access == .unavailable ? "Reminders isn't available here, so tasks stay on this Mac." : "Stackbar can't use Reminders, so tasks stay on this Mac. Allow it in System Settings › Privacy & Security › Reminders.", symbol: "icloud.slash", theme: theme) {
                ActionButton("Keep on this Mac", theme: theme, key: "use-local") { self.storage = Storage.local.rawValue }
            }
        }
        if let notice {
            Banner(notice.text, symbol: "checkmark.circle.fill", theme: theme) {
                if notice.before != nil {
                    ActionButton("Undo", theme: theme, key: "undo") {
                        self.undo()
                        await self.save()
                    }
                }
            }
        }
        if shown(open).isEmpty && !(showDone && !shown(done).isEmpty) {
            EmptyState("Nothing on your plate", symbol: "leaf", message: "Type a task above when something comes up. Dates and times in it are understood.", theme: theme)
        }
        group("Still on your list", overdue)
        group("Today", today)
        group("Tomorrow", tomorrow)
        group("Coming up", later)
        group("Someday", someday)
        if showDone && !shown(done).isEmpty {
            Card("Done", detail: "\(shown(done).count)", spacing: 0, padding: Space.s) {
                ForEach(shown(done).prefix(30)) { task in row(task) }
                Button(key: "clear-done", action: {
                    self.clearDone()
                    await self.save()
                }) {
                    Text("Clear done tasks").typography(.caption).foreground(Theme.critical.textPaint)
                }
                .padding(horizontal: Space.s, vertical: Space.xs)
            }
        }
    }

    var widget: ViewContent {
        VStack(alignment: .start, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Text("TODAY").typography(.overline).foreground(theme.textPaint)
                Spacer()
                if todayTotal > 0 {
                    Text("\(doneToday.count)/\(todayTotal)").role(.secondary).typography(.captionNumber)
                }
            }
            if dueToday.isEmpty {
                Label(open.isEmpty ? "A clear list" : "Nothing due today", symbol: "leaf").role(.secondary)
            } else {
                ForEach(dueToday.prefix(4)) { task in
                    HStack(spacing: Space.xs) {
                        Image(systemName: "circle").font(size: 11).foreground(.role(.secondary))
                        Text(Self.clip(task.nextStep.map { "\(task.title): \($0.title)" } ?? task.title, 34)).typography(.body)
                        Spacer()
                        if task.hasTime, let due = task.due { Text(Self.time(due)).role(.secondary).typography(.captionNumber) }
                    }
                }
                if dueToday.count > 4 { Text("and \(dueToday.count - 4) more").role(.secondary).typography(.caption) }
            }
        }
        .frame(fillWidth: true, fillHeight: true, alignment: .topLeading)
    }

    var settings: ViewContent {
        Section("Where tasks live") {
            Picker("Keep tasks in", options: Storage.allCases.map(\.rawValue), selection: storage) { choice in
                guard choice != self.storage else { return }
                self.storage = choice
                // Measure from what Reminders has now, not from an old copy.
                self.mirror = [:]
                self.lastSync = Date()
                await self.sync()
            }
            Text(storageNote).role(.secondary)
        }
        Section("Menu bar") {
            Picker("Show", options: MenuBarShows.allCases.map(\.rawValue), selection: menuBarShows) { self.menuBarShows = $0 }
        }
        Section("Reminders") {
            Toggle("Notify me when a task with a time is due", isOn: reminders) { self.reminders = $0 }
            Toggle("Play a sound with the reminder", isOn: sound) { self.sound = $0 }
            Picker("Nudge me if nothing's done by", options: Self.nudgeOptions.map(\.title), selection: Self.nudgeOptions.first { $0.hour == nudgeHour }?.title ?? "Off") { title in
                self.nudgeHour = Self.nudgeOptions.first { $0.title == title }?.hour ?? -1
            }
            Picker("Morning summary of the day", options: Self.summaryOptions.map(\.title), selection: Self.summaryOptions.first { $0.hour == summaryHour }?.title ?? "Off") { title in
                self.summaryHour = Self.summaryOptions.first { $0.title == title }?.hour ?? -1
            }
        }
        Section("Done tasks") {
            Picker("Keep done tasks for", options: Self.keepOptions.map(\.title), selection: Self.keepOptions.first { $0.days == keepDoneDays }?.title ?? "7 days") { title in
                self.keepDoneDays = Self.keepOptions.first { $0.title == title }?.days ?? 7
            }
            Button("Clear done tasks now", symbol: "trash", role: .critical) {
                self.clearDone()
                await self.save()
            }
        }
        Section("Typing dates") {
            Text("Write the when anywhere in the task: today, tonight, tomorrow, friday, next week, this weekend, in 3 days, in 2 hours, Nov 5, the 12th. Add a time with 2pm, 14:30, at 9, noon or this evening, and a repeat with every day, every weekday, every monday or monthly. A ! marks a task as important. Put words in \"quotes\" to keep them as they are. #groceries files it in your Groceries list. “Plan the offsite: book a venue; send invites” adds a task with two steps, and several lines add several tasks.").role(.secondary)
        }
    }

    var tools: [AgentTool] {
        AgentTool("tasks", description: "The user's open to-do tasks, one per line, with due date and time, repeat and importance") { _ in
            self.now = Date()
            return self.open.isEmpty ? "No open tasks" : self.open.map(self.describe).joined(separator: "\n")
        }
        AgentTool("add", description: "Adds a to-do task. Dates, times and repeats in the text are understood, like 'Call mum tomorrow 6pm' or 'Pay rent every month'", parameters: [ToolParameter("task", description: "The task as the user would type it")]) { arguments in
            let result = self.add(arguments.string("task") ?? "")
            await self.save()
            switch result {
            case .message(let text): return text ?? "Added"
            case .failure(let text): return text
            default: return "Added"
            }
        }
    }

    var commands: [Command] {
        Command("add", title: "Add a Todo", subtitle: "Dates and times in the text are understood", symbol: "plus.circle", keywords: ["todo", "task", "remind", "add", "new"]) { invocation in
            let result = self.add(invocation["task"] ?? "")
            await self.save()
            return result
        }
        .argument("task", placeholder: "Call mum tomorrow 6pm")
        // Offered under the palette's results for any text: "call mum
        // tomorrow 6pm" becomes a todo without finding the command first.
        .fallback()
        Command("complete", title: "Mark a Todo Done", symbol: "checkmark.circle", keywords: ["todo", "task", "done", "complete", "tick"]) { invocation in
            self.now = Date()
            guard let task = self.find(invocation["task"] ?? "") else { return .failure("No open task called \(invocation["task"] ?? "that")") }
            let message = self.complete(task.id)
            await self.save()
            return .message(message)
        }
        .argument("task", placeholder: "Item", options: open.prefix(20).map(\.title))
        Command("snooze", title: "Snooze a Todo", subtitle: "To a time you type, or an hour or a day later", symbol: "moon.zzz", keywords: ["todo", "task", "snooze", "later", "postpone"]) { invocation in
            self.now = Date()
            guard let task = self.find(invocation["task"] ?? "") else { return .failure("No open task called \(invocation["task"] ?? "that")") }
            let result = self.snooze(task.id, until: invocation["until"])
            await self.save()
            return result
        }
        .argument("task", placeholder: "Item", options: open.prefix(20).map(\.title))
        .argument("until", placeholder: "tomorrow 9am", required: false)
        Command("today", title: "Today's Todos", symbol: "checklist", keywords: ["todo", "task", "today", "list"])
            .view { _ in
                if self.dueToday.isEmpty {
                    ContentUnavailableView("Nothing due today", symbol: "leaf", message: "Add one with Add a Todo.")
                } else {
                    List(self.dueToday) { task in
                        Row(task.title, subtitle: self.when(task), symbol: "circle", key: task.id)
                            .action("Done") {
                                _ = self.complete(task.id)
                                await self.save()
                            }
                    }
                }
            }
    }

    // MARK: - Panel parts

    private var headline: String {
        if !dueToday.isEmpty { return dueToday.count == 1 ? "1 thing for today" : "\(dueToday.count) things for today" }
        if !doneToday.isEmpty { return "All done for today" }
        return open.isEmpty ? "A clear list" : "Nothing due today"
    }

    private var subtitle: String {
        var parts = [Self.format(now, template: "EEEEdMMMM")]
        if !overdue.isEmpty { parts.append("\(overdue.count) still on your list") }
        if dueToday.isEmpty, let next = (tomorrow + later).first { parts.append("next: \(when(next))") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func group(_ title: String, _ all: [Item]) -> ViewContent {
        let list = shown(all)
        if !list.isEmpty {
            Card(title, detail: "\(list.count)", spacing: 0, padding: Space.s) {
                ForEach(list) { task in row(task) }
            }
        }
    }

    @ViewBuilder private func row(_ task: Item) -> ViewContent {
        if editing == task.id {
            editor(task)
        } else {
            let finished = task.done != nil
            HStack(alignment: .center, spacing: Space.s) {
                Button(key: "check-\(task.id)", action: {
                    self.toggle(task.id)
                    await self.save()
                }) {
                    Image(systemName: finished ? "checkmark.circle.fill" : "circle")
                        .font(size: 17)
                        .foreground(finished ? theme.textPaint : (task.important ? theme.textPaint : .role(.secondary)))
                        .frame(width: 22, height: 22)
                }
                .hover(scale: 1.12, lift: false)
                .accessibilityLabel(finished ? "Mark \(task.title) not done" : "Mark \(task.title) done")
                Button(key: "edit-\(task.id)", action: { self.edit(task.id) }) {
                    VStack(alignment: .start, spacing: 1) {
                        if finished {
                            Text(task.title).role(.secondary).typography(.body)
                        } else {
                            Text(task.title).typography(.body)
                        }
                        if let detail = detail(task) {
                            HStack(spacing: 3) {
                                if task.repeats != nil { Image(systemName: "repeat").font(size: 9, weight: .semibold) }
                                Text(detail).typography(.caption)
                            }
                            .foreground(.role(.secondary))
                        }
                    }
                    .frame(fillWidth: true, alignment: .leading)
                }
                .accessibilityLabel(([task.title] + (detail(task).map { [$0] } ?? [])).joined(separator: ", "))
                if task.important && !finished {
                    Image(systemName: "star.fill").font(size: 10).foreground(theme.textPaint).accessibilityLabel("Important")
                }
            }
            .padding(horizontal: Space.xs, vertical: 5)
            .hover(scale: nil, highlight: .hoverWash, lift: false)
            .opacity(finished ? 0.7 : 1)
            if !finished, let step = task.nextStep {
                nextStepRow(task, step)
            }
        }
    }

    /// The step to do next, under its task, ticked right there.
    @ViewBuilder private func nextStepRow(_ task: Item, _ step: Step) -> ViewContent {
        let steps = task.steps ?? []
        HStack(alignment: .center, spacing: Space.s) {
            Button(key: "next-step-\(task.id)", action: {
                self.toggleStep(task.id, step.id)
                await self.save()
            }) {
                Image(systemName: "circle").font(size: 12).foreground(.role(.secondary)).frame(width: 22, height: 16)
            }
            .accessibilityLabel("Mark step \(step.title) done")
            Text("Next: \(step.title)").typography(.caption)
            Text(step.size.rawValue).role(.secondary).typography(.captionNumber)
            Spacer()
            Text("\(steps.filter(\.done).count) of \(steps.count)").role(.secondary).typography(.captionNumber)
        }
        .padding(EdgeInsets(top: 0, leading: 26, bottom: 4, trailing: Space.xs))
    }

    /// The task opened in place: rename (dates in the new text count),
    /// quick reschedule chips, repeat, importance and delete.
    @ViewBuilder private func editor(_ task: Item) -> ViewContent {
        VStack(alignment: .start, spacing: Space.s) {
            TextField("Item", text: task.title, key: "rename-\(task.id)") { text in
                self.rename(task.id, to: text)
                await self.save()
            }
            HStack(spacing: Space.xs) {
                ForEach(Self.quickDates) { choice in
                    Chip(choice.title, theme: theme, selected: isOn(choice, task), key: "date-\(choice.title)-\(task.id)") {
                        self.reschedule(task.id, to: choice)
                        await self.save()
                    }
                }
            }
            stepsEditor(task)
            if syncing && lists.count > 1 {
                Picker("List", options: lists.map(\.title), selection: listTitle(task.list) ?? lists.first { $0.isDefault }?.title, key: "list-\(task.id)") { title in
                    guard let list = self.lists.first(where: { $0.title == title }) else { return }
                    self.update(task.id) { $0.list = list.id }
                    await self.save()
                }
            }
            HStack(alignment: .center, spacing: Space.xs) {
                Picker("Repeat", options: ["Never"] + Repeat.allCases.map(\.rawValue), selection: task.repeats?.rawValue ?? "Never", key: "repeat-\(task.id)") { choice in
                    self.update(task.id) { $0.repeats = Repeat(rawValue: choice) }
                    await self.save()
                }
                Spacer()
                IconButton(task.important ? "star.fill" : "star", label: task.important ? "Not important" : "Important", theme: theme, prominence: task.important ? .tinted : .plain, key: "star-\(task.id)") {
                    self.update(task.id) { $0.important.toggle() }
                    await self.save()
                }
                IconButton("trash", label: "Delete", theme: .critical, key: "delete-\(task.id)") {
                    self.delete(task.id)
                    await self.save()
                }
                ActionButton("Done", theme: theme, prominent: true, key: "close-\(task.id)") {
                    self.editing = nil
                    self.breaking = nil
                }
            }
        }
        .padding(Space.s)
        .background(theme.tintPaint, in: .roundedRectangle(cornerRadius: Radius.medium))
    }

    // MARK: - Lists

    private var open: [Item] { tasks.filter { $0.done == nil }.sorted(by: Self.order) }
    private var done: [Item] { tasks.filter { $0.done != nil }.sorted { ($0.done ?? now) > ($1.done ?? now) } }

    private var calendar: Calendar { Calendar.current }
    private var startOfToday: Date { calendar.startOfDay(for: now) }
    private func days(to date: Date) -> Int {
        calendar.dateComponents([.day], from: startOfToday, to: calendar.startOfDay(for: date)).day ?? 0
    }

    private var overdue: [Item] { open.filter { $0.due.map { days(to: $0) < 0 } ?? false } }
    private var today: [Item] { open.filter { $0.due.map { days(to: $0) == 0 } ?? false } }
    private var tomorrow: [Item] { open.filter { $0.due.map { days(to: $0) == 1 } ?? false } }
    private var later: [Item] { open.filter { $0.due.map { days(to: $0) > 1 } ?? false } }
    private var someday: [Item] { open.filter { $0.due == nil } }
    private var dueToday: [Item] { overdue + today }
    private var doneToday: [Item] { done.filter { $0.done.map { days(to: $0) == 0 } ?? false } }
    private var todayTotal: Int { dueToday.count + doneToday.count }

    private func isOverdue(_ task: Item) -> Bool {
        guard let due = task.due, task.done == nil else { return false }
        return task.hasTime ? due < now : days(to: due) < 0
    }

    /// Dated first, by date; then important first; then oldest first.
    private static func order(_ a: Item, _ b: Item) -> Bool {
        switch (a.due, b.due) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default:
            if a.important != b.important { return a.important }
            return a.created < b.created
        }
    }

    // MARK: - Changes

    /// Adds what was typed. Several lines (a brain dump) add a task each;
    /// "Task: step; step" adds a task with steps; #list files it in a
    /// Reminders list.
    @discardableResult
    func add(_ text: String) -> CommandResult {
        now = Date()
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count > 1 else { return addOne(text) }
        let before = tasks
        var added = 0
        for line in lines {
            if case .message = addOne(line) { added += 1 }
        }
        guard added > 0 else { return .failure("Say what to do as well as when") }
        let message = added == 1 ? "Added 1 task" : "Added \(added) tasks"
        notice = Notice(text: message, before: before, at: now)
        return .message(message)
    }

    private func addOne(_ text: String) -> CommandResult {
        let (words, list) = takeList(text)
        let (head, stepTitles) = StepText.split(words)
        let parsed = Phrase.parse(head, now: now, calendar: calendar)
        guard !parsed.title.isEmpty else {
            return .failure(text.trimmingCharacters(in: .whitespaces).isEmpty ? "Type a task to add" : "Say what to do as well as when")
        }
        let before = tasks
        var task = Item(id: UUID().uuidString, title: parsed.title, due: parsed.due, hasTime: parsed.hasTime, repeats: parsed.repeats, important: parsed.important, created: now)
        task.list = list ?? (syncing && !listFilter.isEmpty ? listFilter : nil)
        if !stepTitles.isEmpty { task.steps = stepTitles.map { Step(title: $0) } }
        tasks.append(task)
        var message = "Added “\(task.title)”" + (task.due == nil ? "" : " for \(when(task))") + (task.repeats.map { ", repeats \($0.rawValue.lowercased())" } ?? "")
        if !stepTitles.isEmpty { message += stepTitles.count == 1 ? " with 1 step" : " with \(stepTitles.count) steps" }
        if let name = listTitle(task.list), syncing, lists.count > 1 { message += " in \(name)" }
        notice = Notice(text: message, before: before, at: now)
        return .message(message)
    }

    /// Takes a #list word naming a Reminders list (spaces and case don't
    /// matter) out of the text.
    private func takeList(_ text: String) -> (String, String?) {
        guard syncing else { return (text, nil) }
        var found: String?
        let words = text.split(separator: " ", omittingEmptySubsequences: false).filter { word in
            guard found == nil, word.hasPrefix("#"), word.count > 1 else { return true }
            let key = Self.listKey(String(word.dropFirst()))
            guard let list = lists.first(where: { Self.listKey($0.title) == key }) else { return true }
            found = list.id
            return false
        }
        return (words.joined(separator: " "), found)
    }

    static func listKey(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func listTitle(_ id: String?) -> String? {
        lists.first { $0.id == id }?.title
    }

    /// The tasks in the list the panel shows.
    private func shown(_ items: [Item]) -> [Item] {
        guard syncing, !listFilter.isEmpty, lists.contains(where: { $0.id == listFilter }) else { return items }
        let defaultList = lists.first { $0.isDefault }?.id
        return items.filter { ($0.list ?? defaultList) == listFilter }
    }

    private func toggle(_ id: String) {
        now = Date()
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        if task.done != nil {
            remember("Back on the list: “\(task.title)”")
            update(id) { $0.done = nil }
        } else {
            _ = complete(id)
        }
    }

    /// Ticks a task off. A repeating one leaves a done copy behind and moves
    /// on to its next day.
    func complete(_ id: String) -> String {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return "That task is gone" }
        let before = tasks
        var task = tasks[index]
        var message = "Done: “\(task.title)”"
        if let repeats = task.repeats {
            var record = task
            record.id = UUID().uuidString
            // A reminder of its own: the done one, while the task moves on.
            record.remote = nil
            record.external = nil
            record.repeats = nil
            record.done = now
            tasks.append(record)
            task.due = Phrase.next(after: task.due ?? now, repeats: repeats, hasTime: task.hasTime, now: now, calendar: calendar)
            task.reminded = false
            tasks[index] = task
            message += ". Next: \(when(task))"
        } else {
            tasks[index].done = now
        }
        if editing == id { editing = nil }
        notice = Notice(text: message, before: before, at: now)
        return message
    }

    func snooze(_ id: String, until text: String?) -> CommandResult {
        guard let task = tasks.first(where: { $0.id == id }) else { return .failure("That task is gone") }
        let before = tasks
        let words = text?.trimmingCharacters(in: .whitespaces) ?? ""
        if words.isEmpty {
            if task.hasTime {
                let from = max(task.due ?? now, now)
                update(id) { $0.due = from.addingTimeInterval(3600); $0.reminded = false }
            } else {
                update(id) { $0.due = self.calendar.date(byAdding: .day, value: 1, to: self.startOfToday) }
            }
        } else {
            let parsed = Phrase.parse("x " + words, now: now, calendar: calendar)
            guard let due = parsed.due else { return .failure("Stackbar didn't find a date or time in “\(words)”") }
            update(id) { $0.due = due; $0.hasTime = parsed.hasTime; $0.reminded = false }
        }
        guard let moved = tasks.first(where: { $0.id == id }) else { return .failure("That task is gone") }
        let message = "Snoozed “\(moved.title)” to \(when(moved))"
        notice = Notice(text: message, before: before, at: now)
        return .message(message)
    }

    private func edit(_ id: String) {
        editing = editing == id ? nil : id
    }

    /// New text for a task. A date in it reschedules; text without one
    /// keeps the date the task had.
    private func rename(_ id: String, to text: String) {
        now = Date()
        let parsed = Phrase.parse(text, now: now, calendar: calendar)
        guard !parsed.title.isEmpty else { return }
        update(id) { task in
            task.title = parsed.title
            if parsed.due != nil {
                task.due = parsed.due
                task.hasTime = parsed.hasTime
                task.reminded = false
            }
            if let repeats = parsed.repeats { task.repeats = repeats }
            if parsed.important { task.important = true }
        }
        editing = nil
    }

    private func reschedule(_ id: String, to choice: QuickDate) {
        now = Date()
        let before = tasks
        update(id) { task in
            guard let offset = choice.days(self.now, self.calendar) else {
                task.due = nil
                task.hasTime = false
                task.repeats = nil
                return
            }
            let day = self.calendar.date(byAdding: .day, value: offset, to: self.startOfToday) ?? self.startOfToday
            if task.hasTime, let due = task.due {
                let parts = self.calendar.dateComponents([.hour, .minute], from: due)
                task.due = self.calendar.date(bySettingHour: parts.hour ?? 9, minute: parts.minute ?? 0, second: 0, of: day)
            } else {
                task.due = day
            }
            task.reminded = false
        }
        if let task = tasks.first(where: { $0.id == id }) {
            notice = Notice(text: task.due == nil ? "“\(task.title)” moved to Someday" : "“\(task.title)” moved to \(when(task))", before: before, at: now)
        }
    }

    private func delete(_ id: String) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        remember("Deleted “\(task.title)”")
        tasks.removeAll { $0.id == id }
        editing = nil
    }

    private func clearDone() {
        let count = done.count
        guard count > 0 else { return }
        remember(count == 1 ? "Cleared 1 done task" : "Cleared \(count) done tasks")
        tasks.removeAll { $0.done != nil }
    }

    private func undo() {
        guard let before = notice?.before else { return }
        tasks = before
        notice = nil
        editing = nil
    }

    private func remember(_ text: String) {
        notice = Notice(text: text, before: tasks, at: now)
    }

    private func update(_ id: String, _ change: (inout Item) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        var task = tasks[index]
        change(&task)
        tasks[index] = task
    }

    /// An open task by id, exact title, or a title that starts with or
    /// contains the words.
    private func find(_ words: String) -> Item? {
        let key = words.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }
        let open = open
        return open.first { $0.id.lowercased() == key }
            ?? open.first { $0.title.lowercased() == key }
            ?? open.first { $0.title.lowercased().hasPrefix(key) }
            ?? open.first { $0.title.lowercased().contains(key) }
    }

    // MARK: - Reminders and upkeep

    /// A notification for each timed task that has come due. One the Mac
    /// slept through by more than half a day is let go quietly.
    private func remind() {
        var changed = tasks
        for index in changed.indices {
            let task = changed[index]
            guard task.done == nil, task.hasTime, !task.reminded, let due = task.due, due <= now else { continue }
            changed[index].reminded = true
            // Reminders alerts on every device itself, with Done and Snooze.
            guard reminders, !(syncing && task.remote != nil), now.timeIntervalSince(due) < 12 * 3600 else { continue }
            Stackbar.notify(task.title, body: task.repeats.map { "Due now · repeats \($0.rawValue.lowercased())" } ?? "Due now")
            if sound { Stackbar.play(.glass) }
        }
        if changed != tasks { tasks = changed }
    }

    /// The morning summary, once a day at the hour chosen in Settings.
    private func summarize() {
        guard summaryHour >= 0, calendar.component(.hour, from: now) >= summaryHour else { return }
        let key = Self.format(now, fixed: "yyyy-MM-dd")
        guard lastSummary != key else { return }
        lastSummary = key
        let list = dueToday
        guard !list.isEmpty else { return }
        let names = list.prefix(3).map(\.title).joined(separator: ", ") + (list.count > 3 ? " and \(list.count - 3) more" : "")
        Stackbar.notify(list.count == 1 ? "1 thing for today" : "\(list.count) things for today", body: names)
    }

    /// Forgets done tasks older than the setting.
    private func tidy() {
        guard let cutoff = calendar.date(byAdding: .day, value: -keepDoneDays, to: startOfToday) else { return }
        let old = tasks.filter { ($0.done ?? .distantFuture) < cutoff }.map(\.id)
        guard !old.isEmpty else { return }
        // Forgotten here only: Reminders keeps its completed reminders.
        tasks.removeAll { old.contains($0.id) }
        for id in old { mirror[id] = nil }
    }

    // MARK: - Words

    /// When a task is due, the way a person says it: "Today", "Tomorrow
    /// 6:00 PM", "Friday", "12 Nov".
    func when(_ task: Item) -> String {
        guard let due = task.due else { return "Someday" }
        let offset = days(to: due)
        let day: String
        switch offset {
        case 0: day = "Today"
        case 1: day = "Tomorrow"
        case -1: day = "Yesterday"
        case 2...6: day = Self.format(due, template: "EEEE")
        default: day = Self.format(due, template: calendar.component(.year, from: due) == calendar.component(.year, from: now) ? "dMMM" : "dMMMy")
        }
        return task.hasTime ? "\(day) \(Self.time(due))" : day
    }

    /// The grey line under a task's title.
    private func detail(_ task: Item) -> String? {
        var parts: [String] = []
        if let done = task.done {
            parts.append("Done " + (days(to: done) == 0 ? Self.time(done) : Self.format(done, template: "dMMM")))
        } else if let due = task.due {
            // The section already says the day; a row says the rest.
            let offset = days(to: due)
            if offset < 0 || offset > 1 { parts.append(when(task)) } else if task.hasTime { parts.append(Self.time(due)) }
        }
        if task.done == nil, let repeats = task.repeats { parts.append(repeats.rawValue) }
        if syncing, lists.count > 1, listFilter.isEmpty, let name = listTitle(task.list) { parts.append(name) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func describe(_ task: Item) -> String {
        var line = "- \(task.title)"
        var facts: [String] = []
        if let due = task.due { facts.append("due " + Self.format(due, fixed: task.hasTime ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd")) }
        if let repeats = task.repeats { facts.append("repeats " + repeats.rawValue.lowercased()) }
        if task.important { facts.append("important") }
        if isOverdue(task) { facts.append("overdue") }
        if let steps = task.steps, !steps.isEmpty { facts.append("\(steps.filter(\.done).count) of \(steps.count) steps done") }
        if let list = lists.first(where: { $0.id == task.list }), !list.isDefault { facts.append("list \(list.title)") }
        if !facts.isEmpty { line += " (" + facts.joined(separator: ", ") + ")" }
        return line
    }

    static func time(_ date: Date) -> String { format(date, template: "jmm") }

    static func format(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    static func format(_ date: Date, fixed: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = fixed
        return formatter.string(from: date)
    }

    static func clip(_ text: String, _ length: Int) -> String {
        text.count > length ? String(text.prefix(length - 1)) + "…" : text
    }

    // MARK: - Choices

    struct QuickDate: Identifiable {
        var title: String
        /// Days from today, or nil for no date.
        var days: (Date, Calendar) -> Int?
        var id: String { title }
    }

    static let quickDates: [QuickDate] = [
        QuickDate(title: "Today") { _, _ in 0 },
        QuickDate(title: "Tomorrow") { _, _ in 1 },
        QuickDate(title: "Weekend") { now, calendar in
            let weekday = calendar.component(.weekday, from: now)
            return weekday == 7 || weekday == 1 ? 0 : 7 - weekday
        },
        QuickDate(title: "Next week") { now, calendar in
            let weekday = calendar.component(.weekday, from: now)
            return (9 - weekday - 1) % 7 + 1
        },
        QuickDate(title: "Someday") { _, _ in nil },
    ]

    private func isOn(_ choice: QuickDate, _ task: Item) -> Bool {
        guard let due = task.due else { return choice.title == "Someday" }
        guard let offset = choice.days(now, calendar) else { return false }
        return days(to: due) == offset
    }

    static let summaryOptions: [(title: String, hour: Int)] = [("Off", -1), ("7 AM", 7), ("8 AM", 8), ("9 AM", 9), ("10 AM", 10)]
    static let keepOptions: [(title: String, days: Int)] = [("1 day", 1), ("7 days", 7), ("30 days", 30)]
    static let nudgeOptions: [(title: String, hour: Int)] = [("Off", -1), ("11 AM", 11), ("1 PM", 13), ("3 PM", 15), ("5 PM", 17)]
}

// MARK: - Model

struct Item: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var due: Date?
    /// Whether `due` has a time of day, or only a day.
    var hasTime: Bool
    var repeats: Repeat?
    var important: Bool
    var created: Date
    var done: Date?
    /// The reminder for the current `due` has gone out.
    var reminded = false
    /// The Reminders list, or nil for the default one (or no Reminders).
    var list: String?
    /// The reminder this task is, once it has been saved to Reminders.
    var remote: String?
    var external: String?
    /// The reminder's own notes, without the steps.
    var notes: String?
    var steps: [Step]?

    /// The step to do next: small ones first, then medium, then big, in
    /// the order they were added.
    var nextStep: Step? {
        let open = (steps ?? []).filter { !$0.done }
        return open.first { $0.size == .small } ?? open.first { $0.size == .medium } ?? open.first
    }

    init(id: String, title: String, due: Date?, hasTime: Bool, repeats: Repeat?, important: Bool, created: Date) {
        self.id = id
        self.title = title
        self.due = due
        self.hasTime = hasTime
        self.repeats = repeats
        self.important = important
        self.created = created
    }
}

enum Repeat: String, Codable, CaseIterable {
    case daily = "Daily", weekdays = "Weekdays", weekly = "Weekly", monthly = "Monthly", yearly = "Yearly"
}

/// One piece of a task broken down. Small, medium or big, like Little
/// Things' sizes, so the next thing to do can be a small one.
struct Step: Codable, Equatable, Identifiable {
    enum Size: String, Codable, CaseIterable {
        case small = "S", medium = "M", big = "B"

        var next: Size {
            switch self {
            case .small: return .medium
            case .medium: return .big
            case .big: return .small
            }
        }
    }

    var id: String
    var title: String
    var size: Size
    var done: Bool

    init(id: String = UUID().uuidString, title: String, size: Size = .small, done: Bool = false) {
        self.id = id
        self.title = title
        self.size = size
        self.done = done
    }
}

// MARK: - Understanding dates in what the user types

/// Turns "Call the dentist tomorrow at 2pm" into a title and a due date.
/// Each phrase it understands is taken out of the title; anything in double
/// quotes is left alone.
enum Phrase {
    struct Parsed: Equatable {
        var title: String
        var due: Date?
        var hasTime = false
        var repeats: Repeat?
        var important = false
    }

    static let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    static let fullWeekday = "(sunday|monday|tuesday|wednesday|thursday|friday|saturday)"
    static let shortWeekday = "(sun|mon|tues?|wed|thu(?:rs?)?|fri|sat)"
    static let month = "(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"
    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    static let lead = #"(?:\b(?:on|by|due|for)\s+)?"#
    static let numbers = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30, "forty-five": 45]

    static func parse(_ input: String, now: Date, calendar: Calendar) -> Parsed {
        var result = Parsed(title: "")
        // Quoted words are kept as written: swap them out while parsing.
        var kept: [String] = []
        var text = ""
        let pieces = input.components(separatedBy: "\"")
        for (index, piece) in pieces.enumerated() {
            if index % 2 == 1 && index < pieces.count - 1 {
                text += " \u{E000}" + String(repeating: "q", count: kept.count + 1) + "\u{E001} "
                kept.append(piece)
            } else {
                text += piece
            }
        }
        text = " " + text + " "

        /// Takes the first match of `pattern` out of the text and returns
        /// its groups ("" for a group that did not take part).
        func take(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let string = text as NSString
            guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: string.length)) else { return nil }
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : string.substring(with: range).lowercased()
            }
            text = string.replacingCharacters(in: match.range, with: " ")
            return groups
        }

        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today) ?? today }
        func weekdayIndex(_ name: String) -> Int {
            (weekdayNames.firstIndex { $0.hasPrefix(String(name.prefix(3))) } ?? 0) + 1
        }
        /// The next `weekday` (1 is Sunday) after today, or from today on.
        func upcoming(_ weekday: Int, includingToday: Bool) -> Date {
            let current = calendar.component(.weekday, from: today)
            var offset = (weekday - current + 7) % 7
            if offset == 0 && !includingToday { offset = 7 }
            return day(offset)
        }
        func count(_ word: String) -> Int? { Int(word) ?? numbers[word] }

        var date: Date?
        var exact: Date?
        var hour: Int?
        var minute = 0

        if take(#"(?:^|\s)!{1,3}(?=\s|$)"#) != nil { result.important = true }

        // Repeats.
        if let groups = take(#"\bevery\s+(day|night|morning|evening|weekday|week|month|year|\#(fullWeekday)|\#(shortWeekday))\b"#) {
            switch groups[1] {
            case "day": result.repeats = .daily
            case "night": result.repeats = .daily; hour = 21
            case "morning": result.repeats = .daily; hour = 9
            case "evening": result.repeats = .daily; hour = 18
            case "weekday": result.repeats = .weekdays
            case "week": result.repeats = .weekly
            case "month": result.repeats = .monthly
            case "year": result.repeats = .yearly
            default:
                result.repeats = .weekly
                date = upcoming(weekdayIndex(groups[1]), includingToday: true)
            }
        } else if let groups = take(#"\b(daily|weekly|monthly|yearly|annually)\b"#) {
            result.repeats = ["daily": .daily, "weekly": .weekly, "monthly": .monthly][groups[1]] ?? .yearly
        }

        // In a while.
        if take(#"\bin\s+half\s+an?\s+hour\b"#) != nil {
            exact = now.addingTimeInterval(1800)
        } else if let groups = take(#"\bin\s+(\d+|an?|one|two|three|four|five|six|seven|eight|nine|ten|fifteen|twenty|thirty|forty-five)\s*(minutes?|mins?|hours?|hrs?|h|days?|weeks?|months?)\b"#),
                  let amount = count(groups[1]) {
            switch groups[2].prefix(1) {
            case "m" where groups[2].hasPrefix("mi"): exact = now.addingTimeInterval(Double(amount) * 60)
            case "h": exact = now.addingTimeInterval(Double(amount) * 3600)
            case "d": date = day(amount)
            case "w": date = day(amount * 7)
            default: date = calendar.date(byAdding: .month, value: amount, to: today)
            }
        }

        // Calendar dates.
        if date == nil, let groups = take(#"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#) {
            date = calendar.date(from: DateComponents(year: Int(groups[1]), month: Int(groups[2]), day: Int(groups[3])))
        }
        func monthDay(_ monthName: String, _ dayText: String, _ yearText: String) -> Date? {
            guard let monthNumber = months.firstIndex(of: String(monthName.prefix(3))).map({ $0 + 1 }), let dayNumber = Int(dayText), (1...31).contains(dayNumber) else { return nil }
            if let year = Int(yearText) { return calendar.date(from: DateComponents(year: year, month: monthNumber, day: dayNumber)) }
            let year = calendar.component(.year, from: today)
            guard let candidate = calendar.date(from: DateComponents(year: year, month: monthNumber, day: dayNumber)) else { return nil }
            return candidate < today ? calendar.date(byAdding: .year, value: 1, to: candidate) : candidate
        }
        if date == nil, let groups = take(lead + #"\b"# + month + #"\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b(?:,?\s+(\d{4})\b)?"#) {
            date = monthDay(groups[1], groups[2], groups[3])
        }
        if date == nil, let groups = take(lead + #"\b(?:the\s+)?(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?"# + month + #"\b(?:,?\s+(\d{4})\b)?"#) {
            date = monthDay(groups[2], groups[1], groups[3])
        }
        if date == nil, let groups = take(lead + #"\bthe\s+(\d{1,2})(?:st|nd|rd|th)\b"#), let dayNumber = Int(groups[1]), (1...31).contains(dayNumber) {
            var parts = calendar.dateComponents([.year, .month], from: today)
            parts.day = dayNumber
            if let candidate = calendar.date(from: parts) {
                date = candidate < today ? calendar.date(byAdding: .month, value: 1, to: candidate) : candidate
            }
        }

        // Day words.
        if date == nil {
            if take(lead + #"\b(?:the\s+)?day\s+after\s+tomorrow\b"#) != nil {
                date = day(2)
            } else if take(lead + #"\b(?:tomorrow|tmrw|tmr|tmw)\b"#) != nil {
                date = day(1)
            } else if take(lead + #"\btoday\b"#) != nil {
                date = today
            } else if take(#"\btonight\b"#) != nil {
                date = today
                hour = hour ?? 20
            } else if let groups = take(lead + #"\b(this\s+|next\s+)?weekend\b"#) {
                let saturday = upcoming(7, includingToday: true)
                let weekday = calendar.component(.weekday, from: today)
                date = groups[1].hasPrefix("next") && weekday != 1 ? calendar.date(byAdding: .day, value: 7, to: saturday) : (weekday == 1 ? today : saturday)
            } else if take(lead + #"\bnext\s+week\b"#) != nil {
                date = upcoming(2, includingToday: false)
            } else if take(lead + #"\bnext\s+month\b"#) != nil {
                var parts = calendar.dateComponents([.year, .month], from: today)
                parts.day = 1
                date = calendar.date(from: parts).flatMap { calendar.date(byAdding: .month, value: 1, to: $0) }
            } else if let groups = take(lead + #"\b(this\s+|next\s+)?"# + fullWeekday + #"\b"#) ?? take(lead + #"\b(this\s+|next\s+|on\s+)"# + shortWeekday + #"\b"#) {
                let weekday = weekdayIndex(groups[2])
                if groups[1].hasPrefix("next") {
                    // In the week after this one (weeks start on Monday).
                    let monday = upcoming(2, includingToday: false)
                    let offset = (weekday - 2 + 7) % 7
                    date = calendar.date(byAdding: .day, value: offset, to: monday)
                } else {
                    date = upcoming(weekday, includingToday: groups[1].hasPrefix("this"))
                }
            }
        }

        // Times of day.
        if exact == nil {
            if let groups = take(#"(?:(?:\bat|\bby|@)\s*)?\b(\d{1,2})(?:[:.](\d{2}))?\s*([ap])\.?m\.?(?=\W|$)"#), let value = Int(groups[1]), (1...12).contains(value) {
                hour = value % 12 + (groups[3] == "p" ? 12 : 0)
                minute = Int(groups[2]) ?? 0
            } else if let groups = take(#"(?:(?:\bat|\bby|@)\s*)?\b([01]?\d|2[0-3]):([0-5]\d)\b"#) {
                // "3:30" is half past three in the afternoon; "03:30" is not.
                let value = Int(groups[1]) ?? 0
                hour = groups[1].count == 1 && (1...6).contains(value) ? value + 12 : value
                minute = Int(groups[2]) ?? 0
            } else if let groups = take(#"(?:\bat|@)\s*(\d{1,2})\b(?![:.]?\d|\s*(?:%|st|nd|rd|th|minutes?|mins?|hours?|days?))"#), let value = Int(groups[1]), (0...23).contains(value) {
                hour = (1...6).contains(value) ? value + 12 : value
            } else if let groups = take(#"(?:\bat\s+)?\b(noon|midday)\b"#), !groups.isEmpty {
                hour = 12
            } else if let groups = take(#"\b(?:this\s+|in\s+the\s+)?(morning|afternoon|evening)\b"#) {
                hour = ["morning": 9, "afternoon": 14][groups[1]] ?? 18
            }
        }

        if let exact {
            result.due = exact
            result.hasTime = true
        } else if let hour {
            var base = date ?? today
            var due = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
            if date == nil && due <= now {
                // A time already gone today means the next one.
                base = result.repeats == .weekdays ? nextWeekday(after: today, calendar: calendar) : day(1)
                due = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
            }
            result.due = due
            result.hasTime = true
        } else if let date {
            result.due = date
        } else if let repeats = result.repeats {
            result.due = repeats == .weekdays && calendar.isDateInWeekend(today) ? nextWeekday(after: today, calendar: calendar) : today
        }
        if result.repeats == .weekdays, let due = result.due, calendar.isDateInWeekend(due) {
            result.due = nextWeekday(after: due, calendar: calendar)
        }

        // What is left is the title.
        var title = text
        for (index, piece) in kept.enumerated() {
            title = title.replacingOccurrences(of: "\u{E000}" + String(repeating: "q", count: index + 1) + "\u{E001}", with: piece)
        }
        var words = title.split(whereSeparator: \.isWhitespace).map(String.init)
        let dangling: Set<String> = ["at", "on", "by", "due", "in", "every", "this", "next", "the", "-", "–", "—", ",", "@"]
        while let last = words.last, dangling.contains(last.lowercased()) { words.removeLast() }
        while let first = words.first, ["-", "–", "—", ",", ":"].contains(first) { words.removeFirst() }
        result.title = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—"))
        return result
    }

    static func nextWeekday(after date: Date, calendar: Calendar) -> Date {
        var day = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        while calendar.isDateInWeekend(day) { day = calendar.date(byAdding: .day, value: 1, to: day) ?? day }
        return day
    }

    /// The next time a repeating task is due once it is done: past both its
    /// current date and now.
    static func next(after due: Date, repeats: Repeat, hasTime: Bool, now: Date, calendar: Calendar) -> Date {
        var date = due
        let floor = hasTime ? now : calendar.startOfDay(for: now)
        repeat {
            switch repeats {
            case .daily: date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            case .weekdays: date = nextWeekday(after: date, calendar: calendar)
            case .weekly: date = calendar.date(byAdding: .day, value: 7, to: date) ?? date
            case .monthly: date = calendar.date(byAdding: .month, value: 1, to: date) ?? date
            case .yearly: date = calendar.date(byAdding: .year, value: 1, to: date) ?? date
            }
        } while date <= floor
        return date
    }
}

// MARK: - Reminders

extension Todo {
    /// What Settings says about where tasks are.
    var storageNote: String {
        guard storage == Storage.reminders.rawValue else {
            return "Tasks stay on this Mac. Choose Reminders to have them on your iPhone, iPad and Watch too."
        }
        switch access {
        case .granted?:
            if let syncProblem { return "Reminders didn't take the last change: \(syncProblem)" }
            let names = lists.map(\.title)
            return "Tasks are in Reminders, so they're on your iPhone, iPad and Watch too. Lists: " + (names.isEmpty ? "none yet" : names.joined(separator: ", ")) + ". Type #listname in a task to file it."
        case .denied?:
            return "Stackbar isn't allowed to use Reminders, so tasks stay on this Mac. Allow it in System Settings › Privacy & Security › Reminders."
        case .unavailable?:
            return "Reminders isn't available here, so tasks stay on this Mac."
        case .notDetermined?, nil:
            return "Stackbar asks macOS for Reminders access the first time it's needed."
        }
    }

    /// Sends this Mac's changes to Reminders, then takes in what changed
    /// there (on any device). Local changes always go first, so nothing
    /// typed here is overwritten by an older copy.
    func sync() async {
        guard storage == Storage.reminders.rawValue else {
            access = nil
            return
        }
        access = (try? await Stackbar.reminderAccess(ask: true)) ?? .unavailable
        guard access == .granted else { return }
        do {
            lists = try await Stackbar.reminderLists()
            // A task Reminders refuses doesn't stop what others sent or
            // changed from arriving.
            var pushFailure: Error?
            do { try await push() } catch { pushFailure = error }
            try await pull()
            syncProblem = pushFailure.map { "\($0)" }
        } catch {
            syncProblem = "\(error)"
        }
    }

    /// After a change made here: send it to Reminders now.
    func save() async {
        guard syncing else { return }
        do {
            try await push()
            syncProblem = nil
        } catch {
            syncProblem = "\(error)"
        }
    }

    /// Adds new tasks to Reminders, writes the fields that changed since the
    /// last sync, and deletes what was deleted here.
    private func push() async throws {
        let alarms = reminders
        var current = tasks
        var known = mirror
        var failure: Error?
        unpushed = []
        for index in current.indices {
            let task = current[index]
            let wanted = task.reminder(alarms: alarms)
            do {
                if task.remote == nil {
                    let saved = try await Stackbar.saveReminder(wanted)
                    current[index].attach(saved)
                } else if let before = known[task.id] {
                    let fields = Item.changes(from: before.reminder(alarms: alarms), to: wanted)
                    guard !fields.isEmpty else { continue }
                    do {
                        let saved = try await Stackbar.saveReminder(wanted, fields: fields)
                        current[index].attach(saved)
                    } catch where "\(error)".contains("deleted") {
                        // Gone from Reminders (an Undo after a delete): add it again.
                        var fresh = wanted
                        fresh.id = ""
                        let saved = try await Stackbar.saveReminder(fresh)
                        current[index].attach(saved)
                    }
                } else {
                    // Never seen in Reminders by this copy: the pull decides.
                    continue
                }
                known[task.id] = current[index]
            } catch {
                // Keep going: what was saved so far must be remembered below,
                // or the next sync would add those tasks to Reminders again.
                failure = failure ?? error
                unpushed.insert(task.id)
            }
        }
        let ids = Set(current.map(\.id))
        for (id, before) in known where !ids.contains(id) {
            if let remote = before.remote {
                do {
                    try await Stackbar.deleteReminder(id: remote)
                } catch where !"\(error)".contains("deleted") {
                    // Still in Reminders: stay in the mirror, so the next
                    // sync deletes it again and the pull doesn't bring it back.
                    let count = (deleteFailures[id] ?? 0) + 1
                    if count < Self.deleteAttempts {
                        deleteFailures[id] = count
                        failure = failure ?? error
                        continue
                    }
                    // It can't be deleted: stop retrying, and say so once.
                    deleteFailures[id] = nil
                    notice = Notice(text: "Couldn't delete “\(before.title)” from Reminders after \(Self.deleteAttempts) tries (\(error)); it may reappear.", before: nil, at: Date())
                } catch {}
            }
            deleteFailures[id] = nil
            known[id] = nil
        }
        if current != tasks { tasks = current }
        if known != mirror { mirror = known }
        if let failure { throw failure }
    }

    /// Takes in Reminders as it is: changes from other devices win (this
    /// Mac's own went out just before), new reminders join, and deleted ones
    /// leave.
    private func pull() async throws {
        let cutoff = calendar.date(byAdding: .day, value: -keepDoneDays, to: startOfToday) ?? startOfToday
        let remote = try await Stackbar.reminders(completedSince: cutoff)
        var byID: [String: Reminder] = [:]
        for reminder in remote where byID[reminder.id] == nil { byID[reminder.id] = reminder }
        var idByExternal: [String: String] = [:]
        for reminder in remote { if let external = reminder.externalID, idByExternal[external] == nil { idByExternal[external] = reminder.id } }

        // Tasks deleted here whose reminder is still there (the delete
        // failed): the pull must neither bring them back nor forget them.
        let localIDs = Set(tasks.map(\.id))
        let pendingDeletes = mirror.filter { !localIDs.contains($0.key) }
        for pending in pendingDeletes.values {
            if let id = pending.remote { byID[id] = nil }
            if let id = pending.external.flatMap({ idByExternal[$0] }) { byID[id] = nil }
        }

        var result: [Item] = []
        for var task in tasks {
            guard let id = task.remote else {
                result.append(task)
                continue
            }
            // The id can change after a full iCloud resync; the external id
            // usually doesn't.
            let match = byID.removeValue(forKey: id) ?? task.external.flatMap { idByExternal[$0] }.flatMap { byID.removeValue(forKey: $0) }
            if let match {
                // A local edit that failed to go out stays; Reminders' copy
                // is older than it.
                if !unpushed.contains(task.id) { task.adopt(match) }
                result.append(task)
            } else if let done = task.done, done < cutoff {
                result.append(task)
            }
            // Otherwise it was deleted in Reminders.
        }
        for reminder in remote where byID[reminder.id] != nil {
            var task = Item(id: UUID().uuidString, title: reminder.title, due: nil, hasTime: false, repeats: nil, important: false, created: reminder.modified ?? now)
            task.adopt(reminder)
            // A timed reminder that's already due has already alerted.
            if let due = task.due, due <= now { task.reminded = true }
            result.append(task)
        }
        if result != tasks { tasks = result }
        var known = Dictionary(result.filter { $0.remote != nil }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        known.merge(pendingDeletes) { current, _ in current }
        // Keep measuring an unpushed edit against what Reminders last had.
        for id in unpushed { known[id] = mirror[id] }
        if known != mirror { mirror = known }
    }

    // MARK: Steps

    /// The steps under a task in its editor: tick, size, remove, and a field
    /// to add more.
    @ViewBuilder func stepsEditor(_ task: Item) -> ViewContent {
        let steps = task.steps ?? []
        if steps.isEmpty && breaking != task.id {
            ActionButton("Break into steps", symbol: "list.bullet.indent", theme: theme, key: "break-\(task.id)") { self.breaking = task.id }
        } else {
            VStack(alignment: .start, spacing: 2) {
                ForEach(steps) { step in
                    HStack(alignment: .center, spacing: Space.xs) {
                        Button(key: "step-\(task.id)-\(step.id)", action: {
                            self.toggleStep(task.id, step.id)
                            await self.save()
                        }) {
                            Image(systemName: step.done ? "checkmark.circle.fill" : "circle").font(size: 13).foreground(step.done ? theme.textPaint : .role(.secondary))
                        }
                        .accessibilityLabel(step.done ? "Mark step \(step.title) not done" : "Mark step \(step.title) done")
                        if step.done {
                            Text(step.title).role(.secondary).typography(.body)
                        } else {
                            Text(step.title).typography(.body)
                        }
                        Spacer()
                        Chip(step.size.rawValue, theme: theme, selected: step.size != .small, key: "size-\(task.id)-\(step.id)") {
                            self.updateStep(task.id, step.id) { $0.size = $0.size.next }
                            await self.save()
                        }
                        IconButton("xmark", label: "Remove step", theme: theme, size: 22, key: "remove-step-\(task.id)-\(step.id)") {
                            self.update(task.id) { item in
                                item.steps?.removeAll { $0.id == step.id }
                                if item.steps?.isEmpty == true { item.steps = nil }
                            }
                            await self.save()
                        }
                    }
                }
                TextField("Add a step, then Return", text: "", key: "add-step-\(task.id)") { text in
                    self.addStep(task.id, text)
                    await self.save()
                }
                Text("S, M and B are a step's size: tap to change it.").role(.secondary).typography(.caption)
            }
        }
    }

    func addStep(_ id: String, _ text: String) {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        breaking = id
        update(id) { task in
            task.steps = (task.steps ?? []) + title.split(separator: ";").map { Step(title: $0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.title.isEmpty }
        }
    }

    /// Ticks a step (or unticks it). Ticking the last one finishes the task.
    func toggleStep(_ id: String, _ stepID: String) {
        now = Date()
        guard let task = tasks.first(where: { $0.id == id }), let step = task.steps?.first(where: { $0.id == stepID }) else { return }
        let before = tasks
        updateStep(id, stepID) { $0.done.toggle() }
        guard !step.done, let steps = tasks.first(where: { $0.id == id })?.steps, steps.allSatisfy(\.done), task.done == nil else {
            notice = Notice(text: step.done ? "Back on the list: “\(step.title)”" : "Done: “\(step.title)”", before: before, at: now)
            return
        }
        _ = complete(id)
        notice?.before = before
    }

    private func updateStep(_ id: String, _ stepID: String, _ change: (inout Step) -> Void) {
        update(id) { task in
            guard let index = task.steps?.firstIndex(where: { $0.id == stepID }) else { return }
            change(&task.steps![index])
        }
    }

    // MARK: Nudge

    /// One gentle nudge at the chosen hour, only on a day nothing has been
    /// ticked off yet, naming the smallest thing to start with.
    func nudge() {
        guard nudgeHour >= 0, calendar.component(.hour, from: now) >= nudgeHour else { return }
        let key = Self.format(now, fixed: "yyyy-MM-dd")
        guard lastNudge != key else { return }
        lastNudge = key
        guard doneToday.isEmpty, let start = smallestStart else { return }
        Stackbar.notify("One small thing?", body: start)
    }

    /// The smallest next step among today's tasks, or the first task.
    private var smallestStart: String? {
        let candidates = dueToday.isEmpty ? open : dueToday
        if let task = candidates.first(where: { $0.nextStep?.size == .small }), let step = task.nextStep {
            return "\(step.title) (for “\(task.title)”)"
        }
        return candidates.first.map { task in task.nextStep.map { "\($0.title) (for “\(task.title)”)" } ?? task.title }
    }
}

// MARK: - Tasks as reminders

extension Item {
    /// The task as a reminder: steps go at the end of the notes as a
    /// checklist, so they're visible on the iPhone too.
    func reminder(alarms: Bool) -> Reminder {
        Reminder(
            id: remote ?? "",
            externalID: external,
            list: list ?? "",
            title: title,
            notes: StepText.notes(notes, steps: steps ?? []),
            due: due,
            dueHasTime: due != nil && hasTime,
            priority: important ? .high : .none,
            completed: done,
            recurrence: repeats?.recurrence,
            alarm: alarms && hasTime ? due : nil
        )
    }

    /// Fields that differ between two versions of a reminder.
    static func changes(from old: Reminder, to new: Reminder) -> [Reminder.Field] {
        Reminder.Field.allCases.filter { field in
            switch field {
            case .list: return old.list != new.list
            case .title: return old.title != new.title
            case .notes: return old.notes != new.notes
            case .due: return old.due != new.due || old.dueHasTime != new.dueHasTime
            case .priority: return old.priority != new.priority
            case .completed: return old.completed != new.completed
            case .recurrence: return old.recurrence != new.recurrence
            case .alarm: return old.alarm != new.alarm
            case .url: return false
            }
        }
    }

    /// Remembers which reminder this task is, after a save.
    mutating func attach(_ saved: Reminder) {
        remote = saved.id
        external = saved.externalID
        list = saved.list.isEmpty ? list : saved.list
    }

    /// Takes the reminder's values, as Reminders has them now.
    mutating func adopt(_ reminder: Reminder) {
        attach(reminder)
        if due != reminder.due || hasTime != reminder.dueHasTime { reminded = false }
        title = reminder.title
        due = reminder.due
        hasTime = reminder.due != nil && reminder.dueHasTime
        if reminder.recurrence != repeats?.recurrence { repeats = reminder.recurrence.flatMap(Repeat.init) }
        if (reminder.priority == .high) != important { important = reminder.priority == .high }
        done = reminder.completed
        let parts = StepText.parse(reminder.notes)
        notes = parts.notes
        let old = steps ?? []
        let merged = parts.steps.map { line -> Step in
            var step = old.first { $0.title == line.title } ?? Step(title: line.title)
            step.done = line.done
            return step
        }
        steps = merged.isEmpty ? nil : merged
    }
}

extension Repeat {
    var recurrence: ReminderRecurrence {
        switch self {
        case .daily: return ReminderRecurrence(.daily)
        case .weekdays: return .weekdays
        case .weekly: return ReminderRecurrence(.weekly)
        case .monthly: return ReminderRecurrence(.monthly)
        case .yearly: return ReminderRecurrence(.yearly)
        }
    }

    /// The repeat a reminder's recurrence means, when Todo has one like it.
    init?(_ recurrence: ReminderRecurrence) {
        guard recurrence.interval == 1 else { return nil }
        switch recurrence.frequency {
        case .daily: self = .daily
        case .weekly: self = recurrence.weekdays.sorted() == [2, 3, 4, 5, 6] ? .weekdays : .weekly
        case .monthly: self = .monthly
        case .yearly: self = .yearly
        }
    }
}

/// Steps in words: typed after a colon ("Plan the offsite: book a venue;
/// send invites") and kept at the end of a reminder's notes as a checklist.
enum StepText {
    static let open = "☐ "
    static let done = "☑ "

    /// "Task: a; b" into the task and its steps. Needs a semicolon, so
    /// "Call: mum" stays one task.
    static func split(_ text: String) -> (String, [String]) {
        guard let colon = text.range(of: ": "), text[colon.upperBound...].contains(";") else { return (text, []) }
        let steps = text[colon.upperBound...].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (String(text[..<colon.lowerBound]), steps)
    }

    static func notes(_ notes: String?, steps: [Step]) -> String? {
        let text = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let list = steps.map { ($0.done ? done : open) + $0.title }.joined(separator: "\n")
        let joined = [text, list].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }

    static func parse(_ notes: String?) -> (notes: String?, steps: [(title: String, done: Bool)]) {
        var text: [String] = []
        var steps: [(String, Bool)] = []
        for line in (notes ?? "").components(separatedBy: "\n") {
            if line.hasPrefix(open) {
                steps.append((String(line.dropFirst(open.count)), false))
            } else if line.hasPrefix(done) {
                steps.append((String(line.dropFirst(done.count)), true))
            } else {
                text.append(line)
            }
        }
        let rest = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (rest.isEmpty ? nil : rest, steps)
    }
}
