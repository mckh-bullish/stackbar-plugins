import StackbarKit
import Foundation

/// A focus timer in the Stackbar look: Focus and Break modes, presets, a
/// big countdown inside a progress ring, a tag for what you are working on,
/// and today's sessions. Stackbar counts the timer and animates the ring, so
/// the plugin only renders when something changes. Commands start, pause and
/// skip from the palette, a hotkey or a Shortcut, and a stray tap never
/// throws away a session already under way. Needs nothing.
@main
final class Pomodoro: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.pomodoro",
        name: "Pomodoro",
        version: "1.4.0",
        summary: "A focus timer with presets, a progress ring, tags and today's sessions.",
        surfaces: [.menuBar, .panel, .settings, .widget],
        triggers: [.launch, .every(.seconds(1)), .wake],
        minimumStackbar: "0.17.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/Pomodoro",
        accent: .red,
        symbol: "timer"
    )

    // MARK: Previews

    static let previews: [PreviewScene<Pomodoro>] = [
        PreviewScene("hero", "Twenty-five focused minutes, counting down") { plugin in
            plugin.session = Session(mode: .focus, minutes: 25, tag: "Deep Work", started: Date().addingTimeInterval(-498), remaining: 25 * 60)
            plugin.days = [plugin.dayKey: Day(sessions: 3, minutes: 75)]
        },
        PreviewScene("break", "A real break between sessions") { plugin in
            plugin.mode = .rest
            plugin.session = Session(mode: .rest, minutes: 5, tag: "Deep Work", started: Date().addingTimeInterval(-70), remaining: 5 * 60)
            plugin.days = [plugin.dayKey: Day(sessions: 4, minutes: 100)]
        },
        PreviewScene("widget", "Your focus timer on the desktop", surface: .widget) { plugin in
            plugin.session = Session(mode: .focus, minutes: 25, tag: "Deep Work", started: Date().addingTimeInterval(-498), remaining: 25 * 60)
            plugin.days = [plugin.dayKey: Day(sessions: 3, minutes: 75)]
        },
    ]

    enum Mode: String, Codable, CaseIterable {
        case focus = "Focus", rest = "Break"

        var symbol: String { self == .focus ? "flame.fill" : "cup.and.saucer.fill" }
    }

    /// A running session, or a paused one with time left.
    struct Session: Codable, Equatable {
        var mode: Mode
        var minutes: Int
        var tag: String
        var started: Date?
        var remaining: TimeInterval

        var end: Date? { started.map { $0.addingTimeInterval(remaining) } }

        /// The whole session as if it had never paused: the same on every
        /// render, so Stackbar counts it and nothing is resent each second.
        var range: TimeRange? {
            guard let started, let end else { return nil }
            return TimeRange(start: started.addingTimeInterval(remaining - Double(minutes * 60)), end: end)
        }
    }

    /// A tap that would end a session already under way, held until the
    /// user confirms it.
    enum Pending: Equatable {
        case mode(Mode), minutes(Int), skip, reset

        var verb: String {
            switch self {
            case .mode(let mode): return "Switch to \(mode.rawValue)"
            case .minutes(let minutes): return "Start \(minutes) min"
            case .skip: return "Skip"
            case .reset: return "Reset"
            }
        }
    }

    struct Day: Codable, Equatable {
        var sessions = 0
        var minutes = 0
    }

    /// Focus in the tomato red, breaks in a calm teal, from the shared
    /// design system like every other Stackbar plugin.
    var theme: Theme { mode == .focus ? .red : .teal }

    @Stored("mode") var mode = Mode.focus
    @Stored("focusMinutes") var focusMinutes = 25
    @Stored("breakMinutes") var breakMinutes = 5
    @Stored("session") var session: Session? = nil
    @Stored("tags") var tags = ["Deep Work", "Email", "Meetings", "Learning"]
    @Stored("tag") var tag = "Deep Work"
    @Stored("autoStart") var autoStart = false
    @Stored("sound") var sound = true
    @Stored("chime") var chime = SystemSound.glass.rawValue
    @Stored("days") var days: [String: Day] = [:]

    var now = Date()
    var pending: Pending?

    /// How far into a session a tap has to be before it asks first.
    static let protectedAfter: TimeInterval = 60

    func refresh() async throws {
        now = Date()
        if let session, let end = session.end, now >= end { finish(session) }
    }

    // MARK: - Surfaces

    var menuBar: ViewContent {
        if let session, let range = session.range {
            HStack(spacing: 4) {
                Image(systemName: session.mode.symbol)
                TimerText(range)
            }
        } else {
            if let session {
                // Paused: the frozen time, dimmed, behind a pause sign.
                Label(clock(session.remaining), symbol: "pause.fill").role(.secondary)
            } else {
                Label("", symbol: "timer").role(.secondary)
            }
        }
    }

    var panel: ViewContent {
        PanelHeader(headline, subtitle: "\(today.sessions) sessions · \(minutesText(today.minutes)) focused today", symbol: mode.symbol, theme: theme) {
            IconButton("arrow.counterclockwise", label: "Reset", theme: theme, key: "reset") { self.guarded(.reset) }
        }
        if let pending {
            Banner(warning(for: pending), symbol: "hand.raised.fill", theme: theme) {
                ActionButton("Keep going", theme: theme, key: "keep") { self.pending = nil }
                ActionButton(pending.verb, theme: theme, prominent: true, key: "confirm") { self.apply(pending) }
            }
        }
        Picker("Mode", options: Mode.allCases.map(\.rawValue), selection: mode.rawValue, style: .segmented, key: "mode") { choice in
            self.guarded(.mode(Mode(rawValue: choice) ?? .focus))
        }
        HeroCard(theme: theme, look: .glow, alignment: .center, spacing: Space.m) {
            dial(size: 172, lineWidth: 12, timeSize: 40)
            HStack(spacing: Space.xs) {
                ForEach(presetMinutes) { minutes in
                    Chip("\(minutes) min", theme: theme, selected: minutes == currentMinutes, key: "preset-\(minutes)") { self.guarded(.minutes(minutes)) }
                }
            }
            controls
        }
        HStack(spacing: Space.s) {
            StatTile("Sessions", value: "\(today.sessions)", symbol: "checkmark.circle.fill", theme: theme)
            StatTile("Focused", value: minutesText(today.minutes), symbol: "clock.fill", theme: theme)
        }
    }

    var widget: ViewContent {
        HStack(spacing: Space.l) {
            dial(size: 104, lineWidth: 8, timeSize: 22, showTag: false)
            VStack(spacing: Space.xxs) {
                Text(mode.rawValue.uppercased()).typography(.overline).foreground(theme.textPaint)
                Text(currentTag).typography(.title)
                Text("\(today.sessions) sessions · \(minutesText(today.minutes)) today").role(.secondary).typography(.caption)
            }
            .frame(fillWidth: true, alignment: .leading)
        }
        .frame(fillWidth: true, fillHeight: true)
    }

    var settings: ViewContent {
        Section("Durations") {
            Slider("Focus minutes", value: Double(focusMinutes), in: 5...120, step: 5) { self.focusMinutes = Int($0) }
            Slider("Break minutes", value: Double(breakMinutes), in: 1...30, step: 1) { self.breakMinutes = Int($0) }
            Toggle("Start the next session on its own", isOn: autoStart) { self.autoStart = $0 }
        }
        Section("Sound") {
            Toggle("Play a sound when a session ends", isOn: sound) { self.sound = $0 }
            Picker("Sound", options: SystemSound.allCases.map(\.rawValue), selection: chime) { self.chime = $0 }
        }
        Section("Tags") {
            ForEach(tags) { name in
                Row(name, symbol: "tag", key: "tag-\(name)").action("Remove") { self.tags.removeAll { $0 == name } }
            }
            TextField("Add a tag", text: "") { submitted in
                let name = submitted.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !self.tags.contains(name) { self.tags.append(name) }
            }
        }
    }

    var tools: [AgentTool] {
        AgentTool("status", description: "The timer's mode, time left and today's focus") { _ in
            let today = self.today
            return "\(self.statusLine). Today: \(today.sessions) sessions, \(today.minutes) minutes focused."
        }
    }

    var commands: [Command] {
        Command("toggle", title: "Start or Pause Pomodoro", symbol: "playpause.fill", keywords: ["pomodoro", "timer", "focus", "pause", "resume", "tomato"]) { _ in
            self.toggle()
            return .message(self.statusLine)
        }
        Command("start-focus", title: "Start a Focus Session", subtitle: "Optionally a length in minutes and a tag", symbol: Mode.focus.symbol, keywords: ["pomodoro", "timer", "focus", "work", "tomato"]) { invocation in
            self.command(.focus, minutes: invocation["minutes"], tag: invocation["tag"])
        }
        .argument("minutes", placeholder: "\(focusMinutes)", required: false)
        .argument("tag", placeholder: tag, required: false, options: tags)
        Command("start-break", title: "Take a Break", subtitle: "Optionally a length in minutes", symbol: Mode.rest.symbol, keywords: ["pomodoro", "timer", "break", "rest", "tomato"]) { invocation in
            self.command(.rest, minutes: invocation["minutes"], tag: nil)
        }
        .argument("minutes", placeholder: "\(breakMinutes)", required: false)
        Command("skip", title: "Skip to the Next Pomodoro Session", symbol: "forward.fill", keywords: ["pomodoro", "timer", "skip", "next"]) { _ in
            self.skip()
            return .message("Up next: \(self.mode.rawValue), \(self.currentMinutes) min")
        }
        Command("reset", title: "Reset Pomodoro", symbol: "arrow.counterclockwise", keywords: ["pomodoro", "timer", "reset", "stop", "cancel"]) { _ in
            self.reset()
            return .message("Pomodoro reset")
        }
    }

    // MARK: - Panel parts

    private var headline: String {
        if isRunning { return mode == .focus ? "Focusing" : "On a break" }
        return session != nil ? "Paused" : (mode == .focus ? "Ready to focus" : "Ready for a break")
    }

    /// The ring with the countdown in the middle and, under it, the tag,
    /// which changes on a click.
    @ViewBuilder private func dial(size: Double, lineWidth: Double, timeSize: Double, showTag: Bool = true) -> ViewContent {
        ZStack {
            // A neutral track, so the ring still shows before it fills.
            Circle().stroke(.hex("#00000017", dark: "#FFFFFF1F"), lineWidth: lineWidth)
            progress(lineWidth: lineWidth)
            VStack(alignment: .center, spacing: Space.xxs) {
                if isRunning {
                    Image(systemName: mode.symbol).font(size: timeSize * 0.4, weight: .semibold).foreground(theme.textPaint).symbolEffect(.breathe)
                } else {
                    Image(systemName: mode.symbol).font(size: timeSize * 0.4, weight: .semibold).foreground(theme.textPaint)
                }
                timeText.typography(Typography(size: timeSize, weight: .bold, design: .rounded, monospacedDigit: true))
                if showTag {
                    Chip(currentTag, symbol: "tag.fill", theme: theme, key: "tag") { self.nextTag() }
                        .accessibilityLabel("Change tag: \(currentTag)")
                }
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var controls: ViewContent {
        HStack(alignment: .center, spacing: Space.m) {
            IconButton(autoStart ? "repeat" : "repeat.1", label: autoStart ? "Auto-start on" : "Auto-start off", theme: theme, size: 34, key: "auto") { self.autoStart.toggle() }
            IconButton("forward.fill", label: "Skip", theme: theme, size: 34, key: "skip") { self.guarded(.skip) }
            IconButton(isRunning ? "pause.fill" : "play.fill", label: isRunning ? "Pause" : "Start", theme: theme, prominence: .filled, size: 52, key: "start") { self.toggle() }
            IconButton(sound ? "speaker.wave.2.fill" : "speaker.slash.fill", label: sound ? "Sound on" : "Sound off", theme: theme, size: 34, key: "sound") { self.sound.toggle() }
        }
    }

    @ViewBuilder private var timeText: ViewContent {
        if let range = session?.range {
            TimerText(range)
        } else {
            Text(clock(session?.remaining ?? Double(currentMinutes * 60)))
        }
    }

    @ViewBuilder private func progress(lineWidth: Double) -> ViewContent {
        if let range = session?.range {
            ProgressBar(timing: range, style: .ring(lineWidth: lineWidth)).foreground(theme.sweep)
        } else {
            let total = Double(currentMinutes * 60)
            ProgressBar(value: total - (session?.remaining ?? total), total: total, style: .ring(lineWidth: lineWidth)).foreground(theme.sweep)
        }
    }

    // MARK: - State

    private var isRunning: Bool { session?.started != nil }
    private var currentMinutes: Int { session?.minutes ?? (mode == .focus ? focusMinutes : breakMinutes) }
    private var currentTag: String { session?.tag ?? tag }
    private var presetMinutes: [Int] { mode == .focus ? [25, 50, 90] : [5, 10, 15] }

    private var dayKey: String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private var today: Day { days[dayKey] ?? Day() }

    private func left(_ session: Session) -> TimeInterval {
        session.end.map { max(0, $0.timeIntervalSince(now)) } ?? session.remaining
    }

    /// One line on where the timer stands, for commands and the agent tool.
    private var statusLine: String {
        now = Date()
        guard let session else { return "Idle. Next: \(mode.rawValue), \(currentMinutes) min" }
        let state = session.started == nil ? "Paused" : (session.mode == .focus ? "Focusing" : "On a break")
        return "\(state)\(session.mode == .focus ? " on \(session.tag)" : ""), \(clock(left(session))) left"
    }

    /// Seconds of the current session already behind the user.
    private var progress: TimeInterval {
        guard let session else { return 0 }
        return Double(session.minutes * 60) - left(session)
    }

    /// Applies a tap now, or, when it would end a session more than a
    /// minute in, asks first with a banner.
    private func guarded(_ change: Pending) {
        now = Date()
        if session != nil, progress >= Self.protectedAfter {
            pending = change
        } else {
            apply(change)
        }
    }

    private func apply(_ change: Pending) {
        pending = nil
        switch change {
        case .mode(let mode): select(mode)
        case .minutes(let minutes): setMinutes(minutes)
        case .skip: skip()
        case .reset: reset()
        }
    }

    private func warning(for change: Pending) -> String {
        let done = "\(Int(progress / 60)) min in"
        switch change {
        case .skip: return "Skipping ends this session without counting it (\(done))."
        case .reset: return "Resetting throws away this session (\(done))."
        case .mode, .minutes: return "This ends the session you are in (\(done))."
        }
    }

    /// What a start command does: resumes or reports a session of the same
    /// kind, otherwise starts a fresh one with any minutes and tag given.
    private func command(_ kind: Mode, minutes text: String?, tag name: String?) -> CommandResult {
        let text = text?.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "min", with: "").trimmingCharacters(in: .whitespaces) ?? ""
        let name = name?.trimmingCharacters(in: .whitespaces) ?? ""
        var minutes: Int?
        if !text.isEmpty {
            guard let value = Int(text), (1...180).contains(value) else { return .failure("Give a length between 1 and 180 minutes") }
            minutes = value
        }
        if let session, session.mode == kind, minutes == nil, name.isEmpty {
            if session.started == nil { toggle() }
            return .message(statusLine)
        }
        now = Date()
        pending = nil
        mode = kind
        if !name.isEmpty { tag = name }
        let length = minutes ?? (kind == .focus ? focusMinutes : breakMinutes)
        session = Session(mode: kind, minutes: length, tag: tag, started: now, remaining: Double(length * 60))
        return .message(statusLine)
    }

    private func toggle() {
        now = Date()
        if var session {
            if session.started != nil {
                session.remaining = left(session)
                session.started = nil
            } else {
                session.started = now
            }
            self.session = session
        } else {
            session = Session(mode: mode, minutes: currentMinutes, tag: tag, started: now, remaining: Double(currentMinutes * 60))
        }
    }

    private func select(_ option: Mode) {
        guard option != mode else { return }
        mode = option
        session = nil
    }

    private func setMinutes(_ minutes: Int) {
        if mode == .focus { focusMinutes = minutes } else { breakMinutes = minutes }
        session = nil
    }

    private func nextTag() {
        guard !tags.isEmpty else { return }
        let index = tags.firstIndex(of: currentTag).map { ($0 + 1) % tags.count } ?? 0
        tag = tags[index]
        session?.tag = tag
    }

    private func skip() {
        if let session { finish(session, counted: false) } else { select(mode == .focus ? .rest : .focus) }
    }

    private func reset() {
        pending = nil
        session = nil
    }

    /// Ends a session: counts a finished focus session, chimes, and moves to
    /// the other mode, starting it when auto-start is on.
    private func finish(_ ended: Session, counted: Bool = true) {
        if counted && ended.mode == .focus {
            var day = today
            day.sessions += 1
            day.minutes += ended.minutes
            days[dayKey] = day
            for old in days.keys.sorted().dropLast(60) { days[old] = nil }
        }
        if counted && sound, let chime = SystemSound(rawValue: chime) { Stackbar.play(chime) }
        if counted { Stackbar.notify(ended.mode == .focus ? "Focus done" : "Break over", body: ended.mode == .focus ? "\(ended.minutes) minutes on \(ended.tag). Time for a break." : "Back to it.") }
        mode = ended.mode == .focus ? .rest : .focus
        pending = nil
        session = nil
        if autoStart { toggle() }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func minutesText(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
