import StackbarKit
import Foundation

/// Snaps the front window to halves, quarters, thirds, the middle or the
/// whole screen, or sends it to the next display. Every layout is a command,
/// so it can be typed in the palette ("left half") or given a hotkey in
/// Settings › Commands. "Restore" puts the window back where it was before
/// the last snap. Needs `.windows`, and Accessibility access for Stackbar.
@main
final class WindowLayouts: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.window-layouts",
        name: "Window Layouts",
        version: "1.0.0",
        summary: "Snap the front window to halves, quarters, thirds or the whole screen from the palette or a hotkey.",
        surfaces: [.panel, .settings],
        triggers: [.launch],
        capabilities: [.windows],
        minimumStackbar: "0.20.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/WindowLayouts",
        accent: .indigo,
        symbol: "rectangle.split.2x1"
    )

    // MARK: Previews

    static let previews: [PreviewScene<WindowLayouts>] = [
        PreviewScene("hero", "Snap the front window from the palette") { plugin in
            plugin.notice = "Safari: Left Half"
        },
    ]

    let theme = Theme.indigo

    /// Space left between a snapped window and the screen's edges, in points.
    @Stored("gap") var gap = 0.0
    var notice: String?
    var problem: String?
    /// Where each window was before its last snap, by app and title.
    var previous: [String: WindowRect] = [:]

    // MARK: Layouts

    /// A place on the screen, as fractions of the visible area.
    struct Layout: Identifiable {
        var id: String
        var title: String
        var symbol: String
        var group: String
        var keywords: [String] = []
        /// x, y, width, height in 0...1 of the visible frame; nil for the
        /// layouts worked out from the window itself.
        var unit: (x: Double, y: Double, width: Double, height: Double)?
    }

    static let layouts: [Layout] = [
        Layout(id: "left-half", title: "Left Half", symbol: "rectangle.lefthalf.filled", group: "Halves", keywords: ["snap", "split"], unit: (0, 0, 0.5, 1)),
        Layout(id: "right-half", title: "Right Half", symbol: "rectangle.righthalf.filled", group: "Halves", keywords: ["snap", "split"], unit: (0.5, 0, 0.5, 1)),
        Layout(id: "top-half", title: "Top Half", symbol: "rectangle.tophalf.filled", group: "Halves", keywords: ["snap", "split"], unit: (0, 0, 1, 0.5)),
        Layout(id: "bottom-half", title: "Bottom Half", symbol: "rectangle.bottomhalf.filled", group: "Halves", keywords: ["snap", "split"], unit: (0, 0.5, 1, 0.5)),
        Layout(id: "top-left", title: "Top Left Quarter", symbol: "rectangle.inset.topleft.filled", group: "Quarters", keywords: ["corner", "snap"], unit: (0, 0, 0.5, 0.5)),
        Layout(id: "top-right", title: "Top Right Quarter", symbol: "rectangle.inset.topright.filled", group: "Quarters", keywords: ["corner", "snap"], unit: (0.5, 0, 0.5, 0.5)),
        Layout(id: "bottom-left", title: "Bottom Left Quarter", symbol: "rectangle.inset.bottomleft.filled", group: "Quarters", keywords: ["corner", "snap"], unit: (0, 0.5, 0.5, 0.5)),
        Layout(id: "bottom-right", title: "Bottom Right Quarter", symbol: "rectangle.inset.bottomright.filled", group: "Quarters", keywords: ["corner", "snap"], unit: (0.5, 0.5, 0.5, 0.5)),
        Layout(id: "first-third", title: "First Third", symbol: "rectangle.leadingthird.inset.filled", group: "Thirds", keywords: ["left", "snap"], unit: (0, 0, 1.0 / 3, 1)),
        Layout(id: "center-third", title: "Center Third", symbol: "rectangle.center.inset.filled", group: "Thirds", keywords: ["middle", "snap"], unit: (1.0 / 3, 0, 1.0 / 3, 1)),
        Layout(id: "last-third", title: "Last Third", symbol: "rectangle.trailingthird.inset.filled", group: "Thirds", keywords: ["right", "snap"], unit: (2.0 / 3, 0, 1.0 / 3, 1)),
        Layout(id: "first-two-thirds", title: "First Two Thirds", symbol: "rectangle.leadinghalf.inset.filled", group: "Thirds", keywords: ["left", "snap"], unit: (0, 0, 2.0 / 3, 1)),
        Layout(id: "last-two-thirds", title: "Last Two Thirds", symbol: "rectangle.trailinghalf.inset.filled", group: "Thirds", keywords: ["right", "snap"], unit: (1.0 / 3, 0, 2.0 / 3, 1)),
        Layout(id: "maximize", title: "Maximize", symbol: "rectangle.fill", group: "Screen", keywords: ["fill", "full", "zoom"], unit: (0, 0, 1, 1)),
        Layout(id: "almost-maximize", title: "Almost Maximize", symbol: "rectangle.inset.filled", group: "Screen", keywords: ["fill", "large"], unit: (0.05, 0.05, 0.9, 0.9)),
        Layout(id: "center", title: "Center", symbol: "rectangle.center.inset.filled", group: "Screen", keywords: ["middle"]),
        Layout(id: "next-display", title: "Next Display", symbol: "rectangle.portrait.and.arrow.forward", group: "Screen", keywords: ["monitor", "screen", "move"]),
        Layout(id: "restore", title: "Restore", symbol: "arrow.uturn.backward", group: "Screen", keywords: ["undo", "back"]),
    ]

    static let groups = ["Halves", "Quarters", "Thirds", "Screen"]

    /// The frame `layout` gives a window at `frame` on `visible`, the
    /// display's area without the menu bar and Dock, `gap` in from its edges.
    static func frame(_ layout: Layout, window frame: WindowRect, visible: WindowRect, gap: Double = 0) -> WindowRect? {
        let area = WindowRect(x: visible.x + gap, y: visible.y + gap, width: max(visible.width - 2 * gap, 100), height: max(visible.height - 2 * gap, 100))
        if let unit = layout.unit {
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
        if layout.id == "center" {
            let width = min(frame.width, area.width)
            let height = min(frame.height, area.height)
            return WindowRect(x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded(), width: width, height: height)
        }
        return nil
    }

    /// The same place, relative to its display, on `next`.
    static func moved(_ frame: WindowRect, from current: WindowRect, to next: WindowRect) -> WindowRect {
        let width = min(frame.width, next.width)
        let height = min(frame.height, next.height)
        let fx = current.width > width ? (frame.x - current.x) / (current.width - width) : 0
        let fy = current.height > height ? (frame.y - current.y) / (current.height - height) : 0
        let clamp = { (value: Double) in min(max(value, 0), 1) }
        return WindowRect(
            x: (next.x + clamp(fx) * (next.width - width)).rounded(),
            y: (next.y + clamp(fy) * (next.height - height)).rounded(),
            width: width,
            height: height
        )
    }

    // MARK: Moving the front window

    /// Stackbar's own windows (the palette, a plugin window) are skipped.
    static let hostID = "io.navbytes.stackbar"

    func apply(_ layout: Layout) async -> CommandResult {
        let snapshot: WindowSnapshot
        do {
            snapshot = try await Stackbar.windows()
        } catch {
            problem = "Can't see your windows: \(error). Stackbar needs Accessibility access (System Settings › Privacy & Security)."
            return .failure(problem ?? "")
        }
        guard let window = snapshot.windows.first(where: { !$0.isMinimized && !$0.appID.hasPrefix(Self.hostID) }) else {
            return .message("No window to move")
        }
        guard let display = snapshot.display(for: window.frame) else { return .message("No display found") }
        let key = window.appID + "|" + window.title
        let target: WindowRect
        switch layout.id {
        case "restore":
            guard let saved = previous[key] else { return .message("Nothing to restore for \(window.appName)") }
            target = saved
        case "next-display":
            guard snapshot.displays.count > 1, let index = snapshot.displays.firstIndex(where: { $0.id == display.id }) else {
                return .message("Only one display")
            }
            let next = snapshot.displays[(index + 1) % snapshot.displays.count]
            target = Self.moved(window.frame, from: display.visibleFrame, to: next.visibleFrame)
        default:
            guard let frame = Self.frame(layout, window: window.frame, visible: display.visibleFrame, gap: gap) else { return .done }
            target = frame
        }
        // The app's windows front first: this one's place among them.
        let ordinal = snapshot.windows.filter { $0.appID == window.appID }.firstIndex(of: window) ?? 0
        let placement = WindowPlacement(appID: window.appID, appName: window.appName, title: window.title, ordinal: ordinal, frame: target)
        do {
            let result = try await Stackbar.arrangeWindows([placement])
            if !result.failed.isEmpty { return .failure("\(window.appName) didn't let its window move") }
        } catch {
            return .failure("Couldn't move the window: \(error)")
        }
        if layout.id != "restore" { previous[key] = window.frame }
        problem = nil
        notice = "\(window.appName): \(layout.title)"
        return .done
    }

    // MARK: Commands

    var commands: [Command] {
        for layout in Self.layouts {
            Command(layout.id, title: layout.title, subtitle: "Window Layouts", symbol: layout.symbol, keywords: layout.keywords + ["window", "layout"]) { _ in
                await self.apply(layout)
            }
        }
    }

    // MARK: Panel

    var panel: ViewContent {
        PanelHeader("Window Layouts", subtitle: notice ?? "Snap the front window", symbol: "rectangle.split.2x1", theme: theme)
        if let problem {
            Banner(problem, theme: .warning)
        }
        ForEach(Self.groups) { group in
            Card(group, spacing: Space.xs, padding: Space.s) {
                Grid(columns: 4, spacing: Space.xs) {
                    ForEach(Self.layouts.filter { $0.group == group }) { layout in
                        Button(layout.title, symbol: layout.symbol, key: layout.id) { _ = await self.apply(layout) }
                    }
                }
            }
        }
        Text("Each layout is a command: type its name in the palette, or give it a hotkey in Settings › Commands.").style(.caption).role(.secondary)
    }

    // MARK: Settings

    static let gaps: [(title: String, points: Double)] = [("None", 0), ("Small", 4), ("Medium", 8), ("Large", 16)]

    var settings: ViewContent {
        Section("Snapping") {
            Picker("Gap around windows", options: Self.gaps.map(\.title), selection: Self.gaps.first { $0.points == gap }?.title ?? "None", style: .segmented) { title in
                self.gap = Self.gaps.first { $0.title == title }?.points ?? 0
            }
        }
    }
}
