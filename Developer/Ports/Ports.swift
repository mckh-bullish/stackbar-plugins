import StackbarKit
import Foundation

/// What is listening on which port, and a way to stop it.
///
/// "Kill Port 3000" from the palette ends whatever holds the port that a dev
/// server forgot to let go of. The panel lists every listening TCP port with
/// its process, from `lsof`, run through Stackbar every 30 seconds. Stopping sends SIGTERM, and SIGKILL only when you ask.
@main
final class Ports: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.ports",
        name: "Ports",
        version: "1.4.2",
        summary: "Which process is listening on which port, and a way to stop it.",
        surfaces: [.panel, .settings],
        triggers: [.launch, .every(.seconds(30))],
        capabilities: [.run(commands: ["lsof", "kill"])],
        minimumStackbar: "0.21.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Developer/Ports",
        accent: .teal,
        symbol: "point.3.connected.trianglepath.dotted"
    )

    // MARK: Previews

    static let previews: [PreviewScene<Ports>] = [
        PreviewScene("hero", "What's listening, and one click to stop it") { plugin in
            plugin.listeners = samples
            plugin.loaded = true
        },
        PreviewScene("confirm", "Asks before it stops anything") { plugin in
            plugin.listeners = samples
            plugin.loaded = true
            plugin.arm("stop:48211:127.0.0.1:3000")
            plugin.notice = "Press Stop Process again within 10 s to stop node (pid 48211)"
            plugin.noticeOK = false
        },
    ]

    static let samples: [Listener] = [
        Listener(port: 3000, address: "127.0.0.1", pid: 48211, process: "node", user: "you"),
        Listener(port: 5173, address: "[::1]", pid: 48390, process: "vite", user: "you"),
        Listener(port: 5432, address: "127.0.0.1", pid: 712, process: "postgres", user: "you"),
        Listener(port: 6379, address: "127.0.0.1", pid: 733, process: "redis-server", user: "you"),
        Listener(port: 8080, address: "*", pid: 51022, process: "java", user: "you"),
        Listener(port: 9229, address: "127.0.0.1", pid: 48211, process: "node", user: "you"),
        Listener(port: 11434, address: "127.0.0.1", pid: 1880, process: "ollama", user: "you"),
    ]

    struct Listener: Equatable, Identifiable {
        var port: Int
        var address: String
        var pid: Int
        var process: String
        var user: String
        var id: String { "\(pid):\(address):\(port)" }
        var isLocalOnly: Bool { address.hasPrefix("127.") || address == "[::1]" || address == "localhost" }
    }

    var listeners: [Listener] = []
    var loaded = false
    /// When `lsof` last answered, so a port typed in the palette reuses a
    /// fresh list instead of running it on every keystroke.
    var loadedAt: Date?
    var problem: String?
    var notice: String?
    var noticeOK = true
    /// The stop or force quit pressed once, waiting for a second press.
    var armed: String?
    var armedAt = Date.distantPast
    static let armWindow: TimeInterval = 10
    var armedNow: String? { armed.flatMap { Date().timeIntervalSince(armedAt) < Self.armWindow ? $0 : nil } }
    func arm(_ id: String) { armed = id; armedAt = Date() }

    @Stored("hideSystem") var hideSystem = true
    @Stored("minimumPort") var minimumPort = 1024

    var shown: [Listener] {
        listeners.filter { $0.port >= (hideSystem ? minimumPort : 0) }
    }

    static let ranges = ["All", "1024+", "3000+"]
    var range: String { !hideSystem || minimumPort <= 1 ? "All" : minimumPort >= 3000 ? "3000+" : "1024+" }

    func setRange(_ choice: String) {
        switch choice {
        case "All": hideSystem = false
        case "3000+": hideSystem = true; minimumPort = 3000
        default: hideSystem = true; minimumPort = 1024
        }
    }

    /// Scans in a row that found the same listeners. After a few, the
    /// timer slows from every 30 seconds to every two minutes: a system-wide
    /// `lsof` costs real CPU, and the plugin can't tell whether the panel is
    /// open. Any change, or any scan you ask for, brings the pace back.
    var unchangedScans = 0
    static let idleScans = 4

    func refresh() async throws {
        notice = nil
        if Stackbar.refreshReason == .interval, unchangedScans >= Self.idleScans, let at = loadedAt, Date().timeIntervalSince(at) < 110 { return }
        await load()
    }

    func load() async {
        do {
            // -F prints one field a line: p (pid), c (command), L (login), n (name).
            // +c 0 prints the whole command name; lsof cuts it to 9 characters otherwise.
            let result = try await Stackbar.run("lsof", ["+c", "0", "-nP", "-iTCP", "-sTCP:LISTEN", "-FpcLn"], timeout: .seconds(20))
            // lsof exits 1 when nothing matches.
            guard result.succeeded || (result.status == 1 && result.errorText.isEmpty) else {
                problem = "lsof failed (\(result.status)): \(result.errorText.prefix(200))"
                unchangedScans = 0
                loaded = true
                return
            }
            let fresh = Self.parse(result.text)
            unchangedScans = fresh == listeners && loaded ? unchangedScans + 1 : 0
            listeners = fresh
            loadedAt = Date()
            problem = nil
        } catch {
            problem = "\(error)"
        }
        loaded = true
    }

    /// For views that ask on every keystroke: a list read in the last ten
    /// seconds is as good as a new one.
    func loadIfStale() async {
        if loadedAt.map({ Date().timeIntervalSince($0) > 10 }) ?? true { await load() }
    }

    /// Parses `lsof -F pcLn` output; one entry per process and port.
    static func parse(_ output: String) -> [Listener] {
        var found: [Listener] = []
        var pid = 0
        var command = ""
        var user = ""
        for line in output.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                pid = Int(value) ?? 0
                command = ""
                user = ""
            case "c": command = value
            case "L": user = value
            case "n":
                // *:3000, 127.0.0.1:5432, [::1]:8080
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let address = String(value[..<colon])
                let listener = Listener(port: port, address: address == "*" ? "all interfaces" : address, pid: pid, process: command, user: user)
                // A process on both 127.0.0.1 and *:port is reachable from the network,
                // so keep its non-local listener when it has one.
                if let index = found.firstIndex(where: { $0.pid == pid && $0.port == port }) {
                    if found[index].isLocalOnly && !listener.isLocalOnly { found[index] = listener }
                } else {
                    found.append(listener)
                }
            default: break
            }
        }
        return found.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    func stop(_ listener: Listener, force: Bool) async throws -> String {
        // The row may be older than the process it shows: act only if the same
        // process still holds that port.
        await load()
        if let problem { throw HostError("Couldn't check \(listener.process) first: \(problem)") }
        guard listeners.contains(where: { $0.pid == listener.pid && $0.port == listener.port && $0.process == listener.process }) else {
            throw HostError("\(listener.process) is no longer listening on :\(listener.port)")
        }
        let result = try await Stackbar.run("kill", [force ? "-KILL" : "-TERM", "\(listener.pid)"], timeout: .seconds(10))
        guard result.succeeded else {
            let reason = result.errorText.contains("not permitted") ? "it belongs to another user" : result.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HostError("Couldn't stop \(listener.process) (\(listener.pid)): \(reason)")
        }
        unchangedScans = 0
        await load()
        let stillThere = listeners.contains { $0.pid == listener.pid }
        let message = !stillThere ? "Stopped \(listener.process) on :\(listener.port)"
            : force ? "Force quit \(listener.process); it is still listening" : "Asked \(listener.process) to stop"
        notice = message
        noticeOK = !(stillThere && force)
        return message
    }

    // MARK: Surfaces

    let theme = Theme.teal

    var panel: ViewContent {
        VStack(spacing: Space.m) {
            if let problem {
                EmptyState("Can't list ports", symbol: "exclamationmark.triangle.fill", message: problem, theme: .critical) {
                    ActionButton("Try Again", symbol: "arrow.clockwise", theme: theme) { await self.load() }
                }
            } else if !loaded {
                PanelHeader("Ports", subtitle: "Checking…", symbol: "network", theme: theme)
            } else {
                let open = shown.filter { !$0.isLocalOnly }.count
                PanelHeader(shown.isEmpty ? "Nothing listening" : "\(shown.count) listening", subtitle: open > 0 ? "\(open) reachable" : "All local", symbol: "network", theme: theme) {
                    Picker("Show ports", options: Self.ranges, selection: range, style: .segmented) { self.setRange($0) }
                        .frame(width: 180)
                }
                if !shown.isEmpty {
                    HeroCard(theme: theme, look: .glow) {
                        HStack(spacing: Space.l) {
                            HeroStat("Listening", value: "\(shown.count)", theme: theme, live: true)
                            HeroStat("Local", value: "\(shown.count - open)", theme: .neutral, symbol: "lock.fill")
                            HeroStat("Open", value: "\(open)", theme: open > 0 ? .warning : .neutral, symbol: "globe")
                            Spacer()
                        }
                    }
                }
                if let notice { Banner(notice, symbol: noticeOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", theme: noticeOK ? .success : .warning) }
                if shown.isEmpty {
                    EmptyState("Nothing is listening", symbol: "network", message: range == "All" ? nil : "Showing ports from \(minimumPort) up.", theme: theme) {
                        if range != "All" { ActionButton("Show All Ports", theme: theme) { self.setRange("All") } }
                    }
                } else {
                    List(shown, searchable: true) { listener in self.row(listener) }
                }
            }
        }
    }

    func row(_ listener: Listener) -> Row {
        let address = listener.isLocalOnly || listener.address == "all interfaces" ? "" : " · \(listener.address)"
        var row = Row(":\(listener.port)", subtitle: "\(listener.process) · pid \(listener.pid)\(address)", symbol: listener.isLocalOnly ? "lock.fill" : "network", key: listener.id)
        if !listener.isLocalOnly { row = row.badge("LAN", role: .warning) }
        return row
            .action("Open in Browser") { Stackbar.open("http://localhost:\(listener.port)") }
            .action("Stop Process", shortcut: "cmd+.", role: .critical) {
                guard self.armedNow == "stop:\(listener.id)" else {
                    let prompt = "Press Stop Process again within 10 s to stop \(listener.process) (pid \(listener.pid))"
                    self.arm("stop:\(listener.id)")
                    self.notice = prompt
                    self.noticeOK = false
                    Stackbar.hud(prompt)
                    return
                }
                self.armed = nil
                _ = try await self.stop(listener, force: false)
            }
            .action("Force Quit Process", shortcut: "cmd+shift+.", role: .critical) {
                guard self.armedNow == "kill:\(listener.id)" else {
                    let prompt = "Press Force Quit Process again within 10 s to force quit \(listener.process) (pid \(listener.pid))"
                    self.arm("kill:\(listener.id)")
                    self.notice = prompt
                    self.noticeOK = false
                    Stackbar.hud(prompt)
                    return
                }
                self.armed = nil
                _ = try await self.stop(listener, force: true)
            }
            .action("Copy PID", shortcut: "cmd+shift+c") { Stackbar.copy("\(listener.pid)") }
    }

    var settings: ViewContent {
        Section("Show") {
            Picker("Show ports", options: Self.ranges, selection: range, style: .segmented) { self.setRange($0) }
        }
        Section("About") {
            Text("Ports lists TCP ports that processes you can see are listening on. Stopping one sends it SIGTERM, so it can clean up; Force Quit sends SIGKILL. A process owned by another user (like a system service) can't be stopped from here.").style(.caption)
        }
    }

    // MARK: Commands

    var commands: [Command] {
        // Shows what holds the port and stops each holder only on Return, so
        // the palette never ends a process the user hasn't seen.
        Command("kill-port", title: "Kill Port", subtitle: "Stop whatever is listening on a port", symbol: "xmark.octagon", keywords: ["port", "kill", "lsof", "free"])
            .argument("port", placeholder: "3000")
            .argument("signal", required: false, default: "TERM", options: ["TERM", "KILL"])
            .view(search: { _ in
                // A "Press again" from the panel doesn't belong in this view.
                self.notice = nil
                await self.loadIfStale()
            }) { invocation in
                let force = invocation["signal"] == "KILL"
                if let notice = self.notice { Banner(notice, symbol: self.noticeOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", theme: self.noticeOK ? .success : .warning) }
                if let problem = self.problem {
                    ContentUnavailableView("Can't list ports", symbol: "exclamationmark.triangle", message: problem)
                } else if let port = Self.port(invocation["port"]) {
                    let holders = Dictionary(grouping: self.listeners.filter { $0.port == port }, by: \.pid).values.compactMap(\.first).sorted { $0.pid < $1.pid }
                    if holders.isEmpty {
                        ContentUnavailableView("Nothing is listening on \(port)", symbol: "checkmark.circle")
                    } else {
                        List(holders) { holder in
                            Row("\(force ? "Force quit" : "Stop") \(holder.process) on :\(port)", subtitle: "pid \(holder.pid) · Return to confirm", symbol: "xmark.octagon", key: "confirm-\(holder.pid)")
                                .action(force ? "Force Quit" : "Stop", role: .critical) { _ = try await self.stop(holder, force: force) }
                        }
                    }
                } else {
                    ContentUnavailableView("Give a port number, like 3000", symbol: "number")
                }
            }
        // Typing a port number (3000 or :3000) at the palette's root shows
        // what holds it; other text never reaches the plugin.
        Command("port", title: "Find Port", symbol: "network", keywords: ["port"])
            .view(search: { _ in await self.loadIfStale() }) { invocation in
                List(Self.matching(self.listeners, invocation.text)) { listener in self.row(listener) }
            }
            .rootSearch(section: "Ports", matching: #":?\d{2,5}"#)
            .stackbarOnly()
        Command("ports", title: "Listening Ports", symbol: "network", keywords: ["port", "lsof", "listen", "server"])
            .view(search: { _ in await self.loadIfStale() }) { _ in
                if let problem = self.problem {
                    ContentUnavailableView("Can't list ports", symbol: "exclamationmark.triangle", message: problem)
                } else {
                    List(self.shown, searchable: true) { listener in self.row(listener) }
                }
            }
    }

    /// The port a typed argument names: `3000` or `:3000`.
    static func port(_ text: String?) -> Int? {
        Int((text ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ": "))).flatMap { (1...65535).contains($0) ? $0 : nil }
    }

    /// Listeners whose port starts with the typed digits, exact first.
    static func matching(_ listeners: [Listener], _ text: String) -> [Listener] {
        let digits = text.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        guard !digits.isEmpty else { return [] }
        return listeners.filter { String($0.port).hasPrefix(digits) }
            .sorted { (String($0.port) == digits ? 0 : 1, $0.port) < (String($1.port) == digits ? 0 : 1, $1.port) }
    }

    var tools: [AgentTool] {
        AgentTool("listening", description: "TCP ports being listened on, as port, process, pid and address") { _ in
            await self.load()
            if let problem = self.problem { return problem }
            return self.listeners.map { "\($0.port)\t\($0.process)\t\($0.pid)\t\($0.address)" }.joined(separator: "\n")
        }
    }
}
