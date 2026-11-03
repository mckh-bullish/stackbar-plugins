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
        version: "1.3.0",
        summary: "Which process is listening on which port, and a way to stop it.",
        surfaces: [.panel, .settings],
        triggers: [.launch, .every(.seconds(30))],
        capabilities: [.run(commands: ["lsof", "kill"])],
        minimumStackbar: "0.17.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Developer/Ports",
        accent: .teal,
        symbol: "point.3.connected.trianglepath.dotted"
    )

    // MARK: Previews

    static let previews: [PreviewScene<Ports>] = [
        PreviewScene("hero", "What's listening, and one click to stop it") { plugin in
            plugin.listeners = [
                Listener(port: 3000, address: "127.0.0.1", pid: 48211, process: "node", user: "you"),
                Listener(port: 5173, address: "[::1]", pid: 48390, process: "vite", user: "you"),
                Listener(port: 5432, address: "127.0.0.1", pid: 712, process: "postgres", user: "you"),
                Listener(port: 6379, address: "127.0.0.1", pid: 733, process: "redis-server", user: "you"),
                Listener(port: 8080, address: "*", pid: 51022, process: "java", user: "you"),
                Listener(port: 9229, address: "127.0.0.1", pid: 48211, process: "node", user: "you"),
                Listener(port: 11434, address: "127.0.0.1", pid: 1880, process: "ollama", user: "you"),
            ]
            plugin.loaded = true
        },
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
    var problem: String?
    var notice: String?
    var noticeOK = true

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

    func refresh() async throws {
        notice = nil
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
                loaded = true
                return
            }
            listeners = Self.parse(result.text)
            problem = nil
        } catch {
            problem = "\(error)"
        }
        loaded = true
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
                if !found.contains(where: { $0.pid == pid && $0.port == port }) { found.append(listener) }
            default: break
            }
        }
        return found.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    func stop(_ listener: Listener, force: Bool) async throws -> String {
        let result = try await Stackbar.run("kill", [force ? "-KILL" : "-TERM", "\(listener.pid)"], timeout: .seconds(10))
        guard result.succeeded else {
            let reason = result.errorText.contains("not permitted") ? "it belongs to another user" : result.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HostError("Couldn't stop \(listener.process) (\(listener.pid)): \(reason)")
        }
        try? await Task.sleep(for: .milliseconds(400))
        await load()
        let stillThere = listeners.contains { $0.pid == listener.pid }
        let message = stillThere ? "Asked \(listener.process) to stop; it is still listening" : "Stopped \(listener.process) on :\(listener.port)"
        notice = message
        noticeOK = !stillThere
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
            .action("Stop Process", shortcut: "cmd+.", role: .critical) { _ = try await self.stop(listener, force: false) }
            .action("Force Quit Process", shortcut: "cmd+shift+.", role: .critical) { _ = try await self.stop(listener, force: true) }
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
        Command("kill-port", title: "Kill Port", subtitle: "Stop whatever is listening on a port", symbol: "xmark.octagon", keywords: ["port", "kill", "lsof", "free"]) { invocation in
            guard let port = Int(invocation["port"] ?? "") else { return .failure("Give a port number, like 3000") }
            await self.load()
            let holders = self.listeners.filter { $0.port == port }
            guard !holders.isEmpty else { return .message("Nothing is listening on \(port)") }
            let force = invocation["signal"] == "KILL"
            var messages: [String] = []
            for holder in Dictionary(grouping: holders, by: \.pid).values.compactMap(\.first) {
                messages.append(try await self.stop(holder, force: force))
            }
            return .message(messages.joined(separator: "; "))
        }
        .argument("port", placeholder: "3000")
        .argument("signal", required: false, default: "TERM", options: ["TERM", "KILL"])
        Command("ports", title: "Listening Ports", symbol: "network", keywords: ["port", "lsof", "listen", "server"])
            .view(search: { _ in await self.load() }) { _ in
                if let problem = self.problem {
                    ContentUnavailableView("Can't list ports", symbol: "exclamationmark.triangle", message: problem)
                } else {
                    List(self.shown, searchable: true) { listener in self.row(listener) }
                }
            }
    }

    var tools: [AgentTool] {
        AgentTool("listening", description: "TCP ports being listened on, as port, process, pid and address") { _ in
            await self.load()
            if let problem = self.problem { return problem }
            return self.listeners.map { "\($0.port)\t\($0.process)\t\($0.pid)\t\($0.address)" }.joined(separator: "\n")
        }
    }
}
