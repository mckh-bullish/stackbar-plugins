import StackbarKit
import Foundation

/// The folders and workspaces you opened lately in VS Code, Cursor,
/// Windsurf and VSCodium, in the palette: type a few letters of the project
/// and Return opens it in the editor you last used it in.
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

    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.recent-projects",
        name: "Recent Projects",
        version: "1.0.0",
        summary: "Open the projects you used lately in VS Code, Cursor, Windsurf or VSCodium from the palette.",
        surfaces: [.panel],
        triggers: [.launch],
        capabilities: [
            .run(commands: ["sqlite3"]),
            .files(paths: editors.map(\.folder)),
            .openURLs(schemes: editors.map(\.scheme)),
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
            plugin.loadedAt = Date()
        },
    ]

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
    }

    var projects: [Project] = []
    var loadedAt: Date?
    var found: [String] = []
    var results: [Project] = []
    @Stored("opens") var opens: [String: Int] = [:]
    @Stored("perEditor") var perEditor = 30

    // MARK: Reading

    func load(force: Bool = false) async {
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 60 { return }
        var all: [Project] = []
        var seen: [String] = []
        for editor in Self.editors {
            // An editor that isn't installed has no folder: the run is
            // refused and it is skipped.
            guard let result = try? await Stackbar.run("sqlite3", ["-readonly", "state.vscdb", "SELECT value FROM ItemTable WHERE key = 'history.recentlyOpenedPathsList'"], workingDirectory: editor.folder, timeout: .seconds(10)),
                  result.succeeded else { continue }
            let list = Self.parse(result.text, editor: editor.name)
            if !list.isEmpty { seen.append(editor.name) }
            all += list.prefix(perEditor)
        }
        // One row a path: the editor listed first (VS Code, then Cursor…)
        // keeps it.
        var paths = Set<String>()
        projects = all.filter { paths.insert($0.path).inserted }
        found = seen
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

    func open(_ project: Project, in editorName: String? = nil) {
        guard let editor = Self.editors.first(where: { $0.name == (editorName ?? project.editor) }) else { return }
        opens[project.path, default: 0] += 1
        let encoded = project.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? project.path
        Stackbar.open("\(editor.scheme)://file\(encoded)")
    }

    func row(_ project: Project) -> Row {
        let editor = Self.editors.first { $0.name == project.editor }
        var row = Row(project.name, subtitle: project.shortPath, symbol: project.kind == .workspace ? "square.stack.3d.up" : "folder", key: project.id)
            .appIcon(editor?.bundleID)
            .action("Open in \(project.editor)") { self.open(project) }
        for other in found where other != project.editor {
            row = row.action("Open in \(other)") { self.open(project, in: other) }
        }
        return row
            .action("Copy Path", shortcut: "cmd+shift+c") { Stackbar.copy(project.path) }
            .badge(project.editor, role: .secondary)
    }

    // MARK: Commands

    var commands: [Command] {
        Command("search", title: "Search Recent Projects", subtitle: "Open a folder or workspace in your editor", symbol: "folder.badge.gearshape", keywords: ["project", "vscode", "code", "cursor", "windsurf", "recent", "open"])
            .view(search: { invocation in
                await self.load()
                self.results = self.matches(invocation.text)
            }) { _ in
                if self.projects.isEmpty {
                    ContentUnavailableView("No recent projects", symbol: "folder", message: "Open a folder in VS Code, Cursor, Windsurf or VSCodium and it shows up here.")
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
        if projects.isEmpty {
            EmptyState("Open a project in your editor", symbol: "folder", message: "Folders and workspaces you open in VS Code, Cursor, Windsurf or VSCodium show up here and in the palette.", theme: theme)
        } else {
            Card("Latest", spacing: 0, padding: Space.s) {
                ForEach(Array(projects.prefix(8))) { project in self.row(project) }
            }
        }
    }
}
