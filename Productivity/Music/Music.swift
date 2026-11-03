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
        version: "1.2.1",
        summary: "What's playing in Music or Spotify, with play, pause, skip and volume.",
        surfaces: [.menuBar, .panel, .widget, .settings],
        triggers: [.launch, .every(.seconds(5)), .wake],
        // osascript is the only way to talk to Music and Spotify; the
        // scripts are fixed text in this file, never built from input.
        // Album art: Spotify names its own image URL; for Music the cover
        // is looked up in the iTunes catalog by artist and album.
        capabilities: [.run(commands: ["osascript"]), .network("itunes.apple.com", "*.mzstatic.com", "i.scdn.co")],
        minimumStackbar: "0.14.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/Music",
        accent: .pink,
        symbol: "music.note"
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
        /// Spotify's cover, straight from the player.
        var artworkURL: String?
    }

    var track: Track?
    var problem: String?
    var checked = false
    /// Covers found in the iTunes catalog, by "artist|album"; "" when there is none.
    var covers: [String: String] = [:]

    @Stored("preferred") var preferred = "Whichever is playing"
    @Stored("showInMenuBar") var showInMenuBar = "Title and artist"

    /// One line for the player if it is running: state, name, artist,
    /// album, duration (seconds), position (seconds), volume (0-100),
    /// tab-separated. Each player gets its own script, because AppleScript
    /// can't compile one that names an app that isn't installed.
    static func statusScript(for player: Player) -> String {
        let duration = player == .spotify ? "((duration of t) / 1000)" : "(duration of t)"
        let artwork = player == .spotify ? "(artwork url of t)" : "\"\""
        return """
        if application "\(player.rawValue)" is running then
            tell application "\(player.rawValue)"
                if player state is not stopped then
                    set t to current track
                    return "\(player.rawValue)" & tab & (player state as text) & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & \(duration) & tab & player position & tab & sound volume & tab & \(artwork)
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
        if let track, track.artworkURL == nil { await findCover(track) }
    }

    struct CatalogResults: Decodable {
        struct Item: Decodable { var artworkUrl100: String? }
        var results: [Item]
    }

    /// Looks the album up once in the iTunes catalog, for Music, which has no
    /// cover URL of its own.
    func findCover(_ track: Track) async {
        let key = "\(track.artist)|\(track.album)"
        guard covers[key] == nil, !track.artist.isEmpty || !track.album.isEmpty else { return }
        covers[key] = ""
        var query = URLComponents(string: "https://itunes.apple.com/search")
        query?.queryItems = [URLQueryItem(name: "term", value: "\(track.artist) \(track.album)"), URLQueryItem(name: "entity", value: "album"), URLQueryItem(name: "limit", value: "1")]
        guard let url = query?.url?.absoluteString,
              let found = try? await Stackbar.getJSON(url, as: CatalogResults.self),
              let small = found.results.first?.artworkUrl100 else { return }
        covers[key] = Self.largeCover(small)
    }

    /// The catalog's 100-pixel cover URL asked for at 600.
    static func largeCover(_ url: String) -> String {
        url.replacingOccurrences(of: "100x100bb", with: "600x600bb")
    }

    /// The cover for a track: Spotify's own, else the catalog's.
    func cover(_ track: Track?) -> String? {
        guard let track else { return nil }
        if let url = track.artworkURL { return url }
        let found = covers["\(track.artist)|\(track.album)"]
        return found?.isEmpty == false ? found : nil
    }

    /// `text` cut to `limit` characters with an ellipsis.
    static func clipped(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    static func parse(_ output: String) -> [Track] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 8, let player = Player(rawValue: fields[0]) else { return nil }
            func number(_ text: String) -> Double { Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0 }
            let artwork = fields.count > 8 && fields[8].hasPrefix("https://") ? fields[8] : nil
            return Track(player: player, playing: fields[1] == "playing", name: fields[2], artist: fields[3], album: fields[4], duration: number(fields[5]), position: number(fields[6]), volume: number(fields[7]), artworkURL: artwork)
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

    /// The cover, or the theme's vivid square with a note until it loads.
    func artwork(_ track: Track?, size: Double) -> some StackbarView {
        ZStack {
            Image(systemName: "music.note").font(size: (size * 0.4).rounded(), weight: .semibold).foreground(theme.onSolidPaint)
                .frame(width: size, height: size)
                .background(theme.vivid)
            if let url = cover(track) { Image(url: url) }
        }
        .frame(width: size, height: size)
        .clipShape(.roundedRectangle(cornerRadius: (size * 0.16).rounded()))
        .shadow(radius: 10, y: 5, color: HexColor("#00000059"))
        .accessibilityLabel(track.map { "Cover of \($0.album.isEmpty ? $0.name : $0.album)" } ?? "No cover")
    }

    /// Bars that dance while playing, a pause mark when not.
    func liveMark(_ track: Track) -> some StackbarView {
        HStack(spacing: Space.xs) {
            if track.playing {
                Image(systemName: "waveform").font(size: 10, weight: .bold).symbolEffect(.variableColor)
            } else {
                Image(systemName: "pause.fill").font(size: 9, weight: .bold)
            }
            Text((track.playing ? "Playing in " : "Paused in ") + track.player.rawValue).typography(.overline)
        }
        .opacity(0.85)
    }

    func scrubber(_ track: Track) -> some StackbarView {
        VStack(spacing: Space.xs) {
            if track.playing {
                let range = timing(track)
                ProgressBar(timing: range).foreground(.onMedia)
                HStack {
                    TimerText(range, countsDown: false).typography(.captionNumber)
                    Spacer()
                    HStack(spacing: 0) {
                        Text("-").typography(.captionNumber)
                        TimerText(range).typography(.captionNumber)
                    }
                }
                .opacity(0.8)
            } else {
                ProgressBar(value: min(track.position, track.duration), total: track.duration).foreground(.onMedia)
                HStack {
                    Text(Self.time(track.position)).typography(.captionNumber)
                    Spacer()
                    Text("-" + Self.time(max(0, track.duration - track.position))).typography(.captionNumber)
                }
                .opacity(0.8)
            }
        }
    }

    var transport: some StackbarView {
        HStack {
            Spacer()
            GlassBar(spacing: Space.m) {
                IconButton("backward.fill", label: "Previous", prominence: .onMedia, size: 34) { try await self.tell("previous track") }
                IconButton(track?.playing == true ? "pause.fill" : "play.fill", label: track?.playing == true ? "Pause" : "Play",
                           theme: theme, prominence: .filled, size: 44, key: "playpause") { try await self.tell("playpause") }
                IconButton("forward.fill", label: "Next", prominence: .onMedia, size: 34) { try await self.tell("next track") }
            }
            Spacer()
        }
    }

    var panel: ViewContent {
        if let problem {
            EmptyState("Can't reach the player", symbol: problem.contains("allowed") ? "lock.shield" : "exclamationmark.triangle", message: problem, theme: .warning) {
                ActionButton("Try Again", symbol: "arrow.clockwise", theme: theme, prominent: true) { await self.check() }
            }
        } else if let track {
            Backdrop(imageURL: cover(track), theme: theme, height: track.duration > 0 ? 250 : 206, blur: 36) {
                HStack(alignment: .end, spacing: Space.m) {
                    artwork(track, size: 88)
                    VStack(spacing: Space.xxs) {
                        liveMark(track)
                        Text(Self.clipped(track.name, 44)).typography(Typography(size: 17, weight: .bold))
                        if !track.artist.isEmpty { Text(Self.clipped(track.artist, 40)).typography(.body).opacity(0.9) }
                        if !track.album.isEmpty { Text(Self.clipped(track.album, 44)).typography(.caption).opacity(0.75) }
                    }
                    .frame(fillWidth: true, alignment: .leading)
                }
                if track.duration > 0 { scrubber(track) }
                transport
            }
            HStack(spacing: Space.s) {
                Image(systemName: "speaker.fill").font(size: 11).foreground(.role(.secondary))
                Slider("Volume", value: track.volume, in: 0...100) { value in
                    // Set it here rather than asking again on every step of a drag.
                    self.track?.volume = value
                    try await self.send("set sound volume to \(Int(value))")
                }
                .foreground(theme.solidPaint)
                Image(systemName: "speaker.wave.3.fill").font(size: 11).foreground(.role(.secondary))
            }
            .padding(horizontal: Space.xs)
        } else {
            Backdrop(theme: theme, height: 196, alignment: .center) {
                Image(systemName: "music.note.list").font(size: 34, weight: .semibold).symbolEffect(.breathe)
                Text(checked ? "Nothing playing" : "Checking…").typography(.title)
                Text("Start something in Music or Spotify, or press play.").typography(.caption).opacity(0.85)
                transport
            }
        }
    }

    var widget: ViewContent {
        Backdrop(imageURL: cover(track), theme: theme, height: 131, blur: 30) {
            HStack(alignment: .end, spacing: Space.m) {
                artwork(track, size: 56)
                VStack(spacing: Space.xxs) {
                    if let track {
                        liveMark(track)
                        Text(Self.clipped(track.name, 30)).typography(.headline)
                        if !track.artist.isEmpty { Text(Self.clipped(track.artist, 32)).typography(.caption).opacity(0.85) }
                    } else {
                        Text("Nothing playing").typography(.headline)
                    }
                }
                .frame(fillWidth: true, alignment: .leading)
            }
            if let track, track.playing, track.duration > 0 {
                ProgressBar(timing: timing(track)).foreground(.onMedia)
            }
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
