import StackbarKit
import Foundation

/// What is listening on which port, and a way to stop it.
///
/// "Kill Port 3000" from the palette ends whatever holds the port that a dev
/// server forgot to let go of. The panel lists every listening TCP port with
/// its process, from `lsof`, run through Stackbar every 30 seconds while the
/// panel is open. Stopping sends SIGTERM, and SIGKILL only when you ask.
@main
final class Ports: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.ports",
        name: "Ports",
        version: "1.0.0",
        summary: "Which process is listening on which port, and a way to stop it.",
        surfaces: [.panel, .settings],
        triggers: [.launch, .every(.seconds(30))],
        capabilities: [.run(commands: ["lsof", "kill"])],
        minimumStackbar: "0.11.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Developer/Ports"
    )

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

    @Stored("hideSystem") var hideSystem = true
    @Stored("minimumPort") var minimumPort = 1024

    var shown: [Listener] {
        listeners.filter { $0.port >= (hideSystem ? minimumPort : 0) }
    }

    func refresh() async throws {
        await load()
    }

    func load() async {
        do {
            // -F prints one field a line: p (pid), c (command), L (login), n (name).
            let result = try await Stackbar.run("lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-FpcLn"], timeout: .seconds(20))
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
        let message = (listeners.contains { $0.pid == listener.pid } ? "Asked \(listener.process) to stop; it is still listening" : "Stopped \(listener.process) on port \(listener.port)")
        notice = message
        return message
    }

    // MARK: Surfaces

    var panel: ViewContent {
        if let problem {
            ContentUnavailableView("Can't list ports", symbol: "exclamationmark.triangle", message: problem)
        } else if !loaded {
            ContentUnavailableView("Loading…", symbol: "network")
        } else if shown.isEmpty {
            ContentUnavailableView("Nothing is listening", symbol: "network", message: hideSystem ? "Ports under \(minimumPort) are hidden in Settings." : nil)
        } else {
            List(shown, searchable: true) { listener in self.row(listener) }
            if let notice { Text(notice).style(.caption) }
        }
    }

    func row(_ listener: Listener) -> Row {
        Row(":\(listener.port)", subtitle: "\(listener.process) · pid \(listener.pid) · \(listener.address)", symbol: "network", key: listener.id)
            .badge(listener.isLocalOnly ? "local" : "open", role: listener.isLocalOnly ? .secondary : .warning)
            .action("Open in Browser") { Stackbar.open("http://localhost:\(listener.port)") }
            .action("Stop Process", shortcut: "cmd+.", role: .critical) { _ = try await self.stop(listener, force: false) }
            .action("Force Quit Process", shortcut: "cmd+shift+.", role: .critical) { _ = try await self.stop(listener, force: true) }
            .action("Copy PID", shortcut: "cmd+shift+c") { Stackbar.copy("\(listener.pid)") }
    }

    var settings: ViewContent {
        Section("Show") {
            Toggle("Hide ports under \(minimumPort)", isOn: hideSystem) { self.hideSystem = $0 }
            Picker("Lowest port shown", options: ["1", "1024", "3000"], selection: "\(minimumPort)") { self.minimumPort = Int($0) ?? 1024 }
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
