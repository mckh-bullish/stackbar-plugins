import StackbarKit
import Foundation

/// Ask an AI model from the palette, with your own key: type a question and
/// press Tab (Stackbar 0.36 and later), or pick Ask AI under the results.
/// Follow-up questions keep the conversation. Commands on the selected text
/// summarize or explain it, or fix, improve or shorten it in place.
///
/// Anthropic's Claude is the default provider; OpenAI, OpenRouter and Ollama
/// (local, no key) are one setting away. Keys stay in the Keychain and are
/// asked for only for the provider in use. Answers arrive whole, not word by
/// word.
@main
final class AskAI: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.ask-ai",
        name: "Ask AI",
        version: "1.0.0",
        summary: "Ask Claude, ChatGPT or a local model from the palette, and fix or summarize selected text, with your own key.",
        surfaces: [.panel, .settings],
        triggers: [.launch],
        // The selection for the text commands; the clipboard to paste their
        // result over it; one host per provider (localhost is Ollama); one
        // key per provider.
        capabilities: [.context, .clipboard,
                       .network("api.anthropic.com", "api.openai.com", "openrouter.ai", "localhost"),
                       .secret(name: "ANTHROPIC_API_KEY"), .secret(name: "OPENAI_API_KEY"), .secret(name: "OPENROUTER_API_KEY")],
        minimumStackbar: "0.26.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/AskAI",
        accent: .violet,
        symbol: "sparkles"
    )

    // MARK: Previews

    static let previews: [PreviewScene<AskAI>] = [
        PreviewScene("hero", "Ask from the palette, follow up, copy the answer") { plugin in
            plugin.exchanges = [
                Exchange(question: "How do I undo the last git commit but keep the changes?",
                         answer: "git reset --soft HEAD~1\n\nThe commit is gone and its changes stay staged. Use --mixed instead to keep them unstaged.",
                         by: "Claude Opus 5.5"),
            ]
        },
    ]

    let theme = Theme.violet

    // MARK: Providers

    enum Provider: String, CaseIterable {
        case anthropic = "Anthropic", openai = "OpenAI", openrouter = "OpenRouter", ollama = "Ollama"

        var defaultModel: String {
            switch self {
            case .anthropic: return "claude-opus-5-5"
            case .openai: return "gpt-5-mini"
            case .openrouter: return "openrouter/auto"
            case .ollama: return "llama3.2"
            }
        }

        /// The Keychain secret, or nil for a local model.
        var secret: String? {
            switch self {
            case .anthropic: return "ANTHROPIC_API_KEY"
            case .openai: return "OPENAI_API_KEY"
            case .openrouter: return "OPENROUTER_API_KEY"
            case .ollama: return nil
            }
        }

        /// Where OpenAI-style chat completions go.
        var chatURL: String {
            switch self {
            case .anthropic: return "https://api.anthropic.com/v1/messages"
            case .openai: return "https://api.openai.com/v1/chat/completions"
            case .openrouter: return "https://openrouter.ai/api/v1/chat/completions"
            case .ollama: return "http://localhost:11434/v1/chat/completions"
            }
        }

        var keyPage: String? {
            switch self {
            case .anthropic: return "https://platform.claude.com/settings/keys"
            case .openai: return "https://platform.openai.com/api-keys"
            case .openrouter: return "https://openrouter.ai/settings/keys"
            case .ollama: return nil
            }
        }
    }

    @Stored("provider") var storedProvider = Provider.anthropic.rawValue
    /// A model per provider, when changed from its default.
    @Stored("models") var models: [String: String] = [:]

    var provider: Provider { Provider(rawValue: storedProvider) ?? .anthropic }
    var model: String {
        let chosen = models[provider.rawValue]?.trimmingCharacters(in: .whitespaces) ?? ""
        return chosen.isEmpty ? provider.defaultModel : chosen
    }

    // MARK: Conversation

    struct Exchange: Equatable {
        var question: String
        var answer: String
        var by: String
    }

    /// The conversation shown in the palette, oldest first.
    var exchanges: [Exchange] = []
    /// The prompt (or selection command) the conversation started from, so
    /// the view asks once and not on every keystroke.
    var started: String?
    var problem: String?

    nonisolated static let systemPrompt = "You answer inside a Mac launcher. Be brief and direct, and start with the answer. Use plain text (no Markdown headings or tables); short lists and code are fine."

    /// One message as the APIs take it.
    struct Message: Equatable {
        var role: String
        var content: String
    }

    nonisolated static func messages(_ history: [Exchange], then question: String) -> [Message] {
        history.flatMap { [Message(role: "user", content: $0.question), Message(role: "assistant", content: $0.answer)] }
            + [Message(role: "user", content: question)]
    }

    /// Claude models that take `output_config.effort` and the server-side
    /// fallback on a refusal.
    nonisolated static func isCurrentClaude(_ model: String) -> Bool {
        ["claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable-5"].contains { model.hasPrefix($0) }
    }

    /// The HTTP request for a provider.
    nonisolated static func request(_ provider: Provider, model: String, key: String?, messages: [Message], system: String = systemPrompt) throws -> HTTPRequest {
        let turns = messages.map { ["role": $0.role, "content": $0.content] }
        var headers = ["Content-Type": "application/json"]
        var body: [String: Any]
        switch provider {
        case .anthropic:
            headers["x-api-key"] = key ?? ""
            headers["anthropic-version"] = "2026-10-21"
            body = ["model": model, "max_tokens": 16_000, "system": system, "messages": turns]
            if isCurrentClaude(model) {
                // Quick answers: low effort keeps them fast.
                body["output_config"] = ["effort": "low"]
            }
            if ["claude-opus-5", "claude-sonnet-5-5", "claude-fable-5"].contains(where: { model.hasPrefix($0) }) {
                // A refused answer is retried on a model that can give it.
                headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
                body["fallbacks"] = "default"
            }
        case .openai, .openrouter, .ollama:
            if let key { headers["Authorization"] = "Bearer \(key)" }
            body = ["model": model, "messages": [["role": "system", "content": system]] + turns]
        }
        return HTTPRequest(url: provider.chatURL, method: "POST", headers: headers,
                           body: try JSONSerialization.data(withJSONObject: body), timeout: 120)
    }

    /// The answer's text, or why there is none.
    nonisolated static func answer(_ provider: Provider, status: Int, body: Data) throws -> String {
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        guard (200..<300).contains(status) else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? (json?["error"] as? String)
            switch status {
            case 401, 403: throw HostError("\(provider.rawValue) refused the key (\(status)). Check \(provider.secret ?? "the key") in Stackbar's Settings")
            case 404 where provider == .ollama: throw HostError(message ?? "Ollama doesn't have that model; run ollama pull, or pick another in Settings")
            case 429: throw HostError("\(provider.rawValue) is busy or out of credit (429). \(message ?? "Try again in a moment")")
            default: throw HostError("\(provider.rawValue) answered \(status)" + (message.map { ": \($0)" } ?? ""))
            }
        }
        switch provider {
        case .anthropic:
            if json?["stop_reason"] as? String == "refusal" {
                throw HostError("Claude declined to answer that")
            }
            let blocks = json?["content"] as? [[String: Any]] ?? []
            let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw HostError("Claude sent no answer") }
            return json?["stop_reason"] as? String == "max_tokens" ? text + "\n\n(cut short)" : text
        case .openai, .openrouter, .ollama:
            let choices = json?["choices"] as? [[String: Any]] ?? []
            guard let text = (choices.first?["message"] as? [String: Any])?["content"] as? String, !text.isEmpty else {
                throw HostError("\(provider.rawValue) sent no answer")
            }
            return text
        }
    }

    /// Asks the provider in use, with the conversation so far.
    func ask(_ question: String, history: [Exchange], system: String = systemPrompt) async throws -> String {
        var key: String?
        if let secret = provider.secret {
            key = try await Stackbar.secret(secret)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key, !key.isEmpty else {
                throw HostError("Add your \(provider.rawValue) API key (\(secret)) in Stackbar's Settings, or switch to Ollama for a local model")
            }
        }
        let request = try Self.request(provider, model: model, key: key, messages: Self.messages(history, then: question), system: system)
        let response = try await Stackbar.http(request)
        return try Self.answer(provider, status: response.status, body: response.body)
    }

    /// Who answered, for the caption.
    var by: String { provider == .anthropic ? model : "\(provider.rawValue) · \(model)" }

    /// Starts a conversation, once per prompt.
    func start(_ question: String, key: String, system: String = systemPrompt) async {
        guard started != key else { return }
        started = key
        exchanges = []
        await follow(question, system: system)
    }

    /// Asks within the conversation.
    func follow(_ question: String, system: String = systemPrompt) async {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        problem = nil
        do {
            let answer = try await ask(question, history: exchanges, system: system)
            exchanges.append(Exchange(question: question, answer: answer, by: by))
        } catch {
            problem = "\(error)"
        }
    }

    // MARK: Selected text

    struct TextCommand {
        var id: String
        var title: String
        var symbol: String
        var instruction: String
        /// Replaces the selection, rather than showing an answer.
        var replaces: Bool
    }

    nonisolated static let textCommands: [TextCommand] = [
        TextCommand(id: "fix", title: "Fix Spelling and Grammar", symbol: "textformat.abc",
                    instruction: "Fix the spelling and grammar of the text. Keep its meaning, tone, language and formatting. Reply with the corrected text only.", replaces: true),
        TextCommand(id: "improve", title: "Improve Writing", symbol: "wand.and.stars",
                    instruction: "Rewrite the text to read more clearly, in the same language and tone. Reply with the rewritten text only.", replaces: true),
        TextCommand(id: "shorter", title: "Make Shorter", symbol: "arrow.down.right.and.arrow.up.left",
                    instruction: "Make the text shorter without losing what it says, in the same language and tone. Reply with the shorter text only.", replaces: true),
        TextCommand(id: "summarize", title: "Summarize Selection", symbol: "text.append",
                    instruction: "Summarize the text in a few short points.", replaces: false),
        TextCommand(id: "explain", title: "Explain Selection", symbol: "questionmark.bubble",
                    instruction: "Explain the text simply: what it means and anything a reader might not know.", replaces: false),
    ]

    nonisolated static func prompt(_ command: TextCommand, text: String) -> String {
        "\(command.instruction)\n\n<text>\n\(text)\n</text>"
    }

    static func selection(_ invocation: CommandInvocation) -> String? {
        guard let text = invocation.context?.selectedText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    // MARK: Commands

    var commands: [Command] {
        Command("ask", title: "Ask AI", subtitle: "A question, with follow-ups", symbol: "sparkles", keywords: ["ai", "chat", "claude", "gpt", "llm", "question"])
            .argument("prompt", placeholder: "Ask anything")
            .view(search: { invocation in
                guard let prompt = invocation["prompt"] else { return }
                await self.start(prompt, key: "ask:" + prompt)
            }) { invocation in
                self.conversation(typed: invocation.text)
            }
            .fallback()
        for command in Self.textCommands {
            if command.replaces {
                Command(command.id, title: command.title, subtitle: "Replaces the selected text", symbol: command.symbol, keywords: ["ai", "selection", "rewrite"]) { invocation in
                    guard let text = Self.selection(invocation) else { return .failure("Select some text first") }
                    let result = try await self.ask(Self.prompt(command, text: text), history: [],
                                                    system: "You edit text. Reply with the edited text only, with no introduction, quotes or notes.")
                    return .paste(result, cursorFromEnd: 0)
                }
            } else {
                Command(command.id, title: command.title, subtitle: "The selected text", symbol: command.symbol, keywords: ["ai", "selection"])
                    .view(search: { invocation in
                        guard let text = Self.selection(invocation) else {
                            self.exchanges = []
                            self.started = nil
                            self.problem = "Select some text first, then run \(command.title)"
                            return
                        }
                        await self.start(Self.prompt(command, text: text), key: command.id + ":" + text)
                    }) { invocation in
                        self.conversation(typed: invocation.text)
                    }
            }
        }
    }

    /// The answers, newest first, with a follow-up row for typed text.
    @ViewBuilder func conversation(typed: String) -> ViewContent {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if exchanges.isEmpty, let problem {
            ContentUnavailableView("No answer", symbol: "sparkles", message: problem)
        } else if exchanges.isEmpty {
            ContentUnavailableView("Thinking…", symbol: "sparkles")
        } else {
            List {
                if !typed.isEmpty {
                    Row("Ask “\(typed)”", subtitle: "A follow-up, with this conversation", symbol: "arrow.up.message", key: "follow-up")
                        .action("Ask") { await self.follow(typed) }
                }
                if let problem {
                    Row(problem, subtitle: "The last question got no answer", symbol: "exclamationmark.triangle", key: "problem")
                }
                for (index, exchange) in exchanges.enumerated().reversed() {
                    Row(Self.gist(exchange.answer), subtitle: Self.gist(Self.shownQuestion(exchange.question)), symbol: "sparkles", key: "answer-\(index)")
                        .preview(text: exchange.answer, caption: exchange.by)
                        .action("Copy Answer") { Stackbar.copy(exchange.answer) }
                        .action("Paste Answer", shortcut: "cmd+p") {
                            try await Stackbar.paste(.text(exchange.answer), restoringClipboard: true)
                        }
                }
            }
        }
    }

    /// A selection command's question shows as its instruction, not the text.
    nonisolated static func shownQuestion(_ question: String) -> String {
        guard let cut = question.range(of: "\n\n<text>") else { return question }
        return String(question[..<cut.lowerBound])
    }

    nonisolated static func gist(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > 140 ? String(flat.prefix(140)) + "…" : flat
    }

    // MARK: Panel and settings

    var panel: ViewContent {
        PanelHeader("Ask AI", subtitle: by, symbol: "sparkles", theme: theme)
        TextField("Ask anything, then Return") { text in
            await self.start(text, key: "panel:\(text):\(Date().timeIntervalSince1970)")
        }
        if let problem {
            Banner(problem)
        }
        if let last = exchanges.last {
            Text(Self.shownQuestion(last.question)).style(.caption).role(.secondary)
            Text(last.answer).style(.body)
            HStack(spacing: Space.s) {
                ActionButton("Copy", symbol: "doc.on.doc", theme: theme, prominent: true) { Stackbar.copy(last.answer) }
                ActionButton("New Question", symbol: "plus", theme: theme) {
                    self.exchanges = []
                    self.started = nil
                    self.problem = nil
                }
                Spacer()
            }
        } else if problem == nil {
            Text("Or type a question in the palette and press Tab.").style(.caption).role(.secondary)
        }
    }

    var settings: ViewContent {
        Section("Provider") {
            Picker("Ask", options: Provider.allCases.map(\.rawValue), selection: provider.rawValue, style: .segmented) { choice in
                self.storedProvider = choice
                self.started = nil
                self.problem = nil
            }
            TextField(provider.defaultModel, text: models[provider.rawValue] ?? "", key: "model-\(provider.rawValue)") { value in
                self.models[self.provider.rawValue] = value.trimmingCharacters(in: .whitespaces)
            }
            Text(caption).style(.caption)
        }
    }

    var caption: String {
        switch provider {
        case .anthropic:
            return "Uses Claude Opus 5.5 at low effort unless you name another model, such as claude-haiku-5-5 for cheaper answers. Needs ANTHROPIC_API_KEY from platform.claude.com; Stackbar asks for it the first time and keeps it in your Keychain."
        case .openai:
            return "Needs OPENAI_API_KEY from platform.openai.com. The model is any chat model your key can use."
        case .openrouter:
            return "Needs OPENROUTER_API_KEY. openrouter/auto picks a model per question; name one (anthropic/…, openai/…) to fix it."
        case .ollama:
            return "Runs on your Mac with Ollama (ollama.com), no key and nothing sent anywhere. Pull the model first: ollama pull llama3.2."
        }
    }
}
