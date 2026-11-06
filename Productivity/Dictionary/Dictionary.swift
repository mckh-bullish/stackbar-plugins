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
        version: "1.0.0",
        summary: "Look words up in the Mac's own Dictionary, offline, from the palette.",
        surfaces: [.panel],
        triggers: [.launch],
        capabilities: [],
        minimumStackbar: "0.26.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/Dictionary",
        accent: .indigo,
        symbol: "character.book.closed"
    )

    let theme = Theme.indigo

    /// Newest first.
    @Stored("recent") var recent: [String] = []
    var found: Definition?
    var looked = ""

    func lookUp(_ text: String) async {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        looked = word
        guard !word.isEmpty else { found = nil; return }
        found = (try? await Stackbar.define(String(word.prefix(Definition.maxQuery)))) ?? nil
    }

    func remember(_ word: String) {
        recent = Array(([word] + recent.filter { $0.lowercased() != word.lowercased() }).prefix(20))
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
            .action("Open in Dictionary", shortcut: "cmd+o") {
                self.remember(definition.word)
                let encoded = definition.word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? definition.word
                Stackbar.open("dict://\(encoded)")
            }
    }

    // MARK: Commands

    var commands: [Command] {
        Command("define", title: "Define Word", subtitle: "Look a word up in the Mac's Dictionary", symbol: "character.book.closed", keywords: ["define", "dictionary", "meaning", "word", "thesaurus"])
            .view(search: { invocation in await self.lookUp(invocation.text) }) { _ in
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
                } else {
                    ContentUnavailableView("No definition", symbol: "questionmark.circle", message: "The Mac's Dictionary has nothing for \"\(self.looked)\". Check the spelling, or add dictionaries in the Dictionary app's settings.")
                }
            }
    }

    // MARK: Panel

    var panel: ViewContent {
        PanelHeader("Dictionary", subtitle: "Define Word in the palette", symbol: "character.book.closed", theme: theme)
        if recent.isEmpty {
            EmptyState("Words, offline", symbol: "character.book.closed", message: "Open the palette and type Define Word, then the word. Definitions come from the Mac's own Dictionary.", theme: theme)
        } else {
            List {
                Section("Recent") {
                    ForEach(recent.prefix(8)) { word in Row(word, symbol: "clock.arrow.circlepath", key: word) }
                }
            }
        }
    }
}
