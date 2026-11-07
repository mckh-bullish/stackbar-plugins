import StackbarKit
import Foundation

/// Your apps and System Settings panes in the command palette, as Spotlight
/// and Raycast have them: type a few letters ("saf", "vsc", "wi-fi") and the
/// app comes first; Return opens it. The ones you open most rank higher.
@main
final class Applications: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.applications",
        name: "Applications",
        version: "1.2.1",
        summary: "Open any app or System Settings pane from the command palette by typing a few letters.",
        surfaces: [.panel],
        triggers: [.launch],
        // Listing and opening apps; opening Settings panes by their link.
        capabilities: [.apps, .openURLs(schemes: ["x-apple.systempreferences"])],
        minimumStackbar: "0.20.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/System/Applications",
        accent: .blue,
        symbol: "square.grid.3x3.fill"
    )

    static let previews: [PreviewScene<Applications>] = [
        PreviewScene("hero", "Every app a few letters away") { plugin in
            try await plugin.load(force: true)
            plugin.opens = ["com.apple.Safari": 12, "com.apple.dt.Xcode": 8, "com.google.Chrome": 3]
        },
    ]

    let theme = Theme.blue

    var apps: [InstalledApp] = []
    var loadedAt: Date?
    var problem: String?
    var results: [InstalledApp] = []
    /// How often each app or pane was opened from here, by id.
    var failedAt: Date?
    @Stored("opens") var opens: [String: Int] = [:]

    /// The list from the host, at most every few minutes: a new app shows
    /// up the next time the palette asks after that.
    func load(force: Bool = false) async throws {
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 120 { return }
        // A failed listing waits a few seconds before the next try, so a
        // broken host call isn't repeated on every keystroke.
        if !force, let failedAt, Date().timeIntervalSince(failedAt) < 10 { return }
        do {
            apps = try await Stackbar.installedApps()
            loadedAt = Date()
            failedAt = nil
            problem = nil
        } catch {
            failedAt = Date()
            problem = "Can't list your apps: \(error)"
        }
    }

    func refresh() async throws {
        try await load()
    }

    // MARK: Matching

    /// How well `typed` matches `name`, or nil, with Stackbar's own matcher
    /// (the palette ranks every result with it): the whole name, then its
    /// start, a word's start, its initials ("vsc" → Visual Studio Code),
    /// anywhere in it, then every letter in order. A tier is worth 100, the
    /// quality within it up to 60.
    static func score(_ typed: String, in name: String) -> Int? {
        TextMatch.match(typed, in: name).map { 100 * ($0.tier.rawValue + 1) + $0.quality }
    }

    static func matches(_ query: String, in apps: [InstalledApp], opens: [String: Int] = [:], limit: Int = 12) -> [InstalledApp] {
        let typed = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return [] }
        return apps.compactMap { app -> (InstalledApp, Int)? in
            // A keyword counts less than the name: every Settings pane has
            // "settings", and "settings" has to find the System Settings app.
            let byName = score(typed, in: app.name)
            let byKeyword = app.keywords.compactMap { score(typed, in: $0) }.max().map { min($0, 299) }
            guard let best = [byName, byKeyword].compactMap({ $0 }).max() else { return nil }
            // Apps first on a tie: a pane named like an app rarely wins.
            let used = min(150, Int(30 * log2(1 + Double(opens[app.id] ?? 0))))
            return (app, best + used + (app.kind == .app ? 5 : 0))
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }
        .prefix(limit)
        .map(\.0)
    }

    // MARK: Opening

    func open(_ app: InstalledApp) async throws {
        opens[app.id, default: 0] += 1
        if app.kind == .settingsPane, let url = app.url {
            Stackbar.open(url)
        } else {
            try await Stackbar.activateApp(app.id, launch: true)
        }
    }

    func row(_ app: InstalledApp) -> Row {
        let pane = app.kind == .settingsPane
        return Row(app.name, subtitle: pane ? "System Settings" : nil, symbol: pane ? "gearshape" : "app", key: app.id)
            .appIcon(pane ? "com.apple.systempreferences" : app.id)
            .action("Open") { try await self.open(app) }
            .action("Copy Path", shortcut: "cmd+shift+c") { Stackbar.copy(app.path) }
            .action("Copy Bundle ID") { Stackbar.copy(app.id) }
    }

    // MARK: Commands

    var commands: [Command] {
        Command("search", title: "Search Applications", subtitle: "Open an app or a Settings pane", symbol: "square.grid.3x3", keywords: ["app", "launch", "open", "settings"])
            .view(search: { invocation in
                try await self.load()
                self.results = Self.matches(invocation.text, in: self.apps, opens: self.opens)
            }) { invocation in
                if let problem = self.problem {
                    ContentUnavailableView("No apps", symbol: "exclamationmark.triangle", message: problem)
                } else if invocation.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    // The most opened first, then every app by name.
                    let top = self.mostOpened(12)
                    let shown = Set(top.map(\.id))
                    List {
                        ForEach(top + self.apps.filter { $0.kind == .app && !shown.contains($0.id) }) { app in self.row(app) }
                    }
                } else {
                    List {
                        ForEach(self.results) { app in self.row(app) }
                    }
                }
            }
            .rootSearch(section: "Applications")
    }

    func mostOpened(_ count: Int) -> [InstalledApp] {
        let byID = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return opens.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(count)
            .compactMap { byID[$0.key] }
    }

    // MARK: Panel

    var panel: ViewContent {
        PanelHeader("Applications", subtitle: "\(apps.filter { $0.kind == .app }.count) apps · type in the palette", symbol: "square.grid.3x3.fill", theme: theme)
        if let problem {
            Banner(problem, theme: .warning)
        }
        let top = mostOpened(8)
        if top.isEmpty {
            EmptyState("Open apps from the palette", symbol: "square.grid.3x3", message: "Press ⌃⌥Space and type a few letters of an app or a Settings pane. Return opens it.", theme: theme)
        } else {
            Card("Most opened", spacing: 0, padding: Space.s) {
                ForEach(top) { app in self.row(app) }
            }
        }
        HStack(spacing: Space.xs) {
            Text("Switch apps without the palette: hold Right ⌘ and press a letter.").role(.secondary).typography(.caption)
            Link("App Switcher", url: "stackbar://store/\(Self.appSwitcherID)")
        }
    }

    /// App Switcher stays its own plugin: it listens to the keyboard, which
    /// every Mac with Applications shouldn't have to approve.
    static let appSwitcherID = "io.navbytes.stackbar.plugins.app-switcher"
}
