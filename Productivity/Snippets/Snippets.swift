import StackbarKit
import Foundation

/// Snippets: text you paste by name, with placeholders filled in.
///
/// Each snippet becomes a command of its own that pastes into the app you
/// were in, then puts your clipboard back. Its text is a template in
/// Raycast's syntax: `{clipboard}`, `{selection}`, `{date format="d MMM"}`,
/// `{argument name="who"}` asks first, `{cursor}` leaves the caret there, and
/// `{snippet name="Signature"}` pulls in another snippet. "Search Snippets"
/// (⌃⌥S) lists them with a preview. Raycast exports import as they are;
/// TextExpander, Espanso and Apple's Text Replacements import with their
/// placeholders turned into these.
///
/// A snippet's keyword, like `;sig`, expands as you type it in any app:
/// Stackbar watches for the keywords this plugin registers, deletes the one
/// typed and runs the snippet's command. The plugin never sees the typing.
@main
final class Snippets: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.snippets",
        name: "Snippets",
        version: "1.5.1",
        summary: "Paste text by name, with placeholders filled in.",
        surfaces: [.panel, .settings],
        triggers: [.launch],
        // Pasting; the selection for {selection}; room for thousands of
        // snippets at Raycast's 65,536-character limit; keywords that
        // expand as you type.
        capabilities: [.clipboard, .context, .storage(megabytes: 16), .textExpansion],
        hotkey: "ctrl+option+s",
        minimumStackbar: "0.24.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/Snippets",
        accent: .indigo,
        symbol: "text.insert"
    )

    // MARK: Previews

    static let previews: [PreviewScene<Snippets>] = [
        PreviewScene("hero", "Text you type often, a keystroke away") { plugin in
            plugin.snippets = samples
        },
    ]

    static let samples: [Snippet] = {
        func snippet(_ number: Int, _ name: String, _ text: String, keyword: String, tags: [String]) -> Snippet {
            Snippet(id: UUID(uuidString: String(format: "5A1B0000-0000-4000-8000-%012d", number)) ?? UUID(), name: name, text: text, keyword: keyword, tags: tags)
        }
        return [
            snippet(1, "Email sign-off", "Thanks,\nSam", keyword: ";thx", tags: ["Email"]),
            snippet(2, "Today's date", "{date}", keyword: ";date", tags: ["Everyday"]),
            snippet(3, "Meeting link", "Here's the link for our call: https://meet.example.com/sam", keyword: ";meet", tags: ["Work"]),
            snippet(4, "Shipping address", "Sam Rivera\n12 Harbour Street\nSpringfield", keyword: ";addr", tags: ["Everyday"]),
            snippet(5, "Bug report", "**Steps**\n1. \n\n**Expected**\n\n**Actual**\n\nVersion: {clipboard}", keyword: ";bug", tags: ["Work"]),
            snippet(6, "Review reply", "Thanks for the review! I've addressed {Comment} in the latest commit.", keyword: ";rev", tags: ["Work"]),
            snippet(7, "Swift test", "func test{Name}() throws {\n    \n}", keyword: ";test", tags: ["Code"]),
        ]
    }()

    static let maxLength = 65_536

    struct Snippet: Codable, Equatable, Identifiable {
        var id: UUID
        var name: String
        /// A template, at most 65,536 characters.
        var text: String
        /// Expands to the snippet as you type it, and is matched by search.
        var keyword: String?
        var tags: [String] = []

        var commandID: String { "sn-" + id.uuidString.lowercased() }
        var template: Template? { try? Template(text) }
    }

    /// The snippets, read from storage once and written back when they
    /// change (reading a `@Stored` array decodes all of it, and a render reads
    /// the snippets for every row).
    private var cached: [Snippet]?
    /// Snippets by name and by keyword, in order, for `{snippet name=}`.
    private var cachedIndex: [String: [(id: UUID, text: String)]]?
    var snippets: [Snippet] {
        get {
            if let cached { return cached }
            let loaded = Stackbar.storage.value("snippets", as: [Snippet].self) ?? []
            cached = loaded
            return loaded
        }
        set {
            cached = newValue
            cachedIndex = nil
            Stackbar.storage.set("snippets", newValue)
            registerKeywords()
        }
    }
    /// The tag the panel filters by; nil shows them all.
    @Stored("panelTag") var panelTag: String? = nil
    var draft = Draft()
    var notice: String?
    /// The keywords last handed to Stackbar, so an edit that leaves them be
    /// sends nothing.
    var registered: [TextExpansion]?
    /// Whether they expand, and if not, why (shown in Settings).
    var expansion: ExpansionStatus?

    func refresh() async throws {
        registerKeywords()
    }

    /// Every snippet's keyword, to its command. Keywords Stackbar can't
    /// expand (over 32 characters, say) stay searchable.
    var expansions: [TextExpansion] {
        var seen: Set<String> = []
        let all = snippets.compactMap { snippet -> TextExpansion? in
            guard let keyword = snippet.keyword, TextExpansion.isValidKeyword(keyword), seen.insert(keyword).inserted else { return nil }
            return TextExpansion(keyword: keyword, command: snippet.commandID)
        }
        return Array(all.prefix(TextExpansion.maxPerPlugin))
    }

    /// Hands Stackbar the keywords when they changed.
    func registerKeywords() {
        let expansions = expansions
        guard expansions != registered else { return }
        registered = expansions
        // One request at a time, in the order they were made: the host
        // answers each in its own task, so an older list could land last.
        let previous = registration
        registration = Task {
            await previous?.value
            do {
                let status = try await Stackbar.setExpansions(expansions)
                if self.registered == expansions { self.expansion = status }
            } catch {
                // Tried again on the next change or launch.
                if self.registered == expansions { self.registered = nil }
            }
        }
    }
    private var registration: Task<Void, Never>?

    /// The create and edit form's errors, kept between its renders.
    struct Draft {
        var nameError: String?
        var textError: String?
        var keywordError: String?
    }

    // MARK: Rendering

    /// What `{snippet name="…"}` can name: every snippet by name, and by
    /// keyword too.
    /// The text `{snippet name=}` finds for a name, without building the library.
    func included(named name: String, excluding id: UUID?) -> String? {
        let index: [String: [(id: UUID, text: String)]]
        if let cachedIndex {
            index = cachedIndex
        } else {
            var built: [String: [(id: UUID, text: String)]] = [:]
            for snippet in snippets {
                if let keyword = snippet.keyword, !keyword.isEmpty { built[keyword, default: []].append((snippet.id, snippet.text)) }
                built[snippet.name, default: []].append((snippet.id, snippet.text))
            }
            cachedIndex = built
            index = built
        }
        return index[name]?.last { $0.id != id }?.text
    }

    /// The library a template renders against: empty unless it includes a
    /// snippet, so rendering a row doesn't walk every snippet.
    func environmentLibrary(for snippet: Snippet, template: Template) -> [String: String] {
        Self.included(by: template).isEmpty ? [:] : library(excluding: snippet.id)
    }

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
        return Self.included(by: template).contains { (included(named: $0, excluding: snippet.id).flatMap { try? Template($0) })?.uses(name) ?? false }
    }

    /// Renders a snippet with what the user typed, copied and selected.
    func render(_ snippet: Snippet, arguments: [String: String], context: InvocationContext?) async throws -> Template.Rendered {
        let template = try Template(snippet.text)
        var environment = Template.Environment(selection: context?.selectedText, snippets: environmentLibrary(for: snippet, template: template))
        if uses("clipboard", in: snippet) { environment.clipboard = try await Stackbar.clipboard()?.text }
        if environment.selection == nil, context == nil, uses("selection", in: snippet) { environment.selection = try await Stackbar.context().selectedText }
        return try template.render(arguments, in: environment)
    }

    /// The text with today's values, and markers for what is only known
    /// when it is pasted.
    func preview(_ snippet: Snippet) -> String {
        guard let template = snippet.template else { return snippet.text }
        let values = Dictionary(arguments(of: snippet).map { ($0.name, $0.defaultValue ?? $0.options?.first ?? "‹\($0.name)›") }, uniquingKeysWith: { first, _ in first })
        let environment = Template.Environment(clipboard: "‹clipboard›", selection: "‹selection›", snippets: environmentLibrary(for: snippet, template: template))
        return (try? template.render(values, in: environment).text) ?? snippet.text
    }

    /// What the snippet asks for: its own arguments, then those of the
    /// snippets it includes, which get the same values.
    func arguments(of snippet: Snippet) -> [ArgumentSpec] {
        guard let template = snippet.template else { return [] }
        var arguments = template.arguments
        for name in Self.included(by: template) {
            for argument in (included(named: name, excluding: snippet.id).flatMap { try? Template($0) })?.arguments ?? [] where !arguments.contains(where: { $0.name == argument.name }) {
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
        Command("import", title: "Import Snippets", subtitle: "From Raycast, TextExpander, Espanso or Text Replacements", symbol: "square.and.arrow.down", keywords: ["snippet", "raycast", "textexpander", "espanso", "text replacements"]) { _ in
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
                ActionButton("Import Snippets", symbol: "square.and.arrow.down", theme: theme) { self.notice = try await self.importSnippets() }
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
            FormField.text("Keyword", name: "keyword", value: existing?.keyword ?? "", placeholder: ";sig (expands as you type it)", error: draft.keywordError)
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
        // One change, one save.
        var all = snippets
        if let id, let index = all.firstIndex(where: { $0.id == id }) {
            all[index].name = name
            all[index].text = text
            all[index].keyword = keyword.isEmpty ? nil : keyword
            all[index].tags = tags
        } else {
            all.append(Snippet(id: UUID(), name: name, text: text, keyword: keyword.isEmpty ? nil : keyword, tags: tags))
        }
        snippets = all
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
        return keyword.count > TextExpansion.maxKeywordLength ? "A keyword is at most \(TextExpansion.maxKeywordLength) characters" : nil
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

    /// What Import Snippets reads.
    static let importTypes = ["json", "plist", "textexpander", "csv", "yml", "yaml"]

    func importSnippets() async throws -> String {
        guard let file = try await Stackbar.chooseFile(types: Self.importTypes) else { return "Import cancelled" }
        let items = try Self.parseImport(name: file.name, data: file.data)
        var imported = 0
        var duplicates = 0
        var problems: [String] = []
        var droppedKeywords: [String] = []
        // Collected here and saved once, not once per item.
        var all = snippets
        for item in items {
            let text = Self.modernized(item.text)
            if all.contains(where: { $0.name == item.name && ($0.text == text || $0.text == item.text) }) {
                duplicates += 1
                continue
            }
            if let problem = Self.importProblem(with: text) {
                problems.append("\(item.name): \(problem)")
                continue
            }
            var keyword = item.keyword.flatMap { $0.isEmpty ? nil : $0 }
            if let candidate = keyword, Self.problem(withKeyword: candidate) != nil || all.contains(where: { $0.keyword == candidate }) {
                droppedKeywords.append(candidate)
                keyword = nil
            }
            all.append(Snippet(id: UUID(), name: item.name, text: text, keyword: keyword, tags: item.tags ?? []))
            imported += 1
        }
        if imported > 0 { snippets = all }
        var summary = "Imported \(imported)"
        if duplicates > 0 { summary += ", skipped \(duplicates) duplicate\(duplicates == 1 ? "" : "s")" }
        if !problems.isEmpty { summary += ", skipped \(problems.count) that didn't parse (\(problems.prefix(3).joined(separator: "; ")))" }
        if !droppedKeywords.isEmpty { summary += "; left out keywords already taken or not allowed: " + droppedKeywords.prefix(5).joined(separator: ", ") }
        notice = summary
        return summary
    }

    // MARK: Importers

    /// Reads any export the importer knows, by its extension and then its
    /// contents: Raycast's JSON, Apple's Text Replacements (a plist dragged
    /// out of System Settings), TextExpander (`.textexpander` or CSV) and
    /// Espanso's YAML match files.
    static func parseImport(name: String, data: Data) throws -> [Exported] {
        let lower = name.lowercased()
        let text = String(decoding: data, as: UTF8.self)
        if lower.hasSuffix(".yml") || lower.hasSuffix(".yaml") || text.range(of: #"(?m)^matches\s*:"#, options: .regularExpression) != nil {
            let items = espanso(text)
            guard !items.isEmpty else { throw HostError("\(name) has no Espanso matches with a trigger and a replace") }
            return items
        }
        if lower.hasSuffix(".csv") {
            let items = textExpanderCSV(text)
            guard !items.isEmpty else { throw HostError("\(name) has no abbreviation,content rows") }
            return items
        }
        if !lower.hasSuffix(".json"), let plist = try? PropertyListSerialization.propertyList(from: data, format: nil), !(plist is String) {
            if let items = textReplacements(plist) ?? textExpander(plist), !items.isEmpty { return items }
            throw HostError("\(name) is a property list, but not Text Replacements or a TextExpander group")
        }
        do {
            return try JSONDecoder().decode([Exported].self, from: data)
        } catch {
            throw HostError("\(name) is not a snippets export Stackbar knows (Raycast JSON, TextExpander, Espanso or Text Replacements)")
        }
    }

    /// Apple's Text Replacements: `[{phrase, shortcut}]`.
    static func textReplacements(_ plist: Any) -> [Exported]? {
        guard let rows = plist as? [[String: Any]], rows.contains(where: { $0["phrase"] != nil }) else { return nil }
        return rows.compactMap { row in
            guard let phrase = row["phrase"] as? String, !phrase.isEmpty else { return nil }
            let shortcut = (row["shortcut"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Exported(name: shortcut.map { "\($0): \(clip(firstLine(of: phrase), 40))" } ?? clip(firstLine(of: phrase), 40),
                            text: phrase, keyword: shortcut, tags: ["Text Replacements"])
        }
    }

    /// A TextExpander group: `{groupName, snippetsTE2: [{abbreviation, plainText, label}]}`.
    static func textExpander(_ plist: Any) -> [Exported]? {
        guard let group = plist as? [String: Any], let rows = (group["snippetsTE2"] ?? group["snippets"]) as? [[String: Any]] else { return nil }
        let tag = (group["groupName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "TextExpander"
        return rows.compactMap { row in
            guard let content = (row["plainText"] ?? row["snippetText"]) as? String, !content.isEmpty else { return nil }
            let abbreviation = (row["abbreviation"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let label = (row["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Exported(name: label ?? abbreviation ?? clip(firstLine(of: content), 40), text: fromTextExpander(content), keyword: abbreviation, tags: [tag])
        }
    }

    /// TextExpander's CSV export: abbreviation, content, label.
    static func textExpanderCSV(_ text: String) -> [Exported] {
        csvRows(text).compactMap { fields in
            guard fields.count >= 2, !fields[1].isEmpty, fields[0].lowercased() != "abbreviation" else { return nil }
            let abbreviation = fields[0].isEmpty ? nil : fields[0]
            let label = fields.count > 2 && !fields[2].isEmpty ? fields[2] : nil
            return Exported(name: label ?? abbreviation ?? clip(firstLine(of: fields[1]), 40), text: fromTextExpander(fields[1]), keyword: abbreviation, tags: ["TextExpander"])
        }
    }

    /// RFC 4180 rows: quoted fields may hold commas, newlines and `""`.
    static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var characters = Array(text)
        if characters.first == "\u{FEFF}" { characters.removeFirst() }
        var index = 0
        func endRow() {
            row.append(field)
            field = ""
            if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
            row = []
        }
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" {
                quoted = true
            } else if character == "," {
                row.append(field)
                field = ""
            } else if character == "\n" || character == "\r\n" || character == "\r" {
                endRow()
            } else {
                field.append(character)
            }
            index += 1
        }
        endRow()
        return rows
    }

    /// TextExpander's `%clipboard`, `%|` (cursor), `%filltext:name=who%` and
    /// date codes, as this plugin's placeholders. Anything else stays as
    /// written.
    static func fromTextExpander(_ content: String) -> String {
        var text = content.replacingOccurrences(of: "%clipboard", with: "{clipboard}").replacingOccurrences(of: "%|", with: "{cursor}")
        if let fill = try? NSRegularExpression(pattern: #"%fill(?:text|area|popup)?:name=([^:%]+)(?::[^%]*)?%"#) {
            text = fill.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "{argument name=\"$1\"}")
        }
        let dates: [(String, String)] = [("%1m", "M"), ("%1H", "H"), ("%1I", "h"), ("%Y", "yyyy"), ("%y", "yy"), ("%m", "MM"), ("%d", "dd"), ("%e", "d"),
                                         ("%B", "MMMM"), ("%b", "MMM"), ("%A", "EEEE"), ("%a", "EEE"), ("%H", "HH"), ("%I", "hh"), ("%M", "mm"), ("%S", "ss"), ("%p", "a")]
        for (code, format) in dates {
            text = text.replacingOccurrences(of: code, with: "{date format=\"\(format)\"}")
        }
        return text
    }

    /// Espanso's `matches:` list, from a match file. A small reader for the
    /// shapes Espanso's docs use: `trigger:` or `triggers: [...]`,
    /// `replace:` as a plain, quoted or block (`|`, `>`) value, and `label:`.
    /// `$|$` becomes the cursor and `{{clipboard}}` the clipboard; other
    /// variables stay as written.
    static func espanso(_ yaml: String) -> [Exported] {
        var items: [Exported] = []
        var current: [String: String] = [:]
        var triggers: [String] = []
        func flush() {
            defer { current = [:]; triggers = [] }
            guard let replace = current["replace"], !replace.isEmpty else { return }
            let text = replace.replacingOccurrences(of: "$|$", with: "{cursor}").replacingOccurrences(of: "{{clipboard}}", with: "{clipboard}")
            for trigger in triggers.isEmpty ? [nil] : triggers.map(Optional.some) {
                items.append(Exported(name: current["label"] ?? trigger ?? clip(firstLine(of: replace), 40), text: text, keyword: trigger, tags: ["Espanso"]))
            }
        }
        let lines = yaml.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        var inMatches = false
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count
            if indent == 0, !trimmed.hasPrefix("- ") {
                flush()
                inMatches = trimmed.hasPrefix("matches:")
                continue
            }
            guard inMatches else { continue }
            var entry = trimmed
            if entry.hasPrefix("- ") {
                flush()
                entry = String(entry.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            guard let colon = entry.firstIndex(of: ":") else { continue }
            let key = String(entry[..<colon]).trimmingCharacters(in: .whitespaces)
            let raw = String(entry[entry.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // Where the key starts, past any "- ".
            let keyIndent = line.prefix { $0 == " " || $0 == "-" }.count
            var value: String
            if raw.hasPrefix("|") || raw.hasPrefix(">") {
                // A block: every following line indented past the key.
                var block: [String] = []
                var blockIndent: Int?
                while index < lines.count {
                    let next = lines[index]
                    let nextIndent = next.prefix { $0 == " " }.count
                    let blank = next.trimmingCharacters(in: .whitespaces).isEmpty
                    if !blank, nextIndent <= keyIndent - (trimmed.hasPrefix("- ") ? 2 : 0) || (!blank && nextIndent < keyIndent && blockIndent == nil) { break }
                    if blockIndent == nil, !blank { blockIndent = nextIndent }
                    if !blank, let blockIndent, nextIndent < blockIndent { break }
                    block.append(blank ? "" : String(next.dropFirst(blockIndent ?? 0)))
                    index += 1
                }
                while block.last?.isEmpty == true { block.removeLast() }
                value = raw.hasPrefix(">") ? block.joined(separator: " ") : block.joined(separator: "\n")
                if !raw.hasSuffix("-") { value += "\n" }
            } else {
                value = unquoted(raw)
            }
            switch key {
            case "trigger": triggers.append(value)
            case "triggers":
                triggers += raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",")
                    .map { unquoted($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
            case "replace", "label": current[key] = value
            default: break
            }
        }
        flush()
        return items
    }

    /// A YAML scalar: double quoted (with `\n` escapes), single quoted, or plain.
    static func unquoted(_ raw: String) -> String {
        if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
            var result = ""
            var escaped = false
            for character in raw.dropFirst().dropLast() {
                if escaped {
                    switch character {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    default: result.append(character)
                    }
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else {
                    result.append(character)
                }
            }
            return result
        }
        if raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'") {
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        // A plain scalar ends at a comment.
        if let hash = raw.range(of: " #") { return String(raw[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return raw
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

    /// Whether keywords expand, in words.
    var expansionSummary: String {
        let count = expansions.count
        guard count > 0 else { return "No snippet has a keyword yet." }
        let keywords = count == 1 ? "1 keyword" : "\(count) keywords"
        guard let status = expansion else { return "\(keywords) registered." }
        if status.turnedOff { return "\(keywords), but keyword expansion is switched off in Stackbar Settings." }
        if status.needsAccessibility { return "\(keywords), waiting for Accessibility access in System Settings › Privacy & Security." }
        if let app = status.secureInputApp { return "\(keywords), paused while \(app) has Secure Input on." }
        var text = status.listening ? "\(keywords) expand as you type." : "\(keywords) registered."
        if !status.taken.isEmpty { text += " Another plugin already uses " + status.taken.prefix(3).joined(separator: ", ") + "." }
        return text
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
        }
        Section("Keywords") {
            Text(expansionSummary).style(.caption)
            Text("Type a snippet's keyword anywhere and it is replaced with the snippet. Turn this off, or skip apps, in Stackbar Settings › Privacy & Secrets.").style(.caption)
        }
    }
}
