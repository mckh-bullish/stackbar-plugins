import StackbarKit
import Foundation

/// The time in the places you work with. The menu bar shows one city; the
/// panel shows them all with the offset from you and whether it is working
/// hours there, drawn on your own day so the overlap shows at a glance.
/// Cities are chosen in Settings. A slider in the panel moves every clock
/// forward or back, to answer "what time is it there when it's 3pm here".
/// Needs nothing from the host.
@main
final class WorldClock: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.world-clock",
        name: "World Clock",
        version: "1.5.1",
        summary: "The time in the cities you work with, with offsets and working hours.",
        surfaces: [.menuBar, .panel, .settings, .widget],
        triggers: [.launch, .every(.seconds(30)), .wake],
        minimumStackbar: "0.21.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/WorldClock",
        accent: .violet,
        symbol: "globe"
    )

    // MARK: Previews

    static let previews: [PreviewScene<WorldClock>] = [
        PreviewScene("hero", "Every city you work with, and their working hours") { plugin in
            plugin.zones = ["America/Los_Angeles", "America/New_York", "Europe/London", "Asia/Kolkata", "Asia/Tokyo"]
        },
        PreviewScene("plan", "Slide to find a time that works everywhere") { plugin in
            plugin.zones = ["America/Los_Angeles", "America/New_York", "Europe/London", "Asia/Kolkata", "Asia/Tokyo"]
            plugin.offsetHours = 3
        },
        PreviewScene("widget", "Your cities on the desktop", surface: .widget) { _ in },
    ]

    /// The real time, from the last refresh.
    var realNow = Date()
    /// How far the panel's time-travel slider has moved every clock, in hours.
    var offsetHours = 0.0
    /// The moment every clock shows: now, or where the slider points.
    var now: Date { realNow.addingTimeInterval(offsetHours * 3600) }
    @Stored("zones") var zones: [String] = ["America/Los_Angeles", "America/New_York", "Europe/London", "Asia/Kolkata"]
    @Stored("menuBarZone") var menuBarZone = "Europe/London"
    @Stored("use24Hour") var use24Hour = true
    @Stored("workStart") var workStart = 9.0
    @Stored("workEnd") var workEnd = 18.0

    func refresh() async throws {
        realNow = Date()
    }

    let theme = Theme.violet

    var menuBar: ViewContent {
        if let zone = TimeZone(identifier: menuBarZone) {
            Label("\(city(menuBarZone)) \(time(realNow, in: zone))", symbol: "globe").role(.primary)
        } else {
            Label("", symbol: "globe").role(.secondary)
        }
    }

    var panel: ViewContent {
        PanelHeader("\(time(now, in: .current)) here", subtitle: (offsetHours == 0 ? "" : Self.shift(offsetHours) + " · ") + "\(now.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))) · \(validZones.count) \(validZones.count == 1 ? "city" : "cities")",
                    symbol: "globe", theme: theme) {
            Picker("Clock", options: ["12h", "24h"], selection: use24Hour ? "24h" : "12h", style: .segmented) { self.use24Hour = $0 == "24h" }
                .frame(width: 96)
        }
        if validZones.isEmpty {
            EmptyState("Add a city", symbol: "globe", message: "Type a city or a time zone. The menu bar shows the one you tap.", theme: theme) {
                TextField("City or time zone, like Tokyo") { submitted in self.add(submitted) }
            }
        } else {
            VStack(spacing: Space.s) {
                ForEach(validZones) { zone in card(zone) }
            }
            timeTravel
            Text("Bars show each city's working hours across your day, and the tick is your time\(offsetHours == 0 ? " now" : " on the slider"). Tap a city to show it in the menu bar.").role(.secondary).typography(.caption)
        }
    }

    /// A slider that moves every clock, so you can find a time that works
    /// everywhere. Steps are half an hour; Now puts it back.
    @ViewBuilder var timeTravel: ViewContent {
        HStack(spacing: Space.s) {
            Image(systemName: "clock.arrow.2.circlepath").opacity(0.6)
            Slider(offsetHours == 0 ? "Slide to see another time" : Self.shift(offsetHours) + " · \(time(now, in: .current)) here", value: offsetHours, in: -12...12, step: 0.5, key: "time-travel") { value in
                self.offsetHours = value
            }
            if offsetHours != 0 {
                ActionButton("Now", theme: theme) { self.offsetHours = 0 }
            }
        }
    }

    /// `+3h`, `−1h 30m`.
    static func shift(_ hours: Double) -> String {
        let minutes = Int((abs(hours) * 60).rounded())
        let text = minutes % 60 == 0 ? "\(minutes / 60)h" : minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
        return (hours > 0 ? "+" : "−") + text + " from now"
    }

    /// One city as a band of its sky: dawn, day, dusk or night, with the
    /// sun or moon, a big time, and its working hours on your day.
    @ViewBuilder func card(_ zone: TimeZone) -> ViewContent {
        let working = isWorking(zone)
        let sky = Sky(hour: hour(in: zone))
        let shown = zone.identifier == menuBarZone
        Button(key: "city-\(zone.identifier)", action: { self.menuBarZone = zone.identifier }) {
            VStack(spacing: Space.s + 2) {
                HStack(spacing: Space.s + 2) {
                    Image(systemName: sky.symbol).font(size: 20, weight: .semibold).symbolRendering(.multicolor)
                    VStack(spacing: 1) {
                        HStack(spacing: Space.xs) {
                            Text(city(zone.identifier)).typography(.headline)
                            if shown { Image(systemName: "menubar.rectangle").font(size: 10, weight: .semibold).opacity(0.8).accessibilityLabel("Shown in the menu bar") }
                        }
                        Text(subtitle(for: zone) + (working ? " · working" : "")).typography(.caption).opacity(0.8)
                    }
                    Spacer()
                    Text(time(now, in: zone)).typography(Typography(size: 28, weight: .bold, design: .rounded, monospacedDigit: true)).numericTransition()
                }
                .frame(fillWidth: true)
                hoursBar(workingHoursOnYourDay(zone), now: hour(in: .current) / 24, width: 332)
            }
            .foreground(.onMedia)
            .padding(Space.m)
            .frame(fillWidth: true)
            .background(sky.paint, in: .roundedRectangle(cornerRadius: Radius.large + 2))
            .hover(scale: 1.015, highlight: .hex("#FFFFFF14"))
        }
        .accessibilityLabel("\(city(zone.identifier)), \(time(now, in: zone)), \(working ? "working hours" : "outside working hours")")
    }

    /// Your day as a faint line on the sky, the city's working hours bright
    /// on it, and a tick at your now.
    func hoursBar(_ spans: [ClosedRange<Double>], now: Double, width: Double) -> some StackbarView {
        let tick = 2.0, height = 4.0
        var pieces: [(width: Double, lit: Bool)] = []
        var at = 0.0
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let from = min(max(span.lowerBound, at), 1), to = min(max(span.upperBound, from), 1)
            if from > at { pieces.append(((from - at) * width, false)) }
            if to > from { pieces.append(((to - from) * width, true)) }
            at = to
        }
        if at < 1 { pieces.append(((1 - at) * width, false)) }
        return ZStack(alignment: .start) {
            HStack(spacing: 0) {
                ForEach(Array(pieces.enumerated())) { _, piece in
                    Rectangle().fill(piece.lit ? .hex("#FFFFFFD9") : .hex("#FFFFFF33")).frame(width: max(piece.width, 0), height: height)
                }
            }
            .clipShape(.capsule)
            HStack(spacing: 0) {
                Rectangle().fill(.clear).frame(width: max(0, min(now, 1) * width - tick / 2), height: 10)
                Capsule().fill(.onMedia).frame(width: tick, height: 10).shadow(radius: 2, color: HexColor("#00000066"))
            }
        }
        .frame(width: width, height: 10)
        .accessibilityLabel("Working hours on your day")
    }

    /// The city's working hours, moved onto your clock, as fractions of your day.
    func workingHoursOnYourDay(_ zone: TimeZone) -> [ClosedRange<Double>] {
        let offset = Double(zone.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)) / 3600
        let start = (workStart - offset).truncatingRemainder(dividingBy: 24)
        let from = start < 0 ? start + 24 : start
        let to = from + Self.workLength(start: workStart, end: workEnd)
        return to <= 24 ? [from / 24...to / 24] : [from / 24...1, 0...(to - 24) / 24]
    }

    var widget: ViewContent {
        Grid(columns: 2, spacing: Space.s) {
            ForEach(Array(validZones.prefix(4))) { zone in
                let sky = Sky(hour: hour(in: zone, at: realNow))
                VStack(spacing: Space.xxs) {
                    HStack(spacing: Space.xs) {
                        Image(systemName: sky.symbol).font(size: 11).symbolRendering(.multicolor)
                        Text(city(zone.identifier)).typography(.caption).opacity(0.85)
                    }
                    Text(time(realNow, in: zone)).typography(Typography(size: 22, weight: .bold, design: .rounded, monospacedDigit: true))
                }
                .foreground(.onMedia)
                .padding(horizontal: Space.m - 2, vertical: Space.s)
                .frame(fillWidth: true, alignment: .leading)
                .background(sky.paint, in: .roundedRectangle(cornerRadius: Radius.large))
            }
        }
    }

    static let hours = (0...24).map { String(format: "%02d:00", $0) }

    var settings: ViewContent {
        Section("Cities") {
            ForEach(zones) { identifier in
                Row(city(identifier), subtitle: TimeZone(identifier: identifier) == nil ? "Unknown time zone" : identifier, symbol: "mappin", key: "zone-\(identifier)")
                    .action("Remove") { self.zones.removeAll { $0 == identifier } }
            }
            TextField("Add a city or time zone, like Tokyo", text: "") { submitted in self.add(submitted) }
            Text("Type a city name (Tokyo, New York) or a zone (Asia/Tokyo).").style(.caption).role(.secondary)
        }
        Section("Menu bar") {
            Picker("City", options: validZones.map(\.identifier), selection: menuBarZone) { self.menuBarZone = $0 }
        }
        Section("Working hours") {
            Picker("Start", options: Array(Self.hours.dropLast()), selection: Self.hours[Self.hourIndex(workStart, in: 0...23)], key: "work-start") { self.workStart = Double(Self.hours.firstIndex(of: $0) ?? 9) }
            Picker("End", options: Array(Self.hours.dropFirst()), selection: Self.hours[Self.hourIndex(workEnd, in: 1...24)], key: "work-end") { self.workEnd = Double(Self.hours.firstIndex(of: $0) ?? 18) }
        }
    }

    var tools: [AgentTool] {
        AgentTool("times", description: "The current time in each configured city") { _ in
            self.validZones.map { "\(self.city($0.identifier)): \(self.time(self.realNow, in: $0))" }.joined(separator: "\n")
        }
    }

    // MARK: Commands

    var commands: [Command] {
        Command("times", title: "World Clock", subtitle: "The time in your cities", symbol: "globe", keywords: ["time", "zone", "clock", "city", "timezone"])
            .view(search: { _ in try await self.refresh() }) { invocation in
                let query = invocation.text.lowercased()
                let zones = self.validZones.filter { query.isEmpty || self.city($0.identifier).lowercased().contains(query) || $0.identifier.lowercased().contains(query) }
                if zones.isEmpty {
                    ContentUnavailableView(self.validZones.isEmpty ? "No cities yet" : "No city matches", symbol: "globe", message: self.validZones.isEmpty ? "Add cities in World Clock's settings." : nil)
                } else {
                    List(zones) { zone in
                        Row(self.city(zone.identifier), subtitle: self.subtitle(for: zone, at: self.realNow), symbol: Sky(hour: self.hour(in: zone, at: self.realNow)).symbol, key: zone.identifier)
                            .badge(self.time(self.realNow, in: zone), role: self.isWorking(zone, at: self.realNow) ? .accent : .secondary)
                            .action("Copy Time") { Stackbar.copy("\(self.time(self.realNow, in: zone)) in \(self.city(zone.identifier))") }
                            .action("Show in Menu Bar") { self.menuBarZone = zone.identifier }
                    }
                }
            }
        // "tokyo" or "time in tok" at the palette's root answers with the time.
        Command("time-in", title: "Time In a City", subtitle: "World Clock", symbol: "globe", keywords: ["time", "zone", "city"])
            .view(search: { _ in self.realNow = Date() }) { invocation in
                List(Array(self.zones(named: invocation.text).prefix(3))) { zone in
                    Row(self.city(zone.identifier), subtitle: self.time(self.realNow, in: zone) + " · " + self.subtitle(for: zone, at: self.realNow),
                        symbol: Sky(hour: self.hour(in: zone, at: self.realNow)).symbol, key: zone.identifier)
                        .action("Copy Time") { Stackbar.copy("\(self.time(self.realNow, in: zone)) in \(self.city(zone.identifier))") }
                        .action(self.zones.contains(zone.identifier) ? "Show in Menu Bar" : "Add to World Clock") {
                            if self.zones.contains(zone.identifier) { self.menuBarZone = zone.identifier } else { self.zones.append(zone.identifier) }
                        }
                }
            }
            .rootSearch(section: "World Clock", matching: #"(?i)[a-z][a-z .'-]+"#)
            .stackbarOnly()
    }

    /// Zones a palette query names: a whole city name ("tokyo"), or a city's
    /// start after "time in" or before "time" ("time in tok", "lond time").
    /// Your own cities come first. Empty for anything else, so ordinary
    /// typing shows nothing from World Clock.
    func zones(named query: String) -> [TimeZone] {
        var text = query.trimmingCharacters(in: .whitespaces).lowercased()
        var prefix = false
        if text.hasPrefix("time in ") {
            text = String(text.dropFirst("time in ".count)).trimmingCharacters(in: .whitespaces)
            prefix = true
        } else if text.hasSuffix(" time") {
            text = String(text.dropLast(" time".count)).trimmingCharacters(in: .whitespaces)
            prefix = true
        }
        guard text.count >= 2 else { return [] }
        let mine = Set(zones)
        let found = TimeZone.knownTimeZoneIdentifiers.filter { identifier in
            let name = city(identifier).lowercased()
            return prefix ? name.hasPrefix(text) : name == text
        }
        return found.sorted { (mine.contains($0) ? 0 : 1, $0) < (mine.contains($1) ? 0 : 1, $1) }.compactMap(TimeZone.init(identifier:))
    }

    // MARK: -

    var validZones: [TimeZone] { zones.compactMap(TimeZone.init(identifier:)) }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let match = TimeZone.knownTimeZoneIdentifiers.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
            ?? TimeZone.knownTimeZoneIdentifiers.first { city($0).caseInsensitiveCompare(trimmed) == .orderedSame }
        guard let match, !zones.contains(match) else { return }
        zones.append(match)
    }

    func city(_ identifier: String) -> String {
        (identifier.split(separator: "/").last.map(String.init) ?? identifier).replacingOccurrences(of: "_", with: " ")
    }

    func time(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = use24Hour ? "HH:mm" : "h:mm a"
        return formatter.string(from: date)
    }

    func hour(in zone: TimeZone, at date: Date? = nil) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date ?? now)
        return Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
    }

    /// Hours between the start and the end of the working day; an end before
    /// the start is a night shift that runs past midnight.
    static func workLength(start: Double, end: Double) -> Double {
        end >= start ? end - start : end + 24 - start
    }

    /// A stored hour as an index into `hours`, kept inside `range` so a stored
    /// value from an edited settings file can't be out of bounds.
    static func hourIndex(_ value: Double, in range: ClosedRange<Int>) -> Int {
        guard value.isFinite else { return range.lowerBound }
        return min(range.upperBound, max(range.lowerBound, Int(value.rounded(.down))))
    }

    func isWorking(_ zone: TimeZone, at date: Date? = nil) -> Bool {
        let date = date ?? now
        let atHour = hour(in: zone, at: date)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var weekday = calendar.component(.weekday, from: date)
        let working: Bool
        if workStart <= workEnd {
            working = atHour >= workStart && atHour < workEnd
        } else if atHour >= workStart {
            working = true
        } else {
            // The small hours belong to the shift that began the day before.
            working = atHour < workEnd
            weekday = weekday == 1 ? 7 : weekday - 1
        }
        return working && (2...6).contains(weekday)
    }

    private func subtitle(for zone: TimeZone, at date: Date? = nil) -> String {
        let now = date ?? self.now
        let difference = zone.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)
        let hours = Double(difference) / 3600
        let offset = difference == 0 ? "Same time" : String(format: "%@%gh", hours > 0 ? "+" : "−", abs(hours))
        // Compare the calendar dates in each zone, not the sign of the offset.
        let theirs = day(in: zone, at: now), ours = day(in: .current, at: now)
        return offset + (theirs == ours ? "" : theirs > ours ? " · tomorrow" : " · yesterday")
    }

    private func day(in zone: TimeZone, at now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }
}
