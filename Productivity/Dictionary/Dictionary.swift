import StackbarKit
import Foundation

/// Looks words up in the Mac's own Dictionary, offline, from the palette:
/// type "define serendipity" and the definition is right there. Words you
/// looked up stay in a list.
@main
final class Dictionary: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.dictionary",
        name: "Dictionary",
        version: "1.2.0",
        summary: "Look words up in the Mac's own Dictionary, offline, from the palette.",
        surfaces: [.panel],
        triggers: [.launch],
        // Open in Dictionary opens dict:// links, which the host only opens
        // for plugins that declare the scheme.
        capabilities: [.openURLs(schemes: ["dict"])],
        minimumStackbar: "0.26.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/Dictionary",
        accent: .indigo,
        symbol: "character.book.closed"
    )

    // MARK: Previews

    static let previews: [PreviewScene<Dictionary>] = [
        PreviewScene("hero", "Definitions as you type, offline") { plugin in
            plugin.recent = ["serendipity", "ephemeral", "laconic", "petrichor"]
            plugin.looked = "serendipity"
            plugin.found = Definition(word: "serendipity", text: "serendipity | ˌserənˈdipədē | noun the occurrence and development of events by chance in a happy or beneficial way.")
        },
        PreviewScene("recent", "Words you looked up, one click away") { plugin in
            plugin.recent = ["serendipity", "ephemeral", "laconic", "petrichor", "sonder"]
        },
    ]

    let theme = Theme.indigo

    /// Newest first.
    @Stored("recent") var recent: [String] = []
    var found: Definition?
    var looked = ""
    /// Why the last look-up failed, when it did (rather than finding nothing).
    var lookupError: String?

    func lookUp(_ text: String) async {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        looked = word
        lookupError = nil
        guard !word.isEmpty else { found = nil; return }
        do {
            found = try await Stackbar.define(String(word.prefix(Definition.maxQuery)))
        } catch {
            found = nil
            lookupError = "\(error)"
        }
    }

    func remember(_ word: String) {
        recent = Array(([word] + recent.filter { $0.lowercased() != word.lowercased() }).prefix(20))
    }

    func openInDictionary(_ word: String) async throws {
        remember(word)
        let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word
        // The waiting call, so a refusal is shown instead of nothing happening.
        try await Stackbar.open("dict://\(encoded)", with: nil)
    }

    /// The definition's first sentence-ish piece, for a row's subtitle.
    static func gist(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 140 ? String(flat.prefix(140)) + "…" : flat
    }

    func row(_ definition: Definition) -> Row {
        Row(definition.word, subtitle: Self.gist(definition.text), symbol: "character.book.closed", key: definition.word)
            .preview(text: definition.text)
            .action("Copy Definition") { self.remember(definition.word); Stackbar.copy(definition.text) }
            .action("Copy Word", shortcut: "cmd+shift+c") { Stackbar.copy(definition.word) }
            .action("Open in Dictionary", shortcut: "cmd+o") { try await self.openInDictionary(definition.word) }
    }

    // MARK: Commands

    var commands: [Command] {
        Command("define", title: "Define Word", subtitle: "Look a word up in the Mac's Dictionary", symbol: "character.book.closed", keywords: ["define", "dictionary", "meaning", "word", "thesaurus"])
            .view(search: { invocation in await self.lookUp(invocation.text.isEmpty ? (invocation["text"] ?? "") : invocation.text) }) { _ in
                if let found = self.found {
                    List { self.row(found) }
                } else if self.looked.isEmpty {
                    if self.recent.isEmpty {
                        ContentUnavailableView("Type a word", symbol: "character.book.closed", message: "Definitions come from the Mac's own Dictionary and work offline.")
                    } else {
                        List {
                            Section("Recent") {
                                ForEach(self.recent) { word in
                                    Row(word, symbol: "clock.arrow.circlepath", key: word)
                                        .navigate("Define", to: "define", arguments: ["text": word])
                                }
                            }
                        }
                    }
                } else if let error = self.lookupError {
                    ContentUnavailableView("Can't look that up", symbol: "exclamationmark.triangle", message: error)
                } else {
                    ContentUnavailableView("No definition", symbol: "questionmark.circle", message: "The Mac's Dictionary has nothing for \"\(self.looked)\". Check the spelling, or add dictionaries in the Dictionary app's settings.")
                }
            }
            .fallback()
    }

    // MARK: Panel

    var panel: ViewContent {
        PanelHeader("Dictionary", subtitle: "Define Word in the palette", symbol: "character.book.closed", theme: theme)
        TextField("Look up a word, then Return") { word in
            await self.lookUp(word)
            if let found = self.found { self.remember(found.word) }
        }
        if let found {
            Card(found.word) {
                Text(found.text.count > 600 ? String(found.text.prefix(599)) + "…" : found.text).style(.body)
                HStack(spacing: Space.s) {
                    ActionButton("Copy", symbol: "doc.on.doc", theme: theme) { Stackbar.copy(found.text) }
                    ActionButton("Open in Dictionary", symbol: "character.book.closed", theme: theme) { try await self.openInDictionary(found.word) }
                }
            }
        } else if !looked.isEmpty {
            Banner(lookupError ?? "No definition for \"\(looked)\"")
        }
        if recent.isEmpty && found == nil && looked.isEmpty {
            EmptyState("Words, offline", symbol: "character.book.closed", message: "Open the palette and type Define Word, then the word. Definitions come from the Mac's own Dictionary.", theme: theme)
        } else if !recent.isEmpty {
            List {
                Section("Recent") {
                    ForEach(recent.prefix(8)) { word in
                        Row(word, symbol: "clock.arrow.circlepath", key: word).action("Define") { await self.lookUp(word) }
                    }
                }
            }
        }
    }
}
