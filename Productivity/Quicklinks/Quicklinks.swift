import StackbarKit
import Foundation

/// Quicklinks: links and folders you open by name from the palette,
/// Spotlight, a hotkey or a link, with placeholders filled in as you go.
///
/// A search quicklink can be a fallback: it is offered under the palette's
/// results for whatever you typed. The everyday search engines start as
/// fallbacks; switch it in a quicklink's form.
///
/// Each quicklink becomes a command of its own. Its link is a template in
/// Raycast's syntax: `https://github.com/search?q={argument name="query"}`
/// asks for a query, `{clipboard}` and `{selection}` take what you copied or
/// selected, and `{date format="yyyy-MM-dd"}` today's date. "Search
/// Quicklinks" lists them all; "Create Quicklink" adds one. Raycast's
/// exported quicklinks import as they are, and export the same way.
@main
final class Quicklinks: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.quicklinks",
        name: "Quicklinks",
        version: "1.5.1",
        summary: "Open links and folders by name, with placeholders filled in.",
        surfaces: [.panel, .settings],
        triggers: [.launch],
        // Any link or folder, in the app each quicklink names; the clipboard
        // and selection for {clipboard} and {selection}.
        // Site icons come from DuckDuckGo's icon service, which sees the
        // domain of each web link shown in the launcher (off in Settings).
        capabilities: [.openURLs(schemes: ["*"]), .clipboard, .context, .network("icons.duckduckgo.com")],
        minimumStackbar: "0.20.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/Quicklinks",
        accent: .cyan,
        symbol: "link"
    )

    // MARK: Previews

    static let previews: [PreviewScene<Quicklinks>] = [
        PreviewScene("hero", "Your searches, sites and folders by name") { plugin in
            plugin.links = samples
            plugin.usage = Dictionary(uniqueKeysWithValues: samples.enumerated().map { index, link in
                (link.commandID, Usage(count: 40 - index * 4, last: Date().addingTimeInterval(-Double(index) * 3600)))
            })
        },
    ]

    static let samples: [Link] = {
        func link(_ number: Int, _ name: String, _ template: String, tags: [String], symbol: String? = nil) -> Link {
            Link(id: UUID(uuidString: String(format: "51C00000-0000-4000-8000-%012d", number)) ?? UUID(), name: name, link: template, tags: tags, symbol: symbol)
        }
        return [
            link(1, "Search GitHub", "https://github.com/search?q={Query}", tags: ["Dev"]),
            link(2, "Jira Ticket", "https://acme.atlassian.net/browse/{Key}", tags: ["Work"]),
            link(3, "Google Maps", "https://maps.google.com/?q={Place}", tags: ["Everyday"]),
            link(4, "Translate", "https://translate.google.com/?sl=auto&tl=en&text={Text}", tags: ["Everyday"]),
            link(5, "Stack Overflow", "https://stackoverflow.com/search?q={Query}", tags: ["Dev"]),
            link(6, "Downloads", "~/Downloads", tags: ["Folders"], symbol: "folder.fill"),
            link(7, "Team Calendar", "https://calendar.google.com", tags: ["Work"]),
            link(8, "Swift Docs", "https://developer.apple.com/search/?q={Query}", tags: ["Dev"]),
        ]
    }()

    struct Link: Codable, Equatable, Identifiable {
        var id: UUID
        var name: String
        /// A template: a URL, a path, or text that becomes https://….
        var link: String
        /// A bundle id; the default app when nil.
        var openWith: String?
        var tags: [String] = []
        var symbol: String?
        /// Offered under the palette's results for anything typed, which
        /// fills its first argument ("Use “…” with Google").
        var fallback: Bool?

        var commandID: String { "ql-" + id.uuidString.lowercased() }
        var template: Template? { try? Template(link) }
    }

    @Stored("quicklinks") var links: [Link] = []
    /// The tag the panel filters by; nil shows them all.
    @Stored("panelTag") var panelTag: String? = nil
    @Stored("siteIcons") var siteIcons = true
    /// How often and how lately each quicklink was opened, by id, so the
    /// ones you use come first.
    @Stored("usage") var usage: [String: Usage] = [:]
    /// The search engines saved before fallbacks existed were made fallbacks
    /// once.
    @Stored("fallbacksSeeded") var fallbacksSeeded = false

    struct Usage: Codable, Equatable {
        var count: Int
        var last: Date
    }
    var draft = Draft()
    var notice: String?

    /// The create and edit form's errors, kept between its renders.
    struct Draft {
        var nameError: String?
        var linkError: String?
    }

    // MARK: Library

    /// A ready-made quicklink: what a new user can add in one click.
    struct Starter: Identifiable {
        var name: String
        var link: String
        var tag: String
        var id: String { link }
    }

    static func ask(_ name: String) -> String { #"{argument name=""# + name + #""}"# }

    /// Starters by tag, the everyday ones first.
    static let library: [Starter] = [
        Starter(name: "Google", link: "https://www.google.com/search?q=" + ask("query"), tag: "Search"),
        Starter(name: "DuckDuckGo", link: "https://duckduckgo.com/?q=" + ask("query"), tag: "Search"),
        Starter(name: "Kagi", link: "https://kagi.com/search?q=" + ask("query"), tag: "Search"),
        Starter(name: "Perplexity", link: "https://www.perplexity.ai/search?q=" + ask("query"), tag: "Search"),
        Starter(name: "Ask Claude", link: "https://claude.ai/new?q=" + ask("prompt"), tag: "Search"),
        Starter(name: "Wikipedia", link: "https://en.wikipedia.org/w/index.php?search=" + ask("query"), tag: "Search"),
        Starter(name: "YouTube", link: "https://www.youtube.com/results?search_query=" + ask("query"), tag: "Search"),
        Starter(name: "Google Maps", link: "https://www.google.com/maps/search/" + ask("place"), tag: "Search"),
        Starter(name: "Google Images", link: "https://www.google.com/search?tbm=isch&q=" + ask("query"), tag: "Search"),
        Starter(name: "Reddit", link: "https://www.reddit.com/search/?q=" + ask("query"), tag: "Search"),
        Starter(name: "Amazon", link: "https://www.amazon.com/s?k=" + ask("query"), tag: "Search"),
        Starter(name: "GitHub Repository", link: "https://github.com/" + ask("owner") + "/" + ask("repo"), tag: "Developer"),
        Starter(name: "GitHub Search", link: "https://github.com/search?type=repositories&q=" + ask("query"), tag: "Developer"),
        Starter(name: "GitHub Code Search", link: "https://github.com/search?type=code&q=" + ask("query"), tag: "Developer"),
        Starter(name: "My Pull Requests", link: "https://github.com/pulls", tag: "Developer"),
        Starter(name: "GitHub Notifications", link: "https://github.com/notifications", tag: "Developer"),
        Starter(name: "Stack Overflow", link: "https://stackoverflow.com/search?q=" + ask("query"), tag: "Developer"),
        Starter(name: "MDN", link: "https://developer.mozilla.org/en-US/search?q=" + ask("query"), tag: "Developer"),
        Starter(name: "Apple Developer Docs", link: "https://developer.apple.com/search/?q=" + ask("query"), tag: "Developer"),
        Starter(name: "Swift Package Index", link: "https://swiftpackageindex.com/search?query=" + ask("query"), tag: "Developer"),
        Starter(name: "npm", link: "https://www.npmjs.com/search?q=" + ask("package"), tag: "Developer"),
        Starter(name: "PyPI", link: "https://pypi.org/search/?q=" + ask("package"), tag: "Developer"),
        Starter(name: "crates.io", link: "https://crates.io/search?q=" + ask("crate"), tag: "Developer"),
        Starter(name: "Homebrew Formula", link: "https://formulae.brew.sh/formula/" + ask("formula"), tag: "Developer"),
        Starter(name: "Docker Hub", link: "https://hub.docker.com/search?q=" + ask("image"), tag: "Developer"),
        Starter(name: "Can I Use", link: "https://caniuse.com/?search=" + ask("feature"), tag: "Developer"),
        Starter(name: "regex101", link: "https://regex101.com", tag: "Developer"),
        Starter(name: "crontab guru", link: "https://crontab.guru", tag: "Developer"),
        Starter(name: "JWT Debugger", link: "https://jwt.io", tag: "Developer"),
        Starter(name: "Gmail", link: "https://mail.google.com", tag: "Productivity"),
        Starter(name: "Google Calendar", link: "https://calendar.google.com", tag: "Productivity"),
        Starter(name: "Google Drive Search", link: "https://drive.google.com/drive/search?q=" + ask("query"), tag: "Productivity"),
        Starter(name: "Google Translate", link: "https://translate.google.com/?sl=auto&tl=en&text=" + ask("text"), tag: "Productivity"),
        Starter(name: "Dictionary", link: "https://www.merriam-webster.com/dictionary/" + ask("word"), tag: "Productivity"),
        Starter(name: "Thesaurus", link: "https://www.thesaurus.com/browse/" + ask("word"), tag: "Productivity"),
        Starter(name: "Weather", link: "https://wttr.in/" + ask("city"), tag: "Productivity"),
        Starter(name: "Downloads", link: "~/Downloads", tag: "Mac"),
        Starter(name: "Desktop", link: "~/Desktop", tag: "Mac"),
        Starter(name: "Documents", link: "~/Documents", tag: "Mac"),
        Starter(name: "Applications", link: "/Applications", tag: "Mac"),
    ]

    /// Opening and everyday sites, added by the empty state's one button.
    static let essentials = ["Google", "YouTube", "Wikipedia", "Google Maps", "GitHub Repository", "Gmail", "Google Calendar", "Downloads"]

    static let libraryTags = ["Search", "Developer", "Productivity", "Mac"]

    /// Whether a starter's link is already saved.
    func has(_ starter: Starter) -> Bool { links.contains { $0.link == starter.link } }

    func add(_ starters: [Starter]) -> Int {
        let new = starters.filter { !has($0) }
        links += new.map { Link(id: UUID(), name: $0.name, link: $0.link, tags: [$0.tag], fallback: Self.fallbacks.contains($0.name) ? true : nil) }
        return new.count
    }

    /// Starters that are fallbacks when added: general searches.
    static let fallbacks: Set<String> = ["Google", "DuckDuckGo", "Kagi", "Perplexity", "Ask Claude", "Wikipedia"]

    func refresh() async throws {
        guard !fallbacksSeeded else { return }
        fallbacksSeeded = true
        let engines = Set(Self.library.filter { Self.fallbacks.contains($0.name) }.map(\.link))
        for index in links.indices where links[index].fallback == nil && engines.contains(links[index].link) {
            links[index].fallback = true
        }
    }

    @ViewBuilder func libraryView(tag: String?) -> ViewContent {
        let shown = Self.library.filter { tag == nil || tag == "All" || $0.tag == tag }
        let missing = shown.filter { !has($0) }
        if !missing.isEmpty {
            Button(missing.count == shown.count ? "Add all \(shown.count)" : "Add the \(missing.count) you don't have", symbol: "plus.circle", key: "library-add-all") {
                let added = self.add(missing)
                self.notice = "Added \(added) quicklink\(added == 1 ? "" : "s")"
            }
        }
        List(searchable: true) {
            ForEach(Self.libraryTags.filter { tag == nil || tag == "All" || $0 == tag }) { group in
                Section(group) {
                    ForEach(shown.filter { $0.tag == group }) { starter in
                        let link = Link(id: UUID(), name: starter.name, link: starter.link, tags: [starter.tag], fallback: Self.fallbacks.contains(starter.name) ? true : nil)
                        let row = Row(starter.name, subtitle: Self.readable(link), symbol: Self.symbol(for: link), key: "starter-\(starter.link)")
                        if self.has(starter) {
                            row.badge("Added", role: .secondary)
                        } else {
                            row.action("Add") {
                                _ = self.add([starter])
                                self.notice = "Added \(starter.name)"
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Ranking

    /// Opens, worth less as they age: a link used daily this week beats
    /// one used a lot last year.
    func score(_ link: Link, now: Date = Date()) -> Double {
        guard let use = usage[link.id.uuidString] else { return 0 }
        let days = max(0, now.timeIntervalSince(use.last) / 86400)
        return Double(use.count) * pow(0.5, days / 14)
    }

    func ranked(_ shown: [Link]) -> [Link] {
        let now = Date()
        return shown.sorted {
            let (a, b) = (score($0, now: now), score($1, now: now))
            return a != b ? a > b : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func noteOpened(_ link: Link) {
        var use = usage[link.id.uuidString] ?? Usage(count: 0, last: Date())
        use.count += 1
        use.last = Date()
        var all = usage
        all[link.id.uuidString] = use
        // Forget deleted links.
        let ids = Set(links.map { $0.id.uuidString })
        usage = all.filter { ids.contains($0.key) }
    }

    // MARK: Links and paths

    enum Kind { case web, path, app }

    /// `~/x` and `/x` are paths; `scheme:` is a URL; anything else gets
    /// `https://` in front, so `github.com` works.
    static func kind(of link: String) -> Kind {
        if link.hasPrefix("/") || link.hasPrefix("~") { return .path }
        if let scheme = scheme(of: link) { return ["http", "https"].contains(scheme) ? .web : .app }
        return .web
    }

    static func scheme(of link: String) -> String? {
        guard let colon = link.firstIndex(of: ":") else { return nil }
        let scheme = link[..<colon]
        guard let first = scheme.first, first.isLetter, scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) else { return nil }
        // `localhost:3000` and `example.com:8080/x` are a host and a port, not a scheme.
        if isHostAndPort(link, colon: colon) { return nil }
        return scheme.lowercased()
    }

    /// Schemes that are followed by digits: a number to call, not a port.
    private static let numberSchemes: Set<String> = ["tel", "sms", "facetime", "facetime-audio", "callto", "fax", "imessage"]

    /// A port (1 to 65535) straight after the colon, then the end or a path.
    private static func isHostAndPort(_ link: String, colon: String.Index) -> Bool {
        guard !numberSchemes.contains(link[..<colon].lowercased()) else { return false }
        let rest = link[link.index(after: colon)...]
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard (1...5).contains(digits.count), let port = Int(digits), (1...65535).contains(port) else { return false }
        let after = rest.dropFirst(digits.count)
        return after.isEmpty || "/?#".contains(after.first!)
    }

    /// A dev server or a box on the home network answers plain http:
    /// `localhost`, loopback, `.local`, private (10/8, 172.16/12, 192.168/16)
    /// and link-local (169.254/16) addresses, `::1`, and dotless names (`nas:5000`).
    static func isLocal(host: String) -> Bool {
        var name = host.lowercased()
        if let at = name.lastIndex(of: "@") { name = String(name[name.index(after: at)...]) }
        if name.hasPrefix("[") {
            let inside = name.dropFirst().prefix { $0 != "]" }
            return inside == "::1"
        }
        if name == "::1" { return true }
        name = name.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard !name.isEmpty else { return false }
        if name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local") || name.hasPrefix("127.") || name == "0.0.0.0" { return true }
        let octets = name.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        if octets.count == 4, octets.allSatisfy({ $0 != nil && (0...255).contains($0!) }) {
            let o = octets.map { $0! }
            return o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168) || (o[0] == 169 && o[1] == 254)
        }
        // A name with no dot can't be on the public internet.
        return !name.contains(".")
    }

    static func target(_ rendered: String) -> String {
        let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind(of: trimmed) {
        case .path, .app: return trimmed
        case .web:
            guard scheme(of: trimmed) == nil else { return trimmed }
            let host = trimmed.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            return (isLocal(host: String(host)) ? "http://" : "https://") + trimmed
        }
    }

    static func symbol(for link: Link) -> String {
        if let symbol = link.symbol, !symbol.isEmpty { return symbol }
        switch kind(of: link.link) {
        case .web: return "globe"
        case .path: return "folder"
        case .app: return "app.badge"
        }
    }

    static func host(of link: String) -> String? {
        guard kind(of: link) == .web else { return nil }
        let full = target(link)
        guard let start = full.range(of: "://")?.upperBound else { return nil }
        let rest = full[start...]
        let host = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" && $0 != "{" }
        return host.isEmpty ? nil : String(host)
    }

    /// The site's icon for a web link, when site icons are on.
    func favicon(_ link: Link) -> String? {
        guard siteIcons, let host = Self.host(of: link.link), !host.contains("{"), host.contains(".") else { return nil }
        return "https://icons.duckduckgo.com/ip3/\(host).ico"
    }

    /// A host without "www." and its registry suffix: "calendar.google".
    static func shortHost(_ host: String) -> String {
        var parts = host.replacingOccurrences(of: "www.", with: "").split(separator: ".").map(String.init)
        if parts.count > 1 { parts.removeLast() }
        // Still too long for a tile: drop the subdomain ("news.ycombinator").
        if parts.count > 1, parts.joined(separator: ".").count > 15 { parts.removeFirst() }
        return parts.joined(separator: ".")
    }

    /// One line short enough for a tile, so tiles in a row match.
    static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    /// The launcher: up to six links that open without asking anything, as
    /// tiles with their site's icon.
    @ViewBuilder func launcher(_ shown: [Link]) -> ViewContent {
        let ready = ranked(shown).filter { !($0.template?.arguments.contains(where: \.required) ?? false) }.prefix(6)
        if ready.count >= 3 {
            Grid(columns: 3, spacing: Space.s) {
                ForEach(Array(ready)) { link in
                    Tile(Self.clip(link.name, 14), subtitle: Self.host(of: link.link).map { Self.clip(Self.shortHost($0), 17) } ?? (link.link.hasPrefix("/") || link.link.hasPrefix("~") ? "Folder" : "Link"), symbol: Self.symbol(for: link), imageURL: favicon(link), theme: theme, key: "tile-\(link.id.uuidString)") {
                        try await self.open(link)
                    }
                }
            }
        }
    }

    /// Renders a link's template with what the user typed, copied and
    /// selected. Values are URL-encoded for web and app links, not paths.
    func resolve(_ link: Link, arguments: [String: String], context: InvocationContext?) async throws -> String {
        let template = try Template(link.link)
        var environment = Template.Environment(selection: context?.selectedText)
        if template.uses("clipboard") { environment.clipboard = try await Stackbar.clipboard()?.text }
        let encoding: Template.Encoding = Self.kind(of: link.link) == .path ? .none : .url
        return Self.target(try template.render(arguments, in: environment, encoding: encoding).text)
    }

    func open(_ link: Link, arguments: [String: String] = [:], context: InvocationContext? = nil) async throws {
        try await Stackbar.open(try await resolve(link, arguments: arguments, context: context), with: link.openWith)
        noteOpened(link)
    }

    // MARK: Commands

    var allTags: [String] {
        Array(Set(links.flatMap(\.tags))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Tags, the most used first, for the panel's chips.
    var tagsByUse: [String] {
        let counts = Dictionary(links.flatMap(\.tags).map { ($0, 1) }, uniquingKeysWith: +)
        return allTags.sorted { (counts[$0] ?? 0, $1) > (counts[$1] ?? 0, $0) }
    }

    /// The host and path, without the template's placeholders.
    static func readable(_ link: Link) -> String {
        let arguments = link.template?.arguments.map(\.name) ?? []
        guard kind(of: link.link) == .web else { return link.link }
        let shown = host(of: link.link) ?? link.link
        return arguments.isEmpty ? shown + pathHint(link.link) : "\(shown) · asks for \(arguments.joined(separator: ", "))"
    }

    static func pathHint(_ link: String) -> String {
        let full = target(link)
        guard let start = full.range(of: "://")?.upperBound, let slash = full[start...].firstIndex(of: "/") else { return "" }
        let path = full[slash...]
        return path.count <= 1 ? "" : path.count > 24 ? String(path.prefix(23)) + "…" : String(path)
    }

    var commands: [Command] {
        for link in links { command(for: link) }
        Command("search", title: "Search Quicklinks", subtitle: "Open, edit or copy a quicklink", symbol: "link", keywords: ["quicklink", "bookmark", "url"])
            .argument("tag", placeholder: "Tag", required: false, default: "All", options: ["All"] + allTags)
            .view { invocation in self.searchView(tag: invocation["tag"]) }
        Command("create", title: "Create Quicklink", symbol: "link.badge.plus", keywords: ["quicklink", "new", "add"])
            .argument("id", placeholder: "Quicklink", required: false)
            .stackbarOnly()
            .view { invocation in self.form(editing: invocation["id"].flatMap(UUID.init(uuidString:))) }
        Command("library", title: "Browse Quicklink Library", subtitle: "\(Self.library.count) ready-made searches, sites and folders", symbol: "books.vertical", keywords: ["quicklink", "starter", "add", "template"])
            .argument("tag", placeholder: "Tag", required: false, default: "All", options: ["All"] + Self.libraryTags)
            .stackbarOnly()
            .view { invocation in self.libraryView(tag: invocation["tag"]) }
        Command("import", title: "Import Quicklinks", subtitle: "From a Raycast export", symbol: "square.and.arrow.down", keywords: ["quicklink", "raycast"]) { _ in
            .message(try await self.importLinks())
        }
        .stackbarOnly()
        Command("export", title: "Export Quicklinks", subtitle: "To a file Raycast reads too", symbol: "square.and.arrow.up", keywords: ["quicklink", "raycast", "backup"]) { _ in
            .message(try await self.exportLinks())
        }
        .stackbarOnly()
    }

    /// A quicklink's own command: its arguments come from its template.
    func command(for link: Link) -> Command {
        var command = Command(link.commandID, title: link.name, subtitle: link.link, symbol: Self.symbol(for: link), keywords: link.tags + [Self.host(of: link.link)].compactMap { $0 } + ["quicklink"]) { invocation in
            do {
                let url = try await self.resolve(link, arguments: invocation.arguments, context: invocation.context)
                self.noteOpened(link)
                return .open(url: url, app: link.openWith)
            } catch {
                return .failure("\(link.name): \(error)")
            }
        }
        let arguments = link.template?.arguments ?? []
        for argument in arguments {
            command = command.argument(argument.name, placeholder: argument.placeholder, required: argument.required, default: argument.defaultValue, options: argument.options)
        }
        // The typed text fills the first argument, so a fallback needs one.
        if link.fallback == true, !arguments.isEmpty { command = command.fallback() }
        return command
    }

    @ViewBuilder func searchView(tag: String?) -> ViewContent {
        let shown = ranked(links.filter { tag == nil || tag == "All" || $0.tags.contains(tag!) })
        if links.isEmpty {
            EmptyState("No quicklinks yet", symbol: "link", message: "Open searches, sites and folders by name. Start with a few everyday ones, browse \(Self.library.count) ready-made ones, or bring in a Raycast export.", theme: theme) {
                ActionButton("Add \(Self.essentials.count) Everyday Links", symbol: "sparkles", theme: theme, prominent: true) {
                    let added = self.add(Self.library.filter { Self.essentials.contains($0.name) })
                    self.notice = "Added \(added) quicklinks. Type a name in the palette to open one."
                }
                ActionButton("Browse Library", symbol: "books.vertical", theme: theme) { self.openCommand("library") }
                ActionButton("Create", symbol: "plus", theme: theme) { self.openCommand("create") }
                ActionButton("Import", symbol: "square.and.arrow.down", theme: theme) { self.notice = try await self.importLinks() }
            }
        } else {
            List(searchable: true) {
                ForEach(shown) { link in self.row(link) }
            }
        }
    }

    func row(_ link: Link) -> Row {
        var row = Row(link.name, subtitle: Self.readable(link), symbol: Self.symbol(for: link), key: link.id.uuidString).appIcon(link.openWith)
        if let tag = link.tags.first { row = row.badge(tag) }
        let needsInput = link.template?.arguments.contains(where: \.required) ?? false
        // With arguments to fill in, Return opens the quicklink's own
        // command, which asks for them.
        row = needsInput
            ? row.navigate("Open", to: link.commandID)
            : row.action("Open") { try await self.open(link) }
        return row
            .action("Copy Link", shortcut: "cmd+shift+c") {
                Stackbar.copy(needsInput ? link.link : ((try? await self.resolve(link, arguments: [:], context: nil)) ?? link.link))
            }
            .navigate("Edit", to: "create", arguments: ["id": link.id.uuidString], shortcut: "cmd+e")
            .action("Duplicate", shortcut: "cmd+d") {
                var copy = link
                copy.id = UUID()
                // "Name 2" sorts next to the original.
                copy.name = link.name + " 2"
                self.links.append(copy)
            }
            .action("Delete", shortcut: "ctrl+x", role: .critical) {
                self.links.removeAll { $0.id == link.id }
            }
    }

    // MARK: Creating and editing

    @ViewBuilder func form(editing id: UUID?) -> ViewContent {
        let existing = id.flatMap { id in links.first { $0.id == id } }
        Form(submit: existing == nil ? "Create Quicklink" : "Save", key: id?.uuidString ?? "new") {
            FormField.text("Name", name: "name", value: existing?.name ?? "", placeholder: "GitHub search", error: draft.nameError)
            FormField.text("Link", name: "link", value: existing?.link ?? "", placeholder: #"https://github.com/search?q={argument name="query"}"#, error: draft.linkError)
            FormField.application("Open with", name: "app", bundleID: existing?.openWith)
            FormField.text("Tags", name: "tags", value: existing?.tags.joined(separator: ", ") ?? "", placeholder: "work, docs")
            FormField.picker("Symbol", name: "symbol", options: Self.symbols, selection: existing?.symbol.flatMap { Self.symbols.contains($0) ? $0 : nil } ?? "Automatic")
            FormField.toggle("Offer for anything typed in the palette", name: "fallback", isOn: existing?.fallback ?? false)
        } onSubmit: { values in
            self.save(values, editing: id)
        }
        Text(#"Placeholders: {argument name="x"}, {clipboard}, {selection}, {date format="yyyy-MM-dd"}, {uuid}. Paths start with / or ~/."#).style(.caption)
    }

    /// Checks the fields; on success saves and clears the errors, which
    /// lets the palette close the form.
    func save(_ values: [String: EventValue], editing id: UUID?) {
        let name = (values.string("name") ?? "").trimmingCharacters(in: .whitespaces)
        let text = (values.string("link") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        draft = Draft()
        if name.isEmpty { draft.nameError = "Give it a name" }
        draft.linkError = Self.problem(with: text)
        guard draft.nameError == nil, draft.linkError == nil else { return }
        let tags = (values.string("tags") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let app = values.string("app").flatMap { $0.isEmpty ? nil : $0 }
        let symbol = values.string("symbol").flatMap { $0.isEmpty || $0 == "Automatic" ? nil : $0 }
        let fallback = values.bool("fallback") ?? false
        if let id, let index = links.firstIndex(where: { $0.id == id }) {
            links[index].name = name
            links[index].link = text
            links[index].openWith = app
            links[index].tags = tags
            links[index].symbol = symbol
            links[index].fallback = fallback
        } else {
            links.append(Link(id: UUID(), name: name, link: text, openWith: app, tags: tags, symbol: symbol, fallback: fallback))
        }
    }

    /// Why a link can't be saved, or nil.
    static func problem(with link: String) -> String? {
        if link.isEmpty { return "Give it a link" }
        let template: Template
        do { template = try Template(link) } catch { return "\(error)" }
        if let typo = template.unrecognized.first { return "\(typo) is not a placeholder; see the list below" }
        if link.contains(where: \.isNewline) { return "A link is one line" }
        if kind(of: link) == .web, scheme(of: link) == nil, link.contains(" "), !link.contains("{") { return "Spaces need a scheme in front, like https://" }
        return nil
    }

    // MARK: Import and export

    /// Raycast's export: `[{name, link, openWith?, iconName?}]`.
    struct Exported: Codable {
        var name: String
        var link: String
        var openWith: String?
        var iconName: String?
        var tags: [String]?
    }

    func importLinks() async throws -> String {
        guard let file = try await Stackbar.chooseFile(types: ["json"]) else { return "Import cancelled" }
        let items: [Exported]
        do {
            items = try JSONDecoder().decode([Exported].self, from: file.data)
        } catch {
            throw HostError("\(file.name) is not a quicklinks export: \(error.localizedDescription)")
        }
        var imported = 0
        var duplicates = 0
        var unknownApps: [String] = []
        var problems: [String] = []
        // Collected here and saved once, not once per link.
        var all = links
        for item in items {
            if all.contains(where: { $0.name == item.name && $0.link == item.link }) {
                duplicates += 1
                continue
            }
            if let problem = Self.problem(with: item.link) {
                problems.append("\(item.name): \(problem)")
                continue
            }
            var app: String?
            if let openWith = item.openWith, !openWith.isEmpty {
                app = try await Stackbar.resolveApplication(openWith)
                if app == nil { unknownApps.append(openWith) }
            }
            all.append(Link(id: UUID(), name: item.name, link: item.link, openWith: app, tags: item.tags ?? []))
            imported += 1
        }
        if imported > 0 { links = all }
        var summary = "Imported \(imported)"
        if duplicates > 0 { summary += ", skipped \(duplicates) duplicate\(duplicates == 1 ? "" : "s")" }
        if !problems.isEmpty { summary += ", skipped \(problems.count) that didn't parse (\(problems.prefix(3).joined(separator: "; ")))" }
        if !unknownApps.isEmpty { summary += "; opening with the default app instead of " + Set(unknownApps).sorted().joined(separator: ", ") + ", which isn't installed" }
        notice = summary
        return summary
    }

    func exportLinks() async throws -> String {
        guard !links.isEmpty else { return "No quicklinks to export" }
        let items = links.map { Exported(name: $0.name, link: $0.link, openWith: $0.openWith, iconName: nil, tags: $0.tags.isEmpty ? nil : $0.tags) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let path = try await Stackbar.saveFile("Quicklinks.json", data: try encoder.encode(items)) else { return "Export cancelled" }
        return "Exported \(links.count) to \(path)"
    }

    // MARK: Panel and settings

    let theme = Theme.cyan

    /// "Automatic" is the link kind's own symbol.
    static let symbols = ["Automatic", "star", "globe", "folder", "doc.text", "book", "magnifyingglass", "chevron.left.forwardslash.chevron.right",
                          "terminal", "server.rack", "cloud", "envelope", "calendar", "person.2", "cart", "music.note", "map"]

    func openCommand(_ command: String) {
        Stackbar.open("stackbar://commands/\(Self.manifest.id)/\(command)")
    }

    var panel: ViewContent {
        if !links.isEmpty {
            PanelHeader(links.count == 1 ? "1 quicklink" : "\(links.count) quicklinks", subtitle: "Type a name in the palette to open one", symbol: "link", theme: theme) {
                HStack(spacing: Space.xs) {
                    IconButton("books.vertical", label: "Browse Library", theme: theme) { self.openCommand("library") }
                    IconButton("plus", label: "New Quicklink", theme: theme, prominence: .tinted) { self.openCommand("create") }
                }
            }
            if let notice { Banner(notice, symbol: "checkmark.circle.fill", theme: .success) }
            if !allTags.isEmpty {
                TagChips(tagsByUse, selection: panelTag.flatMap { allTags.contains($0) ? $0 : nil }, theme: theme) { self.panelTag = $0 }
            }
        }
        let tag = panelTag.flatMap { allTags.contains($0) ? $0 : nil }
        launcher(links.filter { tag == nil || tag == "All" || $0.tags.contains(tag!) })
        searchView(tag: tag)
    }

    var settings: ViewContent {
        Section("Quicklinks") {
            LabeledContent("Saved", value: "\(links.count)")
            Toggle("Show site icons", isOn: siteIcons) { self.siteIcons = $0 }
            Text("Icons come from DuckDuckGo, which sees the domains of the links in the launcher.").style(.caption).role(.secondary)
            if let notice { Text(notice).style(.caption) }
            Button("Browse the library…", symbol: "books.vertical") { self.openCommand("library") }
            Button("Import from Raycast…", symbol: "square.and.arrow.down") { _ = try await self.importLinks() }
            Button("Export…", symbol: "square.and.arrow.up") { self.notice = try await self.exportLinks() }
        }
        Section("Opening") {
            Text("Links without an app open in your default browser, which you choose in System Settings > Desktop & Dock. Give each quicklink a name you'll type, and an alias or hotkey in Settings > Commands.").style(.caption)
        }
    }
}
