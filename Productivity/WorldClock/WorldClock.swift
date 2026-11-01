import StackbarKit
import Foundation

/// The time in the places you work with. The menu bar shows one city; the
/// panel shows them all with the offset from you and whether it is working
/// hours there, drawn on your own day so the overlap shows at a glance.
/// Cities are chosen in Settings. Needs nothing from the host.
@main
final class WorldClock: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.world-clock",
        name: "World Clock",
        version: "1.2.0",
        summary: "The time in the cities you work with, with offsets and working hours.",
        surfaces: [.menuBar, .panel, .settings, .widget],
        triggers: [.launch, .every(.seconds(30)), .wake],
        minimumStackbar: "0.14.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/WorldClock"
    )

    var now = Date()
    @Stored("zones") var zones: [String] = ["America/Los_Angeles", "America/New_York", "Europe/London", "Asia/Kolkata"]
    @Stored("menuBarZone") var menuBarZone = "Europe/London"
    @Stored("use24Hour") var use24Hour = true
    @Stored("workStart") var workStart = 9.0
    @Stored("workEnd") var workEnd = 18.0

    func refresh() async throws {
        now = Date()
    }

    let theme = Theme.violet

    var menuBar: ViewContent {
        if let zone = TimeZone(identifier: menuBarZone) {
            Label("\(city(menuBarZone)) \(time(now, in: zone))", symbol: "globe").role(.primary)
        } else {
            Label("", symbol: "globe").role(.secondary)
        }
    }

    var panel: ViewContent {
        PanelHeader("\(time(now, in: .current)) here", subtitle: "\(now.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))) · \(validZones.count) \(validZones.count == 1 ? "city" : "cities")",
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
            Text("Bars show each city's working hours across your day, and the tick is your time now. Tap a city to show it in the menu bar.").role(.secondary).typography(.caption)
        }
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
        let to = from + max(0, workEnd - workStart)
        return to <= 24 ? [from / 24...to / 24] : [from / 24...1, 0...(to - 24) / 24]
    }

    var widget: ViewContent {
        Grid(columns: 2, spacing: Space.s) {
            ForEach(Array(validZones.prefix(4))) { zone in
                let sky = Sky(hour: hour(in: zone))
                VStack(spacing: Space.xxs) {
                    HStack(spacing: Space.xs) {
                        Image(systemName: sky.symbol).font(size: 11).symbolRendering(.multicolor)
                        Text(city(zone.identifier)).typography(.caption).opacity(0.85)
                    }
                    Text(time(now, in: zone)).typography(Typography(size: 22, weight: .bold, design: .rounded, monospacedDigit: true))
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
            Picker("Start", options: Array(Self.hours.dropLast()), selection: Self.hours[Int(workStart)], key: "work-start") { self.workStart = Double(Self.hours.firstIndex(of: $0) ?? 9) }
            Picker("End", options: Array(Self.hours.dropFirst()), selection: Self.hours[min(24, Int(workEnd))], key: "work-end") { self.workEnd = Double(Self.hours.firstIndex(of: $0) ?? 18) }
        }
    }

    var tools: [AgentTool] {
        AgentTool("times", description: "The current time in each configured city") { _ in
            self.validZones.map { "\(self.city($0.identifier)): \(self.time(self.now, in: $0))" }.joined(separator: "\n")
        }
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

    func hour(in zone: TimeZone) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        return Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
    }

    func isWorking(_ zone: TimeZone) -> Bool {
        let weekday = { () -> Int in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar.component(.weekday, from: now)
        }()
        return (2...6).contains(weekday) && hour(in: zone) >= workStart && hour(in: zone) < workEnd
    }

    private func subtitle(for zone: TimeZone) -> String {
        let difference = zone.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)
        let hours = Double(difference) / 3600
        let offset = difference == 0 ? "Same time" : String(format: "%@%gh", hours > 0 ? "+" : "−", abs(hours))
        // Compare the calendar dates in each zone, not the sign of the offset.
        let theirs = day(in: zone), ours = day(in: .current)
        return offset + (theirs == ours ? "" : theirs > ours ? " · tomorrow" : " · yesterday")
    }

    private func day(in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }
}
