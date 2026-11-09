import StackbarKit
import Foundation

/// Your Docker containers: what is running and what each one costs in CPU
/// and memory, with start, stop, restart, logs, whole Compose projects and
/// cleanup a click away.
///
/// It runs the `docker` CLI through Stackbar (Docker Desktop, OrbStack,
/// Colima and Rancher Desktop all install one), every 15 seconds while a
/// container runs and every minute otherwise. Nothing runs in a shell.
/// When a container crashes, turns unhealthy or keeps restarting, it says
/// so with a notification and a red menu bar.
@main
final class Docker: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.docker",
        name: "Docker",
        version: "1.10.0",
        summary: "Your containers with live CPU and memory, Compose projects, and start, stop, restart and logs a click away.",
        surfaces: [.menuBar, .panel, .window, .widget, .settings],
        triggers: [.launch, .every(.seconds(15)), .wake],
        capabilities: [.run(commands: ["docker"]), .terminal],
        minimumStackbar: "0.35.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Developer/Docker",
        accent: .cyan,
        symbol: "shippingbox.fill"
    )

    // MARK: Previews

    static let previews: [PreviewScene<Docker>] = [
        PreviewScene("hero", "Every container, grouped by Compose project") { plugin in
            plugin.containers = samples
            plugin.stats = sampleStats
            plugin.loaded = true
        },
        PreviewScene("trouble", "Catch the container that keeps crashing") { plugin in
            plugin.containers = samples
            plugin.crashedIDs = ["c6"]
            plugin.loaded = true
        },
        PreviewScene("logs", "Follow a container's logs beside your editor", surface: .window) { plugin in
            plugin.containers = samples
            plugin.stats = sampleStats
            plugin.loaded = true
            plugin.watched = "c2"
            plugin.logs["c2"] = sampleLogs
        },
        PreviewScene("widget", "Your stack's health on the desktop", surface: .widget) { plugin in
            plugin.containers = samples
            plugin.loaded = true
        },
    ]

    static let sampleLogs = """
    2026-11-07T10:42:01.123Z GET /api/orders 200 12ms
    2026-11-07T10:42:01.980Z POST /api/cart 201 31ms
    2026-11-07T10:42:02.415Z GET /api/products?page=2 200 9ms
    2026-11-07T10:42:03.007Z WARN slow query 840ms: select * from orders
    2026-11-07T10:42:03.512Z GET /healthz 200 1ms
    2026-11-07T10:42:04.260Z POST /api/checkout 500 118ms
    2026-11-07T10:42:04.261Z ERROR payment provider timeout
    2026-11-07T10:42:05.044Z GET /api/orders/5810 200 14ms
    2026-11-07T10:42:06.390Z GET /api/session 304 3ms
    2026-11-07T10:42:07.118Z POST /api/cart 201 27ms
    """

    static let samples: [Container] = {
        func container(_ id: String, _ name: String, _ image: String, _ state: String, _ status: String, _ ports: String?, project: String?) -> Container {
            Container(id: id, names: name, image: image, state: state, status: status, ports: ports,
                      labels: project.map { "com.docker.compose.project=\($0),com.docker.compose.service=\(name)" })
        }
        return [
            container("c1", "shop-web", "node:22-alpine", "running", "Up 3 hours", "0.0.0.0:3000->3000/tcp", project: "shop"),
            container("c2", "shop-api", "shop/api:dev", "running", "Up 3 hours (healthy)", "0.0.0.0:8080->8080/tcp", project: "shop"),
            container("c3", "shop-db", "postgres:17", "running", "Up 3 hours (healthy)", "0.0.0.0:5432->5432/tcp", project: "shop"),
            container("c4", "shop-cache", "redis:7", "running", "Up 3 hours", "6379/tcp", project: "shop"),
            container("c5", "blog-site", "ghost:5", "running", "Up 25 minutes", "0.0.0.0:2368->2368/tcp", project: "blog"),
            container("c6", "blog-worker", "blog/worker:latest", "exited", "Exited (1) 4 minutes ago", nil, project: "blog"),
            container("c7", "minio", "minio/minio:latest", "running", "Up 2 days", "0.0.0.0:9000-9001->9000-9001/tcp", project: nil),
            container("c8", "mailpit", "axllent/mailpit", "exited", "Exited (0) 2 hours ago", nil, project: nil),
        ]
    }()

    static let sampleStats: [String: Stats] = [
        "c1": Stats(cpu: 3.4, memory: 182e6, memoryLimit: 8e9),
        "c2": Stats(cpu: 12.8, memory: 412e6, memoryLimit: 8e9),
        "c3": Stats(cpu: 1.9, memory: 96e6, memoryLimit: 8e9),
        "c4": Stats(cpu: 0.4, memory: 11e6, memoryLimit: 8e9),
        "c5": Stats(cpu: 0.8, memory: 140e6, memoryLimit: 8e9),
        "c7": Stats(cpu: 0.2, memory: 88e6, memoryLimit: 8e9),
    ]

    /// One container's share of the machine, from `docker stats`.
    struct Stats: Equatable {
        var cpu: Double
        var memory: Double
        var memoryLimit: Double
    }

    /// One line of `docker stats --no-stream --format '{{json .}}'`.
    struct StatsLine: Decodable {
        let id: String
        let cpu: String
        let memory: String
        enum CodingKeys: String, CodingKey { case id = "ID", cpu = "CPUPerc", memory = "MemUsage" }
    }

    /// `12.5%` → 12.5; `1.2GiB / 7.6GiB` → bytes used and the limit.
    static func parse(_ line: StatsLine) -> Stats? {
        guard let cpu = Double(line.cpu.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) else { return nil }
        let parts = line.memory.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        return Stats(cpu: cpu, memory: parts.first.flatMap(bytes) ?? 0, memoryLimit: parts.count > 1 ? bytes(parts[1]) ?? 0 : 0)
    }

    /// Docker's sizes: `512KiB`, `1.2GiB`, `3.4MB`, `0B`.
    static func bytes(_ text: String) -> Double? {
        let units: [(String, Double)] = [("TiB", pow(1024, 4)), ("GiB", pow(1024, 3)), ("MiB", pow(1024, 2)), ("KiB", 1024),
                                         ("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (unit, scale) in units where text.hasSuffix(unit) {
            return Double(text.dropLast(unit.count).trimmingCharacters(in: .whitespaces)).map { $0 * scale }
        }
        return Double(text)
    }

    static func size(_ bytes: Double) -> String {
        bytes >= 1e9 ? String(format: "%.1f GB", bytes / 1e9) : String(format: "%.0f MB", max(1, bytes / 1e6))
    }

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
        /// The code in `Exited (1) 5 minutes ago`.
        var exitCode: Int? {
            guard state == "exited", let open = status.firstIndex(of: "("), let close = status.firstIndex(of: ")"), open < close else { return nil }
            return Int(status[status.index(after: open)..<close])
        }
        /// Exited on its own with an error. 0 is a clean exit, and 130, 137
        /// and 143 are what `docker stop` and Ctrl-C leave.
        var crashed: Bool { exitCode.map { ![0, 130, 137, 143].contains($0) } ?? false }
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
    /// CPU and memory of each running container, by id.
    var stats: [String: Stats] = [:]
    var loaded = false
    var problem: String?
    var busy: Set<String> = []
    /// What is running now, like "Restarting api…".
    var busyText: String?
    var logs: [String: String] = [:]
    /// The container whose logs the window shows.
    var watched: String?
    /// Until when the log tail is refreshed on its own. Opening the logs or
    /// pressing Refresh extends it; after that the logs wait for a click.
    var followLogsUntil = Date.distantPast
    static let followLogsFor: TimeInterval = 120
    var lastSlowCheck = Date.distantPast

    @Stored("showStopped") var showStopped = true
    @Stored("groupByProject") var groupByProject = true
    @Stored("notifyTrouble") var notifyTrouble = true
    /// Containers that crashed since they last ran, by id, so the menu bar
    /// stays red until they are started again or removed.
    var crashedIDs: Set<String> = []
    /// Containers this plugin is stopping, so their exit isn't a crash.
    var stopping: Set<String> = []

    var running: [Container] { containers.filter(\.isRunning) }
    var prunable: [Container] { containers.filter { !$0.isRunning && $0.state != "paused" } }
    var shown: [Container] { showStopped ? containers : running }

    func refresh() async throws {
        // Every 15 s while something runs; once a minute otherwise, and also
        // while Docker is down (each failing `docker ps` is still a process).
        // A manual refresh always goes through.
        if loaded, running.isEmpty || problem != nil, Stackbar.refreshReason != .manual, Date().timeIntervalSince(lastSlowCheck) < 55 { return }
        await load()
        // The window's log tail follows along, for a couple of minutes after
        // it was asked for: the plugin can't tell that the window closed.
        if let watched, Date() < followLogsUntil, containers.contains(where: { $0.id == watched }) { await loadLogs(watched) }
    }

    /// For views that ask on every keystroke (and filter the list locally): a
    /// list read in the last few seconds is as good as a new one.
    func loadIfStale() async {
        if !loaded || Date().timeIntervalSince(lastSlowCheck) > 5 { await load() }
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
            let fresh = result.text.split(separator: "\n").compactMap { try? decoder.decode(Container.self, from: Data($0.utf8)) }
                .sorted { ($0.isRunning ? 0 : 1, $0.name) < ($1.isRunning ? 0 : 1, $1.name) }
            if loaded, problem == nil { noticeTrouble(from: containers, to: fresh) }
            containers = fresh
            crashedIDs = crashedIDs.filter { id in fresh.contains { $0.id == id && !$0.isRunning } }
            problem = nil
            await loadStats()
        } catch {
            problem = "\(error)".contains("not installed")
                ? "The docker command isn't installed. Install Docker Desktop, OrbStack or Colima, then refresh."
                : "\(error)"
        }
        loaded = true
    }

    /// One snapshot of every running container's CPU and memory. Takes a
    /// second or two, so only while something runs.
    func loadStats() async {
        guard !running.isEmpty else { stats = [:]; return }
        guard let result = try? await Stackbar.run("docker", ["stats", "--no-stream", "--no-trunc", "--format", "{{json .}}"], timeout: .seconds(20)), result.succeeded else {
            // Keep the numbers of containers still running; the rest have stopped.
            stats = stats.filter { id, _ in self.running.contains { $0.id == id } }
            return
        }
        let decoder = JSONDecoder()
        var fresh: [String: Stats] = [:]
        for line in result.text.split(separator: "\n") {
            guard let parsed = try? decoder.decode(StatsLine.self, from: Data(line.utf8)), let numbers = Self.parse(parsed) else { continue }
            // stats ids can be the short form; match them to the full ones.
            if let container = containers.first(where: { $0.id.hasPrefix(parsed.id) || parsed.id.hasPrefix($0.id) }) { fresh[container.id] = numbers }
        }
        stats = fresh
    }

    var totalCPU: Double { stats.values.reduce(0) { $0 + $1.cpu } }
    var totalMemory: Double { stats.values.reduce(0) { $0 + $1.memory } }

    /// Compose projects, by name, with their containers.
    var composeProjects: [(name: String, containers: [Container])] {
        Dictionary(grouping: containers.filter { $0.project != nil }) { $0.project ?? "" }
            .map { (name: $0.key, containers: $0.value) }
            .sorted { $0.name < $1.name }
    }

    /// `docker compose -p <project> stop|start|restart`: Compose finds the
    /// project from its containers' labels, so no compose file is needed.
    func compose(_ verb: String, project: String) async throws {
        let members = containers.filter { $0.project == project }
        busyText = "\(["stop": "Stopping", "start": "Starting", "restart": "Restarting"][verb] ?? verb) \(project)…"
        Stackbar.hud(busyText ?? "")
        if verb != "start" { stopping.formUnion(members.map(\.id)) }
        members.forEach { busy.insert($0.id) }
        defer {
            busyText = nil
            members.forEach { busy.remove($0.id); stopping.remove($0.id) }
        }
        let result = try await Stackbar.run("docker", ["compose", "-p", project, verb], timeout: .seconds(180))
        guard result.succeeded else { throw HostError("\(verb) \(project): " + Self.explain(result)) }
        Stackbar.hud("\(project): \(["stop": "stopped", "start": "started", "restart": "restarted"][verb] ?? verb)")
        await load()
    }

    /// The ids a confirm row showed, if each one still qualifies after a fresh
    /// read. Nil when the list has changed, and the row then does nothing.
    func stillListed(_ shown: [String], among now: () -> [Container]) async throws -> [String]? {
        await load()
        if let problem { throw HostError(problem) }
        let current = Set(now().map(\.id))
        return shown.allSatisfy(current.contains) ? shown : nil
    }

    /// Stops the given containers at once.
    func stopAll(_ ids: [String]) async throws -> String {
        guard !ids.isEmpty else { return "Nothing is running" }
        busyText = "Stopping \(ids.count) container\(ids.count == 1 ? "" : "s")…"
        Stackbar.hud(busyText ?? "")
        stopping.formUnion(ids)
        defer { busyText = nil; stopping.subtract(ids) }
        let result = try await Stackbar.run("docker", ["stop"] + ids, timeout: .seconds(180))
        await load()
        guard result.succeeded else { throw HostError(Self.explain(result)) }
        return "Stopped \(ids.count) container\(ids.count == 1 ? "" : "s")"
    }

    /// Compares two lists and speaks up about what went wrong in between:
    /// a crash, a container turning unhealthy, or one stuck restarting.
    func noticeTrouble(from old: [Container], to new: [Container]) {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var lines: [String] = []
        var ids: [String] = []
        for container in new {
            guard let was = before[container.id] else { continue }
            if was.isRunning, container.crashed, !stopping.contains(container.id) {
                crashedIDs.insert(container.id)
                lines.append("\(container.name) crashed (exit \(container.exitCode ?? 0))")
                ids.append(container.id)
            } else if container.isUnhealthy, !was.isUnhealthy {
                lines.append("\(container.name) is unhealthy")
                ids.append(container.id)
            } else if container.state == "restarting", was.state != "restarting" {
                lines.append("\(container.name) keeps restarting")
                ids.append(container.id)
            }
        }
        guard notifyTrouble, !lines.isEmpty else { return }
        if lines.count == 1 {
            Stackbar.notify(lines[0], body: "Open Docker in the menu bar for its logs.",
                            actions: [NotificationAction("Show Logs", command: "logs", arguments: ["container": ids[0]])])
        } else {
            Stackbar.notify("\(lines.count) containers need a look", body: lines.joined(separator: "\n"))
        }
    }

    /// Containers that need a look: unhealthy, restarting, or crashed.
    var troubled: [Container] {
        containers.filter { $0.isUnhealthy || $0.state == "restarting" || crashedIDs.contains($0.id) }
    }

    static func explain(_ result: RunResult) -> String {
        let text = result.errorText
        if text.contains("Cannot connect to the Docker daemon") || text.contains("docker daemon running") || text.contains("connect: no such file")
            || text.contains("failed to connect to the docker API") || text.contains("connection refused") || text.contains("Is the docker daemon running") {
            return "Docker isn't running. Start Docker Desktop, OrbStack or Colima."
        }
        if result.timedOut { return "docker took too long to answer" }
        return "docker failed (\(result.status)): " + (text.split(separator: "\n").first.map(String.init) ?? "")
    }

    func act(_ verb: String, _ container: Container) async throws {
        busy.insert(container.id)
        busyText = "\(["stop": "Stopping", "start": "Starting", "restart": "Restarting", "unpause": "Resuming", "rm": "Removing"][verb] ?? verb) \(container.name)…"
        Stackbar.hud(busyText ?? "Working…")
        if verb == "stop" || verb == "restart" { stopping.insert(container.id) }
        defer {
            busy.remove(container.id)
            busyText = nil
            stopping.remove(container.id)
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
        } else if !troubled.isEmpty {
            Label("\(running.count) · \(troubled.count)!", symbol: "shippingbox.fill").role(.critical)
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
                            if !stats.isEmpty {
                                HeroStat("CPU", value: String(format: "%.0f%%", totalCPU), theme: totalCPU >= 200 ? .warning : .neutral, symbol: "cpu")
                                HeroStat("Memory", value: Self.size(totalMemory), theme: .neutral, symbol: "memorychip")
                            } else {
                                HeroStat("Stopped", value: "\(containers.count - running.count)", theme: .neutral, symbol: "stop.fill")
                            }
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
                if !troubled.isEmpty {
                    Banner(troubled.map { self.trouble($0) }.joined(separator: " · "), symbol: "exclamationmark.triangle.fill", theme: .critical)
                }
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
                                if !project.isEmpty { self.projectControls(project, up: up, all: all) }
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

    /// Start, stop and restart for a whole Compose project.
    @ViewBuilder func projectControls(_ project: String, up: Int, all: Int) -> ViewContent {
        HStack(spacing: Space.xs) {
            if up < all {
                Chip("Start all", symbol: "play.fill", theme: theme, key: "compose-start-\(project)") { try await self.compose("start", project: project) }
            }
            if up > 0 {
                Chip("Restart", symbol: "arrow.clockwise", theme: theme, key: "compose-restart-\(project)") { try await self.compose("restart", project: project) }
                Chip("Stop", symbol: "stop.fill", theme: theme, key: "compose-stop-\(project)") { try await self.compose("stop", project: project) }
            }
            Spacer()
        }
    }

    func trouble(_ container: Container) -> String {
        if crashedIDs.contains(container.id) { return "\(container.name) crashed (exit \(container.exitCode ?? 0))" }
        if container.state == "restarting" { return "\(container.name) keeps restarting" }
        return "\(container.name) is unhealthy"
    }

    var summary: String {
        let count = "\(containers.count) container\(containers.count == 1 ? "" : "s")"
        return projects > 0 ? "\(count) · \(projects) project\(projects == 1 ? "" : "s")" : count
    }

    /// The containers on the left; the one picked shows its last 200 log
    /// lines on the right, refreshed with the list while it runs.
    var window: ViewContent {
        HStack(alignment: .start, spacing: Space.m) {
            VStack(spacing: Space.s) {
                PanelHeader("Containers", subtitle: summary, symbol: "shippingbox.fill", theme: theme)
                if let problem, containers.isEmpty {
                    EmptyState("Docker isn't available", symbol: "shippingbox", message: problem, theme: .warning)
                } else if containers.isEmpty {
                    EmptyState("No containers", symbol: "shippingbox", theme: theme)
                } else {
                    List(containers, searchable: true) { container in
                        self.row(container)
                            .action("Show Logs", shortcut: "cmd+l") { await self.watch(container.id) }
                    }
                }
            }
            .frame(width: 320)
            Divider()
            VStack(spacing: Space.s) {
                if let id = watched, let container = containers.first(where: { $0.id == id }) {
                    HStack(spacing: Space.s) {
                        Text("\(container.name) · last 200 lines").style(.headline)
                        Spacer()
                        Button("Refresh", symbol: "arrow.clockwise") { self.followLogsUntil = Date().addingTimeInterval(Self.followLogsFor); await self.loadLogs(id) }
                        Button("Copy", symbol: "doc.on.doc") { Stackbar.copy(self.logs[id] ?? "") }
                    }
                    Text(String((logs[id] ?? "Loading…").suffix(40_000))).style(.monospaced)
                } else {
                    EmptyState("Pick a container", symbol: "text.alignleft", message: "Choose Show Logs on a container (⌘L) to follow its output here.", theme: theme)
                }
                Spacer(minLength: 0)
            }
            .frame(fillWidth: true)
        }
    }

    func watch(_ id: String) async {
        watched = id
        followLogsUntil = Date().addingTimeInterval(Self.followLogsFor)
        await loadLogs(id)
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
        } else if crashedIDs.contains(container.id) {
            row = row.badge("crashed", role: .critical)
        } else if container.state == "paused" {
            row = row.badge("paused")
        }
        if container.isRunning, let numbers = stats[container.id] {
            row = row.badge(String(format: "%.1f%% · ", numbers.cpu) + Self.size(numbers.memory), role: numbers.cpu >= 80 ? .warning : .secondary)
        } else if container.isRunning, let url = container.localURLs.first {
            row = row.badge(String(url.dropFirst("http://".count)))
        }
        if let url = container.localURLs.first {
            row = row.action("Open \(url.dropFirst("http://".count))") { Stackbar.open(url) }
        }
        if container.isRunning {
            row = row
                .action("Stop", shortcut: "cmd+.") { try await self.act("stop", container) }
                .action("Restart", shortcut: "cmd+r") { try await self.act("restart", container) }
                .action("Open Shell", shortcut: "cmd+t") {
                    // bash when the image has it, sh otherwise.
                    try await Stackbar.openInTerminal(["docker", "exec", "-it", container.name, "sh", "-c", "command -v bash >/dev/null && exec bash || exec sh"], title: container.name)
                }
        } else if container.state == "paused" {
            row = row
                .action("Resume", shortcut: "cmd+return") { try await self.act("unpause", container) }
                .action("Stop", shortcut: "cmd+.") { try await self.act("stop", container) }
        } else {
            row = row.action("Start", shortcut: "cmd+return") { try await self.act("start", container) }
        }
        return row
            .navigate("Logs", to: "logs", arguments: ["container": container.id], shortcut: "cmd+l")
            .action("Follow Logs in Terminal", shortcut: "cmd+shift+l") {
                try await Stackbar.openInTerminal(["docker", "logs", "--follow", "--tail", "200", container.name], title: "\(container.name) logs")
            }
            .action("Copy ID", shortcut: "cmd+shift+c") { Stackbar.copy(String(container.id.prefix(12))) }
            .action("Copy Exec Command") { Stackbar.copy("docker exec -it \(container.name) sh") }
            .action("Remove", shortcut: "ctrl+x", role: .critical, confirm: "remove \(container.name)") {
                guard !container.isRunning, container.state != "paused" else { throw HostError("Stop \(container.name) before removing it") }
                try await self.act("rm", container)
            }
    }

    var settings: ViewContent {
        Section("Show") {
            Toggle("Group by Compose project", isOn: groupByProject) { self.groupByProject = $0 }
        }
        Section("Notify") {
            Toggle("When a container crashes, turns unhealthy or keeps restarting", isOn: notifyTrouble) { self.notifyTrouble = $0 }
        }
        Section("Cleanup") {
            let shown = prunable.map(\.id)
            Button("Remove Stopped Containers", symbol: "trash", role: .critical, key: "prune", confirm: "remove \(shown.count) stopped container\(shown.count == 1 ? "" : "s")") {
                guard let ids = try await self.stillListed(shown, among: { self.prunable }) else {
                    Stackbar.hud("The list changed; open it again")
                    return
                }
                Stackbar.hud(try await self.prune(ids))
            }
            Text("Removes stopped containers with docker rm. Images and volumes are left alone.").style(.caption)
        }
    }

    /// Removes the given stopped containers with `docker rm`, which refuses one
    /// that is still running.
    func prune(_ ids: [String]) async throws -> String {
        guard !ids.isEmpty else { return "No stopped containers" }
        let result = try await Stackbar.run("docker", ["rm"] + ids, timeout: .seconds(120))
        await load()
        guard result.succeeded else { throw HostError(Self.explain(result)) }
        return "Removed \(ids.count) stopped container\(ids.count == 1 ? "" : "s")"
    }

    // MARK: Commands

    func find(_ text: String?) -> Container? {
        guard let text, !text.isEmpty else { return nil }
        return containers.first { $0.id.hasPrefix(text) || $0.name == text } ?? containers.first { $0.name.localizedCaseInsensitiveContains(text) }
    }

    var commands: [Command] {
        Command("containers", title: "Docker Containers", symbol: "shippingbox", keywords: ["docker", "container", "compose"])
            .view(search: { _ in await self.loadIfStale() }) { _ in
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
        Command("compose", title: "Docker Compose Projects", symbol: "square.stack.3d.up", keywords: ["docker", "compose", "project", "stack"])
            .view(search: { _ in await self.loadIfStale() }) { _ in
                if let problem = self.problem {
                    ContentUnavailableView("Docker isn't available", symbol: "shippingbox", message: problem)
                } else if self.composeProjects.isEmpty {
                    ContentUnavailableView("No Compose projects", symbol: "square.stack.3d.up", message: "Projects you start with docker compose up show here.")
                } else {
                    List(self.composeProjects.map { ComposeProject(id: $0.name, containers: $0.containers) }, searchable: true) { project in self.projectRow(project) }
                }
            }
        Command("stop-all", title: "Stop All Docker Containers", symbol: "stop.circle", keywords: ["docker", "stop", "containers", "all"])
            .view(search: { _ in await self.loadIfStale() }) { _ in
                if let problem = self.problem {
                    ContentUnavailableView("Docker isn't available", symbol: "shippingbox", message: problem)
                } else if self.running.isEmpty {
                    ContentUnavailableView("Nothing is running", symbol: "moon.zzz")
                } else {
                    let shown = self.running
                    List {
                        Row("Stop \(shown.count) container\(shown.count == 1 ? "" : "s") now", subtitle: shown.map(\.name).joined(separator: ", "), symbol: "stop.circle", key: "confirm")
                            .action("Stop All", role: .critical, confirm: .none) {
                                guard let ids = try await self.stillListed(shown.map(\.id), among: { self.running }) else {
                                    Stackbar.hud("The list changed; open it again")
                                    return
                                }
                                Stackbar.hud(try await self.stopAll(ids))
                            }
                    }
                }
            }
        Command("prune", title: "Remove Stopped Docker Containers", symbol: "trash", keywords: ["docker", "prune", "clean"])
            .view(search: { _ in await self.loadIfStale() }) { _ in
                if let problem = self.problem {
                    ContentUnavailableView("Docker isn't available", symbol: "shippingbox", message: problem)
                } else if self.prunable.isEmpty {
                    ContentUnavailableView("No stopped containers", symbol: "trash")
                } else {
                    let shown = self.prunable
                    List {
                        Row("Remove \(shown.count) stopped container\(shown.count == 1 ? "" : "s") now", subtitle: shown.map(\.name).joined(separator: ", "), symbol: "trash", key: "confirm")
                            .action("Remove", role: .critical, confirm: .none) {
                                guard let ids = try await self.stillListed(shown.map(\.id), among: { self.prunable }) else {
                                    Stackbar.hud("The list changed; open it again")
                                    return
                                }
                                Stackbar.hud(try await self.prune(ids))
                            }
                    }
                }
            }
            .stackbarOnly()
    }

    func projectRow(_ project: ComposeProject) -> Row {
        let up = project.containers.filter(\.isRunning).count
        var row = Row(project.id, subtitle: "\(up) of \(project.containers.count) running · " + project.containers.map(\.name).joined(separator: ", "),
                      symbol: up == 0 ? "square.stack.3d.up" : "square.stack.3d.up.fill", key: project.id)
        if up < project.containers.count {
            row = row.action("Start", shortcut: "cmd+return") { try await self.compose("start", project: project.id) }
        }
        if up > 0 {
            row = row
                .action("Restart", shortcut: "cmd+r") { try await self.compose("restart", project: project.id) }
                .action("Stop", shortcut: "cmd+.") { try await self.compose("stop", project: project.id) }
        }
        return row
    }

    struct ComposeProject: Identifiable {
        let id: String
        let containers: [Container]
    }

    var tools: [AgentTool] {
        AgentTool("containers", description: "Docker containers with name, image, state and status") { _ in
            if self.containers.isEmpty { await self.load() }
            if let problem = self.problem { return problem }
            return self.containers.map { container in
                let numbers = self.stats[container.id].map { String(format: "\t%.1f%% cpu\t", $0.cpu) + Self.size($0.memory) } ?? ""
                return "\(container.name)\t\(container.image)\t\(container.state)\t\(container.status)\(numbers)"
            }.joined(separator: "\n")
        }
    }
}
