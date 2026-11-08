import StackbarKit
import Foundation

/// CPU, memory, disk and network in the menu bar, with the processes using
/// the most, and a notification when one stays high.
///
/// Every 10 seconds it runs `ps` once for every process's CPU and memory,
/// `sysctl` for the load, memory pressure and swap, `vm_stat` for memory the
/// way Activity Monitor counts it (app memory, wired and compressed, not the
/// file cache), `netstat` for the bytes through Wi-Fi and Ethernet, and `df`
/// for the disk, through Stackbar. Each returns at once, so nothing waits a
/// second to sample. Nothing runs in a shell.
@main
final class SystemMonitor: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.system-monitor",
        name: "System Monitor",
        version: "1.8.0",
        summary: "CPU, memory, disk and network speed in the menu bar, the processes using the most, and alerts when one stays high.",
        surfaces: [.menuBar, .panel, .widget, .settings],
        triggers: [.launch, .every(.seconds(10)), .wake],
        capabilities: [.run(commands: ["ps", "sysctl", "vm_stat", "netstat", "df", "kill"]), .sensors],
        minimumStackbar: "0.35.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Monitoring/SystemMonitor",
        accent: .green,
        symbol: "gauge.with.dots.needle.67percent"
    )

    // MARK: Previews

    static let previews: [PreviewScene<SystemMonitor>] = [
        PreviewScene("hero", "CPU, memory and disk at a glance") { plugin in
            plugin.sample = samples
            plugin.disk = sampleDisk
            plugin.cpuHistory = readings([18, 22, 31, 27, 24, 41, 38, 33, 29, 35, 52, 47, 39, 34, 30, 28, 36, 44, 40, 34])
            plugin.network = sampleNetwork
        },
        PreviewScene("memory", "Find what is eating your memory") { plugin in
            plugin.sortBy = "Memory"
            plugin.sample = samples
            plugin.sample?.processes = SystemMonitor.sorted(samples.processes, by: "Memory")
            plugin.disk = sampleDisk
        },
        PreviewScene("sensors", "Temperatures and fans, as the Mac reports them") { plugin in
            plugin.sample = samples
            plugin.disk = sampleDisk
            plugin.sensors = sampleSensors
        },
        PreviewScene("widget", "Your Mac's load on the desktop", surface: .widget) { plugin in
            plugin.sample = samples
            plugin.disk = sampleDisk
            plugin.cpuHistory = readings([18, 22, 31, 27, 24, 41, 38, 33, 29, 35, 52, 47, 39, 34, 30, 28, 36, 44, 40, 34])
            plugin.network = sampleNetwork
        },
    ]

    static let gib = 1_073_741_824.0
    static let mib = 1_048_576.0

    /// A busy afternoon on a 32 GB Mac.
    static let samples = Sample(cpu: 34, memoryUsed: 21.4 * gib, memoryTotal: 32 * gib, pressure: .normal, swapUsed: 3.2 * gib, load: [3.12, 2.87, 2.40], processes: [
        ProcessRow(pid: 812, command: "Xcode", cpu: 48.2, rss: 4.1 * gib),
        ProcessRow(pid: 1204, command: "Safari", cpu: 21.7, rss: 2.6 * gib),
        ProcessRow(pid: 977, command: "Slack", cpu: 9.4, rss: 1.2 * gib),
        ProcessRow(pid: 401, command: "WindowServer", cpu: 7.9, rss: 820 * mib),
        ProcessRow(pid: 1530, command: "Docker", cpu: 6.1, rss: 3.3 * gib),
        ProcessRow(pid: 2210, command: "Music", cpu: 2.3, rss: 410 * mib),
        ProcessRow(pid: 1388, command: "Figma", cpu: 1.8, rss: 1.9 * gib),
        ProcessRow(pid: 166, command: "Stackbar", cpu: 0.6, rss: 96 * mib),
    ])

    static let sampleDisk = Disk(used: 612e9, total: 994e9)

    static let sampleSensors = [
        SensorReading(id: "cpu", name: "CPU", kind: .temperature, value: 53),
        SensorReading(id: "gpu", name: "GPU", kind: .temperature, value: 44),
        SensorReading(id: "ssd", name: "SSD", kind: .temperature, value: 39),
        SensorReading(id: "battery", name: "Battery", kind: .temperature, value: 31),
        SensorReading(id: "fan-0", name: "Left fan", kind: .fan, value: 1850, maximum: 4900),
    ]

    static let sampleNetwork = Network(down: 2_400_000, up: 310_000,
                                       downHistory: [0.4, 0.9, 1.2, 3.1, 2.2, 0.8, 0.6, 1.9, 2.8, 2.4].map { $0 * 1e6 },
                                       upHistory: [0.1, 0.2, 0.2, 0.4, 0.3, 0.2, 0.1, 0.3, 0.4, 0.31].map { $0 * 1e6 })

    /// Readings ten seconds apart, the last one now, for the previews.
    static func readings(_ values: [Double]) -> [Reading] {
        let now = Date()
        return values.enumerated().map { Reading(at: now.addingTimeInterval(-10 * Double(values.count - 1 - $0.offset)), value: $0.element) }
    }

    // MARK: State

    struct Sample: Equatable {
        /// Share of the whole machine, nil until the core count is known.
        var cpu: Double?
        var memoryUsed: Double?
        var memoryTotal: Double?
        /// Memory pressure as macOS reports it, nil when that read failed.
        var pressure: Pressure?
        var swapUsed: Double?
        var load: [Double] = []
        /// Every process, in the order the user sorts by. The panel shows
        /// the first eight.
        var processes: [ProcessRow] = []

        var memoryFraction: Double? {
            guard let used = memoryUsed, let total = memoryTotal, total > 0 else { return nil }
            return used / total
        }
    }

    /// macOS's memory pressure, from `kern.memorystatus_vm_pressure_level`.
    enum Pressure: Int, Equatable {
        case normal = 1
        case warning = 2
        case critical = 4

        var name: String {
            switch self {
            case .normal: return "Normal"
            case .warning: return "Warning"
            case .critical: return "Critical"
            }
        }

        var theme: Theme {
            switch self {
            case .normal: return .success
            case .warning: return .warning
            case .critical: return .critical
            }
        }
    }

    struct ProcessRow: Equatable, Identifiable {
        var pid: Int
        var command: String
        /// Share of one core, as `ps` reports it.
        var cpu: Double
        /// Resident memory in bytes.
        var rss: Double
        var id: Int { pid }
    }

    /// Bytes a second through Wi-Fi and Ethernet, and the last few minutes of them.
    /// A nil speed is one that couldn't be read this time, shown as a dash.
    struct Network: Equatable {
        var down: Double?
        var up: Double?
        var downHistory: [Double] = []
        var upHistory: [Double] = []
    }

    /// The counters netstat reported last, to turn totals into speeds.
    struct Counters: Equatable {
        var received: Double
        var sent: Double
        var at: Date
    }

    struct Disk: Equatable {
        var used: Double
        var total: Double
        var fraction: Double { total > 0 ? used / total : 0 }
    }

    /// One reading and when it was taken. The charts and alerts count real
    /// time with these, not the number of readings.
    struct Reading: Equatable {
        var at: Date
        var value: Double
    }

    var sample: Sample?
    var disk: Disk?
    var network: Network?
    /// Temperatures and fans, as the Mac reports them (none on a Mac that
    /// exposes none).
    var sensors: [SensorReading] = []
    var counters: Counters?
    /// CPU share of the whole machine at each timer, launch or wake reading.
    var cpuHistory: [Reading] = []
    /// Memory pressure level at each of those readings.
    var pressureHistory: [Reading] = []
    /// Why `ps` couldn't be read, while there is no list to show.
    var problem: String?
    /// The Mac's core count and memory size, read until they are known.
    var cores: Double?
    var memoryTotal: Double?
    /// When each alert last fired, so a long busy spell notifies once.
    var alerted: [String: Date] = [:]
    /// When each source last gave a reading, so a failed read can say how
    /// old the numbers on screen are.
    var lastGood: [String: Date] = [:]
    /// The sources whose last read failed, with when each last gave a good reading.
    var stale: [String: Date] = [:]
    /// When the last read started: a palette view reads again only when this
    /// is more than five seconds old.
    var lastAttempt: Date?

    @Stored("menuBarShows") var menuBarShows = "CPU and memory"
    @Stored("sortBy") var sortBy = "CPU"
    @Stored("alerts") var alertsOn = true
    @Stored("cpuThreshold") var cpuThreshold = 85.0

    // MARK: Reading

    /// The timer, launch and wake. These are the only readings the charts
    /// and alerts count.
    func refresh() async throws {
        await measure(recording: true)
    }

    /// Reads every source once. A read that fails keeps what was there and
    /// says how old it is, rather than showing zeros. Only `refresh()` records
    /// (`recording`), so looking at Top Processes can't move the charts.
    func measure(recording: Bool) async {
        let now = Date()
        lastAttempt = now
        var failed: [String] = []

        if cores == nil || memoryTotal == nil {
            if let facts = try? await Stackbar.run("sysctl", ["-n", "hw.logicalcpu", "hw.memsize"], timeout: .seconds(10)), facts.succeeded {
                let numbers = facts.text.split(separator: "\n").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if numbers.count == 2 { cores = numbers[0]; memoryTotal = numbers[1] }
            }
        }

        let ps = try? await Stackbar.run("ps", ["-A", "-o", "pid=,%cpu=,rss=,comm="], timeout: .seconds(10))
        let listed = ps.flatMap { $0.succeeded ? Self.parsePS($0.text, sortBy: sortBy) : nil }
        if listed != nil {
            lastGood["ps"] = now
            problem = nil
        } else {
            failed.append("ps")
            problem = ps?.succeeded == true ? "Couldn't read what ps reported. Stackbar will try again in 10 seconds." : "Couldn't run ps. Stackbar will try again in 10 seconds."
        }

        // Memory as Activity Monitor counts it. Without it the last figure stays.
        var used = sample?.memoryUsed
        if let vm = try? await Stackbar.run("vm_stat", timeout: .seconds(10)), vm.succeeded, let counted = Self.parseVMStat(vm.text) {
            used = memoryTotal.map { min(counted, $0) } ?? counted
            lastGood["vm_stat"] = now
        } else {
            failed.append("vm_stat")
        }

        // Load, memory pressure and swap, in one sysctl call.
        var read: (load: [Double], pressure: Pressure?, swap: Double?)?
        if let result = try? await Stackbar.run("sysctl", ["-n", "vm.loadavg", "kern.memorystatus_vm_pressure_level", "vm.swapusage"], timeout: .seconds(10)), result.succeeded {
            read = Self.parseSysctl(result.text)
        }
        if read != nil { lastGood["sysctl"] = now } else { failed.append("sysctl") }
        let load = read?.load ?? sample?.load ?? []
        let pressure = read != nil ? read?.pressure : sample?.pressure
        let swap = read != nil ? read?.swap : sample?.swapUsed

        let networkRead = await readNetwork(recording: recording, now: now)
        if !networkRead { failed.append("netstat") }

        if let readings = try? await Stackbar.sensors() { sensors = readings; lastGood["sensors"] = now } else { failed.append("sensors") }
        if let fresh = await Self.readDisk() { disk = fresh; lastGood["df"] = now } else { failed.append("df") }

        var next = sample ?? Sample()
        next.memoryUsed = used
        next.memoryTotal = memoryTotal
        next.pressure = pressure
        next.swapUsed = swap
        next.load = load
        if let listed {
            next.processes = listed
            next.cpu = cores.map { min(100, max(0, listed.reduce(0) { $0 + $1.cpu } / max(1, $0))) }
        }
        if listed != nil || sample != nil { sample = next }

        if recording {
            if listed != nil, let cpu = next.cpu { Self.append(cpu, at: now, to: &cpuHistory) }
            if read != nil, let pressure { Self.append(Double(pressure.rawValue), at: now, to: &pressureHistory) }
        }

        stale = [:]
        for source in failed { stale[source] = lastGood[source] }
        checkAlerts(now: now)
    }

    /// The bytes through Wi-Fi and Ethernet since the last reading, as speeds.
    /// A dash, not the old speed, when netstat fails or the counters can't be
    /// compared: they went backwards (an interface went away) or the Mac slept.
    func readNetwork(recording: Bool, now: Date) async -> Bool {
        guard let result = try? await Stackbar.run("netstat", ["-ibn"], timeout: .seconds(10)), result.succeeded,
              let totals = Self.parseNetstat(result.text) else {
            network = Network()
            counters = nil
            return false
        }
        let current = Counters(received: totals.received, sent: totals.sent, at: now)
        var next = network ?? Network()
        next.down = nil
        next.up = nil
        if let last = counters {
            let seconds = now.timeIntervalSince(last.at)
            if seconds > 0.5, seconds < 120, current.received >= last.received, current.sent >= last.sent {
                next.down = (current.received - last.received) / seconds
                next.up = (current.sent - last.sent) / seconds
            }
        }
        if recording, let down = next.down, let up = next.up {
            next.downHistory = Array((next.downHistory + [down]).suffix(30))
            next.upHistory = Array((next.upHistory + [up]).suffix(30))
        }
        network = next
        counters = current
        lastGood["netstat"] = now
        return true
    }

    /// Adds a reading and drops the ones older than the chart shows.
    static func append(_ value: Double, at now: Date, to history: inout [Reading]) {
        history.append(Reading(at: now, value: value))
        history.removeAll { now.timeIntervalSince($0.at) > historySpan }
    }

    static func readDisk() async -> Disk? {
        for path in ["/System/Volumes/Data", "/"] {
            guard let result = try? await Stackbar.run("df", ["-k", path], timeout: .seconds(10)), result.succeeded else { continue }
            if let disk = parseDF(result.text) { return disk }
        }
        return nil
    }

    // MARK: Alerts

    /// A minute of real time: the window a sustained reading has to fill.
    static let sustainedFor: TimeInterval = 60
    /// Readings further apart than this (a sleep, a refresh that didn't
    /// happen) don't make one run.
    static let longestGap: TimeInterval = 30
    /// What the CPU chart shows.
    static let historySpan: TimeInterval = 300

    /// Whether every reading from the newest one at least a minute old up to
    /// now is at or above `line`, the newest reading is recent, and no two
    /// readings in that run are more than `longestGap` apart.
    static func sustained(_ readings: [Reading], atLeast line: Double, now: Date) -> Bool {
        guard let newest = readings.last, now.timeIntervalSince(newest.at) <= longestGap,
              let start = readings.lastIndex(where: { now.timeIntervalSince($0.at) >= sustainedFor }) else { return false }
        let run = readings[start...]
        guard run.allSatisfy({ $0.value >= line }) else { return false }
        return zip(run, run.dropFirst()).allSatisfy { $1.at.timeIntervalSince($0.at) <= longestGap }
    }

    static let showProcesses = NotificationAction("Show Processes", command: "top")

    /// Notifies once when CPU stays above the line for a minute, or memory
    /// pressure stays at warning or worse, naming what is behind it, and when
    /// the disk is nearly full. Quiet for 30 minutes after (six hours for the
    /// disk), then the next spell notifies again.
    func checkAlerts(now: Date) {
        guard alertsOn, let sample else { return }
        let busiest = sample.processes.max { $0.cpu < $1.cpu }
        let biggest = sample.processes.max { $0.rss < $1.rss }
        let busy = Self.sustained(cpuHistory, atLeast: cpuThreshold, now: now)
        alert("cpu", when: busy, title: "CPU busy for a minute: \(Self.percent((cpuHistory.last?.value ?? 0) / 100))",
              body: busiest.map { "\($0.command) is using \(String(format: "%.0f%%", $0.cpu)) of a core." }, actions: [Self.showProcesses])
        let pressed = Self.sustained(pressureHistory, atLeast: Double(Pressure.warning.rawValue), now: now)
        alert("memory", when: pressed, title: "Memory pressure high for a minute",
              body: biggest.map { "\($0.command) is using \(Self.memory($0.rss))." }, actions: [Self.showProcesses])
        if let disk {
            alert("disk", when: disk.fraction >= 0.95, title: "Disk nearly full", body: "\(Self.diskSize(disk.total - disk.used)) free of \(Self.diskSize(disk.total)).", cooldown: 6 * 3600)
        }
    }

    func alert(_ name: String, when condition: Bool, title: String, body: String?, actions: [NotificationAction] = [], cooldown: TimeInterval = 1800) {
        // The cooldown counts from the last alert whatever the readings do
        // in between, so a reading that flaps around its threshold can't
        // notify again before it is over.
        guard condition else { return }
        if let last = alerted[name], Date().timeIntervalSince(last) < cooldown { return }
        alerted[name] = Date()
        Stackbar.notify(title, body: body, actions: actions)
    }

    // MARK: Parsing

    /// Memory Used as Activity Monitor shows it: app memory (anonymous
    /// pages that can't be purged), wired and compressed.
    static func parseVMStat(_ output: String) -> Double? {
        var pageSize = 4096.0
        var pages: [String: Double] = [:]
        for line in output.split(separator: "\n") {
            if let range = line.range(of: "page size of ") {
                pageSize = Double(line[range.upperBound...].prefix { $0.isNumber }) ?? pageSize
                continue
            }
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            pages[parts[0].trimmingCharacters(in: .whitespaces)] = Double(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " .")))
        }
        guard let anonymous = pages["Anonymous pages"], let wired = pages["Pages wired down"] else { return nil }
        let app = max(0, anonymous - (pages["Pages purgeable"] ?? 0))
        return (app + wired + (pages["Pages occupied by compressor"] ?? 0)) * pageSize
    }

    /// `df -k`: the second line's blocks, used and available, in KiB.
    static func parseDF(_ output: String) -> Disk? {
        let lines = output.split(separator: "\n")
        guard lines.count >= 2 else { return nil }
        let fields = lines[1].split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 4, let used = Double(fields[2]), let available = Double(fields[3]) else { return nil }
        // used + available, not the block count, which includes space
        // reserved for other APFS volumes.
        return Disk(used: used * 1024, total: (used + available) * 1024)
    }

    /// `ps -A -o pid=,%cpu=,rss=,comm=`: every process, its share of one
    /// core (a short decaying average), resident KiB and executable path.
    /// Nothing is cut: the panel shows the first few and the palette all.
    static func parsePS(_ output: String, sortBy: String) -> [ProcessRow]? {
        var processes: [ProcessRow] = []
        for raw in output.split(separator: "\n") {
            let fields = raw.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int(fields[0]), let cpu = Double(fields[1].replacingOccurrences(of: ",", with: ".")), let kib = Double(fields[2]) else { continue }
            processes.append(ProcessRow(pid: pid, command: lastComponent(String(fields[3])), cpu: cpu, rss: kib * 1024))
        }
        guard !processes.isEmpty else { return nil }
        return sorted(processes, by: sortBy)
    }

    /// Heaviest first, by CPU, or by memory in use (resident).
    static func sorted(_ processes: [ProcessRow], by sortBy: String) -> [ProcessRow] {
        processes.sorted { sortBy == "Memory" ? ($0.rss, $0.cpu) > ($1.rss, $1.cpu) : ($0.cpu, $0.rss) > ($1.cpu, $1.rss) }
    }

    /// A process's name: the last part of its path, so `.build/release/x` is `x`.
    static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// `sysctl -n vm.loadavg kern.memorystatus_vm_pressure_level vm.swapusage`:
    /// `{ 3.12 2.87 2.40 }`, the level (1, 2 or 4), and
    /// `total = 4096.00M  used = 3233.19M  free = 862.81M  (encrypted)`.
    /// Each line is recognised by its shape, so the order doesn't matter.
    static func parseSysctl(_ output: String) -> (load: [Double], pressure: Pressure?, swap: Double?) {
        var result: (load: [Double], pressure: Pressure?, swap: Double?) = ([], nil, nil)
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("{") {
                result.load = parseLoad(line)
            } else if let level = Int(line) {
                result.pressure = Pressure(rawValue: level)
            } else if let range = line.range(of: "used = ") {
                result.swap = bytes(String(line[range.upperBound...].prefix { $0 != " " }))
            }
        }
        return result
    }

    /// `sysctl -n vm.loadavg`: `{ 3.12 2.87 2.40 }`.
    static func parseLoad(_ output: String) -> [Double] {
        output.split { $0 == " " || $0 == "{" || $0 == "}" || $0 == "\n" }.compactMap { Double($0) }.prefix(3).map { $0 }
    }

    /// `netstat -ibn`: bytes in and out of every Wi-Fi and Ethernet interface
    /// (`en0`, `en1`, …), from its link row. Loopback, VPN tunnels and
    /// bridges are left out so traffic isn't counted twice.
    static func parseNetstat(_ output: String) -> (received: Double, sent: Double)? {
        var received = 0.0
        var sent = 0.0
        var found = false
        for raw in output.split(separator: "\n") {
            let fields = raw.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 10, fields[0].hasPrefix("en"), fields[2].hasPrefix("<Link#") else { continue }
            // Address can be empty, so count from the right: Ibytes, Opkts,
            // Oerrs, Obytes, Coll.
            guard let inBytes = Double(fields[fields.count - 5]), let outBytes = Double(fields[fields.count - 2]) else { continue }
            received += inBytes
            sent += outBytes
            found = true
        }
        return found ? (received, sent) : nil
    }

    // MARK: Formatting

    /// `2.4 MB/s`, `310 KB/s`, `0 KB/s`, or a dash while it can't be read.
    static func speed(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "–" }
        if bytesPerSecond >= 1e9 { return String(format: "%.1f GB/s", bytesPerSecond / 1e9) }
        if bytesPerSecond >= 1e6 { return String(format: bytesPerSecond >= 1e7 ? "%.0f MB/s" : "%.1f MB/s", bytesPerSecond / 1e6) }
        return String(format: "%.0f KB/s", bytesPerSecond / 1e3)
    }

    /// `1.1 GB`, `6 MB`: a process's memory, in powers of 1024 like Activity Monitor.
    static func memory(_ bytes: Double) -> String {
        let megabytes = bytes / mib
        return megabytes >= 1000 ? String(format: "%.1f GB", megabytes / 1024) : String(format: "%.0f MB", max(1, megabytes))
    }

    /// Memory in powers of 1024, as Activity Monitor shows it: `32 GB`, `21.4 GB`.
    static func memorySize(_ bytes: Double) -> String {
        let gigabytes = bytes / gib
        return gigabytes >= 10 || gigabytes == gigabytes.rounded() ? String(format: "%.0f GB", gigabytes) : String(format: "%.1f GB", gigabytes)
    }

    /// Disk space in powers of 1000, as Finder shows it: `994 GB`, `12.5 GB`.
    static func diskSize(_ bytes: Double) -> String {
        let gigabytes = bytes / 1e9
        return gigabytes >= 10 || gigabytes == gigabytes.rounded() ? String(format: "%.0f GB", gigabytes) : String(format: "%.1f GB", gigabytes)
    }

    /// `9.8`: gigabytes without the unit, for "9.8 of 16 GB".
    static func number(_ bytes: Double) -> String {
        let gigabytes = bytes / gib
        return gigabytes >= 100 ? String(format: "%.0f", gigabytes) : String(format: "%.1f", gigabytes)
    }

    /// `15G`, `2101M`, `512K`, `100B` (top's units are binary).
    static func bytes(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "+-.,()"))
        guard let unit = trimmed.last, let value = Double(trimmed.dropLast()) else { return Double(trimmed) }
        switch unit {
        case "T": return value * pow(1024, 4)
        case "G": return value * pow(1024, 3)
        case "M": return value * pow(1024, 2)
        case "K": return value * 1024
        case "B": return value
        default: return Double(trimmed)
        }
    }

    static func percentages(in line: String) -> [Double] {
        line.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { word in
            word.hasSuffix("%") ? Double(word.dropLast()) : nil
        }
    }

    /// The menu bar stays quiet until something needs a look: secondary,
    /// then amber from 75%, red from 90%.
    static func role(_ fraction: Double?) -> Role {
        guard let fraction else { return .secondary }
        return fraction >= 0.9 ? .critical : fraction >= 0.75 ? .warning : .secondary
    }

    // MARK: Look

    let theme = Theme.green

    /// Green while there is room, amber when it's getting full, red when it's not.
    /// `calm` replaces green for a resource that keeps its own colour.
    func tone(_ fraction: Double?, calm: Theme? = nil) -> Theme {
        guard let fraction else { return calm ?? theme }
        return fraction >= 0.9 ? .critical : fraction >= 0.75 ? .warning : calm ?? theme
    }

    /// Each resource keeps its own ring color until it needs a look.
    func rings(_ sample: Sample) -> [RingCluster.Ring] {
        var rings = [
            RingCluster.Ring("CPU", value: (sample.cpu ?? 0) / 100, theme: tone(sample.cpu.map { $0 / 100 })),
            RingCluster.Ring("Memory", value: sample.memoryFraction ?? 0, theme: tone(sample.memoryFraction, calm: .cyan)),
        ]
        if let disk { rings.append(RingCluster.Ring("Disk", value: disk.fraction, theme: tone(disk.fraction, calm: .violet))) }
        return rings
    }

    /// `34%`, or a dash while the number can't be read.
    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "–" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// What a glance should take away: the reading in trouble, or the two readings.
    func headline(_ sample: Sample) -> String {
        if let cpu = sample.cpu, cpu >= 75 { return "CPU busy: \(Self.percent(cpu / 100))" }
        if let pressure = sample.pressure, pressure != .normal { return "Memory pressure: \(pressure.name)" }
        if let disk, disk.fraction >= 0.9 { return "Disk nearly full: \(Self.diskSize(disk.total - disk.used)) free" }
        return "CPU \(Self.percent(sample.cpu.map { $0 / 100 })) · Memory \(Self.percent(sample.memoryFraction))"
    }

    var cpuTemperature: Double? { sensors.first { $0.id == "cpu" }?.value }

    static func degrees(_ value: Double) -> String { "\(Int(value.rounded()))°" }

    /// `40 s` or `3 min`, for how old a reading is.
    static func span(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds.rounded())) s" : "\(Int(seconds / 60)) min"
    }

    /// Names the numbers on screen that are old, and how old, while a read has
    /// failed: "Disk and network numbers from 2 min ago".
    var staleNote: String? {
        guard let oldest = stale.values.min() else { return nil }
        let nouns = Self.staleNouns.filter { stale[$0.source] != nil }.enumerated().map { index, item -> String in
            index == 0 ? item.noun : item.noun.prefix(1).lowercased() + item.noun.dropFirst()
        }
        let subject = nouns.count > 1 ? nouns.dropLast().joined(separator: ", ") + " and " + nouns[nouns.count - 1] : nouns.joined()
        return "\(subject) numbers from \(Self.span(Date().timeIntervalSince(oldest))) ago"
    }

    /// What each source's numbers are called in the banner, in the banner's order.
    static let staleNouns: [(source: String, noun: String)] = [
        ("ps", "Processes and CPU"), ("vm_stat", "Memory"), ("sysctl", "Load and swap"),
        ("df", "Disk"), ("netstat", "Network"), ("sensors", "Temperature and fan"),
    ]

    /// How far back the CPU chart reaches, from the time of its oldest reading.
    var cpuHistoryLabel: String {
        guard let oldest = cpuHistory.first else { return "" }
        let seconds = Date().timeIntervalSince(oldest.at)
        return seconds >= Self.historySpan ? "last 5 min" : "since \(Self.span(seconds)) ago"
    }

    /// The memory figure behind the percentage: "21.4 of 32 GB", or nothing until both are known.
    func memoryDetail(_ sample: Sample) -> String {
        guard let used = sample.memoryUsed, let total = sample.memoryTotal else { return "" }
        return "\(Self.number(used)) of \(Self.memorySize(total))"
    }

    // MARK: Surfaces

    var menuBar: ViewContent {
        if let sample {
            switch menuBarShows {
            case "CPU": Label(Self.percent(sample.cpu.map { $0 / 100 }), symbol: "cpu").role(Self.role(sample.cpu.map { $0 / 100 }))
            case "Memory": Label(Self.percent(sample.memoryFraction), symbol: "memorychip").role(Self.role(sample.memoryFraction))
            case "Network": Label(network.map { "↓\(Self.speed($0.down))" } ?? "–", symbol: "network").role(.secondary)
            case "Temperature": Label(cpuTemperature.map(Self.degrees) ?? "–", symbol: "thermometer.medium").role(cpuTemperature.map { $0 >= 95 ? .critical : $0 >= 85 ? .warning : .secondary } ?? .secondary)
            default: Label("\(Self.percent(sample.cpu.map { $0 / 100 })) · \(Self.percent(sample.memoryFraction))", symbol: "gauge.with.dots.needle.33percent").role(Self.role([sample.cpu.map { $0 / 100 }, sample.memoryFraction].compactMap { $0 }.max()))
            }
        } else {
            Label("", symbol: "gauge.with.dots.needle.33percent").role(.secondary)
        }
    }

    var panel: ViewContent {
        if let problem, sample == nil {
            EmptyState("Can't read the system", symbol: "exclamationmark.triangle", message: problem, theme: .critical) {
                ActionButton("Try Again", symbol: "arrow.clockwise", theme: theme, prominent: true) { await self.measure(recording: false) }
            }
        } else if let sample {
            VStack(spacing: Space.m) {
                if let note = staleNote { Banner(note) }
                PanelHeader(headline(sample), subtitle: sample.load.count == 3 ? "Load " + sample.load.map { String(format: "%.2f", $0) }.joined(separator: "  ") : nil, symbol: "gauge.with.dots.needle.33percent", theme: theme)
                HeroCard(theme: theme, look: .glow) {
                    HStack(spacing: Space.l) {
                        RingCluster(rings(sample), size: 116, lineWidth: 11, gap: 3)
                        VStack(spacing: Space.s) {
                            legend("CPU", value: Self.percent(sample.cpu.map { $0 / 100 }), detail: "busy", theme: tone(sample.cpu.map { $0 / 100 }))
                            legend("Memory", value: Self.percent(sample.memoryFraction), detail: memoryDetail(sample), theme: tone(sample.memoryFraction, calm: .cyan))
                            if let disk { legend("Disk", value: Self.percent(disk.fraction), detail: "\(Self.diskSize(disk.total - disk.used)) free", theme: tone(disk.fraction, calm: .violet)) }
                        }
                        .frame(fillWidth: true)
                    }
                }
                Card("Memory", detail: "Pressure and swap") {
                    HStack(spacing: Space.s) {
                        StatTile("Pressure", value: sample.pressure?.name ?? "–", symbol: "gauge.with.dots.needle.33percent", theme: sample.pressure?.theme ?? theme)
                        StatTile("Swap", value: sample.swapUsed.map { Self.memorySize($0) } ?? "–", caption: "in use", symbol: "arrow.left.arrow.right", theme: .cyan)
                    }
                }
                if cpuHistory.count >= 3 {
                    Card("CPU", detail: cpuHistoryLabel) {
                        Sparkline(cpuHistory.map(\.value), theme: tone(sample.cpu.map { $0 / 100 }), height: 48, label: "CPU over time")
                        HStack {
                            Text("Peak \(Self.percent((cpuHistory.map(\.value).max() ?? 0) / 100))").role(.secondary).typography(.captionNumber)
                            Spacer()
                            Text("Average \(Self.percent(cpuHistory.map(\.value).reduce(0, +) / Double(cpuHistory.count) / 100))").role(.secondary).typography(.captionNumber)
                        }
                    }
                }
                if let network {
                    Card("Network", detail: "Wi-Fi and Ethernet") {
                        HStack(spacing: Space.l) {
                            VStack(spacing: Space.xs) {
                                Label("Down", symbol: "arrow.down.circle.fill").role(.secondary).typography(.caption)
                                Text(Self.speed(network.down)).typography(.stat).numericTransition()
                                if network.downHistory.count >= 3 { Sparkline(network.downHistory, theme: .teal, height: 28, label: "Download over time") }
                            }
                            .frame(fillWidth: true)
                            VStack(spacing: Space.xs) {
                                Label("Up", symbol: "arrow.up.circle.fill").role(.secondary).typography(.caption)
                                Text(Self.speed(network.up)).typography(.stat).numericTransition()
                                if network.upHistory.count >= 3 { Sparkline(network.upHistory, theme: .violet, height: 28, label: "Upload over time") }
                            }
                            .frame(fillWidth: true)
                        }
                    }
                }
                if !sensors.isEmpty {
                    Card("Sensors", detail: sensors.contains { $0.kind == .fan } ? "temperatures and fans" : "temperatures") {
                        HStack(spacing: Space.l) {
                            ForEach(sensors.filter { $0.kind == .temperature }) { reading in
                                VStack(spacing: Space.xs) {
                                    Label(reading.name, symbol: "thermometer.medium").role(.secondary).typography(.caption)
                                    Text(Self.degrees(reading.value)).role(reading.value >= 95 ? .critical : reading.value >= 85 ? .warning : .primary).typography(.stat).numericTransition()
                                }
                                .frame(fillWidth: true)
                            }
                        }
                        ForEach(sensors.filter { $0.kind == .fan }) { fan in
                            Row(fan.name, subtitle: fan.maximum.map { "of \(Int($0)) rpm" }, symbol: "fan", key: fan.id)
                                .badge(fan.value < 1 ? "Off" : "\(Int(fan.value)) rpm", role: .secondary)
                        }
                    }
                }
                VStack(spacing: Space.xs) {
                    HStack(spacing: Space.s) {
                        CardTitle("Top processes")
                        Picker("Sort by", options: ["CPU", "Memory"], selection: sortBy, style: .segmented) { choice in
                            self.sortBy = choice
                            self.resort()
                        }
                        .frame(width: 150)
                    }
                    ForEach(sample.processes.prefix(8)) { process in
                        processRow(process)
                    }
                }
            }
        } else {
            VStack(spacing: Space.m) {
                PanelHeader("Measuring…", subtitle: "The first reading takes a couple of seconds", symbol: "gauge.with.dots.needle.33percent", theme: theme)
                HeroCard(theme: theme, look: .glow, alignment: .center) {
                    RingCluster([.init("CPU", value: 0, theme: theme), .init("Memory", value: 0, theme: .cyan), .init("Disk", value: 0, theme: .violet)], size: 116, lineWidth: 11) {
                        Image(systemName: "gauge.with.dots.needle.33percent").font(size: 20, weight: .semibold).foreground(theme.textPaint).symbolEffect(.pulse)
                    }
                }
            }
        }
    }

    /// One ring's key: its color, the reading large, what it means small.
    @ViewBuilder func legend(_ name: String, value: String, detail: String, theme: Theme) -> ViewContent {
        HStack(spacing: Space.s) {
            Capsule().fill(theme.sweep).frame(width: 4, height: 30)
            VStack(spacing: 0) {
                Text(name).role(.secondary).typography(.caption)
                HStack(alignment: .end, spacing: Space.xs) {
                    Text(value).typography(.stat).numericTransition()
                    if !detail.isEmpty { Text(detail).role(.secondary).typography(.caption) }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityLabel(detail.isEmpty ? "\(name) \(value)" : "\(name) \(value), \(detail)")
    }

    var widget: ViewContent {
        if let sample {
            HStack(spacing: Space.m) {
                RingCluster(rings(sample), size: 96, lineWidth: 9, gap: 2)
                VStack(spacing: Space.xs) {
                    legend("CPU", value: Self.percent(sample.cpu.map { $0 / 100 }), detail: "", theme: tone(sample.cpu.map { $0 / 100 }))
                    if cpuHistory.count >= 3 { Sparkline(cpuHistory.map(\.value), theme: tone(sample.cpu.map { $0 / 100 }), height: 22) }
                    HStack(spacing: Space.m) {
                        Text("Mem \(Self.percent(sample.memoryFraction))").typography(.captionNumber)
                        if let disk { Text("Disk \(Self.percent(disk.fraction))").typography(.captionNumber) }
                        if let network { Text("↓\(Self.speed(network.down))").typography(.captionNumber) }
                    }
                }
                .frame(fillWidth: true)
            }
            .frame(fillWidth: true, fillHeight: true)
        } else {
            Text("Measuring…").style(.caption)
        }
    }

    /// A row in the panel: its state, Copy PID and, where it may be quit, Quit Process.
    func processRow(_ process: ProcessRow) -> Row {
        // The badge shows the sort; the subtitle shows the other number.
        let other = sortBy == "Memory" ? String(format: "%.1f%% CPU", process.cpu) : Self.memory(process.rss)
        let row = Row(process.command, subtitle: "pid \(process.pid) · \(other)", symbol: "gearshape", key: "\(process.pid)")
            .badge(sortBy == "Memory" ? Self.memory(process.rss) : String(format: "%.1f%%", process.cpu), role: process.cpu > 80 ? .warning : .secondary)
            .action("Copy PID") { Stackbar.copy("\(process.pid)") }
        return quitAction(row, process)
    }

    /// A row in Top Processes, with every process listed.
    func listRow(_ process: ProcessRow) -> Row {
        let row = Row(process.command, subtitle: "pid \(process.pid) · \(String(format: "%.1f%%", process.cpu)) CPU · \(Self.memory(process.rss))", symbol: "gearshape", key: "\(process.pid)")
            .action("Copy PID") { Stackbar.copy("\(process.pid)") }
        return quitAction(row, process, shortcut: "cmd+.")
    }

    // MARK: Quitting

    /// Processes that would log you out or freeze the screen. This plugin's
    /// own process is kept out of the quit actions too.
    static let keepRunning: Set<String> = ["loginwindow", "WindowServer", "Dock", "launchd", "kernel_task", "Stackbar"]

    static func keepsRunning(_ process: ProcessRow) -> Bool {
        keepRunning.contains(process.command) || process.pid == Int(ProcessInfo.processInfo.processIdentifier)
    }

    /// Quit Process on the row, unless the process is one that is kept
    /// running. Stackbar asks for a second press before it runs.
    func quitAction(_ row: Row, _ process: ProcessRow, shortcut: String? = nil) -> Row {
        guard !Self.keepsRunning(process) else { return row }
        return row.action("Quit Process", shortcut: shortcut, role: .critical, confirm: "quit \(process.command) (pid \(process.pid))") { await self.quit(process) }
    }

    func quit(_ process: ProcessRow) async {
        await end([process], force: false)
    }

    /// Ends the processes the shared way. Each pid must still have the name
    /// it was listed under, since pids get reused. The signal goes out, then
    /// the pids are checked for up to two seconds. The list loses the ones
    /// that ended, and the HUD says how many did.
    func end(_ processes: [ProcessRow], force: Bool) async {
        let targets = processes.filter { !Self.keepsRunning($0) }
        guard let first = targets.first else { return }
        guard let names = await Self.commandNames(targets.map(\.pid)) else {
            Stackbar.hud("Couldn't check \(first.command); nothing was quit", isError: true)
            return
        }
        let ours = targets.filter { names[$0.pid] == $0.command }
        guard !ours.isEmpty else {
            forget(Set(targets.map(\.pid)))
            Stackbar.hud("\(first.command) has already ended")
            return
        }
        let pids = ours.map(\.pid)
        let sent = try? await Stackbar.run("kill", [force ? "-KILL" : "-TERM"] + pids.map(String.init), timeout: .seconds(10))
        var alive = Set(pids)
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(250))
            // A check that failed says nothing, so the pids still count as alive.
            guard let listed = await Self.commandNames(Array(alive)) else { continue }
            alive = alive.filter { listed[$0] != nil }
            if alive.isEmpty { break }
        }
        forget(Set(targets.map(\.pid)).subtracting(alive))
        let ended = ours.count - alive.count
        if alive.isEmpty {
            Stackbar.hud(ended == targets.count ? "Ended \(ended) of \(targets.count)" : "Ended \(ended) · \(targets.count - ended) had already ended")
        } else {
            let refused = sent?.errorText.contains("not permitted") == true
            Stackbar.hud("Ended \(ended) of \(targets.count) · \(first.command) is still running" + (refused ? ": it belongs to another user" : ""), isError: true)
        }
    }

    /// The name each of these pids runs as now, in the same columns the list
    /// uses, so the names compare. Pids that are gone are left out. Nil when
    /// the check itself failed (`ps` threw, timed out or wrote an error), which
    /// is not the same as "gone".
    static func commandNames(_ pids: [Int]) async -> [Int: String]? {
        guard !pids.isEmpty else { return [:] }
        guard let result = try? await Stackbar.run("ps", ["-o", "pid=,comm=", "-p", pids.map(String.init).joined(separator: ",")], timeout: .seconds(10)), !result.timedOut else { return nil }
        // `ps -p` exits 1 with no output when none of the pids is running.
        if result.status != 0 && !result.errorText.isEmpty { return nil }
        var names: [Int: String] = [:]
        for line in result.text.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2, let pid = Int(fields[0]) else { continue }
            names[pid] = lastComponent(String(fields[1]))
        }
        return names
    }

    /// Takes processes that have ended out of the list on screen, in place.
    func forget(_ pids: Set<Int>) {
        sample?.processes.removeAll { pids.contains($0.pid) }
    }

    /// Re-sorts the list already read, so changing the sort costs no reading.
    func resort() {
        guard let processes = sample?.processes else { return }
        sample?.processes = Self.sorted(processes, by: sortBy)
    }

    // MARK: Commands

    var commands: [Command] {
        Command("top", title: "Top Processes", subtitle: "What is using your CPU and memory", symbol: "gauge.with.dots.needle.67percent", keywords: ["cpu", "memory", "process", "activity", "kill", "quit", "slow"])
            .argument("by", placeholder: "Sort by", required: false, default: "CPU", options: ["CPU", "Memory"])
            .view(search: { invocation in
                if let by = invocation["by"], by != self.sortBy {
                    self.sortBy = by
                    self.resort()
                }
                // The list filters itself as you type; only an old reading is worth another read.
                if self.sample == nil || Date().timeIntervalSince(self.lastAttempt ?? .distantPast) > 5 {
                    await self.measure(recording: false)
                }
            }) { _ in
                if let sample = self.sample {
                    if let note = self.staleNote { Banner(note) }
                    List(sample.processes, searchable: true) { process in
                        self.listRow(process)
                    }
                } else {
                    ContentUnavailableView(self.problem == nil ? "Measuring…" : "Can't read the system", symbol: "gauge.with.dots.needle.33percent", message: self.problem)
                }
            }
    }

    var tools: [AgentTool] {
        AgentTool("usage", description: "CPU, memory and disk use now, and the busiest processes") { _ in
            guard let sample = self.sample else { return self.problem ?? "not measured yet" }
            var lines = [
                "cpu: \(sample.cpu.map { "\(Int($0.rounded()))%" } ?? "unknown")",
                "memory: \(sample.memoryUsed.map { Self.memorySize($0) } ?? "unknown") of \(sample.memoryTotal.map { Self.memorySize($0) } ?? "unknown")",
                "memory pressure: \(sample.pressure?.name ?? "unknown")",
            ]
            if let swap = sample.swapUsed { lines.append("swap used: \(Self.memorySize(swap))") }
            if let disk = self.disk { lines.append("disk: \(Self.diskSize(disk.used)) of \(Self.diskSize(disk.total))") }
            if let network = self.network { lines.append("network: \(Self.speed(network.down)) down, \(Self.speed(network.up)) up") }
            lines += self.sensors.map { "\($0.name.lowercased()): \($0.kind == .fan ? "\(Int($0.value)) rpm" : Self.degrees($0.value))" }
            lines += sample.processes.prefix(8).map { "\($0.pid) \($0.command) \($0.cpu)% cpu \(Self.memory($0.rss))" }
            return lines.joined(separator: "\n")
        }
    }

    var settings: ViewContent {
        Section("Menu bar") {
            Picker("Show", options: ["CPU and memory", "CPU", "Memory", "Network", "Temperature"], selection: menuBarShows) { self.menuBarShows = $0 }
        }
        Section("Alerts") {
            Toggle("Notify when CPU or memory stays high", isOn: alertsOn) { self.alertsOn = $0 }
            Picker("CPU above", options: ["70%", "85%", "95%"], selection: "\(Int(cpuThreshold))%", style: .segmented) { choice in
                self.cpuThreshold = Double(choice.dropLast()) ?? 85
            }
            Text("After a minute above the line, once, naming the busiest process. Memory alerts when pressure is Warning or Critical for a minute, and the disk at 95%.").style(.caption)
        }
    }
}
