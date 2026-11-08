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
        version: "1.3.0",
        summary: "Find a process by name, see its CPU and memory, and quit or force quit it.",
        surfaces: [.panel, .settings],
        triggers: [.launch, .every(.seconds(60))],
        capabilities: [.run(commands: ["ps", "kill"])],
        minimumStackbar: "0.35.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/System/KillProcess",
        accent: .red,
        symbol: "xmark.octagon.fill"
    )

    static let previews: [PreviewScene<KillProcess>] = [
        PreviewScene("hero", "The heaviest processes, one key from gone") { plugin in
            plugin.processes = sample
            plugin.loadedAt = Date()
        },
        PreviewScene("memory", "Sort by memory to find the heavy one") { plugin in
            plugin.processes = sample
            plugin.sortByMemory = true
        },
        PreviewScene("unavailable", "A failed scan keeps the last list") { plugin in
            plugin.processes = sample
            plugin.problem = "Couldn't run ps. Stackbar will try again in a minute."
        },
    ]

    static let sample: [Proc] = [
        Proc(pid: 48211, cpu: 182.4, memory: 1_240_000, name: "node", args: "/usr/local/bin/node /Users/you/projects/api/server.js"),
        Proc(pid: 3121, cpu: 64.0, memory: 2_900_000, name: "Google Chrome Helper (Renderer)", args: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer) --type=renderer"),
        Proc(pid: 902, cpu: 21.7, memory: 640_000, name: "Xcode", args: "/Applications/Xcode.app/Contents/MacOS/Xcode"),
        Proc(pid: 1880, cpu: 8.2, memory: 4_100_000, name: "ollama", args: "/usr/local/bin/ollama serve"),
        Proc(pid: 733, cpu: 0.4, memory: 52_000, name: "redis-server", args: "redis-server *:6379"),
    ]

    let theme = Theme.red

    struct Proc: Equatable, Identifiable {
        var pid: Int
        var cpu: Double
        /// Resident memory in kilobytes, as `ps` reports it.
        var memory: Int
        var name: String
        /// The whole command line, as `ps` reports it; empty when it couldn't be read.
        var args: String = ""
        var id: String { "\(pid)" }
    }

    /// A process as the busy alert tracks it: by pid and by name, since a pid
    /// can be reused by another program.
    struct Watch: Hashable {
        var pid: Int
        var name: String
    }

    /// When a process first went above the line, and when it was last seen there.
    struct Spell: Equatable {
        var since: Date
        var last: Date
    }

    /// Ending these logs you out or freezes the screen. This plugin's own
    /// process is left out too.
    static let protected: Set<String> = ["loginwindow", "WindowServer", "Dock", "launchd", "kernel_task", "Stackbar"]

    static func isProtected(pid: Int, name: String) -> Bool {
        protected.contains(name) || pid == Int(ProcessInfo.processInfo.processIdentifier)
    }

    var processes: [Proc] = []
    var loadedAt: Date?
    var problem: String?
    var results: [Proc] = []
    /// Processes above the busy line on each poll, since when.
    var spells: [Watch: Spell] = [:]
    /// Processes already notified for their current busy spell.
    var notified: Set<Watch> = []
    @Stored("sortByMemory") var sortByMemory = false
    @Stored("alertBusy") var alertBusy = false
    @Stored("alertAbove") var alertAbove = "90%"

    /// Reads every process and its command line. A failed read keeps the list
    /// from before, which the panel and the palette show under a note.
    func load(force: Bool = false) async {
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 3 { return }
        // Only this user's processes (-x without -a), with the bare
        // executable name (-c) and no header (the = after each column).
        guard let result = try? await Stackbar.run("ps", ["-xco", "pid=,%cpu=,rss=,comm="], timeout: .seconds(10)), result.succeeded else {
            problem = "Couldn't run ps. Stackbar will try again in a minute."
            return
        }
        let listed = Self.parse(result.text)
        // The command lines come from a second ps call, so a pid can have been
        // reused in between; parseArgs checks each line against the name.
        var commands: [Int: String] = [:]
        if let lines = try? await Stackbar.run("ps", ["-xwwo", "pid=,args="], timeout: .seconds(10)), lines.succeeded {
            commands = Self.parseArgs(lines.text, names: Dictionary(listed.map { ($0.pid, $0.name) }, uniquingKeysWith: { first, _ in first }))
        }
        processes = listed.map { process in
            var process = process
            process.args = commands[process.pid] ?? ""
            return process
        }
        loadedAt = Date()
        problem = nil
    }

    /// Every minute, so the panel's list and the numbers beside each
    /// pid follow along; a scan the palette made a moment ago is reused.
    /// Busy spells are checked after every fresh read, whatever started it.
    /// They are timed on the clock, so an early read (a wake, a manual
    /// refresh) only moves where a spell was last seen and can't speed it up.
    func refresh() async throws {
        let before = loadedAt
        await load(force: Stackbar.refreshReason != .interval)
        if loadedAt != before { checkBusy(at: Date()) }
    }

    /// `ps -o pid=,%cpu=,rss=,comm=` lines: `48211 182.4 1240000 node`.
    static func parse(_ output: String) -> [Proc] {
        output.split(separator: "\n").compactMap { line -> Proc? in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int(fields[0]), let cpu = Double(fields[1].replacingOccurrences(of: ",", with: ".")), let memory = Int(fields[2]) else { return nil }
            let name = String(fields[3]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !isProtected(pid: pid, name: name) else { return nil }
            return Proc(pid: pid, cpu: cpu, memory: memory, name: name)
        }
    }

    /// `ps -xwwo pid=,args=` lines: the whole command line of each pid. A line
    /// counts only for a pid in `names` whose command line still holds that
    /// name, so a pid reused between the two `ps` calls takes no stranger's
    /// line, and the first line for a pid wins. A line without a pid (the rest
    /// of an argument that has a newline in it) is skipped.
    static func parseArgs(_ output: String, names: [Int: String]) -> [Int: String] {
        var commands: [Int: String] = [:]
        for raw in output.split(separator: "\n") {
            let parts = raw.drop { $0 == " " }.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int(parts[0]), commands[pid] == nil, let name = names[pid] else { continue }
            let args = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard args.contains(name) else { continue }
            commands[pid] = args
        }
        return commands
    }

    /// The command line without the program's own path: `/usr/local/bin/node
    /// server.js` reads `node server.js`. The path ends at the last "/name"
    /// followed by a space or the end: a directory can have a space and the
    /// name in it (`/Users/me/node projects/x/node server.js`), and a helper's
    /// bundle path has the name twice (`Code Helper.app/…/Code Helper --type=…`).
    /// Capped at about 60 characters.
    static func shortCommand(_ name: String, _ line: String) -> String {
        var cut: String.Index?
        var search = line.startIndex..<line.endIndex
        while let range = line.range(of: "/" + name, range: search) {
            if range.upperBound == line.endIndex || line[range.upperBound] == " " {
                cut = range.upperBound
            }
            search = range.upperBound..<line.endIndex
        }
        let text = cut.map { name + String(line[$0...]) } ?? line
        return text.count > 60 ? String(text.prefix(59)) + "…" : text
    }

    /// Heaviest first, by CPU or memory.
    func sorted(_ list: [Proc]) -> [Proc] {
        list.sorted { sortByMemory ? ($0.memory, $0.cpu) > ($1.memory, $1.cpu) : ($0.cpu, $0.memory) > ($1.cpu, $1.memory) }
    }

    /// Processes whose name or command line holds every word typed, or whose
    /// pid is what was typed; the heaviest first, names that start with the
    /// first word before the rest.
    func matches(_ query: String) -> [Proc] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return Array(sorted(processes).prefix(60)) }
        if words.count == 1, let pid = Int(words[0]) { return processes.filter { $0.pid == pid } }
        let found = processes.filter { process in
            let text = (process.name + " " + process.args).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        let first = words[0]
        return Array(sorted(found).sorted { ($0.name.lowercased().hasPrefix(first) ? 0 : 1) < ($1.name.lowercased().hasPrefix(first) ? 0 : 1) }.prefix(60))
    }

    static func memory(_ kilobytes: Int) -> String {
        let megabytes = Double(kilobytes) / 1024
        return megabytes >= 1024 ? String(format: "%.1f GB", megabytes / 1024) : String(format: "%.0f MB", megabytes)
    }

    /// `Stackbar plugin: system-monitor` for a plugin's own process, which is
    /// named by its identifier.
    static func label(_ name: String) -> String {
        guard name.hasPrefix("io.navbytes.stackbar.") else { return name }
        return "Stackbar plugin: " + (name.split(separator: ".").last.map(String.init) ?? name)
    }

    // MARK: Busy alerts

    /// Notifies once when one of your processes has been above the line for
    /// two minutes of polls. Polls are a minute apart, so a gap longer than 90
    /// seconds (a sleep, a missed poll) starts the count again. A process that
    /// drops below the line can notify again later.
    func checkBusy(at now: Date) {
        guard alertBusy else {
            spells = [:]
            notified = []
            return
        }
        let line = Double(alertAbove.dropLast()) ?? 90
        var next: [Watch: Spell] = [:]
        for process in processes where process.cpu >= line {
            let watch = Watch(pid: process.pid, name: process.name)
            var spell = spells[watch] ?? Spell(since: now, last: now)
            if now.timeIntervalSince(spell.last) > 90 { spell = Spell(since: now, last: now) }
            spell.last = now
            next[watch] = spell
        }
        spells = next
        notified.formIntersection(next.keys)
        for (watch, spell) in next where now.timeIntervalSince(spell.since) >= 120 && !notified.contains(watch) {
            guard let process = processes.first(where: { $0.pid == watch.pid && $0.name == watch.name }) else { continue }
            notified.insert(watch)
            Stackbar.notify("\(Self.label(process.name)) has been busy for two minutes", body: "It has used \(Int(process.cpu))% CPU recently. Show it to quit it.", actions: [NotificationAction("Show", command: "search", arguments: ["text": process.name])])
        }
    }

    // MARK: Ending

    /// Ends the processes the shared way. Each pid must still have the name it
    /// was listed under, since pids get reused. The signal goes out, then the
    /// pids are checked for up to two seconds. Processes that ended leave both
    /// lists in place, and the HUD says how many ended.
    func end(_ targets: [Proc], force: Bool) async {
        let allowed = targets.filter { !Self.isProtected(pid: $0.pid, name: $0.name) }
        guard let first = allowed.first else { return }
        guard let names = await Self.commandNames(allowed.map(\.pid)) else {
            Stackbar.hud("Couldn't check \(Self.label(first.name)); nothing was quit", isError: true)
            return
        }
        let ours = allowed.filter { names[$0.pid] == $0.name }
        guard !ours.isEmpty else {
            forget(Set(allowed.map(\.pid)))
            Stackbar.hud("\(Self.label(first.name)) has already ended")
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
        forget(Set(allowed.map(\.pid)).subtracting(alive))
        let ended = ours.count - alive.count
        if alive.isEmpty {
            Stackbar.hud(ended == allowed.count ? "Ended \(ended) of \(allowed.count)" : "Ended \(ended) · \(allowed.count - ended) had already ended")
        } else {
            let refused = sent?.errorText.contains("not permitted") == true
            Stackbar.hud("Ended \(ended) of \(allowed.count) · \(Self.label(first.name)) is still running" + (refused ? ": it belongs to another user" : ""), isError: true)
        }
    }

    /// The name each of these pids runs as now, in the same columns the list
    /// is read in, so the names compare. Pids that are gone are left out. Nil
    /// when the check itself failed (`ps` threw, timed out or wrote an error),
    /// which is not the same as "gone".
    static func commandNames(_ pids: [Int]) async -> [Int: String]? {
        guard !pids.isEmpty else { return [:] }
        guard let result = try? await Stackbar.run("ps", ["-co", "pid=,comm=", "-p", pids.map(String.init).joined(separator: ",")], timeout: .seconds(10)), !result.timedOut else { return nil }
        // `ps -p` exits 1 with no output when none of the pids is running.
        if result.status != 0 && !result.errorText.isEmpty { return nil }
        var names: [Int: String] = [:]
        for line in result.text.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2, let pid = Int(fields[0]) else { continue }
            names[pid] = String(fields[1]).trimmingCharacters(in: .whitespaces)
        }
        return names
    }

    /// Takes these pids out of both lists, in place.
    func forget(_ pids: Set<Int>) {
        processes.removeAll { pids.contains($0.pid) }
        results.removeAll { pids.contains($0.pid) }
    }

    /// The command line, shortened, then CPU and memory. The command line is
    /// what tells two processes with the same name apart.
    func subtitle(_ process: Proc) -> String {
        let command = process.args.isEmpty ? "pid \(process.pid)" : Self.shortCommand(process.name, process.args)
        return "\(command) · \(String(format: "%.1f", process.cpu))% CPU · \(Self.memory(process.memory))"
    }

    func row(_ process: Proc) -> Row {
        let group = processes.filter { $0.name == process.name }
        // Stackbar asks for a second press before any of these runs.
        let name = Self.label(process.name)
        var row = Row(name, subtitle: subtitle(process), symbol: "gearshape", key: process.id)
            .action("Quit Process", role: .critical, confirm: "quit \(name) (pid \(process.pid))") { await self.end([process], force: false) }
            .action("Force Quit Process", shortcut: "cmd+shift+return", role: .critical, confirm: "force quit \(name) (pid \(process.pid))") { await self.end([process], force: true) }
        if group.count > 1 {
            row = row.action("Quit All \(group.count) Named \(process.name)", role: .critical, confirm: "quit all \(group.count) \(name)") { await self.end(group, force: false) }
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
                // A notification's Show button passes the name as an argument, not as typed text.
                let text = invocation.text.isEmpty ? invocation["text"] ?? "" : invocation.text
                self.results = self.matches(text)
            }) { _ in
                if self.processes.isEmpty, let problem = self.problem {
                    ContentUnavailableView("Can't list processes", symbol: "exclamationmark.triangle", message: problem)
                } else {
                    if let problem = self.problem { Banner(problem, theme: .warning) }
                    if self.results.isEmpty {
                        ContentUnavailableView("No process matches", symbol: "magnifyingglass", message: "Type part of a process name, or its pid.")
                    } else {
                        List {
                            ForEach(self.results) { process in self.row(process) }
                        }
                    }
                }
            }
    }

    // MARK: Panel

    /// The busiest process and its CPU: the state at a glance.
    var headline: String {
        guard let busiest = processes.max(by: { $0.cpu < $1.cpu }) else { return "Kill Process" }
        return "\(Self.label(busiest.name)) · \(Int(busiest.cpu.rounded()))% CPU"
    }

    var panel: ViewContent {
        PanelHeader(headline, subtitle: "\(processes.count) of your processes · Kill Process in the palette", symbol: "xmark.octagon.fill", theme: theme) {
            IconButton("arrow.clockwise", label: "Refresh", theme: theme, prominence: .tinted) { await self.load(force: true) }
        }
        if let problem {
            Banner(problem, theme: .warning)
        }
        Picker("Sort by", options: ["CPU", "Memory"], selection: sortByMemory ? "Memory" : "CPU", style: .segmented) { self.sortByMemory = $0 == "Memory" }
        Card("Heaviest now", spacing: 0, padding: Space.s) {
            ForEach(Array(sorted(processes).prefix(8))) { process in self.row(process) }
        }
    }

    // MARK: Settings

    var settings: ViewContent {
        Section("Alerts") {
            Toggle("Notify when a process stays busy", isOn: alertBusy) { self.alertBusy = $0 }
            Picker("Busy above", options: ["50%", "90%", "150%"], selection: alertAbove, style: .segmented) { self.alertAbove = $0 }
            Text("After two minutes above the line, once, naming the process. A process that calms down can notify again. Checked every minute, for your own processes.").style(.caption)
        }
    }
}
