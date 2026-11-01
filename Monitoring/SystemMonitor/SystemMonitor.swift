import StackbarKit
import Foundation

/// CPU, memory and disk in the menu bar, with the processes using the most.
///
/// Every 10 seconds it runs `top` once for two one-second samples (the
/// second is the accurate one), `vm_stat` for memory the way Activity
/// Monitor counts it (app memory, wired and compressed, not the file cache)
/// and `df` for the disk, through Stackbar. Nothing runs in a shell.
@main
final class SystemMonitor: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.system-monitor",
        name: "System Monitor",
        version: "1.0.0",
        summary: "CPU, memory and disk in the menu bar, with the processes using the most.",
        surfaces: [.menuBar, .panel, .widget, .settings],
        triggers: [.launch, .every(.seconds(10)), .wake],
        capabilities: [.run(commands: ["top", "vm_stat", "df", "kill"])],
        minimumStackbar: "0.11.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Monitoring/SystemMonitor"
    )

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
    }

    struct Disk: Equatable {
        var used: Double
        var total: Double
        var fraction: Double { total > 0 ? used / total : 0 }
    }

    var sample: Sample?
    var disk: Disk?
    var cpuHistory: [Double] = []
    var problem: String?

    @Stored("menuBarShows") var menuBarShows = "CPU and memory"
    @Stored("sortBy") var sortBy = "CPU"

    func refresh() async throws {
        await measure()
    }

    func measure() async {
        do {
            let order = sortBy == "Memory" ? "mem" : "cpu"
            let result = try await Stackbar.run("top", ["-l", "2", "-s", "1", "-n", "8", "-o", order, "-stats", "pid,command,cpu,mem"], timeout: .seconds(15))
            guard result.succeeded, var parsed = Self.parseTop(result.text) else {
                problem = result.succeeded ? "Couldn't read top's output" : "top failed (\(result.status)): \(result.errorText.prefix(160))"
                return
            }
            if let vm = try? await Stackbar.run("vm_stat", timeout: .seconds(10)), vm.succeeded, let used = Self.parseVMStat(vm.text) {
                parsed.memoryUsed = min(used, parsed.memoryTotal)
            }
            sample = parsed
            cpuHistory = Array((cpuHistory + [parsed.cpu]).suffix(30))
            problem = nil
        } catch {
            problem = "\(error)"
        }
        disk = await Self.readDisk()
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

    /// Reads the last of top's samples.
    static func parseTop(_ output: String) -> Sample? {
        let samples = output.components(separatedBy: "Processes:")
        guard samples.count >= 2, let last = samples.last else { return nil }
        var sample = Sample()
        var foundCPU = false
        var inTable = false
        for raw in last.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("CPU usage:") {
                // CPU usage: 7.69% user, 10.25% sys, 82.5% idle
                let numbers = percentages(in: line)
                if numbers.count >= 3 {
                    sample.cpu = min(100, max(0, 100 - numbers[2]))
                    foundCPU = true
                }
            } else if line.hasPrefix("Load Avg:") {
                sample.load = line.dropFirst("Load Avg:".count).split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            } else if line.hasPrefix("PhysMem:") {
                // PhysMem: 15G used (2101M wired, 3240M compressor), 140M unused.
                let words = line.split(separator: " ")
                for (index, word) in words.enumerated() where index > 0 {
                    let next = words.indices.contains(index + 1) ? words[index + 1] : ""
                    if next.hasPrefix("used") { sample.memoryUsed = bytes(String(word)) ?? 0 }
                    if next.hasPrefix("unused") { sample.memoryTotal = sample.memoryUsed + (bytes(String(word)) ?? 0) }
                }
            } else if line.hasPrefix("PID") {
                inTable = true
            } else if inTable {
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count >= 4, let pid = Int(fields[0]), let cpu = Double(fields[fields.count - 2]) else { continue }
                let command = fields[1..<(fields.count - 2)].joined(separator: " ")
                sample.processes.append(ProcessRow(pid: pid, command: command, cpu: cpu, memory: String(fields[fields.count - 1])))
            }
        }
        return foundCPU ? sample : nil
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

    static func size(_ bytes: Double) -> String {
        let gigabytes = bytes / pow(1024, 3)
        return gigabytes >= 100 ? String(format: "%.0f GB", gigabytes) : String(format: "%.1f GB", gigabytes)
    }

    static func role(_ fraction: Double) -> Role {
        fraction >= 0.9 ? .critical : fraction >= 0.75 ? .warning : .accent
    }

    // MARK: Surfaces

    var menuBar: ViewContent {
        if let sample {
            switch menuBarShows {
            case "CPU": Label("\(Int(sample.cpu.rounded()))%", symbol: "cpu").role(Self.role(sample.cpu / 100))
            case "Memory": Label("\(Int((sample.memoryFraction * 100).rounded()))%", symbol: "memorychip").role(Self.role(sample.memoryFraction))
            default: Label("\(Int(sample.cpu.rounded()))% · \(Int((sample.memoryFraction * 100).rounded()))%", symbol: "gauge.with.dots.needle.33percent").role(Self.role(max(sample.cpu / 100, sample.memoryFraction)))
            }
        } else {
            Label("", symbol: "gauge.with.dots.needle.33percent").role(.secondary)
        }
    }

    var panel: ViewContent {
        if let problem, sample == nil {
            ContentUnavailableView("Can't read the system", symbol: "exclamationmark.triangle", message: problem)
        } else if let sample {
            Section("CPU") {
                Chart("CPU", values: cpuHistory, kind: .area, role: Self.role(sample.cpu / 100), unit: "%")
                LabeledContent("Now", value: "\(Int(sample.cpu.rounded()))%")
                if sample.load.count == 3 {
                    LabeledContent("Load", value: sample.load.map { String(format: "%.2f", $0) }.joined(separator: "  "))
                }
            }
            Section("Memory and disk") {
                ProgressBar("Memory \(Self.size(sample.memoryUsed)) of \(Self.size(sample.memoryTotal))", value: sample.memoryFraction, role: Self.role(sample.memoryFraction))
                if let disk {
                    ProgressBar("Disk \(Self.size(disk.used)) of \(Self.size(disk.total))", value: disk.fraction, role: Self.role(disk.fraction))
                }
            }
            Section("Top processes by \(sortBy == "Memory" ? "memory" : "CPU")") {
                ForEach(sample.processes.prefix(8)) { process in
                    Row(process.command, subtitle: "pid \(process.pid) · \(process.memory)", symbol: "app", key: "\(process.pid)")
                        .badge(String(format: "%.1f%%", process.cpu), role: process.cpu > 80 ? .warning : .secondary)
                        .action("Copy PID") { Stackbar.copy("\(process.pid)") }
                        .action("Quit Process", role: .critical) { try await self.quit(process) }
                }
            }
        } else {
            ContentUnavailableView("Measuring…", symbol: "gauge.with.dots.needle.33percent")
        }
    }

    var widget: ViewContent {
        if let sample {
            ProgressBar("CPU \(Int(sample.cpu.rounded()))%", value: sample.cpu / 100, role: Self.role(sample.cpu / 100))
            ProgressBar("Memory \(Int((sample.memoryFraction * 100).rounded()))%", value: sample.memoryFraction, role: Self.role(sample.memoryFraction))
            if let disk { ProgressBar("Disk \(Int((disk.fraction * 100).rounded()))%", value: disk.fraction, role: Self.role(disk.fraction)) }
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
            Picker("Show", options: ["CPU and memory", "CPU", "Memory"], selection: menuBarShows) { self.menuBarShows = $0 }
        }
        Section("Processes") {
            Picker("Sort by", options: ["CPU", "Memory"], selection: sortBy) { choice in
                self.sortBy = choice
                await self.measure()
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
            lines += sample.processes.map { "\($0.pid) \($0.command) \($0.cpu)% cpu \($0.memory)" }
            return lines.joined(separator: "\n")
        }
    }
}
