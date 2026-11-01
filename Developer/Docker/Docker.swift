import StackbarKit
import Foundation

/// Your Docker containers: what is running, with start, stop, restart, logs
/// and cleanup a click away.
///
/// It runs the `docker` CLI through Stackbar (Docker Desktop, OrbStack,
/// Colima and Rancher Desktop all install one), every 15 seconds while a
/// container runs and every minute otherwise. Nothing runs in a shell.
@main
final class Docker: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.docker",
        name: "Docker",
        version: "1.2.0",
        summary: "Your containers, with start, stop, restart and logs a click away.",
        surfaces: [.menuBar, .panel, .widget, .settings],
        triggers: [.launch, .every(.seconds(15)), .wake],
        capabilities: [.run(commands: ["docker"])],
        minimumStackbar: "0.14.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Developer/Docker"
    )

    /// One line of `docker ps --format '{{json .}}'`.
    struct Container: Decodable, Equatable, Identifiable {
        let id: String
        let names: String
        let image: String
        let state: String
        let status: String
        let ports: String?
        let labels: String?

        enum CodingKeys: String, CodingKey {
            case id = "ID", names = "Names", image = "Image", state = "State", status = "Status", ports = "Ports", labels = "Labels"
        }

        var name: String { names.split(separator: ",").first.map(String.init) ?? names }
        var isRunning: Bool { state == "running" || state == "restarting" }
        var isUnhealthy: Bool { status.contains("(unhealthy)") }
        /// `nginx:latest`, without Docker Hub's `docker.io/library/`.
        var shortImage: String {
            image.hasPrefix("docker.io/library/") ? String(image.dropFirst("docker.io/library/".count)) : image
        }
        /// The compose project, from its label.
        var project: String? {
            labels?.split(separator: ",").first { $0.hasPrefix("com.docker.compose.project=") }
                .map { String($0.dropFirst("com.docker.compose.project=".count)) }
        }
        /// `0.0.0.0:8080->80/tcp` becomes `http://localhost:8080`.
        var localURLs: [String] {
            (ports ?? "").split(separator: ",").compactMap { mapping -> String? in
                let part = mapping.trimmingCharacters(in: .whitespaces)
                guard let arrow = part.range(of: "->"), part[arrow.upperBound...].hasSuffix("/tcp") else { return nil }
                guard let port = part[..<arrow.lowerBound].split(separator: ":").last, Int(port) != nil else { return nil }
                return "http://localhost:\(port)"
            }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        }
    }

    var containers: [Container] = []
    var loaded = false
    var problem: String?
    var busy: Set<String> = []
    /// What is running now, like "Restarting api…".
    var busyText: String?
    var logs: [String: String] = [:]
    var lastSlowCheck = Date.distantPast

    @Stored("showStopped") var showStopped = true
    @Stored("groupByProject") var groupByProject = true

    var running: [Container] { containers.filter(\.isRunning) }
    var shown: [Container] { showStopped ? containers : running }

    func refresh() async throws {
        // Every 15 s while something runs; once a minute otherwise.
        if running.isEmpty, loaded, problem == nil, Date().timeIntervalSince(lastSlowCheck) < 55 { return }
        await load()
    }

    func load() async {
        lastSlowCheck = Date()
        do {
            let result = try await Stackbar.run("docker", ["ps", "--all", "--no-trunc", "--format", "{{json .}}"], timeout: .seconds(20))
            guard result.succeeded else {
                // The last list stays on screen under a banner.
                problem = Self.explain(result)
                loaded = true
                return
            }
            let decoder = JSONDecoder()
            containers = result.text.split(separator: "\n").compactMap { try? decoder.decode(Container.self, from: Data($0.utf8)) }
                .sorted { ($0.isRunning ? 0 : 1, $0.name) < ($1.isRunning ? 0 : 1, $1.name) }
            problem = nil
        } catch {
            problem = "\(error)".contains("not installed")
                ? "The docker command isn't installed. Install Docker Desktop, OrbStack or Colima, then refresh."
                : "\(error)"
        }
        loaded = true
    }

    static func explain(_ result: RunResult) -> String {
        let text = result.errorText
        if text.contains("Cannot connect to the Docker daemon") || text.contains("docker daemon running") || text.contains("connect: no such file") {
            return "Docker isn't running. Start Docker Desktop, OrbStack or Colima."
        }
        if result.timedOut { return "docker took too long to answer" }
        return "docker failed (\(result.status)): " + (text.split(separator: "\n").first.map(String.init) ?? "")
    }

    func act(_ verb: String, _ container: Container) async throws {
        busy.insert(container.id)
        busyText = "\(["stop": "Stopping", "start": "Starting", "restart": "Restarting", "rm": "Removing"][verb] ?? verb) \(container.name)…"
        defer {
            busy.remove(container.id)
            busyText = nil
        }
        let result = try await Stackbar.run("docker", [verb, container.id], timeout: .seconds(90))
        guard result.succeeded else { throw HostError("\(verb) \(container.name): " + Self.explain(result)) }
        await load()
    }

    func loadLogs(_ id: String, lines: Int = 200) async {
        do {
            let result = try await Stackbar.run("docker", ["logs", "--tail", "\(lines)", "--timestamps", id], timeout: .seconds(20))
            // docker logs writes the container's stderr to stderr.
            let text = [result.text, result.errorText].filter { !$0.isEmpty }.joined(separator: "\n")
            logs[id] = result.succeeded ? (text.isEmpty ? "(no output)" : text) : Self.explain(result)
        } catch {
            logs[id] = "\(error)"
        }
    }

    // MARK: Surfaces

    let theme = Theme.cyan

    var projects: Int { Set(containers.compactMap(\.project)).count }

    var menuBar: ViewContent {
        if problem != nil, loaded {
            Label("", symbol: "shippingbox").role(.warning)
        } else if running.isEmpty {
            Label("", symbol: "shippingbox").role(.secondary)
        } else {
            Label("\(running.count)", symbol: "shippingbox.fill")
        }
    }

    var panel: ViewContent {
        VStack(spacing: Space.m) {
            if !loaded {
                PanelHeader("Containers", subtitle: "Checking…", symbol: "shippingbox.fill", theme: theme)
            } else if let problem, containers.isEmpty {
                let missing = problem.contains("isn't installed")
                EmptyState(missing ? "Docker isn't installed" : "Docker isn't running", symbol: missing ? "shippingbox" : "exclamationmark.triangle.fill",
                           message: problem.hasPrefix("Docker isn't running. ") ? String(problem.dropFirst("Docker isn't running. ".count)) : problem, theme: missing ? theme : .critical) {
                    ActionButton("Try Again", symbol: "arrow.clockwise", theme: theme) { await self.load() }
                }
                if missing { Link("Get OrbStack", url: "https://orbstack.dev") }
            } else {
                PanelHeader(running.isEmpty ? "Nothing running" : "\(running.count) running", subtitle: summary, symbol: "shippingbox.fill", theme: theme) {
                    Picker("Show", options: ["Running", "All"], selection: showStopped ? "All" : "Running", style: .segmented) { self.showStopped = $0 == "All" }
                        .frame(width: 124)
                }
                if !containers.isEmpty {
                    let unhealthy = containers.filter(\.isUnhealthy).count
                    HeroCard(theme: theme, look: .glow) {
                        HStack(spacing: Space.l) {
                            HeroStat("Running", value: "\(running.count)", theme: theme, live: !running.isEmpty)
                            HeroStat("Stopped", value: "\(containers.count - running.count)", theme: .neutral, symbol: "stop.fill")
                            if unhealthy > 0 {
                                HeroStat("Unhealthy", value: "\(unhealthy)", theme: .critical, symbol: "cross.case.fill")
                            } else if projects > 0 {
                                HeroStat("Projects", value: "\(projects)", theme: theme, symbol: "square.stack.3d.up.fill")
                            }
                            Spacer()
                        }
                    }
                }
                if let problem { Banner(problem) }
                if let busyText { Banner(busyText, symbol: "arrow.triangle.2.circlepath", theme: .info) }
                if containers.isEmpty {
                    EmptyState("No containers yet", symbol: "shippingbox", message: "Containers you create or start with Compose show up here.", theme: theme)
                } else if shown.isEmpty {
                    EmptyState("Nothing running", symbol: "moon.zzz", message: "\(containers.count) stopped.", theme: theme) {
                        ActionButton("Show All", theme: theme) { self.showStopped = true }
                    }
                } else if groupByProject {
                    let groups = Dictionary(grouping: shown) { $0.project ?? "" }
                    VStack(spacing: Space.s) {
                        ForEach(groups.keys.sorted { ($0.isEmpty ? 1 : 0, $0) < ($1.isEmpty ? 1 : 0, $1) }) { project in
                            let members = groups[project] ?? []
                            let up = containers.filter { ($0.project ?? "") == project && $0.isRunning }.count
                            let all = containers.filter { ($0.project ?? "") == project }.count
                            Section(project.isEmpty ? (groups.count > 1 ? "Other containers" : "Containers") : "\(project) · \(up)/\(all) running") {
                                ForEach(members) { container in self.row(container) }
                            }
                        }
                    }
                } else {
                    List(shown, searchable: shown.count > 8) { container in self.row(container) }
                }
            }
        }
    }

    var summary: String {
        let count = "\(containers.count) container\(containers.count == 1 ? "" : "s")"
        return projects > 0 ? "\(count) · \(projects) project\(projects == 1 ? "" : "s")" : count
    }

    var widget: ViewContent {
        if problem != nil, containers.isEmpty {
            VStack(alignment: .center, spacing: Space.xs) {
                IconTile("shippingbox", theme: .neutral, size: 32)
                Text("Docker isn't running").role(.secondary).typography(.caption)
            }
            .frame(fillWidth: true, fillHeight: true)
        } else {
            VStack(spacing: Space.s) {
                HStack(spacing: Space.s) {
                    StatTile("Running", value: "\(running.count)", symbol: "play.fill", theme: theme, emphasized: !running.isEmpty)
                    StatTile("Stopped", value: "\(containers.count - running.count)", symbol: "stop.fill")
                    let unhealthy = containers.filter(\.isUnhealthy).count
                    StatTile("Unhealthy", value: "\(unhealthy)", symbol: "cross.case.fill", theme: unhealthy > 0 ? .critical : .neutral, emphasized: unhealthy > 0)
                }
                ForEach(running.prefix(2)) { container in
                    HStack(spacing: Space.xs + 2) {
                        StatusDot(container.isUnhealthy ? .critical : .success, size: 6)
                        Text(container.name).typography(.caption)
                        Spacer()
                        Text(container.status).role(.secondary).typography(.caption)
                    }
                }
            }
        }
    }

    func row(_ container: Container) -> Row {
        var row = Row(container.name, subtitle: "\(container.shortImage) · \(container.status.replacingOccurrences(of: " (unhealthy)", with: "").replacingOccurrences(of: " (healthy)", with: ""))", symbol: container.isRunning ? "circle.fill" : "circle", key: container.id)
        if busy.contains(container.id) {
            row = row.badge("…")
        } else if container.isUnhealthy {
            row = row.badge("unhealthy", role: .critical)
        } else if container.state == "restarting" {
            row = row.badge("restarting", role: .warning)
        } else if container.state == "paused" {
            row = row.badge("paused")
        }
        if container.isRunning, let url = container.localURLs.first {
            row = row.badge(String(url.dropFirst("http://".count)))
        }
        if let url = container.localURLs.first {
            row = row.action("Open \(url.dropFirst("http://".count))") { Stackbar.open(url) }
        }
        if container.isRunning {
            row = row
                .action("Stop", shortcut: "cmd+.") { try await self.act("stop", container) }
                .action("Restart", shortcut: "cmd+r") { try await self.act("restart", container) }
        } else {
            row = row.action("Start", shortcut: "cmd+return") { try await self.act("start", container) }
        }
        return row
            .navigate("Logs", to: "logs", arguments: ["container": container.id], shortcut: "cmd+l")
            .action("Copy ID", shortcut: "cmd+shift+c") { Stackbar.copy(String(container.id.prefix(12))) }
            .action("Copy Exec Command") { Stackbar.copy("docker exec -it \(container.name) sh") }
            .action("Remove", shortcut: "ctrl+x", role: .critical) {
                guard !container.isRunning else { throw HostError("Stop \(container.name) before removing it") }
                try await self.act("rm", container)
            }
    }

    var settings: ViewContent {
        Section("Show") {
            Toggle("Group by Compose project", isOn: groupByProject) { self.groupByProject = $0 }
        }
        Section("Cleanup") {
            Button("Remove Stopped Containers", symbol: "trash", role: .critical) { _ = try await self.prune() }
            Text("Runs docker container prune. Images and volumes are left alone.").style(.caption)
        }
    }

    func prune() async throws -> String {
        let result = try await Stackbar.run("docker", ["container", "prune", "--force"], timeout: .seconds(120))
        guard result.succeeded else { throw HostError(Self.explain(result)) }
        await load()
        return result.text.split(separator: "\n").last.map(String.init) ?? "Removed stopped containers"
    }

    // MARK: Commands

    func find(_ text: String?) -> Container? {
        guard let text, !text.isEmpty else { return nil }
        return containers.first { $0.id.hasPrefix(text) || $0.name == text } ?? containers.first { $0.name.localizedCaseInsensitiveContains(text) }
    }

    var commands: [Command] {
        Command("containers", title: "Docker Containers", symbol: "shippingbox", keywords: ["docker", "container", "compose"])
            .view(search: { _ in await self.load() }) { _ in
                if let problem = self.problem {
                    ContentUnavailableView("Docker isn't available", symbol: "shippingbox", message: problem)
                } else {
                    List(self.shown, searchable: true) { container in self.row(container) }
                }
            }
        Command("logs", title: "Docker Logs", symbol: "text.alignleft", keywords: ["docker"])
            .argument("container", placeholder: "Container")
            .view(search: { invocation in
                if self.containers.isEmpty { await self.load() }
                if let container = self.find(invocation["container"]) { await self.loadLogs(container.id) }
            }) { invocation in
                if let container = self.find(invocation["container"]) {
                    HStack {
                        Button("Refresh", symbol: "arrow.clockwise") { await self.loadLogs(container.id) }
                        Button("Copy", symbol: "doc.on.doc") { Stackbar.copy(self.logs[container.id] ?? "") }
                    }
                    Section("\(container.name) · last 200 lines") {
                        Text(String((self.logs[container.id] ?? "Loading…").suffix(20_000))).style(.monospaced)
                    }
                } else {
                    ContentUnavailableView("No container \(invocation["container"] ?? "")", symbol: "shippingbox")
                }
            }
            .stackbarOnly()
        Command("prune", title: "Remove Stopped Docker Containers", symbol: "trash", keywords: ["docker", "prune", "clean"]) { _ in
            .message(try await self.prune())
        }
        .stackbarOnly()
    }

    var tools: [AgentTool] {
        AgentTool("containers", description: "Docker containers with name, image, state and status") { _ in
            if self.containers.isEmpty { await self.load() }
            if let problem = self.problem { return problem }
            return self.containers.map { "\($0.name)\t\($0.image)\t\($0.state)\t\($0.status)" }.joined(separator: "\n")
        }
    }
}
