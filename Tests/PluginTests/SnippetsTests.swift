import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class SnippetsTests: XCTestCase {
    private static let raycastExport = """
    [
      {"name": "Signature", "text": "-- \\n{argument name=\\"who\\" default=\\"Nav\\"}", "keyword": ";sig"},
      {"name": "Reply", "text": "Hi {argument name=\\"name\\"},\\n\\n{cursor}\\n\\n{snippet name=\\"Signature\\"}", "keyword": ";re"},
      {"name": "Today", "text": "{date: yyyy-MM-dd} at {time: HH:mm}"},
      {"name": "Signature", "text": "-- \\n{argument name=\\"who\\" default=\\"Nav\\"}"},
      {"name": "Spaced", "text": "x", "keyword": "has space"},
      {"name": "Too many", "text": "{argument name=a}{argument name=b}{argument name=c}{argument name=d}"}
    ]
    """

    private func host() -> Host {
        let host = Host(self)
        host.system.restoreDelay = .milliseconds(20)
        return host
    }

    private func importSample(_ host: Host, _ session: PluginSession) async throws {
        host.system.simulate(chosenFile: ChosenFile(name: "snippets.json", data: Data(Self.raycastExport.utf8)))
        let result = try await session.runCommand("import")
        guard case .message = result else { return XCTFail("\(result)") }
    }

    private func snippets(_ session: PluginSession) async -> [CommandSpec] {
        await session.commands().filter { $0.id.hasPrefix("sn-") }
    }

    private func command(_ session: PluginSession, titled title: String) async throws -> CommandSpec {
        let found = await snippets(session).first { $0.title == title }
        return try XCTUnwrap(found, "no command \(title)")
    }

    func testImportingARaycastExport() async throws {
        let host = host()
        let session = try await host.session("Snippets")
        try await importSample(host, session)
        let titles = await snippets(session).map(\.title)
        XCTAssertEqual(titles.sorted(), ["Reply", "Signature", "Spaced", "Today"], "a duplicate and one with four arguments are skipped")
        let spaced = try await command(session, titled: "Spaced")
        XCTAssertFalse(spaced.keywords.contains("has space"), "a keyword with a space is left out")
        try await importSample(host, session)
        let again = await snippets(session)
        XCTAssertEqual(again.count, 4, "importing again skips them all")

        let today = try await command(session, titled: "Today")
        XCTAssertEqual(today.subtitle, #"{date format="yyyy-MM-dd"} at {time format="HH:mm"}"#, "the old shorthand is modernised")
        await session.stop()
    }

    func testEachSnippetPastesWithItsArgumentsAndCursor() async throws {
        let host = host()
        let session = try await host.session("Snippets")
        try await importSample(host, session)
        let reply = try await command(session, titled: "Reply")
        XCTAssertEqual(reply.arguments.map(\.name), ["name", "who"], "an included snippet's arguments are asked for too")
        XCTAssertEqual(reply.arguments.map(\.required), [true, false])
        XCTAssertTrue(reply.keywords.contains(";re"))

        let result = try await session.runCommand(reply.id, arguments: ["name": "Zoë"])
        let tail = "\n\n-- \nNav"
        XCTAssertEqual(result, .paste("Hi Zoë,\n\n" + tail, cursorFromEnd: tail.count))

        // Grapheme clusters, not UTF-16: one ← per character the user sees.
        let reply2 = try await session.runCommand(reply.id, arguments: ["name": "A", "who": "🇸🇬 e\u{301}"])
        guard case .paste(let text, let cursor) = reply2 else { return XCTFail("\(reply2)") }
        XCTAssertTrue(text.hasSuffix("🇸🇬 e\u{301}"))
        XCTAssertEqual(cursor, 9)

        let missing = try await session.runCommand(reply.id)
        guard case .failure = missing else { return XCTFail("a required argument left out fails: \(missing)") }
        await session.stop()
    }

    func testPlaceholdersFillFromTheClipboard() async throws {
        let host = host()
        let session = try await host.session("Snippets")
        host.system.simulate(chosenFile: ChosenFile(name: "s.json", data: Data(#"[{"name": "Hello", "text": "Hello {clipboard | uppercase}{cursor}!"}]"#.utf8)))
        _ = try await session.runCommand("import")
        let hello = try await command(session, titled: "Hello")
        host.system.simulateCopy("world")
        let result = try await session.runCommand(hello.id)
        XCTAssertEqual(result, .paste("Hello WORLD!", cursorFromEnd: 1))
        await session.stop()
    }

    func testTheFormValidates() async throws {
        let host = host()
        let session = try await host.session("Snippets")
        try await importSample(host, session)
        let opened = try await session.openView("create")
        let submit = ActionID("view/\(opened.session)/form/new")
        func errors(_ fields: [String: String]) async throws -> [String: String] {
            try await session.event(submit, value: .fields(fields.mapValues { .text($0) }))
            return await session.commandView(opened.session)?.form?.errors ?? [:]
        }
        let empty = try await errors(["name": "", "text": "{cursor} and {cursor}", "keyword": "a b"])
        XCTAssertEqual(Set(empty.keys), ["name", "text", "keyword"], "no name, two cursors, a space in the keyword")
        for (text, why) in [(#"{snippet name="Loop"}"#, "can't include itself"), (#"{snippet name="Reply"}"#, "one level deep"), ("{clipbaord}", "a typo")] {
            let found = try await errors(["name": "Loop", "text": text])
            XCTAssertEqual(Set(found.keys), ["text"], why)
        }
        let typo = try await errors(["name": "Typo", "text": "{clipbaord}"])
        XCTAssertTrue(typo["text"]?.contains("{clipbaord}") == true, "the typo is named: \(typo)")
        let taken = try await errors(["name": "Taken", "text": "x", "keyword": ";sig"])
        XCTAssertEqual(Set(taken.keys), ["keyword"], "a keyword already taken")

        let none = try await errors(["name": "Thanks", "text": "Thanks!\n{snippet name=\"Signature\"}", "keyword": ";ty", "tags": "email"])
        XCTAssertEqual(none, [:])
        let created = try await command(session, titled: "Thanks")
        XCTAssertTrue(created.keywords.contains("email"))
        let ran = try await session.runCommand(created.id)
        XCTAssertEqual(ran, .paste("Thanks!\n-- \nNav", cursorFromEnd: 0))
        await session.stop()
    }

    func testSearchRowsPreviewPasteAndExportRoundTrips() async throws {
        let host = host()
        let session = try await host.session("Snippets")
        try await importSample(host, session)
        let opened = try await session.openView("search")
        let rows = try XCTUnwrap(opened.root).rows
        let reply = try XCTUnwrap(rows.first { $0.title == "Reply" })
        XCTAssertTrue(reply.preview?.text?.hasSuffix("-- \nNav") == true, "the preview expands what it includes: \(reply.preview?.text ?? "none")")
        let replyCommand = try await command(session, titled: "Reply")
        XCTAssertEqual(reply.actions.first?.navigate, CommandTarget(command: replyCommand.id), "a snippet that needs input opens its own command")

        let signature = try XCTUnwrap(rows.first { $0.title == "Signature" })
        try await session.event(try XCTUnwrap(signature.actions.first).id)
        XCTAssertEqual(host.system.pastes.last?.content, .text("-- \nNav"))
        XCTAssertEqual(host.system.pastes.last?.options.restoreClipboard, true, "the user's clipboard comes back")

        _ = try await session.runCommand("export")
        let saved = try XCTUnwrap(host.system.saved.last)
        let items = try JSONDecoder().decode([[String: String]].self, from: saved.data)
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items.first { $0["name"] == "Signature" }?["keyword"], ";sig")
        XCTAssertNil(items.first { $0["name"] == "Spaced" }?["keyword"])
        await session.stop()
    }

    func testImportingTextExpanderEspansoAndTextReplacements() async throws {
        let host = host()
        let session = try await host.session("Snippets")

        let csv = "abbreviation,content,label\n;addr,\"1 Main St\nSpringfield\",Address\n;dt,Today is %Y-%m-%d,\n;hi,\"Hi %filltext:name=who%, \"\"thanks\"\"%|\",\n"
        host.system.simulate(chosenFile: ChosenFile(name: "Group.csv", data: Data(csv.utf8)))
        guard case .message = try await session.runCommand("import") else { return XCTFail("csv") }

        let espanso = """
        # base.yml
        matches:
          - trigger: ":sig"
            replace: "Best,\\nSam"
          - triggers: [":ty", ":thx"]
            replace: Thank you!
          - trigger: ":block"
            label: Standup
            replace: |
              Yesterday:
                - shipped
              Today: $|$
          - trigger: ":clip"
            replace: "Pasted: {{clipboard}}"
        """
        host.system.simulate(chosenFile: ChosenFile(name: "base.yml", data: Data(espanso.utf8)))
        guard case .message = try await session.runCommand("import") else { return XCTFail("espanso") }

        let replacements: [[String: String]] = [["phrase": "On my way!", "shortcut": "omw"], ["phrase": "", "shortcut": "x"]]
        let plist = try PropertyListSerialization.data(fromPropertyList: replacements, format: .xml, options: 0)
        host.system.simulate(chosenFile: ChosenFile(name: "Text Substitutions.plist", data: plist))
        guard case .message = try await session.runCommand("import") else { return XCTFail("plist") }

        let byTitle = Dictionary(await snippets(session).map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(Set(byTitle.keys), ["Address", ";dt", ";hi", ":sig", ":ty", ":thx", "Standup", ":clip", "omw: On my way!"])
        XCTAssertTrue(byTitle["Address"]?.keywords.contains(";addr") == true)
        XCTAssertEqual(byTitle[":thx"]?.keywords.contains(":thx"), true, "each Espanso trigger becomes its own snippet")

        let date = try await session.runCommand(XCTUnwrap(byTitle[";dt"]).id)
        let today = { () -> String in let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }()
        XCTAssertEqual(date, .paste("Today is \(today)", cursorFromEnd: 0))
        let hi = try await session.runCommand(XCTUnwrap(byTitle[";hi"]).id, arguments: ["who": "Ana"])
        XCTAssertEqual(hi, .paste("Hi Ana, \"thanks\"", cursorFromEnd: 0), "a fill-in becomes an argument and %| the cursor")
        let sig = try await session.runCommand(XCTUnwrap(byTitle[":sig"]).id)
        XCTAssertEqual(sig, .paste("Best,\nSam", cursorFromEnd: 0))
        let block = try await session.runCommand(XCTUnwrap(byTitle["Standup"]).id)
        XCTAssertEqual(block, .paste("Yesterday:\n  - shipped\nToday: \n", cursorFromEnd: 1))
        let omw = try await session.runCommand(XCTUnwrap(byTitle["omw: On my way!"]).id)
        XCTAssertEqual(omw, .paste("On my way!", cursorFromEnd: 0))
        await session.stop()
    }

    func testImportingManySnippetsKeepsEachOneAndItsKeyword() async throws {
        let host = host()
        let session = try await host.session("Snippets")
        let items = (0..<300).map { #"{"name": "Snippet \#($0)", "text": "Body \#($0)\#($0 == 0 ? "" : " {snippet name=\\\"Snippet 0\\\"}")", "keyword": ";k\#($0)x"}"# }
        host.system.simulate(chosenFile: ChosenFile(name: "many.json", data: Data(("[" + items.joined(separator: ",") + "]").utf8)))
        guard case .message(let summary?) = try await session.runCommand("import") else { return XCTFail("import") }
        XCTAssertTrue(summary.hasPrefix("Imported 300"), summary)
        let all = await snippets(session)
        XCTAssertEqual(all.count, 300)
        let last = try await command(session, titled: "Snippet 299")
        XCTAssertTrue(last.keywords.contains(";k299x"))
        let result = try await session.runCommand(last.id)
        XCTAssertEqual(result, .paste("Body 299 Body 0", cursorFromEnd: 0), "one level of inclusion")
        await session.stop()
    }

    func testAKeywordThatStartsAnotherIsRefused() async throws {
        let host = host()
        let session = try await host.session("Snippets")
        try await importSample(host, session)
        let opened = try await session.openView("create")
        let submit = ActionID("view/\(opened.session)/form/new")
        func errors(_ fields: [String: String]) async throws -> [String: String] {
            try await session.event(submit, value: .fields(fields.mapValues { .text($0) }))
            return await session.commandView(opened.session)?.form?.errors ?? [:]
        }
        let longer = try await errors(["name": "Sign", "text": "x", "keyword": ";sign"])
        XCTAssertEqual(Set(longer.keys), ["keyword"], "typing ;sign would expand ;sig first")
        let shorter = try await errors(["name": "S", "text": "x", "keyword": ";s"])
        XCTAssertEqual(Set(shorter.keys), ["keyword"], ";s would expand before ;sig is typed")
        let unrelated = try await errors(["name": "Other", "text": "x", "keyword": ";other"])
        XCTAssertEqual(unrelated, [:])
        await session.stop()
    }

    func testAnImportLeavesOutAKeywordThatWouldClash() async throws {
        let host = host()
        let session = try await host.session("Snippets")
        try await importSample(host, session)
        host.system.simulate(chosenFile: ChosenFile(name: "more.json", data: Data(#"[{"name": "Sign off", "text": "Best", "keyword": ";sign"}]"#.utf8)))
        guard case .message(let summary?) = try await session.runCommand("import") else { return XCTFail("import") }
        XCTAssertTrue(summary.contains(";sign"), "the keyword is named as left out: \(summary)")
        let imported = try await command(session, titled: "Sign off")
        XCTAssertFalse(imported.keywords.contains(";sign"), "the snippet is kept without it")
        await session.stop()
    }

    func testCreateStartsFromTheSelection() async throws {
        let host = host()
        let session = try await host.session("Snippets")
        let opened = try await session.openView("create", context: InvocationContext(selectedText: "Kind regards,\nSam"))
        let form = await session.commandView(opened.session)?.form ?? opened.root?.form
        let text = form?.fields.first { $0.name == "text" }
        XCTAssertEqual(text?.value, .text("Kind regards,\nSam"), "the snippet starts with what was selected")
        await session.stop()
    }

    func testSettingsPointsOutKeywordsThatAlreadyClash() async throws {
        let host = host()
        let id = "io.navbytes.stackbar.snippets"
        let saved = #"[{"id":"5A1B0000-0000-4000-8000-000000000001","name":"Sig","text":"x","keyword":";sig","tags":[]},{"id":"5A1B0000-0000-4000-8000-000000000002","name":"Sign","text":"y","keyword":";sign","tags":[]}]"#
        try await host.services.storage.set("snippets", saved, for: id)
        let supervisor = try await host.start("Snippets")
        let settings = await supervisor.views[.settings]?.plainText ?? ""
        XCTAssertTrue(settings.contains(";sig expands before ;sign can be typed in full"), settings)
        await supervisor.stop()
    }

    func testSavingAnEditThatKeepsAClashingKeywordStillWorks() async throws {
        let host = host()
        let id = "io.navbytes.stackbar.snippets"
        let sign = "5A1B0000-0000-4000-8000-000000000002"
        let saved = #"[{"id":"5A1B0000-0000-4000-8000-000000000001","name":"Sig","text":"x","keyword":";sig","tags":[]},{"id":"\#(sign)","name":"Sign","text":"y","keyword":";sign","tags":[]}]"#
        try await host.services.storage.set("snippets", saved, for: id)
        let session = try await host.session("Snippets")
        let opened = try await session.openView("create", query: CommandQuery(arguments: ["id": sign]))
        try await session.event(ActionID("view/\(opened.session)/form/\(sign)"), value: .fields([
            "name": .text("Sign"), "text": .text("Changed"), "keyword": .text(";sign"), "tags": .text(""),
        ]))
        let errors = await session.commandView(opened.session)?.form?.errors ?? [:]
        XCTAssertEqual(errors, [:], "a clash that was already there doesn't block an edit that keeps the keyword")
        let edited = try await command(session, titled: "Sign")
        let result = try await session.runCommand(edited.id)
        XCTAssertEqual(result, .paste("Changed", cursorFromEnd: 0), "the new text is saved")
        await session.stop()
    }
}
