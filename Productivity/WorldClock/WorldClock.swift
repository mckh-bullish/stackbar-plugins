import StackbarKit
import Foundation

/// The time in the places you work with. The menu bar shows one city; the
/// panel shows them all with the offset from you and whether it is working
/// hours there. Cities are chosen in Settings. Needs nothing from the host.
@main
final class WorldClock: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.world-clock",
        name: "World Clock",
        version: "1.0.0",
        summary: "The time in the cities you work with, with offsets and working hours.",
        surfaces: [.menuBar, .panel, .settings, .widget],
        triggers: [.launch, .every(.seconds(30)), .wake],
        minimumStackbar: "0.10.0",
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

    var menuBar: ViewContent {
        if let zone = TimeZone(identifier: menuBarZone) {
            Label("\(city(menuBarZone)) \(time(now, in: zone))", symbol: "globe")
        } else {
            Label("World Clock", symbol: "globe")
        }
    }

    var panel: ViewContent {
        if validZones.isEmpty {
            ContentUnavailableView("No cities", symbol: "globe", message: "Add cities in Settings.")
        } else {
            List {
                ForEach(validZones) { zone in
                    Row(city(zone.identifier), subtitle: subtitle(for: zone), symbol: isWorking(zone) ? "briefcase" : "moon", key: zone.identifier)
                        .badge(time(now, in: zone), role: isWorking(zone) ? .success : .secondary)
                        .action("Show in menu bar") { self.menuBarZone = zone.identifier }
                        .action("Copy time") { Stackbar.copy("\(self.city(zone.identifier)): \(self.time(self.now, in: zone))") }
                }
            }
        }
    }

    var widget: ViewContent {
        ForEach(validZones.prefix(4)) { zone in
            LabeledContent(city(zone.identifier), value: time(now, in: zone))
        }
    }

    var settings: ViewContent {
        Section("Cities") {
            ForEach(zones) { identifier in
                Row(city(identifier), subtitle: TimeZone(identifier: identifier) == nil ? "Unknown time zone" : identifier, symbol: "mappin", key: "zone-\(identifier)")
                    .action("Remove") { self.zones.removeAll { $0 == identifier } }
            }
            TextField("Add a time zone, like Asia/Tokyo", text: "") { submitted in self.add(submitted) }
        }
        Section("Menu bar") {
            Picker("City", options: validZones.map(\.identifier), selection: menuBarZone) { self.menuBarZone = $0 }
            Toggle("24-hour clock", isOn: use24Hour) { self.use24Hour = $0 }
        }
        Section("Working hours") {
            Slider("Start", value: workStart, in: 0...23, step: 1) { self.workStart = $0 }
            Slider("End", value: workEnd, in: 1...24, step: 1) { self.workEnd = $0 }
        }
    }

    var tools: [AgentTool] {
        AgentTool("times", description: "The current time in each configured city") { _ in
            self.validZones.map { "\(self.city($0.identifier)): \(self.time(self.now, in: $0))" }.joined(separator: "\n")
        }
    }

    // MARK: -

    private var validZones: [TimeZone] { zones.compactMap(TimeZone.init(identifier:)) }

    private func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let match = TimeZone.knownTimeZoneIdentifiers.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
            ?? TimeZone.knownTimeZoneIdentifiers.first { city($0).caseInsensitiveCompare(trimmed) == .orderedSame }
        guard let match, !zones.contains(match) else { return }
        zones.append(match)
    }

    private func city(_ identifier: String) -> String {
        (identifier.split(separator: "/").last.map(String.init) ?? identifier).replacingOccurrences(of: "_", with: " ")
    }

    private func time(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = use24Hour ? "HH:mm" : "h:mm a"
        return formatter.string(from: date)
    }

    private func hour(in zone: TimeZone) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        return Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
    }

    private func isWorking(_ zone: TimeZone) -> Bool {
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
        let offset = difference == 0 ? "Same time" : String(format: "%@%g h", hours > 0 ? "+" : "−", abs(hours))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let theirDay = calendar.component(.day, from: now)
        let ourDay = Calendar(identifier: .gregorian).component(.day, from: now)
        let day = theirDay == ourDay ? "" : (zone.secondsFromGMT(for: now) > TimeZone.current.secondsFromGMT(for: now) ? ", tomorrow" : ", yesterday")
        return offset + day
    }
}
