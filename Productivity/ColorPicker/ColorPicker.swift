import StackbarKit
import Foundation

/// Picks a color from anywhere on screen with the system magnifier and
/// copies it as hex, RGB or HSL, as Raycast's Pick Color does. The last
/// colors picked stay in a list, so a palette you're matching is a few
/// keys away.
@main
final class ColorPicker: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.color-picker",
        name: "Color Picker",
        version: "1.2.0",
        summary: "Pick a color from anywhere on screen and copy it as hex, RGB or HSL.",
        surfaces: [.panel, .settings],
        triggers: [.launch],
        capabilities: [],
        minimumStackbar: "0.35.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/ColorPicker",
        accent: .pink,
        symbol: "eyedropper"
    )

    // MARK: Previews

    static let previews: [PreviewScene<ColorPicker>] = [
        PreviewScene("hero", "Any pixel, copied as hex, RGB or HSL") { plugin in
            let now = Date()
            plugin.history = ["#0A60C8", "#FF5FA2", "#34C759", "#FFB020", "#1C1C1E", "#8E7CFF"].enumerated().map { Picked(hex: $1, at: now.addingTimeInterval(Double(-$0) * 900)) }
        },
        PreviewScene("rgb", "Copy in the format your code wants") { plugin in
            plugin.history = ["#0A60C8", "#FF5FA2", "#34C759"].map { Picked(hex: $0, at: Date()) }
            plugin.format = "RGB"
        },
    ]

    let theme = Theme.pink

    enum Format: String, CaseIterable {
        case hex = "Hex", rgb = "RGB", hsl = "HSL", swiftUI = "SwiftUI"
    }

    struct Picked: Codable, Equatable, Identifiable {
        var hex: String
        var at: Date
        var id: String { hex }
    }

    /// Newest first, one entry per color.
    @Stored("history") var history: [Picked] = []
    @Stored("format") var format = Format.hex.rawValue
    static let historyLimit = 30
    /// The hex color typed into Convert Color, if it reads as one.
    var converted: PickedColor?

    static func text(_ color: PickedColor, as format: Format) -> String {
        switch format {
        case .hex: return color.hex
        case .rgb: return color.rgb
        case .hsl: return color.hsl
        case .swiftUI: return String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", color.red, color.green, color.blue)
        }
    }

    var chosenFormat: Format { Format(rawValue: format) ?? .hex }

    func remember(_ color: PickedColor) {
        history = Array(([Picked(hex: color.hex, at: Date())] + history.filter { $0.hex != color.hex }).prefix(Self.historyLimit))
    }

    /// Shows the magnifier; nil when the person pressed Escape.
    func pick() async throws -> String? {
        guard let color = try await Stackbar.pickColor() else { return nil }
        remember(color)
        let text = Self.text(color, as: chosenFormat)
        Stackbar.copy(text)
        return text
    }

    func row(_ picked: Picked) -> Row {
        guard let color = PickedColor(hex: picked.hex) else { return Row(picked.hex) }
        var row = Row(Self.text(color, as: chosenFormat), subtitle: Format.allCases.filter { $0 != chosenFormat }.map { Self.text(color, as: $0) }.joined(separator: " · "), symbol: "circle.fill", key: picked.hex)
            .preview(text: "\(color.hex)\n\(color.rgb)\n\(color.hsl)", caption: picked.at.formatted(date: .abbreviated, time: .shortened))
        // The chosen format first, so Return copies it. ⌘1 to ⌘9 belong to the host (they pick a row), so these use ⌘⇧ letters.
        let shortcuts: [Format: String] = [.hex: "cmd+shift+x", .rgb: "cmd+shift+r", .hsl: "cmd+shift+l", .swiftUI: "cmd+shift+s"]
        for format in [chosenFormat] + Format.allCases.filter({ $0 != chosenFormat }) {
            row = row.action("Copy \(format.rawValue)", shortcut: shortcuts[format]) { Stackbar.copy(Self.text(color, as: format)) }
        }
        return row.action("Remove", shortcut: "ctrl+x", role: .critical, confirm: .none) { self.history.removeAll { $0.hex == picked.hex } }
    }

    // MARK: Commands

    var commands: [Command] {
        Command("pick", title: "Pick Color", subtitle: "Click anywhere on screen to copy its color", symbol: "eyedropper", keywords: ["color", "colour", "eyedropper", "hex", "picker"]) { _ in
            guard let text = try await self.pick() else { return .message("No color picked") }
            return .message("Copied \(text)")
        }
        Command("history", title: "Picked Colors", subtitle: "The colors you picked, to copy again", symbol: "swatchpalette", keywords: ["color", "colour", "history", "palette"])
            .view { _ in
                if self.history.isEmpty {
                    ContentUnavailableView("No colors yet", symbol: "eyedropper", message: "Run Pick Color and click anywhere on screen.")
                } else {
                    List {
                        ForEach(self.history) { picked in self.row(picked) }
                    }
                }
            }
        Command("convert", title: "Convert Color", subtitle: "Type a hex color to copy it as RGB, HSL or SwiftUI", symbol: "swatchpalette", keywords: ["color", "colour", "hex", "rgb", "hsl", "convert"])
            .view(search: { invocation in
                self.converted = PickedColor(hex: invocation.text.trimmingCharacters(in: .whitespaces))
            }) { _ in
                if let color = self.converted {
                    List {
                        ForEach(Format.allCases.map(\.rawValue)) { name in
                            let format = Format(rawValue: name) ?? .hex
                            Row(Self.text(color, as: format), subtitle: name, symbol: "circle.fill", key: "convert-\(name)")
                                .action("Copy \(name)") { Stackbar.copy(Self.text(color, as: format)) }
                        }
                    }
                } else {
                    ContentUnavailableView("Type a hex color", symbol: "swatchpalette", message: "Like #0A60C8 or #FA0.")
                }
            }
            .rootSearch(section: "Color", matching: #"#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})"#)
    }

    // MARK: Surfaces

    var panel: ViewContent {
        PanelHeader("Color Picker", subtitle: "Copies as \(chosenFormat.rawValue)", symbol: "eyedropper", theme: theme)
        Button("Pick a Color", symbol: "eyedropper") { _ = try await self.pick() }
        if history.isEmpty {
            EmptyState("Any pixel, one click", symbol: "eyedropper", message: "Pick a color and it's copied. Picked Colors in the palette keeps the last \(Self.historyLimit).", theme: theme)
        } else {
            List {
                Section("Recent") {
                    ForEach(history.prefix(8)) { picked in self.row(picked) }
                }
            }
        }
    }

    var settings: ViewContent {
        Section("Copying") {
            Picker("Copy as", options: Format.allCases.map(\.rawValue), selection: format) { self.format = $0 }
        }
        Section("History") {
            Button("Clear Picked Colors", symbol: "trash", role: .critical, key: "clear", confirm: "clear \(history.count) picked color\(history.count == 1 ? "" : "s")") {
                self.history = []
            }
        }
    }
}
