import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class QuicklinksTests: XCTestCase {
    private static let raycastExport = """
    [
      {"name": "GitHub Search", "link": "https://github.com/search?q={argument name=\\"query\\"}&type={argument name=\\"type\\" default=\\"code\\"}", "openWith": "Google Chrome"},
      {"name": "Temp", "link": "/tmp"},
      {"name": "Translate", "link": "translate.google.com/?text={selection}"},
      {"name": "Temp", "link": "/tmp"},
      {"name": "Too many", "link": "{argument name=a}{argument name=b}{argument name=c}{argument name=d}"},
      {"name": "Notes", "link": "https://notes.example.com/{date format=\\"yyyy-MM-dd\\"}", "openWith": "Nonexistent Browser"}
    ]
    """

    private func importSample(_ host: Host, _ session: PluginSession) async throws -> CommandResult {
        host.system.simulate(chosenFile: ChosenFile(name: "quicklinks.json", data: Data(Self.raycastExport.utf8)))
        return try await session.runCommand("import")
    }

    private func quicklinks(_ session: PluginSession) async -> [CommandSpec] {
        await session.commands().filter { $0.id.hasPrefix("ql-") }
    }

    private func command(_ session: PluginSession, titled title: String) async throws -> CommandSpec {
        let found = await quicklinks(session).first { $0.title == title }
        return try XCTUnwrap(found, "no command \(title)")
    }

    func testImportingARaycastExport() async throws {
        let host = Host(self)
        let session = try await host.session("Quicklinks")
        let result = try await importSample(host, session)
        let titles = await quicklinks(session).map(\.title)
        XCTAssertEqual(titles.sorted(), ["GitHub Search", "Notes", "Temp", "Translate"], "a duplicate and one with four arguments are skipped")
        // Only the summary says an app wasn't found; Notes opens in the default browser.
        guard case .message(let message?) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(message.contains("Nonexistent Browser"), message)
        let notes = try await command(session, titled: "Notes")
        guard case .open(_, nil) = try await session.runCommand(notes.id) else { return XCTFail("an app that isn't installed is dropped") }

        // Importing again skips them all.
        _ = try await importSample(host, session)
        let again = await quicklinks(session)
        XCTAssertEqual(again.count, 4)
        await session.stop()
    }

    func testEachQuicklinkIsACommandWithItsArguments() async throws {
        let host = Host(self)
        let session = try await host.session("Quicklinks")
        _ = try await importSample(host, session)
        let search = try await command(session, titled: "GitHub Search")
        XCTAssertEqual(search.arguments.map(\.name), ["query", "type"])
        XCTAssertEqual(search.arguments.map(\.required), [true, false])
        XCTAssertTrue(search.keywords.contains("github.com"))

        let result = try await session.runCommand(search.id, arguments: ["query": "swift actors"])
        XCTAssertEqual(result, .open(url: "https://github.com/search?q=swift%20actors&type=code", app: "com.google.Chrome"))

        let missing = try await session.runCommand(search.id)
        guard case .failure = missing else { return XCTFail("a required argument left out fails: \(missing)") }

        let temp = try await command(session, titled: "Temp")
        let tempResult = try await session.runCommand(temp.id)
        XCTAssertEqual(tempResult, .open(url: "/tmp", app: nil))

        let translate = try await command(session, titled: "Translate")
        let context = InvocationContext(frontmostApp: .init(bundleID: "com.apple.Safari", name: "Safari"), selectedText: "bonjour à tous")
        let translated = try await session.runCommand(translate.id, context: context)
        XCTAssertEqual(translated, .open(url: "https://translate.google.com/?text=bonjour%20%C3%A0%20tous", app: nil))
        await session.stop()
    }

    func testCreatingAndEditingWithTheForm() async throws {
        let session = try await Host(self).session("Quicklinks")
        let opened = try await session.openView("create")
        let submit = ActionID("view/\(opened.session)/form/new")
        // Invalid: no name, and a placeholder typo.
        try await session.event(submit, value: .fields(["name": .text(""), "link": .text("https://x.com/{clipbaord}")]))
        let errors = await session.commandView(opened.session)?.form?.errors ?? [:]
        XCTAssertEqual(Set(errors.keys), ["name", "link"])
        XCTAssertTrue(errors["link"]?.contains("{clipbaord}") == true, "the typo is named: \(errors)")
        let none = await quicklinks(session)
        XCTAssertTrue(none.isEmpty)

        try await session.event(submit, value: .fields(["name": .text("Search Docs"), "link": .text("docs.example.com/?q={argument}"), "tags": .text("work, docs"), "app": .text("")]))
        let created = try await command(session, titled: "Search Docs")
        XCTAssertEqual(created.arguments.map(\.name), ["argument"])
        XCTAssertTrue(created.keywords.contains("work"))
        let ran = try await session.runCommand(created.id, arguments: ["argument": "a+b"])
        XCTAssertEqual(ran, .open(url: "https://docs.example.com/?q=a%2Bb", app: nil))
        await session.closeView(opened.session)

        // Editing keeps the id, so aliases and hotkeys still point at it.
        let uuid = String(created.id.dropFirst(3)).uppercased()
        let edit = try await session.openView("create", query: CommandQuery(arguments: ["id": uuid]))
        try await session.event(ActionID("view/\(edit.session)/form/\(uuid)"), value: .fields(["name": .text("Docs Search"), "link": .text("https://docs.example.com/?q={argument}"), "tags": .text(""), "app": .text("com.apple.Safari")]))
        let edited = try await command(session, titled: "Docs Search")
        XCTAssertEqual(edited.id, created.id)
        let ranEdited = try await session.runCommand(edited.id, arguments: ["argument": "x"])
        XCTAssertEqual(ranEdited, .open(url: "https://docs.example.com/?q=x", app: "com.apple.Safari"))
        await session.stop()
    }

    func testExportRoundTrips() async throws {
        let host = Host(self)
        let session = try await host.session("Quicklinks")
        _ = try await importSample(host, session)
        _ = try await session.runCommand("export")
        let saved = try XCTUnwrap(host.system.saved.last)
        let items = try JSONDecoder().decode([[String: String]].self, from: saved.data)
        XCTAssertEqual(Set(items.compactMap { $0["name"] }), ["GitHub Search", "Temp", "Translate", "Notes"])
        XCTAssertEqual(items.first { $0["name"] == "GitHub Search" }?["openWith"], "com.google.Chrome")
        await session.stop()
    }

    func testSearchListsRowsThatOpenEditAndCopy() async throws {
        let host = Host(self)
        let session = try await host.session("Quicklinks")
        _ = try await importSample(host, session)
        let opened = try await session.openView("search")
        let rows = try XCTUnwrap(opened.root).rows
        let search = try XCTUnwrap(rows.first { $0.title == "GitHub Search" })
        let command = try await self.command(session, titled: "GitHub Search")
        let targets = search.actions.compactMap(\.navigate)
        XCTAssertTrue(targets.contains(CommandTarget(command: command.id)), "a quicklink with arguments opens its own command: \(targets)")
        XCTAssertTrue(targets.contains { $0.command == "create" && $0.arguments["id"] != nil }, "and can be edited: \(targets)")

        let temp = try XCTUnwrap(rows.first { $0.title == "Temp" })
        for action in temp.actions where action.navigate == nil && action.role != .critical {
            try await session.event(action.id)
        }
        XCTAssertTrue(host.copies.all.contains("/tmp"), "a row copies its link: \(host.copies.all)")
        // Foundation adds a trailing slash for a directory, which /tmp is on
        // Linux; on macOS it is a symlink to /private/tmp and gets none.
        XCTAssertTrue(host.opened.all.contains { ["file:///tmp", "file:///tmp/"].contains($0.url) }, "and opens it: \(host.opened.all)")
        await session.stop()
    }

    func testAFirstRunOffersEverydayLinksAndRanksByUse() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Quicklinks")
        let offer = await supervisor.views[.panel]?.tree.lazy.compactMap { node -> ActionID? in
            if case .tappable(_, let action) = node, action.rawValue.hasPrefix("button/Add ") { return action }
            return nil
        }.first
        await supervisor.press(try XCTUnwrap(offer, "the empty panel offers a starter set"))
        let added = await waitUntil(10) { await supervisor.views[.panel]?.rows.count == 8 }
        XCTAssertTrue(added, "the starter set is added")

        // Opening one moves it to the top of the list.
        let rows = await supervisor.views[.panel]?.rows ?? []
        let gmail = try XCTUnwrap(rows.first { $0.title == "Gmail" })
        XCTAssertNotEqual(rows.first?.title, "Gmail")
        await supervisor.press(try XCTUnwrap(gmail.actions.first).id)
        let moved = await waitUntil(10) { await supervisor.views[.panel]?.rows.first?.title == "Gmail" }
        XCTAssertTrue(moved, "the most used quicklink comes first")
        await supervisor.stop()
    }
}
