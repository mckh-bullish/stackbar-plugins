import StackbarKit
import Foundation

/// Snippets: text you paste by name, with placeholders filled in.
///
/// Each snippet becomes a command of its own that pastes into the app you
/// were in, then puts your clipboard back. Its text is a template in
/// Raycast's syntax: `{clipboard}`, `{selection}`, `{date format="d MMM"}`,
/// `{argument name="who"}` asks first, `{cursor}` leaves the caret there, and
/// `{snippet name="Signature"}` pulls in another snippet. "Search Snippets"
/// (⌃⌥S) lists them with a preview. Raycast exports import as they are.
///
/// Keywords are kept but not expanded as you type: that needs a system-wide
/// keyboard monitor, which Stackbar doesn't have.
@main
final class Snippets: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.snippets",
        name: "Snippets",
        version: "1.2.0",
        summary: "Paste text by name, with placeholders filled in.",
        surfaces: [.panel, .settings],
        triggers: [.launch],
        // Pasting; the selection for {selection}; room for thousands of
        // snippets at Raycast's 65,536-character limit.
        capabilities: [.clipboard, .context, .storage(megabytes: 16)],
        hotkey: "ctrl+option+s",
        minimumStackbar: "0.14.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/Snippets"
    )

    static let maxLength = 65_536

    struct Snippet: Codable, Equatable, Identifiable {
        var id: UUID
        var name: String
        /// A template, at most 65,536 characters.
        var text: String
        /// Kept for expansion later, and matched by search.
        var keyword: String?
        var tags: [String] = []

        var commandID: String { "sn-" + id.uuidString.lowercased() }
        var template: Template? { try? Template(text) }
    }

    @Stored("snippets") var snippets: [Snippet] = []
    /// The tag the panel filters by; nil shows them all.
    @Stored("panelTag") var panelTag: String? = nil
    var draft = Draft()
    var notice: String?

    /// The create and edit form's errors, kept between its renders.
    struct Draft {
        var nameError: String?
        var textError: String?
        var keywordError: String?
    }

    // MARK: Rendering

    /// What `{snippet name="…"}` can name: every snippet by name, and by
    /// keyword too.
    func library(excluding id: UUID? = nil) -> [String: String] {
        var library: [String: String] = [:]
        for snippet in snippets where snippet.id != id {
            if let keyword = snippet.keyword, !keyword.isEmpty { library[keyword] = snippet.text }
            library[snippet.name] = snippet.text
        }
        return library
    }

    /// The names a template pulls in with `{snippet name="…"}`.
    static func included(by template: Template) -> [String] {
        template.placeholders.filter { $0.name == "snippet" }.compactMap { $0.options["name"] }
    }

    /// Whether the snippet, or one it includes, uses a placeholder.
    func uses(_ name: String, in snippet: Snippet) -> Bool {
        guard let template = snippet.template else { return false }
        if template.uses(name) { return true }
        let library = library(excluding: snippet.id)
        return Self.included(by: template).contains { (library[$0].flatMap { try? Template($0) })?.uses(name) ?? false }
    }

    /// Renders a snippet with what the user typed, copied and selected.
    func render(_ snippet: Snippet, arguments: [String: String], context: InvocationContext?) async throws -> Template.Rendered {
        let template = try Template(snippet.text)
        var environment = Template.Environment(selection: context?.selectedText, snippets: library(excluding: snippet.id))
        if uses("clipboard", in: snippet) { environment.clipboard = try await Stackbar.clipboard()?.text }
        if environment.selection == nil, context == nil, uses("selection", in: snippet) { environment.selection = try await Stackbar.context().selectedText }
        return try template.render(arguments, in: environment)
    }

    /// The text with today's values, and markers for what is only known
    /// when it is pasted.
    func preview(_ snippet: Snippet) -> String {
        guard let template = snippet.template else { return snippet.text }
        let values = Dictionary(arguments(of: snippet).map { ($0.name, $0.defaultValue ?? $0.options?.first ?? "‹\($0.name)›") }, uniquingKeysWith: { first, _ in first })
        let environment = Template.Environment(clipboard: "‹clipboard›", selection: "‹selection›", snippets: library(excluding: snippet.id))
        return (try? template.render(values, in: environment).text) ?? snippet.text
    }

    /// What the snippet asks for: its own arguments, then those of the
    /// snippets it includes, which get the same values.
    func arguments(of snippet: Snippet) -> [ArgumentSpec] {
        guard let template = snippet.template else { return [] }
        var arguments = template.arguments
        let library = library(excluding: snippet.id)
        for name in Self.included(by: template) {
            for argument in (library[name].flatMap { try? Template($0) })?.arguments ?? [] where !arguments.contains(where: { $0.name == argument.name }) {
                arguments.append(argument)
            }
        }
        return Array(arguments.prefix(Template.maxArguments))
    }

    func paste(_ snippet: Snippet) async throws {
        let rendered = try await render(snippet, arguments: [:], context: nil)
        try await Stackbar.paste(.text(rendered.text), restoringClipboard: true, cursorFromEnd: rendered.cursorFromEnd ?? 0)
    }

    // MARK: Commands

    var allTags: [String] {
        Array(Set(snippets.flatMap(\.tags))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Tags, the most used first, for the panel's chips.
    var tagsByUse: [String] {
        let counts = Dictionary(snippets.flatMap(\.tags).map { ($0, 1) }, uniquingKeysWith: +)
        return allTags.sorted { (counts[$0] ?? 0, $1) > (counts[$1] ?? 0, $0) }
    }

    var commands: [Command] {
        for snippet in snippets { command(for: snippet) }
        Command("search", title: "Search Snippets", subtitle: "Paste, copy or edit a snippet", symbol: "text.quote", keywords: ["snippet", "text", "paste"])
            .argument("tag", placeholder: "Tag", required: false, default: "All", options: ["All"] + allTags)
            .view { invocation in self.searchView(tag: invocation["tag"]) }
        Command("create", title: "Create Snippet", symbol: "text.badge.plus", keywords: ["snippet", "new", "add"])
            .argument("id", placeholder: "Snippet", required: false)
            .stackbarOnly()
            .view { invocation in self.form(editing: invocation["id"].flatMap(UUID.init(uuidString:))) }
        Command("import", title: "Import Snippets", subtitle: "From a Raycast export", symbol: "square.and.arrow.down", keywords: ["snippet", "raycast"]) { _ in
            .message(try await self.importSnippets())
        }
        .stackbarOnly()
        Command("export", title: "Export Snippets", subtitle: "To a file Raycast reads too", symbol: "square.and.arrow.up", keywords: ["snippet", "raycast", "backup"]) { _ in
            .message(try await self.exportSnippets())
        }
        .stackbarOnly()
    }

    /// A snippet's own command: its arguments come from its template, and
    /// running it pastes.
    func command(for snippet: Snippet) -> Command {
        let keywords = snippet.tags + [snippet.keyword].compactMap { $0 } + ["snippet"]
        var command = Command(snippet.commandID, title: snippet.name, subtitle: Self.firstLine(of: snippet.text), symbol: "text.quote", keywords: keywords) { invocation in
            do {
                let rendered = try await self.render(snippet, arguments: invocation.arguments, context: invocation.context)
                return .paste(rendered.text, cursorFromEnd: rendered.cursorFromEnd ?? 0)
            } catch {
                return .failure("\(snippet.name): \(error)")
            }
        }
        for argument in arguments(of: snippet) {
            command = command.argument(argument.name, placeholder: argument.placeholder, required: argument.required, default: argument.defaultValue, options: argument.options)
        }
        return command
    }

    static func firstLine(of text: String) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    @ViewBuilder func searchView(tag: String?) -> ViewContent {
        let shown = snippets.filter { tag == nil || tag == "All" || $0.tags.contains(tag!) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if snippets.isEmpty {
            EmptyState("No snippets yet", symbol: "text.quote", message: "Save text you type often, with placeholders for what changes.", theme: theme) {
                ActionButton("Create Snippet", symbol: "plus", theme: theme, prominent: true) { self.openCommand("create") }
                ActionButton("Import from Raycast", symbol: "square.and.arrow.down", theme: theme) { self.notice = try await self.importSnippets() }
            }
        } else {
            List(searchable: true) {
                ForEach(shown) { snippet in self.row(snippet) }
            }
        }
    }

    func row(_ snippet: Snippet) -> Row {
        let preview = preview(snippet)
        var row = Row(snippet.name, subtitle: Self.firstLine(of: preview), symbol: Self.symbol(for: snippet), key: snippet.id.uuidString)
        if let keyword = snippet.keyword { row = row.badge(keyword, role: .secondary) }
        if let tag = snippet.tags.first { row = row.badge(tag) }
        row = row.preview(text: preview, caption: "\(snippet.text.count) characters" + (snippet.keyword.map { " · keyword \($0)" } ?? ""))
        let needsInput = arguments(of: snippet).contains(where: \.required)
        // With arguments to fill in, Return opens the snippet's own command,
        // which asks for them and then pastes.
        row = needsInput
            ? row.navigate("Paste", to: snippet.commandID)
            : row.action("Paste") { try await self.paste(snippet) }
        return row
            .action("Copy", shortcut: "cmd+c") {
                let text = needsInput ? snippet.text : ((try? await self.render(snippet, arguments: [:], context: nil).text) ?? snippet.text)
                Stackbar.copy(text)
            }
            .navigate("Edit", to: "create", arguments: ["id": snippet.id.uuidString], shortcut: "cmd+e")
            .action("Duplicate", shortcut: "cmd+d") {
                var copy = snippet
                copy.id = UUID()
                // "Name 2" sorts next to the original.
                copy.name = snippet.name + " 2"
                copy.keyword = nil
                self.snippets.append(copy)
            }
            .action("Delete", shortcut: "ctrl+x", role: .critical) {
                self.snippets.removeAll { $0.id == snippet.id }
            }
    }

    // MARK: Creating and editing

    @ViewBuilder func form(editing id: UUID?) -> ViewContent {
        let existing = id.flatMap { id in snippets.first { $0.id == id } }
        Form(submit: existing == nil ? "Create Snippet" : "Save", key: id?.uuidString ?? "new") {
            FormField.text("Name", name: "name", value: existing?.name ?? "", placeholder: "Signature", error: draft.nameError)
            FormField.multiline("Snippet", name: "text", value: existing?.text ?? "", placeholder: "Thanks,\n{argument name=\"name\" default=\"Nav\"}", error: draft.textError)
            FormField.text("Keyword", name: "keyword", value: existing?.keyword ?? "", placeholder: ";sig (kept for later; not expanded as you type)", error: draft.keywordError)
            FormField.text("Tags", name: "tags", value: existing?.tags.joined(separator: ", ") ?? "", placeholder: "work, email")
        } onSubmit: { values in
            self.save(values, editing: id)
        }
        Text(#"Placeholders: {clipboard}, {selection}, {cursor}, {date format="yyyy-MM-dd" offset="+1d"}, {time}, {day}, {uuid}, {argument name="x" default="y"}, {snippet name="Other"}. Modifiers: {clipboard | trim | uppercase}."#).style(.caption)
    }

    /// Checks the fields; on success saves and clears the errors, which
    /// lets the palette close the form.
    func save(_ values: [String: EventValue], editing id: UUID?) {
        let name = (values.string("name") ?? "").trimmingCharacters(in: .whitespaces)
        let text = values.string("text") ?? ""
        let keyword = (values.string("keyword") ?? "").trimmingCharacters(in: .whitespaces)
        draft = Draft()
        if name.isEmpty { draft.nameError = "Give it a name" }
        draft.textError = problem(with: text, name: name, editing: id)
        draft.keywordError = Self.problem(withKeyword: keyword)
        if draft.keywordError == nil, !keyword.isEmpty, snippets.contains(where: { $0.keyword == keyword && $0.id != id }) {
            draft.keywordError = "Another snippet has the keyword \(keyword)"
        }
        guard draft.nameError == nil, draft.textError == nil, draft.keywordError == nil else { return }
        let tags = (values.string("tags") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let id, let index = snippets.firstIndex(where: { $0.id == id }) {
            snippets[index].name = name
            snippets[index].text = text
            snippets[index].keyword = keyword.isEmpty ? nil : keyword
            snippets[index].tags = tags
        } else {
            snippets.append(Snippet(id: UUID(), name: name, text: text, keyword: keyword.isEmpty ? nil : keyword, tags: tags))
        }
    }

    /// Why a snippet's text can't be saved, or nil.
    func problem(with text: String, name: String, editing id: UUID?) -> String? {
        if text.isEmpty { return "Write the snippet" }
        if text.count > Self.maxLength { return "A snippet is at most 65,536 characters" }
        let template: Template
        do { template = try Template(text) } catch { return "\(error)" }
        if let typo = template.unrecognized.first { return "\(typo) is not a placeholder; see the list below" }
        if template.placeholders.filter({ $0.name == "cursor" }).count > 1 { return "Use {cursor} once" }
        let library = library(excluding: id)
        for included in Self.included(by: template) {
            if included == name { return "A snippet can't include itself" }
            guard let other = library[included] else { return "There's no snippet named \(included)" }
            if let inner = try? Template(other), !Self.included(by: inner).isEmpty {
                return "\(included) includes another snippet itself; snippets nest one level deep"
            }
        }
        return nil
    }

    /// Raycast's rule: no whitespace, quotes or backticks.
    static func problem(withKeyword keyword: String) -> String? {
        if keyword.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "`" }) {
            return "A keyword has no spaces, quotes or backticks"
        }
        return keyword.count > 64 ? "A keyword is at most 64 characters" : nil
    }

    // MARK: Import and export

    /// Raycast's export: `[{name, text, keyword?}]`.
    struct Exported: Codable {
        var name: String
        var text: String
        var keyword: String?
        var tags: [String]?
    }

    /// Raycast's older `{date: yyyy-MM-dd}` shorthand, as `{date format="…"}`.
    static func modernized(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            rest = rest[open...]
            var converted = false
            for name in ["datetime", "date", "time"] where rest.hasPrefix("{\(name):") {
                let body = rest.dropFirst(name.count + 2)
                if let close = body.firstIndex(of: "}") {
                    let format = body[..<close].trimmingCharacters(in: .whitespaces)
                    if !format.isEmpty, !format.contains("\"") {
                        result += "{\(name) format=\"\(format)\"}"
                        rest = body[body.index(after: close)...]
                        converted = true
                    }
                }
                break
            }
            if !converted {
                result.append("{")
                rest = rest.dropFirst()
            }
        }
        return result + rest
    }

    func importSnippets() async throws -> String {
        guard let file = try await Stackbar.chooseFile(types: ["json"]) else { return "Import cancelled" }
        let items: [Exported]
        do {
            items = try JSONDecoder().decode([Exported].self, from: file.data)
        } catch {
            throw HostError("\(file.name) is not a snippets export: \(error.localizedDescription)")
        }
        var imported = 0
        var duplicates = 0
        var problems: [String] = []
        var droppedKeywords: [String] = []
        for item in items {
            let text = Self.modernized(item.text)
            if snippets.contains(where: { $0.name == item.name && ($0.text == text || $0.text == item.text) }) {
                duplicates += 1
                continue
            }
            if let problem = Self.importProblem(with: text) {
                problems.append("\(item.name): \(problem)")
                continue
            }
            var keyword = item.keyword.flatMap { $0.isEmpty ? nil : $0 }
            if let candidate = keyword, Self.problem(withKeyword: candidate) != nil || snippets.contains(where: { $0.keyword == candidate }) {
                droppedKeywords.append(candidate)
                keyword = nil
            }
            snippets.append(Snippet(id: UUID(), name: item.name, text: text, keyword: keyword, tags: item.tags ?? []))
            imported += 1
        }
        var summary = "Imported \(imported)"
        if duplicates > 0 { summary += ", skipped \(duplicates) duplicate\(duplicates == 1 ? "" : "s")" }
        if !problems.isEmpty { summary += ", skipped \(problems.count) that didn't parse (\(problems.prefix(3).joined(separator: "; ")))" }
        if !droppedKeywords.isEmpty { summary += "; left out keywords already taken or not allowed: " + droppedKeywords.prefix(5).joined(separator: ", ") }
        notice = summary
        return summary
    }

    /// The checks that don't depend on the other snippets, which may arrive
    /// later in the same file.
    static func importProblem(with text: String) -> String? {
        if text.isEmpty { return "it is empty" }
        if text.count > maxLength { return "it is over 65,536 characters" }
        do { _ = try Template(text) } catch { return "\(error)" }
        return nil
    }

    func exportSnippets() async throws -> String {
        guard !snippets.isEmpty else { return "No snippets to export" }
        let items = snippets.map { Exported(name: $0.name, text: $0.text, keyword: $0.keyword, tags: $0.tags.isEmpty ? nil : $0.tags) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let path = try await Stackbar.saveFile("Snippets.json", data: try encoder.encode(items)) else { return "Export cancelled" }
        return "Exported \(snippets.count) to \(path)"
    }

    // MARK: Panel and settings

    let theme = Theme.indigo

    func openCommand(_ command: String) {
        Stackbar.open("stackbar://commands/\(Self.manifest.id)/\(command)")
    }

    var panel: ViewContent {
        if !snippets.isEmpty {
            PanelHeader(snippets.count == 1 ? "1 snippet" : "\(snippets.count) snippets", subtitle: "⌃⌥S to search and paste", symbol: "text.quote", theme: theme) {
                IconButton("plus", label: "New Snippet", theme: theme, prominence: .tinted) { self.openCommand("create") }
            }
            if let notice { Banner(notice, symbol: "checkmark.circle.fill", theme: .success) }
            if !allTags.isEmpty {
                TagChips(tagsByUse, selection: panelTag.flatMap { allTags.contains($0) ? $0 : nil }, theme: theme, limit: 3) { self.panelTag = $0 }
            }
        }
        if panelTag == nil || !allTags.contains(panelTag ?? "") { quickPaste }
        searchView(tag: panelTag.flatMap { allTags.contains($0) ? $0 : nil })
    }

    /// The first four snippets that paste without asking anything, as
    /// tiles: one click each. Only with enough snippets to need a shortcut.
    @ViewBuilder var quickPaste: ViewContent {
        let quick = snippets.filter { !arguments(of: $0).contains(where: \.required) }.prefix(4)
        if snippets.count > 4, quick.count >= 2 {
            Grid(columns: 2, spacing: Space.xs) {
                ForEach(Array(quick)) { snippet in
                    Tile(Self.clip(snippet.name, 18), subtitle: Self.clip(Self.firstLine(of: preview(snippet)), 22), symbol: Self.symbol(for: snippet), theme: theme,
                         key: "quick-" + snippet.id.uuidString) { try await self.paste(snippet) }
                }
            }
        }
    }

    /// One line short enough for a tile, so tiles in a row match.
    static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    /// A symbol for what the snippet holds: placeholders, a link, code,
    /// several lines, or plain text.
    static func symbol(for snippet: Snippet) -> String {
        let text = snippet.text
        if text.contains("{") && snippet.template.map({ !$0.placeholders.isEmpty }) == true { return "curlybraces" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return "link" }
        if ["func ", "let ", "const ", "def ", "import ", "SELECT ", "#!/", "$ ", "git "].contains(where: trimmed.hasPrefix) { return "chevron.left.forwardslash.chevron.right" }
        if trimmed.contains("\n") { return "text.alignleft" }
        return "text.quote"
    }

    var settings: ViewContent {
        Section("Snippets") {
            LabeledContent("Saved", value: "\(snippets.count)")
            if let notice { Text(notice).style(.caption) }
            Button("Import from Raycast…", symbol: "square.and.arrow.down") { _ = try await self.importSnippets() }
            Button("Export…", symbol: "square.and.arrow.up") { self.notice = try await self.exportSnippets() }
        }
        Section("Pasting") {
            Text("⌃⌥S opens Search Snippets; give one you use often its own hotkey in Settings › Commands. Pasting needs Accessibility access and puts your clipboard back after.").style(.caption)
            Text("Keywords are searchable but not expanded as you type. For plain text, macOS can expand them in System Settings › Keyboard › Text Replacements.").style(.caption)
        }
    }
}
