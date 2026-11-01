import StackbarKit
import Foundation

/// What's playing in Music or Spotify, in the menu bar. Click to play or
/// pause; the panel has the track, previous, next and volume.
///
/// It asks the player over AppleScript (`osascript`, run by Stackbar every 5
/// seconds) and never opens a player that isn't running. macOS asks once
/// whether Stackbar may control Music or Spotify.
@main
final class Music: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.music",
        name: "Music",
        version: "1.0.0",
        summary: "What's playing in Music or Spotify, with play, pause, skip and volume.",
        surfaces: [.menuBar, .panel, .widget, .settings],
        triggers: [.launch, .every(.seconds(5)), .wake],
        // osascript is the only way to talk to Music and Spotify; the
        // scripts are fixed text in this file, never built from input.
        capabilities: [.run(commands: ["osascript"])],
        minimumStackbar: "0.11.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/Music"
    )

    enum Player: String, CaseIterable {
        case music = "Music"
        case spotify = "Spotify"
    }

    struct Track: Equatable {
        var player: Player
        var playing: Bool
        var name: String
        var artist: String
        var album: String
        var duration: Double
        var position: Double
        var volume: Double
    }

    var track: Track?
    var problem: String?
    var checked = false

    @Stored("preferred") var preferred = "Whichever is playing"
    @Stored("showInMenuBar") var showInMenuBar = "Title and artist"

    /// One line per running player: state, name, artist, album, duration
    /// (seconds), position (seconds), volume (0-100), tab-separated.
    static let statusScript = """
    set output to ""
    if application "Music" is running then
        tell application "Music"
            if player state is not stopped then
                set t to current track
                set output to output & "Music" & tab & (player state as text) & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & (duration of t) & tab & player position & tab & sound volume & linefeed
            end if
        end tell
    end if
    if application "Spotify" is running then
        tell application "Spotify"
            if player state is not stopped then
                set t to current track
                set output to output & "Spotify" & tab & (player state as text) & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & ((duration of t) / 1000) & tab & player position & tab & sound volume & linefeed
            end if
        end tell
    end if
    return output
    """

    func refresh() async throws {
        await check()
    }

    func check() async {
        do {
            let result = try await Stackbar.run("osascript", ["-e", Self.statusScript], timeout: .seconds(10))
            checked = true
            guard result.succeeded else {
                // -1743: the user said no to automation.
                problem = result.errorText.contains("-1743") || result.errorText.contains("Not authorized")
                    ? "Stackbar isn't allowed to control the player. Turn it on in System Settings > Privacy & Security > Automation > Stackbar."
                    : "The player didn't answer: \(result.errorText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))"
                return
            }
            track = Self.choose(Self.parse(result.text), preferred: Player(rawValue: preferred))
            problem = nil
        } catch {
            checked = true
            problem = "\(error)"
        }
    }

    static func parse(_ output: String) -> [Track] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 8, let player = Player(rawValue: fields[0]) else { return nil }
            func number(_ text: String) -> Double { Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0 }
            return Track(player: player, playing: fields[1] == "playing", name: fields[2], artist: fields[3], album: fields[4], duration: number(fields[5]), position: number(fields[6]), volume: number(fields[7]))
        }
    }

    /// The preferred player if it has a track, else the one playing, else any.
    static func choose(_ tracks: [Track], preferred: Player?) -> Track? {
        if let preferred, let track = tracks.first(where: { $0.player == preferred }) { return track }
        return tracks.first(where: \.playing) ?? tracks.first
    }

    func tell(_ command: String) async throws {
        let player = track?.player ?? Player(rawValue: preferred) ?? .music
        // Fixed commands only: playpause, next track, previous track, set
        // sound volume to a number.
        let result = try await Stackbar.run("osascript", ["-e", "if application \"\(player.rawValue)\" is running then tell application \"\(player.rawValue)\" to \(command)"], timeout: .seconds(10))
        guard result.succeeded else { throw HostError("\(player.rawValue) didn't answer: \(result.errorText.prefix(160))") }
        try? await Task.sleep(for: .milliseconds(250))
        await check()
    }

    static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Surfaces

    var menuBarClick: MenuBarAction? {
        guard let track else { return nil }
        return MenuBarAction(track.playing ? "Click to pause" : "Click to play") { try await self.tell("playpause") }
    }

    var menuBar: ViewContent {
        if let track, showInMenuBar != "Icon only" {
            let text = showInMenuBar == "Title" ? track.name : "\(track.name) – \(track.artist)"
            Label(text.count > 32 ? String(text.prefix(31)) + "…" : text, symbol: track.playing ? "music.note" : "pause.fill").role(track.playing ? .primary : .secondary)
        } else {
            Label("", symbol: track?.playing == true ? "music.note" : "music.note").role(track == nil ? .secondary : .primary)
        }
    }

    var panel: ViewContent {
        if let problem {
            ContentUnavailableView("Can't reach the player", symbol: "music.note", message: problem)
        } else if let track {
            Text(track.name).style(.headline)
            Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " — ")).style(.caption)
            if track.duration > 0 {
                ProgressBar("\(Self.time(track.position)) / \(Self.time(track.duration))", value: min(track.position, track.duration), total: track.duration)
            }
            HStack {
                Button("Previous", symbol: "backward.fill") { try await self.tell("previous track") }
                Button(track.playing ? "Pause" : "Play", symbol: track.playing ? "pause.fill" : "play.fill", role: .accent, key: "playpause") { try await self.tell("playpause") }
                Button("Next", symbol: "forward.fill") { try await self.tell("next track") }
            }
            Slider("Volume", value: track.volume, in: 0...100, step: 5) { value in
                try await self.tell("set sound volume to \(Int(value))")
            }
            Text("Playing in \(track.player.rawValue)").style(.caption)
        } else if checked {
            ContentUnavailableView("Nothing playing", symbol: "music.note", message: "Start something in Music or Spotify.")
        } else {
            ContentUnavailableView("Checking…", symbol: "music.note")
        }
    }

    var widget: ViewContent {
        if let track {
            Text(track.name).style(.headline)
            Text(track.artist).style(.caption)
        } else {
            Text("Nothing playing").style(.caption)
        }
    }

    var settings: ViewContent {
        Section("Player") {
            Picker("Follow", options: ["Whichever is playing"] + Player.allCases.map(\.rawValue), selection: preferred) { choice in
                self.preferred = choice
                await self.check()
            }
        }
        Section("Menu bar") {
            Picker("Show", options: ["Title and artist", "Title", "Icon only"], selection: showInMenuBar) { self.showInMenuBar = $0 }
            Text("Click the menu-bar item to play or pause; right-click for the panel.").style(.caption)
        }
    }

    // MARK: Commands

    var commands: [Command] {
        Command("play-pause", title: "Play or Pause Music", symbol: "playpause.fill", keywords: ["music", "spotify", "play", "pause"]) { _ in
            await self.check()
            try await self.tell("playpause")
            return .message(self.track.map { "\($0.playing ? "Playing" : "Paused") \($0.name)" } ?? "Done")
        }
        Command("next", title: "Next Track", symbol: "forward.fill", keywords: ["music", "spotify", "skip"]) { _ in
            await self.check()
            try await self.tell("next track")
            return .message(self.track.map { "\($0.name) – \($0.artist)" } ?? "Skipped")
        }
        Command("previous", title: "Previous Track", symbol: "backward.fill", keywords: ["music", "spotify", "back"]) { _ in
            await self.check()
            try await self.tell("previous track")
            return .done
        }
        Command("copy-track", title: "Copy Current Track", symbol: "doc.on.doc", keywords: ["music", "spotify", "song", "share"]) { _ in
            await self.check()
            guard let track = self.track else { return .failure("Nothing is playing") }
            return .copy("\(track.name) – \(track.artist)")
        }
    }

    var tools: [AgentTool] {
        AgentTool("now_playing", description: "The track playing in Music or Spotify") { _ in
            await self.check()
            guard let track = self.track else { return self.problem ?? "Nothing playing" }
            return "\(track.playing ? "playing" : "paused") in \(track.player.rawValue): \(track.name) by \(track.artist) from \(track.album), \(Self.time(track.position)) of \(Self.time(track.duration))"
        }
    }
}
