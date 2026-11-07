import StackbarKit
import Foundation

/// Your open browser tabs and your bookmarks in the palette, as Raycast's
/// browser extensions have them: type part of a page's title or address and
/// Return switches to that tab, or opens the bookmark.
///
/// Tabs come from Safari, Chrome, Arc, Brave and Edge while they run, read
/// with AppleScript (macOS asks once to let Stackbar control each browser).
/// Bookmarks come from the bookmark file Chrome, Brave, Edge and Vivaldi
/// keep; Safari's are behind Full Disk Access, so they aren't read.
@main
final class BrowserTabs: StackbarPlugin {
    struct Browser: Sendable {
        var name: String
        var bundleID: String
        /// AppleScript dialect for tabs: Safari's or Chromium's.
        var safari: Bool
        /// The profile folder holding `Bookmarks`, for Chromium browsers.
        var profile: String?
    }

    static let browsers: [Browser] = [
        Browser(name: "Safari", bundleID: "com.apple.Safari", safari: true),
        Browser(name: "Google Chrome", bundleID: "com.google.Chrome", safari: false, profile: "~/Library/Application Support/Google/Chrome/Default"),
        Browser(name: "Arc", bundleID: "company.thebrowser.Browser", safari: false),
        Browser(name: "Brave Browser", bundleID: "com.brave.Browser", safari: false, profile: "~/Library/Application Support/BraveSoftware/Brave-Browser/Default"),
        Browser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", safari: false, profile: "~/Library/Application Support/Microsoft Edge/Default"),
        Browser(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", safari: false, profile: "~/Library/Application Support/Vivaldi/Default"),
    ]

    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.browser-tabs",
        name: "Browser Tabs",
        version: "1.0.1",
        summary: "Switch to any open tab in Safari, Chrome, Arc, Brave or Edge, and search your bookmarks.",
        surfaces: [.panel],
        triggers: [.launch],
        capabilities: [
            .run(commands: ["osascript", "cat"]),
            // Which browsers are running, so a browser that isn't is never
            // started or asked for.
            .apps,
            .files(paths: browsers.compactMap(\.profile)),
        ],
        minimumStackbar: "0.22.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/BrowserTabs",
        accent: .cyan,
        symbol: "rectangle.stack.fill"
    )

    static let previews: [PreviewScene<BrowserTabs>] = [
        PreviewScene("hero", "Every tab, a few letters away") { plugin in
            plugin.tabs = [
                Tab(browser: "Safari", window: 1, index: 2, title: "Pull requests · navbytes/stackbar", url: "https://github.com/navbytes/stackbar/pulls"),
                Tab(browser: "Google Chrome", window: 1, index: 1, title: "Stackbar — your Mac, one keystroke away", url: "https://stackbar.app/"),
                Tab(browser: "Arc", window: 1, index: 4, title: "Swift Forums", url: "https://forums.swift.org/"),
            ]
            plugin.bookmarks = [Bookmark(title: "Apple Developer Documentation", url: "https://developer.apple.com/documentation/", folder: "Bookmarks Bar › Docs", browser: "Google Chrome")]
            plugin.tabsReadAt = Date()
        },
    ]

    let theme = Theme.cyan

    struct Tab: Equatable, Identifiable {
        var browser: String
        var window: Int
        var index: Int
        var title: String
        var url: String
        /// Lowercased once, so a keystroke doesn't allocate them again.
        let lowerTitle: String
        let lowerURL: String
        var id: String { "\(browser)|\(window)|\(index)" }

        init(browser: String, window: Int, index: Int, title: String, url: String) {
            (self.browser, self.window, self.index, self.title, self.url) = (browser, window, index, title, url)
            (lowerTitle, lowerURL) = (title.lowercased(), url.lowercased())
        }
    }

    struct Bookmark: Equatable, Identifiable {
        var title: String
        var url: String
        var folder: String
        var browser: String
        /// Lowercased once, at load: a profile can hold thousands of bookmarks.
        let lowerTitle: String
        let lowerURL: String
        var id: String { "\(browser)|\(folder)|\(url)" }

        init(title: String, url: String, folder: String, browser: String) {
            (self.title, self.url, self.folder, self.browser) = (title, url, folder, browser)
            (lowerTitle, lowerURL) = (title.lowercased(), url.lowercased())
        }
    }

    var tabs: [Tab] = []
    var tabsReadAt: Date?
    var bookmarks: [Bookmark] = []
    var bookmarksReadAt: Date?
    var problems: [String] = []
    var bookmarkProblems: [String] = []
    var tabResults: [Tab] = []
    var bookmarkResults: [Bookmark] = []

    // MARK: Tabs

    /// Prints `window⇥tab⇥title⇥url` a line for every tab. Only run for a
    /// browser that is running, so it never starts one.
    static func listScript(_ browser: Browser) -> String {
        let title = browser.safari ? "name of t" : "title of t"
        return """
        set out to ""
        tell application "\(browser.name)"
            repeat with w from 1 to (count of windows)
                set i to 0
                repeat with t in (tabs of window w)
                    set i to i + 1
                    set out to out & w & tab & i & tab & (\(title)) & tab & (URL of t) & linefeed
                end repeat
            end repeat
        end tell
        return out
        """
    }

    static func focusScript(_ tab: Tab, safari: Bool) -> String {
        if safari {
            return """
            tell application "Safari"
                set current tab of window \(tab.window) to tab \(tab.index) of window \(tab.window)
                set index of window \(tab.window) to 1
                activate
            end tell
            """
        }
        if tab.browser == "Arc" {
            return """
            tell application "Arc"
                tell tab \(tab.index) of window \(tab.window) to select
                activate
            end tell
            """
        }
        return """
        tell application "\(tab.browser)"
            set active tab index of window \(tab.window) to \(tab.index)
            set index of window \(tab.window) to 1
            activate
        end tell
        """
    }

    static func closeScript(_ tab: Tab) -> String {
        "tell application \"\(tab.browser)\" to close tab \(tab.index) of window \(tab.window)"
    }

    static func parseTabs(_ text: String, browser: String) -> [Tab] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, let window = Int(fields[0]), let index = Int(fields[1]), !fields[3].isEmpty, fields[3] != "missing value" else { return nil }
            return Tab(browser: browser, window: window, index: index, title: fields[2] == "missing value" || fields[2].isEmpty ? fields[3] : fields[2], url: fields[3])
        }
    }

    func loadTabs(force: Bool = false) async {
        if !force, let tabsReadAt, Date().timeIntervalSince(tabsReadAt) < 5 { return }
        var found: [Tab] = []
        var failed: [String] = []
        let running = Set(((try? await Stackbar.runningApps()) ?? []).map(\.id))
        // One script per running browser, side by side: a browser stuck on a
        // dialog costs its own timeout, not everyone else's as well.
        let outcomes = await withTaskGroup(of: (Int, String?, String?).self) { group in
            for (position, browser) in Self.browsers.enumerated() where running.contains(browser.bundleID) {
                group.addTask {
                    guard let result = try? await Stackbar.run("osascript", ["-e", Self.listScript(browser)], timeout: .seconds(10)) else { return (position, nil, nil) }
                    return (position, result.succeeded ? result.text : nil, result.succeeded ? nil : result.errorText)
                }
            }
            var all: [(Int, String?, String?)] = []
            for await outcome in group { all.append(outcome) }
            return all.sorted { $0.0 < $1.0 }
        }
        for (position, text, errorText) in outcomes {
            let browser = Self.browsers[position]
            if let text {
                found += Self.parseTabs(text, browser: browser.name)
            } else if let errorText, errorText.contains("-1743") || errorText.contains("Not authorized") {
                failed.append("Allow Stackbar to control \(browser.name) in System Settings › Privacy & Security › Automation.")
            }
        }
        tabs = found
        problems = failed
        tabsReadAt = Date()
    }

    func focus(_ tab: Tab) async throws {
        let safari = Self.browsers.first { $0.name == tab.browser }?.safari ?? false
        let result = try await Stackbar.run("osascript", ["-e", Self.focusScript(tab, safari: safari)], timeout: .seconds(10))
        guard result.succeeded else { throw HostError("Couldn't switch to the tab: \(result.errorText.prefix(160))") }
    }

    func close(_ tab: Tab) async throws {
        let result = try await Stackbar.run("osascript", ["-e", Self.closeScript(tab)], timeout: .seconds(10))
        guard result.succeeded else { throw HostError("Couldn't close the tab: \(result.errorText.prefix(160))") }
        await loadTabs(force: true)
    }

    // MARK: Bookmarks

    /// Chromium's `Bookmarks` JSON: `roots` of folders with `children`.
    static func parseBookmarks(_ data: Data, browser: String) -> [Bookmark] {
        struct Node: Decodable {
            var type: String?
            var name: String?
            var url: String?
            var children: [Node]?
        }
        struct File: Decodable { var roots: [String: Node] }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        var found: [Bookmark] = []
        func walk(_ node: Node, path: [String]) {
            if node.type == "url", let url = node.url, url.hasPrefix("http") {
                found.append(Bookmark(title: node.name?.isEmpty == false ? node.name! : url, url: url, folder: path.joined(separator: " › "), browser: browser))
            }
            for child in node.children ?? [] {
                walk(child, path: node.type == "folder" ? path + [node.name ?? ""] : path)
            }
        }
        for key in ["bookmark_bar", "other", "synced"] {
            if let root = file.roots[key] { walk(root, path: []) }
        }
        return Array(found.prefix(5000))
    }

    func loadBookmarks(force: Bool = false) async {
        if !force, let bookmarksReadAt, Date().timeIntervalSince(bookmarksReadAt) < 300 { return }
        var found: [Bookmark] = []
        var failed: [String] = []
        for browser in Self.browsers {
            guard let profile = browser.profile,
                  let result = try? await Stackbar.run("cat", ["Bookmarks"], workingDirectory: profile, timeout: .seconds(10)),
                  result.succeeded else { continue }
            // Output past 8 MB is cut and the JSON would not decode, so say so
            // instead of showing no bookmarks.
            if result.truncated {
                failed.append("\(browser.name)'s bookmarks file is too large to read.")
                continue
            }
            found += Self.parseBookmarks(result.stdout, browser: browser.name)
        }
        bookmarkProblems = failed
        var seen = Set<String>()
        bookmarks = found.filter { seen.insert($0.url).inserted }
        bookmarksReadAt = Date()
    }

    func refresh() async throws {
        await loadTabs(force: true)
        await loadBookmarks(force: true)
    }

    // MARK: Matching

    /// `title` and `url` give the lowercased text to match, which the items
    /// keep from when they were read.
    static func matches<Item>(_ query: String, in items: [Item], title: (Item) -> String, url: (Item) -> String) -> [Item] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return Array(items.prefix(80)) }
        return items.compactMap { item -> (Item, Int)? in
            let name = title(item)
            let address = url(item)
            var score = 0
            for word in words {
                if name.hasPrefix(word) { score += 300 } else if name.contains(word) { score += 200 } else if address.contains(word) { score += 100 } else { return nil }
            }
            return (item, score)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(80)
        .map(\.0)
    }

    static func host(_ url: String) -> String {
        URL(string: url)?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url
    }

    func row(_ tab: Tab) -> Row {
        Row(tab.title, subtitle: Self.host(tab.url), symbol: "globe", key: tab.id)
            .appIcon(Self.browsers.first { $0.name == tab.browser }?.bundleID)
            .action("Switch to Tab") { try await self.focus(tab) }
            .action("Copy Link", shortcut: "cmd+shift+c") { Stackbar.copy(tab.url) }
            .action("Close Tab", shortcut: "cmd+w", role: .critical) { try await self.close(tab) }
    }

    func row(_ bookmark: Bookmark) -> Row {
        let bundleID = Self.browsers.first { $0.name == bookmark.browser }?.bundleID
        return Row(bookmark.title, subtitle: [bookmark.folder, Self.host(bookmark.url)].filter { !$0.isEmpty }.joined(separator: " · "), symbol: "bookmark", key: bookmark.id)
            .appIcon(bundleID)
            .action("Open in \(bookmark.browser)") { try await Stackbar.open(bookmark.url, with: bundleID) }
            .action("Open in Default Browser") { Stackbar.open(bookmark.url) }
            .action("Copy Link", shortcut: "cmd+shift+c") { Stackbar.copy(bookmark.url) }
    }

    // MARK: Commands

    var commands: [Command] {
        Command("tabs", title: "Search Browser Tabs", subtitle: "Switch to any open tab", symbol: "rectangle.stack", keywords: ["tab", "browser", "safari", "chrome", "arc", "switch"])
            .view(search: { invocation in
                await self.loadTabs(force: invocation.text.isEmpty)
                self.tabResults = Self.matches(invocation.text, in: self.tabs, title: \.lowerTitle, url: \.lowerURL)
            }) { _ in
                if self.tabResults.isEmpty {
                    ContentUnavailableView(self.tabs.isEmpty ? "No tabs open" : "No tab matches", symbol: "rectangle.stack", message: self.problems.first ?? "Tabs in Safari, Chrome, Arc, Brave and Edge show up here while they run.")
                } else {
                    List {
                        ForEach(self.tabResults) { tab in self.row(tab) }
                    }
                }
            }
        Command("bookmarks", title: "Search Bookmarks", subtitle: "From Chrome, Brave, Edge and Vivaldi", symbol: "bookmark", keywords: ["bookmark", "favorite", "browser", "chrome"])
            .view(search: { invocation in
                await self.loadBookmarks()
                self.bookmarkResults = Self.matches(invocation.text, in: self.bookmarks, title: \.lowerTitle, url: \.lowerURL)
            }) { _ in
                if self.bookmarkResults.isEmpty {
                    ContentUnavailableView(self.bookmarks.isEmpty ? "No bookmarks found" : "No bookmark matches", symbol: "bookmark", message: self.bookmarkProblems.first ?? "Bookmarks from Chrome, Brave, Edge and Vivaldi show up here. Safari keeps its bookmarks private.")
                } else {
                    List {
                        ForEach(self.bookmarkResults) { bookmark in self.row(bookmark) }
                    }
                }
            }
    }

    // MARK: Panel

    var panel: ViewContent {
        PanelHeader("Browser Tabs", subtitle: "\(tabs.count) tabs · \(bookmarks.count) bookmarks", symbol: "rectangle.stack.fill", theme: theme)
        for problem in problems { Banner(problem, theme: .warning) }
        if tabs.isEmpty {
            EmptyState("Switch tabs from the palette", symbol: "rectangle.stack", message: "Open the palette, type Search Browser Tabs, then part of a page's title or address.", theme: theme)
        } else {
            Card("Open tabs", spacing: 0, padding: Space.s) {
                ForEach(Array(tabs.prefix(8))) { tab in self.row(tab) }
            }
        }
    }
}
