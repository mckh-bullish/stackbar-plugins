import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol
@testable import Plugin_AskAI

/// Nothing here reaches a provider: the requests are built and the answers
/// read from canned replies.
final class AskAITests: XCTestCase {
    private func body(_ request: HTTPRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
    }

    func testAnthropicRequestCarriesTheKeyVersionAndConversation() throws {
        let history = [AskAI.Exchange(question: "2+2?", answer: "4", by: "x")]
        let request = try AskAI.request(.anthropic, model: "claude-opus-5-5", key: "sk-test", messages: AskAI.messages(history, then: "and 3+3?"))
        XCTAssertEqual(request.url, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.headers["x-api-key"], "sk-test")
        XCTAssertEqual(request.headers["anthropic-version"], "2026-10-21")
        XCTAssertEqual(request.headers["anthropic-beta"], "server-side-fallback-2026-07-01")
        let json = try body(request)
        XCTAssertEqual(json["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(json["system"] as? String, AskAI.systemPrompt)
        XCTAssertEqual((json["output_config"] as? [String: String])?["effort"], "low")
        XCTAssertEqual(json["fallbacks"] as? String, "default")
        XCTAssertNil(json["temperature"])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["user", "assistant", "user"])
        XCTAssertEqual(messages.last?["content"], "and 3+3?")
    }

    func testOlderClaudeModelsGetNoEffortOrFallback() throws {
        let request = try AskAI.request(.anthropic, model: "claude-haiku-4-5", key: "k", messages: AskAI.messages([], then: "hi"))
        let json = try body(request)
        XCTAssertNil(json["output_config"])
        XCTAssertNil(json["fallbacks"])
        XCTAssertNil(request.headers["anthropic-beta"])
        let haiku = try body(AskAI.request(.anthropic, model: "claude-haiku-5-5", key: "k", messages: AskAI.messages([], then: "hi")))
        XCTAssertNotNil(haiku["output_config"], "current Haiku takes effort")
        XCTAssertNil(haiku["fallbacks"], "but has no server-side fallback")
    }

    func testOpenAIStyleProvidersPutTheSystemPromptFirst() throws {
        let openai = try AskAI.request(.openai, model: "gpt-5-mini", key: "sk", messages: AskAI.messages([], then: "hi"))
        XCTAssertEqual(openai.headers["Authorization"], "Bearer sk")
        let messages = try XCTUnwrap(body(openai)["messages"] as? [[String: String]])
        XCTAssertEqual(messages.first?["role"], "system")
        XCTAssertEqual(messages.last?["content"], "hi")

        let ollama = try AskAI.request(.ollama, model: "llama3.2", key: nil, messages: AskAI.messages([], then: "hi"))
        XCTAssertEqual(ollama.url, "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(ollama.headers["Authorization"], "a local model needs no key")
    }

    func testReadsAnswersAndExplainsFailures() throws {
        let claude = Data(#"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"Paris"}],"stop_reason":"end_turn"}"#.utf8)
        XCTAssertEqual(try AskAI.answer(.anthropic, status: 200, body: claude), "Paris")
        let refused = Data(#"{"content":[],"stop_reason":"refusal"}"#.utf8)
        XCTAssertThrowsError(try AskAI.answer(.anthropic, status: 200, body: refused))
        let cut = Data(#"{"content":[{"type":"text","text":"Long"}],"stop_reason":"max_tokens"}"#.utf8)
        XCTAssertEqual(try AskAI.answer(.anthropic, status: 200, body: cut), "Long\n\n(cut short)")

        let chat = Data(#"{"choices":[{"message":{"role":"assistant","content":"Berlin"}}]}"#.utf8)
        XCTAssertEqual(try AskAI.answer(.openrouter, status: 200, body: chat), "Berlin")

        let unauthorized = Data(#"{"error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        XCTAssertThrowsError(try AskAI.answer(.anthropic, status: 401, body: unauthorized)) { error in
            XCTAssertTrue("\(error)".contains("ANTHROPIC_API_KEY"))
        }
    }

    func testSelectionCommandsShowTheirInstructionNotTheText() {
        let fix = AskAI.textCommands[0]
        let prompt = AskAI.prompt(fix, text: "teh cat")
        XCTAssertTrue(prompt.hasSuffix("<text>\nteh cat\n</text>"))
        XCTAssertEqual(AskAI.shownQuestion(prompt), fix.instruction)
        XCTAssertEqual(AskAI.shownQuestion("plain question"), "plain question")
    }

    func testReplacingCommandsNeedASelection() async throws {
        let host = Host(self)
        let session = try await host.session("AskAI")
        let result = try await session.runCommand("fix")
        XCTAssertEqual(result, .failure("Select some text first"))
        XCTAssertTrue(host.system.pasted.isEmpty)
        await session.stop()
    }
}
