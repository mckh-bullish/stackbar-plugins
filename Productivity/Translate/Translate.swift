import StackbarKit
import Foundation
#if canImport(Translation)
import NaturalLanguage
import Translation
#endif

/// Translates the text you selected, from the palette, a hotkey or
/// Spotlight.
///
/// With no setup it translates in place: on your Mac with Apple's
/// translation when the language pair is downloaded, and with Google
/// Translate otherwise. DeepL (with an API key) and opening Google Translate
/// in the browser are the other engines. Paste the result over the
/// selection or copy it. When an app doesn't share its selection, it uses
/// what you last copied.
@main
final class Translate: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.translate",
        name: "Translate",
        version: "1.6.1",
        summary: "Translate the selected text in place, on your Mac or with Google or DeepL.",
        surfaces: [.panel, .settings],
        triggers: [.launch],
        // The selection; the clipboard as a fallback and for pasting the
        // result; Google Translate's keyless endpoint, used when the Mac
        // can't translate the pair itself; DeepL's two API hosts (free and
        // paid keys).
        capabilities: [.context, .clipboard, .screenText, .network("translate.googleapis.com", "api-free.deepl.com", "api.deepl.com"), .secret(name: "DEEPL_API_KEY")],
        minimumStackbar: "0.26.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/Translate",
        accent: .teal,
        symbol: "character.bubble.fill"
    )

    // MARK: Previews

    static let previews: [PreviewScene<Translate>] = [
        PreviewScene("hero", "Translate on your Mac, without leaving the app you're in") { plugin in
            plugin.result = (source: "Können wir das Meeting auf Donnerstag verschieben? Ich schicke dir vorher die Folien.",
                             text: "Can we move the meeting to Thursday? I'll send you the slides beforehand.",
                             detected: "German", target: "English", by: "On your Mac")
        },
    ]

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

    /// "Automatic" (on the Mac, else Google), "DeepL" or "Browser".
    @Stored("engine") var storedEngine = "Automatic"
    @Stored("target") var target = "English"
    @Stored("second") var second = "German"
    @Stored("formality") var formality = "Default"

    var engine: String {
        // Before 1.3 the only keyless engine opened the browser; those users get the new default.
        ["DeepL", "Browser"].contains(storedEngine) ? storedEngine : "Automatic"
    }
    var useDeepL: Bool { engine == "DeepL" }
    /// Whether the translation shows here, rather than in the browser.
    var inPlace: Bool { engine != "Browser" }

    /// The last translation, for the view. `by` names the engine that did it.
    var result: (source: String, text: String, detected: String?, target: String, by: String)?
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

    /// The language as Apple's Translation names it.
    static func appleCode(_ language: Language) -> String {
        switch language.deepl {
        case "EN-US": return "en-US"
        case "EN-GB": return "en-GB"
        case "PT-BR": return "pt-BR"
        case "ZH-HANS": return "zh-Hans"
        case "ZH-HANT": return "zh-Hant"
        default: return language.google
        }
    }

    /// Translates on the Mac, with nothing sent anywhere, when Apple's
    /// Translation has this language pair downloaded. Nil means it can't
    /// (another OS, an unknown source language, or the pair isn't installed).
    /// If the pair is installed but the translation fails, that throws: the
    /// text is not sent to Google behind the user's back.
    func onDevice(_ text: String, to language: Language) async throws -> (text: String, detected: String?)? {
        #if canImport(Translation)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let detected = recognizer.dominantLanguage?.rawValue else { return nil }
        let source = Locale.Language(identifier: detected)
        let target = Locale.Language(identifier: Self.appleCode(language))
        guard await LanguageAvailability().status(from: source, to: target) == .installed else { return nil }
        let session = TranslationSession(installedSource: source, target: target)
        let response = try await session.translate(text)
        return (response.targetText, detected)
        #else
        return nil
        #endif
    }

    /// Translates with Google Translate's keyless endpoint, the one its
    /// browser extension uses. It answers nested arrays: the translated
    /// pieces first, the detected language third.
    func google(_ text: String, to language: Language) async throws -> (text: String, detected: String?) {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let query = String(text.prefix(Self.maxCharacters)).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let response = try await Stackbar.http(HTTPRequest(url: "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=\(language.google)&dt=t&q=\(query)"))
        guard (200..<300).contains(response.status) else {
            throw HostError(response.status == 429 ? "Google Translate is busy; try again in a moment" : "Google Translate answered \(response.status)")
        }
        guard let reply = try JSONSerialization.jsonObject(with: response.body) as? [Any], let pieces = reply.first as? [Any] else {
            throw HostError("Google Translate sent something unexpected")
        }
        let translated = pieces.compactMap { ($0 as? [Any])?.first as? String }.joined()
        guard !translated.isEmpty else { throw HostError("Google Translate sent no translation") }
        return (translated, reply.count > 2 ? reply[2] as? String : nil)
    }

    /// The engine's translation, and which engine it was.
    func run(_ text: String, to language: Language) async throws -> (text: String, detected: String?, by: String) {
        if useDeepL {
            let result = try await deepL(text, to: language)
            return (result.text, result.detected, "DeepL")
        }
        // Google only takes over when the Mac can't do this pair at all; a
        // failure of the installed pair is shown, since Settings promises the
        // text stays on the Mac in that case.
        if let local = try await onDevice(text, to: language) { return (local.text, local.detected, "your Mac") }
        let result = try await google(text, to: language)
        return (result.text, result.detected, "Google Translate")
    }

    /// Whether `detected` (a DeepL, Google or Apple code) is `language`.
    static func same(_ detected: String?, _ language: Language) -> Bool {
        guard let detected = detected?.lowercased(), !detected.isEmpty else { return false }
        let code = language.google.lowercased()
        let base = detected.split(separator: "-").first.map(String.init) ?? detected
        return code == detected || code.hasPrefix(base + "-") || code == base
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
        var translated = try await run(text, to: language)
        if name == nil, Self.same(translated.detected, language) {
            language = Self.language(second)
            translated = try await run(text, to: language)
        }
        // Google and DeepL take the first 5,000 characters; say so.
        cutAt = translated.by == "your Mac" || text.count <= Self.maxCharacters ? nil : text.count
        result = (text, translated.text, translated.detected, language.name, translated.by)
    }

    /// The length of the text when only its first `maxCharacters` were translated.
    var cutAt: Int?

    /// "123 characters translated by Google Translate", and what was left out.
    func caption(_ result: (source: String, text: String, detected: String?, target: String, by: String)) -> String {
        if let cutAt { return "The first \(Self.maxCharacters) of \(cutAt) characters translated by \(result.by); the rest was not sent" }
        return "\(result.source.count) characters translated by \(result.by)"
    }

    /// The typed text the search last saw, so an older keystroke doesn't translate.
    private var latestTyped: String?

    // MARK: Commands

    var commands: [Command] {
        translateCommand("translate", title: "Translate Selection", subtitle: "The selected text, or what you copied")
        // Offered under the palette's results for any text: translates what
        // was typed.
        translateCommand("translate-typed", title: "Translate", subtitle: "What you typed")
            .fallback()
            .stackbarOnly()
        Command("translate-screen", title: "Translate Text on Screen", subtitle: "Drag over any text, even in an image", symbol: "text.viewfinder", keywords: ["translate", "screen", "ocr", "image", "capture"]) { invocation in
            guard let read = try await Stackbar.captureScreenText() else { return .done }
            let text = read.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .failure("No text found there") }
            guard self.inPlace else { return .open(url: Self.googleURL(text, to: Self.language(invocation["to"] ?? self.target)), app: nil) }
            try await self.translate(text, to: invocation["to"])
            guard let result = self.result else { return .failure("Couldn't translate it") }
            Stackbar.copy(result.text)
            return .message("Copied: " + (result.text.count > 120 ? String(result.text.prefix(119)) + "…" : result.text))
        }
        .argument("to", placeholder: "Into", required: false, options: Self.languages.map(\.name))
        Command("open-google", title: "Translate Selection in Google Translate", symbol: "globe", keywords: ["translate", "google"]) { invocation in
            guard let text = try await self.input(invocation) else { return .failure("Select some text first, or copy it") }
            return .open(url: Self.googleURL(text, to: Self.language(invocation["to"] ?? self.target)), app: nil)
        }
        .argument("to", placeholder: "Into", required: false, options: Self.languages.map(\.name))
    }

    /// The view that translates typed text, else the selection, else the
    /// clipboard.
    func translateCommand(_ id: String, title: String, subtitle: String) -> Command {
        Command(id, title: title, subtitle: subtitle, symbol: "character.bubble", keywords: ["translate", "deepl", "google", "language"])
            .argument("to", placeholder: "Into", required: false, options: Self.languages.map(\.name))
            .view(search: { invocation in
                self.problem = nil
                guard let text = try await self.input(invocation) else {
                    self.result = nil
                    self.problem = "Select some text first (or copy it), or type it here"
                    return
                }
                if self.inPlace {
                    // Typed text is translated once the typing pauses, not
                    // sent to a network engine for every keystroke.
                    if !invocation.text.isEmpty {
                        self.latestTyped = text
                        try? await Task.sleep(for: .milliseconds(350))
                        if self.latestTyped != text || Task.isCancelled { return }
                    }
                    do { try await self.translate(text, to: invocation["to"]) } catch { self.problem = "\(error)" }
                } else {
                    self.result = (text, "", nil, invocation["to"] ?? self.target, "")
                }
            }) { invocation in
                self.view(into: invocation["to"])
            }
    }

    @ViewBuilder func view(into name: String?) -> ViewContent {
        if let problem {
            ContentUnavailableView("Can't translate", symbol: "character.bubble", message: problem)
        } else if let result {
            if inPlace {
                List {
                    Row(result.text, subtitle: "\(result.detected.map { "From \($0) " } ?? "")into \(result.target)", symbol: "character.bubble", key: "translation")
                        .preview(text: result.text, caption: caption(result))
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
                Text("Choose Automatic in Settings to translate here instead.").style(.caption)
            }
        } else {
            ContentUnavailableView(inPlace ? "Translating…" : "Reading the selection…", symbol: "character.bubble")
        }
    }

    // MARK: Panel and settings

    let theme = Theme.teal

    /// Translates what was typed or picked up in the panel: in place with
    /// DeepL, or by opening Google Translate.
    func translateHere(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        problem = nil
        if inPlace {
            do { try await translate(text, to: nil) } catch { problem = "\(error)" }
        } else {
            Stackbar.open(Self.googleURL(text, to: Self.language(target)))
        }
    }

    var panel: ViewContent {
        PanelHeader("Translate", subtitle: useDeepL ? "DeepL" + (formality == "Default" ? "" : " · \(formality.lowercased())") : inPlace ? "On your Mac, or Google Translate" : "Google Translate · opens in your browser",
                    symbol: "character.bubble.fill", theme: theme)
        HStack(spacing: Space.s) {
            Pill("Detect", theme: .neutral)
            Image(systemName: "arrow.right").font(size: 11, weight: .semibold).foreground(.role(.secondary))
            Picker("Into", options: Self.languages.map(\.name), selection: target) { self.target = $0 }
            Spacer()
            IconButton("arrow.left.arrow.right", label: "Swap languages", theme: theme, prominence: .tinted) {
                (self.target, self.second) = (self.second, self.target)
            }
        }
        TextField("Type or paste, then Return") { text in await self.translateHere(text) }
        if useDeepL, problem != nil, result == nil {
            Text("Or switch to Automatic in Settings.").role(.secondary).typography(.caption)
        }
        HStack(spacing: Space.xs + 2) {
            Chip("Translate clipboard", symbol: "doc.on.clipboard", theme: theme) {
                guard let copied = try await Stackbar.clipboard(), !copied.concealed, let text = copied.text else {
                    self.problem = "The clipboard has no text"
                    return
                }
                await self.translateHere(text)
            }
            Chip("Translate selection", symbol: "text.cursor", theme: theme) {
                guard let text = try await Stackbar.context().selectedText, !text.isEmpty else {
                    self.problem = "Nothing is selected in the app you were in"
                    return
                }
                await self.translateHere(text)
            }
            Spacer()
        }
        if let problem {
            Banner(problem)
        } else if let result, inPlace {
            // Two cards: what went in, quiet, and what came out, lit.
            VStack(spacing: Space.xxs) {
                Text((result.detected.map { Self.languageName($0) + " · detected" } ?? "Original").uppercased() + " · BY \(result.by.uppercased())")
                    .role(.secondary).typography(.overline)
                Text(Self.clipped(result.source, 220)).role(.secondary).typography(.body)
            }
            .padding(Space.m)
            .frame(fillWidth: true, alignment: .leading)
            .background(.surface, in: .roundedRectangle(cornerRadius: Radius.large))
            HeroCard(theme: theme, look: .glow, spacing: Space.s) {
                HStack(spacing: Space.xs) {
                    Image(systemName: "sparkles").font(size: 10, weight: .bold).foreground(theme.textPaint).symbolEffect(.bounce)
                    Text(result.target.uppercased()).typography(.overline).foreground(theme.textPaint)
                }
                Text(result.text).typography(Typography(size: 17, weight: .semibold))
                HStack(spacing: Space.s) {
                    ActionButton("Paste", symbol: "doc.on.clipboard.fill", theme: theme, prominent: true) {
                        try await Stackbar.paste(.text(result.text), restoringClipboard: true)
                    }
                    ActionButton("Copy", symbol: "doc.on.doc", theme: theme) { Stackbar.copy(result.text) }
                    Spacer()
                    IconButton("globe", label: "Open in Google Translate", theme: theme) {
                        Stackbar.open(Self.googleURL(result.source, to: Self.language(result.target)))
                    }
                }
            }
        }
    }

    /// The text cut to `limit` characters, with an ellipsis.
    static func clipped(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    /// DeepL's source code ("DE") as a name ("German").
    static func languageName(_ code: String) -> String {
        languages.first { $0.deepl.hasPrefix(code.uppercased()) || same(code, $0) }?.name.replacingOccurrences(of: " (UK)", with: "") ?? code
    }

    var settings: ViewContent {
        Section("Engine") {
            Picker("Translate with", options: ["Automatic", "DeepL", "Browser"], selection: engine, style: .segmented) { choice in
                self.storedEngine = choice
                self.result = nil
                self.problem = nil
            }
            if engine == "Automatic" {
                Text("Translates on your Mac when the language pair is downloaded (System Settings > General > Language & Region > Translation Languages), so nothing leaves it. If the pair isn't downloaded, the text goes to Google Translate instead, with no account or key. If a downloaded pair fails, you see the error and nothing is sent. Texts over 5,000 characters are cut there, and the result says so.").style(.caption)
            } else if useDeepL {
                Text("DeepL needs an API key: the free plan at deepl.com/pro-api covers 500,000 characters a month. Stackbar asks for it the first time and keeps it in your Keychain.").style(.caption)
                Picker("Formality", options: ["Default", "Formal", "Informal"], selection: formality, style: .segmented) { self.formality = $0 }
            } else {
                Text("Opens translate.google.com in your browser with the text filled in.").style(.caption)
            }
        }
        Section("Languages") {
            Picker("When it's already in \(target), into", options: Self.languages.map(\.name), selection: second) { self.second = $0 }
            Text("Pick the main language in the panel.").style(.caption).role(.secondary)
        }
    }
}
