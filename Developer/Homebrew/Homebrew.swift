import StackbarKit
import Foundation

/// What Homebrew can upgrade, in the menu bar, with upgrades one click away.
///
/// Every hour (and on wake) it runs `brew outdated --json=v2`, which reads
/// what Homebrew already knows and is quick. Every few hours it first runs
/// `brew update` in the background so that list is not stale, and "Update
/// Homebrew" does the same on demand. Runs go through
/// Stackbar, which finds `brew` in /opt/homebrew/bin or /usr/local/bin and
/// asks you to approve that path once.
@main
final class Homebrew: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.homebrew",
        name: "Homebrew",
        version: "1.6.0",
        summary: "Outdated formulae and casks, with upgrades a click away.",
        surfaces: [.menuBar, .panel, .widget, .settings],
        triggers: [.launch, .minutes(60), .wake],
        capabilities: [.run(commands: ["brew"])],
        minimumStackbar: "0.26.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Developer/Homebrew",
        accent: .amber,
        symbol: "mug.fill"
    )

    // MARK: Previews

    static let previews: [PreviewScene<Homebrew>] = [
        PreviewScene("hero", "Every outdated formula and cask, one click to upgrade") { plugin in
            plugin.packages = samples
            plugin.checked = Date().addingTimeInterval(-6 * 60)
            plugin.indexUpdated = Date().addingTimeInterval(-6 * 60)
        },
        PreviewScene("widget", "Updates waiting, on your desktop", surface: .widget) { plugin in
            plugin.packages = samples
            plugin.checked = Date().addingTimeInterval(-6 * 60)
            plugin.indexUpdated = Date().addingTimeInterval(-6 * 60)
        },
    ]

    static let samples = [
        Package(name: "node", installed: "22.11.0", current: "22.12.0", isCask: false, pinned: false),
        Package(name: "git", installed: "2.47.0", current: "2.47.1", isCask: false, pinned: false),
        Package(name: "ripgrep", installed: "14.1.0", current: "14.1.1", isCask: false, pinned: false),
        Package(name: "python@3.13", installed: "3.13.0", current: "3.13.1", isCask: false, pinned: true),
        Package(name: "visual-studio-code", installed: "1.95.1", current: "1.95.3", isCask: true, pinned: false),
        Package(name: "firefox", installed: "132.0", current: "132.0.2", isCask: true, pinned: false),
        Package(name: "orbstack", installed: "1.8.1", current: "1.8.2", isCask: true, pinned: false),
    ]

    struct Package: Equatable, Identifiable {
        var name: String
        var installed: String
        var current: String
        var isCask: Bool
        var pinned: Bool
        var id: String { (isCask ? "cask:" : "formula:") + name }
    }

    /// `brew outdated --json=v2`.
    struct Outdated: Decodable {
        struct Item: Decodable {
            let name: String
            let installed_versions: Versions
            let current_version: String
            let pinned: Bool?
        }

        /// A list for formulae; casks have sent both a list and a string.
        struct Versions: Decodable {
            let values: [String]
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let list = try? container.decode([String].self) {
                    values = list
                } else {
                    values = [try container.decode(String.self)]
                }
            }
        }

        let formulae: [Item]
        let casks: [Item]
    }

    /// One line of `brew services list --json`. Each field is read on its own,
    /// so an odd value (a null status, a code sent as text) doesn't drop the line.
    struct Service: Decodable, Equatable, Identifiable {
        let name: String
        let status: String
        let exit_code: Int?
        var id: String { name }
        private enum K: String, CodingKey { case name, status, exit_code }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            name = try c.decode(String.self, forKey: .name)
            status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "unknown"
            exit_code = (try? c.decodeIfPresent(Int.self, forKey: .exit_code)) ?? (try? c.decodeIfPresent(String.self, forKey: .exit_code)).flatMap { Int($0) }
        }
    }

    /// A list entry that doesn't decode is skipped, not a reason to drop the list.
    private struct Lossy: Decodable {
        let value: Service?
        init(from d: Decoder) { value = try? Service(from: d) }
    }

    var packages: [Package] = []
    var checked: Date?
    var problem: String?
    /// What is running now, like "Upgrading node".
    var busy: String?
    var lastResult: String?
    var lastFailed = false
    var services: [Service] = []
    var servicesLoadedAt: Date?
    var servicesProblem: String?

    @Stored("includeCasks") var includeCasks = true
    @Stored("hidePinned") var hidePinned = true
    @Stored("greedy") var greedy = false
    @Stored("notify") var notifyNew = false
    /// Run `brew update` in the background when the formulae list is older than this.
    @Stored("autoUpdate") var autoUpdate = true
    /// When `brew update` last succeeded, from here or the button.
    @Stored("indexUpdated") var indexUpdated: Date? = nil

    static let staleAfter: TimeInterval = 6 * 3600

    /// Whether the background `brew update` is due.
    func indexIsStale(now: Date = Date()) -> Bool {
        guard let indexUpdated else { return true }
        return now.timeIntervalSince(indexUpdated) >= Self.staleAfter
    }

    var shown: [Package] {
        packages.filter { (includeCasks || !$0.isCask) && (!hidePinned || !$0.pinned) }
    }

    func refresh() async throws {
        if busy == nil { lastResult = nil }
        // Not on the first check after launch, which should show the list
        // right away; the next hourly or wake check fetches first.
        if autoUpdate, busy == nil, checked != nil, indexIsStale() {
            // Quietly: a failed fetch (offline, say) still leaves the last list to show.
            _ = try? await fetchIndex(label: "Fetching the latest formulae", announce: false)
        }
        await check()
    }

    func check() async {
        var arguments = ["outdated", "--json=v2"]
        if greedy { arguments.append("--greedy") }
        do {
            let result = try await Stackbar.run("brew", arguments, environment: Self.quiet, timeout: .seconds(120))
            guard result.succeeded else {
                problem = Self.failure(result, doing: "brew outdated")
                return
            }
            let reply = try JSONDecoder().decode(Outdated.self, from: result.stdout)
            let fresh = reply.formulae.map { Package(name: $0.name, installed: $0.installed_versions.values.last ?? "?", current: $0.current_version, isCask: false, pinned: $0.pinned ?? false) }
                + reply.casks.map { Package(name: $0.name, installed: $0.installed_versions.values.last ?? "?", current: $0.current_version, isCask: true, pinned: false) }
            if notifyNew, checked != nil {
                let known = Set(packages.map(\.id))
                let new = fresh.filter { !known.contains($0.id) && (includeCasks || !$0.isCask) }
                if !new.isEmpty {
                    Stackbar.notify("Homebrew: \(new.count) new update\(new.count == 1 ? "" : "s")", body: new.prefix(5).map(\.name).joined(separator: ", "),
                                    actions: [NotificationAction("Upgrade All", command: "upgrade-all")])
                }
            }
            packages = fresh.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            checked = Date()
            problem = nil
        } catch {
            problem = Self.explain(error)
        }
    }

    /// For views that ask on every keystroke: a list checked in the last minute
    /// is as good as a new one, and a failed check is tried again.
    func checkIfStale() async {
        if problem != nil || checked.map({ Date().timeIntervalSince($0) > 60 }) ?? true { await check() }
    }

    /// No auto-update, hints or analytics noise in the output.
    static let quiet = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1", "HOMEBREW_NO_COLOR": "1"]

    static func explain(_ error: Error) -> String {
        let text = "\(error)"
        if text.contains("not installed") || text.contains("not found") {
            return "Homebrew isn't installed. Get it from brew.sh, then refresh."
        }
        return text
    }

    /// What went wrong in a run that finished, without naming what it was for.
    static func detail(_ result: RunResult) -> String {
        if result.timedOut { return "took too long" }
        let message = result.errorText.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init)
        return "failed (\(result.status))" + (message.map { ": \($0)" } ?? "")
    }

    static func failure(_ result: RunResult, doing what: String) -> String {
        "\(what) \(detail(result))"
    }

    // MARK: Actions

    /// Formulae and casks go in separate calls, so a name that is both a
    /// formula and a cask upgrades the right one. A failure in one group
    /// doesn't stop the other.
    func upgrade(_ packages: [Package], label: String) async throws {
        guard busy == nil else { throw HostError("\(busy!) is still running") }
        busy = label
        defer { busy = nil }
        Stackbar.hud("\(label)… this can take a few minutes")
        let formulae = packages.filter { !$0.isCask }.map(\.name)
        let casks = packages.filter(\.isCask).map(\.name)
        var outcomes: [String] = []
        var failed = false
        for (kind, flag, names) in [("formulae", "--formula", formulae), ("casks", "--cask", casks)] where !names.isEmpty {
            do {
                let result = try await Stackbar.run("brew", ["upgrade", flag] + names, environment: Self.quiet, timeout: .seconds(600))
                if result.succeeded {
                    outcomes.append("\(kind): done")
                } else {
                    failed = true
                    outcomes.append("\(kind): \(Self.detail(result))")
                }
            } catch {
                failed = true
                outcomes.append("\(kind): \(Self.explain(error))")
            }
        }
        lastResult = failed ? outcomes.joined(separator: "; ") : "\(label): done"
        lastFailed = failed
        await check()
        if failed { throw HostError(lastResult!) }
    }

    /// Runs `brew update` and records when it worked. A background fetch
    /// stays quiet; one the user asked for says it may take a while.
    func fetchIndex(label: String, announce: Bool = true) async throws {
        guard busy == nil else { throw HostError("\(busy!) is still running") }
        busy = label
        defer { busy = nil }
        if announce { Stackbar.hud("\(label)… this can take a few minutes") }
        let result = try await Stackbar.run("brew", ["update"], environment: ["HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_COLOR": "1"], timeout: .seconds(300))
        guard result.succeeded else { throw HostError(Self.failure(result, doing: "brew update")) }
        indexUpdated = Date()
    }

    func update() async throws -> String {
        try await fetchIndex(label: "Updating Homebrew")
        await check()
        lastResult = "Homebrew updated; \(shown.count) outdated"
        lastFailed = false
        return lastResult!
    }

    /// The background services launchd runs for formulae, like postgresql.
    /// Reused for half a minute, so searching the view doesn't re-run brew;
    /// a failure is kept for that long too.
    func loadServices(force: Bool = false) async {
        if !force, let at = servicesLoadedAt, Date().timeIntervalSince(at) < 30 { return }
        defer { servicesLoadedAt = Date() }
        do {
            let result = try await Stackbar.run("brew", ["services", "list", "--json"], environment: Self.quiet, timeout: .seconds(60))
            guard result.succeeded else {
                servicesProblem = Self.failure(result, doing: "brew services")
                return
            }
            services = try result.stdout.isEmpty ? [] : JSONDecoder().decode([Lossy].self, from: result.stdout).compactMap(\.value)
            servicesProblem = nil
        } catch {
            servicesProblem = Self.explain(error)
        }
    }

    func service(_ verb: String, _ name: String) async throws {
        let result = try await Stackbar.run("brew", ["services", verb, name], environment: Self.quiet, timeout: .seconds(60))
        guard result.succeeded else { throw HostError(Self.failure(result, doing: "brew services \(verb) \(name)")) }
        Stackbar.hud("\(name) \(["start": "started", "stop": "stopped", "restart": "restarted"][verb] ?? verb)")
        await loadServices(force: true)
    }

    // MARK: Surfaces

    let theme = Theme.amber

    var menuBar: ViewContent {
        if busy != nil {
            Label("", symbol: "arrow.triangle.2.circlepath")
        } else if problem != nil {
            Label("", symbol: "mug").role(.warning)
        } else if shown.isEmpty {
            Label("", symbol: "mug").role(.secondary)
        } else {
            Label("\(shown.count)", symbol: "mug.fill")
        }
    }

    var upgradable: [Package] { shown.filter { !$0.pinned } }

    var panel: ViewContent {
        VStack(spacing: Space.m) {
            if checked == nil && problem == nil {
                PanelHeader("Homebrew", subtitle: "Checking…", symbol: "mug.fill", theme: theme)
            } else if let problem, checked == nil {
                let missing = problem.contains("isn't installed")
                EmptyState(missing ? "Homebrew isn't installed" : "Can't check Homebrew", symbol: missing ? "mug" : "exclamationmark.triangle.fill", message: problem, theme: missing ? theme : .critical) {
                    ActionButton("Try Again", symbol: "arrow.clockwise", theme: theme) { await self.check() }
                }
                if missing { Link("Get Homebrew at brew.sh", url: "https://brew.sh") }
            } else {
                PanelHeader(shown.isEmpty ? "Up to date" : "\(shown.count) update\(shown.count == 1 ? "" : "s")", subtitle: checkedText, symbol: "mug.fill", theme: theme) {
                    IconButton("arrow.down.circle", label: "Update Homebrew", theme: theme, prominence: .tinted) { _ = try await self.update() }
                    if upgradable.count >= 2 {
                        ActionButton("Upgrade All", theme: theme, prominent: true) {
                            try await self.upgrade(self.upgradable, label: "Upgrading everything")
                        }
                    }
                }
                HeroCard(theme: shown.isEmpty ? .success : theme, look: .glow) {
                    HStack(spacing: Space.l) {
                        if shown.isEmpty {
                            Image(systemName: "checkmark.seal.fill").font(size: 30, weight: .semibold).foreground(Theme.success.textPaint).symbolEffect(.bounce, repeats: false)
                            VStack(spacing: Space.xxs) {
                                Text("Everything's fresh").typography(.title)
                                Text(checkedText).role(.secondary).typography(.caption)
                            }
                        } else {
                            HeroStat("Outdated", value: "\(shown.count)", theme: theme, symbol: "arrow.up.circle.fill")
                            HeroStat("Formulae", value: "\(shown.filter { !$0.isCask }.count)", theme: theme, symbol: "terminal.fill")
                            HeroStat("Casks", value: "\(shown.filter(\.isCask).count)", theme: theme, symbol: "macwindow")
                        }
                        Spacer()
                    }
                }
                if let problem { Banner(problem) }
                if let busy {
                    Banner("\(busy)… this can take a few minutes.", symbol: "arrow.triangle.2.circlepath", theme: .info)
                } else if let lastResult {
                    Banner(lastResult, symbol: lastFailed ? "xmark.octagon.fill" : "checkmark.circle.fill", theme: lastFailed ? .critical : .success)
                }
                if shown.isEmpty {
                    // The hero above already says it's all fresh.
                    ActionButton("Update Homebrew", symbol: "arrow.down.circle", theme: theme, fillWidth: true) { _ = try await self.update() }
                } else {
                    List(shown, searchable: shown.count > 8) { package in
                        self.row(package)
                    }
                }
            }
        }
    }

    var widget: ViewContent {
        HStack(alignment: .start, spacing: Space.l) {
            VStack(spacing: Space.s) {
                Metric("\(shown.count)", unit: shown.count == 1 ? "update" : "updates", caption: checkedText, type: .metric)
                // Stackbar 0.21.0 sends widget presses to the plugin.
                if upgradable.isEmpty {
                    Button("Check", symbol: "arrow.clockwise", key: "widget-check") { await self.check() }
                } else {
                    Button("Upgrade All", symbol: "arrow.up.circle", key: "widget-upgrade") {
                        try await self.upgrade(self.upgradable, label: "Upgrading everything")
                    }
                }
            }
            VStack(spacing: Space.xxs) {
                ForEach(shown.prefix(4)) { package in
                    Text(package.name).typography(.caption)
                }
            }
            Spacer()
        }
    }

    var checkedText: String {
        guard let checked else { return "" }
        let text = "Checked " + checked.formatted(date: .omitted, time: .shortened)
        guard let indexUpdated else { return text + " · list never fetched" }
        return text + " · list from " + Self.ago(indexUpdated, now: checked)
    }

    /// "just now", "3h ago", "2d ago".
    static func ago(_ date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        if minutes < 48 * 60 { return "\(minutes / 60)h ago" }
        return "\(minutes / 1440)d ago"
    }

    /// Casks report a build number after a comma (`4.98.0,245422`); the
    /// version people know is the part before it.
    static func display(_ version: String) -> String {
        version.split(separator: ",").first.map(String.init) ?? version
    }

    func row(_ package: Package) -> Row {
        var row = Row(package.name, subtitle: "\(Self.display(package.installed)) → \(Self.display(package.current))", symbol: package.isCask ? "macwindow" : "terminal", key: package.id)
        if package.pinned {
            // brew refuses to upgrade a pinned formula, so offer the way out instead.
            row = row.badge("pinned", role: .warning)
                .action("Copy Unpin Command") { Stackbar.copy("brew unpin \(package.name)") }
        } else {
            row = row.action("Upgrade") { try await self.upgrade([package], label: "Upgrading \(package.name)") }
        }
        row = row.action("Open Homepage", shortcut: "cmd+o") {
            Stackbar.open("https://formulae.brew.sh/\(package.isCask ? "cask" : "formula")/\(package.name)")
        }
        if !package.pinned {
            row = row.action("Copy Upgrade Command", shortcut: "cmd+shift+c") {
                Stackbar.copy("brew upgrade \(package.isCask ? "--cask " : "")\(package.name)")
            }
        }
        return row
    }

    func serviceRow(_ service: Service) -> Row {
        let started = service.status == "started"
        var row = Row(service.name, subtitle: started ? "Running" : service.status == "error" ? "Failed (exit \(service.exit_code ?? 0))" : "Not running",
                      symbol: started ? "circle.fill" : "circle", key: "service:\(service.name)")
        if service.status == "error" { row = row.badge("error", role: .critical) }
        // Stopping a service is undone by Start, so it takes one click.
        if started {
            row = row
                .action("Restart", shortcut: "cmd+r") { try await self.service("restart", service.name) }
                .action("Stop", shortcut: "cmd+.") { try await self.service("stop", service.name) }
        } else {
            row = row.action("Start", shortcut: "cmd+return") { try await self.service("start", service.name) }
        }
        return row
    }

    var settings: ViewContent {
        Section("Show") {
            Toggle("Casks", isOn: includeCasks) { self.includeCasks = $0 }
            Toggle("Hide pinned formulae", isOn: hidePinned) { self.hidePinned = $0 }
            Toggle("Include casks that update themselves", isOn: greedy) { value in
                self.greedy = value
                await self.check()
            }
        }
        Section("Stay current") {
            Toggle("Fetch the latest formulae every 6 hours", isOn: autoUpdate) { self.autoUpdate = $0 }
        }
        Section("Notify") {
            Toggle("When new updates appear", isOn: notifyNew) { self.notifyNew = $0 }
        }
        Section("How it checks") {
            Text("Hourly and on wake, Stackbar runs brew outdated, which reads what Homebrew already knows. Every 6 hours it runs brew update first, so that list stays current; Update Homebrew does it now. Nothing runs in a shell.").style(.caption)
        }
    }

    var commands: [Command] {
        Command("upgrade-all", title: "Upgrade All Homebrew Packages", symbol: "arrow.up.circle", keywords: ["brew", "homebrew", "upgrade"]) { _ in
            await self.check()
            let packages = self.shown.filter { !$0.pinned }
            guard !packages.isEmpty else { return .message("Everything is up to date") }
            try await self.upgrade(packages, label: "Upgrading \(packages.count) package\(packages.count == 1 ? "" : "s")")
            return .message("Upgraded \(packages.count)")
        }
        Command("update", title: "Update Homebrew", symbol: "arrow.down.circle", keywords: ["brew", "homebrew"]) { _ in
            .message(try await self.update())
        }
        Command("outdated", title: "Outdated Homebrew Packages", symbol: "mug", keywords: ["brew", "homebrew"])
            .view(search: { _ in await self.checkIfStale() }) { _ in
                if let problem = self.problem {
                    ContentUnavailableView("Can't check Homebrew", symbol: "exclamationmark.triangle", message: problem)
                } else if self.shown.isEmpty {
                    ContentUnavailableView("Everything is up to date", symbol: "checkmark.seal")
                } else {
                    List(self.shown, searchable: true) { package in self.row(package) }
                }
            }
        Command("services", title: "Homebrew Services", symbol: "gearshape.2", keywords: ["brew", "homebrew", "services", "launchd", "postgres", "redis"])
            .view(search: { _ in await self.loadServices() }) { _ in
                if let problem = self.servicesProblem {
                    ContentUnavailableView("Can't list services", symbol: "exclamationmark.triangle", message: problem)
                } else if self.services.isEmpty {
                    ContentUnavailableView("No services", symbol: "gearshape.2", message: "Formulae that run in the background, like postgresql or redis, show here.")
                } else {
                    List(self.services, searchable: true) { service in self.serviceRow(service) }
                }
            }
    }

    var tools: [AgentTool] {
        AgentTool("outdated", description: "Homebrew formulae and casks with updates, as name installed -> current") { _ in
            self.shown.isEmpty ? "Everything is up to date" : self.shown.map { "\($0.name) \(Self.display($0.installed)) -> \(Self.display($0.current))\($0.isCask ? " (cask)" : "")" }.joined(separator: "\n")
        }
    }
}
