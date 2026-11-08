import StackbarKit
import Foundation

/// Countdown timers from the palette, as Raycast's timers have them: type
/// "Start Timer", then "10m tea" or "1h30" or "17:45", and Return. Several
/// run at once; the soonest counts down in the menu bar, and each one ends
/// with a sound, a notification and a message on screen.
@main
final class Timers: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.timers",
        name: "Timers",
        version: "1.2.0",
        summary: "Countdown timers from the palette, several at once, the soonest in the menu bar.",
        surfaces: [.menuBar, .panel, .settings],
        triggers: [.launch, .every(.seconds(1)), .wake],
        capabilities: [],
        minimumStackbar: "0.35.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/Timers",
        accent: .orange,
        symbol: "timer"
    )

    static let previews: [PreviewScene<Timers>] = [
        PreviewScene("hero", "Several timers, the soonest in the menu bar") { plugin in
            let now = Date()
            plugin.timers = [
                Countdown(name: "Tea", start: now.addingTimeInterval(-120), end: now.addingTimeInterval(180)),
                Countdown(name: "Standup", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(1500)),
                Countdown(name: "Laundry", start: now.addingTimeInterval(-900), end: now.addingTimeInterval(2700)),
            ]
            plugin.now = now
        },
        PreviewScene("start", "Start one with a click, or type “10m tea”") { plugin in
            plugin.recent = ["3m", "45m"]
            plugin.now = Date()
        },
        PreviewScene("paused", "Pause a timer and pick it up later") { plugin in
            let now = Date()
            plugin.timers = [
                Countdown(name: "Tea", start: now.addingTimeInterval(-120), end: now.addingTimeInterval(180)),
                Countdown(name: "Standup", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(1500), paused: 1500),
                Countdown(name: "Laundry", start: now.addingTimeInterval(-900), end: now.addingTimeInterval(2700)),
            ]
            plugin.now = now
        },
    ]

    let theme = Theme.orange

    struct Countdown: Codable, Equatable, Identifiable {
        var id = UUID().uuidString
        var name: String
        var start: Date
        var end: Date
        /// A timer set for a clock time ("17:45"), rather than a length.
        var isAlarm: Bool? = nil
        /// Set while paused: the seconds that were left when it was paused.
        var paused: Double? = nil
        var range: TimeRange { TimeRange(start: start, end: end) }
    }

    @Stored("timers") var timers: [Countdown] = []
    /// Lengths started recently, newest first, as typed ("10m").
    @Stored("recent") var recent: [String] = []
    @Stored("sound") var sound = SystemSound.glass.rawValue
    @Stored("showInMenuBar") var showInMenuBar = true
    var now = Date()
    /// When Stop All Timers was last run with several timers going, so that a
    /// second run within ten seconds stops them.
    private var stopAllArmedAt: Date?

    static let presets = ["1m", "5m", "10m", "25m", "1h"]

    func refresh() async throws {
        now = Date()
        let ended = timers.filter { $0.paused == nil && $0.end <= now }
        guard !ended.isEmpty else { return }
        timers.removeAll { timer in ended.contains { $0.id == timer.id } }
        if ended.count > 1 {
            // Apps get ten notifications a minute, so timers ending together share one.
            if let sound = SystemSound(rawValue: sound) { Stackbar.play(sound) }
            Stackbar.notify("\(ended.count) timers are done", body: ended.map(\.name).joined(separator: ", "))
            Stackbar.hud("⏰ \(ended.count) timers are done")
        } else {
            for timer in ended { ring(timer) }
        }
    }

    func ring(_ timer: Countdown) {
        if let sound = SystemSound(rawValue: sound) { Stackbar.play(sound) }
        let length = Self.length(timer.end.timeIntervalSince(timer.start))
        // An alarm for a clock time has no length to start again.
        let again = timer.isAlarm == true ? [] : [NotificationAction("Again", command: "start", arguments: ["for": "\(length.replacingOccurrences(of: " ", with: "")) \(timer.name)"])]
        Stackbar.notify("\(timer.name) is done", body: "Your \(length) timer ended.", actions: again + [NotificationAction("5 More Minutes", command: "start", arguments: ["for": "5m \(timer.name)"])])
        Stackbar.hud("⏰ \(timer.name) is done")
    }

    // MARK: Parsing

    /// `"90"` (minutes), `"90s"`, `"10m"`, `"2h"`, `"1h30"` or `"1:30"` as
    /// seconds; nil for anything else.
    static func duration(_ text: String) -> Double? {
        // Unit words after a number become their letter ("10minutes" is "10m"),
        // whole words only, so "min" inside "minutes" isn't cut short.
        var text = text.lowercased().replacingOccurrences(of: " ", with: "")
        for (pattern, unit) in [("(hours|hour|hrs|hr)", "h"), ("(minutes|minute|mins|min)", "m"), ("(seconds|second|secs|sec)", "s")] {
            text = text.replacingOccurrences(of: "(?<=[0-9.])" + pattern + "(?![a-z])", with: unit, options: .regularExpression)
        }
        guard !text.isEmpty else { return nil }
        if text.hasSuffix("s"), !text.contains("m"), !text.contains("h"), let seconds = Double(text.dropLast()), seconds > 0 { return seconds }
        if let minutes = Double(text.hasSuffix("m") ? String(text.dropLast()) : text), minutes > 0 { return minutes * 60 }
        // 1h30, 1h30m, 1:30, 2h, 5m30s
        var total = 0.0
        var number = ""
        var unitsSeen = false
        for character in text {
            if character.isNumber || character == "." {
                number.append(character)
                continue
            }
            guard let value = Double(number) else { return nil }
            switch character {
            case "h", ":": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            default: return nil
            }
            unitsSeen = true
            number = ""
        }
        if !number.isEmpty {
            guard let value = Double(number), unitsSeen else { return nil }
            // What follows hours is minutes, what follows minutes is seconds.
            total += text.contains("m") ? value : value * 60
        }
        return unitsSeen && total > 0 ? total : nil
    }

    /// The next clock time after `now`, as a date: `17:45`, `5pm`, `5:30pm`,
    /// `5.30pm`, `noon` or `midnight`. With `bare`, an hour from 1 to 12 with
    /// no am or pm is read as a time after "at" or "until": 1 to 6 is the
    /// afternoon or evening ("at 3" is 3 pm), 7 to 11 is whichever of morning
    /// and night comes next ("at 8"), and 12 is the next noon.
    static func clockTime(_ text: String, after now: Date, bare: Bool = false) -> Date? {
        var text = text.lowercased().replacingOccurrences(of: " ", with: "")
        var meridiem: String?
        for suffix in ["am", "pm"] where text.hasSuffix(suffix) {
            meridiem = suffix
            text = String(text.dropLast(2))
        }
        let hour: Int
        var minute = 0
        if meridiem == nil, text == "noon" || text == "midnight" {
            hour = text == "noon" ? 12 : 0
        } else {
            let parts = text.split(whereSeparator: { $0 == ":" || (meridiem != nil && $0 == ".") })
            guard (1...2).contains(parts.count), let value = Int(parts[0]) else { return nil }
            guard parts.count == 2 || meridiem != nil else { return nil }
            guard let minutes = parts.count == 2 ? Int(parts[1]) : 0, (0...59).contains(minutes) else { return nil }
            hour = value
            minute = minutes
        }
        let readings: [Int]
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            readings = [hour % 12 + (meridiem == "pm" ? 12 : 0)]
        } else if bare, (1...12).contains(hour) {
            readings = hour <= 6 ? [hour + 12] : hour <= 11 ? [hour, hour + 12] : [12]
        } else {
            guard (0...23).contains(hour) else { return nil }
            readings = [hour]
        }
        // Set on the calendar, not by adding seconds, so the day the clocks change is right.
        let calendar = Calendar.current
        return readings.compactMap { reading -> Date? in
            guard let date = calendar.date(bySettingHour: reading, minute: minute, second: 0, of: now) else { return nil }
            return date > now ? date : calendar.date(byAdding: .day, value: 1, to: date)
        }.min()
    }

    /// What was typed, split into when the timer ends, its name and the length
    /// as typed (nil for a clock time): `"10m tea"`, `"tea 10m"`, `"17:45 call"`.
    /// Nil when nothing in it is a length or a time.
    static func parse(_ text: String, now: Date) -> (end: Date, name: String, length: String?)? {
        let words = text.split(separator: " ").map(String.init)
        // Words that lead a length or a time ("for 10 minutes", "at 5 pm") and
        // are not part of the name.
        let fillers: Set<String> = ["for", "in", "at", "until", "till", "by"]
        /// The name left once the `used` words are taken out, along with the
        /// filler word just before the first of them.
        func name(_ used: Set<Int>) -> String {
            var gone = used
            if let first = used.min(), first > 0, fillers.contains(words[first - 1].lowercased()) { gone.insert(first - 1) }
            return words.enumerated().filter { !gone.contains($0.offset) }.map(\.element).joined(separator: " ")
        }
        for (index, word) in words.enumerated() {
            // "noon" and "midnight" are read last, so "Midnight snack 10m" is still a timer.
            if ["noon", "midnight"].contains(word.lowercased()) { continue }
            // "5 pm": the number and its meridiem are one time.
            if index + 1 < words.count, ["am", "pm"].contains(words[index + 1].lowercased()), let end = clockTime(word + words[index + 1], after: now) {
                let rest = name([index, index + 1])
                return (end, rest.isEmpty ? "Alarm" : rest, nil)
            }
            // "lunch at 12": a bare hour after a time word is a time, not a length.
            if index > 0, ["at", "until", "till", "by"].contains(words[index - 1].lowercased()), measured(words, at: index) == nil,
               let hour = Int(word), (0...23).contains(hour), let end = clockTime("\(hour):00", after: now, bare: (1...12).contains(hour)) {
                let rest = name([index])
                return (end, rest.isEmpty ? "Alarm" : rest, nil)
            }
            // "30 seconds", "1 hour 30 minutes": a number and the unit word
            // after it, which `duration` would otherwise read as minutes.
            if let first = measured(words, at: index) {
                var total = duration(first.token) ?? 0
                var used = Set(index..<(index + first.count))
                var tokens = first.token
                var rank = first.rank
                var next = index + first.count
                while next < words.count, let more = measured(words, at: next), more.rank < rank, let extra = duration(more.token) {
                    total += extra
                    used.formUnion(next..<(next + more.count))
                    tokens += more.token
                    rank = more.rank
                    next += more.count
                }
                if total > 0 {
                    return (now.addingTimeInterval(total), name(used), tokens)
                }
            }
            if clockTime(word, after: now) == nil, let seconds = duration(word) {
                return (now.addingTimeInterval(seconds), name([index]), word)
            }
            if let end = clockTime(word, after: now) {
                let rest = name([index])
                return (end, rest.isEmpty ? "Alarm" : rest, nil)
            }
        }
        // Only when nothing else in the text is a length or a time: "lunch at noon" is an alarm.
        for (index, word) in words.enumerated() where ["noon", "midnight"].contains(word.lowercased()) {
            if let end = clockTime(word, after: now) {
                let rest = name([index])
                return (end, rest.isEmpty ? "Alarm" : rest, nil)
            }
        }
        return nil
    }

    private static let units: [String: (letter: String, rank: Int)] = [
        "h": ("h", 3), "hr": ("h", 3), "hrs": ("h", 3), "hour": ("h", 3), "hours": ("h", 3),
        "m": ("m", 2), "min": ("m", 2), "mins": ("m", 2), "minute": ("m", 2), "minutes": ("m", 2),
        "s": ("s", 1), "sec": ("s", 1), "secs": ("s", 1), "second": ("s", 1), "seconds": ("s", 1),
    ]

    /// A number with its unit, glued ("10min") or in the next word ("10 min"),
    /// as one token ("10m"), with the words it took. Nil for anything else.
    static func measured(_ words: [String], at index: Int) -> (token: String, rank: Int, count: Int)? {
        let word = words[index].lowercased()
        if let split = word.firstIndex(where: { !($0.isNumber || $0 == ".") }), split != word.startIndex {
            guard Double(word[..<split]) != nil, let unit = units[String(word[split...])] else { return nil }
            return (String(word[..<split]) + unit.letter, unit.rank, 1)
        }
        if Double(word) != nil, index + 1 < words.count, let unit = units[words[index + 1].lowercased()] {
            return (word + unit.letter, unit.rank, 2)
        }
        return nil
    }

    static func length(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let (hours, minutes, rest) = (total / 3600, (total % 3600) / 60, total % 60)
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return rest > 0 ? "\(minutes)m \(rest)s" : "\(minutes)m" }
        return "\(rest)s"
    }

    // MARK: Starting and stopping

    @discardableResult
    func start(_ text: String) throws -> Countdown {
        now = Date()
        guard let parsed = Self.parse(text, now: now) else {
            throw HostError("Try a length like 10m, 1h30 or 90s, or a time like 17:45, then a name")
        }
        guard parsed.end.timeIntervalSince(now) <= 7 * 24 * 3600 else { throw HostError("A timer can run for a week at most") }
        guard timers.count < 20 else { throw HostError("20 timers are running already") }
        let name = parsed.name.isEmpty ? "\(Self.length(parsed.end.timeIntervalSince(now))) timer" : parsed.name
        let timer = Countdown(name: String(name.prefix(60)), start: now, end: parsed.end, isAlarm: parsed.length == nil)
        // One assignment, so storage gets one write of the sorted list.
        timers = (timers + [timer]).sorted(by: Self.before)
        if let length = parsed.length, Self.duration(length) != nil {
            recent = Array(([length] + recent.filter { $0 != length }).prefix(5))
        }
        return timer
    }

    /// Running timers soonest first, then the paused ones, by id where they tie.
    static func before(_ a: Countdown, _ b: Countdown) -> Bool {
        (a.paused == nil ? a.end : .distantFuture, a.id) < (b.paused == nil ? b.end : .distantFuture, b.id)
    }

    func cancel(_ id: String) {
        timers.removeAll { $0.id == id }
    }

    func extend(_ id: String, by seconds: Double) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        var changed = timers
        if changed[index].paused != nil {
            changed[index].paused? += seconds
            changed[index].end = changed[index].end.addingTimeInterval(seconds)
        } else {
            changed[index].end = max(Date(), changed[index].end).addingTimeInterval(seconds)
        }
        timers = changed.sorted(by: Self.before)
    }

    /// Pauses a running timer, keeping the time it has left, or resumes a
    /// paused one for that time from now.
    func togglePause(_ id: String) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        now = Date()
        var changed = timers
        if let left = changed[index].paused {
            let total = changed[index].end.timeIntervalSince(changed[index].start)
            changed[index].end = now.addingTimeInterval(left)
            changed[index].start = changed[index].end.addingTimeInterval(-total)
            changed[index].paused = nil
        } else {
            changed[index].paused = max(0, changed[index].end.timeIntervalSince(now))
        }
        timers = changed.sorted(by: Self.before)
    }

    // MARK: Surfaces

    var menuBar: ViewContent {
        if showInMenuBar, let soonest = timers.filter({ $0.paused == nil }).min(by: { $0.end < $1.end }) {
            HStack(spacing: 4) {
                Image(systemName: "timer")
                TimerText(soonest.range)
            }
        } else if showInMenuBar, let paused = timers.first(where: { $0.paused != nil }), let left = paused.paused {
            Label(Self.length(left), symbol: "pause.fill").role(.secondary)
        } else {
            Label("", symbol: "timer").role(.secondary)
        }
    }

    func row(_ timer: Countdown) -> Row {
        let subtitle = timer.paused.map { "Paused with \(Self.length($0)) left" } ?? "Ends \(timer.end.formatted(date: .omitted, time: .shortened))"
        return Row(timer.name, subtitle: subtitle, symbol: "timer", key: timer.id)
            .action("Add 1 Minute") { self.extend(timer.id, by: 60) }
            .action("Add 5 Minutes") { self.extend(timer.id, by: 300) }
            .action(timer.paused == nil ? "Pause" : "Resume") { self.togglePause(timer.id) }
            .action("Cancel Timer", role: .critical, confirm: "cancel \(timer.name)") { self.cancel(timer.id) }
    }

    var panel: ViewContent {
        PanelHeader("Timers", subtitle: timers.isEmpty ? "Nothing running" : "\(timers.count) running", symbol: "timer", theme: theme)
        if timers.isEmpty {
            EmptyState("Start a timer", symbol: "timer", message: "Pick one below, or open the palette and type Start Timer, then \"10m tea\" or \"17:45 call\".", theme: theme)
        } else {
            Card("Running", spacing: Space.s, padding: Space.s) {
                ForEach(timers.sorted(by: Self.before)) { timer in
                    VStack(alignment: .start, spacing: Space.xs) {
                        HStack(spacing: Space.s) {
                            Text(timer.name).font(size: 13, weight: .semibold)
                            Spacer()
                            if let left = timer.paused {
                                Text(Self.length(left)).font(size: 13, weight: .semibold)
                            } else {
                                TimerText(timer.range).font(size: 13, weight: .semibold)
                            }
                        }
                        if let left = timer.paused {
                            let total = timer.end.timeIntervalSince(timer.start)
                            ProgressBar(value: total - left, total: total)
                        } else {
                            ProgressBar(timing: timer.range)
                        }
                        HStack(spacing: Space.s) {
                            Chip("+1m", theme: theme, key: "plus1-\(timer.id)") { self.extend(timer.id, by: 60) }
                            Chip("+5m", theme: theme, key: "plus5-\(timer.id)") { self.extend(timer.id, by: 300) }
                            Chip(timer.paused == nil ? "Pause" : "Resume", theme: theme, key: "pause-\(timer.id)") { self.togglePause(timer.id) }
                            Spacer()
                            Chip("Cancel", symbol: "xmark", theme: theme, key: "cancel-\(timer.id)") { self.cancel(timer.id) }
                        }
                    }
                }
            }
        }
        Card("Quick start", spacing: Space.s, padding: Space.s) {
            HStack(spacing: Space.s) {
                ForEach(Array(Set(Self.presets + recent)).sorted { (Self.duration($0) ?? 0, $0) < (Self.duration($1) ?? 0, $1) }.prefix(6)) { length in
                    Chip(length, theme: theme, key: "start-\(length)") { try self.start(length) }
                }
            }
        }
    }

    var settings: ViewContent {
        Section("When a timer ends") {
            Picker("Sound", options: SystemSound.allCases.map(\.rawValue), selection: sound) { self.sound = $0 }
        }
        Section("Menu bar") {
            Toggle("Show the soonest timer in the menu bar", isOn: showInMenuBar) { self.showInMenuBar = $0 }
        }
    }

    // MARK: Commands

    var commands: [Command] {
        Command("start", title: "Start Timer", subtitle: "A length like 10m or 1h30, or a time like 17:45, then a name", symbol: "timer", keywords: ["timer", "countdown", "alarm", "remind"]) { invocation in
            let timer = try self.start(invocation["for"] ?? "")
            return .message("\(timer.name): ends at \(timer.end.formatted(date: .omitted, time: .shortened))")
        }
        .argument("for", placeholder: "10m tea", required: true)
        Command("list", title: "Show Timers", subtitle: "The timers running now", symbol: "list.bullet", keywords: ["timer", "countdown", "running"])
            .view { _ in
                if self.timers.isEmpty {
                    ContentUnavailableView("No timers running", symbol: "timer", message: "Start one with Start Timer.")
                } else {
                    List {
                        ForEach(self.timers) { timer in self.row(timer) }
                    }
                }
            }
        Command("stop-all", title: "Stop All Timers", symbol: "stop.circle", keywords: ["timer", "cancel", "clear"]) { _ in
            let count = self.timers.count
            let armed = self.stopAllArmedAt.map { Date().timeIntervalSince($0) < 10 } ?? false
            if count > 1, !armed {
                self.stopAllArmedAt = Date()
                return .message("Run Stop All Timers again within 10 seconds to stop \(count) timers")
            }
            self.stopAllArmedAt = nil
            self.timers = []
            return .message(count == 0 ? "No timers were running" : "Stopped \(count) timer\(count == 1 ? "" : "s")")
        }
    }
}
