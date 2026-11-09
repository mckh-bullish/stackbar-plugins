import StackbarKit
import Foundation

/// Window management in one place. Snap the front window to a half, a
/// quarter, a third, the middle or the whole screen, or send it to the next
/// display; and save where every window goes for each monitor setup, so
/// plugging in or unplugging a display brings that setup's layout back by
/// itself, apps that weren't running included. Every snap and every saved
/// layout is a command, so each can have a hotkey.
///
/// It was two plugins, Workspaces and Window Layouts. It keeps Workspaces'
/// id (saved layouts stay where they are) and Window Layouts' command ids
/// (`replaces` moves their hotkeys over). Needs `.windows`, and
/// Accessibility access for Stackbar.
@main
final class Windows: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.workspaces",
        name: "Windows",
        version: "2.4.0",
        summary: "Snap the front window to halves, thirds or quarters, and save where your windows go for each monitor setup.",
        surfaces: [.menuBar, .panel, .settings],
        triggers: [.launch, .wake, .displays],
        capabilities: [.windows],
        minimumStackbar: "0.35.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/Windows",
        accent: .indigo,
        symbol: "macwindow.on.rectangle",
        replaces: ["io.navbytes.stackbar.plugins.window-layouts"]
    )

    // MARK: Previews

    /// Outside the app the windows are simulated: a laptop with an external display.
    static let previews: [PreviewScene<Windows>] = [
        PreviewScene("hero", "Snap a window, or bring back every window for your desk") { plugin in
            try await plugin.refresh()
            for name in ["Coding", "Writing", "Meetings"] { _ = await plugin.save(name) }
            plugin.notice = "Safari: Left Half"
        },
        PreviewScene("restored", "Back where they were, apps opened for you") { plugin in
            try await plugin.refresh()
            await plugin.save("Desk")
            plugin.notice = "Restored “Desk”: moved 3 windows; opened Xcode; 1 window not open (Slack)"
        },
        PreviewScene("settings", "Gaps, auto-restore and more", surface: .settings) { plugin in
            try await plugin.refresh()
            plugin.gap = 8
        },
    ]

    let theme = Theme.indigo

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
    /// Space left between a snapped window and the screen's edges, in points.
    @Stored("gap") var gap = 0.0
    /// Pressing a half again steps through two thirds and one third, as Rectangle does.
    @Stored("cycleSizes") var cycleSizes = true
    /// Where each window was before its last snap, by app and title.
    var previous: [String: WindowRect] = [:]
    /// Where each window's last snap left it, and which snap that was: a half
    /// pressed again on that frame is the next step of a cycle.
    var placed: [String: (snap: String, frame: WindowRect)] = [:]

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

    /// `apps` (names or bundle ids, comma-separated) saves only their
    /// windows; empty saves every window.
    @discardableResult
    func save(_ rawName: String, apps: String = "") async -> CommandResult {
        let name = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !name.isEmpty else { return .failure("Give the layout a name, like Desk") }
        guard await look(), let snapshot else { return .failure(problem ?? "Can't read your windows") }
        let wanted = Self.appNames(apps)
        let placements = Array(WindowPlacement.capture(snapshot).filter { Self.matches($0, wanted) }.prefix(WindowPlacement.maxPerCall))
        guard !placements.isEmpty else { return .failure(wanted.isEmpty ? "There are no windows to save" : "None of those apps has a window open") }
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

    /// `Xcode, safari` → ["xcode", "safari"].
    static func appNames(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    /// Whether the placement's app is one of `names` (by name or bundle id);
    /// every app when there are none.
    static func matches(_ placement: WindowPlacement, _ names: [String]) -> Bool {
        names.isEmpty || names.contains(placement.appName.lowercased()) || names.contains(placement.appID.lowercased())
    }

    /// Takes one window out of a saved layout.
    func remove(_ index: Int, from layoutID: String) {
        guard let at = layouts.firstIndex(where: { $0.id == layoutID }), layouts[at].placements.indices.contains(index) else { return }
        let gone = layouts[at].placements.remove(at: index)
        notice = "Removed \(gone.appName) from “\(layouts[at].name)”"
    }

    /// Every layout as JSON, to keep in a file or move to another Mac.
    func exportLayouts() async throws -> String {
        guard !layouts.isEmpty else { return "No layouts to export" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let path = try await Stackbar.saveFile("Window Layouts.json", data: try encoder.encode(layouts)) else { return "Export cancelled" }
        return "Exported \(Self.count(layouts.count, "layout")) to \(path)"
    }

    /// Layouts from a file: one with the same id is replaced, the rest added.
    func importLayouts() async throws -> String {
        guard let file = try await Stackbar.chooseFile(types: ["json"]) else { return "Import cancelled" }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let incoming: [Layout]
        do {
            incoming = try decoder.decode([Layout].self, from: file.data)
        } catch {
            throw HostError("\(file.name) is not a window layouts export: \(error.localizedDescription)")
        }
        var all = layouts
        for layout in incoming {
            if let at = all.firstIndex(where: { $0.id == layout.id }) { all[at] = layout } else { all.append(layout) }
        }
        layouts = all
        return "Imported \(Self.count(incoming.count, "layout"))"
    }

    func restore(_ layout: Layout, automatic: Bool = false) async -> CommandResult {
        _ = await look()
        let placements = snapshot.map { Self.fitted(layout.placements, to: $0) } ?? layout.placements
        do {
            let result = try await Stackbar.arrangeWindows(placements, launch: openApps)
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
        if unique.count > 1 { return unique.dropLast().joined(separator: ", ") + " and " + (unique.last ?? "") }
        return unique.first ?? ""
    }

    // MARK: - Snapping

    /// A place on the screen for the front window, as fractions of the
    /// display's visible area.
    struct Snap: Identifiable {
        var id: String
        var title: String
        var symbol: String
        var group: String
        var keywords: [String] = []
        /// x, y, width, height in 0...1 of the visible frame; nil for the
        /// snaps worked out from the window itself.
        var unit: (x: Double, y: Double, width: Double, height: Double)?
    }

    /// The ids are Window Layouts' own, so its hotkeys carry over. Its
    /// "restore" became "undo-snap": "restore" here restores a saved layout.
    static let snaps: [Snap] = [
        Snap(id: "left-half", title: "Left Half", symbol: "rectangle.lefthalf.filled", group: "Halves", keywords: ["snap", "split"], unit: (0, 0, 0.5, 1)),
        Snap(id: "right-half", title: "Right Half", symbol: "rectangle.righthalf.filled", group: "Halves", keywords: ["snap", "split"], unit: (0.5, 0, 0.5, 1)),
        Snap(id: "top-half", title: "Top Half", symbol: "rectangle.tophalf.filled", group: "Halves", keywords: ["snap", "split"], unit: (0, 0, 1, 0.5)),
        Snap(id: "bottom-half", title: "Bottom Half", symbol: "rectangle.bottomhalf.filled", group: "Halves", keywords: ["snap", "split"], unit: (0, 0.5, 1, 0.5)),
        Snap(id: "top-left", title: "Top Left Quarter", symbol: "rectangle.inset.topleft.filled", group: "Quarters", keywords: ["corner", "snap"], unit: (0, 0, 0.5, 0.5)),
        Snap(id: "top-right", title: "Top Right Quarter", symbol: "rectangle.inset.topright.filled", group: "Quarters", keywords: ["corner", "snap"], unit: (0.5, 0, 0.5, 0.5)),
        Snap(id: "bottom-left", title: "Bottom Left Quarter", symbol: "rectangle.inset.bottomleft.filled", group: "Quarters", keywords: ["corner", "snap"], unit: (0, 0.5, 0.5, 0.5)),
        Snap(id: "bottom-right", title: "Bottom Right Quarter", symbol: "rectangle.inset.bottomright.filled", group: "Quarters", keywords: ["corner", "snap"], unit: (0.5, 0.5, 0.5, 0.5)),
        Snap(id: "first-third", title: "First Third", symbol: "rectangle.leadingthird.inset.filled", group: "Thirds", keywords: ["left", "snap"], unit: (0, 0, 1.0 / 3, 1)),
        Snap(id: "center-third", title: "Center Third", symbol: "rectangle.center.inset.filled", group: "Thirds", keywords: ["middle", "snap"], unit: (1.0 / 3, 0, 1.0 / 3, 1)),
        Snap(id: "last-third", title: "Last Third", symbol: "rectangle.trailingthird.inset.filled", group: "Thirds", keywords: ["right", "snap"], unit: (2.0 / 3, 0, 1.0 / 3, 1)),
        Snap(id: "first-two-thirds", title: "First Two Thirds", symbol: "rectangle.leadinghalf.inset.filled", group: "Thirds", keywords: ["left", "snap"], unit: (0, 0, 2.0 / 3, 1)),
        Snap(id: "last-two-thirds", title: "Last Two Thirds", symbol: "rectangle.trailinghalf.inset.filled", group: "Thirds", keywords: ["right", "snap"], unit: (1.0 / 3, 0, 2.0 / 3, 1)),
        Snap(id: "maximize", title: "Maximize", symbol: "rectangle.fill", group: "Screen", keywords: ["fill", "full", "zoom"], unit: (0, 0, 1, 1)),
        Snap(id: "almost-maximize", title: "Almost Maximize", symbol: "rectangle.inset.filled", group: "Screen", keywords: ["fill", "large"], unit: (0.05, 0.05, 0.9, 0.9)),
        Snap(id: "center", title: "Center", symbol: "rectangle.center.inset.filled", group: "Screen", keywords: ["middle"]),
        Snap(id: "next-display", title: "Next Display", symbol: "rectangle.portrait.and.arrow.forward", group: "Screen", keywords: ["monitor", "screen", "move"]),
        Snap(id: "previous-display", title: "Previous Display", symbol: "arrow.left.to.line", group: "Screen", keywords: ["monitor", "screen", "move", "back"]),
        Snap(id: "make-larger", title: "Make Larger", symbol: "arrow.up.left.and.arrow.down.right", group: "Screen", keywords: ["grow", "bigger", "resize"]),
        Snap(id: "make-smaller", title: "Make Smaller", symbol: "arrow.down.right.and.arrow.up.left", group: "Screen", keywords: ["shrink", "resize"]),
        Snap(id: "undo-snap", title: "Undo Snap", symbol: "arrow.uturn.backward", group: "Screen", keywords: ["restore", "undo", "back"]),
    ]

    /// The frame `snap` gives a window at `frame` on `visible`, the display's
    /// area without the menu bar and Dock, `gap` in from its edges.
    static func frame(_ snap: Snap, window frame: WindowRect, visible: WindowRect, gap: Double = 0) -> WindowRect? {
        let area = WindowRect(x: visible.x + gap, y: visible.y + gap, width: max(visible.width - 2 * gap, 100), height: max(visible.height - 2 * gap, 100))
        if let unit = snap.unit {
            // Gaps between neighbours: half on each side of an inner edge.
            let half = gap / 2
            let left = unit.x > 0 ? half : 0
            let top = unit.y > 0 ? half : 0
            let right = unit.x + unit.width < 0.999 ? half : 0
            let bottom = unit.y + unit.height < 0.999 ? half : 0
            return WindowRect(
                x: (area.x + area.width * unit.x + left).rounded(),
                y: (area.y + area.height * unit.y + top).rounded(),
                width: (area.width * unit.width - left - right).rounded(),
                height: (area.height * unit.height - top - bottom).rounded()
            )
        }
        if snap.id == "make-larger" || snap.id == "make-smaller" {
            // A tenth of the screen at a time, from the window's middle, kept on screen.
            let sign = snap.id == "make-larger" ? 1.0 : -1.0
            let width = min(max(frame.width + sign * area.width / 10, area.width / 5), area.width)
            let height = min(max(frame.height + sign * area.height / 10, area.height / 5), area.height)
            let x = min(max(frame.midX - width / 2, area.x), area.x + area.width - width)
            let y = min(max(frame.midY - height / 2, area.y), area.y + area.height - height)
            return WindowRect(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: height.rounded())
        }
        if snap.id == "center" {
            let width = min(frame.width, area.width)
            let height = min(frame.height, area.height)
            return WindowRect(x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded(), width: width, height: height)
        }
        return nil
    }

    /// The same place and size, relative to its display, on `next`: a half
    /// on the laptop is a half on the big display.
    static func moved(_ frame: WindowRect, from current: WindowRect, to next: WindowRect) -> WindowRect {
        let clamp = { (value: Double) in min(max(value, 0), 1) }
        let width = min(next.width * clamp(frame.width / max(current.width, 1)), next.width)
        let height = min(next.height * clamp(frame.height / max(current.height, 1)), next.height)
        let fx = current.width > frame.width ? (frame.x - current.x) / (current.width - frame.width) : 0
        let fy = current.height > frame.height ? (frame.y - current.y) / (current.height - frame.height) : 0
        return WindowRect(
            x: (next.x + clamp(fx) * (next.width - width)).rounded(),
            y: (next.y + clamp(fy) * (next.height - height)).rounded(),
            width: width.rounded(),
            height: height.rounded()
        )
    }

    /// Snaps that are commands only, to keep the panel's grid to one row.
    static let commandOnly: Set<String> = ["previous-display", "make-larger", "make-smaller"]

    /// The four halves: the snaps that cycle through two thirds and one third.
    static let halfIDs: Set<String> = ["left-half", "right-half", "top-half", "bottom-half"]

    /// The part of the screen a half covers when it is `fraction` of the
    /// screen's width (or height) on its side.
    static func halfUnit(_ id: String, _ fraction: Double) -> (x: Double, y: Double, width: Double, height: Double)? {
        switch id {
        case "left-half": return (0, 0, fraction, 1)
        case "right-half": return (1 - fraction, 0, fraction, 1)
        case "top-half": return (0, 0, 1, fraction)
        case "bottom-half": return (0, 1 - fraction, 1, fraction)
        default: return nil
        }
    }

    /// A half pressed again steps through a half, two thirds and one third on
    /// its side, as Rectangle does: the next size the window isn't at yet.
    static func cycled(_ snap: Snap, window: WindowRect, visible: WindowRect, gap: Double) -> WindowRect? {
        let sizes = [0.5, 2.0 / 3, 1.0 / 3]
        func sized(_ fraction: Double) -> WindowRect? {
            var variant = snap
            variant.unit = halfUnit(snap.id, fraction)
            return frame(variant, window: window, visible: visible, gap: gap)
        }
        let current = sizes.firstIndex { size in sized(size).map { close($0, window) } == true } ?? sizes.count - 1
        return sized(sizes[(current + 1) % sizes.count])
    }

    /// Whether two frames are the same place, to within a point or two.
    static func close(_ a: WindowRect, _ b: WindowRect) -> Bool {
        abs(a.x - b.x) < 2 && abs(a.y - b.y) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    /// A window whose middle is on no display now (one saved with a display
    /// that's gone) is moved onto the nearest one, kept whole.
    static func fitted(_ placements: [WindowPlacement], to snapshot: WindowSnapshot) -> [WindowPlacement] {
        placements.map { placement in
            var p = placement
            let f = p.frame
            guard !p.isMinimized, !snapshot.displays.contains(where: { $0.frame.contains(x: f.midX, y: f.midY) }),
                  let v = snapshot.display(for: f)?.visibleFrame else { return p }
            let w = min(f.width, v.width), h = min(f.height, v.height)
            p.frame = WindowRect(x: min(max(f.x, v.x), v.x + v.width - w), y: min(max(f.y, v.y), v.y + v.height - h), width: w, height: h)
            return p
        }
    }

    /// Stackbar's own windows (the palette, a plugin window) are skipped.
    static let hostID = "io.navbytes.stackbar"

    /// Moves the front window as `snap` says.
    func apply(_ snap: Snap) async -> CommandResult {
        let current: WindowSnapshot
        do {
            current = try await Stackbar.windows()
        } catch {
            problem = "Can't see your windows: \(error). Stackbar needs Accessibility access (System Settings › Privacy & Security)."
            return .failure(problem ?? "")
        }
        guard let window = current.windows.first(where: { !$0.isMinimized && !$0.appID.hasPrefix(Self.hostID) }) else {
            return .message("No window to move")
        }
        guard let display = current.display(for: window.frame) else { return .message("No display found") }
        let key = window.appID + "|" + window.title
        let target: WindowRect
        switch snap.id {
        case "undo-snap":
            guard let saved = previous[key] else { return .message("Nothing to undo for \(window.appName)") }
            target = saved
        case "next-display", "previous-display":
            guard current.displays.count > 1, let index = current.displays.firstIndex(where: { $0.id == display.id }) else {
                return .message("Only one display")
            }
            let count = current.displays.count
            let next = current.displays[(index + (snap.id == "next-display" ? 1 : count - 1)) % count]
            target = Self.moved(window.frame, from: display.visibleFrame, to: next.visibleFrame)
        default:
            let framed = cycleSizes && Self.halfIDs.contains(snap.id)
                ? Self.cycled(snap, window: window.frame, visible: display.visibleFrame, gap: gap)
                : Self.frame(snap, window: window.frame, visible: display.visibleFrame, gap: gap)
            guard let frame = framed else { return .done }
            target = frame
        }
        // The app's windows front first: this one's place among them.
        let ordinal = current.windows.filter { $0.appID == window.appID }.firstIndex(of: window) ?? 0
        let placement = WindowPlacement(appID: window.appID, appName: window.appName, title: window.title, ordinal: ordinal, frame: target)
        do {
            let result = try await Stackbar.arrangeWindows([placement])
            if !result.failed.isEmpty { return .failure("\(window.appName) didn't let its window move") }
        } catch {
            return .failure("Couldn't move the window: \(error)")
        }
        if snap.id != "undo-snap", !continuesCycle(snap, key: key, window: window.frame) {
            if previous.count >= 100 {
                previous.removeAll()
                placed.removeAll()
            }
            previous[key] = window.frame
        }
        if placed.count >= 100 { placed.removeAll() }
        placed[key] = (snap.id, target)
        problem = nil
        notice = "\(window.appName): \(snap.title)"
        return .done
    }

    /// Whether this press is the next step of a half cycle: the same half again,
    /// on the frame the last press left the window in. Undo then keeps the frame
    /// from before the cycle began.
    func continuesCycle(_ snap: Snap, key: String, window: WindowRect) -> Bool {
        guard cycleSizes, Self.halfIDs.contains(snap.id), let last = placed[key], last.snap == snap.id else { return false }
        return Self.close(last.frame, window)
    }

    // MARK: - Surfaces

    var menuBar: ViewContent {
        if menuBarIcon || problem != nil {
            Label("", symbol: problem == nil ? "rectangle.3.group" : "exclamationmark.triangle").role(problem == nil ? .secondary : .warning)
        }
    }

    var panel: ViewContent {
        let windows = snapshot?.windows.count ?? 0
        PanelHeader(currentSetupName, subtitle: snapshot == nil ? "Windows" : "\(Self.count(windows, "window")) open · \(Self.count(here.count, "layout")) for this setup", symbol: "macwindow.on.rectangle", theme: theme) {
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
        Card("Snap the front window", spacing: Space.xs, padding: Space.s) {
            Grid(columns: 9, spacing: Space.xs) {
                ForEach(Self.snaps.filter { !Self.commandOnly.contains($0.id) }) { snap in
                    IconButton(snap.symbol, label: snap.title, theme: theme, key: "snap-\(snap.id)") {
                        switch await self.apply(snap) {
                        case .failure(let text):
                            // A problem already shows its own banner, so don't repeat it.
                            if text != self.problem { self.notice = text }
                        case .message(let text?): self.notice = text
                        default: break
                        }
                    }
                }
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
            IconButton("trash", label: "Delete \(layout.name)", theme: theme, key: "delete-\(layout.id)", confirm: "delete \(layout.name)") {
                self.delete(layout)
            }
        }
        .padding(horizontal: Space.xs, vertical: 5)
        .hover(scale: nil, highlight: .hoverWash, lift: false)
    }

    /// A window of a layout being edited, by its place in the layout.
    struct EditedWindow: Identifiable {
        var index: Int
        var placement: WindowPlacement
        var id: Int { index }
    }

    static let gaps: [(title: String, points: Double)] = [("None", 0), ("Small", 4), ("Medium", 8), ("Large", 16)]

    var settings: ViewContent {
        Section("Menu bar") {
            Toggle("Show the icon in the menu bar", isOn: menuBarIcon) { self.menuBarIcon = $0 }
            Text("Without it, open Windows from the palette. The icon comes back by itself when something needs you.").role(.secondary)
        }
        Section("Snapping") {
            Picker("Gap around windows", options: Self.gaps.map(\.title), selection: Self.gaps.first { $0.points == gap }?.title ?? "None", style: .segmented) { title in
                self.gap = Self.gaps.first { $0.title == title }?.points ?? 0
            }
            Toggle("Pressing a half again cycles through two thirds and one third", isOn: cycleSizes) { self.cycleSizes = $0 }
            Text("Every snap is a command: type \u{201C}left half\u{201D} in the palette, or give it a hotkey in Settings › Commands.").role(.secondary)
        }
        Section("Restoring") {
            Toggle("Bring back the starred layout when displays change", isOn: autoRestore) { self.autoRestore = $0 }
            Toggle("Open apps that aren't running", isOn: openApps) { self.openApps = $0 }
            Text("A layout belongs to the displays it was saved on. When you plug in or unplug a display, or wake the Mac on a different set of displays, that set's starred layout comes back. Windows in full screen and on other Spaces stay where they are.").role(.secondary)
        }
        Section("Layouts") {
            Text("\(Self.count(layouts.count, "layout")) saved across \(Self.count(Set(layouts.map(\.setupID)).count, "setup")). Each one is a command you can give a hotkey in Stackbar's Settings.").role(.secondary)
            if !layouts.isEmpty {
                Button("Delete every layout", symbol: "trash", role: .critical, key: "delete-all", confirm: "delete \(Self.count(layouts.count, "layout"))") {
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
        for snap in Self.snaps {
            Command(snap.id, title: snap.title, subtitle: "Windows", symbol: snap.symbol, keywords: snap.keywords + ["window", "snap"].filter { !snap.keywords.contains($0) }) { _ in
                await self.apply(snap)
            }
        }
        for layout in layouts {
            Command(layout.commandID, title: "Restore \(layout.name)", subtitle: "\(Self.count(layout.windowCount, "window")) · \(layout.setupName)", symbol: "rectangle.3.group", keywords: ["workspace", "layout", "windows", "restore", layout.name]) { _ in
                await self.restore(layout)
            }
        }
        Command("save", title: "Save Window Layout", subtitle: "Remember where every window is on these displays", symbol: "square.and.arrow.down", keywords: ["workspace", "layout", "windows", "save", "snapshot"]) { invocation in
            await self.save(invocation["name"] ?? "", apps: invocation["apps"] ?? "")
        }
        .argument("name", placeholder: "Desk")
        .argument("apps", placeholder: "Only these apps: Xcode, Safari", required: false)
        Command("edit", title: "Edit Window Layout", subtitle: "Take windows out of a saved layout", symbol: "slider.horizontal.3", keywords: ["workspace", "layout", "windows", "remove"])
            .argument("layout", placeholder: "Layout", options: (here + elsewhere).prefix(20).map(\.name))
            .view { invocation in
                if let layout = self.find(invocation["layout"] ?? "") {
                    List(Array(layout.placements.enumerated()).map { EditedWindow(index: $0.offset, placement: $0.element) }, searchable: true) { item in
                        Row(item.placement.appName, subtitle: item.placement.title.isEmpty ? "Window \(item.placement.ordinal + 1)" : item.placement.title, symbol: "macwindow", key: "w\(item.index)-\(item.placement.appID)")
                            .appIcon(item.placement.appID)
                            .action("Remove from \(layout.name)", role: .critical, confirm: .none) { self.remove(item.index, from: layout.id) }
                    }
                } else {
                    ContentUnavailableView("Which layout?", symbol: "rectangle.3.group", message: "Pick one of your saved layouts.")
                }
            }
            .stackbarOnly()
        Command("export", title: "Export Window Layouts", subtitle: "To a file, for a backup or another Mac", symbol: "square.and.arrow.up", keywords: ["workspace", "layout", "windows", "backup"]) { _ in
            .message(try await self.exportLayouts())
        }
        .stackbarOnly()
        Command("import", title: "Import Window Layouts", subtitle: "From an exported file", symbol: "square.and.arrow.down", keywords: ["workspace", "layout", "windows"]) { _ in
            .message(try await self.importLayouts())
        }
        .stackbarOnly()
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
        AgentTool("snap", description: "Moves the front window: " + Self.snaps.map(\.title).joined(separator: ", "), parameters: [ToolParameter("to", description: "Where to, like Left Half or Next Display")]) { arguments in
            let wanted = (arguments.string("to") ?? "").trimmingCharacters(in: .whitespaces)
            guard let snap = Self.snaps.first(where: { $0.title.caseInsensitiveCompare(wanted) == .orderedSame || $0.id == wanted.lowercased() }) else {
                return "No snap called \(wanted). Try one of: " + Self.snaps.map(\.title).joined(separator: ", ")
            }
            return Self.text(await self.apply(snap))
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
