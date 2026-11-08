import StackbarKit
import Foundation

/// Every open window in the command palette, as Raycast's Switch Windows
/// and Alfred's window switcher have them: type a few letters of the app or
/// the window's title ("pull", "slack") and Return brings that window to the
/// front, out of the Dock if it was minimized.
@main
final class WindowSwitcher: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.window-switcher",
        name: "Window Switcher",
        version: "1.1.0",
        summary: "Jump to any open window by typing part of its app or title in the palette.",
        surfaces: [.panel],
        triggers: [.launch, .apps],
        // Listing windows and bringing one to the front.
        capabilities: [.windows],
        minimumStackbar: "0.31.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/WindowSwitcher",
        accent: .indigo,
        symbol: "macwindow.on.rectangle"
    )

    static let previews: [PreviewScene<WindowSwitcher>] = [
        PreviewScene("hero", "Any window, a few letters away") { plugin in
            plugin.snapshot = WindowSwitcher.sample(displays: 1)
            plugin.readAt = Date()
        },
        PreviewScene("displays", "Says which display each window is on") { plugin in
            plugin.snapshot = WindowSwitcher.sample(displays: 2)
            plugin.readAt = Date()
        },
    ]

    let theme = Theme.indigo

    var snapshot = WindowSnapshot()
    var problem: String?
    var results: [WindowInfo] = []

    var readAt: Date?

    /// Reads the windows when the view opens (nothing typed yet) or the last
    /// read is a few seconds old: listing them over Accessibility waits on
    /// every unresponsive app, so typing reuses the snapshot. A failed read
    /// counts too, so a broken state doesn't retry on every keystroke.
    func load(force: Bool = true) async {
        if !force, let readAt, Date().timeIntervalSince(readAt) < 3 { return }
        readAt = Date()
        do {
            snapshot = try await Stackbar.windows()
            problem = nil
        } catch {
            problem = "Can't list your windows: \(error)"
        }
    }

    func refresh() async throws {
        // A burst of app launches (.apps) would otherwise scan every window once per launch.
        if Stackbar.refreshReason == .apps, let readAt, Date().timeIntervalSince(readAt) < 2 { return }
        await load()
    }

    // MARK: Previews

    /// Made-up windows for the store: all on one display, or with Slack and
    /// Mail on the laptop beside a desk display.
    static func sample(displays: Int) -> WindowSnapshot {
        let desk = DisplayInfo(id: "9C1E4F2B-7A1D-4E59-8C3A-5B2F6D0E1A44", name: "Studio Display", frame: WindowRect(x: 0, y: 0, width: 2560, height: 1440), visibleFrame: WindowRect(x: 0, y: 33, width: 2560, height: 1407), isMain: true)
        let laptop = DisplayInfo(id: "37D8832A-2D66-02CA-B9F7-8F30A301B230", name: "Built-in Retina Display", frame: WindowRect(x: 2560, y: 458, width: 1512, height: 982), isBuiltIn: true)
        let twoScreens = displays > 1
        let beside = twoScreens ? laptop.id : desk.id
        let besideFrame = twoScreens ? WindowRect(x: 2560, y: 458, width: 1512, height: 982) : WindowRect(x: 1700, y: 200, width: 900, height: 800)
        return WindowSnapshot(displays: twoScreens ? [desk, laptop] : [desk], windows: [
            WindowInfo(appID: "com.apple.dt.Xcode", appName: "Xcode", title: "Stackbar — Windows.swift", frame: WindowRect(x: 0, y: 33, width: 1700, height: 1407), displayID: desk.id, order: 0),
            WindowInfo(appID: "com.apple.Safari", appName: "Safari", title: "Pull requests", frame: WindowRect(x: 400, y: 200, width: 1200, height: 900), displayID: desk.id, order: 1),
            WindowInfo(appID: "com.tinyspeck.slackmacgap", appName: "Slack", title: "#design", frame: besideFrame, displayID: beside, order: 2),
            WindowInfo(appID: "com.apple.Notes", appName: "Notes", title: "Groceries", frame: WindowRect(x: 1700, y: 33, width: 860, height: 1407), displayID: desk.id, order: 3),
            WindowInfo(appID: "com.apple.mail", appName: "Mail", title: "Inbox", frame: besideFrame, displayID: beside, order: 4),
            WindowInfo(appID: "com.apple.Safari", appName: "Safari", title: "Swift Forums", frame: WindowRect(x: 400, y: 200, width: 1200, height: 900), displayID: desk.id, order: 5, isMinimized: true),
        ])
    }

    // MARK: Matching

    /// What a window is called in the list: its title, or the app's name
    /// for a window without one.
    static func title(_ window: WindowInfo) -> String {
        window.title.isEmpty ? window.appName : window.title
    }

    /// How well `typed` matches `text`, or nil: the start beats the start of
    /// a word, which beats anywhere, which beats letters in order.
    static func score(_ typed: String, in text: String) -> Int? {
        let text = text.lowercased()
        guard !typed.isEmpty else { return nil }
        if text == typed { return 1200 }
        if text.hasPrefix(typed) { return 1000 - min(text.count, 100) }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if words.contains(where: { $0.hasPrefix(typed) }) { return 800 - min(text.count, 100) }
        if text.contains(typed) { return 500 - min(text.count, 100) }
        var rest = Substring(typed)
        for character in text where character == rest.first {
            rest.removeFirst()
            if rest.isEmpty { return 200 - min(text.count, 100) }
        }
        return nil
    }

    /// The windows matching `query`, best first; every window front to
    /// back when nothing is typed. Each word typed must match the app or
    /// the title, so "saf pull" finds Safari's Pull requests window.
    static func matches(_ query: String, in windows: [WindowInfo], limit: Int = 50) -> [WindowInfo] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return Array(windows.prefix(limit)) }
        return windows.compactMap { window -> (WindowInfo, Int)? in
            var total = 0
            for word in words {
                guard let best = [window.appName, window.title].compactMap({ score(word, in: $0) }).max() else { return nil }
                total += best
            }
            // Nearer the front wins a tie.
            return (window, total - window.order)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(limit)
        .map(\.0)
    }

    // MARK: Switching

    func focus(_ window: WindowInfo) async throws {
        try await Stackbar.focusWindow(WindowTarget(window, in: snapshot))
    }

    /// A panel row also hides from the palette, where a window that closed
    /// hours ago would otherwise still be offered.
    func row(_ window: WindowInfo, inPanel: Bool = false) -> Row {
        var detail = window.title.isEmpty ? nil : window.appName
        if window.isMinimized { detail = [detail, "Minimized"].compactMap { $0 }.joined(separator: " · ") }
        var row = Row(Self.title(window), subtitle: detail, symbol: "macwindow", key: "\(window.appID)#\(window.order)")
            .appIcon(window.appID)
            .action("Switch to Window") { try await self.focus(window) }
            .action("Copy Title", shortcut: "cmd+shift+c") { Stackbar.copy(Self.title(window)) }
        if let display = snapshot.displays.first(where: { $0.id == window.displayID }), snapshot.displays.count > 1 {
            row = row.badge(display.name, role: .secondary)
        }
        if inPanel { row = row.hiddenFromPalette() }
        return row
    }

    // MARK: Commands

    var commands: [Command] {
        Command("switch", title: "Switch Windows", subtitle: "Bring any open window to the front", symbol: "macwindow.on.rectangle", keywords: ["window", "switch", "focus", "tab"])
            .view(search: { invocation in
                await self.load(force: invocation.text.isEmpty)
                self.results = Self.matches(invocation.text, in: self.snapshot.windows)
            }) { _ in
                if let problem = self.problem {
                    ContentUnavailableView("No windows", symbol: "exclamationmark.triangle", message: problem)
                } else if self.results.isEmpty {
                    ContentUnavailableView("No windows match", symbol: "macwindow", message: "Type part of an app's name or a window's title.")
                } else {
                    List {
                        ForEach(self.results) { window in self.row(window) }
                    }
                }
            }
    }

    // MARK: Panel

    var panel: ViewContent {
        PanelHeader("Window Switcher", subtitle: "\(snapshot.windows.count) windows · as of \(readAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—")", symbol: "macwindow.on.rectangle", theme: theme) {
            IconButton("arrow.clockwise", label: "Refresh", theme: theme) { await self.load() }
        }
        if let problem {
            Banner(problem, theme: .warning)
        }
        if snapshot.windows.isEmpty {
            EmptyState("Jump to any window", symbol: "macwindow.on.rectangle", message: "Open the palette, type Switch Windows, then a few letters of the app or the title. Return brings it to the front.", theme: theme)
        } else {
            Card("Open now", spacing: 0, padding: Space.s) {
                ForEach(Array(snapshot.windows.prefix(8))) { window in self.row(window, inPanel: true) }
            }
        }
    }
}
