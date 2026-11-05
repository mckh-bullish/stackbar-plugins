import StackbarKit
import Foundation

/// Remembers where your windows go for each monitor setup and puts them
/// back. Save the arrangement you like at the desk and the one you like on
/// the laptop alone; plug in or unplug a display and the setup's default
/// layout comes back by itself, apps that weren't running included. Every
/// layout is a command, so it can have a hotkey. Needs `.windows`, and
/// Accessibility access for Stackbar.
@main
final class Workspaces: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.workspaces",
        name: "Workspaces",
        version: "1.2.0",
        summary: "Saves where your windows are for each monitor setup, and puts them back when you dock, undock or wake.",
        surfaces: [.menuBar, .panel, .settings],
        triggers: [.launch, .wake, .displays],
        capabilities: [.windows],
        minimumStackbar: "0.21.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/Workspaces",
        accent: .graphite,
        symbol: "rectangle.3.group"
    )

    // MARK: Previews

    /// Outside the app the windows are simulated: a laptop with an external display.
    static let previews: [PreviewScene<Workspaces>] = [
        PreviewScene("hero", "Save your windows as a layout and get them back") { plugin in
            try await plugin.refresh()
            for name in ["Coding", "Writing", "Meetings"] { _ = await plugin.save(name) }
            plugin.notice = nil
        },
    ]

    /// Calm and neutral: windows are the user's content, not ours.
    let theme = Theme.graphite

    /// One saved arrangement, tied to the setup it was saved on.
    struct Layout: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        var setupID: String
        /// The displays in words, as they were when it was saved.
        var setupName: String
        var placements: [WindowPlacement]
        var savedAt: Date

        var commandID: String { "restore-\(id)" }
        var windowCount: Int { placements.count }
    }

    @Stored("layouts") var layouts: [Layout] = []
    /// Off by default: layouts are restored from the palette or a hotkey, so
    /// the icon only shows up when something needs the user.
    @Stored("menuBarIcon") var menuBarIcon = false
    /// The layout that comes back by itself, by setup id.
    @Stored("defaults") var defaults: [String: String] = [:]
    @Stored("autoRestore") var autoRestore = true
    @Stored("openApps") var openApps = true
    @Stored("lastSetup") var lastSetup = ""

    var snapshot: WindowSnapshot?
    var problem: String?
    var notice: String?

    func refresh() async throws {
        let reason = Stackbar.refreshReason
        guard await look() else { return }
        guard let snapshot else { return }
        let changed = snapshot.setupID != lastSetup
        lastSetup = snapshot.setupID
        // A dock or undock (also one that happened while the Mac slept)
        // brings the new setup's default back. A display merely waking up
        // on the same setup leaves the user's windows alone.
        if autoRestore, changed, reason == .displays || reason == .wake, let layout = defaultLayout(for: snapshot.setupID) {
            _ = await restore(layout, automatic: true)
        }
    }

    /// Reads the windows now; false (with `problem` set) when it can't.
    @discardableResult
    func look() async -> Bool {
        do {
            snapshot = try await Stackbar.windows()
            problem = nil
            return true
        } catch {
            problem = "\(error)"
            return false
        }
    }

    // MARK: - Model

    var setupID: String { snapshot?.setupID ?? lastSetup }

    var here: [Layout] { layouts.filter { $0.setupID == setupID }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var elsewhere: [Layout] { layouts.filter { $0.setupID != setupID }.sorted { ($0.setupName, $0.name) < ($1.setupName, $1.name) } }

    func defaultLayout(for setup: String) -> Layout? {
        defaults[setup].flatMap { id in layouts.first { $0.id == id } }
    }

    func isDefault(_ layout: Layout) -> Bool { defaults[layout.setupID] == layout.id }

    /// "Studio Display + Built-in", main display first.
    static func setupName(_ snapshot: WindowSnapshot) -> String {
        let names = snapshot.displays.sorted { ($0.isMain ? 0 : 1, $0.frame.x) < ($1.isMain ? 0 : 1, $1.frame.x) }.map { display in
            display.isBuiltIn ? "Built-in" : display.name
        }
        return names.isEmpty ? "No displays" : names.joined(separator: " + ")
    }

    var currentSetupName: String { snapshot.map(Self.setupName) ?? "This setup" }

    func find(_ name: String) -> Layout? {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        let match = { (layout: Layout) in layout.name.caseInsensitiveCompare(wanted) == .orderedSame }
        let prefix = { (layout: Layout) in layout.name.lowercased().hasPrefix(wanted.lowercased()) }
        return here.first(where: match) ?? elsewhere.first(where: match) ?? here.first(where: prefix) ?? elsewhere.first(where: prefix)
    }

    // MARK: - Actions

    @discardableResult
    func save(_ rawName: String) async -> CommandResult {
        let name = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !name.isEmpty else { return .failure("Give the layout a name, like Desk") }
        guard await look(), let snapshot else { return .failure(problem ?? "Can't read your windows") }
        let placements = Array(WindowPlacement.capture(snapshot).prefix(WindowPlacement.maxPerCall))
        guard !placements.isEmpty else { return .failure("There are no windows to save") }
        let setupName = Self.setupName(snapshot)
        var verb = "Saved"
        if let index = layouts.firstIndex(where: { $0.setupID == snapshot.setupID && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            layouts[index].placements = placements
            layouts[index].setupName = setupName
            layouts[index].savedAt = Date()
            verb = "Updated"
        } else {
            let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
            layouts.append(Layout(id: id, name: name, setupID: snapshot.setupID, setupName: setupName, placements: placements, savedAt: Date()))
            if defaults[snapshot.setupID] == nil { defaults[snapshot.setupID] = id }
        }
        let text = "\(verb) “\(name)” with \(Self.count(placements.count, "window")) on \(setupName)"
        notice = text
        return .message(text)
    }

    func restore(_ layout: Layout, automatic: Bool = false) async -> CommandResult {
        do {
            let result = try await Stackbar.arrangeWindows(layout.placements, launch: openApps)
            _ = await look()
            let text = Self.describe(result, layout: layout, automatic: automatic)
            notice = text
            return .message(text)
        } catch {
            let text = "Couldn't restore “\(layout.name)”: \(error)"
            notice = text
            return .failure(text)
        }
    }

    func makeDefault(_ layout: Layout) {
        defaults[layout.setupID] = layout.id
        notice = "“\(layout.name)” now comes back by itself on \(layout.setupName)"
    }

    func delete(_ layout: Layout) {
        layouts.removeAll { $0.id == layout.id }
        if defaults[layout.setupID] == layout.id {
            defaults[layout.setupID] = layouts.first { $0.setupID == layout.setupID }?.id
        }
        notice = "Deleted “\(layout.name)”"
    }

    static func describe(_ result: ArrangeResult, layout: Layout, automatic: Bool) -> String {
        var parts = ["\(automatic ? "Brought back" : "Restored") “\(layout.name)”"]
        if result.moved > 0 {
            parts[0] += ": moved \(count(result.moved, "window"))"
        } else if result.opened.isEmpty && result.missing.isEmpty && result.failed.isEmpty {
            parts[0] += ": everything was already in place"
        }
        if !result.opened.isEmpty { parts.append("opened \(list(result.opened))") }
        if !result.missing.isEmpty { parts.append("\(count(result.missing.count, "window")) not open (\(list(result.missing)))") }
        if !result.failed.isEmpty { parts.append("\(list(result.failed)) wouldn't move") }
        return parts.joined(separator: "; ")
    }

    static func count(_ value: Int, _ noun: String) -> String { "\(value) \(noun)\(value == 1 ? "" : "s")" }

    /// "Slack, Mail and 2 more", each name once.
    static func list(_ names: [String]) -> String {
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        if unique.count > 3 { return unique.prefix(2).joined(separator: ", ") + " and \(unique.count - 2) more" }
        if unique.count > 1 { return unique.dropLast().joined(separator: ", ") + " and " + unique.last! }
        return unique.first ?? ""
    }

    // MARK: - Surfaces

    var menuBar: ViewContent {
        if menuBarIcon || problem != nil {
            Label("", symbol: problem == nil ? "rectangle.3.group" : "exclamationmark.triangle").role(problem == nil ? .secondary : .warning)
        }
    }

    var panel: ViewContent {
        let windows = snapshot?.windows.count ?? 0
        PanelHeader(currentSetupName, subtitle: snapshot == nil ? "Workspaces" : "\(Self.count(windows, "window")) open · \(Self.count(here.count, "layout")) for this setup", symbol: "rectangle.3.group", theme: theme) {
            IconButton("arrow.clockwise", label: "Look again", theme: theme, key: "reload") { await self.look() }
        }
        if let problem {
            Banner(problem, theme: .warning) {
                ActionButton("Try Again", theme: theme, key: "retry") { await self.look() }
            }
        }
        if let notice {
            Banner(notice, symbol: "checkmark.circle.fill", theme: theme) {
                IconButton("xmark", label: "Dismiss", theme: theme, key: "dismiss") { self.notice = nil }
            }
        }
        TextField("Save the windows as… (Desk, Laptop, Focus)", text: "", key: "save") { text in await self.save(text) }
        if layouts.isEmpty {
            EmptyState("No layouts yet", symbol: "macwindow.on.rectangle", message: "Arrange your windows the way you like them, type a name above and press Return. When this monitor setup comes back, so do your windows.", theme: theme)
        } else {
            if here.isEmpty {
                Card("This setup", spacing: Space.xs, padding: Space.s) {
                    Text("Nothing saved for \(currentSetupName) yet. Save one above, or restore a layout from another setup below.").role(.secondary).typography(.caption)
                }
            } else {
                Card("This setup", detail: autoRestore ? "★ comes back by itself" : nil, spacing: 0, padding: Space.s) {
                    ForEach(here) { layout in self.row(layout) }
                }
            }
            if !elsewhere.isEmpty {
                Card("Other setups", detail: "\(elsewhere.count)", spacing: 0, padding: Space.s) {
                    ForEach(elsewhere) { layout in self.row(layout, showSetup: true) }
                }
            }
        }
    }

    @ViewBuilder private func row(_ layout: Layout, showSetup: Bool = false) -> ViewContent {
        HStack(alignment: .center, spacing: Space.s) {
            Button(key: "default-\(layout.id)", action: { self.makeDefault(layout) }) {
                Image(systemName: isDefault(layout) ? "star.fill" : "star")
                    .font(size: 13)
                    .foreground(isDefault(layout) ? theme.textPaint : .role(.secondary))
                    .frame(width: 22, height: 22)
            }
            .accessibilityLabel(isDefault(layout) ? "\(layout.name) comes back by itself" : "Bring \(layout.name) back by itself")
            Button(key: "restore-\(layout.id)", action: { _ = await self.restore(layout) }) {
                VStack(alignment: .start, spacing: 1) {
                    Text(layout.name).typography(.body)
                    Text(([Self.count(layout.windowCount, "window")] + (showSetup ? [layout.setupName] : []) + ["saved " + layout.savedAt.formatted(date: .abbreviated, time: .omitted)]).joined(separator: " · "))
                        .role(.secondary).typography(.caption)
                }
                .frame(fillWidth: true, alignment: .leading)
            }
            .accessibilityLabel("Restore \(layout.name)")
            IconButton("arrow.down.circle", label: "Save the windows now as \(layout.name)", theme: theme, key: "update-\(layout.id)") {
                if layout.setupID == self.setupID {
                    await self.save(layout.name)
                } else {
                    self.notice = "“\(layout.name)” belongs to \(layout.setupName); save a new layout for this setup instead"
                }
            }
            IconButton("trash", label: "Delete \(layout.name)", theme: theme, key: "delete-\(layout.id)") { self.delete(layout) }
        }
        .padding(horizontal: Space.xs, vertical: 5)
        .hover(scale: nil, highlight: .hoverWash, lift: false)
    }

    var settings: ViewContent {
        Section("Menu bar") {
            Toggle("Show the icon in the menu bar", isOn: menuBarIcon) { self.menuBarIcon = $0 }
            Text("Without it, open Workspaces from the palette. The icon comes back by itself when something needs you.").role(.secondary)
        }
        Section("Restoring") {
            Toggle("Bring back the starred layout when displays change", isOn: autoRestore) { self.autoRestore = $0 }
            Toggle("Open apps that aren't running", isOn: openApps) { self.openApps = $0 }
            Text("A layout belongs to the displays it was saved on. When you plug in or unplug a display, or wake the Mac on a different set of displays, that set's starred layout comes back. Windows in full screen and on other Spaces stay where they are.").role(.secondary)
        }
        Section("Layouts") {
            Text("\(Self.count(layouts.count, "layout")) saved across \(Self.count(Set(layouts.map(\.setupID)).count, "setup")). Each one is a command you can give a hotkey in Stackbar's Settings.").role(.secondary)
            if !layouts.isEmpty {
                Button("Delete every layout", symbol: "trash", role: .critical) {
                    self.layouts = []
                    self.defaults = [:]
                }
            }
        }
        Section("Permission") {
            Text("Stackbar needs Accessibility access to see and move windows: System Settings › Privacy & Security › Accessibility.").role(.secondary)
        }
    }

    var commands: [Command] {
        for layout in layouts {
            Command(layout.commandID, title: "Restore \(layout.name)", subtitle: "\(Self.count(layout.windowCount, "window")) · \(layout.setupName)", symbol: "rectangle.3.group", keywords: ["workspace", "layout", "windows", "restore", layout.name]) { _ in
                await self.restore(layout)
            }
        }
        Command("save", title: "Save Window Layout", subtitle: "Remember where every window is on these displays", symbol: "square.and.arrow.down", keywords: ["workspace", "layout", "windows", "save", "snapshot"]) { invocation in
            await self.save(invocation["name"] ?? "")
        }
        .argument("name", placeholder: "Desk")
        Command("restore", title: "Restore Window Layout", subtitle: "Put windows back as a layout saved them", symbol: "rectangle.3.group", keywords: ["workspace", "layout", "windows", "restore"]) { invocation in
            await self.look()
            guard let layout = self.find(invocation["layout"] ?? "") ?? (invocation["layout"] == nil ? self.defaultLayout(for: self.setupID) : nil) else {
                return .failure("No layout called \(invocation["layout"] ?? "that")")
            }
            return await self.restore(layout)
        }
        .argument("layout", placeholder: "Layout", required: false, options: (here + elsewhere).prefix(20).map(\.name))
    }

    var tools: [AgentTool] {
        AgentTool("layouts", description: "The user's saved window layouts, one per line, with their monitor setup, window count and whether they come back by themselves") { _ in
            await self.look()
            guard !self.layouts.isEmpty else { return "No layouts saved" }
            return (self.here + self.elsewhere).map { layout in
                "- \(layout.name): \(Self.count(layout.windowCount, "window")) on \(layout.setupName)\(layout.setupID == self.setupID ? " (current setup)" : "")\(self.isDefault(layout) ? ", starred" : "")"
            }.joined(separator: "\n")
        }
        AgentTool("save_layout", description: "Saves where every window is now as a named layout for the current monitor setup; an existing name is updated", parameters: [ToolParameter("name", description: "The layout's name, like Desk")]) { arguments in
            Self.text(await self.save(arguments.string("name") ?? ""))
        }
        AgentTool("restore_layout", description: "Moves windows back to a saved layout, opening apps that aren't running if the user allows it", parameters: [ToolParameter("name", description: "The layout's name")]) { arguments in
            await self.look()
            guard let layout = self.find(arguments.string("name") ?? "") else { return "No layout called \(arguments.string("name") ?? "that")" }
            return Self.text(await self.restore(layout))
        }
    }

    static func text(_ result: CommandResult) -> String {
        switch result {
        case .message(let text): return text ?? "Done"
        case .failure(let text): return text
        default: return "Done"
        }
    }
}
