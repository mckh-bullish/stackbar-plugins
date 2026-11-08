import StackbarKit
import Foundation

/// Switch apps without ⌘Tab: hold Right ⌘ and press an app's first letter.
/// Pressing the letter again moves to the next app with that letter, or hides
/// the app when it is the only one. Pin a letter to an app with Right ⌘ ⌥ and
/// the letter, and that letter opens the app even when it isn't running.
/// Holding Right ⌘ on its own shows the letter map. The host listens to the
/// keyboard and switches inside the key press, so it stays instant. Needs
/// `.keyLayer` and `.apps`, and Accessibility access for Stackbar.
@main
final class AppSwitcher: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.app-switcher",
        name: "App Switcher",
        version: "1.3.0",
        summary: "Hold Right ⌘ and press an app's first letter to switch to it. Press again to cycle or hide.",
        surfaces: [.menuBar, .panel, .settings],
        triggers: [.launch, .apps, .every(.seconds(60))],
        capabilities: [.apps, .keyLayer, .openURLs(schemes: ["x-apple.systempreferences"])],
        minimumStackbar: "0.21.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/AppSwitcher",
        accent: .indigo,
        symbol: "command"
    )

    // MARK: Previews

    static let previews: [PreviewScene<AppSwitcher>] = [
        PreviewScene("hero", "Hold Right ⌘ and press a letter") { plugin in
            plugin.apps = sampleApps
            plugin.pins = ["m": ["com.apple.mail"], "t": ["com.apple.Terminal"]]
            plugin.pinNames = ["com.apple.mail": "Mail", "com.apple.Terminal": "Terminal"]
        },
        PreviewScene("pinned", "Pinned letters open apps that aren't running") { plugin in
            plugin.apps = sampleApps.filter { $0.name != "Notes" }
            plugin.pins = ["n": ["com.apple.Notes"], "m": ["com.apple.mail"], "t": ["com.apple.Terminal"]]
            plugin.pinNames = ["com.apple.Notes": "Notes", "com.apple.mail": "Mail", "com.apple.Terminal": "Terminal"]
        },
        PreviewScene("settings", "Pick the key you hold", surface: .settings) { plugin in
            plugin.apps = sampleApps
            plugin.pins = ["m": ["com.apple.mail"], "t": ["com.apple.Terminal"]]
            plugin.pinNames = ["com.apple.mail": "Mail", "com.apple.Terminal": "Terminal"]
        },
    ]

    static let sampleApps = [
        RunningApp(id: "com.apple.finder", name: "Finder"),
        RunningApp(id: "com.apple.Safari", name: "Safari", isActive: true),
        RunningApp(id: "com.tinyspeck.slackmacgap", name: "Slack"),
        RunningApp(id: "com.spotify.client", name: "Spotify"),
        RunningApp(id: "com.apple.dt.Xcode", name: "Xcode"),
        RunningApp(id: "com.apple.Notes", name: "Notes"),
        RunningApp(id: "com.figma.Desktop", name: "Figma"),
        RunningApp(id: "com.apple.iCal", name: "Calendar"),
        RunningApp(id: "com.apple.Terminal", name: "Terminal"),
    ]

    let theme = Theme.indigo

    /// Pinned letters: key → bundle ids (one app per pinned key).
    @Stored("pins") var pins: [String: [String]] = [:]
    /// Names of pinned apps, for when they aren't running.
    @Stored("pinNames") var pinNames: [String: String] = [:]
    /// Apps left out of the letters: they get no letter of their own (a pin still wins).
    @Stored("skipped") var skipped: [String] = []
    @Stored("trigger") var trigger = KeyLayerTrigger.rightCommand.rawValue
    @Stored("secondPress") var secondPress = SecondPress.hide.rawValue
    @Stored("autoLetters") var autoLetters = true
    @Stored("openPinned") var openPinned = true
    @Stored("overlay") var overlay = true
    /// Off by default: the switcher lives on a held key, so the icon only
    /// shows up when the key stops working.
    @Stored("menuBarIcon") var menuBarIcon = false

    var apps: [RunningApp] = []
    var status: KeyLayerStatus?
    var problem: String?
    var notice: String?
    /// The layer last sent, so an unchanged map isn't sent again.
    var sent: KeyLayer?
    /// When "Clear every pin" was last clicked: a second click within 10 seconds clears.
    var clearArmedAt = Date.distantPast
    var clearArmed: Bool { Date().timeIntervalSince(clearArmedAt) < 10 }

    func refresh() async throws {
        do {
            apps = try await Stackbar.runningApps()
            problem = nil
        } catch {
            problem = "\(error)"
        }
        await apply()
    }

    // MARK: - The map

    var triggerKey: KeyLayerTrigger { KeyLayerTrigger(rawValue: trigger) ?? .rightCommand }
    var secondPressMode: SecondPress { SecondPress(rawValue: secondPress) ?? .hide }
    var assignKey: String { triggerKey == .rightOption ? "Right ⌘" : "Right ⌥" }

    var layer: KeyLayer {
        KeyLayer(trigger: triggerKey, bindings: Self.bindings(running: apps, pins: pins, autoLetters: autoLetters, openPinned: openPinned, skipped: Set(skipped)), secondPress: secondPressMode, assignCommand: "assign", overlay: overlay)
    }

    /// The letter an app gets on its own: the first letter or digit of its
    /// name, accents folded ("Écrit" → e). Nil for names with none.
    static func letter(for name: String) -> String? {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return folded.unicodeScalars.lazy.map(String.init).first(where: KeyBinding.isValidKey)
    }

    /// Pinned apps first on their key (and opened when closed if
    /// `openPinned`), then running apps on their own letter in launch order.
    /// A pinned app only lives on its pinned key, and an app left out of the
    /// letters takes none of its own.
    static func bindings(running: [RunningApp], pins: [String: [String]], autoLetters: Bool, openPinned: Bool, skipped: Set<String>) -> [KeyBinding] {
        let pinned = Set(pins.values.flatMap { $0 })
        var byKey: [String: [String]] = pins.filter { KeyBinding.isValidKey($0.key) && !$0.value.isEmpty }
        if autoLetters {
            for app in running where !pinned.contains(app.id) && !skipped.contains(app.id) {
                guard let key = letter(for: app.name) else { continue }
                if !(byKey[key] ?? []).contains(app.id) { byKey[key, default: []].append(app.id) }
            }
        }
        return byKey.keys.sorted().map { key in
            let isPinned = pins[key]?.isEmpty == false
            return KeyBinding(key: key, apps: Array(byKey[key]!.prefix(KeyLayer.maxAppsPerKey)), launch: openPinned && isPinned)
        }
    }

    func apply() async {
        let next = layer
        do {
            status = next == sent ? try await Stackbar.keyLayerStatus() : try await Stackbar.setKeyLayer(next)
            sent = next
        } catch {
            problem = "\(error)"
        }
    }

    func name(of id: String) -> String {
        apps.first { $0.id == id }?.name ?? pinNames[id] ?? id
    }

    func isRunning(_ id: String) -> Bool { apps.contains { $0.id == id } }

    // MARK: - Actions

    /// Pins `key` to the app (from the chord: the app in front), by bundle id
    /// or by the name of an installed app. Pinning the same app to the same
    /// key again unpins it.
    func assign(key rawKey: String, app id: String) async -> CommandResult {
        let key = rawKey.lowercased()
        guard KeyBinding.isValidKey(key) else { return .failure("Pin a letter or digit") }
        let typed = id.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return .failure("No app is in front") }
        if let fresh = try? await Stackbar.runningApps() { apps = fresh }
        let appID: String
        if isRunning(typed) { appID = typed }
        else if let found = try? await Stackbar.resolveApplication(typed) { appID = found }
        else { return .failure("No app called \(typed) is installed. Type its name, like Safari, or its bundle id.") }
        var name = name(of: appID)
        if name == appID, let installed = try? await Stackbar.installedApps(), let match = installed.first(where: { $0.id == appID }) { name = match.name }
        if pins[key] == [appID] {
            pins[key] = nil
            notice = "\(key.uppercased()) is no longer pinned to \(name)"
        } else {
            for other in pins.keys where pins[other]?.contains(appID) == true { pins[other] = nil }
            pins[key] = [appID]
            pinNames[appID] = name
            notice = "\(triggerKey.title) \(key.uppercased()) now opens \(name)"
        }
        await apply()
        return .message(notice)
    }

    func unpin(_ key: String) async {
        guard let id = pins[key]?.first else { return }
        pins[key] = nil
        notice = "\(key.uppercased()) is no longer pinned to \(name(of: id))"
        await apply()
    }

    func set(_ change: () -> Void) async {
        change()
        await apply()
    }

    /// Brings the app forward (or opens it), and says in the panel why it can't.
    func activate(_ id: String, launch: Bool = false) async {
        do { try await Stackbar.activateApp(id, launch: launch) } catch { notice = "Couldn't open \(name(of: id)): \(error)" }
    }

    // MARK: - Surfaces

    /// Whether something the user must fix stops the key from working.
    /// Secure Input is left out: it passes once a password field is left.
    var needsAttention: Bool {
        problem != nil || status?.needsAccessibility == true || status?.conflict != nil
    }

    var menuBar: ViewContent {
        if menuBarIcon || needsAttention {
            Label("", symbol: status?.listening == false ? "command.circle" : "command").role(needsAttention ? .warning : .secondary)
        }
    }

    @ViewBuilder var statusBanner: ViewContent {
        if let problem {
            Banner(problem, theme: .warning)
        } else if let status {
            if status.needsAccessibility {
                Banner("Stackbar needs Accessibility access to hear \(triggerKey.title).", theme: .warning) {
                    ActionButton("Open Settings", theme: theme, key: "accessibility") {
                        Stackbar.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                    }
                }
            } else if let conflict = status.conflict {
                Banner("\(conflict) already uses \(triggerKey.title). Pick another key in Settings.", theme: .warning)
            } else if let app = status.secureInputApp {
                Banner("Paused: \(app) has Secure Input on, which blocks every keyboard shortcut app. It goes off when you leave the password field, or quit \(app).", theme: .warning)
            }
        }
    }

    var panel: ViewContent {
        let bindings = layer.bindings
        PanelHeader("App Switcher", subtitle: "Hold \(triggerKey.title) and press a letter", symbol: "command", theme: theme) {
            IconButton("arrow.clockwise", label: "Look again", theme: theme, key: "reload") { try await self.refresh() }
        }
        statusBanner
        if let notice {
            Banner(notice, symbol: "pin.fill", theme: theme) {
                IconButton("xmark", label: "Dismiss", theme: theme, key: "dismiss") { self.notice = nil }
            }
        }
        if bindings.isEmpty {
            EmptyState("No letters yet", symbol: "keyboard", message: "Open some apps, or pin one: bring it to the front and press \(triggerKey.title) \(assignKey) and a letter.", theme: theme)
        } else {
            Card("Letters", detail: "\(bindings.count)", spacing: 0, padding: Space.s) {
                ForEach(bindings) { binding in self.row(binding) }
            }
            Text("Pin a letter: bring the app to the front and press \(triggerKey.title) \(assignKey) and the letter. Pressing it again unpins.")
                .role(.secondary).typography(.caption)
        }
    }

    private func row(_ binding: KeyBinding) -> ViewContent {
        let isPinned = pins[binding.key]?.isEmpty == false
        let pinnedApps = Set(pins.values.flatMap { $0 })
        let names = binding.apps.map(name(of:))
        let running = binding.apps.filter(isRunning)
        var detail: [String] = []
        if isPinned { detail.append(binding.launch ? "pinned, opens when closed" : "pinned") }
        if binding.apps.count > 1 { detail.append("press again for the next") }
        if running.isEmpty { detail.append("not running") }
        var row = Row(names.joined(separator: ", "), subtitle: detail.isEmpty ? nil : detail.joined(separator: " · "), symbol: isPinned ? "pin.fill" : "app", key: "key-\(binding.key)")
            .appIcon(running.first ?? binding.apps.first)
            .badge(binding.key.uppercased(), role: .accent)
        if let first = running.first {
            row = row.action("Switch") { await self.activate(first) }
        } else if let first = binding.apps.first {
            row = row.action("Open") { await self.activate(first, launch: true) }
        }
        if isPinned {
            row = row.action("Unpin") { await self.unpin(binding.key) }
        }
        for appID in binding.apps where !pinnedApps.contains(appID) {
            row = row.action("Leave Out \(name(of: appID))") {
                await self.set {
                    self.skipped.append(appID)
                    self.pinNames[appID] = self.name(of: appID)
                }
            }
        }
        return [row]
    }

    var settings: ViewContent {
        Section("Menu bar") {
            Toggle("Show the icon in the menu bar", isOn: menuBarIcon) { value in await self.set { self.menuBarIcon = value } }
            Text("Without it, open App Switcher from the palette. The icon comes back by itself when the key stops working.").role(.secondary)
        }
        Section("Keys") {
            Picker("Hold", options: KeyLayerTrigger.allCases.map(\.title), selection: triggerKey.title) { title in
                await self.set { self.trigger = (KeyLayerTrigger.allCases.first { $0.title == title } ?? .rightCommand).rawValue }
            }
            Picker("Pressing the letter of the app in front", options: Self.secondPressTitles.map(\.1), selection: Self.secondPressTitles.first { $0.0 == secondPressMode }?.1 ?? "") { title in
                await self.set { self.secondPress = (Self.secondPressTitles.first { $0.1 == title }?.0 ?? .hide).rawValue }
            }
            Toggle("Show the letter map while the key is held", isOn: overlay) { value in await self.set { self.overlay = value } }
            Text("Only right-hand keys are used, so the left ones keep every shortcut. Letters with no app pass through, so \(triggerKey.title) C still copies.").role(.secondary)
        }
        Section("Letters") {
            Toggle("Give running apps their first letter", isOn: autoLetters) { value in await self.set { self.autoLetters = value } }
            Toggle("Open pinned apps that aren't running", isOn: openPinned) { value in await self.set { self.openPinned = value } }
            if !pins.isEmpty {
                Button(clearArmed ? "Click again to clear every pin" : "Clear every pin", symbol: "pin.slash", role: .critical, key: "clear-pins") {
                    guard self.clearArmed else {
                        self.clearArmedAt = Date()
                        return
                    }
                    self.clearArmedAt = .distantPast
                    await self.set { self.pins = [:] }
                }
            }
        }
        if !skipped.isEmpty {
            Section("Left out") {
                ForEach(skipped) { id in
                    Row(name(of: id), key: "skipped-\(id)")
                        .action("Bring Back") { await self.set { self.skipped.removeAll { $0 == id } } }
                }
            }
        }
        Section("Permission") {
            Text("Stackbar needs Accessibility access to hear the key you hold: System Settings › Privacy & Security › Accessibility. While an app has Secure Input on (a password field), macOS blocks every keyboard listener, this one included.").role(.secondary)
        }
    }

    static let secondPressTitles: [(SecondPress, String)] = [(.hide, "Hides it"), (.cycleWindows, "Shows its next window"), (.stay, "Does nothing")]

    var commands: [Command] {
        Command("assign", title: "Pin a Letter to an App", subtitle: "\(triggerKey.title) \(assignKey) and a letter does this for the app in front", symbol: "pin", keywords: ["app switcher", "pin", "letter", "rcmd"]) { invocation in
            await self.assign(key: invocation["key"] ?? "", app: invocation["app"] ?? "")
        }
        .argument("key", placeholder: "Letter")
        .argument("app", placeholder: "App name or bundle id, like Safari")
        Command("clear-pins", title: "Clear App Switcher Pins", subtitle: "Every letter goes back to its app's first letter", symbol: "pin.slash", keywords: ["app switcher", "pin", "letter"])
            .view { _ in
                List {
                    Row("Clear Every Pin Now", subtitle: "\(self.pins.count) pinned \(self.pins.count == 1 ? "letter" : "letters") will go back to each app's first letter", symbol: "pin.slash", key: "confirm")
                        .action("Clear", role: .critical) {
                            await self.set { self.pins = [:] }
                            self.notice = "Cleared every pin"
                        }
                }
            }
    }

    var tools: [AgentTool] {
        AgentTool("letters", description: "The App Switcher's letter map: which app each letter switches to while the trigger key is held, pinned letters marked") { _ in
            try? await self.refresh()
            let bindings = self.layer.bindings
            guard !bindings.isEmpty else { return "No letters" }
            return bindings.map { binding in
                "- \(binding.key.uppercased()): \(binding.apps.map(self.name(of:)).joined(separator: ", "))\(self.pins[binding.key]?.isEmpty == false ? " (pinned)" : "")"
            }.joined(separator: "\n")
        }
    }
}
