import StackbarKit
import Foundation

/// What Homebrew can upgrade, in the menu bar, with upgrades one click away.
///
/// Every hour (and on wake) it runs `brew outdated --json=v2`, which reads
/// what Homebrew already knows and is quick. "Update Homebrew" runs
/// `brew update` to fetch the latest formulae first. Runs go through
/// Stackbar, which finds `brew` in /opt/homebrew/bin or /usr/local/bin and
/// asks you to approve that path once.
@main
final class Homebrew: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.homebrew",
        name: "Homebrew",
        version: "1.2.0",
        summary: "Outdated formulae and casks, with upgrades a click away.",
        surfaces: [.menuBar, .panel, .widget, .settings],
        triggers: [.launch, .minutes(60), .wake],
        capabilities: [.run(commands: ["brew"])],
        minimumStackbar: "0.14.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Developer/Homebrew"
    )

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

    var packages: [Package] = []
    var checked: Date?
    var problem: String?
    /// What is running now, like "Upgrading node".
    var busy: String?
    var lastResult: String?
    var lastFailed = false

    @Stored("includeCasks") var includeCasks = true
    @Stored("hidePinned") var hidePinned = true
    @Stored("greedy") var greedy = false
    @Stored("notify") var notifyNew = false

    var shown: [Package] {
        packages.filter { (includeCasks || !$0.isCask) && (!hidePinned || !$0.pinned) }
    }

    func refresh() async throws {
        if busy == nil { lastResult = nil }
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
                    Stackbar.notify("Homebrew: \(new.count) new update\(new.count == 1 ? "" : "s")", body: new.prefix(5).map(\.name).joined(separator: ", "))
                }
            }
            packages = fresh.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            checked = Date()
            problem = nil
        } catch {
            problem = Self.explain(error)
        }
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

    static func failure(_ result: RunResult, doing what: String) -> String {
        if result.timedOut { return "\(what) took too long" }
        let message = result.errorText.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init)
        return "\(what) failed (\(result.status))" + (message.map { ": \($0)" } ?? "")
    }

    // MARK: Actions

    func upgrade(_ names: [String], label: String) async throws {
        guard busy == nil else { throw HostError("\(busy!) is still running") }
        busy = label
        defer { busy = nil }
        let result = try await Stackbar.run("brew", ["upgrade"] + names, environment: Self.quiet, timeout: .seconds(600))
        lastResult = result.succeeded ? "\(label): done" : Self.failure(result, doing: label)
        lastFailed = !result.succeeded
        await check()
        if !result.succeeded { throw HostError(lastResult!) }
    }

    func update() async throws -> String {
        guard busy == nil else { throw HostError("\(busy!) is still running") }
        busy = "Updating Homebrew"
        defer { busy = nil }
        let result = try await Stackbar.run("brew", ["update"], environment: ["HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_COLOR": "1"], timeout: .seconds(300))
        guard result.succeeded else { throw HostError(Self.failure(result, doing: "brew update")) }
        await check()
        lastResult = "Homebrew updated; \(shown.count) outdated"
        lastFailed = false
        return lastResult!
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
                            try await self.upgrade(self.upgradable.map(\.name), label: "Upgrading everything")
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
            Metric("\(shown.count)", unit: shown.count == 1 ? "update" : "updates", caption: checkedText, type: .metric)
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
        return "Checked " + checked.formatted(date: .omitted, time: .shortened)
    }

    func row(_ package: Package) -> Row {
        var row = Row(package.name, subtitle: "\(package.installed) → \(package.current)", symbol: package.isCask ? "macwindow" : "terminal", key: package.id)
        if package.pinned { row = row.badge("pinned", role: .warning) }
        return row
            .action("Upgrade") { try await self.upgrade([package.name], label: "Upgrading \(package.name)") }
            .action("Open Homepage", shortcut: "cmd+o") {
                Stackbar.open("https://formulae.brew.sh/\(package.isCask ? "cask" : "formula")/\(package.name)")
            }
            .action("Copy Upgrade Command", shortcut: "cmd+shift+c") {
                Stackbar.copy("brew upgrade \(package.isCask ? "--cask " : "")\(package.name)")
            }
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
        Section("Notify") {
            Toggle("When new updates appear", isOn: notifyNew) { self.notifyNew = $0 }
        }
        Section("How it checks") {
            Text("Hourly and on wake, Stackbar runs brew outdated, which reads what Homebrew already knows. Update Homebrew runs brew update to fetch the latest. Nothing runs in a shell.").style(.caption)
        }
    }

    var commands: [Command] {
        Command("upgrade-all", title: "Upgrade All Homebrew Packages", symbol: "arrow.up.circle", keywords: ["brew", "homebrew", "upgrade"]) { _ in
            await self.check()
            let names = self.shown.filter { !$0.pinned }.map(\.name)
            guard !names.isEmpty else { return .message("Everything is up to date") }
            try await self.upgrade(names, label: "Upgrading \(names.count) package\(names.count == 1 ? "" : "s")")
            return .message("Upgraded \(names.count)")
        }
        Command("update", title: "Update Homebrew", symbol: "arrow.down.circle", keywords: ["brew", "homebrew"]) { _ in
            .message(try await self.update())
        }
        Command("outdated", title: "Outdated Homebrew Packages", symbol: "mug", keywords: ["brew", "homebrew"])
            .view(search: { _ in await self.check() }) { _ in
                if let problem = self.problem {
                    ContentUnavailableView("Can't check Homebrew", symbol: "exclamationmark.triangle", message: problem)
                } else if self.shown.isEmpty {
                    ContentUnavailableView("Everything is up to date", symbol: "checkmark.seal")
                } else {
                    List(self.shown, searchable: true) { package in self.row(package) }
                }
            }
    }

    var tools: [AgentTool] {
        AgentTool("outdated", description: "Homebrew formulae and casks with updates, as name installed -> current") { _ in
            self.shown.isEmpty ? "Everything is up to date" : self.shown.map { "\($0.name) \($0.installed) -> \($0.current)\($0.isCask ? " (cask)" : "")" }.joined(separator: "\n")
        }
    }
}
