import StackbarKit
import Foundation

/// Find a stuck process by name and end it from the palette, as Raycast's
/// Kill Process does: type "kill" and part of the name, see what it costs in
/// CPU and memory, and press Return to quit it. Force Quit is a ⌘K away.
/// Only your own processes are listed, and the few that would log you out
/// are left alone.
@main
final class KillProcess: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.kill-process",
        name: "Kill Process",
        version: "1.0.0",
        summary: "Find a process by name, see its CPU and memory, and quit or force quit it.",
        surfaces: [.panel],
        triggers: [.launch],
        capabilities: [.run(commands: ["ps", "kill"])],
        minimumStackbar: "0.22.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/System/KillProcess",
        accent: .red,
        symbol: "xmark.octagon.fill"
    )

    static let previews: [PreviewScene<KillProcess>] = [
        PreviewScene("hero", "The heaviest processes, one key from gone") { plugin in
            plugin.processes = [
                Proc(pid: 48211, cpu: 182.4, memory: 1_240_000, name: "node"),
                Proc(pid: 3121, cpu: 64.0, memory: 2_900_000, name: "Google Chrome Helper (Renderer)"),
                Proc(pid: 902, cpu: 21.7, memory: 640_000, name: "Xcode"),
                Proc(pid: 1880, cpu: 8.2, memory: 4_100_000, name: "ollama"),
                Proc(pid: 733, cpu: 0.4, memory: 52_000, name: "redis-server"),
            ]
            plugin.loadedAt = Date()
        },
    ]

    let theme = Theme.red

    struct Proc: Equatable, Identifiable {
        var pid: Int
        var cpu: Double
        /// Resident memory in kilobytes, as `ps` reports it.
        var memory: Int
        var name: String
        var id: String { "\(pid)" }
    }

    /// Ending these logs you out or freezes the screen.
    static let protected: Set<String> = ["loginwindow", "WindowServer", "launchd", "kernel_task", "Stackbar"]

    var processes: [Proc] = []
    var loadedAt: Date?
    var problem: String?
    var results: [Proc] = []
    @Stored("sortByMemory") var sortByMemory = false

    func load(force: Bool = false) async {
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 3 { return }
        do {
            // Only this user's processes (-x without -a), with the bare
            // executable name (-c) and no header (the = after each column).
            let result = try await Stackbar.run("ps", ["-xco", "pid=,%cpu=,rss=,comm="], timeout: .seconds(10))
            guard result.succeeded else {
                problem = "ps failed (\(result.status)): \(result.errorText.prefix(200))"
                return
            }
            processes = Self.parse(result.text)
            loadedAt = Date()
            problem = nil
        } catch {
            problem = "\(error)"
        }
    }

    func refresh() async throws {
        await load(force: true)
    }

    /// `ps -o pid=,%cpu=,rss=,comm=` lines: `48211 182.4 1240000 node`.
    static func parse(_ output: String) -> [Proc] {
        output.split(separator: "\n").compactMap { line -> Proc? in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int(fields[0]), let cpu = Double(fields[1].replacingOccurrences(of: ",", with: ".")), let memory = Int(fields[2]) else { return nil }
            let name = String(fields[3]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !protected.contains(name) else { return nil }
            return Proc(pid: pid, cpu: cpu, memory: memory, name: name)
        }
    }

    /// Heaviest first, by CPU or memory.
    func sorted(_ list: [Proc]) -> [Proc] {
        list.sorted { sortByMemory ? ($0.memory, $0.cpu) > ($1.memory, $1.cpu) : ($0.cpu, $0.memory) > ($1.cpu, $1.memory) }
    }

    /// Processes whose name holds every word typed, or whose pid is what
    /// was typed; the heaviest first, names that start with it before the
    /// rest.
    func matches(_ query: String) -> [Proc] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return Array(sorted(processes).prefix(60)) }
        if words.count == 1, let pid = Int(words[0]) { return processes.filter { $0.pid == pid } }
        let found = processes.filter { process in
            let name = process.name.lowercased()
            return words.allSatisfy { name.contains($0) }
        }
        let first = words[0]
        return Array(sorted(found).sorted { ($0.name.lowercased().hasPrefix(first) ? 0 : 1) < ($1.name.lowercased().hasPrefix(first) ? 0 : 1) }.prefix(60))
    }

    static func memory(_ kilobytes: Int) -> String {
        let megabytes = Double(kilobytes) / 1024
        return megabytes >= 1024 ? String(format: "%.1f GB", megabytes / 1024) : String(format: "%.0f MB", megabytes)
    }

    // MARK: Ending

    @discardableResult
    func end(_ pids: [Int], name: String, force: Bool) async throws -> String {
        let result = try await Stackbar.run("kill", [force ? "-KILL" : "-TERM"] + pids.map(String.init), timeout: .seconds(10))
        await load(force: true)
        guard result.succeeded else {
            throw HostError("Couldn't end \(name): \(result.errorText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let message = force ? "Force quit \(name)" : "Asked \(name) to quit"
        Stackbar.hud(message)
        return message
    }

    func row(_ process: Proc) -> Row {
        let siblings = processes.filter { $0.name == process.name }.map(\.pid)
        var row = Row(process.name, subtitle: "\(String(format: "%.1f", process.cpu))% CPU · \(Self.memory(process.memory)) · pid \(process.pid)", symbol: "gearshape", key: process.id)
            .action("Quit Process") { try await self.end([process.pid], name: process.name, force: false) }
            .action("Force Quit Process", shortcut: "cmd+shift+return", role: .critical) { try await self.end([process.pid], name: process.name, force: true) }
        if siblings.count > 1 {
            row = row.action("Quit All \(siblings.count) Named \(process.name)") { try await self.end(siblings, name: process.name, force: false) }
        }
        row = row.action("Copy PID", shortcut: "cmd+shift+c") { Stackbar.copy("\(process.pid)") }
        if process.cpu >= 80 { row = row.badge("High CPU", role: .critical) }
        return row
    }

    // MARK: Commands

    var commands: [Command] {
        Command("search", title: "Kill Process", subtitle: "Quit or force quit a process by name", symbol: "xmark.octagon", keywords: ["kill", "process", "quit", "force", "cpu", "memory", "activity"])
            .view(search: { invocation in
                await self.load()
                self.results = self.matches(invocation.text)
            }) { _ in
                if let problem = self.problem {
                    ContentUnavailableView("Can't list processes", symbol: "exclamationmark.triangle", message: problem)
                } else if self.results.isEmpty {
                    ContentUnavailableView("No process matches", symbol: "magnifyingglass", message: "Type part of a process name, or its pid.")
                } else {
                    List {
                        ForEach(self.results) { process in self.row(process) }
                    }
                }
            }
    }

    // MARK: Panel

    var panel: ViewContent {
        PanelHeader("Kill Process", subtitle: "\(processes.count) of your processes · Kill Process in the palette", symbol: "xmark.octagon.fill", theme: theme)
        if let problem {
            Banner(problem, theme: .warning)
        }
        Picker("Sort by", options: ["CPU", "Memory"], selection: sortByMemory ? "Memory" : "CPU", style: .segmented) { self.sortByMemory = $0 == "Memory" }
        Card("Heaviest now", spacing: 0, padding: Space.s) {
            ForEach(Array(sorted(processes).prefix(8))) { process in self.row(process) }
        }
    }
}
