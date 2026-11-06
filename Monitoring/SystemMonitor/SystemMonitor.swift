import StackbarKit
import Foundation

/// CPU, memory, disk and network in the menu bar, with the processes using
/// the most, and a notification when one stays high.
///
/// Every 10 seconds it runs `ps` once for every process's CPU and memory,
/// `sysctl` for the load and the Mac's size, `vm_stat` for memory the way
/// Activity Monitor counts it (app memory, wired and compressed, not the
/// file cache), `netstat` for the bytes through Wi-Fi and Ethernet, and
/// `df` for the disk, through Stackbar. Each returns at once, so nothing
/// waits a second to sample. Nothing runs in a shell.
@main
final class SystemMonitor: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.system-monitor",
        name: "System Monitor",
        version: "1.5.0",
        summary: "CPU, memory, disk and network speed in the menu bar, the processes using the most, and alerts when one stays high.",
        surfaces: [.menuBar, .panel, .widget, .settings],
        triggers: [.launch, .every(.seconds(10)), .wake],
        capabilities: [.run(commands: ["ps", "sysctl", "vm_stat", "netstat", "df", "kill"])],
        minimumStackbar: "0.17.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Monitoring/SystemMonitor",
        accent: .green,
        symbol: "gauge.with.dots.needle.67percent"
    )

    // MARK: Previews

    static let previews: [PreviewScene<SystemMonitor>] = [
        PreviewScene("hero", "CPU, memory and disk at a glance") { plugin in
            plugin.sample = samples
            plugin.disk = Disk(used: 612e9, total: 994e9)
            plugin.cpuHistory = [18, 22, 31, 27, 24, 41, 38, 33, 29, 35, 52, 47, 39, 34, 30, 28, 36, 44, 40, 34]
            plugin.network = sampleNetwork
        },
        PreviewScene("memory", "Find what is eating your memory") { plugin in
            plugin.sortBy = "Memory"
            plugin.sample = samples
            let order = ["Xcode", "Docker", "Safari", "Figma", "Slack", "WindowServer", "Music", "Stackbar"]
            plugin.sample?.processes.sort { order.firstIndex(of: $0.command) ?? 0 < order.firstIndex(of: $1.command) ?? 0 }
            plugin.disk = Disk(used: 612e9, total: 994e9)
        },
        PreviewScene("widget", "Your Mac's load on the desktop", surface: .widget) { plugin in
            plugin.sample = samples
            plugin.disk = Disk(used: 612e9, total: 994e9)
            plugin.cpuHistory = [18, 22, 31, 27, 24, 41, 38, 33, 29, 35, 52, 47, 39, 34, 30, 28, 36, 44, 40, 34]
        },
    ]

    /// A busy afternoon on a 32 GB Mac.
    static let samples = Sample(cpu: 34, memoryUsed: 21.4 * 1_073_741_824, memoryTotal: 32 * 1_073_741_824, load: [3.12, 2.87, 2.40], processes: [
        ProcessRow(pid: 812, command: "Xcode", cpu: 48.2, memory: "4.1G"),
        ProcessRow(pid: 1204, command: "Safari", cpu: 21.7, memory: "2.6G"),
        ProcessRow(pid: 977, command: "Slack", cpu: 9.4, memory: "1.2G"),
        ProcessRow(pid: 401, command: "WindowServer", cpu: 7.9, memory: "820M"),
        ProcessRow(pid: 1530, command: "Docker", cpu: 6.1, memory: "3.3G"),
        ProcessRow(pid: 2210, command: "Music", cpu: 2.3, memory: "410M"),
        ProcessRow(pid: 1388, command: "Figma", cpu: 1.8, memory: "1.9G"),
        ProcessRow(pid: 166, command: "Stackbar", cpu: 0.6, memory: "96M"),
    ])

    struct Sample: Equatable {
        var cpu: Double = 0
        var memoryUsed: Double = 0
        var memoryTotal: Double = 0
        var load: [Double] = []
        var processes: [ProcessRow] = []
        var memoryFraction: Double { memoryTotal > 0 ? memoryUsed / memoryTotal : 0 }
    }

    struct ProcessRow: Equatable, Identifiable {
        var pid: Int
        var command: String
        var cpu: Double
        var memory: String
        var id: Int { pid }
        /// Resident memory in bytes.
        var rss: Double = 0
    }

    static let sampleNetwork = Network(down: 2_400_000, up: 310_000,
                                       downHistory: [0.4, 0.9, 1.2, 3.1, 2.2, 0.8, 0.6, 1.9, 2.8, 2.4].map { $0 * 1e6 },
                                       upHistory: [0.1, 0.2, 0.2, 0.4, 0.3, 0.2, 0.1, 0.3, 0.4, 0.31].map { $0 * 1e6 })

    /// Bytes a second through Wi-Fi and Ethernet, and the last few minutes of them.
    struct Network: Equatable {
        var down: Double = 0
        var up: Double = 0
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

    var sample: Sample?
    var disk: Disk?
    var network: Network?
    var counters: Counters?
    var cpuHistory: [Double] = []
    var memoryHistory: [Double] = []
    var problem: String?
    /// The Mac's core count and memory, read once.
    var cores: Double?
    var memoryTotal: Double?
    /// When each alert last fired, so a long busy spell notifies once.
    var alerted: [String: Date] = [:]

    @Stored("menuBarShows") var menuBarShows = "CPU and memory"
    @Stored("sortBy") var sortBy = "CPU"
    @Stored("alerts") var alertsOn = true
    @Stored("cpuThreshold") var cpuThreshold = 85.0

    func refresh() async throws {
        await measure()
    }

    func measure() async {
        do {
            if cores == nil || memoryTotal == nil {
                let facts = try await Stackbar.run("sysctl", ["-n", "hw.logicalcpu", "hw.memsize"], timeout: .seconds(10))
                let numbers = facts.text.split(separator: "\n").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if numbers.count == 2 { cores = numbers[0]; memoryTotal = numbers[1] }
            }
            let result = try await Stackbar.run("ps", ["-A", "-o", "pid=,%cpu=,rss=,comm="], timeout: .seconds(10))
            guard result.succeeded, var parsed = Self.parsePS(result.text, cores: cores ?? 1, sortBy: sortBy) else {
                problem = result.succeeded ? "Couldn't read ps's output" : "ps failed (\(result.status)): \(result.errorText.prefix(160))"
                return
            }
            parsed.memoryTotal = memoryTotal ?? 0
            if let vm = try? await Stackbar.run("vm_stat", timeout: .seconds(10)), vm.succeeded, let used = Self.parseVMStat(vm.text) {
                parsed.memoryUsed = parsed.memoryTotal > 0 ? min(used, parsed.memoryTotal) : used
            }
            if let load = try? await Stackbar.run("sysctl", ["-n", "vm.loadavg"], timeout: .seconds(10)), load.succeeded {
                parsed.load = Self.parseLoad(load.text)
            }
            sample = parsed
            cpuHistory = Array((cpuHistory + [parsed.cpu]).suffix(30))
            memoryHistory = Array((memoryHistory + [parsed.memoryFraction]).suffix(30))
            problem = nil
        } catch {
            problem = "\(error)"
        }
        await measureNetwork()
        disk = await Self.readDisk()
        checkAlerts()
    }

    func measureNetwork() async {
        guard let result = try? await Stackbar.run("netstat", ["-ibn"], timeout: .seconds(10)), result.succeeded,
              let totals = Self.parseNetstat(result.text) else { return }
        let now = Counters(received: totals.received, sent: totals.sent, at: Date())
        defer { counters = now }
        guard let last = counters else { return }
        let seconds = now.at.timeIntervalSince(last.at)
        // A counter that went backwards (an interface went away) or a long
        // gap (the Mac slept) has no speed to report this time.
        guard seconds > 0.5, seconds < 120, now.received >= last.received, now.sent >= last.sent else { return }
        var network = self.network ?? Network()
        network.down = (now.received - last.received) / seconds
        network.up = (now.sent - last.sent) / seconds
        network.downHistory = Array((network.downHistory + [network.down]).suffix(30))
        network.upHistory = Array((network.upHistory + [network.up]).suffix(30))
        self.network = network
    }

    // MARK: Alerts

    /// Six readings, one minute at the 10-second pace.
    static let sustained = 6

    /// Notifies once when CPU or memory stays high for a minute, or the
    /// disk is nearly full, naming what is behind it. Quiet for 30 minutes
    /// after, and again once things calm down and climb back.
    func checkAlerts() {
        guard alertsOn, let sample else { return }
        let busy = cpuHistory.count >= Self.sustained && cpuHistory.suffix(Self.sustained).allSatisfy { $0 >= cpuThreshold }
        let full = memoryHistory.count >= Self.sustained && memoryHistory.suffix(Self.sustained).allSatisfy { $0 >= 0.9 }
        let byCPU = sample.processes.max { $0.cpu < $1.cpu }
        let byMemory = sample.processes.max { $0.rss < $1.rss }
        alert("cpu", when: busy, title: "CPU busy for a minute: \(Self.percent(sample.cpu / 100))",
              body: byCPU.map { "\($0.command) is using \(String(format: "%.0f%%", $0.cpu)) of a core." })
        alert("memory", when: full, title: "Memory nearly full: \(Self.percent(sample.memoryFraction))",
              body: byMemory.map { "\($0.command) is using \(Self.memory($0.memory))." })
        if let disk {
            alert("disk", when: disk.fraction >= 0.95, title: "Disk nearly full", body: "\(Self.size(disk.total - disk.used)) free of \(Self.size(disk.total)).", cooldown: 6 * 3600)
        }
    }

    func alert(_ name: String, when condition: Bool, title: String, body: String?, cooldown: TimeInterval = 1800) {
        guard condition else {
            // Calm again: the next spell may notify straight away.
            if let last = alerted[name], Date().timeIntervalSince(last) > 60 { alerted[name] = nil }
            return
        }
        if let last = alerted[name], Date().timeIntervalSince(last) < cooldown { return }
        alerted[name] = Date()
        Stackbar.notify(title, body: body)
    }

    static func readDisk() async -> Disk? {
        for path in ["/System/Volumes/Data", "/"] {
            guard let result = try? await Stackbar.run("df", ["-k", path], timeout: .seconds(10)), result.succeeded else { continue }
            if let disk = parseDF(result.text) { return disk }
        }
        return nil
    }

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
    /// Total CPU is their sum over the cores, which is what top reports
    /// without waiting a second between two samples.
    static func parsePS(_ output: String, cores: Double, sortBy: String) -> Sample? {
        var processes: [ProcessRow] = []
        var total = 0.0
        for raw in output.split(separator: "\n") {
            let fields = raw.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int(fields[0]), let cpu = Double(fields[1].replacingOccurrences(of: ",", with: ".")), let kib = Double(fields[2]) else { continue }
            total += cpu
            let path = String(fields[3])
            let name = path.hasPrefix("/") ? String(path.split(separator: "/").last ?? Substring(path)) : path
            processes.append(ProcessRow(pid: pid, command: name, cpu: cpu, memory: "\(Int(kib))K", rss: kib * 1024))
        }
        guard !processes.isEmpty else { return nil }
        processes.sort { sortBy == "Memory" ? $0.rss > $1.rss : ($0.cpu, $0.rss) > ($1.cpu, $1.rss) }
        return Sample(cpu: min(100, max(0, total / max(1, cores))), processes: Array(processes.prefix(8)))
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

    /// `2.4 MB/s`, `310 KB/s`, `0 KB/s`.
    static func speed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1e9 { return String(format: "%.1f GB/s", bytesPerSecond / 1e9) }
        if bytesPerSecond >= 1e6 { return String(format: bytesPerSecond >= 1e7 ? "%.0f MB/s" : "%.1f MB/s", bytesPerSecond / 1e6) }
        return String(format: "%.0f KB/s", bytesPerSecond / 1e3)
    }

    static func percentages(in line: String) -> [Double] {
        line.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { word in
            word.hasSuffix("%") ? Double(word.dropLast()) : nil
        }
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

    /// top's `1129M-` or `6337K+` as `1.1 GB` or `6 MB`.
    static func memory(_ text: String) -> String {
        guard let bytes = bytes(text) else { return text }
        let megabytes = bytes / pow(1024, 2)
        return megabytes >= 1000 ? String(format: "%.1f GB", megabytes / 1024) : String(format: "%.0f MB", max(1, megabytes))
    }

    static func size(_ bytes: Double) -> String {
        let gigabytes = bytes / pow(1024, 3)
        return gigabytes >= 10 || gigabytes == gigabytes.rounded() ? String(format: "%.0f GB", gigabytes) : String(format: "%.1f GB", gigabytes)
    }

    /// The menu bar stays quiet until something needs a look.
    /// `9.8`: gigabytes without the unit, for "9.8 of 16 GB".
    static func number(_ bytes: Double) -> String {
        let gigabytes = bytes / pow(1024, 3)
        return gigabytes >= 100 ? String(format: "%.0f", gigabytes) : String(format: "%.1f", gigabytes)
    }

    static func role(_ fraction: Double) -> Role {
        fraction >= 0.9 ? .critical : fraction >= 0.75 ? .warning : .primary
    }

    // MARK: Look

    let theme = Theme.green

    /// Green while there is room, amber when it's getting full, red when it's not.
    func tone(_ fraction: Double, calm: Theme? = nil) -> Theme {
        fraction >= 0.9 ? .critical : fraction >= 0.75 ? .warning : calm ?? theme
    }

    /// Each resource keeps its own ring color until it needs a look.
    func rings(_ sample: Sample) -> [RingCluster.Ring] {
        var rings = [
            RingCluster.Ring("CPU", value: sample.cpu / 100, theme: tone(sample.cpu / 100)),
            RingCluster.Ring("Memory", value: sample.memoryFraction, theme: tone(sample.memoryFraction, calm: .cyan)),
        ]
        if let disk { rings.append(RingCluster.Ring("Disk", value: disk.fraction, theme: tone(disk.fraction, calm: .violet))) }
        return rings
    }

    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    /// What a glance should take away: the two readings, or the one in trouble.
    func headline(_ sample: Sample) -> String {
        if sample.cpu >= 75 { return "CPU busy: \(Self.percent(sample.cpu / 100))" }
        if sample.memoryFraction >= 0.9 { return "Memory nearly full: \(Self.percent(sample.memoryFraction))" }
        if let disk, disk.fraction >= 0.9 { return "Disk nearly full: \(Self.size(disk.total - disk.used)) free" }
        return "CPU \(Self.percent(sample.cpu / 100)) · Memory \(Self.percent(sample.memoryFraction))"
    }

    // MARK: Surfaces

    var menuBar: ViewContent {
        if let sample {
            switch menuBarShows {
            case "CPU": Label(Self.percent(sample.cpu / 100), symbol: "cpu").role(Self.role(sample.cpu / 100))
            case "Memory": Label(Self.percent(sample.memoryFraction), symbol: "memorychip").role(Self.role(sample.memoryFraction))
            case "Network": Label(network.map { "↓\(Self.speed($0.down))" } ?? "–", symbol: "network").role(.primary)
            default: Label("\(Self.percent(sample.cpu / 100)) · \(Self.percent(sample.memoryFraction))", symbol: "gauge.with.dots.needle.33percent").role(Self.role(max(sample.cpu / 100, sample.memoryFraction)))
            }
        } else {
            Label("", symbol: "gauge.with.dots.needle.33percent").role(.secondary)
        }
    }

    var panel: ViewContent {
        if let problem, sample == nil {
            EmptyState("Can't read the system", symbol: "exclamationmark.triangle", message: problem, theme: .critical) {
                ActionButton("Try Again", symbol: "arrow.clockwise", theme: theme, prominent: true) { await self.measure() }
            }
        } else if let sample {
            VStack(spacing: Space.m) {
                PanelHeader(headline(sample), subtitle: sample.load.count == 3 ? "Load " + sample.load.map { String(format: "%.2f", $0) }.joined(separator: "  ") : nil, symbol: "gauge.with.dots.needle.33percent", theme: theme)
                HeroCard(theme: theme, look: .glow) {
                    HStack(spacing: Space.l) {
                        RingCluster(rings(sample), size: 116, lineWidth: 11, gap: 3)
                        VStack(spacing: Space.s) {
                            legend("CPU", value: Self.percent(sample.cpu / 100), detail: "busy", theme: tone(sample.cpu / 100))
                            legend("Memory", value: Self.percent(sample.memoryFraction), detail: "\(Self.number(sample.memoryUsed)) of \(Self.size(sample.memoryTotal))", theme: tone(sample.memoryFraction, calm: .cyan))
                            if let disk { legend("Disk", value: Self.percent(disk.fraction), detail: "\(Self.size(disk.total - disk.used)) free", theme: tone(disk.fraction, calm: .violet)) }
                        }
                        .frame(fillWidth: true)
                    }
                }
                if cpuHistory.count >= 3 {
                    Card("CPU", detail: cpuHistory.count >= 30 ? "last 5 min" : "since \(cpuHistory.count * 10 / 60 < 1 ? "\(cpuHistory.count * 10) s" : "\(cpuHistory.count * 10 / 60) min") ago") {
                        Sparkline(cpuHistory, theme: tone(sample.cpu / 100), height: 48, label: "CPU over time")
                        HStack {
                            Text("Peak \(Self.percent((cpuHistory.max() ?? 0) / 100))").role(.secondary).typography(.captionNumber)
                            Spacer()
                            Text("Average \(Self.percent(cpuHistory.reduce(0, +) / Double(cpuHistory.count) / 100))").role(.secondary).typography(.captionNumber)
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
                VStack(spacing: Space.xs) {
                    HStack(spacing: Space.s) {
                        CardTitle("Top processes")
                        Picker("Sort by", options: ["CPU", "Memory"], selection: sortBy, style: .segmented) { choice in
                            self.sortBy = choice
                            await self.measure()
                        }
                        .frame(width: 150)
                    }
                    ForEach(sample.processes.prefix(8)) { process in
                        Row(process.command, subtitle: "pid \(process.pid) · \(Self.memory(process.memory))", symbol: "gearshape", key: "\(process.pid)")
                            .badge(sortBy == "Memory" ? Self.memory(process.memory) : String(format: "%.1f%%", process.cpu), role: process.cpu > 80 ? .warning : .secondary)
                            .action("Copy PID") { Stackbar.copy("\(process.pid)") }
                            .action("Quit Process", role: .critical) { try await self.quit(process) }
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
        .accessibilityLabel("\(name) \(value), \(detail)")
    }

    var widget: ViewContent {
        if let sample {
            HStack(spacing: Space.m) {
                RingCluster(rings(sample), size: 96, lineWidth: 9, gap: 2)
                VStack(spacing: Space.xs) {
                    legend("CPU", value: Self.percent(sample.cpu / 100), detail: "", theme: tone(sample.cpu / 100))
                    if cpuHistory.count >= 3 { Sparkline(cpuHistory, theme: tone(sample.cpu / 100), height: 22) }
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

    func quit(_ process: ProcessRow) async throws {
        let result = try await Stackbar.run("kill", ["-TERM", "\(process.pid)"], timeout: .seconds(10))
        guard result.succeeded else {
            throw HostError("Couldn't quit \(process.command): " + (result.errorText.contains("not permitted") ? "it belongs to another user" : result.errorText))
        }
        await measure()
    }

    var settings: ViewContent {
        Section("Menu bar") {
            Picker("Show", options: ["CPU and memory", "CPU", "Memory", "Network"], selection: menuBarShows, style: .segmented) { self.menuBarShows = $0 }
        }
        Section("Alerts") {
            Toggle("Notify when CPU or memory stays high", isOn: alertsOn) { self.alertsOn = $0 }
            Picker("CPU above", options: ["70%", "85%", "95%"], selection: "\(Int(cpuThreshold))%", style: .segmented) { choice in
                self.cpuThreshold = Double(choice.dropLast()) ?? 85
            }
            Text("After a minute above the line, once, naming the busiest process. Memory alerts at 90% and the disk at 95%.").style(.caption)
        }
    }

    // MARK: Commands

    var commands: [Command] {
        Command("top", title: "Top Processes", subtitle: "What is using your CPU and memory", symbol: "gauge.with.dots.needle.67percent", keywords: ["cpu", "memory", "process", "activity", "kill", "quit", "slow"])
            .argument("by", placeholder: "Sort by", required: false, default: "CPU", options: ["CPU", "Memory"])
            .view(search: { invocation in
                if let by = invocation["by"], by != self.sortBy { self.sortBy = by }
                await self.measure()
            }) { _ in
                if let sample = self.sample {
                    List(sample.processes, searchable: true) { process in
                        Row(process.command, subtitle: "pid \(process.pid) · \(String(format: "%.1f%%", process.cpu)) CPU · \(Self.memory(process.memory))", symbol: "gearshape", key: "\(process.pid)")
                            .action("Copy PID") { Stackbar.copy("\(process.pid)") }
                            .action("Quit Process", shortcut: "cmd+.", role: .critical) { try await self.quit(process) }
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
                "cpu: \(Int(sample.cpu.rounded()))%",
                "memory: \(Self.size(sample.memoryUsed)) of \(Self.size(sample.memoryTotal))",
            ]
            if let disk = self.disk { lines.append("disk: \(Self.size(disk.used)) of \(Self.size(disk.total))") }
            if let network = self.network { lines.append("network: \(Self.speed(network.down)) down, \(Self.speed(network.up)) up") }
            lines += sample.processes.map { "\($0.pid) \($0.command) \($0.cpu)% cpu \($0.memory)" }
            return lines.joined(separator: "\n")
        }
    }
}
