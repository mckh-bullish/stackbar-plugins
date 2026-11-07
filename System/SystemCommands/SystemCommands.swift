import StackbarKit
import Foundation

/// Lock, sleep, restart and the rest, by name in the palette, as Raycast's
/// and Alfred's system commands are: type `lock`, `sleep`, `empty trash` or
/// `dark mode` and press Return. Restart, shut down, log out, emptying the
/// Trash and quitting other apps ask once more before they run.
@main
final class SystemCommands: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.system-commands",
        name: "System Commands",
        version: "1.0.1",
        summary: "Lock, sleep, restart, empty the Trash or switch to dark mode from the palette.",
        surfaces: [.panel],
        triggers: [.launch],
        capabilities: [.systemActions],
        minimumStackbar: "0.22.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/System/SystemCommands",
        accent: .graphite,
        symbol: "power.circle.fill"
    )

    let theme = Theme.graphite

    /// The commands, in the order the panel lists them.
    struct Item: Sendable {
        var action: SystemAction
        var id: String
        var symbol: String
        var subtitle: String
        var keywords: [String]
        /// What the HUD says after it ran, for the actions that leave you
        /// at the screen.
        var done: String?
    }

    static let items: [Item] = [
        Item(action: .lockScreen, id: "lock-screen", symbol: "lock.fill", subtitle: "Lock the Mac now", keywords: ["lock", "away"], done: nil),
        Item(action: .sleep, id: "sleep", symbol: "moon.zzz.fill", subtitle: "Put the Mac to sleep", keywords: ["sleep", "suspend"], done: nil),
        Item(action: .sleepDisplays, id: "sleep-displays", symbol: "display", subtitle: "Turn the screens off", keywords: ["display", "screen", "monitor", "off"], done: nil),
        Item(action: .startScreenSaver, id: "screen-saver", symbol: "sparkles.tv", subtitle: "Start the screen saver", keywords: ["screensaver"], done: nil),
        Item(action: .toggleDarkMode, id: "toggle-dark-mode", symbol: "circle.lefthalf.filled", subtitle: "Switch between light and dark", keywords: ["dark", "light", "appearance", "theme"], done: "Appearance switched"),
        Item(action: .hideOtherApps, id: "hide-other-apps", symbol: "eye.slash", subtitle: "Hide every app but the one you're in", keywords: ["hide", "focus"], done: "Other apps hidden"),
        Item(action: .ejectDisks, id: "eject-disks", symbol: "eject.fill", subtitle: "Eject every external disk and disk image", keywords: ["eject", "unmount", "usb", "disk"], done: "Disks ejected"),
        Item(action: .emptyTrash, id: "empty-trash", symbol: "trash.fill", subtitle: "Delete what's in the Trash for good", keywords: ["trash", "bin", "delete"], done: "Trash emptied"),
        Item(action: .quitOtherApps, id: "quit-other-apps", symbol: "xmark.app.fill", subtitle: "Quit every app but Finder and the one you're in", keywords: ["quit", "close", "all"], done: "Other apps quitting"),
        Item(action: .logOut, id: "log-out", symbol: "rectangle.portrait.and.arrow.right", subtitle: "Log out of this Mac", keywords: ["logout", "sign out"], done: nil),
        Item(action: .restart, id: "restart", symbol: "arrow.clockwise.circle.fill", subtitle: "Restart the Mac", keywords: ["reboot"], done: nil),
        Item(action: .shutDown, id: "shut-down", symbol: "power", subtitle: "Turn the Mac off", keywords: ["shutdown", "power off", "turn off"], done: nil),
    ]

    /// The destructive command clicked once in the panel, waiting for a
    /// second click.
    var armed: String?
    private var armedAt = Date.distantPast
    /// How long the second click stays good: a click much later starts over.
    static let armWindow: TimeInterval = 10

    /// The armed command, if its window hasn't passed.
    var armedNow: String? {
        armed.flatMap { Date().timeIntervalSince(armedAt) < Self.armWindow ? $0 : nil }
    }

    /// The row reads its window at every render (the panel renders again
    /// when it opens), so a click much later is a first click again.
    func arm(_ id: String) {
        armed = id
        armedAt = Date()
    }

    func perform(_ item: Item) async throws {
        try await Stackbar.system(item.action)
        if let done = item.done { Stackbar.hud(done) }
    }

    // MARK: Commands

    var commands: [Command] {
        return Self.items.map { item in
            if item.action.isDestructive {
                // A second Return, on a row that says what happens, before
                // anything is lost.
                return Command(item.id, title: item.action.title, subtitle: item.subtitle, symbol: item.symbol, keywords: item.keywords)
                    .view { _ in
                        List {
                            Row("\(item.action.title) Now", subtitle: item.subtitle, symbol: item.symbol, key: "confirm")
                                .action(item.action.title, role: .critical) { try await self.perform(item) }
                        }
                    }
            }
            return Command(item.id, title: item.action.title, subtitle: item.subtitle, symbol: item.symbol, keywords: item.keywords) { _ in
                try await Stackbar.system(item.action)
                return .message(item.done)
            }
        }
    }

    // MARK: Panel

    var panel: ViewContent {
        PanelHeader("System Commands", subtitle: "Type any of these in the palette", symbol: "power.circle.fill", theme: theme)
        Card("Now", spacing: 0, padding: Space.s) {
            ForEach(Self.items.filter { !$0.action.isDestructive }) { item in
                Row(item.action.title, subtitle: item.subtitle, symbol: item.symbol, key: item.id)
                    .action(item.action.title) { try await self.perform(item) }
            }
        }
        Card("Asks first", spacing: 0, padding: Space.s) {
            ForEach(Self.items.filter(\.action.isDestructive)) { item in
                if armedNow == item.id {
                    Row("Click again to \(item.action.title.lowercased())", subtitle: item.subtitle, symbol: item.symbol, key: item.id)
                        .action(item.action.title, role: .critical) {
                            // A stale confirmation counts as a first click.
                            guard self.armedNow == item.id else { return self.arm(item.id) }
                            self.armed = nil
                            try await self.perform(item)
                        }
                        .action("Cancel") { self.armed = nil }
                } else {
                    Row(item.action.title, subtitle: item.subtitle, symbol: item.symbol, key: item.id)
                        .action(item.action.title) { self.arm(item.id) }
                }
            }
        }
    }
}
