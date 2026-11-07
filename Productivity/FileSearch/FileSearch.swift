import StackbarKit
import Foundation

/// Files and folders by name in the command palette, from Spotlight's index:
/// type three letters or more and the best matches show under Files, most
/// recently used first. Return opens one; ⌘K shows it in Finder or copies
/// its path. Apps, hidden files and Library internals are left out.
@main
final class FileSearch: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.file-search",
        name: "File Search",
        version: "1.0.1",
        summary: "Find files and folders by name from the command palette, most recently used first.",
        surfaces: [.panel],
        triggers: [.launch],
        // Names from Spotlight; opening what you pick, in its app.
        capabilities: [.fileSearch, .openURLs(schemes: ["*"])],
        minimumStackbar: "0.20.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/FileSearch",
        accent: .cyan,
        symbol: "doc.text.magnifyingglass"
    )

    static let previews: [PreviewScene<FileSearch>] = [
        PreviewScene("hero", "Any file, a few letters away") { plugin in
            plugin.recent = try await Stackbar.findFiles("plan")
        },
    ]

    let theme = Theme.cyan

    var results: [FoundFile] = []
    var problem: String?
    /// What was opened from here lately, for the panel.
    var recent: [FoundFile] = []

    /// Shorter text matches half the disk.
    static let minimumLength = 3

    func search(_ text: String, limit: Int) async {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text.count >= Self.minimumLength else {
            results = []
            problem = nil
            return
        }
        do {
            results = try await Stackbar.findFiles(text, limit: limit)
            problem = nil
        } catch {
            results = []
            problem = "Spotlight didn't answer: \(error)"
        }
    }

    func open(_ file: FoundFile) {
        recent = Array(([file] + recent.filter { $0.path != file.path }).prefix(8))
        Stackbar.open(file.path)
    }

    static func folder(of file: FoundFile) -> String {
        URL(fileURLWithPath: file.path).deletingLastPathComponent().path
    }

    func row(_ file: FoundFile) -> Row {
        Row(file.name, subtitle: file.folder, symbol: file.isFolder ? "folder" : "doc", key: file.path)
            .fileIcon(file.path)
            .action("Open") { self.open(file) }
            .action("Show in Finder", shortcut: "cmd+return") { Stackbar.open(Self.folder(of: file)) }
            .action("Copy Path", shortcut: "cmd+shift+c") { Stackbar.copy(file.path) }
    }

    // MARK: Commands

    var commands: [Command] {
        Command("search", title: "Search Files", subtitle: "Find a file or folder by name", symbol: "doc.text.magnifyingglass", keywords: ["file", "folder", "find", "spotlight", "document"])
            .view(search: { invocation in
                await self.search(invocation.text, limit: 20)
            }) { invocation in
                if let problem = self.problem {
                    ContentUnavailableView("Can't search", symbol: "exclamationmark.triangle", message: problem)
                } else if invocation.text.trimmingCharacters(in: .whitespaces).count < Self.minimumLength {
                    ContentUnavailableView("Type a file name", symbol: "doc.text.magnifyingglass", message: "Three letters or more. Every word must be in the name.")
                } else if self.results.isEmpty {
                    ContentUnavailableView("No files found", symbol: "doc.questionmark", message: "Spotlight has nothing by that name in your home folder.")
                } else {
                    List {
                        ForEach(self.results) { file in self.row(file) }
                    }
                }
            }
            .rootSearch(section: "Files")
    }

    // MARK: Panel

    var panel: ViewContent {
        PanelHeader("File Search", subtitle: "Type a file name in the palette", symbol: "doc.text.magnifyingglass", theme: theme)
        if recent.isEmpty {
            EmptyState("Find files from the palette", symbol: "doc.text.magnifyingglass", message: "Press ⌃⌥Space and type three letters or more of a file's name. Return opens it; ⌘K shows it in Finder.", theme: theme)
        } else {
            Card("Opened lately", spacing: 0, padding: Space.s) {
                ForEach(recent) { file in self.row(file) }
            }
        }
    }
}
