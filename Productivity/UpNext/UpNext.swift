import StackbarKit
import Foundation

/// Your next meeting in the menu bar, with a one-click join.
///
/// It reads the calendars you have in Calendar.app (through the host, which
/// asks for access once), finds the video link in the location, URL or notes
/// (Zoom, Meet, Teams, Webex and a dozen more), counts down to it, reminds
/// you a few minutes before, and can open the call for you when it starts.
@main
final class UpNext: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.up-next",
        name: "Up Next",
        version: "1.3.1",
        summary: "Your next meeting in the menu bar, with a countdown and one-click join.",
        surfaces: [.menuBar, .panel, .window, .widget, .settings],
        triggers: [.launch, .every(.seconds(30)), .wake],
        capabilities: [.calendar],
        hotkey: "ctrl+option+j",
        minimumStackbar: "0.14.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/UpNext",
        accent: .red,
        symbol: "calendar"
    )

    // MARK: Meeting links

    struct Service {
        let name: String
        /// Lowercased fragments a link to this service contains.
        let patterns: [String]
    }

    /// Known video services, most specific first.
    static let services: [Service] = [
        Service(name: "Zoom", patterns: ["zoom.us/j/", "zoom.us/my/", "zoom.us/w/", "zoomgov.com/j/", "zoom.us/s/"]),
        Service(name: "Google Meet", patterns: ["meet.google.com/"]),
        Service(name: "Teams", patterns: ["teams.microsoft.com/l/meetup-join", "teams.live.com/meet", "teams.microsoft.com/meet"]),
        Service(name: "Webex", patterns: [".webex.com/meet", ".webex.com/join", ".webex.com/wbxmjs", ".webex.com/"]),
        Service(name: "Slack huddle", patterns: ["app.slack.com/huddle"]),
        Service(name: "FaceTime", patterns: ["facetime.apple.com/join"]),
        Service(name: "Chime", patterns: ["chime.aws/"]),
        Service(name: "GoTo Meeting", patterns: ["gotomeeting.com/join", "gotomeet.me/", "meet.goto.com/"]),
        Service(name: "Whereby", patterns: ["whereby.com/"]),
        Service(name: "Jitsi", patterns: ["meet.jit.si/"]),
        Service(name: "BlueJeans", patterns: ["bluejeans.com/"]),
        Service(name: "Around", patterns: ["around.co/"]),
        Service(name: "Tuple", patterns: ["tuple.app/c/"]),
        Service(name: "Gather", patterns: ["app.gather.town/"]),
        Service(name: "Skype", patterns: ["join.skype.com/"]),
        Service(name: "Discord", patterns: ["discord.gg/", "discord.com/channels/"]),
        Service(name: "Zoho Meeting", patterns: ["meeting.zoho.com/", "meeting.zoho.eu/"]),
        Service(name: "Livestorm", patterns: ["app.livestorm.co/"]),
    ]

    struct MeetingLink: Equatable {
        let url: String
        let service: String
    }

    /// The first video-call link in the event's location, URL or notes.
    static func meetingLink(for event: CalendarEvent) -> MeetingLink? {
        for text in [event.location, event.url, event.notes].compactMap({ $0 }) {
            for url in links(in: text) {
                let lower = url.lowercased()
                if let service = services.first(where: { service in service.patterns.contains { lower.contains($0) } }) {
                    return MeetingLink(url: url, service: service.name)
                }
            }
        }
        return nil
    }

    /// Every http(s) URL in a piece of text, without trailing punctuation.
    static func links(in text: String) -> [String] {
        var result: [String] = []
        var rest = Substring(text)
        while let start = rest.range(of: "https://", options: .caseInsensitive) ?? rest.range(of: "http://", options: .caseInsensitive) {
            let tail = rest[start.lowerBound...]
            let end = tail.firstIndex(where: { $0.isWhitespace || "<>\"'()[]{}".contains($0) }) ?? tail.endIndex
            var url = String(tail[..<end])
            while let last = url.last, ".,;:!?".contains(last) { url.removeLast() }
            if url.count > 10 { result.append(url) }
            rest = tail[end...]
        }
        return result
    }

    // MARK: State

    @Stored("hiddenCalendars") var hiddenCalendars: [String] = []
    @Stored("showAllDay") var showAllDay = true
    @Stored("showDeclined") var showDeclined = false
    @Stored("onlyWithLinks") var onlyWithLinks = false
    @Stored("remindMinutes") var remindMinutes = 2.0
    @Stored("autoJoin") var autoJoin = false
    /// Cover the screen when a meeting starts, so it can't be missed.
    @Stored("fullScreenAlert") var fullScreenAlert = false
    @Stored("titleLength") var titleLength = 24.0
    @Stored("showTitle") var showTitle = true
    @Stored("openInApps") var openInApps = true
    @Stored("onlyWithPeople") var onlyWithPeople = false
    @Stored("showFinished") var showFinished = false
    /// Show the next meeting in the menu bar only this many hours ahead (0: any time today).
    @Stored("menuBarHours") var menuBarHours = 0.0

    var events: [CalendarEvent] = []
    var calendars: [String] = []
    var lastError: String?
    var loaded = false
    private var reminded: Set<String> = []
    private var joined: Set<String> = []
    private var alerted: Set<String> = []

    func refresh() async throws {
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        guard let end = Calendar.current.date(byAdding: .day, value: 7, to: start) else { return }
        do {
            let all = try await Stackbar.calendarEvents(from: start, to: end)
            calendars = Array(Set(all.map(\.calendar))).sorted()
            events = all
            lastError = nil
            loaded = true
        } catch {
            lastError = "\(error)"
            return
        }
        remindAndJoin(now: now)
    }

    /// The events the settings let through.
    var visible: [CalendarEvent] {
        events.filter { event in
            !hiddenCalendars.contains(event.calendar)
                && (showAllDay || !event.isAllDay)
                && (showDeclined || event.participation != .declined)
                && (!onlyWithLinks || event.isAllDay || Self.meetingLink(for: event) != nil)
                && (!onlyWithPeople || event.isAllDay || event.attendees > 1)
        }
    }

    /// Timed events that haven't ended, soonest first.
    func upcoming(now: Date = Date()) -> [CalendarEvent] {
        visible.filter { !$0.isAllDay && $0.end > now && $0.participation != .declined }.sorted { $0.start < $1.start }
    }

    /// What's on now (the latest-started one), else what's next today.
    func focus(now: Date = Date()) -> CalendarEvent? {
        let soon = upcoming(now: now)
        if let current = soon.filter({ $0.start <= now }).max(by: { $0.start < $1.start }) {
            // A meeting about to start beats one that is ending.
            if let next = soon.first(where: { $0.start > now }), next.start.timeIntervalSince(now) <= 5 * 60, current.end.timeIntervalSince(now) <= 5 * 60 { return next }
            return current
        }
        // Today's next one, or one soon after midnight (a late-night call
        // shouldn't vanish because the date changes first).
        return soon.first { Calendar.current.isDate($0.start, inSameDayAs: now) || $0.start.timeIntervalSince(now) <= 3 * 3600 }
    }

    func remindAndJoin(now: Date) {
        for event in upcoming(now: now) {
            let until = event.start.timeIntervalSince(now)
            if remindMinutes > 0, until > 0, until <= remindMinutes * 60 + 15, !reminded.contains(event.id) {
                reminded.insert(event.id)
                let link = Self.meetingLink(for: event)
                Stackbar.notify(
                    "\(event.title) in \(max(1, Int((until / 60).rounded()))) min",
                    body: link.map { "On \($0.service)" } ?? event.location,
                    actions: link.map { [NotificationAction("Join", url: openInApps ? Self.appURL(for: $0) : $0.url)] } ?? []
                )
            }
            if fullScreenAlert, until <= 60, until > -60, !alerted.contains(event.id) {
                alerted.insert(event.id)
                let link = Self.meetingLink(for: event)
                var actions = link.map { [NotificationAction("Join on \($0.service)", url: openInApps ? Self.appURL(for: $0) : $0.url)] } ?? []
                if let dial = Self.dialIn(for: event) { actions.append(NotificationAction("Call in", url: dial.tel)) }
                Stackbar.alert(event.title, body: until > 0 ? "Starts at \(Self.time(event.start))" + (event.organizer.map { " · \($0)" } ?? "") : "Started at \(Self.time(event.start))", actions: actions)
            }
            if autoJoin, until <= 30, now < event.start.addingTimeInterval(120), !joined.contains(event.id), let link = Self.meetingLink(for: event) {
                joined.insert(event.id)
                Stackbar.open(link.url)
            }
        }
        if reminded.count > 200 { reminded = Set(reminded.suffix(50)) }
        if joined.count > 200 { joined = Set(joined.suffix(50)) }
        if alerted.count > 200 { alerted = Set(alerted.suffix(50)) }
    }

    func join(_ event: CalendarEvent) {
        if let link = Self.meetingLink(for: event) {
            joined.insert(event.id)
            Stackbar.open(openInApps ? Self.appURL(for: link) : link.url)
        } else if let url = event.url {
            Stackbar.open(url)
        }
    }

    /// A phone dial-in from the event: a `tel:` link, or a number starting
    /// with + (Zoom's "+16465588656,,123456789#" included). `tel` keeps the
    /// pauses and PIN so the call dials straight in.
    static func dialIn(for event: CalendarEvent) -> (display: String, tel: String)? {
        for text in [event.location, event.notes].compactMap({ $0 }) {
            if let match = text.firstMatch(of: /tel:(\+?[0-9,;#*]{7,})/) {
                let number = String(match.1)
                return (number.replacingOccurrences(of: ",", with: " ").trimmingCharacters(in: .whitespaces), "tel:" + number.replacingOccurrences(of: "#", with: "%23"))
            }
            if let match = text.firstMatch(of: /\+\d[\d \-().]{6,}\d(?:,,\d+#?)?/) {
                let raw = String(match.0)
                let digits = raw.filter { $0.isNumber || $0 == "+" || $0 == "," || $0 == "#" }
                guard digits.filter(\.isNumber).count >= 8 else { continue }
                return (raw.components(separatedBy: ",,").first ?? raw, "tel:" + digits.replacingOccurrences(of: "#", with: "%23"))
            }
        }
        return nil
    }

    /// The meeting app's own URL for Zoom and Teams links, so joining opens
    /// the app without leaving a browser tab behind. Other links stay https.
    static func appURL(for link: MeetingLink) -> String {
        guard let url = URLComponents(string: link.url), let host = url.host?.lowercased() else { return link.url }
        if link.service == "Zoom", url.path.hasPrefix("/j/") {
            let number = url.path.dropFirst(3).prefix { $0.isNumber }
            guard !number.isEmpty else { return link.url }
            var app = URLComponents()
            app.scheme = "zoommtg"
            app.host = host
            app.path = "/join"
            app.queryItems = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: String(number))]
                + (url.queryItems ?? []).filter { $0.name == "pwd" }
            return app.string ?? link.url
        }
        if link.service == "Teams", link.url.lowercased().hasPrefix("https://teams.microsoft.com/") {
            return "msteams:" + link.url.dropFirst("https://teams.microsoft.com".count)
        }
        return link.url
    }

    static let instantMeetings: [(name: String, url: String)] = [
        ("Google Meet", "https://meet.google.com/new"),
        ("Zoom", "https://zoom.us/start/videomeeting"),
        ("Teams", "https://teams.microsoft.com/l/meeting/new"),
    ]

    // MARK: Words

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    static func span(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "\(max(1, minutes))m" }
        let hours = minutes / 60
        return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m"
    }

    func countdown(_ event: CalendarEvent, now: Date = Date()) -> String {
        if event.start <= now { return "\(Self.span(event.end.timeIntervalSince(now))) left" }
        return "in \(Self.span(event.start.timeIntervalSince(now)))"
    }

    func shortTitle(_ title: String) -> String {
        let limit = max(4, Int(titleLength))
        return title.count > limit ? String(title.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : title
    }

    func subtitle(_ event: CalendarEvent) -> String {
        var parts: [String] = []
        parts.append(event.isAllDay ? "All day" : "\(Self.time(event.start))–\(Self.time(event.end))")
        if let link = Self.meetingLink(for: event) {
            parts.append(link.service)
        } else if let location = event.location, !location.isEmpty {
            parts.append(location.count > 40 ? String(location.prefix(39)) + "…" : location)
        }
        if event.attendees > 1 { parts.append("\(event.attendees) people") }
        parts.append(event.calendar)
        return parts.joined(separator: " · ")
    }

    // MARK: Surfaces

    let theme = Theme.red

    var menuBar: ViewContent {
        if lastError != nil && !loaded {
            Label("", symbol: "calendar.badge.exclamationmark").role(.warning)
        } else if let event = focus(), menuBarHours == 0 || event.start.timeIntervalSinceNow <= menuBarHours * 3600 {
            let symbol = Self.meetingLink(for: event) != nil ? "video" : "calendar"
            let until = event.start.timeIntervalSinceNow
            if until > 0, until <= 10 * 60 {
                // The host counts down, so it never says "in 1m" as the call starts.
                HStack(spacing: Space.xs) {
                    Image(systemName: symbol)
                    if showTitle { Text(shortTitle(event.title) + " ·") }
                    TimerText(TimeRange(start: Date(), end: event.start))
                }
                .foreground(.role(.warning))
            } else {
                Label(showTitle ? "\(shortTitle(event.title)) · \(countdown(event))" : countdown(event), symbol: symbol).role(.primary)
            }
        } else {
            Label("", symbol: "calendar").role(.secondary)
        }
    }

    var panel: ViewContent {
        let now = Date()
        if let lastError, !loaded {
            EmptyState("Allow calendar access", symbol: "calendar.badge.exclamationmark", message: lastError, theme: theme) {
                ActionButton("Try Again", symbol: "arrow.clockwise", theme: theme, prominent: true) { try await self.refresh() }
            }
        } else {
            header(now: now)
            if let lastError { Banner(lastError) }
            hero(now: now)
            if loaded, !meetings(on: now).isEmpty { dayCard(now: now) }
            List(searchable: true) {
                day("Today", now, now: now)
                if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) {
                    day("Tomorrow", tomorrow, now: now)
                }
            }
        }
    }

    @ViewBuilder func header(now: Date) -> ViewContent {
        let count = meetings(on: now).count
        let hours = meetingHours(on: now)
        PanelHeader(now.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                    subtitle: !loaded ? "Reading your calendars…" : count == 0 ? "No meetings today" : "\(count) meeting\(count == 1 ? "" : "s") today · \(Self.hours(hours))",
                    symbol: "calendar", theme: theme)
    }

    /// What's on now or next, as big as the panel gets.
    @ViewBuilder func hero(now: Date) -> ViewContent {
        if let event = focus(now: now) {
            let link = Self.meetingLink(for: event)
            let dial = Self.dialIn(for: event)
            let started = event.start <= now
            // Sized by its content, unlike a Backdrop, so there's no empty band.
            VStack(spacing: Space.m) {
                HStack(alignment: .end, spacing: Space.m) {
                    VStack(spacing: Space.xxs) {
                        HStack(spacing: Space.xs) {
                            Image(systemName: started ? "record.circle.fill" : "clock.fill").font(size: 10, weight: .bold).symbolEffect(started ? .pulse : .breathe)
                            Text(started ? "NOW" : "NEXT").typography(.overline)
                        }
                        Text(Self.clipped(event.title, 30)).typography(Typography(size: 18, weight: .bold))
                        Text(heroDetail(event)).typography(.caption).opacity(0.85)
                    }
                    .frame(fillWidth: true, alignment: .leading)
                    clock(event, now: now)
                }
                if link != nil || dial != nil {
                    HStack(spacing: Space.s) {
                        if let link {
                            ActionButton("Join \(link.service)", symbol: "video.fill", theme: theme, prominent: true, fillWidth: true, key: "join-focus") { self.join(event) }
                        }
                        if let dial {
                            Button(key: "call-focus", action: { Stackbar.open(dial.tel) }) {
                                HStack(spacing: Space.xs) {
                                    Image(systemName: "phone.fill").font(size: 12, weight: .semibold)
                                    Text("Call in").typography(.headline)
                                }
                                .padding(horizontal: Space.m, vertical: Space.s)
                                .frame(fillWidth: link == nil)
                                .background(.material(.glass), in: .capsule)
                            }
                        }
                    }
                }
            }
            .foreground(.onMedia)
            .padding(Space.l)
            .frame(fillWidth: true, alignment: .leading)
            .background(.scrim, in: .roundedRectangle(cornerRadius: Radius.large + 2))
            .background(stage(for: event), in: .roundedRectangle(cornerRadius: Radius.large + 2))
        } else if loaded {
            HeroCard(theme: theme, spacing: Space.s) {
                HStack(spacing: Space.m) {
                    IconTile("sun.max.fill", theme: .amber, size: 40)
                    VStack(spacing: Space.xxs) {
                        Text("Nothing else today").typography(.title)
                        Text("Enjoy the focus time").role(.secondary).typography(.caption)
                    }
                    .frame(fillWidth: true, alignment: .leading)
                }
                startChips
            }
        }
        if focus(now: now) != nil || !loaded {
            startChips
        }
    }

    /// Start an instant call: chips, so picking the same one twice works.
    @ViewBuilder var startChips: ViewContent {
        HStack(spacing: Space.xs + 2) {
            Text("Start a call").role(.secondary).typography(.caption)
            ForEach(Self.instantMeetings) { meeting in
                Chip(meeting.name == "Google Meet" ? "Meet" : meeting.name,
                     theme: theme, key: "start-\(meeting.name)") { Stackbar.open(meeting.url) }
            }
            Spacer()
        }
    }

    /// The stage behind the next meeting: its calendar's color, deepening
    /// to night, so the hero says which calendar at a glance.
    func stage(for event: CalendarEvent) -> Paint {
        guard let color = event.calendarColor, HexColor.components(color) != nil else { return theme.vivid }
        return .gradient([color, "#1B1530"], angle: 45)
    }

    /// Time left as a ring once it has started, else a countdown.
    @ViewBuilder func clock(_ event: CalendarEvent, now: Date) -> ViewContent {
        if event.start <= now {
            ZStack {
                Circle().stroke(.hex("#FFFFFF40"), lineWidth: 5)
                ProgressBar(timing: TimeRange(start: event.start, end: event.end), style: .ring(lineWidth: 5)).foreground(.onMedia)
                VStack(alignment: .center, spacing: 0) {
                    Text(Self.span(event.end.timeIntervalSince(now))).typography(Typography(size: 14, weight: .bold, design: .rounded, monospacedDigit: true)).numericTransition()
                    Text("left").typography(.caption).opacity(0.8)
                }
            }
            .frame(width: 62, height: 62)
        } else if event.start.timeIntervalSince(now) < 3600 {
            VStack(alignment: .end, spacing: 0) {
                TimerText(TimeRange(start: now, end: event.start)).typography(Typography(size: 26, weight: .heavy, design: .rounded, monospacedDigit: true))
                Text("until it starts").typography(.caption).opacity(0.8)
            }
        } else {
            Text(countdown(event, now: now)).typography(Typography(size: 26, weight: .heavy, design: .rounded, monospacedDigit: true)).numericTransition()
        }
    }

    static func clipped(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    func heroDetail(_ event: CalendarEvent) -> String {
        var parts = ["\(Self.time(event.start))–\(Self.time(event.end))"]
        if let link = Self.meetingLink(for: event) {
            parts.append(link.service)
        } else if let location = event.location, !location.isEmpty {
            parts.append(location.count > 30 ? String(location.prefix(29)) + "…" : location)
        }
        if event.attendees > 1 { parts.append("\(event.attendees) people") }
        return parts.joined(separator: " · ")
    }

    /// Today's meetings on a bar from the morning to the evening, with now marked.
    @ViewBuilder func dayCard(now: Date) -> ViewContent {
        let start = Calendar.current.startOfDay(for: now)
        let todays = meetings(on: now)
        let first = min(8, todays.map { Int($0.start.timeIntervalSince(start) / 3600) }.min() ?? 8)
        let last = max(20, todays.map { Int(($0.end.timeIntervalSince(start) / 3600).rounded(.up)) }.max() ?? 20)
        let from = start.addingTimeInterval(Double(max(0, first)) * 3600)
        let span = Double(min(24, last) - max(0, first)) * 3600
        let fraction = { (date: Date) in date.timeIntervalSince(from) / span }
        Card(spacing: Space.xs + 2) {
            DayBar(todays.map { fraction($0.start)...max(fraction($0.start), fraction($0.end)) }, now: (0...1).contains(fraction(now)) ? fraction(now) : nil, theme: theme)
            HStack {
                ForEach(Array(stride(from: max(0, first), through: min(24, last), by: max(1, (min(24, last) - max(0, first)) / 3)).enumerated())) { index, hour in
                    if index > 0 { Spacer() }
                    Text("\(hour)").role(.secondary).typography(.captionNumber)
                }
            }
            .frame(width: 332)
        }
    }

    /// The window adds the week's meeting load.
    var window: ViewContent {
        panel
        if loaded {
            let calendar = Calendar.current
            let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: Date()) }
            let load = days.map { (meetingHours(on: $0) * 10).rounded() / 10 }
            Card("Meeting load", detail: "\(Self.hours(load.reduce(0, +))) in the next 7 days", spacing: Space.s) {
                Chart(values: load, kind: .bar, labels: days.map { calendar.shortWeekdaySymbols[calendar.component(.weekday, from: $0) - 1] }, unit: "h", goal: 4, highlight: 0)
                    .foreground(theme.solidPaint)
            }
            let today = byCalendar(on: Date())
            if today.count > 1 {
                Card("Today by calendar", spacing: Space.s) {
                    Chart(values: today.map(\.hours), kind: .donut, labels: today.map(\.name), unit: "h")
                }
            }
        }
    }

    /// A working day, for the "in meetings today" gauge.
    static let workday = 8.0

    static func hours(_ value: Double) -> String {
        let minutes = Int((value * 60).rounded())
        return minutes >= 60 ? "\(minutes / 60)h" + (minutes % 60 > 0 ? " \(minutes % 60)m" : "") : "\(minutes)m"
    }

    /// Timed events you go to (not declined) that overlap the day.
    func meetings(on date: Date) -> [CalendarEvent] {
        let start = Calendar.current.startOfDay(for: date)
        let end = start.addingTimeInterval(86400)
        return visible.filter { !$0.isAllDay && $0.participation != .declined && $0.start < end && $0.end > start }
    }

    /// Hours of the day in meetings, overlaps counted once.
    func meetingHours(on date: Date) -> Double {
        let start = Calendar.current.startOfDay(for: date)
        let end = start.addingTimeInterval(86400)
        let spans = meetings(on: date).map { (max($0.start, start), min($0.end, end)) }.sorted { $0.0 < $1.0 }
        var total = 0.0
        var cursor = start
        for (from, to) in spans where to > cursor {
            total += to.timeIntervalSince(max(from, cursor))
            cursor = to
        }
        return total / 3600
    }

    func byCalendar(on date: Date) -> [(name: String, hours: Double)] {
        let start = Calendar.current.startOfDay(for: date)
        let end = start.addingTimeInterval(86400)
        let grouped = Dictionary(grouping: meetings(on: date), by: \.calendar).mapValues { events in
            events.reduce(0.0) { $0 + min($1.end, end).timeIntervalSince(max($1.start, start)) / 3600 }
        }
        return grouped.map { (name: $0.key, hours: ($0.value * 10).rounded() / 10) }.sorted { $0.hours > $1.hours }
    }

    @ViewBuilder func day(_ title: String, _ date: Date, now: Date) -> ViewContent {
        let dayStart = Calendar.current.startOfDay(for: date)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        // Timed events first (soonest on top, so Return joins it), all-day ones after.
        let items = visible.filter { $0.start < dayEnd && $0.end > dayStart && (showFinished || $0.isAllDay || $0.end > now) }
            .sorted { ($0.isAllDay ? 1 : 0, $0.start) < ($1.isAllDay ? 1 : 0, $1.start) }
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { event in row(event, now: now) }
            }
        }
    }

    func row(_ event: CalendarEvent, now: Date) -> Row {
        let link = Self.meetingLink(for: event)
        let past = !event.isAllDay && event.end <= now
        var row = Row(event.title, subtitle: subtitle(event), symbol: event.isAllDay ? "sun.max" : link != nil ? "video" : "calendar", key: event.id)
        switch event.participation {
        case .declined: row = row.badge("Declined", role: .critical)
        case .tentative: row = row.badge("Maybe", role: .warning)
        case .pending: row = row.badge("Invited", role: .warning)
        default:
            if past {
                break
            } else if !event.isAllDay, event.start <= now {
                row = row.badge("Now", role: .accent)
            } else if !event.isAllDay, event.start.timeIntervalSince(now) < 3600 {
                row = row.badge(countdown(event, now: now), role: .primary)
            }
        }
        if let link {
            row = row.action("Join on \(link.service)", shortcut: "cmd+return") { self.join(event) }
                .action("Copy meeting link") { Stackbar.copy(link.url) }
        }
        if let url = event.url, url != link?.url {
            row = row.action("Open event link") { Stackbar.open(url) }
        }
        if let dial = Self.dialIn(for: event) {
            row = row.action("Call in (\(dial.display))") { Stackbar.open(dial.tel) }
                .action("Copy dial-in number") { Stackbar.copy(dial.display) }
        }
        return row.action("Copy details") {
            Stackbar.copy([event.title, self.subtitle(event), link?.url].compactMap { $0 }.joined(separator: "\n"))
        }
    }

    static let remindChoices: [(title: String, minutes: Double)] = [("Off", 0), ("1 min before", 1), ("2 min before", 2), ("5 min before", 5), ("10 min before", 10)]
    static let titleChoices: [(title: String, length: Double)] = [("Hidden", 0), ("Short", 16), ("Medium", 24), ("Long", 32)]

    /// Stackbar's Settings window, so the panel stays about the day.
    var settings: ViewContent {
        Section("Reminders and joining") {
            Picker("Remind me", options: Self.remindChoices.map(\.title), selection: Self.remindChoices.first { $0.minutes == remindMinutes }?.title ?? "\(Int(remindMinutes)) min before", key: "remind") { title in
                self.remindMinutes = Self.remindChoices.first { $0.title == title }?.minutes ?? self.remindMinutes
            }
            Toggle("Open the call when it starts", isOn: autoJoin) { self.autoJoin = $0 }
            Toggle("Open Zoom and Teams in their apps", isOn: openInApps) { self.openInApps = $0 }
            Toggle("Cover the screen when a meeting starts", isOn: fullScreenAlert) { self.fullScreenAlert = $0 }
        }
        Section("Menu bar") {
            Picker("Title", options: Self.titleChoices.map(\.title), selection: showTitle ? Self.titleChoices.first { $0.length == titleLength }?.title ?? "\(Int(titleLength))" : "Hidden", style: .segmented, key: "title-length") { title in
                guard let choice = Self.titleChoices.first(where: { $0.title == title }) else { return }
                self.showTitle = choice.length > 0
                if choice.length > 0 { self.titleLength = choice.length }
            }
            Slider(menuBarHours == 0 ? "Menu bar: any meeting today" : "Menu bar: meetings within \(Int(menuBarHours))h", value: menuBarHours, in: 0...8, step: 1, key: "menu-hours") { self.menuBarHours = $0 }
        }
        Section("Which events") {
            Toggle("Show all-day events", isOn: showAllDay) { self.showAllDay = $0 }
            Toggle("Show declined events", isOn: showDeclined) { self.showDeclined = $0 }
            Toggle("Only meetings with a call link", isOn: onlyWithLinks) { self.onlyWithLinks = $0 }
            Toggle("Only events with other people", isOn: onlyWithPeople) { self.onlyWithPeople = $0 }
            Toggle("Show finished events", isOn: showFinished) { self.showFinished = $0 }
        }
        Section("Calendars") {
            if calendars.isEmpty { Text("No calendars yet.").role(.secondary) }
            ForEach(calendars) { name in
                Toggle(name, isOn: !hiddenCalendars.contains(name), key: "calendar-\(name)") { on in
                    if on { self.hiddenCalendars.removeAll { $0 == name } } else if !self.hiddenCalendars.contains(name) { self.hiddenCalendars.append(name) }
                }
            }
        }
    }

    var widget: ViewContent {
        let now = Date()
        if let event = focus(now: now) {
            Backdrop(paint: stage(for: event), theme: theme, height: 131) {
                HStack(alignment: .end, spacing: Space.m) {
                    VStack(spacing: Space.xxs) {
                        Text("\(event.start <= now ? "NOW" : "NEXT") · \(Self.time(event.start))").typography(.overline)
                        Text(Self.clipped(event.title, 32)).typography(.title)
                        if let next = upcoming(now: now).first(where: { $0.id != event.id }) {
                            Text("Then \(Self.time(next.start))  \(Self.clipped(next.title, 24))").typography(.caption).opacity(0.8)
                        }
                    }
                    .frame(fillWidth: true, alignment: .leading)
                    clock(event, now: now)
                }
            }
        } else {
            HStack(spacing: Space.m) {
                IconTile("sun.max.fill", theme: .amber, size: 36)
                VStack(spacing: Space.xxs) {
                    Text("Nothing else today").typography(.headline)
                    Text("Enjoy the focus time").role(.secondary).typography(.caption)
                }
                .frame(fillWidth: true, alignment: .leading)
            }
        }
    }

    // MARK: Commands

    var commands: [Command] {
        Command("join-next", title: "Join Next Meeting", symbol: "video", keywords: ["meeting", "zoom", "meet", "teams", "call", "join"]) { _ in
            guard let event = self.focus() else { return .message("No more meetings today") }
            guard Self.meetingLink(for: event) != nil || event.url != nil else { return .failure("\(event.title) has no call link") }
            self.join(event)
            return .message("Joining \(event.title)")
        }
        Command("copy-next-link", title: "Copy Next Meeting Link", symbol: "link", keywords: ["meeting", "zoom", "meet", "teams", "call", "link"]) { _ in
            guard let event = self.focus() else { return .message("No more meetings today") }
            guard let link = Self.meetingLink(for: event) else { return .failure("\(event.title) has no call link") }
            return .copy(link.url)
        }
        Command("agenda", title: "Today's Meetings", symbol: "calendar", keywords: ["meeting", "agenda", "calendar", "today", "schedule"])
            .view(search: { _ in try await self.refresh() }) { invocation in
                let now = Date()
                let query = invocation.text.lowercased()
                let today = self.visible
                    .filter { Calendar.current.isDate($0.start, inSameDayAs: now) && (self.showFinished || $0.isAllDay || $0.end > now) }
                    .filter { query.isEmpty || $0.title.lowercased().contains(query) }
                    .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
                if today.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "Nothing else today" : "No meetings match", symbol: "sun.max")
                } else {
                    List(today) { event in self.row(event, now: now) }
                }
            }
    }

    // MARK: Agents

    var tools: [AgentTool] {
        AgentTool("next_meeting", description: "The meeting on now or next, with its time and call link") { _ in
            guard let event = self.focus() else { return "No more meetings today." }
            return "\(event.title), \(self.subtitle(event)), \(self.countdown(event))" + (Self.meetingLink(for: event).map { "\nJoin: \($0.url)" } ?? "")
        }
        AgentTool("agenda", description: "Meetings for today or tomorrow, one per line", parameters: [ToolParameter("day", description: "today or tomorrow (default today)", required: false)]) { arguments in
            let tomorrow = arguments.string("day")?.lowercased() == "tomorrow"
            let date = tomorrow ? Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date() : Date()
            let items = self.visible.filter { Calendar.current.isDate($0.start, inSameDayAs: date) }.sorted { $0.start < $1.start }
            return items.isEmpty ? "Nothing on the calendar \(tomorrow ? "tomorrow" : "today")." : items.map { "\($0.isAllDay ? "All day" : Self.time($0.start)) \($0.title)" }.joined(separator: "\n")
        }
        AgentTool("join_next", description: "Open the call link of the meeting on now or next") { _ in
            guard let event = self.focus(), let link = Self.meetingLink(for: event) else { return "The next meeting has no call link." }
            self.join(event)
            return "Opening \(event.title) on \(link.service)."
        }
    }
}
