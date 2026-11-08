import StackbarKit
import Foundation

/// The folders and workspaces you opened lately in VS Code, Cursor,
/// Windsurf and VSCodium, in the palette: type a few letters of the project
/// and Return opens it in the editor you last used it in, or in the default
/// editor picked in Settings (Zed, Xcode, Sublime Text, a JetBrains IDE…).
///
/// Each editor keeps its recent list in a small database in Application
/// Support; Stackbar reads it with `sqlite3` in read-only mode, so the
/// editor's own files are never changed.
@main
final class RecentProjects: StackbarPlugin {
    struct Editor: Equatable, Sendable {
        var name: String
        var bundleID: String
        /// The folder under Application Support that holds `state.vscdb`.
        var folder: String
        var scheme: String
    }

    static let editors: [Editor] = [
        Editor(name: "VS Code", bundleID: "com.microsoft.VSCode", folder: "~/Library/Application Support/Code/User/globalStorage", scheme: "vscode"),
        Editor(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", folder: "~/Library/Application Support/Cursor/User/globalStorage", scheme: "cursor"),
        Editor(name: "Windsurf", bundleID: "com.exafunction.windsurf", folder: "~/Library/Application Support/Windsurf/User/globalStorage", scheme: "windsurf"),
        Editor(name: "VSCodium", bundleID: "com.vscodium", folder: "~/Library/Application Support/VSCodium/User/globalStorage", scheme: "vscodium"),
    ]

    /// An app a project can open in. The VS Code family opens through its
    /// own link (`vscode://file/…`), which reuses a window already showing
    /// the folder; the rest are handed the folder like Finder's Open With.
    struct App: Equatable, Sendable {
        var name: String
        var bundleID: String
        var scheme: String?
        /// Whether it opens `.code-workspace` files: the VS Code family only.
        var opensWorkspaces: Bool { scheme != nil }
    }

    /// The editors Settings offers as the default, when installed.
    static let apps: [App] = editors.map { App(name: $0.name, bundleID: $0.bundleID, scheme: $0.scheme) } + [
        App(name: "VS Code Insiders", bundleID: "com.microsoft.VSCodeInsiders", scheme: "vscode-insiders"),
        App(name: "Zed", bundleID: "dev.zed.Zed"),
        App(name: "Zed Preview", bundleID: "dev.zed.Zed-Preview"),
        App(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
        App(name: "Sublime Text", bundleID: "com.sublimetext.4"),
        App(name: "Nova", bundleID: "com.panic.Nova"),
        App(name: "BBEdit", bundleID: "com.barebones.bbedit"),
        App(name: "TextMate", bundleID: "com.macromates.TextMate"),
        App(name: "IntelliJ IDEA", bundleID: "com.jetbrains.intellij"),
        App(name: "IntelliJ IDEA CE", bundleID: "com.jetbrains.intellij.ce"),
        App(name: "WebStorm", bundleID: "com.jetbrains.WebStorm"),
        App(name: "PyCharm", bundleID: "com.jetbrains.pycharm"),
        App(name: "PyCharm CE", bundleID: "com.jetbrains.pycharm.ce"),
        App(name: "GoLand", bundleID: "com.jetbrains.goland"),
        App(name: "RustRover", bundleID: "com.jetbrains.rustrover"),
        App(name: "Android Studio", bundleID: "com.google.android.studio"),
    ]

    /// The default editor setting's first choice: each project opens where
    /// it came from.
    static let lastUsed = "Where it was last opened"

    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.recent-projects",
        name: "Recent Projects",
        version: "1.2.0",
        summary: "Open the projects you used lately in VS Code, Cursor, Windsurf or VSCodium from the palette.",
        surfaces: [.panel, .settings],
        triggers: [.launch, .minutes(5), .wake],
        capabilities: [
            .run(commands: ["sqlite3"]),
            .files(paths: editors.map(\.folder)),
            // "*": folders open in any default editor, not only by link.
            .openURLs(schemes: ["*"]),
            // Which editors are installed, for the default editor setting.
            .apps,
        ],
        minimumStackbar: "0.22.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Developer/RecentProjects",
        accent: .blue,
        symbol: "folder.badge.gearshape"
    )

    static let previews: [PreviewScene<RecentProjects>] = [
        PreviewScene("hero", "Your projects, a few letters away") { plugin in
            plugin.projects = [
                Project(path: "/Users/you/code/stackbar", kind: .folder, editor: "VS Code"),
                Project(path: "/Users/you/code/stackbar-plugins", kind: .folder, editor: "Cursor"),
                Project(path: "/Users/you/code/site/site.code-workspace", kind: .workspace, editor: "VS Code"),
                Project(path: "/Users/you/code/notes", kind: .folder, editor: "Windsurf"),
            ]
            plugin.found = ["VS Code", "Cursor", "Windsurf"]
            plugin.loadedAt = Date()
        },
        PreviewScene("editors", "Open projects in the editor you prefer", surface: .settings) { plugin in
            plugin.installed = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.apple.dt.Xcode"]
            plugin.defaultEditor = "dev.zed.Zed"
            plugin.loadedAt = Date()
        },
    ]

    /// What the panel and the palette say while VS Code keeps its list where
    /// this version can't read it.
    static let vsCodeMovedText = "VS Code 1.118 and later keep recent projects where this version can't read them yet."

    let theme = Theme.blue

    struct Project: Equatable, Identifiable {
        enum Kind: Equatable { case folder, workspace }
        var path: String
        var kind: Kind
        var editor: String
        var id: String { "\(editor)|\(path)" }
        var name: String {
            let last = (path as NSString).lastPathComponent
            return kind == .workspace ? (last as NSString).deletingPathExtension : last
        }
        /// The path with the home folder as ~.
        var shortPath: String {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0] == "Users" else { return path }
            return "~/" + parts.dropFirst(2).joined(separator: "/")
        }
        /// What Show in Finder opens: a folder itself, or a workspace's folder.
        var folder: String { kind == .workspace ? (path as NSString).deletingLastPathComponent : path }
    }

    var projects: [Project] = []
    var loadedAt: Date?
    var found: [String] = []
    var results: [Project] = []
    @Stored("opens") var opens: [String: Int] = [:]
    @Stored("perEditor") var perEditor = 30
    /// The default editor's bundle id; empty opens each project where it
    /// was last opened.
    @Stored("defaultEditor") var defaultEditor = ""
    /// The bundle ids of the `apps` installed on this Mac.
    var installed: Set<String> = []
    /// Editors whose list couldn't be read, and why: a locked database, say.
    var problems: [String] = []

    /// VS Code is installed but its list wasn't found where this version
    /// looks: it moved the list in 1.118.
    var vsCodeMoved: Bool { installed.contains("com.microsoft.VSCode") && !found.contains("VS Code") && !problems.contains { $0.hasPrefix("VS Code") } }

    // MARK: Reading

    func load(force: Bool = false) async {
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 60 { return }
        var all: [Project] = []
        var seen: [String] = []
        var failures: [String] = []
        for editor in Self.editors {
            let result: RunResult
            do {
                result = try await Stackbar.run("sqlite3", ["-readonly", "state.vscdb", "SELECT value FROM ItemTable WHERE key = 'history.recentlyOpenedPathsList'"], workingDirectory: editor.folder, timeout: .seconds(10))
            } catch {
                // An editor that isn't installed has no folder: the run is
                // refused and it is skipped. Any other refusal is a failed read.
                if !"\(error)".contains("is not a folder") { failures.append("\(editor.name): \(error)") }
                continue
            }
            guard result.succeeded else {
                failures.append("\(editor.name): " + (result.errorText.split(separator: "\n").first.map(String.init) ?? "sqlite3 failed (\(result.status))"))
                continue
            }
            let list = Self.parse(result.text, editor: editor.name)
            if !list.isEmpty { seen.append(editor.name) }
            all += list.prefix(perEditor)
        }
        // One row a path: the editor listed first (VS Code, then Cursor…)
        // keeps it.
        var paths = Set<String>()
        projects = all.filter { paths.insert($0.path).inserted }
        found = seen
        problems = failures
        if let list = try? await Stackbar.installedApps() {
            let ids = Set(list.map(\.id))
            installed = Set(Self.apps.map(\.bundleID).filter(ids.contains))
        }
        // Counts for projects that have left every list are dropped. Not
        // after a failed read, which would lose the counts of its projects.
        if problems.isEmpty {
            let kept = opens.filter { paths.contains($0.key) }
            if kept.count != opens.count { opens = kept }
        }
        loadedAt = Date()
    }

    func refresh() async throws {
        await load(force: true)
    }

    /// The JSON VS Code keeps under `history.recentlyOpenedPathsList`:
    /// `{"entries": [{"folderUri": "file:///…"}, {"workspace": {"configPath": "file:///…"}}, {"fileUri": …}]}`.
    /// Folders and workspaces on this Mac only; files and remote ones are
    /// left out.
    static func parse(_ text: String, editor: String) -> [Project] {
        struct List: Decodable {
            struct Entry: Decodable {
                struct Workspace: Decodable { var configPath: String? }
                var folderUri: String?
                var workspace: Workspace?
            }
            var entries: [Entry]
        }
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let list = try? JSONDecoder().decode(List.self, from: data) else { return [] }
        return list.entries.compactMap { entry in
            if let uri = entry.folderUri, let path = localPath(uri) { return Project(path: path, kind: .folder, editor: editor) }
            if let uri = entry.workspace?.configPath, let path = localPath(uri) { return Project(path: path, kind: .workspace, editor: editor) }
            return nil
        }
    }

    static func localPath(_ uri: String) -> String? {
        guard let url = URL(string: uri), url.scheme == "file" else { return nil }
        let path = url.path
        return path.isEmpty ? nil : path
    }

    // MARK: Matching

    func matches(_ query: String) -> [Project] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let used = { (project: Project) in self.opens[project.path] ?? 0 }
        guard !words.isEmpty else { return projects }
        return projects.compactMap { project -> (Project, Int)? in
            let name = project.name.lowercased()
            let path = project.shortPath.lowercased()
            var score = 0
            for word in words {
                if name.hasPrefix(word) { score += 300 } else if name.contains(word) { score += 200 } else if path.contains(word) { score += 50 } else { return nil }
            }
            return (project, score + min(200, used(project) * 20))
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    // MARK: Opening

    static func app(named name: String) -> App? { apps.first { $0.name == name } }

    /// The editor Return opens a project in: the default one when it can
    /// open it, else the one whose list it came from.
    func primary(for project: Project) -> App? {
        if let chosen = Self.apps.first(where: { $0.bundleID == defaultEditor }),
           project.kind == .folder || chosen.opensWorkspaces {
            return chosen
        }
        return Self.app(named: project.editor)
    }

    /// The other editors ⌘K offers: the ones with a recent list, and the
    /// default editor.
    func others(for project: Project) -> [App] {
        let primary = primary(for: project)
        var names = found
        if let chosen = Self.apps.first(where: { $0.bundleID == defaultEditor }), !names.contains(chosen.name) { names.append(chosen.name) }
        return names.compactMap(Self.app(named:)).filter { app in
            app != primary && (project.kind == .folder || app.opensWorkspaces)
        }
    }

    func open(_ project: Project, in app: App) async {
        opens[project.path, default: 0] += 1
        if let scheme = app.scheme {
            let encoded = project.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? project.path
            Stackbar.open("\(scheme)://file\(encoded)")
            return
        }
        do {
            try await Stackbar.open(project.path, with: app.bundleID)
        } catch {
            Stackbar.hud("Couldn't open \(project.name) in \(app.name)", isError: true)
        }
    }

    func row(_ project: Project) -> Row {
        let primary = primary(for: project)
        var row = Row(project.name, subtitle: project.shortPath, symbol: project.kind == .workspace ? "square.stack.3d.up" : "folder", key: project.id)
            .appIcon(primary?.bundleID)
        if let primary {
            row = row.action("Open in \(primary.name)") { await self.open(project, in: primary) }
        }
        for other in others(for: project) {
            row = row.action("Open in \(other.name)") { await self.open(project, in: other) }
        }
        return row
            .action("Show in Finder", shortcut: "cmd+shift+f") { try await Stackbar.open(project.folder, with: "com.apple.finder") }
            .action("Copy Path", shortcut: "cmd+shift+c") { Stackbar.copy(project.path) }
            .badge(project.editor, role: .secondary)
    }

    // MARK: Settings

    /// The editors to pick from: the installed ones, and the current choice
    /// even when it isn't found.
    var choices: [App] {
        Self.apps.filter { installed.contains($0.bundleID) || $0.bundleID == defaultEditor }
    }

    var settings: ViewContent {
        Section("Opening") {
            Picker("Open projects in", options: [Self.lastUsed] + choices.map(\.name), selection: Self.apps.first { $0.bundleID == defaultEditor }?.name ?? Self.lastUsed) { choice in
                self.defaultEditor = Self.app(named: choice)?.bundleID ?? ""
            }
            Text("Return opens a project in this editor and ⌘K offers the others. Workspace files (.code-workspace) open in VS Code, Cursor, Windsurf or VSCodium, since other editors can't read them.").style(.caption)
            if choices.isEmpty {
                Text("No editor found on this Mac yet. VS Code, Cursor, Windsurf, VSCodium, Zed, Xcode, Sublime Text, Nova, BBEdit, TextMate, JetBrains IDEs and Android Studio show up here once installed.").style(.caption).role(.secondary)
            }
        }
    }

    // MARK: Commands

    var commands: [Command] {
        Command("search", title: "Search Recent Projects", subtitle: "Open a folder or workspace in your editor", symbol: "folder.badge.gearshape", keywords: ["project", "vscode", "code", "cursor", "windsurf", "recent", "open"])
            .view(search: { invocation in
                // Typing answers from the list read at launch, and again on the
                // timer or at wake, rather than reading every editor's list per keystroke.
                if self.loadedAt == nil { await self.load(force: true) }
                self.results = self.matches(invocation.text)
            }) { _ in
                if self.projects.isEmpty {
                    ContentUnavailableView("No recent projects", symbol: "folder", message: self.vsCodeMoved ? Self.vsCodeMovedText : "Open a folder in VS Code, Cursor, Windsurf or VSCodium and it shows up here.")
                } else if self.results.isEmpty {
                    ContentUnavailableView("No project matches", symbol: "magnifyingglass", message: "Type part of a project's name or path.")
                } else {
                    List {
                        ForEach(self.results) { project in self.row(project) }
                    }
                }
            }
            .rootSearch(section: "Recent Projects")
    }

    // MARK: Panel

    var panel: ViewContent {
        PanelHeader("Recent Projects", subtitle: found.isEmpty ? "No editor found yet" : found.joined(separator: " · "), symbol: "folder.badge.gearshape", theme: theme)
        if vsCodeMoved { Banner(Self.vsCodeMovedText, symbol: "info.circle", theme: .info) }
        if let first = problems.first { Banner("Couldn't read " + first, theme: .warning) }
        if projects.isEmpty {
            EmptyState("Open a project in your editor", symbol: "folder", message: "Folders and workspaces you open in VS Code, Cursor, Windsurf or VSCodium show up here and in the palette.", theme: theme)
        } else {
            List(projects, searchable: projects.count > 8) { project in self.row(project) }
        }
    }
}
