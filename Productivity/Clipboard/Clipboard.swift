import StackbarKit
import Foundation

/// Clipboard history: everything you copy, searchable, pinnable and one
/// keystroke from being pasted back.
///
/// ⌘⇧V opens it from anywhere. Type to filter, ↑↓ and Return (or ⌘1...⌘9)
/// to paste into the app you were in, ⌥Return to paste as plain text, ⌘P to
/// pin, ⌥⌫ to delete. Formatted text keeps its formatting. Pinned items stay
/// at the top and are never trimmed. Passwords are skipped: the host never hands out items an app
/// marks as concealed or transient, and items from password managers (or any
/// app you add) are ignored. Images are kept by the host and pasted back.
@main
final class Clipboard: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.clipboard",
        name: "Clipboard History",
        version: "1.3.0",
        summary: "Everything you copy, searchable and one keystroke from pasting back.",
        surfaces: [.menuBar, .panel, .window, .settings],
        triggers: [.launch, .clipboard],
        capabilities: [.clipboard],
        hotkey: "cmd+shift+v",
        minimumStackbar: "0.14.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/Clipboard"
    )

    struct Entry: Codable, Equatable {
        var id: String
        var kind: ClipboardItem.Kind
        var text: String?
        var files: [String] = []
        var imageID: String?
        var imageSize: [Int]?
        /// The host's copy of the original, formatting included.
        var contentID: String?
        var appID: String?
        var appName: String?
        var firstCopied: Date
        var lastCopied: Date
        var count: Int = 1
        var pinned = false

        /// What makes two copies the same item.
        var fingerprint: String {
            switch kind {
            case .image: return "image:" + (imageID ?? id)
            case .files: return "files:" + files.joined(separator: "\n")
            case .text, .url: return "text:" + (text ?? "")
            }
        }

        var content: ClipboardContent {
            switch kind {
            case .image: return .image(id: imageID ?? "")
            case .files: return .files(files)
            case .text, .url: return contentID.map { .stored(id: $0) } ?? .text(text ?? "")
            }
        }

        var plainText: String? {
            switch kind {
            case .text, .url, .files: return text
            case .image: return nil
            }
        }

        var title: String {
            switch kind {
            case .image:
                let size = imageSize.map { "\($0.first ?? 0)×\($0.last ?? 0)" } ?? ""
                return "Image \(size)".trimmingCharacters(in: .whitespaces)
            case .files:
                let names = files.map { ($0 as NSString).lastPathComponent }
                return names.count == 1 ? names[0] : "\(names.count) files: " + names.prefix(3).joined(separator: ", ")
            case .text, .url:
                let line = (text ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let shown = trimmed.isEmpty ? "(whitespace)" : trimmed
                return shown.count > 90 ? String(shown.prefix(89)) + "…" : shown
            }
        }

        var symbol: String {
            switch kind {
            case .text: return contentID == nil ? "doc.plaintext" : "doc.richtext"
            case .url: return "link"
            case .files: return "doc.on.doc"
            case .image: return "photo"
            }
        }

        var bytes: Int { (text?.utf8.count ?? 0) + files.reduce(0) { $0 + $1.utf8.count } + 200 }
    }

    enum Order: String, CaseIterable, Codable {
        case recent = "Last copied"
        case first = "First copied"
        case frequent = "Most used"
    }

    /// Password managers whose copies are never recorded, on top of the
    /// concealed-type marker most of them already set.
    static let defaultIgnored = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc",
    ]

    /// The plugin's 1 MB of storage, less room for settings.
    static let storageBudget = 850_000
    static let maxEntryCharacters = 100_000

    @Stored("limit") var limit = 200.0
    @Stored("order") var order = Order.recent
    @Stored("pasteDirectly") var pasteDirectly = true
    @Stored("keepImages") var keepImages = true
    @Stored("ignoredApps") var ignoredApps = Clipboard.defaultIgnored
    @Stored("paused") var paused = false
    @Stored("plainByDefault") var plainByDefault = false
    /// Regular expressions; a copy whose text matches one is not recorded
    /// (tokens, one-time codes).
    @Stored("ignoredPatterns") var ignoredPatterns: [String] = []
    /// Copies recorded per day (yyyy-MM-dd), for the last 30 days.
    @Stored("copiesByDay") var copiesByDay: [String: Int] = [:]

    /// The history, read from storage once and written back when it changes
    /// (a `@Stored` array would be decoded on every render).
    private var cached: [Entry]?
    private var lastChange: Int?
    private var ignoreNext = false
    /// When this plugin last put something on the clipboard, so its own
    /// writes don't count as new copies from whichever app is frontmost.
    private var lastWrite: Date?
    var lastError: String?
    /// A pattern typed in Settings that isn't a regex, shown where it was typed.
    var settingsError: String?

    var entries: [Entry] {
        get {
            if let cached { return cached }
            let loaded = Stackbar.storage.value("history", as: [Entry].self) ?? []
            cached = loaded
            return loaded
        }
        set {
            cached = newValue
            Stackbar.storage.set("history", newValue)
        }
    }

    // MARK: Recording

    func refresh() async throws {
        guard let item = try await Stackbar.clipboard() else { return }
        // The first read after a launch records what is on the clipboard
        // now; if it is already in the history it just moves to the top.
        defer { lastChange = item.changeCount }
        guard item.changeCount != lastChange else { return }
        if ignoreNext {
            ignoreNext = false
            return
        }
        guard !paused, !item.concealed else { return }
        if let app = item.sourceAppID, isIgnored(app: app, name: item.sourceAppName) { return }
        if item.kind == .image && !keepImages { return }
        if let text = item.text, matchesIgnoredPattern(text) { return }
        record(item)
    }

    func record(_ item: ClipboardItem) {
        var entry = Entry(
            id: UUID().uuidString, kind: item.kind, text: item.text.map { String($0.prefix(Self.maxEntryCharacters)) }, files: item.files,
            imageID: item.imageID, imageSize: item.imageSize, contentID: item.contentID, appID: item.sourceAppID, appName: item.sourceAppName,
            firstCopied: item.copiedAt, lastCopied: item.copiedAt
        )
        if entry.kind != .image && entry.kind != .files && (entry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        // Our own paste coming back says nothing new about where it came from.
        let ownWrite = item.sourceAppID == "io.navbytes.stackbar" || (lastWrite.map { item.copiedAt.timeIntervalSince($0) < 3 } ?? false)
        var history = entries
        if let index = history.firstIndex(where: { $0.fingerprint == entry.fingerprint }) {
            var existing = history.remove(at: index)
            existing.lastCopied = item.copiedAt
            existing.contentID = item.contentID ?? existing.contentID
            if !ownWrite {
                existing.count += 1
                existing.appID = item.sourceAppID ?? existing.appID
                existing.appName = item.sourceAppName ?? existing.appName
            }
            entry = existing
        }
        history.insert(entry, at: 0)
        entries = trimmed(history)
        if !ownWrite { countCopy(on: item.copiedAt) }
    }

    func countCopy(on date: Date) {
        var days = copiesByDay
        days[Self.day(date), default: 0] += 1
        let oldest = Self.day(date.addingTimeInterval(-29 * 86400))
        copiesByDay = days.filter { $0.key >= oldest }
    }

    static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Drops the oldest unpinned items past the limit or the storage budget.
    func trimmed(_ history: [Entry]) -> [Entry] {
        var kept: [Entry] = []
        var unpinned = 0
        var bytes = 0
        for entry in history {
            bytes += entry.bytes
            if entry.pinned {
                kept.append(entry)
                continue
            }
            guard unpinned < Int(limit), bytes <= Self.storageBudget else { continue }
            unpinned += 1
            kept.append(entry)
        }
        return kept
    }

    func matchesIgnoredPattern(_ text: String) -> Bool {
        ignoredPatterns.contains { pattern in
            (try? Regex(pattern)).map { text.contains($0) } ?? false
        }
    }

    func isIgnored(app id: String, name: String?) -> Bool {
        ignoredApps.contains { ignored in
            ignored.caseInsensitiveCompare(id) == .orderedSame || (name.map { ignored.caseInsensitiveCompare($0) == .orderedSame } ?? false)
        }
    }

    // MARK: Acting on an entry

    func use(_ entry: Entry, paste: Bool, plain: Bool = false) async {
        let content: ClipboardContent = plain || plainByDefault ? entry.plainText.map { .text($0) } ?? entry.content : entry.content
        lastWrite = Date()
        do {
            if paste {
                try await Stackbar.paste(content)
            } else if case .text(let text) = content {
                Stackbar.copy(text)
            } else {
                try await Stackbar.setClipboard(content)
            }
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    func update(_ id: String, _ change: (inout Entry) -> Void) {
        var history = entries
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        change(&history[index])
        entries = history
    }

    func delete(_ id: String) {
        entries = entries.filter { $0.id != id }
    }

    func clear(keepPinned: Bool = true) {
        entries = keepPinned ? entries.filter(\.pinned) : []
    }

    var sorted: [Entry] {
        let history = entries
        switch order {
        case .recent: return history.sorted { $0.lastCopied > $1.lastCopied }
        case .first: return history.sorted { $0.firstCopied > $1.firstCopied }
        case .frequent: return history.sorted { ($0.count, $0.lastCopied) > ($1.count, $1.lastCopied) }
        }
    }

    // MARK: Surfaces

    var menuBar: ViewContent {
        Label("", symbol: paused ? "pause.circle" : "list.clipboard").role(paused ? .warning : .primary)
    }

    let theme = Theme.blue

    var panel: ViewContent {
        let all = sorted
        let pinned = all.filter(\.pinned)
        let history = all.filter { !$0.pinned }
        let detail = ["⌘⇧V anywhere", pinned.isEmpty ? nil : "\(pinned.count) pinned"].compactMap { $0 }.joined(separator: " · ")
        PanelHeader(paused ? "Paused" : all.count == 1 ? "1 item" : "\(all.count) items", subtitle: detail,
                    symbol: paused ? "pause.circle.fill" : "list.clipboard.fill", theme: paused ? .warning : theme) {
            HStack(spacing: Space.xs) {
                IconButton("eye.slash", label: ignoreNext ? "Next copy will be ignored" : "Ignore next copy", theme: theme,
                           prominence: ignoreNext ? .filled : .plain) { self.ignoreNext.toggle() }
                IconButton(paused ? "play.fill" : "pause.fill", label: paused ? "Resume recording" : "Pause recording",
                           theme: paused ? .warning : theme, prominence: paused ? .filled : .plain) { self.paused.toggle() }
            }
        }
        if let lastError {
            Banner(lastError)
        }
        if all.isEmpty {
            if paused {
                EmptyState("Recording is paused", symbol: "pause.circle", message: "Copies aren't kept until you resume.", theme: .warning) {
                    ActionButton("Resume", symbol: "play.fill", theme: theme, prominent: true) { self.paused = false }
                }
            } else {
                EmptyState("Nothing copied yet", symbol: "list.clipboard", message: "Copy something in any app and it shows up here.", theme: theme)
            }
        } else {
            if let latest = history.first { lastCopied(latest) }
            List(searchable: true) {
                if !pinned.isEmpty {
                    Section("Pinned") {
                        ForEach(pinned) { entry in row(entry) }
                    }
                }
                if !history.isEmpty {
                    Section(pinned.isEmpty ? nil : "History") {
                        ForEach(history) { entry in row(entry) }
                    }
                }
            }
        }
    }

    /// The newest copy as a card: its first lines in a code face, where it
    /// came from, and one button to use it again.
    func lastCopied(_ entry: Entry) -> some StackbarView {
        HeroCard(theme: theme, look: .glow, spacing: Space.s) {
            HStack(spacing: Space.s) {
                IconTile(entry.symbol, theme: theme, size: 30).symbolEffect(.bounce)
                VStack(spacing: 0) {
                    Text("LAST COPIED").typography(.overline).foreground(theme.textPaint)
                    Text([entry.appName, Self.relative(entry.lastCopied)].compactMap { $0 }.joined(separator: " · ")).role(.secondary).typography(.caption)
                }
                Spacer(minLength: Space.xs)
                IconButton(pasteDirectly ? "arrow.down.doc.fill" : "doc.on.doc.fill", label: pasteDirectly ? "Paste" : "Copy", theme: theme,
                           prominence: .filled, size: 32, key: "use-latest") { await self.use(entry, paste: self.pasteDirectly) }
            }
            Text(Self.snippet(entry))
                .typography(Typography(size: 12, design: entry.kind == .text ? .monospaced : .default))
                .padding(Space.s)
                .frame(fillWidth: true, alignment: .leading)
                .background(.raised, in: .roundedRectangle(cornerRadius: Radius.medium))
        }
    }

    /// Up to three lines of a copy, each cut to fit the card.
    static func snippet(_ entry: Entry) -> String {
        guard entry.kind == .text || entry.kind == .url, let text = entry.text else { return entry.title }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let shown = lines.prefix(3).map { $0.count > 52 ? String($0.prefix(51)) + "…" : $0 }
        let more = lines.count > 3 ? "\n+ \(lines.count - 3) more lines" : ""
        return shown.isEmpty ? entry.title : shown.joined(separator: "\n") + more
    }

    /// The window has room for the history and what it says about you.
    var window: ViewContent {
        panel
        insights
    }

    @ViewBuilder var insights: ViewContent {
        let all = entries
        if !all.isEmpty {
            Card("Insights") {
                let calendar = Calendar.current
                let dates = (0..<14).reversed().map { Date().addingTimeInterval(Double(-$0) * 86400) }
                Chart("Copies, last 14 days", values: dates.map { Double(copiesByDay[Self.day($0)] ?? 0) }, kind: .bar, labels: dates.map { String(calendar.component(.day, from: $0)) }, highlight: 13)
                let byApp = Dictionary(grouping: all, by: { $0.appName ?? "Unknown" }).mapValues { $0.reduce(0) { $0 + $1.count } }.sorted { $0.value > $1.value }
                let top = byApp.prefix(5)
                let rest = byApp.dropFirst(5).reduce(0) { $0 + $1.value }
                Chart("Where your copies come from", values: top.map { Double($0.value) } + (rest > 0 ? [Double(rest)] : []), kind: .donut, labels: top.map(\.key) + (rest > 0 ? ["Other"] : []))
                let kinds: [(String, Int)] = [("Text", all.filter { $0.kind == .text }.count), ("Links", all.filter { $0.kind == .url }.count), ("Images", all.filter { $0.kind == .image }.count), ("Files", all.filter { $0.kind == .files }.count)].filter { $0.1 > 0 }
                Chart("What you copy", values: kinds.map { Double($0.1) }, kind: .donut, role: .success, labels: kinds.map(\.0))
            }
        }
    }

    /// Stackbar's Settings window, so the panel stays about the history.
    var settings: ViewContent {
        Section("Pasting") {
            Toggle("Paste into the app on click", isOn: pasteDirectly) { self.pasteDirectly = $0 }
            Toggle("Always paste as plain text", isOn: plainByDefault) { self.plainByDefault = $0 }
        }
        Section("History") {
            Picker("Order", options: Order.allCases.map(\.rawValue), selection: order.rawValue, style: .segmented) { self.order = Order(rawValue: $0) ?? .recent }
            Slider("Keep \(Int(limit)) items", value: limit, in: 25...1000, step: 25) { value in
                self.limit = value
                self.entries = self.trimmed(self.entries)
            }
            Toggle("Keep images", isOn: keepImages) { self.keepImages = $0 }
            Button("Clear history (keeps pinned)", symbol: "trash", role: .critical) { self.clear() }
        }
        Section("Ignored apps") {
            ignoredAppsContent
        }
        Section("Ignored text") {
            ignoredText
        }
        Section {
            Button("Clear everything, including pinned", symbol: "trash.slash", role: .critical) { self.clear(keepPinned: false) }
        }
    }

    @ViewBuilder var ignoredAppsContent: ViewContent {
        TextField("Ignore an app (bundle id or name)") { app in
            let app = app.trimmingCharacters(in: .whitespaces)
            guard !app.isEmpty, !self.ignoredApps.contains(app) else { return }
            self.ignoredApps.append(app)
        }
        if let recent = entries.first(where: { $0.appID != nil && $0.appID != "io.navbytes.stackbar" }), let app = recent.appID, !isIgnored(app: app, name: recent.appName) {
            Button("Ignore \(recent.appName ?? app)", symbol: "hand.raised", key: "ignore-recent") { self.ignoredApps.append(app) }
        }
        ForEach(ignoredApps) { app in
            Row(app, subtitle: "Ignored", symbol: "hand.raised", key: "ignored-\(app)")
                .action("Stop ignoring") { self.ignoredApps.removeAll { $0 == app } }
        }
    }

    @ViewBuilder var ignoredText: ViewContent {
        TextField("Ignore copies matching a pattern (regex)") { pattern in
            let pattern = pattern.trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty, !self.ignoredPatterns.contains(pattern) else { return }
            guard (try? Regex(pattern)) != nil else {
                self.settingsError = "\"\(pattern)\" isn't a valid regular expression"
                return
            }
            self.settingsError = nil
            self.ignoredPatterns.append(pattern)
            self.entries = self.entries.filter { $0.pinned || !self.matchesIgnoredPattern($0.text ?? "") }
        }
        if let settingsError { Text(settingsError).style(.caption).role(.warning) }
        ForEach(ignoredPatterns) { pattern in
            Row(pattern, subtitle: "Copies matching this aren't recorded", symbol: "line.3.horizontal.decrease", key: "pattern-\(pattern)")
                .action("Remove") { self.ignoredPatterns.removeAll { $0 == pattern } }
        }
    }

    /// `paste` picks the primary action: the panel follows the setting, the
    /// palette always pastes.
    func row(_ entry: Entry) -> Row {
        row(entry, paste: pasteDirectly)
    }

    func row(_ entry: Entry, paste pasteDirectly: Bool) -> Row {
        let source = [entry.appName, Self.relative(entry.lastCopied), entry.count > 1 ? "×\(entry.count)" : nil, entry.kind == .text ? "\(entry.text?.count ?? 0) chars" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        var row = Row(entry.title, subtitle: source, symbol: entry.pinned ? "pin.fill" : entry.symbol, key: entry.id).appIcon(entry.appID)
        if let preview = preview(entry) { row = preview(row) }
        row = row.action(pasteDirectly ? "Paste" : "Copy") { await self.use(entry, paste: self.pasteDirectly) }
        if entry.plainText != nil, entry.contentID != nil || entry.kind == .files {
            row = row.action(pasteDirectly ? "Paste as plain text" : "Copy as plain text", shortcut: "option+return") { await self.use(entry, paste: self.pasteDirectly, plain: true) }
        }
        row = row.action(pasteDirectly ? "Copy" : "Paste") { await self.use(entry, paste: !self.pasteDirectly) }
            .action(entry.pinned ? "Unpin" : "Pin", shortcut: "cmd+p") { self.update(entry.id) { $0.pinned.toggle() } }
        if entry.kind == .url, let url = entry.text {
            row = row.action("Open link") { Stackbar.open(url.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return row.action("Delete", shortcut: "option+delete", role: .critical) { self.delete(entry.id) }
    }

    /// The selected row's preview: the text past its first line, the image,
    /// or the files, with when and how often it was copied.
    func preview(_ entry: Entry) -> ((Row) -> Row)? {
        var caption = ["First copied \(Self.relative(entry.firstCopied))"]
        if entry.count > 1 { caption.append("copied \(entry.count) times") }
        switch entry.kind {
        case .image:
            if let size = entry.imageSize, size.count == 2 { caption.insert("\(size[0]) × \(size[1])", at: 0) }
            return { $0.preview(imageID: entry.imageID, caption: caption.joined(separator: " · ")) }
        case .files:
            return { $0.preview(text: entry.files.joined(separator: "\n"), caption: caption.joined(separator: " · ")) }
        case .text, .url:
            guard let text = entry.text, text.count > 60 || text.contains("\n") else { return nil }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
            caption.insert("\(text.count) characters" + (lines > 1 ? ", \(lines) lines" : ""), at: 0)
            return { $0.preview(text: String(text.prefix(2000)), caption: caption.joined(separator: " · ")) }
        }
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: Commands

    var commands: [Command] {
        Command("search", title: "Search Clipboard History", subtitle: "Paste anything you copied", symbol: "list.clipboard", keywords: ["paste", "copy", "history"])
            .view { _ in
                let all = self.sorted
                if all.isEmpty {
                    ContentUnavailableView("Nothing copied yet", symbol: "list.clipboard", message: self.paused ? "Recording is paused." : "Copy something in any app and it shows up here.")
                } else {
                    List(searchable: true) {
                        let pinned = all.filter(\.pinned)
                        if !pinned.isEmpty {
                            Section("Pinned") {
                                ForEach(pinned) { entry in self.row(entry, paste: true) }
                            }
                        }
                        Section(pinned.isEmpty ? nil : "History") {
                            ForEach(all.filter { !$0.pinned }) { entry in self.row(entry, paste: true) }
                        }
                    }
                }
            }
        Command("paste-plain", title: "Paste Last Copy as Plain Text", symbol: "doc.plaintext", keywords: ["clipboard", "format"]) { _ in
            guard let latest = self.sorted.first(where: { !$0.pinned }) ?? self.sorted.first else { return .message("Nothing copied yet") }
            await self.use(latest, paste: true, plain: true)
            if let error = self.lastError { return .failure(error) }
            return .done
        }
        Command("pause", title: self.paused ? "Resume Clipboard History" : "Pause Clipboard History", symbol: self.paused ? "play.fill" : "pause.fill", keywords: ["clipboard", "record"]) { _ in
            self.paused.toggle()
            return .message(self.paused ? "Clipboard history paused" : "Clipboard history recording")
        }
        Command("ignore-next", title: "Ignore Next Copy", symbol: "eye.slash", keywords: ["clipboard", "password", "secret"]) { _ in
            self.ignoreNext = true
            return .message("The next copy won't be kept")
        }
    }

    // MARK: Agents

    var tools: [AgentTool] {
        AgentTool("recent_clips", description: "The most recent clipboard items, newest first", parameters: [ToolParameter("count", .number, description: "How many (default 10)", required: false)]) { arguments in
            let count = Int(arguments.number("count") ?? 10)
            return self.sorted.prefix(max(1, min(count, 50))).enumerated().map { "\($0.offset + 1). \($0.element.title)" }.joined(separator: "\n")
        }
        AgentTool("search_clips", description: "Clipboard items containing the text, newest first, in full", parameters: [ToolParameter("query", description: "Text to look for")]) { arguments in
            let query = arguments.string("query") ?? ""
            let found = self.sorted.filter { ($0.text ?? "").localizedCaseInsensitiveContains(query) }.prefix(10)
            return found.isEmpty ? "Nothing in the history contains \"\(query)\"." : found.map { $0.text ?? $0.title }.joined(separator: "\n---\n")
        }
        AgentTool("copy_clip", description: "Put a history item back on the clipboard, by its position in recent_clips", parameters: [ToolParameter("position", .number, description: "1 is the newest")]) { arguments in
            let position = Int(arguments.number("position") ?? 0)
            let items = self.sorted
            guard position >= 1, position <= items.count else { return "There is no item \(position)." }
            await self.use(items[position - 1], paste: false)
            return "Copied \(items[position - 1].title)"
        }
    }
}
