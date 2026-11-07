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
        version: "1.0.1",
        summary: "Countdown timers from the palette, several at once, the soonest in the menu bar.",
        surfaces: [.menuBar, .panel, .settings],
        triggers: [.launch, .every(.seconds(1)), .wake],
        capabilities: [],
        minimumStackbar: "0.22.0",
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
    ]

    let theme = Theme.orange

    struct Countdown: Codable, Equatable, Identifiable {
        var id = UUID().uuidString
        var name: String
        var start: Date
        var end: Date
        var range: TimeRange { TimeRange(start: start, end: end) }
    }

    @Stored("timers") var timers: [Countdown] = []
    /// Lengths started recently, newest first, as typed ("10m").
    @Stored("recent") var recent: [String] = []
    @Stored("sound") var sound = SystemSound.glass.rawValue
    @Stored("showInMenuBar") var showInMenuBar = true
    var now = Date()

    static let presets = ["1m", "5m", "10m", "25m", "1h"]

    func refresh() async throws {
        now = Date()
        let ended = timers.filter { $0.end <= now }
        guard !ended.isEmpty else { return }
        timers.removeAll { $0.end <= now }
        for timer in ended { ring(timer) }
    }

    func ring(_ timer: Countdown) {
        if let sound = SystemSound(rawValue: sound) { Stackbar.play(sound) }
        Stackbar.notify("\(timer.name) is done", body: "Your \(Self.length(timer.end.timeIntervalSince(timer.start))) timer ended.")
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

    /// A clock time later today (or tomorrow) as a date: `17:45`, `5pm`,
    /// `5:30pm`.
    static func clockTime(_ text: String, after now: Date) -> Date? {
        var text = text.lowercased().replacingOccurrences(of: " ", with: "")
        var meridiem: String?
        for suffix in ["am", "pm"] where text.hasSuffix(suffix) {
            meridiem = suffix
            text = String(text.dropLast(2))
        }
        let parts = text.split(separator: ":")
        guard (1...2).contains(parts.count), let hour = Int(parts[0]) else { return nil }
        guard parts.count == 2 || meridiem != nil else { return nil }
        guard let minute = parts.count == 2 ? Int(parts[1]) : 0, (0...59).contains(minute) else { return nil }
        var hour24 = hour
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            hour24 = hour % 12 + (meridiem == "pm" ? 12 : 0)
        } else {
            guard (0...23).contains(hour) else { return nil }
        }
        let today = Calendar.current.startOfDay(for: now).addingTimeInterval(Double(hour24 * 3600 + minute * 60))
        return today > now ? today : Calendar.current.date(byAdding: .day, value: 1, to: today)
    }

    /// What was typed, split into when the timer ends and its name:
    /// `"10m tea"`, `"tea 10m"`, `"17:45 call"`. Nil when nothing in it is
    /// a length or a time.
    static func parse(_ text: String, now: Date) -> (end: Date, name: String, length: String)? {
        let words = text.split(separator: " ").map(String.init)
        for (index, word) in words.enumerated() {
            // "5 pm": the number and its meridiem are one time.
            if index + 1 < words.count, ["am", "pm"].contains(words[index + 1].lowercased()), let end = clockTime(word + words[index + 1], after: now) {
                let rest = words.enumerated().filter { $0.offset != index && $0.offset != index + 1 }.map(\.element).joined(separator: " ")
                return (end, rest.isEmpty ? "Alarm" : rest, word + words[index + 1])
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
                    let rest = words.enumerated().filter { !used.contains($0.offset) }.map(\.element).joined(separator: " ")
                    return (now.addingTimeInterval(total), rest, tokens)
                }
            }
            let rest = words.enumerated().filter { $0.offset != index }.map(\.element).joined(separator: " ")
            if clockTime(word, after: now) == nil, let seconds = duration(word) {
                return (now.addingTimeInterval(seconds), rest, word)
            }
            if let end = clockTime(word, after: now) {
                return (end, rest.isEmpty ? "Alarm" : rest, word)
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
        let timer = Countdown(name: String(name.prefix(60)), start: now, end: parsed.end)
        // One assignment, so storage gets one write of the sorted list.
        timers = (timers + [timer]).sorted { $0.end < $1.end }
        if Self.duration(parsed.length) != nil {
            recent = Array(([parsed.length] + recent.filter { $0 != parsed.length }).prefix(5))
        }
        return timer
    }

    func cancel(_ id: String) {
        timers.removeAll { $0.id == id }
    }

    func extend(_ id: String, by seconds: Double) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        var changed = timers
        changed[index].end = max(Date(), changed[index].end).addingTimeInterval(seconds)
        timers = changed.sorted { $0.end < $1.end }
    }

    // MARK: Surfaces

    var menuBar: ViewContent {
        if showInMenuBar, let soonest = timers.min(by: { $0.end < $1.end }) {
            HStack(spacing: 4) {
                Image(systemName: "timer")
                TimerText(soonest.range)
            }
        } else {
            Label("", symbol: "timer").role(.secondary)
        }
    }

    func row(_ timer: Countdown) -> Row {
        Row(timer.name, subtitle: "Ends \(timer.end.formatted(date: .omitted, time: .shortened))", symbol: "timer", key: timer.id)
            .action("Add 1 Minute") { self.extend(timer.id, by: 60) }
            .action("Add 5 Minutes") { self.extend(timer.id, by: 300) }
            .action("Cancel Timer", role: .critical) { self.cancel(timer.id) }
    }

    var panel: ViewContent {
        PanelHeader("Timers", subtitle: timers.isEmpty ? "Nothing running" : "\(timers.count) running", symbol: "timer", theme: theme)
        if timers.isEmpty {
            EmptyState("Start a timer", symbol: "timer", message: "Pick one below, or open the palette and type Start Timer, then \"10m tea\" or \"17:45 call\".", theme: theme)
        } else {
            Card("Running", spacing: Space.s, padding: Space.s) {
                ForEach(timers.sorted { $0.end < $1.end }) { timer in
                    VStack(alignment: .start, spacing: Space.xs) {
                        HStack(spacing: Space.s) {
                            Text(timer.name).font(size: 13, weight: .semibold)
                            Spacer()
                            TimerText(timer.range).font(size: 13, weight: .semibold)
                        }
                        ProgressBar(timing: timer.range)
                        HStack(spacing: Space.s) {
                            Chip("+1m", theme: theme, key: "plus1-\(timer.id)") { self.extend(timer.id, by: 60) }
                            Chip("+5m", theme: theme, key: "plus5-\(timer.id)") { self.extend(timer.id, by: 300) }
                            Spacer()
                            Chip("Cancel", symbol: "xmark", theme: theme, key: "cancel-\(timer.id)") { self.cancel(timer.id) }
                        }
                    }
                }
            }
        }
        Card("Quick start", spacing: Space.s, padding: Space.s) {
            HStack(spacing: Space.s) {
                ForEach(Array(Set(Self.presets + recent)).sorted { (Self.duration($0) ?? 0) < (Self.duration($1) ?? 0) }.prefix(6)) { length in
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
            self.timers = []
            return .message(count == 0 ? "No timers were running" : "Stopped \(count) timer\(count == 1 ? "" : "s")")
        }
    }
}
