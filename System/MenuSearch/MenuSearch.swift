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
        version: "1.0.0",
        summary: "Search the menus of the app you're in and choose an item without the mouse.",
        surfaces: [.panel],
        triggers: [.launch],
        // Reading the front app's menus and choosing an item.
        capabilities: [.menus],
        minimumStackbar: "0.25.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/System/MenuSearch",
        accent: .teal,
        symbol: "filemenu.and.selection"
    )

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
        if !force, menus != nil, let readAt, Date().timeIntervalSince(readAt) < 30 { return }
        do {
            menus = try await Stackbar.menuItems()
            readAt = Date()
            problem = nil
        } catch {
            menus = nil
            problem = "Can't read the menus: \(error)"
        }
    }

    // MARK: Matching

    static func key(_ appID: String, _ item: MenuItemInfo) -> String {
        "\(appID)|\(item.path.joined(separator: "\u{1f}"))"
    }

    /// How well `typed` matches `text`, or nil: the start beats the start of
    /// a word, which beats anywhere.
    static func score(_ typed: String, in text: String) -> Int? {
        let text = text.lowercased()
        if text == typed { return 1200 }
        if text.hasPrefix(typed) { return 1000 - min(text.count, 100) }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if words.contains(where: { $0.hasPrefix(typed) }) { return 800 - min(text.count, 100) }
        if text.contains(typed) { return 500 - min(text.count, 100) }
        return nil
    }

    /// The items matching `query`, best first. Every word typed must match
    /// the item's title or a menu above it, with the title worth more, so
    /// "view zoom" finds View › Zoom In. Dimmed items sink to the bottom.
    static func matches(_ query: String, in menus: MenuSnapshot, chosen: [String: Int] = [:], limit: Int = 60) -> [MenuItemInfo] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return Array(menus.items.prefix(limit)) }
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

    var panel: ViewContent {
        PanelHeader("Menu Search", subtitle: "Search Menu Items in the palette", symbol: "filemenu.and.selection", theme: theme)
        EmptyState("Every menu, a few letters away", symbol: "filemenu.and.selection", message: "In any app, open the palette, type Search Menu Items, then part of an item's name. Return chooses it. Stackbar needs Accessibility access for this.", theme: theme)
    }
}
