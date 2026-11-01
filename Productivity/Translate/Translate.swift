import StackbarKit
import Foundation

/// Translates the text you selected, from the palette, a hotkey or
/// Spotlight.
///
/// With no setup it opens Google Translate in your browser with the text
/// filled in. With a DeepL API key (the free plan is enough) it translates
/// in place, so you can paste the result over the selection or copy it.
/// When an app doesn't share its selection, it uses what you last copied.
@main
final class Translate: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.translate",
        name: "Translate",
        version: "1.0.0",
        summary: "Translate the selected text, in your browser or in place with DeepL.",
        surfaces: [.panel, .settings],
        triggers: [.launch],
        // The selection; the clipboard as a fallback and for pasting the
        // result; DeepL's two API hosts (free and paid keys).
        capabilities: [.context, .clipboard, .network("api-free.deepl.com", "api.deepl.com"), .secret(name: "DEEPL_API_KEY")],
        minimumStackbar: "0.11.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/Translate"
    )

    struct Language: Equatable {
        var name: String
        var google: String
        var deepl: String
    }

    static let languages: [Language] = [
        .init(name: "English", google: "en", deepl: "EN-US"),
        .init(name: "English (UK)", google: "en", deepl: "EN-GB"),
        .init(name: "German", google: "de", deepl: "DE"),
        .init(name: "French", google: "fr", deepl: "FR"),
        .init(name: "Spanish", google: "es", deepl: "ES"),
        .init(name: "Italian", google: "it", deepl: "IT"),
        .init(name: "Portuguese (Brazil)", google: "pt", deepl: "PT-BR"),
        .init(name: "Portuguese", google: "pt-PT", deepl: "PT-PT"),
        .init(name: "Dutch", google: "nl", deepl: "NL"),
        .init(name: "Polish", google: "pl", deepl: "PL"),
        .init(name: "Swedish", google: "sv", deepl: "SV"),
        .init(name: "Danish", google: "da", deepl: "DA"),
        .init(name: "Finnish", google: "fi", deepl: "FI"),
        .init(name: "Czech", google: "cs", deepl: "CS"),
        .init(name: "Turkish", google: "tr", deepl: "TR"),
        .init(name: "Ukrainian", google: "uk", deepl: "UK"),
        .init(name: "Russian", google: "ru", deepl: "RU"),
        .init(name: "Indonesian", google: "id", deepl: "ID"),
        .init(name: "Japanese", google: "ja", deepl: "JA"),
        .init(name: "Korean", google: "ko", deepl: "KO"),
        .init(name: "Chinese (Simplified)", google: "zh-CN", deepl: "ZH-HANS"),
        .init(name: "Chinese (Traditional)", google: "zh-TW", deepl: "ZH-HANT"),
    ]

    static let maxCharacters = 5_000

    @Stored("engine") var engine = "Google Translate (browser)"
    @Stored("target") var target = "English"
    @Stored("second") var second = "German"
    @Stored("formality") var formality = "Default"

    var useDeepL: Bool { engine == "DeepL" }

    /// The last translation, for the view.
    var result: (source: String, text: String, detected: String?, target: String)?
    var problem: String?

    static func language(_ name: String?) -> Language {
        languages.first { $0.name == name } ?? languages[0]
    }

    /// The selection, or the clipboard when the app doesn't share it.
    func input(_ invocation: CommandInvocation) async throws -> String? {
        if !invocation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return invocation.text }
        if let selected = invocation.context?.selectedText, !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return selected }
        if let copied = try await Stackbar.clipboard(), !copied.concealed, let text = copied.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        return nil
    }

    static func googleURL(_ text: String, to language: Language) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encoded = String(text.prefix(maxCharacters)).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "https://translate.google.com/?sl=auto&tl=\(language.google)&op=translate&text=\(encoded)"
    }

    /// Translates with DeepL. A key ending in `:fx` is a free-plan key.
    func deepL(_ text: String, to language: Language) async throws -> (text: String, detected: String?) {
        guard let key = try await Stackbar.secret("DEEPL_API_KEY"), !key.isEmpty else {
            throw HostError("Add your DeepL API key (DEEPL_API_KEY), or switch to Google Translate in Settings")
        }
        let host = key.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
        var body: [String: Any] = ["text": [String(text.prefix(Self.maxCharacters))], "target_lang": language.deepl]
        if formality != "Default" { body["formality"] = formality == "Formal" ? "prefer_more" : "prefer_less" }
        let response = try await Stackbar.http(HTTPRequest(url: "https://\(host)/v2/translate", method: "POST", headers: [
            "Authorization": "DeepL-Auth-Key \(key)", "Content-Type": "application/json",
        ], body: try JSONSerialization.data(withJSONObject: body)))
        switch response.status {
        case 200..<300: break
        case 403: throw HostError("DeepL rejected the key (403); check DEEPL_API_KEY")
        case 456: throw HostError("Your DeepL quota for this month is used up")
        case 429: throw HostError("DeepL is busy; try again in a moment")
        default: throw HostError("DeepL answered \(response.status)")
        }
        struct Reply: Decodable {
            struct Item: Decodable { let detected_source_language: String?; let text: String }
            let translations: [Item]
        }
        let reply = try JSONDecoder().decode(Reply.self, from: response.body)
        guard let first = reply.translations.first else { throw HostError("DeepL sent no translation") }
        return (first.text, first.detected_source_language)
    }

    /// Translating into the language the text is already in switches to
    /// the second language, so one command goes both ways.
    func translate(_ text: String, to name: String?) async throws {
        var language = Self.language(name ?? target)
        var translated = try await deepL(text, to: language)
        if name == nil, let detected = translated.detected, language.deepl.hasPrefix(detected) {
            language = Self.language(second)
            translated = try await deepL(text, to: language)
        }
        result = (text, translated.text, translated.detected, language.name)
    }

    // MARK: Commands

    var commands: [Command] {
        Command("translate", title: "Translate Selection", subtitle: "The selected text, or what you copied", symbol: "character.bubble", keywords: ["translate", "deepl", "google", "language"])
            .argument("to", placeholder: "Into", required: false, options: Self.languages.map(\.name))
            .view(search: { invocation in
                self.problem = nil
                guard let text = try await self.input(invocation) else {
                    self.result = nil
                    self.problem = "Select some text first (or copy it), or type it here"
                    return
                }
                if self.useDeepL {
                    do { try await self.translate(text, to: invocation["to"]) } catch { self.problem = "\(error)" }
                } else {
                    self.result = (text, "", nil, invocation["to"] ?? self.target)
                }
            }) { invocation in
                self.view(into: invocation["to"])
            }
        Command("open-google", title: "Translate Selection in Google Translate", symbol: "globe", keywords: ["translate", "google"]) { invocation in
            guard let text = try await self.input(invocation) else { return .failure("Select some text first, or copy it") }
            return .open(url: Self.googleURL(text, to: Self.language(invocation["to"] ?? self.target)), app: nil)
        }
        .argument("to", placeholder: "Into", required: false, options: Self.languages.map(\.name))
    }

    @ViewBuilder func view(into name: String?) -> ViewContent {
        if let problem {
            ContentUnavailableView("Can't translate", symbol: "character.bubble", message: problem)
        } else if let result {
            if useDeepL {
                List {
                    Row(result.text, subtitle: "\(result.detected.map { "From \($0) " } ?? "")into \(result.target)", symbol: "character.bubble", key: "translation")
                        .preview(text: result.text, caption: "\(result.source.count) characters translated by DeepL")
                        .action("Paste") {
                            try await Stackbar.paste(.text(result.text), restoringClipboard: true)
                        }
                        .action("Copy", shortcut: "cmd+c") { Stackbar.copy(result.text) }
                        .action("Open in Google Translate", shortcut: "cmd+o") {
                            Stackbar.open(Self.googleURL(result.source, to: Self.language(result.target)))
                        }
                }
            } else {
                Text(String(result.source.prefix(400))).style(.body)
                Button("Open in Google Translate (\(result.target))", symbol: "globe", role: .accent) {
                    Stackbar.open(Self.googleURL(result.source, to: Self.language(result.target)))
                }
                Text("Add a DeepL API key in Settings to translate here instead.").style(.caption)
            }
        } else {
            ContentUnavailableView("Translating…", symbol: "character.bubble")
        }
    }

    // MARK: Panel and settings

    var panel: ViewContent {
        Text("Select text in any app, then run Translate Selection from the palette, or give it a hotkey in Settings > Commands.").style(.caption)
        LabeledContent("Engine", value: engine)
        LabeledContent("Into", value: "\(target), or \(second) when the text is already in \(target)")
    }

    var settings: ViewContent {
        Section("Engine") {
            Picker("Translate with", options: ["Google Translate (browser)", "DeepL"], selection: engine) { self.engine = $0 }
            if useDeepL {
                Text("DeepL needs an API key: the free plan at deepl.com/pro-api covers 500,000 characters a month. Stackbar asks for it the first time and keeps it in your Keychain.").style(.caption)
                Picker("Formality", options: ["Default", "Formal", "Informal"], selection: formality) { self.formality = $0 }
            } else {
                Text("Opens translate.google.com with the text filled in. Nothing is sent until you look at it there.").style(.caption)
            }
        }
        Section("Languages") {
            Picker("Into", options: Self.languages.map(\.name), selection: target) { self.target = $0 }
            Picker("Or, when it's already in that", options: Self.languages.map(\.name), selection: second) { self.second = $0 }
        }
    }
}
