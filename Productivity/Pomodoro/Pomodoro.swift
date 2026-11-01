import StackbarKit
import Foundation

/// A focus timer with its own warm look: Focus and Break modes, presets, a
/// big countdown inside a progress ring, a tag for what you are working on,
/// and today's sessions. Stackbar counts the timer and animates the ring, so
/// the plugin only renders when something changes. Needs nothing.
@main
final class Pomodoro: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.pomodoro",
        name: "Pomodoro",
        version: "1.0.1",
        summary: "A focus timer with presets, a progress ring, tags and today's sessions.",
        surfaces: [.menuBar, .panel, .settings, .widget],
        triggers: [.launch, .every(.seconds(1)), .wake],
        minimumStackbar: "0.12.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/Pomodoro"
    )

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

    struct Day: Codable, Equatable {
        var sessions = 0
        var minutes = 0
    }

    // The look. Every color has a dark variant.
    let cream = Paint.hex("#F7E7D9", dark: "#2B221C")
    let card = Paint.hex("#FFF6EE", dark: "#3A2E26")
    let orange = Paint.hex("#F28C38", dark: "#F59A4E")
    let ink = Paint.hex("#1C1A19", dark: "#F7EDE4")
    /// Text and symbols on orange stay dark in both modes, for contrast.
    let onOrange = Paint.hex("#1C1A19")
    let muted = Paint.hex("#6E625A", dark: "#C9B9AC")
    let track = Paint.hex("#1C1A1914", dark: "#F7EDE41F")

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
            Label(session == nil ? "" : clock(session?.remaining ?? 0), symbol: "timer").role(session == nil ? .secondary : .primary)
        }
    }

    var panel: ViewContent {
        VStack(alignment: .center, spacing: 12) {
            modeToggle
            presets
            countdown
            ring
            tagChip
            stats
            controls
        }
        .padding(18)
        .frame(fillWidth: true)
        .background(cream, in: .roundedRectangle(cornerRadius: 18))
    }

    var widget: ViewContent {
        HStack(spacing: 16) {
            ZStack {
                progress(lineWidth: 7)
                Image(systemName: mode.symbol).font(size: 24).foreground(orange)
            }
            .frame(width: 84, height: 84)
            VStack(alignment: .start, spacing: 2) {
                Text("\(mode.rawValue) · \(currentTag)").font(size: 13, weight: .semibold).foreground(muted)
                timeText.font(size: 44, weight: .heavy, design: .rounded, monospacedDigit: true).foreground(ink)
            }
        }
        .frame(fillWidth: true, fillHeight: true)
        .background(cream, in: .roundedRectangle(cornerRadius: 18))
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
            let state = self.session.map { "\($0.mode.rawValue) on \($0.tag), \(self.clock(self.left($0))) left\($0.started == nil ? " (paused)" : "")" } ?? "Idle"
            return "\(state). Today: \(today.sessions) sessions, \(today.minutes) minutes focused."
        }
    }

    // MARK: - Panel parts

    @ViewBuilder private var modeToggle: ViewContent {
        HStack(spacing: 4) {
            ForEach(Mode.allCases) { option in
                Button(key: "mode-\(option.rawValue)") { self.select(option) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: option.symbol)
                        Text(option.rawValue)
                    }
                    .font(size: 14, weight: .semibold)
                    .foreground(option == mode ? onOrange : muted)
                    .frame(fillWidth: true)
                    .padding(vertical: 9)
                    .background(option == mode ? orange : .hex("#00000000"), in: .capsule)
                }
            }
        }
        .padding(4)
        .background(card, in: .capsule)
        .border(ink, width: 2, in: .capsule)
    }

    @ViewBuilder private var presets: ViewContent {
        HStack(spacing: 10) {
            ForEach(presetMinutes) { minutes in
                Button(key: "preset-\(minutes)") { self.setMinutes(minutes) } label: {
                    Text("\(minutes)")
                        .font(size: 15, weight: .bold, monospacedDigit: true)
                        .foreground(minutes == currentMinutes ? onOrange : ink)
                        .frame(width: 52, height: 34)
                        .background(minutes == currentMinutes ? orange : card, in: .roundedRectangle(cornerRadius: 10))
                        .border(ink, width: 2, in: .roundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    @ViewBuilder private var countdown: ViewContent {
        timeText.font(size: 64, weight: .heavy, design: .rounded, monospacedDigit: true).foreground(ink)
    }

    @ViewBuilder private var ring: ViewContent {
        ZStack {
            progress(lineWidth: 6)
            Button(key: "start") { self.toggle() } label: {
                Image(systemName: isRunning ? "pause.fill" : "play.fill")
                    .font(size: 26, weight: .bold)
                    .foreground(onOrange)
                    .frame(width: 76, height: 76)
                    .background(orange, in: .circle)
                    .border(ink, width: 2, in: .circle)
                    .shadow(radius: 0, x: 2, y: 3, color: HexColor("#1C1A19", dark: "#000000"))
            }
            .accessibilityLabel(isRunning ? "Pause" : "Start")
        }
        .frame(width: 128, height: 128)
    }

    @ViewBuilder private var tagChip: ViewContent {
        Button(key: "tag") { self.nextTag() } label: {
            HStack(spacing: 6) {
                Circle().fill(orange).frame(width: 8, height: 8)
                Text(currentTag)
                // Says the chip changes on a click.
                Image(systemName: "chevron.up.chevron.down").font(size: 10, weight: .bold).foreground(muted)
            }
            .font(size: 13, weight: .semibold)
            .foreground(ink)
            .padding(horizontal: 12, vertical: 5)
            .background(card, in: .capsule)
            .border(ink, width: 1.5, in: .capsule)
        }
        .accessibilityLabel("Change tag: \(currentTag)")
    }

    @ViewBuilder private var stats: ViewContent {
        HStack(spacing: 0) {
            stat("\(today.sessions)", "sessions", symbol: "checkmark.circle.fill")
            Rectangle().fill(track).frame(width: 1, height: 30)
            stat(minutesText(today.minutes), "focused", symbol: "clock.fill")
        }
        .padding(vertical: 10)
        .frame(width: 240)
        .background(card, in: .roundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private func stat(_ value: String, _ caption: String, symbol: String) -> ViewContent {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(size: 15).foreground(muted)
            VStack(spacing: 0) {
                Text(value).font(size: 16, weight: .bold).foreground(ink)
                Text(caption).font(size: 11).foreground(muted)
            }
        }
        .frame(fillWidth: true)
    }

    @ViewBuilder private var controls: ViewContent {
        HStack(spacing: 14) {
            iconButton("forward.fill", label: "Skip", key: "skip") { self.skip() }
            iconButton("repeat", label: autoStart ? "Auto-start on" : "Auto-start off", key: "auto", filled: autoStart) { self.autoStart.toggle() }
            iconButton(sound ? "music.note" : "speaker.slash.fill", label: sound ? "Sound on" : "Sound off", key: "sound", filled: sound) { self.sound.toggle() }
            iconButton("arrow.counterclockwise", label: "Reset", key: "reset") { self.reset() }
        }
    }

    @ViewBuilder private func iconButton(_ symbol: String, label: String, key: String, filled: Bool = false, action: @escaping @MainActor () async throws -> Void) -> ViewContent {
        Button(key: key, action: action) {
            Image(systemName: symbol)
                .font(size: 15, weight: .bold)
                .foreground(filled ? onOrange : ink)
                .frame(width: 40, height: 40)
                .background(filled ? orange : card, in: .circle)
                .border(ink, width: 2, in: .circle)
        }
        .accessibilityLabel(label)
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
            ProgressBar(timing: range, style: .ring(lineWidth: lineWidth)).foreground(orange)
        } else {
            let total = Double(currentMinutes * 60)
            ProgressBar(value: total - (session?.remaining ?? total), total: total, style: .ring(lineWidth: lineWidth)).foreground(orange)
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
