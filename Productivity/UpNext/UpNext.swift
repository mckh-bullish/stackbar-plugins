import StackbarKit
import Foundation

/// Your next meeting in the menu bar, with a one-click join.
///
/// It reads the calendars you have in Calendar.app (through the host, which
/// asks for access once), finds the video link in the location, URL or notes
/// (Zoom, Meet, Teams, Webex and a dozen more), counts down to it, reminds
/// you a few minutes before and again as it starts, and can open the call
/// for you. The panel steps through the week a day at a time, says how long
/// you are free, and flags meetings that clash.
@main
final class UpNext: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.up-next",
        name: "Up Next",
        version: "1.7.0",
        summary: "Your next meeting in the menu bar, with a countdown and one-click join.",
        surfaces: [.menuBar, .panel, .window, .widget, .settings],
        triggers: [.launch, .every(.seconds(30)), .wake],
        capabilities: [.calendar, .calendarWrite],
        hotkey: "ctrl+option+j",
        hotkeyCommand: "join-next",
        minimumStackbar: "0.27.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/UpNext",
        accent: .red,
        symbol: "calendar"
    )

    // MARK: Previews

    /// The simulated calendar outside the app is a sample working day.
    static let previews: [PreviewScene<UpNext>] = [
        PreviewScene("hero", "Your next meeting, one click from joining") { try await $0.refresh() },
        PreviewScene("week", "The day and the week's meeting load", surface: .window) { try await $0.refresh() },
        PreviewScene("widget", "What's next, on your desktop", surface: .widget) { try await $0.refresh() },
    ]

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
                if let service = service(for: url) {
                    return MeetingLink(url: url, service: service.name)
                }
            }
        }
        return nil
    }

    /// The service a link is for. Its host must be the service's own (or a
    /// subdomain of it) and its path must start with the service's path, so
    /// "evil.com/?r=zoom.us/j/1" and "evilzoom.us/j/1" are not Zoom.
    static func service(for url: String) -> Service? {
        guard let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http", let host = parts.host?.lowercased() else { return nil }
        // URLComponents decodes the host, so "evil.com%2f.zoom.us" arrives as
        // "evil.com/.zoom.us": only letters, digits, hyphens and dots may remain.
        guard host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }) else { return nil }
        // Nor may the raw address hide a separator, a control character or a
        // dot-dot in its encoded form.
        let raw = url.lowercased()
        guard let schemeEnd = raw.range(of: "://") else { return nil }
        let afterScheme = raw[schemeEnd.upperBound...]
        let authority = afterScheme.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !["%2f", "%5c", "%23", "%3f", "%00"].contains(where: { authority.contains($0) }) else { return nil }
        let rawPath = afterScheme.dropFirst(authority.count).prefix { $0 != "?" && $0 != "#" }
        guard !rawPath.contains("/..") && !rawPath.contains("%2e") else { return nil }
        let path = parts.path.lowercased()
        return services.first { service in
            service.patterns.contains { pattern in
                let slash = pattern.firstIndex(of: "/") ?? pattern.endIndex
                let domain = String(pattern[..<slash])
                let subdomainOnly = domain.hasPrefix(".")
                let name = subdomainOnly ? String(domain.dropFirst()) : domain
                let inDomain = subdomainOnly ? host.hasSuffix("." + name) : (host == name || host.hasSuffix("." + name))
                return inDomain && path.hasPrefix(String(pattern[slash...]))
            }
        }
    }

    /// Every http(s) URL in a piece of text, without trailing punctuation.
    /// A link a mail or security scanner wrapped is unwrapped, and a known
    /// service written without its scheme gets one.
    static func links(in text: String) -> [String] {
        var result: [String] = []
        for token in text.split(whereSeparator: { $0.isWhitespace || "<>\"'()[]{}".contains($0) }) {
            guard var url = linkText(token) else { continue }
            while let last = url.last, ".,;:!?".contains(last) { url.removeLast() }
            if url.count > 10 { result.append(unwrap(url)) }
        }
        return result
    }

    /// The link in a token: from its first http:// or https:// (whichever
    /// comes first, so a plain http link isn't skipped), else a known
    /// service's address without a scheme, as the token or after a label such
    /// as "Join:".
    private static func linkText(_ token: Substring) -> String? {
        // Every service address has a slash, and most words don't.
        guard token.contains("/") else { return nil }
        let schemes = ["https://", "http://"].compactMap { token.range(of: $0, options: .caseInsensitive) }
        if let start = schemes.min(by: { $0.lowerBound < $1.lowerBound }) {
            return String(token[start.lowerBound...])
        }
        for candidate in [token, token.split(separator: ":").last ?? token] {
            let url = "https://" + String(candidate)
            if service(for: url) != nil { return url }
        }
        return nil
    }

    /// The address inside a link that a mail or security scanner wrapped it
    /// in, or the link itself. Outlook Safe Links, urldefense (v2 and v3) and
    /// Google's redirect are unwrapped; an address inside may be wrapped too.
    static func unwrap(_ url: String, depth: Int = 0) -> String {
        guard depth < 3, let parts = URLComponents(string: url), let host = parts.host?.lowercased() else { return url }
        var inner: String?
        if host.hasSuffix(".safelinks.protection.outlook.com") {
            inner = parts.queryItems?.first { $0.name == "url" }?.value
        } else if host == "urldefense.com", let start = url.range(of: "/v3/__") {
            // v3 puts the address between "__" and "__;".
            let rest = url[start.upperBound...]
            inner = rest.range(of: "__").map { String(rest[..<$0.lowerBound]) }
        } else if host == "urldefense.proofpoint.com" {
            // v2 writes "_" for "/" and "-" for "%".
            inner = parts.queryItems?.first { $0.name == "u" }?.value?
                .replacingOccurrences(of: "_", with: "/")
                .replacingOccurrences(of: "-", with: "%")
                .removingPercentEncoding
        } else if host == "google.com" || host.hasSuffix(".google.com"), parts.path == "/url" {
            inner = parts.queryItems?.first { $0.name == "q" }?.value
        }
        guard let inner, inner.lowercased().hasPrefix("http") else { return url }
        return unwrap(inner, depth: depth + 1)
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
    /// Meetings hidden from the countdown, reminders and auto-join, by event id.
    @Stored("hiddenEvents") var hiddenEvents: [String] = []
    /// The last calls joined, by event id, so a restart doesn't open one again.
    @Stored("joinedEvents") var joinedEvents: [String] = []

    var events: [CalendarEvent] = [] {
        didSet { eventsVersion += 1 }
    }
    private var eventsVersion = 0
    /// What `visible` last computed, and what it was computed from.
    private var visibleCache: (key: VisibleKey, events: [CalendarEvent])?
    var calendars: [String] = []
    /// Why the last read failed, until one works.
    var readProblem: ReadProblem?
    var loaded = false
    /// Which day the panel shows: 0 is today (with tomorrow under it).
    var dayOffset = 0
    private var reminded: Set<String> = []
    private var nudged: Set<String> = []
    private var joined: Set<String> = []
    private var alerted: Set<String> = []
    private var lastJoin: Date?
    private var lastAlert: Date?
    private var lastFetch: Date?

    /// Why the calendars couldn't be read. Only a permission problem says so;
    /// any other error gets a plain line, not its own text.
    enum ReadProblem {
        case access, other

        var title: String { self == .access ? "Allow calendar access" : "Couldn't read your calendars" }
        var message: String { self == .access ? "Allow Stackbar in System Settings → Privacy & Security → Calendars." : "Try again in a moment." }
        var banner: String { self == .access ? "Calendar access is off, so these may be out of date." : "Couldn't refresh your calendars, so these may be out of date." }
    }

    /// Whether the calendars were last read more than 30 seconds ago, or never.
    var calendarsAreStale: Bool { lastFetch.map { Date().timeIntervalSince($0) > 30 } ?? true }

    func refresh() async throws {
        let now = Date()
        lastFetch = now
        let start = Calendar.current.startOfDay(for: now)
        guard let end = Calendar.current.date(byAdding: .day, value: 7, to: start) else { return }
        do {
            let all = try await Stackbar.calendarEvents(from: start, to: end)
            calendars = Array(Set(all.map(\.calendar))).sorted()
            events = all
            // Hidden meetings that have left the week are forgotten, but only
            // once the list has grown, and never against an empty read.
            if hiddenEvents.count > 100, !all.isEmpty {
                let ids = Set(all.map(\.id))
                hiddenEvents = hiddenEvents.filter(ids.contains)
            }
            readProblem = nil
            loaded = true
        } catch {
            readProblem = Self.isAccessProblem("\(error)") ? .access : .other
            return
        }
        remindAndJoin(now: now)
    }

    /// Whether an error's text is about permission, the one problem the panel says how to fix.
    static func isAccessProblem(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("access") || text.localizedCaseInsensitiveContains("privacy")
    }

    private struct VisibleKey: Equatable {
        var version: Int
        var hidden: [String]
        var allDay: Bool
        var declined: Bool
        var links: Bool
        var people: Bool
    }

    /// The events the settings let through. A render asks for this dozens of
    /// times (every row and day chip), and each setting read decodes its JSON,
    /// so the answer is kept until the events or a setting changes.
    var visible: [CalendarEvent] {
        let key = VisibleKey(version: eventsVersion, hidden: hiddenCalendars, allDay: showAllDay, declined: showDeclined, links: onlyWithLinks, people: onlyWithPeople)
        if let visibleCache, visibleCache.key == key { return visibleCache.events }
        let result = events.filter { event in
            !key.hidden.contains(event.calendar)
                && (key.allDay || !event.isAllDay)
                && (key.declined || event.participation != .declined)
                && (!key.links || event.isAllDay || Self.meetingLink(for: event) != nil)
                && (!key.people || event.isAllDay || event.attendees > 1)
        }
        visibleCache = (key, result)
        return result
    }

    /// Timed events that haven't ended and aren't hidden from the countdown, soonest first.
    func upcoming(now: Date = Date()) -> [CalendarEvent] {
        let hidden = hiddenEvents
        return visible.filter { !$0.isAllDay && $0.end > now && $0.participation != .declined && !hidden.contains($0.id) }.sorted { $0.start < $1.start }
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
        remindSnoozed(now: now)
        let due = upcoming(now: now)
        for event in due {
            let until = event.start.timeIntervalSince(now)
            // A nudge as it starts replaces the reminder when both are due at
            // once, as on launch or wake, so the two don't both fire.
            let nudge = remindMinutes > 0 && !fullScreenAlert && until <= 20 && until > -60 && !nudged.contains(event.id)
            if nudge { reminded.insert(event.id) }
            if remindMinutes > 0, until > 0, until <= remindMinutes * 60 + 15, !reminded.contains(event.id) {
                reminded.insert(event.id)
                let link = Self.meetingLink(for: event)
                Stackbar.notify(
                    "\(event.title) in \(max(1, Int((until / 60).rounded()))) min",
                    body: link.map { "On \($0.service)" } ?? event.location,
                    actions: reminderActions(event)
                )
            }
            if nudge {
                nudged.insert(event.id)
                let link = Self.meetingLink(for: event)
                Stackbar.notify("\(event.title) is starting", body: link.map { "On \($0.service)" } ?? event.location, actions: reminderActions(event))
            }
        }
        // Every meeting due for the full-screen alert in this pass shares one.
        // The host allows one alert a minute, so one that comes sooner waits
        // for the next pass, while its meeting is still in the window.
        if fullScreenAlert, lastAlert.map({ Date().timeIntervalSince($0) >= 61 }) ?? true {
            let starting = due.filter { event in
                let until = event.start.timeIntervalSince(now)
                return until <= 60 && until > -60 && !alerted.contains(event.id)
            }
            if !starting.isEmpty {
                postAlert(starting, now: now)
                alerted.formUnion(starting.map(\.id))
                lastAlert = Date()
            }
        }
        // Auto-join opens the meeting you're in, not every one starting together.
        if autoJoin, let event = focus(now: now), event.participation != .tentative, event.participation != .pending, Self.meetingLink(for: event) != nil {
            let until = event.start.timeIntervalSince(now)
            let joinedLately = lastJoin.map { now.timeIntervalSince($0) < 120 } ?? false
            if until <= 30, now < event.start.addingTimeInterval(120), !joined.contains(event.id), !joinedEvents.contains(event.id), !joinedLately {
                join(event)
            }
        }
        // Only events still in the fetched week can come round again, so
        // forget the rest (a Set has no order to keep "the latest" by).
        let current = Set(events.map(\.id))
        if reminded.count > 200 { reminded.formIntersection(current) }
        if joined.count > 200 { joined.formIntersection(current) }
        if alerted.count > 200 { alerted.formIntersection(current) }
        if nudged.count > 200 { nudged.formIntersection(current) }
    }

    /// The full-screen alert for the meetings starting now. One meeting gets
    /// its own; several share one that lists each and offers up to three Join
    /// buttons, then Call in if there's room.
    private func postAlert(_ starting: [CalendarEvent], now: Date) {
        var actions: [NotificationAction] = []
        for event in starting where actions.count < 3 {
            guard let link = Self.meetingLink(for: event) else { continue }
            let label = starting.count == 1 ? "Join on \(link.service)" : "Join \(Self.clipped(event.title, 20))"
            actions.append(NotificationAction(label, command: "join-event", arguments: ["event": event.id]))
        }
        if actions.count < 3, let dial = starting.lazy.compactMap({ Self.dialIn(for: $0) }).first {
            actions.append(NotificationAction("Call in", url: dial.tel))
        }
        if starting.count == 1, let only = starting.first {
            Stackbar.alert(only.title, body: Self.alertLine(only, now: now), actions: actions)
        } else {
            let body = starting.map { "\($0.title) · \(Self.alertLine($0, now: now))" }.joined(separator: "\n")
            Stackbar.alert("\(starting.count) meetings starting", body: body, actions: actions)
        }
    }

    /// "Starts at 10:00 · Ada" until the meeting starts, then "Started at 10:00".
    static func alertLine(_ event: CalendarEvent, now: Date) -> String {
        guard event.start > now else { return "Started at \(time(event.start))" }
        return "Starts at \(time(event.start))" + (event.organizer.map { " · \($0)" } ?? "")
    }

    // MARK: Snooze and quick add

    /// Reminders the user snoozed, by event id, and when to remind again.
    private var snoozedUntil: [String: Date] = [:]

    /// The buttons on a reminder: join the call, and snooze for five minutes.
    /// Join runs join-event, so the join is remembered and auto-join won't open the call again.
    func reminderActions(_ event: CalendarEvent) -> [NotificationAction] {
        var actions = Self.meetingLink(for: event).map { [NotificationAction("Join on \($0.service)", command: "join-event", arguments: ["event": event.id])] } ?? []
        actions.append(NotificationAction("Snooze 5 Min", command: "snooze", arguments: ["event": event.id]))
        return actions
    }

    /// Snoozes the meeting with that id, or the one on now or next. An id
    /// that is no longer on the calendar snoozes nothing.
    func snooze(_ id: String?, minutes: Int = 5) -> CommandResult {
        let event: CalendarEvent
        if let id {
            guard let found = events.first(where: { $0.id == id }) else { return .failure("That meeting is no longer on your calendar") }
            event = found
        } else {
            guard let focused = focus() else { return .message("No meeting to snooze") }
            event = focused
        }
        snoozedUntil[event.id] = Date().addingTimeInterval(TimeInterval(minutes * 60))
        return .message("Reminding you about \(event.title) in \(minutes) min")
    }

    /// Reminds again about the events whose snooze has run out and that
    /// haven't ended or been hidden from the countdown.
    func remindSnoozed(now: Date) {
        let hidden = hiddenEvents
        for (id, due) in snoozedUntil where due <= now {
            snoozedUntil[id] = nil
            guard let event = events.first(where: { $0.id == id }), event.end > now, !hidden.contains(id) else { continue }
            let until = event.start.timeIntervalSince(now)
            let title = until > 60 ? "\(event.title) in \(Int((until / 60).rounded())) min" : until > -60 ? "\(event.title) is starting" : "\(event.title) started \(Int((-until / 60).rounded())) min ago"
            Stackbar.notify(title, body: Self.meetingLink(for: event).map { "On \($0.service)" } ?? event.location, actions: reminderActions(event))
        }
    }

    /// "Lunch with Sam tomorrow 1pm for 45m", "Call Ana at 5 pm", "Standup
    /// 10.30am", "Dentist fri 9:30", "Offsite next monday" (all day), "Offsite
    /// fri for 3 days" (all day, three days long). The day, the time and the
    /// length are taken out, with the "at" or "for" in front of them; the rest,
    /// as typed, is the title. A time already past today means tomorrow, and an
    /// explicit weekday whose time has passed means the week after.
    static func quickAdd(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> CalendarEventDraft? {
        // Matching ignores a trailing comma or dot; the title keeps the words as typed.
        let raw = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let cleaned = raw.map { word -> String in
            var word = word
            while let last = word.last, ",.".contains(last) { word.removeLast() }
            return word
        }
        let matchable = raw.indices.filter { !cleaned[$0].isEmpty }
        let words = matchable.map { cleaned[$0] }
        var phrases: [Phrase] = []
        var index = 0
        while index < words.count {
            if let phrase = timePhrase(words, at: index) ?? lengthPhrase(words, at: index) ?? dayPhrase(words, at: index) {
                phrases.append(phrase)
                index = phrase.words.upperBound
            } else {
                index += 1
            }
        }
        // The first time, length and day count are taken; a later one stays in the title.
        var taken = Set<Int>()
        var time: (hour: Int, minute: Int, guess: Bool)?
        var minutes: Int?
        var days: Int?
        for phrase in phrases {
            switch phrase.kind {
            case .time(let hour, let minute, let guess) where time == nil:
                time = (hour, minute, guess)
                taken.formUnion(phrase.words)
            case .length(let parsed) where minutes == nil:
                minutes = parsed
                taken.formUnion(phrase.words)
            case .days(let count) where days == nil:
                days = count
                taken.formUnion(phrase.words)
            default: break
            }
        }
        // "Tomorrow" beats "today" when both are written, and both leave the
        // title. An explicit day beats a weekday. A weekday written in full counts
        // anywhere; an abbreviation only when time, length or day words follow it,
        // so "Review sat scores" keeps "sat".
        let timeWords = Set(phrases.filter(\.isTimeLengthOrDays).flatMap(\.words))
        var day: Date?
        var weekdayPicked = false
        let explicit = phrases.filter(\.isTodayOrTomorrow)
        if !explicit.isEmpty {
            for phrase in explicit { taken.formUnion(phrase.words) }
            day = explicit.contains(where: \.isTomorrow) ? calendar.date(byAdding: .day, value: 1, to: now) : now
        } else if let weekday = phrases.first(where: { phrase in
            phrase.isWeekday && (phrase.isFullWeekday || (phrase.words.upperBound..<words.count).allSatisfy { timeWords.contains($0) })
        }), case .weekday(let number, let next, _) = weekday.kind {
            taken.formUnion(weekday.words)
            weekdayPicked = true
            day = next
                ? Self.next(weekday: number, after: calendar.date(byAdding: .day, value: 1, to: now) ?? now, calendar: calendar)
                : Self.next(weekday: number, after: now, calendar: calendar)
        }
        let title = matchable.indices.filter { !taken.contains($0) }.map { raw[matchable[$0]] }.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ",").union(.whitespaces))
        guard !title.isEmpty else { return nil }
        if let time {
            var hour = time.hour
            let base = day ?? now
            // A plain hour from 1 to 11 is the afternoon or evening: 1 to 6 always,
            // and 7 to 11 when the morning reading has passed and the evening one hasn't.
            if time.guess {
                let morning = calendar.date(bySettingHour: hour, minute: time.minute, second: 0, of: base)
                let evening = calendar.date(bySettingHour: hour + 12, minute: time.minute, second: 0, of: base)
                let isToday = calendar.isDate(base, inSameDayAs: now)
                if hour <= 6 || (isToday && (morning ?? .distantFuture) < now && (evening ?? .distantPast) >= now) {
                    hour += 12
                }
            }
            var start = calendar.date(bySettingHour: hour, minute: time.minute, second: 0, of: base) ?? now
            if start < now {
                if weekdayPicked {
                    start = calendar.date(byAdding: .day, value: 7, to: start) ?? start
                } else if day == nil {
                    start = calendar.date(byAdding: .day, value: 1, to: start) ?? start
                }
            }
            let end = days.flatMap { calendar.date(byAdding: .day, value: $0, to: start) } ?? start.addingTimeInterval(TimeInterval((minutes ?? 60) * 60))
            return CalendarEventDraft(title: title, start: start, end: end)
        }
        let start = calendar.startOfDay(for: day ?? now)
        let end = calendar.date(byAdding: .day, value: days ?? 1, to: start) ?? start
        return CalendarEventDraft(title: title, start: start, end: end, isAllDay: true)
    }

    /// A run of words the quick add takes out of the title.
    private struct Phrase {
        enum Kind {
            /// `guess`: a plain hour from 1 to 11, which may be the afternoon or evening.
            case time(hour: Int, minute: Int, guess: Bool)
            case length(Int)
            case days(Int)
            case today, tomorrow
            /// `full`: the weekday is written in full, so it counts anywhere.
            case weekday(Int, next: Bool, full: Bool)
        }
        var words: Range<Int>
        var kind: Kind

        /// Time, length and day counts; a weekday abbreviation may be followed by these.
        var isTimeLengthOrDays: Bool {
            switch kind {
            case .time, .length, .days: return true
            default: return false
            }
        }

        var isTodayOrTomorrow: Bool {
            switch kind {
            case .today, .tomorrow: return true
            default: return false
            }
        }

        var isTomorrow: Bool {
            if case .tomorrow = kind { return true }
            return false
        }

        var isWeekday: Bool {
            if case .weekday = kind { return true }
            return false
        }

        var isFullWeekday: Bool {
            if case .weekday(_, _, let full) = kind { return full }
            return false
        }
    }

    /// "5 pm", "at 5pm", "at 12", "at 1" (a plain hour after "at"), "10.30am", "15:30", "noon".
    private static func timePhrase(_ words: [String], at index: Int) -> Phrase? {
        func word(_ offset: Int) -> String? { index + offset < words.count ? words[index + offset] : nil }
        if word(0)?.lowercased() == "at", let next = word(1) {
            if let period = word(2).flatMap(meridiem), let parsed = clock(next + period) {
                return Phrase(words: index..<index + 3, kind: .time(hour: parsed.hour, minute: parsed.minute, guess: false))
            }
            if let parsed = timeAfterAt(next) {
                return Phrase(words: index..<index + 2, kind: .time(hour: parsed.hour, minute: parsed.minute, guess: parsed.guess))
            }
            return nil
        }
        if let period = word(1).flatMap(meridiem), let parsed = clock(words[index] + period) {
            return Phrase(words: index..<index + 2, kind: .time(hour: parsed.hour, minute: parsed.minute, guess: false))
        }
        if let parsed = clock(words[index]) {
            return Phrase(words: index..<index + 1, kind: .time(hour: parsed.hour, minute: parsed.minute, guess: false))
        }
        return nil
    }

    /// "for 3 days" (an all-day span), "30 minutes", "1 hour", "45m", "30min",
    /// "1h30", "1.5h", each minute or hour length optionally after "for".
    private static func lengthPhrase(_ words: [String], at index: Int) -> Phrase? {
        if words[index].lowercased() == "for", index + 2 < words.count, let count = Int(words[index + 1]), (1...366).contains(count), ["day", "days"].contains(words[index + 2].lowercased()) {
            return Phrase(words: index..<index + 3, kind: .days(count))
        }
        if words[index].lowercased() == "for", index + 1 < words.count, let inner = lengthPhrase(words, at: index + 1) {
            return Phrase(words: index..<inner.words.upperBound, kind: inner.kind)
        }
        let word = words[index].lowercased()
        if let minutes = length(word) {
            return Phrase(words: index..<index + 1, kind: .length(minutes))
        }
        if index + 1 < words.count, lengthUnits.contains(words[index + 1].lowercased()), let minutes = length(word + words[index + 1].lowercased()) {
            return Phrase(words: index..<index + 2, kind: .length(minutes))
        }
        return nil
    }

    /// "today", "tomorrow" (or "tmr"), a weekday, or "next" and a weekday.
    private static func dayPhrase(_ words: [String], at index: Int) -> Phrase? {
        let word = words[index].lowercased()
        switch word {
        case "today":
            return Phrase(words: index..<index + 1, kind: .today)
        case "tomorrow", "tmr", "tmrw":
            return Phrase(words: index..<index + 1, kind: .tomorrow)
        case "next":
            guard index + 1 < words.count, let weekday = weekdays[words[index + 1].lowercased()] else { return nil }
            return Phrase(words: index..<index + 2, kind: .weekday(weekday, next: true, full: fullWeekdays.contains(words[index + 1].lowercased())))
        default:
            guard let weekday = weekdays[word] else { return nil }
            return Phrase(words: index..<index + 1, kind: .weekday(weekday, next: false, full: fullWeekdays.contains(word)))
        }
    }

    private static let lengthUnits = ["minute", "minutes", "min", "mins", "hour", "hours", "hr", "hrs"]

    private static let fullWeekdays: Set<String> = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    private static let weekdays: [String: Int] = [
        "sun": 1, "sunday": 1, "mon": 2, "monday": 2, "tue": 3, "tues": 3, "tuesday": 3, "wed": 4, "wednesday": 4,
        "thu": 5, "thur": 5, "thurs": 5, "thursday": 5, "fri": 6, "friday": 6, "sat": 7, "saturday": 7,
    ]

    /// The first day on or after `date` that is `weekday` (1 is Sunday).
    private static func next(weekday: Int, after date: Date, calendar: Calendar) -> Date? {
        let ahead = (weekday - calendar.component(.weekday, from: date) + 7) % 7
        return calendar.date(byAdding: .day, value: ahead, to: date)
    }

    /// "3pm", "3:30pm", "15:30", "9:30", "10.30am", "noon", "midnight". A bare
    /// hour is a time only after "at" (see `timeAfterAt`).
    static func clock(_ word: String) -> (hour: Int, minute: Int)? {
        let text = word.lowercased()
        if text == "noon" { return (12, 0) }
        if text == "midnight" { return (0, 0) }
        var digits = text
        var period: String?
        for ending in ["am", "pm", "a", "p"] where digits.hasSuffix(ending) {
            period = ending.hasPrefix("a") ? "am" : "pm"
            digits = String(digits.dropLast(ending.count))
            break
        }
        let parts = digits.split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "." })
        guard (1...2).contains(parts.count), let hour = Int(parts[0]), parts[0].count <= 2 else { return nil }
        let minute = parts.count == 2 ? Int(parts[1]) : 0
        guard let minute, (0..<60).contains(minute), parts.count == 1 || parts[1].count == 2 else { return nil }
        // A bare number is only a time with am/pm or a colon, never a dotted one like "3.14".
        let usesDot = digits.contains(".")
        guard period != nil || (parts.count == 2 && !usesDot) else { return nil }
        switch period {
        case "am": return (1...12).contains(hour) ? (hour % 12, minute) : nil
        case "pm": return (1...12).contains(hour) ? (hour % 12 + 12, minute) : nil
        default: return (0..<24).contains(hour) ? (hour, minute) : nil
        }
    }

    /// "am" or "pm" when a word is one, as in "5 pm" or "a.m.".
    static func meridiem(_ word: String) -> String? {
        let text = word.lowercased().replacingOccurrences(of: ".", with: "")
        return text == "am" || text == "pm" ? text : nil
    }

    /// The time after "at": a time, a dotted "10.30" read as "10:30", or a bare
    /// hour from 0 to 23, so "at 12" is noon and "at 0" midnight. A plain 1 to 11
    /// is a `guess`: quickAdd decides whether it means the afternoon or morning.
    static func timeAfterAt(_ word: String) -> (hour: Int, minute: Int, guess: Bool)? {
        if let parsed = clock(word) ?? clock(word.replacingOccurrences(of: ".", with: ":")) {
            return (parsed.hour, parsed.minute, false)
        }
        guard !word.isEmpty, word.allSatisfy(\.isNumber), let hour = Int(word), (0...23).contains(hour) else { return nil }
        return (hour, 0, (1...11).contains(hour) && !word.hasPrefix("0"))
    }

    /// "45m", "45min", "1h", "1h30", "1h30m", "1.5h" in minutes. Days aren't a
    /// length: "3D printing" is a title.
    static func length(_ word: String) -> Int? {
        let units: [String: Double] = ["m": 1, "min": 1, "mins": 1, "minute": 1, "minutes": 1, "h": 60, "hr": 60, "hrs": 60, "hour": 60, "hours": 60]
        var total = 0.0
        var rest = Substring(word.lowercased())
        var afterHours = false
        while !rest.isEmpty {
            let number = rest.prefix { $0.isNumber || $0 == "." }
            rest = rest.dropFirst(number.count)
            let unit = rest.prefix { $0.isLetter }
            rest = rest.dropFirst(unit.count)
            guard let value = Double(number) else { return nil }
            // "1h30": a bare number after hours is minutes, and it ends the word.
            let scale: Double? = unit.isEmpty && afterHours && rest.isEmpty ? 1 : units[String(unit)]
            guard let scale else { return nil }
            total += value * scale
            afterHours = scale == 60
        }
        guard total > 0, total <= 31 * 1440 else { return nil }
        return Int(total.rounded())
    }

    /// The text the add-event view parses: what was typed, or the `text` a
    /// link or Shortcut passed.
    static func typed(_ invocation: CommandInvocation) -> String {
        let text = invocation.text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? (invocation["text"] ?? "").trimmingCharacters(in: .whitespaces) : text
    }

    /// "Today 1:00 PM–1:45 PM", "Fri, Nov 13 3:00 PM – Sun, Nov 15 3:00 PM" when a
    /// timed event ends on another day, "Tomorrow, all day", "Fri, Nov 13 – Sun, Nov 15, all day".
    static func whenText(_ draft: CalendarEventDraft) -> String {
        if draft.isAllDay {
            let last = Calendar.current.date(byAdding: .day, value: -1, to: draft.end) ?? draft.end
            let span = Calendar.current.isDate(last, inSameDayAs: draft.start) ? "" : " – \(dayName(last))"
            return "\(dayName(draft.start))\(span), all day"
        }
        if !Calendar.current.isDate(draft.end, inSameDayAs: draft.start) {
            return "\(dayName(draft.start)) \(time(draft.start)) – \(dayName(draft.end)) \(time(draft.end))"
        }
        return "\(dayName(draft.start)) \(time(draft.start))–\(time(draft.end))"
    }

    private static func dayName(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// Adds the event to `calendar`, then says what was added and reads the
    /// calendars again. A second press, or a row from an earlier query, finds
    /// no draft and adds nothing.
    func save(_ draft: CalendarEventDraft, to calendar: CalendarInfo) async {
        guard addDraft == draft else { return }
        addDraft = nil
        var request = draft
        request.calendarID = calendar.id
        do {
            let saved = try await Stackbar.saveCalendarEvent(request)
            let message = "Added \(saved.title) to \(calendar.title)"
            addedText = message
            Stackbar.hud(message)
            try? await refresh()
        } catch {
            addDraft = addDraft ?? draft
            Stackbar.hud(Self.isAccessProblem("\(error)") ? "Up Next can't add to your calendar: allow Calendar access in System Settings" : "Couldn't add \(draft.title)", isError: true)
        }
    }

    func join(_ event: CalendarEvent) {
        if let link = Self.meetingLink(for: event) {
            markJoined(event.id)
            lastJoin = Date()
            Stackbar.open(openInApps ? Self.appURL(for: link) : link.url)
        } else if let url = event.url, Self.isWebURL(url) {
            markJoined(event.id)
            lastJoin = Date()
            Stackbar.open(url)
        }
    }

    /// Whether a link is one a browser opens: http or https, nothing else.
    static func isWebURL(_ url: String) -> Bool {
        guard let scheme = URLComponents(string: url)?.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    /// Remembers a join, in memory and on disk, so no later pass or restart opens the same call again.
    private func markJoined(_ id: String) {
        joined.insert(id)
        joinedEvents = Array((joinedEvents.filter { $0 != id } + [id]).suffix(50))
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
        if readProblem != nil && !loaded {
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
        if let readProblem, !loaded {
            EmptyState(readProblem.title, symbol: "calendar.badge.exclamationmark", message: readProblem.message, theme: theme) {
                ActionButton("Try Again", symbol: "arrow.clockwise", theme: theme, prominent: true) { try await self.refresh() }
            }
        } else {
            header(now: now)
            if let readProblem { Banner(readProblem.banner) }
            hero(now: now)
            if loaded { dayPicker(now: now) }
            let shown = date(offset: dayOffset, from: now)
            if loaded, !meetings(on: shown).isEmpty { dayCard(now: now, on: shown) }
            List(searchable: true) {
                if dayOffset == 0 {
                    day("Today", now, now: now)
                    if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) {
                        day("Tomorrow", tomorrow, now: now, startingOnly: true)
                    }
                } else {
                    day(shown.formatted(.dateTime.weekday(.wide).day().month(.wide)), shown, now: now)
                }
            }
            if dayOffset > 0, meetings(on: shown).isEmpty, visible.filter({ $0.isAllDay && Calendar.current.isDate($0.start, inSameDayAs: shown) }).isEmpty {
                EmptyState("Nothing on \(shown.formatted(.dateTime.weekday(.wide)))", symbol: "sun.max", theme: theme)
            }
        }
    }

    @ViewBuilder func header(now: Date) -> ViewContent {
        let count = meetings(on: now).count
        let hours = meetingHours(on: now)
        let free = freeUntil(now: now).map { " · Free until \(Self.time($0))" } ?? ""
        PanelHeader(now.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                    subtitle: !loaded ? "Reading your calendars…" : count == 0 ? "No meetings today" : "\(count) meeting\(count == 1 ? "" : "s") today · \(Self.hours(hours))" + free,
                    symbol: "calendar", theme: theme)
    }

    /// When the next meeting starts, while you're between meetings today.
    func freeUntil(now: Date) -> Date? {
        let soon = upcoming(now: now)
        guard !soon.contains(where: { $0.start <= now }) else { return nil }
        return soon.first { Calendar.current.isDate($0.start, inSameDayAs: now) }?.start
    }

    func date(offset: Int, from now: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: now) ?? now
    }

    /// Today and the next six days as chips, each day's meeting count under
    /// its name's tooltip.
    @ViewBuilder func dayPicker(now: Date) -> ViewContent {
        HStack(spacing: Space.xs) {
            ForEach(Array(0..<7)) { offset in
                let date = self.date(offset: offset, from: now)
                let count = self.meetings(on: date).count
                Chip(offset == 0 ? "Today" : date.formatted(.dateTime.weekday(.abbreviated)), theme: theme, selected: offset == dayOffset, key: "day-\(offset)") { self.dayOffset = offset }
                    .accessibilityLabel("\(offset == 0 ? "Today" : date.formatted(.dateTime.weekday(.wide))): \(count) meeting\(count == 1 ? "" : "s")")
            }
            Spacer(minLength: 0)
        }
    }

    /// Other meetings you go to that share some of this one's time.
    func clashes(with event: CalendarEvent) -> [CalendarEvent] {
        guard !event.isAllDay, event.participation != .declined else { return [] }
        return meetings(on: event.start).filter { $0.id != event.id && $0.start < event.end && $0.end > event.start }
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
    @ViewBuilder func dayCard(now: Date, on date: Date? = nil) -> ViewContent {
        let start = Calendar.current.startOfDay(for: date ?? now)
        let todays = meetings(on: date ?? now)
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
        let end = Self.dayEnd(start)
        return visible.filter { !$0.isAllDay && $0.participation != .declined && $0.start < end && $0.end > start }
    }

    /// Hours of the day in meetings, overlaps counted once.
    func meetingHours(on date: Date) -> Double {
        let start = Calendar.current.startOfDay(for: date)
        let end = Self.dayEnd(start)
        let spans = meetings(on: date).map { (max($0.start, start), min($0.end, end)) }.sorted { $0.0 < $1.0 }
        var total = 0.0
        var cursor = start
        for (from, to) in spans where to > cursor {
            total += to.timeIntervalSince(max(from, cursor))
            cursor = to
        }
        return total / 3600
    }

    /// Midnight that ends the day starting at `start` (23 or 25 hours on a daylight-saving day).
    static func dayEnd(_ start: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
    }

    func byCalendar(on date: Date) -> [(name: String, hours: Double)] {
        let start = Calendar.current.startOfDay(for: date)
        let end = Self.dayEnd(start)
        let grouped = Dictionary(grouping: meetings(on: date), by: \.calendar).mapValues { events in
            events.reduce(0.0) { $0 + min($1.end, end).timeIntervalSince(max($1.start, start)) / 3600 }
        }
        return grouped.map { (name: $0.key, hours: ($0.value * 10).rounded() / 10) }.sorted { $0.hours > $1.hours }
    }

    /// A day's events. `startingOnly` lists those that start that day, so one
    /// that runs past midnight isn't listed under both days.
    @ViewBuilder func day(_ title: String, _ date: Date, now: Date, startingOnly: Bool = false) -> ViewContent {
        let dayStart = Calendar.current.startOfDay(for: date)
        let dayEnd = Self.dayEnd(dayStart)
        // Timed events first (soonest on top, so Return joins it), all-day ones after.
        let items = visible.filter { event in
            let inDay = startingOnly ? event.start >= dayStart && event.start < dayEnd : event.start < dayEnd && event.end > dayStart
            return inDay && (showFinished || event.isAllDay || event.end > now)
        }
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
        let hidden = hiddenEvents.contains(event.id)
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
        if hidden { row = row.badge("Hidden", role: .secondary) }
        if !past, let other = clashes(with: event).first {
            row = row.badge("Clashes", role: .warning)
                .preview(text: "Overlaps \(other.title), \(Self.time(other.start))–\(Self.time(other.end))")
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
        row = row.action("Copy details") {
            Stackbar.copy([event.title, self.subtitle(event), link?.url].compactMap { $0 }.joined(separator: "\n"))
        }
        if hidden || (!event.isAllDay && !past) {
            row = row.action(hidden ? "Show Again" : "Hide from Countdown") { self.setHidden(event.id, !hidden) }
        }
        return row
    }

    /// Hides a meeting from the countdown, reminders and auto-join, or shows it again.
    func setHidden(_ id: String, _ hidden: Bool) {
        hiddenEvents = hiddenEvents.filter { $0 != id } + (hidden ? [id] : [])
    }

    /// Whether the title, calendar, place or call service contains the text,
    /// ignoring case and accents.
    func matches(_ event: CalendarEvent, _ query: String) -> Bool {
        [event.title, event.calendar, event.location ?? "", Self.meetingLink(for: event)?.service ?? ""]
            .contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
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
                        if let link = Self.meetingLink(for: event) {
                            ActionButton("Join on \(link.service)", symbol: "video.fill", theme: theme, prominent: true, key: "join-widget") { self.join(event) }
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

    /// What the add-event view parsed from its text, what it last added, the
    /// calendars it can add to (read at most every 30 seconds), and why it can't.
    private var addDraft: CalendarEventDraft?
    private var addedText: String?
    private var addCalendars: [CalendarInfo] = []
    private var addCalendarsRead: Date?
    private var addProblem: (any Error)?

    var commands: [Command] {
        Command("join-next", title: "Join Next Meeting", symbol: "video", keywords: ["meeting", "zoom", "meet", "teams", "call", "join"]) { _ in
            guard let event = self.focus() else { return .message("No more meetings today") }
            guard Self.meetingLink(for: event) != nil || Self.isWebURL(event.url ?? "") else { return .failure("\(event.title) has no call link") }
            self.join(event)
            return .message("Joining \(event.title)")
        }
        Command("copy-next-link", title: "Copy Next Meeting Link", symbol: "link", keywords: ["meeting", "zoom", "meet", "teams", "call", "link"]) { _ in
            guard let event = self.focus() else { return .message("No more meetings today") }
            guard let link = Self.meetingLink(for: event) else { return .failure("\(event.title) has no call link") }
            return .copy(link.url)
        }
        // A view, so the event is shown before it's added: one row per calendar, the default first.
        Command("add-event", title: "Add Calendar Event", subtitle: "Like \"Lunch with Sam tomorrow 1pm for 45m\"", symbol: "calendar.badge.plus", keywords: ["calendar", "event", "meeting", "new", "add", "schedule", "create"])
            .argument("text", placeholder: "Lunch with Sam tomorrow 1pm", required: false)
            .view(search: { invocation in
                self.addDraft = Self.quickAdd(Self.typed(invocation))
                self.addedText = nil
                // The calendars don't change between keystrokes, so they're read at most every 30 seconds.
                if self.addCalendarsRead.map({ Date().timeIntervalSince($0) > 30 }) ?? true {
                    do {
                        self.addCalendars = try await Stackbar.writableCalendars()
                        self.addCalendarsRead = Date()
                        self.addProblem = nil
                    } catch {
                        self.addCalendars = []
                        self.addProblem = error
                    }
                }
            }) { invocation in
                if let addProblem = self.addProblem {
                    ContentUnavailableView(addProblem)
                } else if self.addCalendars.isEmpty {
                    ContentUnavailableView("No calendar to add to", symbol: "calendar.badge.exclamationmark", message: "Turn on a calendar in Calendar.app.")
                } else if let addedText = self.addedText {
                    ContentUnavailableView(addedText, symbol: "checkmark.circle")
                } else if let draft = self.addDraft {
                    let calendars = self.addCalendars.filter(\.isDefault) + self.addCalendars.filter { !$0.isDefault }
                    List(calendars) { calendar in
                        Row("\(draft.title) — \(Self.whenText(draft)) · \(calendar.title)", subtitle: calendar.account, symbol: "calendar.badge.plus", key: calendar.id)
                            .action("Add to \(calendar.title)") { await self.save(draft, to: calendar) }
                    }
                } else {
                    ContentUnavailableView(Self.typed(invocation).isEmpty ? "Add a calendar event" : "Give it a title and a time", symbol: "calendar.badge.plus", message: "Like \"Lunch with Sam tomorrow 1pm for 45m\"")
                }
            }
        // The Join button of a reminder or alert runs this, so the join counts
        // and auto-join won't open the call again. Without a meeting that's on
        // the calendar and has a call link, it opens nothing.
        Command("join-event", title: "Join Meeting", subtitle: "From a reminder or alert", symbol: "video") { invocation in
            guard let id = invocation["event"], let event = self.events.first(where: { $0.id == id }) else {
                return .failure("That meeting is no longer on your calendar")
            }
            guard Self.meetingLink(for: event) != nil else { return .failure("That meeting has no call link") }
            self.join(event)
            return .done
        }
        .argument("event", required: false)
        .stackbarOnly()
        Command("snooze", title: "Snooze Meeting Reminder", subtitle: "Remind again in five minutes", symbol: "zzz", keywords: ["meeting", "remind", "snooze", "later"]) { invocation in
            self.snooze(invocation["event"])
        }
        .argument("event", required: false)
        Command("agenda", title: "Today's Meetings", symbol: "calendar", keywords: ["meeting", "agenda", "calendar", "today", "schedule"])
            .view(search: { _ in
                // Each keystroke runs this, so the calendars are read at most every 30 seconds.
                if self.calendarsAreStale { try await self.refresh() }
            }) { invocation in
                let now = Date()
                let query = invocation.text.trimmingCharacters(in: .whitespaces)
                let today = self.visible
                    .filter { Calendar.current.isDate($0.start, inSameDayAs: now) && (self.showFinished || $0.isAllDay || $0.end > now) }
                    .filter { query.isEmpty || self.matches($0, query) }
                    .sorted { ($0.isAllDay ? 1 : 0, $0.start) < ($1.isAllDay ? 1 : 0, $1.start) }
                if today.isEmpty {
                    if let readProblem = self.readProblem, !self.loaded {
                        EmptyState(readProblem.title, symbol: "calendar.badge.exclamationmark", message: readProblem.message, theme: self.theme)
                    } else {
                        ContentUnavailableView(query.isEmpty ? "Nothing else today" : "No meetings match", symbol: "sun.max")
                    }
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
        .optIn()
        AgentTool("agenda", description: "Meetings for today or tomorrow, one per line", parameters: [ToolParameter("day", description: "today or tomorrow (default today)", required: false)]) { arguments in
            let tomorrow = arguments.string("day")?.lowercased() == "tomorrow"
            let date = tomorrow ? Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date() : Date()
            let items = self.visible.filter { Calendar.current.isDate($0.start, inSameDayAs: date) }.sorted { $0.start < $1.start }
            return items.isEmpty ? "Nothing on the calendar \(tomorrow ? "tomorrow" : "today")." : items.map { "\($0.isAllDay ? "All day" : Self.time($0.start)) \($0.title)" }.joined(separator: "\n")
        }
        .optIn()
        AgentTool("join_next", description: "Open the call link of the meeting on now or next") { _ in
            guard let event = self.focus(), let link = Self.meetingLink(for: event) else { return "The next meeting has no call link." }
            self.join(event)
            return "Opening \(event.title) on \(link.service)."
        }
        .optIn()
    }
}
