import StackbarKit
import Foundation

/// Keeps the Mac awake: for a while, until a time, while an app runs, on a
/// weekday schedule, or until you say stop. It lets go when the battery runs
/// low, and the host releases the assertion if the plugin ever stops or
/// crashes, so it can't leave the Mac awake by accident.
@main
final class StayAwake: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.stay-awake",
        name: "Stay Awake",
        version: "1.4.0",
        summary: "Keeps your Mac awake for a while, until a time, while an app runs or on a schedule.",
        surfaces: [.menuBar, .panel, .widget, .settings],
        triggers: [.launch, .every(.seconds(15)), .wake],
        capabilities: [.power],
        minimumStackbar: "0.17.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/System/StayAwake",
        accent: .amber,
        symbol: "cup.and.saucer.fill"
    )

    // MARK: Previews

    static let previews: [PreviewScene<StayAwake>] = [
        PreviewScene("hero", "Awake for the next hour, then back to normal") { plugin in
            let now = Date()
            plugin.session = Session(mode: .until(now.addingTimeInterval(75 * 60)), started: now.addingTimeInterval(-45 * 60))
            plugin.awakeByDay = sampleWeek(now: now)
            plugin.batteryTrail = [0.92, 0.91, 0.9, 0.88, 0.87, 0.86, 0.85, 0.83, 0.82, 0.81]
            try await plugin.refresh()
        },
        PreviewScene("while-app", "Awake while your build runs") { plugin in
            let now = Date()
            plugin.session = Session(mode: .whileRunning(appID: "com.apple.dt.Xcode", name: "Xcode"), started: now.addingTimeInterval(-20 * 60))
            plugin.awakeByDay = sampleWeek(now: now)
            try await plugin.refresh()
        },
        PreviewScene("widget", "Your Mac's sleep state on the desktop", surface: .widget) { plugin in
            let now = Date()
            plugin.session = Session(mode: .until(now.addingTimeInterval(75 * 60)), started: now.addingTimeInterval(-45 * 60))
            plugin.awakeByDay = sampleWeek(now: now)
            try await plugin.refresh()
        },
    ]

    /// Seconds kept awake on each of the last seven days.
    static func sampleWeek(now: Date) -> [String: Double] {
        let hours = [2.5, 4, 1.5, 6, 3, 0.5, 2]
        return Dictionary(uniqueKeysWithValues: hours.enumerated().map { offset, value in
            (day(now.addingTimeInterval(Double(offset - 6) * 86400)), value * 3600)
        })
    }

    /// What the current session waits for before it ends.
    enum Mode: Codable, Equatable {
        case indefinitely
        case until(Date)
        case whileRunning(appID: String, name: String)
    }

    struct Session: Codable, Equatable {
        var mode: Mode
        var started: Date
        var total: Double? {
            if case .until(let end) = mode { return end.timeIntervalSince(started) }
            return nil
        }
    }

    static let durations: [(title: String, minutes: Double)] = [("15 min", 15), ("30 min", 30), ("1 hour", 60), ("2 hours", 120), ("4 hours", 240), ("8 hours", 480)]

    @Stored("session") var session: Session? = nil
    @Stored("keepDisplayOn") var keepDisplayOn = true
    @Stored("batteryFloor") var batteryFloor = 20.0
    @Stored("pauseOnLowPower") var pauseOnLowPower = true
    @Stored("notifyOnEnd") var notifyOnEnd = true
    @Stored("scheduleOn") var scheduleOn = false
    @Stored("whilePluggedIn") var whilePluggedIn = false
    @Stored("whileExternalDisplay") var whileExternalDisplay = false
    @Stored("whileVPN") var whileVPN = false
    @Stored("whileDownloading") var whileDownloading = false
    /// What a click on the menu-bar cup does: -1 opens the panel, 0 starts
    /// until stopped, otherwise starts for that many minutes. Clicking again
    /// stops; a right click always opens the panel.
    @Stored("clickMinutes") var clickMinutes = 0.0
    /// Shows the time left as digits next to the cup during a timed session.
    @Stored("showTimeLeft") var showTimeLeft = true
    @Stored("scheduleStart") var scheduleStart = "09:00"
    @Stored("scheduleEnd") var scheduleEnd = "18:00"
    @Stored("scheduleWeekdaysOnly") var scheduleWeekdaysOnly = true
    /// Seconds awake per day (yyyy-MM-dd), for the last two weeks.
    @Stored("awakeByDay") var awakeByDay: [String: Double] = [:]
    /// The automatic rules (plugged in, schedule and so on) hold off until then.
    @Stored("pausedUntil") var pausedUntil: Date? = nil

    var status = SystemStatus()
    /// What the host is holding for us right now. The host drops it when the
    /// helper restarts, so this starts empty and the first refresh re-asserts.
    var held: KeepAwakeRequest?
    var heldReason: String?
    var lastTick: Date?
    var lastError: String?
    /// A duration or time typed in the panel that didn't parse, shown under the field.
    var inputError: String?
    /// A schedule time typed in Settings that didn't parse, shown there.
    var settingsError: String?
    var lastEnded: String?
    /// The end time the 5-minute warning was sent for.
    var warnedFor: Date?
    /// Battery percentage once a minute while awake, for the session chart.
    var batteryTrail: [Double] = []
    var lastSample: Date?
    /// The last network counter reading, for the download rate.
    var lastBytes: (count: UInt64, at: Date)?
    /// Bytes per second received, one sample per refresh (about 10 minutes).
    var rateTrail: [Double] = []
    /// A download keeps the Mac awake until this long after it goes quiet,
    /// so a pause between files doesn't let it sleep.
    var downloadUntil: Date?
    static let downloadThreshold = 100_000.0
    static let downloadGrace = 120.0

    // MARK: Deciding

    func refresh() async throws {
        do {
            status = try await Stackbar.systemStatus()
        } catch {
            lastError = "\(error)"
        }
        endSessionIfDone()
        sampleNetwork()
        await apply()
    }

    /// Turns the host's byte counter into a rate and decides whether a
    /// download is running.
    func sampleNetwork(now: Date = Date()) {
        guard let count = status.networkBytesReceived else { return }
        defer { lastBytes = (count, now) }
        guard let last = lastBytes, count >= last.count else { return }
        let seconds = now.timeIntervalSince(last.at)
        guard seconds >= 1 else { return }
        let rate = Double(count - last.count) / seconds
        rateTrail.append(rate)
        if rateTrail.count > 40 { rateTrail.removeFirst(rateTrail.count - 40) }
        if rate >= Self.downloadThreshold { downloadUntil = now.addingTimeInterval(Self.downloadGrace) }
    }

    var downloading: Bool { (downloadUntil ?? .distantPast) > Date() }

    static func rate(_ bytes: Double) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB/s", bytes / 1_000_000) }
        return "\(Int((bytes / 1000).rounded())) KB/s"
    }

    /// Why the Mac should stay awake right now, or `nil` to let it sleep.
    var reason: String? {
        if blocker != nil { return nil }
        if let session { return describe(session.mode) }
        if let pausedUntil, pausedUntil > Date() { return nil }
        if scheduleOn, inSchedule(Date()) { return "Schedule until \(scheduleEnd)" }
        if whilePluggedIn, status.onACPower { return "While plugged in" }
        if whileExternalDisplay, (status.externalDisplays ?? 0) > 0 { return "While a display is connected" }
        if whileVPN, status.vpnActive == true { return "While the VPN is on" }
        if whileDownloading, downloading { return "While a download is running" }
        return nil
    }

    /// Battery or Low Power Mode holding things back.
    var blocker: String? {
        if !status.onACPower, let level = status.batteryLevel, batteryFloor > 0, level * 100 < batteryFloor {
            return "Battery below \(Int(batteryFloor))%"
        }
        if pauseOnLowPower, status.lowPowerMode { return "Low Power Mode is on" }
        return nil
    }

    func endSessionIfDone(now: Date = Date()) {
        guard let session else { return }
        switch session.mode {
        case .indefinitely:
            return
        case .until(let end):
            if now >= end {
                finish("Time's up")
            } else if notifyOnEnd, end.timeIntervalSince(now) <= 5 * 60, warnedFor != end, session.total ?? 0 > 10 * 60 {
                warnedFor = end
                Stackbar.notify("Your Mac can sleep in 5 minutes", body: "Open Stay Awake to add more time.")
            }
        case .whileRunning(let appID, let name):
            if !status.runningApps.isEmpty, !status.runningApps.contains(where: { $0.id == appID }) { finish("\(name) quit") }
        }
    }

    func finish(_ why: String) {
        session = nil
        lastEnded = why
        if notifyOnEnd { Stackbar.notify("Your Mac can sleep again", body: why) }
    }

    /// Brings the host's assertion in line with `reason`, and counts awake time.
    func apply(now: Date = Date()) async {
        if let lastTick, held != nil {
            let day = Self.day(now)
            awakeByDay[day, default: 0] += min(now.timeIntervalSince(lastTick), 60)
            if awakeByDay.count > 14 { awakeByDay = awakeByDay.filter { $0.key >= Self.day(now.addingTimeInterval(-13 * 86400)) } }
        }
        lastTick = now
        if held != nil, let level = status.batteryLevel, now.timeIntervalSince(lastSample ?? .distantPast) >= 60 {
            batteryTrail.append((level * 1000).rounded() / 10)
            if batteryTrail.count > 240 { batteryTrail.removeFirst(batteryTrail.count - 240) }
            lastSample = now
        }
        let wanted = reason.map { KeepAwakeRequest(display: keepDisplayOn, reason: $0) }
        guard wanted != held else { return }
        do {
            if let wanted {
                try await Stackbar.keepAwake(display: wanted.display, reason: wanted.reason)
            } else {
                try await Stackbar.allowSleep()
            }
            held = wanted
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    func start(_ mode: Mode) async {
        if session == nil { batteryTrail = [] }
        session = Session(mode: mode, started: Date())
        lastEnded = nil
        await apply()
    }

    func stop() async {
        session = nil
        lastEnded = nil
        await apply()
    }

    // MARK: Time helpers

    func describe(_ mode: Mode) -> String {
        switch mode {
        case .indefinitely: return "Until you stop it"
        case .until(let end): return "Until \(end.formatted(date: .omitted, time: .shortened))"
        case .whileRunning(_, let name): return "While \(name) is running"
        }
    }

    static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// `"17:30"`, `"9"` or `"5:30pm"` as minutes after midnight.
    static func minutes(_ text: String) -> Int? {
        var text = text.lowercased().replacingOccurrences(of: " ", with: "")
        var meridiem: String?
        for suffix in ["am", "pm"] where text.hasSuffix(suffix) {
            meridiem = suffix
            text.removeLast(2)
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let hour = Int(parts[0]) else { return nil }
        guard let minute = parts.count == 2 ? Int(parts[1]) : 0, (0...59).contains(minute) else { return nil }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            return (hour % 12 + (meridiem == "pm" ? 12 : 0)) * 60 + minute
        }
        guard (0...23).contains(hour) else { return nil }
        return hour * 60 + minute
    }

    /// `"90"`, `"90m"`, `"2h"`, `"1h30"` or `"1:30"` as seconds.
    static func duration(_ text: String) -> Double? {
        let text = text.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "min", with: "m")
        if let minutes = Double(text.hasSuffix("m") ? String(text.dropLast()) : text), minutes > 0 { return minutes * 60 }
        let parts = text.split(whereSeparator: { $0 == "h" || $0 == ":" }).map(String.init)
        guard text.contains("h") || text.contains(":"), let hours = parts.first.flatMap(Double.init) else { return nil }
        let minutes = parts.count > 1 ? Double(parts[1].replacingOccurrences(of: "m", with: "")) : 0
        guard let minutes, hours * 60 + minutes > 0 else { return nil }
        return (hours * 60 + minutes) * 60
    }

    /// The next time `text` (a clock time) happens, today or tomorrow.
    static func next(_ text: String, after now: Date = Date()) -> Date? {
        guard let minutes = minutes(text) else { return nil }
        let today = Calendar.current.startOfDay(for: now).addingTimeInterval(Double(minutes) * 60)
        return today > now ? today : Calendar.current.date(byAdding: .day, value: 1, to: today)
    }

    func inSchedule(_ date: Date) -> Bool {
        guard let start = Self.minutes(scheduleStart), let end = Self.minutes(scheduleEnd) else { return false }
        let calendar = Calendar.current
        if scheduleWeekdaysOnly, calendar.isDateInWeekend(date) { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return start <= end ? (start..<end).contains(now) : (now >= start || now < end)
    }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }

    var remaining: Double? {
        if case .until(let end)? = session?.mode { return end.timeIntervalSinceNow }
        return nil
    }

    // MARK: Surfaces

    static let clickChoices: [(title: String, minutes: Double)] = [("Opens the panel", -1), ("Starts until I stop it", 0)] + durations.map { ("Starts for \($0.title)", $0.minutes) }

    var menuBarClick: MenuBarAction? {
        guard clickMinutes >= 0 else { return nil }
        if session != nil {
            return MenuBarAction("Click to stop keeping awake") { await self.stop() }
        }
        let minutes = clickMinutes
        let label = minutes == 0 ? "until you stop it" : "for \(Self.durations.first { $0.minutes == minutes }?.title ?? "\(Int(minutes)) min")"
        return MenuBarAction("Click to keep awake \(label)") {
            await self.start(minutes == 0 ? .indefinitely : .until(Date().addingTimeInterval(minutes * 60)))
        }
    }

    let theme = Theme.amber

    /// The timed session's span, for host-counted rings and clocks.
    var range: TimeRange? {
        guard let session, case .until(let end) = session.mode else { return nil }
        return TimeRange(start: session.started, end: end)
    }

    /// Held by a rule rather than a session the user started.
    var heldByRule: Bool { held != nil && session == nil }

    var menuBar: ViewContent {
        if held != nil, let range {
            HStack(spacing: Space.xs) {
                Image(systemName: "cup.and.heat.waves.fill")
                if showTimeLeft {
                    TimerText(range)
                } else {
                    ProgressBar(timing: range, style: .ring(lineWidth: 2)).frame(width: 13, height: 13)
                }
            }
        } else if held != nil {
            Label("", symbol: "cup.and.heat.waves.fill").role(.primary)
        } else if session != nil, blocker != nil {
            Label("", symbol: "cup.and.saucer").role(.warning)
        } else {
            Label("", symbol: "cup.and.saucer").role(.secondary)
        }
    }

    /// The cup in a ring that drains as a timed session runs out.
    /// The cup in a ring of time left. Awake, it sits on the vivid hero in
    /// `onSolid`, glowing and breathing; asleep, a quiet moon on neutral.
    @ViewBuilder func dial(size: Double, lineWidth: Double) -> ViewContent {
        if held != nil {
            let ink = theme.onSolidPaint
            ZStack {
                Circle().fill(.radial(["#FFFFFF59", "#FFFFFF00"], radius: size * 0.62))
                Circle().stroke(.hex("#FFFFFF3D", dark: "#00000029"), lineWidth: lineWidth)
                if let range {
                    ProgressBar(timing: range, style: .ring(lineWidth: lineWidth)).foreground(ink)
                } else {
                    ProgressBar(value: 1, style: .ring(lineWidth: lineWidth)).foreground(ink)
                }
                Image(systemName: "cup.and.heat.waves.fill").font(size: (size * 0.36).rounded(), weight: .semibold).foreground(ink).symbolEffect(.breathe)
            }
            .frame(width: size, height: size)
        } else {
            Gauge(value: 0, theme: .neutral, size: size, lineWidth: lineWidth) {
                Image(systemName: "moon.zzz.fill").font(size: (size * 0.36).rounded(), weight: .semibold).foreground(Theme.neutral.textPaint)
            }
        }
    }

    /// A button on the vivid hero: `onSolid` on a light veil.
    func heroButton(_ title: String?, symbol: String, label: String? = nil, key: String? = nil, action: @escaping @MainActor () async throws -> Void) -> some StackbarView {
        Button(key: key ?? title ?? label, action: action) {
            HStack(spacing: Space.xs) {
                Image(systemName: symbol).font(size: 12, weight: .semibold)
                if let title { Text(title).typography(.headline) }
            }
            .foreground(theme.onSolidPaint)
            .padding(horizontal: title == nil ? Space.s : Space.m, vertical: Space.s - 1)
            .background(.hex("#00000029", dark: "#0000001F"), in: .capsule)
            .hover(scale: 1.04, lift: false)
        }
        .accessibilityLabel(label ?? title ?? symbol)
    }

    var caption: String {
        if let reason, held != nil { return reason + (keepDisplayOn ? " · display on" : " · display may sleep") }
        if let blocker, session != nil { return "Paused: \(blocker)" }
        if let pausedUntil, pausedUntil > Date() { return "Rules paused until \(pausedUntil.formatted(date: .omitted, time: .shortened))" }
        if let lastEnded { return "Last session: \(lastEnded)" }
        return "Pick how long below"
    }

    /// The chip that matches the running session, if any.
    var activeChip: Double? {
        guard let session else { return nil }
        switch session.mode {
        case .indefinitely: return 0
        case .until: return session.total.map { ($0 / 60).rounded() }
        case .whileRunning: return nil
        }
    }

    static let chips: [[(title: String, minutes: Double)]] = [[("∞", 0), ("15m", 15), ("30m", 30), ("1h", 60)], [("2h", 120), ("4h", 240), ("8h", 480)]]

    var panel: ViewContent {
        let awake = held != nil
        if awake {
            HeroCard(theme: theme, look: .vivid) {
                HStack(spacing: Space.m) {
                    dial(size: 76, lineWidth: 6)
                    VStack(spacing: Space.xxs) {
                        Text("Awake").typography(Typography(size: 22, weight: .bold, design: .rounded))
                        Text(caption).typography(.caption).opacity(0.85)
                    }
                    .frame(fillWidth: true, alignment: .leading)
                    heroButton(nil, symbol: keepDisplayOn ? "display" : "display.trianglebadge.exclamationmark", label: keepDisplayOn ? "Display stays on" : "Keep display on", key: "display") {
                        self.keepDisplayOn.toggle()
                        await self.apply()
                    }
                }
                if let range {
                    TimerText(range).typography(Typography(size: 52, weight: .heavy, design: .rounded, monospacedDigit: true))
                }
                if let blocker, session != nil {
                    Text("Paused: \(blocker)").typography(.caption)
                }
                HStack(spacing: Space.s) {
                    if session != nil {
                        heroButton("Stop", symbol: "stop.fill") { await self.stop() }
                    }
                    if let remaining {
                        heroButton("+30 min", symbol: "plus") { await self.start(.until(Date().addingTimeInterval(remaining + 1800))) }
                    }
                    if heldByRule {
                        heroButton("Pause for 1 hour", symbol: "pause.fill") {
                            self.pausedUntil = Date().addingTimeInterval(3600)
                            await self.apply()
                        }
                    }
                    Spacer()
                }
            }
        } else {
            HeroCard(theme: .neutral) {
                HStack(spacing: Space.m) {
                    dial(size: 64, lineWidth: 5)
                    VStack(spacing: Space.xxs) {
                        Text("Sleeps normally").typography(Typography(size: 22, weight: .bold, design: .rounded))
                        Text(caption).role(.secondary).typography(.caption)
                    }
                    .frame(fillWidth: true, alignment: .leading)
                    IconButton("display", label: keepDisplayOn ? "Display stays on" : "Keep display on", theme: theme,
                               prominence: keepDisplayOn ? .filled : .tinted, key: "display") {
                        self.keepDisplayOn.toggle()
                        await self.apply()
                    }
                }
                if let blocker, session != nil {
                    Banner("Paused: \(blocker)")
                }
                if session != nil {
                    HStack(spacing: Space.s) {
                        ActionButton("Stop", symbol: "stop.fill", theme: .critical, prominent: true) { await self.stop() }
                        Spacer()
                    }
                }
            }
        }
        if let lastError {
            Banner(lastError)
        }
        Card("Keep awake", spacing: Space.s) {
            ForEach(Array(Self.chips.enumerated())) { _, row in
                HStack(spacing: Space.xs + 2) {
                    ForEach(row) { option in
                        Chip(option.title, theme: theme, selected: activeChip == option.minutes, key: "for-\(Int(option.minutes))") {
                            await self.start(option.minutes == 0 ? .indefinitely : .until(Date().addingTimeInterval(option.minutes * 60)))
                        }
                    }
                    Spacer()
                }
            }
            TextField("Or type 90m, 1h30 or 17:30") { text in
                if let seconds = Self.duration(text) {
                    self.inputError = nil
                    await self.start(.until(Date().addingTimeInterval(seconds)))
                } else if let end = Self.next(text) {
                    self.inputError = nil
                    await self.start(.until(end))
                } else {
                    self.inputError = "\"\(text)\" isn't a duration or a time; try 45m, 1h30 or 17:30"
                }
            }
            if let inputError {
                Banner(inputError)
            }
            let apps = status.runningApps.filter { $0.id != "io.navbytes.stackbar" }.sorted { $0.name < $1.name }
            if !apps.isEmpty {
                Picker("While an app runs", options: apps.map(\.name), selection: whileRunningName) { name in
                    guard let app = apps.first(where: { $0.name == name }) else { return }
                    await self.start(.whileRunning(appID: app.id, name: app.name))
                }
            }
        }
        let week = hoursAwake(days: 7)
        if awakeByDay.values.contains(where: { $0 > 0 }) {
            Card("This week", detail: "today \(Self.clock(awakeByDay[Self.day(Date())] ?? 0)) · average \(Self.clock(week.values.reduce(0, +) / 7 * 3600))", spacing: Space.s) {
                Chart(values: week.values, kind: .bar, labels: week.labels, unit: "h", highlight: 6).foreground(theme.solidPaint)
            }
        }
        if awake, whileDownloading, rateTrail.count >= 3, rateTrail.contains(where: { $0 >= Self.downloadThreshold }) {
            Card("Download speed", detail: downloading ? Self.rate(rateTrail.last ?? 0) : "quiet", spacing: Space.s) {
                Chart(values: rateTrail.map { ($0 / 10_000).rounded() / 100 }, kind: .area, unit: "MB/s", goal: Self.downloadThreshold / 1_000_000)
                    .foreground((downloading ? theme : .neutral).solidPaint)
                Text(downloading ? "Staying awake until it's quiet for 2 minutes" : "No download running").role(.secondary).typography(.caption)
            }
        }
        if awake, !status.onACPower, let level = status.batteryLevel, batteryTrail.count >= 3 {
            Card("Battery while awake", detail: "\(Int((level * 100).rounded()))%", spacing: Space.s) {
                Chart(values: batteryTrail, kind: .area, unit: "%").foreground((level < 0.2 ? Theme.critical : .success).solidPaint)
            }
        }
    }

    /// Hours awake per day for the last `days` days, oldest first, with
    /// short weekday names (or day numbers past a week).
    func hoursAwake(days: Int, now: Date = Date()) -> (values: [Double], labels: [String]) {
        let calendar = Calendar.current
        let dates = (0..<days).reversed().map { now.addingTimeInterval(Double(-$0) * 86400) }
        let values = dates.map { ((awakeByDay[Self.day($0)] ?? 0) / 360).rounded() / 10 }
        let labels = dates.map { date in
            days <= 7 ? calendar.shortWeekdaySymbols[calendar.component(.weekday, from: date) - 1] : String(calendar.component(.day, from: date))
        }
        return (values, labels)
    }

    /// Stackbar's Settings window, so the panel stays about starting and stopping.
    var settings: ViewContent {
        Section("Menu bar") {
            Picker("Clicking the cup", options: Self.clickChoices.map(\.title), selection: Self.clickChoices.first { $0.minutes == clickMinutes }?.title ?? Self.clickChoices[1].title, key: "click") { title in
                self.clickMinutes = Self.clickChoices.first { $0.title == title }?.minutes ?? 0
            }
            Toggle("Show time left during a timed session", isOn: showTimeLeft, key: "time-left") { self.showTimeLeft = $0 }
            Text("A right click always opens the panel. Toggle, Keep Awake For and Allow Sleep are commands too, so you can give them a hotkey or run them from Shortcuts.").style(.caption).role(.secondary)
        }
        Section("Stop or pause") {
            Slider(batteryFloor > 0 ? "Stop below \(Int(batteryFloor))% battery" : "Ignore the battery level", value: batteryFloor, in: 0...50, step: 5, key: "battery") { value in
                self.batteryFloor = value
                await self.apply()
            }
            Toggle("Pause in Low Power Mode", isOn: pauseOnLowPower) { on in
                self.pauseOnLowPower = on
                await self.apply()
            }
            Toggle("Notify 5 minutes before and when a session ends", isOn: notifyOnEnd, key: "notify") { self.notifyOnEnd = $0 }
        }
        Section("Automatically") {
            Toggle("Always stay awake while plugged in", isOn: whilePluggedIn) { on in
                self.whilePluggedIn = on
                await self.apply()
            }
            Toggle("While an external display is connected", isOn: whileExternalDisplay, key: "display") { on in
                self.whileExternalDisplay = on
                await self.apply()
            }
            Toggle("While a VPN is connected", isOn: whileVPN, key: "vpn") { on in
                self.whileVPN = on
                await self.apply()
            }
            Toggle("While a download is running", isOn: whileDownloading, key: "download") { on in
                self.whileDownloading = on
                await self.apply()
            }
            Text("A download is anything over \(Self.rate(Self.downloadThreshold)); the Mac stays awake until it's been quiet for 2 minutes.").style(.caption).role(.secondary)
            Text("To work with the lid closed, connect power and a display (macOS calls it clamshell mode), and turn on the display option above so it doesn't idle-sleep.").style(.caption).role(.secondary)
        }
        Section("Schedule") {
            Toggle(scheduleWeekdaysOnly ? "Weekdays \(scheduleStart)–\(scheduleEnd)" : "Every day \(scheduleStart)–\(scheduleEnd)", isOn: scheduleOn, key: "schedule") { on in
                self.scheduleOn = on
                await self.apply()
            }
            TextField("Starts, like 09:00", text: scheduleStart, key: "schedule-start") { text in await self.setSchedule(start: text) }
            TextField("Ends, like 18:00", text: scheduleEnd, key: "schedule-end") { text in await self.setSchedule(end: text) }
            if let settingsError { Text(settingsError).style(.caption).role(.warning) }
            Toggle("Weekdays only", isOn: scheduleWeekdaysOnly) { on in
                self.scheduleWeekdaysOnly = on
                await self.apply()
            }
        }
    }

    var widget: ViewContent {
        if held != nil {
            HeroCard(theme: theme, look: .vivid, spacing: Space.s) {
                HStack(spacing: Space.m) {
                    dial(size: 64, lineWidth: 5)
                    VStack(spacing: Space.xxs) {
                        Text("Awake").typography(.title)
                        if let range { TimerText(range).typography(Typography(size: 26, weight: .heavy, design: .rounded, monospacedDigit: true)) }
                        Text(reason ?? "").typography(.caption).opacity(0.85)
                    }
                    .frame(fillWidth: true, alignment: .leading)
                }
            }
            .frame(fillWidth: true, fillHeight: true)
        } else {
            HStack(spacing: Space.m) {
                dial(size: 64, lineWidth: 5)
                VStack(spacing: Space.xxs) {
                    Text("Sleeps normally").typography(.title)
                    Text("Today \(Self.clock(awakeByDay[Self.day(Date())] ?? 0)) awake").role(.secondary).typography(.caption)
                }
                .frame(fillWidth: true, alignment: .leading)
            }
            .frame(fillWidth: true, fillHeight: true)
        }
    }

    var whileRunningName: String? {
        if case .whileRunning(_, let name)? = session?.mode { return name }
        return nil
    }

    func setSchedule(start: String? = nil, end: String? = nil) async {
        for text in [start, end].compactMap({ $0 }) where Self.minutes(text) == nil {
            settingsError = "\"\(text)\" isn't a time; try 09:00 or 6pm"
            return
        }
        if let start { scheduleStart = start.trimmingCharacters(in: .whitespaces) }
        if let end { scheduleEnd = end.trimmingCharacters(in: .whitespaces) }
        settingsError = nil
        await apply()
    }

    // MARK: Commands

    /// What a typed `for` argument means: nothing is until stopped, `90m`,
    /// `2h` or `1:30` is a duration, and `until 17:30` or `5pm` is a time.
    static func mode(for text: String?, now: Date = Date()) -> Mode? {
        let text = (text ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if text.isEmpty { return .indefinitely }
        if text.hasPrefix("until ") { return next(String(text.dropFirst(6)), after: now).map(Mode.until) }
        if let seconds = duration(text) { return .until(now.addingTimeInterval(seconds)) }
        return next(text, after: now).map(Mode.until)
    }

    var commands: [Command] {
        Command("toggle", title: "Toggle Stay Awake", symbol: "cup.and.heat.waves", keywords: ["awake", "caffeine", "amphetamine", "sleep"]) { _ in
            if self.session != nil {
                await self.stop()
                return .message("Your Mac can sleep again")
            }
            await self.start(.indefinitely)
            return .message("Keeping your Mac awake until you stop it")
        }
        Command("keep-awake", title: "Keep Awake For…", subtitle: "A duration like 90m or 2h, or a time like 17:30", symbol: "timer", keywords: ["awake", "caffeine", "sleep", "until"]) { invocation in
            guard let mode = Self.mode(for: invocation["for"]) else {
                return .failure("Try a duration like 90m or 2h, or a time like 17:30")
            }
            await self.start(mode)
            return .message("Keeping your Mac awake " + self.describe(mode).lowercased())
        }
        .argument("for", placeholder: "2h, 90m or 17:30", required: false)
        Command("allow-sleep", title: "Allow Sleep", symbol: "moon.zzz", keywords: ["awake", "sleep", "stop"]) { _ in
            await self.stop()
            return .message("Your Mac can sleep again")
        }
    }

    // MARK: Agents

    var tools: [AgentTool] {
        AgentTool("awake_status", description: "Whether the Mac is being kept awake, why, and for how long") { _ in
            guard let reason = self.reason, self.held != nil else { return "The Mac sleeps normally." + (self.blocker.map { " (\($0))" } ?? "") }
            return "Staying awake: \(reason)" + (self.remaining.map { ", \(Self.clock($0)) left" } ?? "")
        }
        AgentTool("keep_awake", description: "Keep the Mac awake, for a number of minutes or until stopped", parameters: [ToolParameter("minutes", .number, description: "Minutes; leave out to keep awake until stopped", required: false)]) { arguments in
            if let minutes = arguments.number("minutes"), minutes > 0 {
                await self.start(.until(Date().addingTimeInterval(minutes * 60)))
                return "Keeping the Mac awake for \(Self.clock(minutes * 60))."
            }
            await self.start(.indefinitely)
            return "Keeping the Mac awake until stopped."
        }
        AgentTool("allow_sleep", description: "Stop keeping the Mac awake") { _ in
            await self.stop()
            return "The Mac can sleep again."
        }
    }
}
