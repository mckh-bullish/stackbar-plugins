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
        version: "1.2.1",
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
        minimumStackbar: "0.35.0",
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
        PreviewScene("browsers", "Safari, Chrome, Arc, Brave and Edge in one list") { plugin in
            plugin.tabs = [
                Tab(browser: "Safari", window: 1, index: 1, title: "Inbox · Fastmail", url: "https://app.fastmail.com/mail/Inbox"),
                Tab(browser: "Google Chrome", window: 1, index: 3, title: "Q4 roadmap — Docs", url: "https://docs.google.com/document/d/abc"),
                Tab(browser: "Arc", window: 1, index: 2, title: "Swift Forums", url: "https://forums.swift.org/"),
                Tab(browser: "Brave Browser", window: 2, index: 1, title: "Hacker News", url: "https://news.ycombinator.com/"),
                Tab(browser: "Microsoft Edge", window: 1, index: 1, title: "Azure Portal", url: "https://portal.azure.com/"),
            ]
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
    /// One line per tab: window, index, title and URL, split by tab
    /// characters. The separators are made before `tell`: inside it, `tab`
    /// is the browser's tab class, which joins as the word "tab", so no line
    /// would split and every browser would look empty.
    static func listScript(_ browser: Browser) -> String {
        let title = browser.safari ? "name of t" : "title of t"
        return """
        set sep to character id 9
        set nl to character id 10
        set out to ""
        tell application "\(browser.name)"
            repeat with w from 1 to (count of windows)
                set i to 0
                repeat with t in (tabs of window w)
                    set i to i + 1
                    set out to out & w & sep & i & sep & (\(title)) & sep & (URL of t) & nl
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
            // A title may hold tabs of its own, so the URL is the last field.
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4, let window = Int(fields[0]), let index = Int(fields[1]), let url = fields.last, !url.isEmpty, url != "missing value" else { return nil }
            let title = fields[2..<(fields.count - 1)].joined(separator: "\t")
            return Tab(browser: browser, window: window, index: index, title: title == "missing value" || title.isEmpty ? url : title, url: url)
        }
    }

    /// False when the browsers couldn't be listed, so the tabs kept are older
    /// than asked for.
    @discardableResult
    func loadTabs(force: Bool = false) async -> Bool {
        if !force, let tabsReadAt, Date().timeIntervalSince(tabsReadAt) < 5 { return true }
        var found: [Tab] = []
        var failed: [String] = []
        let running: Set<String>
        do {
            running = Set(try await Stackbar.runningApps().map(\.id))
        } catch {
            problems = ["Can't see which browsers are running: \(error)"]
            tabsReadAt = Date()
            return false
        }
        // One script per running browser, side by side: a browser stuck on a
        // dialog costs its own timeout, not everyone else's as well.
        let outcomes = await withTaskGroup(of: (Int, String?, String?).self) { group in
            for (position, browser) in Self.browsers.enumerated() where running.contains(browser.bundleID) {
                group.addTask {
                    guard let result = try? await Stackbar.run("osascript", ["-e", Self.listScript(browser)], timeout: .seconds(10)) else { return (position, nil, "it didn't answer") }
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
            } else if let errorText {
                failed.append("Couldn't read \(browser.name)'s tabs: \(errorText.split(separator: "\n").first.map(String.init) ?? "it didn't answer")")
            }
        }
        tabs = found
        problems = failed
        tabsReadAt = Date()
        return true
    }

    /// The tab as it is now, found by its page. Closing needs a sure match: the
    /// same slot with the same title, or the page's only tab. Switching takes
    /// the copy nearest the old place.
    func current(_ tab: Tab, fresh: Bool) async throws -> Tab {
        let read = await loadTabs(force: fresh)
        if fresh && !read { throw HostError("Couldn't check the tab. Try again.") }
        let pages = tabs.filter { $0.browser == tab.browser && $0.url == tab.url }
        let sameTitle = pages.filter { $0.title == tab.title }
        let candidates = sameTitle.isEmpty ? pages : sameTitle
        if fresh {
            if let slot = pages.first(where: { $0.window == tab.window && $0.index == tab.index }), slot.title == tab.title { return slot }
            guard let only = candidates.first, candidates.count == 1 else {
                if candidates.isEmpty { throw HostError("That tab has closed. Search your tabs again.") }
                throw HostError("More than one tab has that page. Close it from the browser.")
            }
            return only
        }
        // The copy in the same window nearest the old index, then any window.
        let nearest = candidates.min { lhs, rhs in
            (lhs.window == tab.window ? 0 : 1, abs(lhs.index - tab.index)) < (rhs.window == tab.window ? 0 : 1, abs(rhs.index - tab.index))
        }
        if let nearest { return nearest }
        throw HostError("That tab has closed. Search your tabs again.")
    }

    func focus(_ tab: Tab) async throws {
        let tab = try await current(tab, fresh: false)
        let safari = Self.browsers.first { $0.name == tab.browser }?.safari ?? false
        let result = try await Stackbar.run("osascript", ["-e", Self.focusScript(tab, safari: safari)], timeout: .seconds(10))
        guard result.succeeded else { throw HostError("Couldn't switch to the tab: \(result.errorText.prefix(160))") }
    }

    func close(_ tab: Tab) async throws {
        let tab = try await current(tab, fresh: true)
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
            guard let profile = browser.profile else { continue }
            let result: RunResult
            do {
                result = try await Stackbar.run("cat", ["Bookmarks"], workingDirectory: profile, timeout: .seconds(10))
            } catch {
                // No profile folder means the browser isn't installed: as quiet as a missing file.
                if !"\(error)".contains("is not a folder") {
                    failed.append("Couldn't read \(browser.name)'s bookmarks: \(error)")
                }
                continue
            }
            // A missing file means the browser isn't installed, so that stays quiet.
            guard result.succeeded else {
                if !result.errorText.contains("No such file") {
                    failed.append("Couldn't read \(browser.name)'s bookmarks: \(result.errorText.split(separator: "\n").first.map(String.init) ?? "it didn't answer")")
                }
                continue
            }
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

    /// A Markdown link to paste: brackets escaped in the title, parentheses and
    /// spaces percent-encoded in the address, so the link holds.
    static func markdownLink(title: String, url: String) -> String {
        let text = title.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        let address = url.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29").replacingOccurrences(of: " ", with: "%20")
        return "[\(text)](\(address))"
    }

    /// A panel row also hides from the palette: a tab read at launch may have
    /// closed or changed title since, and its actions would still be offered.
    func row(_ tab: Tab, inPanel: Bool = false) -> Row {
        let row = Row(tab.title, subtitle: Self.host(tab.url), symbol: "globe", key: tab.id)
            .appIcon(Self.browsers.first { $0.name == tab.browser }?.bundleID)
            .action("Switch to Tab") { try await self.focus(tab) }
            .action("Copy Link", shortcut: "cmd+shift+c") { Stackbar.copy(tab.url) }
            .action("Copy as Markdown Link") { Stackbar.copy(Self.markdownLink(title: tab.title, url: tab.url)) }
            .action("Close Tab", shortcut: "cmd+w", role: .critical, confirm: .none) { try await self.close(tab) }
        return inPanel ? row.hiddenFromPalette() : row
    }

    func row(_ bookmark: Bookmark) -> Row {
        let bundleID = Self.browsers.first { $0.name == bookmark.browser }?.bundleID
        return Row(bookmark.title, subtitle: [bookmark.folder, Self.host(bookmark.url)].filter { !$0.isEmpty }.joined(separator: " · "), symbol: "bookmark", key: bookmark.id)
            .appIcon(bundleID)
            .action("Open in \(bookmark.browser)") { try await Stackbar.open(bookmark.url, with: bundleID) }
            .action("Open in Default Browser") { Stackbar.open(bookmark.url) }
            .action("Copy Link", shortcut: "cmd+shift+c") { Stackbar.copy(bookmark.url) }
            .action("Copy as Markdown Link") { Stackbar.copy(Self.markdownLink(title: bookmark.title, url: bookmark.url)) }
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
        for problem in bookmarkProblems { Banner(problem, theme: .warning) }
        if tabs.isEmpty {
            EmptyState("Switch tabs from the palette", symbol: "rectangle.stack", message: "Open the palette, type Search Browser Tabs, then part of a page's title or address.", theme: theme)
        } else {
            Card("Open tabs", spacing: 0, padding: Space.s) {
                ForEach(Array(tabs.prefix(8))) { tab in self.row(tab, inPanel: true) }
            }
        }
    }
}
