import StackbarKit
import Foundation

/// The menu bar of the app you're in, searchable from the palette, as
/// Raycast's Search Menu Items and macOS's own Help menu search have it:
/// type "export" or "zoom" and Return chooses the item, so nothing in a
/// menu is more than a few letters away. Shortcuts show beside each item,
/// which is a quick way to learn them.
@main
final class MenuSearch: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.menu-search",
        name: "Menu Search",
        version: "1.1.0",
        summary: "Search the menus of the app you're in and choose an item without the mouse.",
        surfaces: [.panel],
        triggers: [.launch],
        // Reading the front app's menus and choosing an item.
        capabilities: [.menus],
        minimumStackbar: "0.31.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/System/MenuSearch",
        accent: .teal,
        symbol: "filemenu.and.selection"
    )

    static let previews: [PreviewScene<MenuSearch>] = [
        PreviewScene("hero", "Your most used menu items, one click away") { plugin in
            plugin.chosen = ["com.apple.Safari|File\u{1f}New Private Window": 9, "com.apple.dt.Xcode|Product\u{1f}Clean Build Folder…": 7,
                             "com.apple.Safari|View\u{1f}Zoom In": 4, "com.apple.Notes|Format\u{1f}Checklist": 3]
        },
        PreviewScene("first-run", "Every menu, a few letters away") { _ in },
    ]

    let theme = Theme.teal

    var menus: MenuSnapshot?
    var readAt: Date?
    var problem: String?
    var results: [MenuItemInfo] = []
    /// How often each item was chosen, by app id and path.
    @Stored("chosen") var chosen: [String: Int] = [:]

    /// Reads the menus when the view opens (nothing typed yet) or the last
    /// read is old: walking a big app's menus takes a moment, so typing
    /// reuses it.
    func load(force: Bool) async {
        // A failed read is remembered too (for a shorter while), so a broken
        // state doesn't repeat the walk on every keystroke.
        if !force, let readAt, Date().timeIntervalSince(readAt) < (menus != nil ? 30 : 5) { return }
        do {
            menus = try await Stackbar.menuItems()
            readAt = Date()
            problem = nil
        } catch {
            menus = nil
            readAt = Date()
            problem = "Can't read the menus: \(error)"
        }
    }

    // MARK: Matching

    static func key(_ appID: String, _ item: MenuItemInfo) -> String {
        "\(appID)|\(item.path.joined(separator: "\u{1f}"))"
    }

    /// How well `typed` matches `text`, or nil: the start beats the start of
    /// a word, which beats anywhere. Initials ("nw") and letters in order
    /// ("prvate") come last, so a typo still finds the item.
    static func score(_ typed: String, in text: String) -> Int? {
        let text = text.lowercased()
        if text == typed { return 1200 }
        if text.hasPrefix(typed) { return 1000 - min(text.count, 100) }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if words.contains(where: { $0.hasPrefix(typed) }) { return 800 - min(text.count, 100) }
        if text.contains(typed) { return 500 - min(text.count, 100) }
        if let match = TextMatch.match(typed, in: text) {
            switch match.tier {
            case .initials: return 450 - min(text.count, 100)
            case .inOrder: return 150 - min(text.count, 100)
            default: break
            }
        }
        return nil
    }

    /// The items matching `query`, best first. Every word typed must match
    /// the item's title or a menu above it, with the title worth more, so
    /// "view zoom" finds View › Zoom In. Dimmed items sink to the bottom.
    static func matches(_ query: String, in menus: MenuSnapshot, chosen: [String: Int] = [:], limit: Int = 60) -> [MenuItemInfo] {
        // "export..." is "export": dots and ellipses trail a name, they aren't in it.
        let words = query.lowercased().split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".…")) }.filter { !$0.isEmpty }
        guard !words.isEmpty else {
            return query.trimmingCharacters(in: .whitespaces).isEmpty ? Array(menus.items.prefix(limit)) : []
        }
        return menus.items.enumerated().compactMap { index, item -> (MenuItemInfo, Int, Int)? in
            var total = 0
            for word in words {
                let own = score(word, in: item.title)
                let above = item.path.dropLast().compactMap { score(word, in: $0) }.max().map { $0 / 2 }
                guard let best = [own, above].compactMap({ $0 }).max() else { return nil }
                total += best
            }
            let used = min(300, Int(60 * log2(1 + Double(chosen[key(menus.appID, item)] ?? 0))))
            return (item, total + used - (item.isEnabled ? 0 : 2000), index)
        }
        // Menu order on a tie, as the app arranged them.
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
        .prefix(limit)
        .map(\.0)
    }

    // MARK: Choosing

    func press(_ item: MenuItemInfo, in menus: MenuSnapshot) async throws {
        chosen[Self.key(menus.appID, item), default: 0] += 1
        try await Stackbar.pressMenuItem(appID: menus.appID, path: item.path)
    }

    func row(_ item: MenuItemInfo, in menus: MenuSnapshot) -> Row {
        let symbol = item.isChecked ? "checkmark" : "filemenu.and.selection"
        var row = Row(item.title, subtitle: item.isEnabled ? item.location : "\(item.location) · dimmed", symbol: symbol, key: item.path.joined(separator: "\u{1f}"))
            .appIcon(menus.appID)
        if let shortcut = item.shortcut { row = row.badge(shortcut, role: .secondary) }
        if item.isEnabled {
            row = row.action("Choose") { try await self.press(item, in: menus) }
        }
        return row.action("Copy Path", shortcut: "cmd+shift+c") { Stackbar.copy(item.path.joined(separator: " › ")) }
    }

    // MARK: Commands

    var commands: [Command] {
        Command("search", title: "Search Menu Items", subtitle: "Choose any menu item of the app you're in", symbol: "filemenu.and.selection", keywords: ["menu", "command", "action", "help"])
            .view(search: { invocation in
                await self.load(force: invocation.text.isEmpty)
                self.results = self.menus.map { Self.matches(invocation.text, in: $0, chosen: self.chosen) } ?? []
            }) { _ in
                if let problem = self.problem {
                    ContentUnavailableView("No menus", symbol: "exclamationmark.triangle", message: problem)
                } else if let menus = self.menus, !self.results.isEmpty {
                    List {
                        Section(menus.appName) {
                            ForEach(self.results) { item in self.row(item, in: menus) }
                        }
                    }
                } else {
                    ContentUnavailableView("No items match", symbol: "filemenu.and.selection", message: "Type part of a menu item, or the menu it's in.")
                }
            }
    }

    // MARK: Panel

    /// One of the most chosen items; `key` is the one `chosen` counts it by.
    struct Favourite: Identifiable {
        var key: String
        var appID: String
        var path: [String]
        var id: String { key }
    }

    /// The eight most chosen items, ties by key. A key that doesn't parse
    /// (no app, no menu) is skipped.
    var favourites: [Favourite] {
        chosen.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(8)
            .compactMap { key, _ in
                guard let bar = key.firstIndex(of: "|") else { return nil }
                let appID = String(key[..<bar])
                let path = key[key.index(after: bar)...].split(separator: "\u{1f}").map(String.init)
                guard !appID.isEmpty, !path.isEmpty else { return nil }
                return Favourite(key: key, appID: appID, path: path)
            }
    }

    var panel: ViewContent {
        PanelHeader("Menu Search", subtitle: "Search Menu Items in the palette", symbol: "filemenu.and.selection", theme: theme)
        let top = favourites
        if top.isEmpty {
            EmptyState("Every menu, a few letters away", symbol: "filemenu.and.selection", message: "In any app, open the palette, type Search Menu Items, then part of an item's name. Return chooses it. Stackbar needs Accessibility access for this.", theme: theme)
        } else {
            Card("Most chosen", spacing: 0, padding: Space.s) {
                ForEach(top) { favourite in
                    Row(favourite.path.last ?? "", subtitle: favourite.path.dropLast().joined(separator: " › "), symbol: "filemenu.and.selection", key: favourite.key)
                        .appIcon(favourite.appID)
                        .hiddenFromPalette()
                        .action("Choose") {
                            self.chosen[favourite.key, default: 0] += 1
                            try await Stackbar.pressMenuItem(appID: favourite.appID, path: favourite.path)
                        }
                }
            }
            Text("Search Menu Items in the palette for any other item.").role(.secondary).typography(.caption)
        }
    }
}
