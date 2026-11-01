import StackbarKit
import Foundation

/// What's playing in Music or Spotify, in the menu bar. Click to play or
/// pause; the panel has the track, previous, next and volume.
///
/// It asks the player over AppleScript (`osascript`, run by Stackbar every 5
/// seconds) and never opens a player that isn't running, unless you press
/// Play with nothing playing. macOS asks once whether Stackbar may control
/// Music or Spotify.
@main
final class Music: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.music",
        name: "Music",
        version: "1.1.0",
        summary: "What's playing in Music or Spotify, with play, pause, skip and volume.",
        surfaces: [.menuBar, .panel, .widget, .settings],
        triggers: [.launch, .every(.seconds(5)), .wake],
        // osascript is the only way to talk to Music and Spotify; the
        // scripts are fixed text in this file, never built from input.
        capabilities: [.run(commands: ["osascript"])],
        minimumStackbar: "0.13.0",
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

    /// One line for the player if it is running: state, name, artist,
    /// album, duration (seconds), position (seconds), volume (0-100),
    /// tab-separated. Each player gets its own script, because AppleScript
    /// can't compile one that names an app that isn't installed.
    static func statusScript(for player: Player) -> String {
        let duration = player == .spotify ? "((duration of t) / 1000)" : "(duration of t)"
        return """
        if application "\(player.rawValue)" is running then
            tell application "\(player.rawValue)"
                if player state is not stopped then
                    set t to current track
                    return "\(player.rawValue)" & tab & (player state as text) & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & \(duration) & tab & player position & tab & sound volume
                end if
            end tell
        end if
        return ""
        """
    }

    func refresh() async throws {
        await check()
    }

    func check() async {
        var tracks: [Track] = []
        var denied = false
        var failed: Player?
        for player in Player.allCases {
            guard let result = try? await Stackbar.run("osascript", ["-e", Self.statusScript(for: player)], timeout: .seconds(10)) else {
                failed = player
                continue
            }
            if result.succeeded {
                tracks += Self.parse(result.text)
            } else if result.errorText.contains("-1743") || result.errorText.contains("Not authorized") {
                // -1743: the user said no to automation.
                denied = true
            } else if !(result.errorText.contains("-2741") || result.errorText.contains("-2740") || result.errorText.contains("-1728")) {
                // A compile error means the player isn't installed; anything else is worth saying.
                failed = player
            }
        }
        checked = true
        if denied && tracks.isEmpty {
            problem = "Stackbar isn't allowed to control the player. Turn it on in System Settings › Privacy & Security › Automation › Stackbar."
        } else if let failed, tracks.isEmpty {
            problem = "\(failed.rawValue) didn't answer. Try again in a moment."
        } else {
            problem = nil
        }
        track = Self.choose(tracks, preferred: Player(rawValue: preferred))
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

    /// Sends a command, then checks what the player is doing now.
    func tell(_ command: String) async throws {
        try await send(command)
        try? await Task.sleep(for: .milliseconds(250))
        await check()
    }

    func send(_ command: String) async throws {
        let player = track?.player ?? Player(rawValue: preferred) ?? .music
        // Fixed commands only: playpause, next track, previous track, set
        // sound volume to a number. With nothing running, playpause opens
        // the preferred player and plays its last track.
        let script = track == nil && command == "playpause"
            ? "tell application \"\(player.rawValue)\" to playpause"
            : "if application \"\(player.rawValue)\" is running then tell application \"\(player.rawValue)\" to \(command)"
        let result = try await Stackbar.run("osascript", ["-e", script], timeout: .seconds(10))
        guard result.succeeded else { throw HostError("\(player.rawValue) didn't answer: \(result.errorText.prefix(160))") }
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

    let theme = Theme.pink

    var menuBar: ViewContent {
        if let track, showInMenuBar != "Icon only" {
            let text = showInMenuBar == "Title" ? track.name : "\(track.name) – \(track.artist)"
            Label(text.count > 24 ? String(text.prefix(23)) + "…" : text, symbol: track.playing ? "music.note" : "pause.fill").role(track.playing ? .primary : .secondary)
        } else {
            Label("", symbol: track?.playing == false ? "pause.fill" : "music.note").role(track?.playing == true ? .primary : .secondary)
        }
    }

    /// The song's span as the host counts it, so the scrubber moves on its
    /// own between checks.
    func timing(_ track: Track) -> TimeRange {
        let start = Date().addingTimeInterval(-track.position)
        return TimeRange(start: start, end: start.addingTimeInterval(track.duration))
    }

    /// The album-art stand-in: the theme's gradient with a note.
    func artwork(size: Double, dimmed: Bool = false) -> some StackbarView {
        Image(systemName: "music.note").font(size: (size * 0.4).rounded(), weight: .semibold).foreground(theme.onSolidPaint)
            .frame(width: size, height: size)
            .background(theme.gradient, in: .roundedRectangle(cornerRadius: (size * 0.19).rounded()))
            .opacity(dimmed ? 0.5 : 1)
    }

    var panel: ViewContent {
        if let problem {
            EmptyState("Can't reach the player", symbol: problem.contains("allowed") ? "lock.shield" : "exclamationmark.triangle", message: problem, theme: .warning) {
                ActionButton("Try Again", symbol: "arrow.clockwise", theme: theme, prominent: true) { await self.check() }
            }
        } else {
            HeroCard(theme: theme) {
                HStack(spacing: Space.m) {
                    artwork(size: 64, dimmed: track == nil)
                    VStack(spacing: Space.xxs) {
                        if let track {
                            Text(track.name).typography(.title)
                            if !track.artist.isEmpty { Text(track.artist).role(.secondary).typography(.body) }
                            if !track.album.isEmpty { Text(track.album).role(.secondary).typography(.caption) }
                        } else {
                            Text(checked ? "Nothing playing" : "Checking…").typography(.title)
                            Text("Start something in Music or Spotify").role(.secondary).typography(.caption)
                        }
                    }
                    .frame(fillWidth: true, alignment: .leading)
                    if let track {
                        Pill(track.player.rawValue, theme: theme)
                    }
                }
                if let track, track.duration > 0 {
                    VStack(spacing: Space.xs) {
                        if track.playing {
                            let range = timing(track)
                            ProgressBar(timing: range).foreground(theme.solidPaint)
                            HStack {
                                TimerText(range, countsDown: false).typography(.captionNumber).foreground(.role(.secondary))
                                Spacer()
                                TimerText(range).typography(.captionNumber).foreground(.role(.secondary))
                            }
                        } else {
                            ProgressBar(value: min(track.position, track.duration), total: track.duration).foreground(theme.solidPaint)
                            HStack {
                                Text(Self.time(track.position)).role(.secondary).typography(.captionNumber)
                                Spacer()
                                Text("-" + Self.time(max(0, track.duration - track.position))).role(.secondary).typography(.captionNumber)
                            }
                        }
                    }
                }
                HStack(spacing: Space.xl) {
                    Spacer()
                    IconButton("backward.fill", label: "Previous", theme: theme, prominence: .tinted, size: 36) { try await self.tell("previous track") }
                    IconButton(track?.playing == true ? "pause.fill" : "play.fill", label: track?.playing == true ? "Pause" : "Play",
                               theme: theme, prominence: .filled, size: 52, key: "playpause") { try await self.tell("playpause") }
                    IconButton("forward.fill", label: "Next", theme: theme, prominence: .tinted, size: 36) { try await self.tell("next track") }
                    Spacer()
                }
            }
            if let track {
                HStack(spacing: Space.s) {
                    Image(systemName: "speaker.fill").font(size: 11).foreground(.role(.secondary))
                    Slider("Volume", value: track.volume, in: 0...100, step: 5) { value in
                        // Set it here rather than asking again on every step of a drag.
                        self.track?.volume = value
                        try await self.send("set sound volume to \(Int(value))")
                    }
                    Image(systemName: "speaker.wave.3.fill").font(size: 11).foreground(.role(.secondary))
                }
                .padding(horizontal: Space.xs)
            }
        }
    }

    var widget: ViewContent {
        HStack(spacing: Space.m) {
            artwork(size: 56, dimmed: track == nil)
            VStack(spacing: Space.xxs) {
                Text(track?.name ?? "Nothing playing").typography(.headline)
                if let track, !track.artist.isEmpty { Text(track.artist).role(.secondary).typography(.caption) }
                if let track, track.playing, track.duration > 0 {
                    ProgressBar(timing: timing(track)).foreground(theme.solidPaint)
                }
            }
            .frame(fillWidth: true, alignment: .leading)
        }
        .frame(fillWidth: true, fillHeight: true)
    }

    var settings: ViewContent {
        Section("Player") {
            Picker("Follow", options: ["Whichever is playing"] + Player.allCases.map(\.rawValue), selection: preferred) { choice in
                self.preferred = choice
                await self.check()
            }
        }
        Section("Menu bar") {
            Picker("Show", options: ["Title and artist", "Title", "Icon only"], selection: showInMenuBar, style: .segmented) { self.showInMenuBar = $0 }
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
