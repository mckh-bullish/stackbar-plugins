import StackbarKit
import Foundation

/// Quicklinks: links and folders you open by name from the palette,
/// Spotlight, a hotkey or a link, with placeholders filled in as you go.
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
        version: "1.0.1",
        summary: "Open links and folders by name, with placeholders filled in.",
        surfaces: [.panel, .settings],
        triggers: [.launch],
        // Any link or folder, in the app each quicklink names; the clipboard
        // and selection for {clipboard} and {selection}.
        capabilities: [.openURLs(schemes: ["*"]), .clipboard, .context],
        minimumStackbar: "0.11.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/Quicklinks"
    )

    struct Link: Codable, Equatable, Identifiable {
        var id: UUID
        var name: String
        /// A template: a URL, a path, or text that becomes https://….
        var link: String
        /// A bundle id; the default app when nil.
        var openWith: String?
        var tags: [String] = []
        var symbol: String?

        var commandID: String { "ql-" + id.uuidString.lowercased() }
        var template: Template? { try? Template(link) }
    }

    @Stored("quicklinks") var links: [Link] = []
    var draft = Draft()
    var notice: String?

    /// The create and edit form's errors, kept between its renders.
    struct Draft {
        var nameError: String?
        var linkError: String?
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
        return scheme.lowercased()
    }

    static func target(_ rendered: String) -> String {
        let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind(of: trimmed) {
        case .path, .app: return trimmed
        case .web: return scheme(of: trimmed) == nil ? "https://" + trimmed : trimmed
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
    }

    // MARK: Commands

    var allTags: [String] {
        Array(Set(links.flatMap(\.tags))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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
                return .open(url: try await self.resolve(link, arguments: invocation.arguments, context: invocation.context), app: link.openWith)
            } catch {
                return .failure("\(link.name): \(error)")
            }
        }
        for argument in link.template?.arguments ?? [] {
            command = command.argument(argument.name, placeholder: argument.placeholder, required: argument.required, default: argument.defaultValue, options: argument.options)
        }
        return command
    }

    @ViewBuilder func searchView(tag: String?) -> ViewContent {
        let shown = links.filter { tag == nil || tag == "All" || $0.tags.contains(tag!) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if links.isEmpty {
            ContentUnavailableView("No quicklinks yet", symbol: "link", message: "Create one, or import a Raycast export from Settings.")
        } else {
            List(searchable: true) {
                ForEach(shown) { link in self.row(link) }
            }
        }
    }

    func row(_ link: Link) -> Row {
        var row = Row(link.name, subtitle: link.link, symbol: Self.symbol(for: link), key: link.id.uuidString).appIcon(link.openWith)
        for tag in link.tags { row = row.badge(tag) }
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
                copy.name = link.name + " copy"
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
            FormField.text("Symbol", name: "symbol", value: existing?.symbol ?? "", placeholder: "An SF Symbol, like star")
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
        let symbol = values.string("symbol").flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
        if let id, let index = links.firstIndex(where: { $0.id == id }) {
            links[index].name = name
            links[index].link = text
            links[index].openWith = app
            links[index].tags = tags
            links[index].symbol = symbol
        } else {
            links.append(Link(id: UUID(), name: name, link: text, openWith: app, tags: tags, symbol: symbol))
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
        for item in items {
            if links.contains(where: { $0.name == item.name && $0.link == item.link }) {
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
            links.append(Link(id: UUID(), name: item.name, link: item.link, openWith: app, tags: item.tags ?? []))
            imported += 1
        }
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

    var panel: ViewContent {
        searchView(tag: nil)
    }

    var settings: ViewContent {
        Section("Quicklinks") {
            LabeledContent("Saved", value: "\(links.count)")
            if let notice { Text(notice).style(.caption) }
            Button("Import from Raycast…", symbol: "square.and.arrow.down") { _ = try await self.importLinks() }
            Button("Export…", symbol: "square.and.arrow.up") { self.notice = try await self.exportLinks() }
        }
        Section("Opening") {
            Text("Links without an app open in your default browser, which you choose in System Settings > Desktop & Dock. Give each quicklink a name you'll type, and an alias or hotkey in Settings > Commands.").style(.caption)
        }
    }
}
