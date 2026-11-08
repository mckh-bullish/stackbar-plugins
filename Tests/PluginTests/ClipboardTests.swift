import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class ClipboardTests: XCTestCase {
    func testFindsImagesByTheirText() async throws {
        let host = Host(self)
        host.system.simulate(text: RecognizedText(lines: [.init(text: "Invoice 42", confidence: 0.99), .init(text: "Total $10", confidence: 0.9)]), inImage: "abc123")
        let supervisor = try await host.start("Clipboard")
        try host.system.writeClipboard(.image(id: "abc123"))
        let read = await waitUntil(10) { await supervisor.views[.panel]?.rows.contains { $0.title == "Image: Invoice 42" } ?? false }
        let rows = await supervisor.views[.panel]?.rows ?? []
        XCTAssertTrue(read, "\(rows.map(\.title))")
        let row = try XCTUnwrap(rows.first { $0.title == "Image: Invoice 42" })
        XCTAssertEqual(row.preview?.text, "Invoice 42\nTotal $10", "the preview carries the text, so the filter finds it")
        XCTAssertTrue(row.actions.contains { $0.title == "Copy Text in Image" })
        await supervisor.stop()
    }

    func testRecordsCopiesAndSkipsPasswords() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Clipboard")
        func titles() async -> [String] { await supervisor.views[.panel]?.rows.map(\.title) ?? [] }

        // The host polls twice a second, like other clipboard managers, so
        // copies further apart than that are each recorded.
        func copy(_ text: String, app: SystemStatus.App? = SystemStatus.App(id: "com.apple.Safari", name: "Safari"), concealed: Bool = false, formatted: Bool = false) async {
            let before = await supervisor.settledCount
            host.system.simulateCopy(text, app: app, concealed: concealed, formatted: formatted)
            _ = await waitUntil(5) { await supervisor.settledCount > before }
        }
        await copy("first thing")
        await copy("https://example.com/page")
        let recorded = await waitUntil(10) { await titles().contains("https://example.com/page") }
        XCTAssertTrue(recorded, "every copy is recorded")
        await copy("hunter2", concealed: true)
        await copy("from a password manager", app: SystemStatus.App(id: "com.1password.1password", name: "1Password"))
        await copy("last thing")
        _ = await waitUntil(10) { await titles().contains("last thing") }
        let recordedTitles = await titles()
        XCTAssertFalse(recordedTitles.contains("hunter2"), "\(recordedTitles)")
        XCTAssertFalse(recordedTitles.contains("from a password manager"), "password managers are ignored")

        let panel = await supervisor.views[.panel]
        let first = try XCTUnwrap(panel?.rows.first { $0.title == "first thing" })
        await supervisor.press(try XCTUnwrap(first.actions.first).id)
        XCTAssertEqual(host.system.pasted, [.text("first thing")], "a row's primary action pastes it")
        let moved = await waitUntil(10) { await titles().first == "first thing" }
        XCTAssertTrue(moved, "a pasted item moves to the top")

        // Formatted text is pasted back as it was copied, or as plain text on request.
        await copy("**bold**", formatted: true)
        _ = await waitUntil(10) { await titles().first == "**bold**" }
        let rows = await supervisor.views[.panel]?.rows ?? []
        let rich = try XCTUnwrap(rows.first { $0.title == "**bold**" })
        await supervisor.event(try XCTUnwrap(rich.actions.first).id)
        _ = await waitUntil(5) { host.system.pasted.count == 2 }
        guard case .stored = host.system.pasted.last else { return XCTFail("formatted copies paste their stored original: \(host.system.pasted)") }
        // The plain-text action is the one on Option-Return.
        let plain = try XCTUnwrap(rich.actions.first { $0.shortcut == "option+return" }, "\(rich.actions.map(\.title))")
        await supervisor.event(plain.id)
        _ = await waitUntil(5) { host.system.pasted.count == 3 }
        XCTAssertEqual(host.system.pasted.last, .text("**bold**"))
        await supervisor.stop()
    }

    func testRowsCarryTheFullTextAsAPreview() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Clipboard")
        let before = await supervisor.settledCount
        let long = "func greet() {\n    print(\"hello\")\n}\n" + String(repeating: "// more\n", count: 20)
        host.system.simulateCopy(long)
        _ = await waitUntil(5) { await supervisor.settledCount > before }
        let found = await waitUntil(5) { await supervisor.views[.panel]?.rows.contains { $0.preview?.text?.contains("print(\"hello\")") == true } == true }
        XCTAssertTrue(found, "a long copy has its full text as a preview")
        let row = await supervisor.views[.panel]?.rows.first { $0.preview != nil }
        XCTAssertNotNil(row?.preview?.caption)
        host.system.simulateCopy("hello")
        let short = await waitUntil(5) { await supervisor.views[.panel]?.rows.contains { $0.title == "hello" && $0.preview?.text == "hello" } == true }
        XCTAssertTrue(short, "a short copy has a preview too, so the palette's detail pane stays put")
        await supervisor.stop()
    }

    func testMasksCopiesThatLookLikeSecrets() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Clipboard")
        func titles() async -> [String] { await supervisor.views[.panel]?.rows.map(\.title) ?? [] }
        func copy(_ text: String) async {
            let before = await supervisor.settledCount
            host.system.simulateCopy(text)
            _ = await waitUntil(5) { await supervisor.settledCount > before }
        }
        let token = "ghp_" + String(repeating: "a1B2", count: 9)
        await copy(token)
        await copy("4242 4242 4242 4242")
        await copy("a normal sentence with ghp_ in it")
        _ = await waitUntil(10) { await titles().contains("a normal sentence with ghp_ in it") }
        let shown = await titles()
        XCTAssertTrue(shown.contains("•••••••• GitHub token"), "\(shown)")
        XCTAssertTrue(shown.contains("•••••••• card number"), "\(shown)")
        XCTAssertFalse(shown.contains { $0.contains(token) }, "the token itself is never shown")
        let masked = await supervisor.views[.panel]?.rows.first { $0.title == "•••••••• GitHub token" }
        XCTAssertFalse(masked?.preview?.text?.contains(token) ?? false, "nor in the preview")

        // Pasting still pastes the real thing.
        await supervisor.press(try XCTUnwrap(masked?.actions.first).id)
        XCTAssertEqual(host.system.pasted.last, .text(token))
        await supervisor.stop()
    }

    func testPinsCannotPushTheStoredHistoryPastTheQuota() async throws {
        let host = Host(self)
        let id = "io.navbytes.stackbar.clipboard"
        // Six pinned 100,000-character copies: 600 KB, more than pins may use.
        let big = String(repeating: "x", count: 100_000)
        let pinned = (0..<6).map { index in
            #"{"id":"pin\#(index)","kind":"text","text":"\#(big)","files":[],"firstCopied":0,"lastCopied":\#(100 - index),"count":1,"pinned":true}"#
        }
        try await host.services.storage.set("history", "[" + pinned.joined(separator: ",") + "]", for: id)
        let supervisor = try await host.start("Clipboard")
        let before = await supervisor.settledCount
        host.system.simulateCopy("something new")
        _ = await waitUntil(5) { await supervisor.settledCount > before }
        let saved = await waitUntil(10) {
            await self.history(host, id).contains { $0["text"] as? String == "something new" }
        }
        XCTAssertTrue(saved)
        let stored = await history(host, id)
        let stillPinned = stored.filter { $0["pinned"] as? Bool == true }
        XCTAssertLessThanOrEqual(stillPinned.count, 4, "pins past their budget are unpinned")
        let size = await host.services.storage.snapshot(for: id)["history"]?.utf8.count ?? 0
        XCTAssertLessThan(size, 1024 * 1024, "the host would refuse the write otherwise")
        await supervisor.stop()
    }

    func testCopiesStayOutOfThePaletteResultsUntilTurnedOn() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Clipboard")
        _ = await waitUntil(10) { await supervisor.commands.contains { $0.id == "search" } }
        let commands = await supervisor.commands
        let search = try XCTUnwrap(commands.first { $0.id == "search" }, "⌘⇧V still opens the history")
        XCTAssertFalse(search.rootSearch, "off by default")
        host.system.simulateCopy("panel only")
        _ = await waitUntil(10) { await supervisor.views[.panel]?.rows.contains { $0.title == "panel only" } ?? false }
        let rows = await supervisor.views[.panel]?.rows ?? []
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.hiddenFromPalette == true }, "the panel's history rows stay out of the palette")
        await supervisor.stop()
    }

    func testPastePlainUsesTheLastCopyWhateverTheOrder() async throws {
        let host = Host(self)
        let id = "io.navbytes.stackbar.clipboard"
        try await host.services.storage.set("order", "\"Most used\"", for: id)
        try await host.services.storage.set("history", #"[{"id":"a","kind":"text","text":"often","files":[],"firstCopied":0,"lastCopied":100,"count":9,"pinned":false},{"id":"b","kind":"text","text":"latest","files":[],"firstCopied":0,"lastCopied":200,"count":1,"pinned":false},{"id":"c","kind":"text","text":"pinned","files":[],"firstCopied":0,"lastCopied":300,"count":1,"pinned":true}]"#, for: id)
        let session = try await host.session("Clipboard")
        _ = try await session.runCommand("paste-plain")
        XCTAssertEqual(host.system.pasted.last, .text("latest"))
        await session.stop()
    }

    func testClearCommandKeepsPinned() async throws {
        let host = Host(self)
        let id = "io.navbytes.stackbar.clipboard"
        try await host.services.storage.set("history", #"[{"id":"keep","kind":"text","text":"keep me","files":[],"firstCopied":0,"lastCopied":100,"count":1,"pinned":true},{"id":"drop","kind":"text","text":"drop me","files":[],"firstCopied":0,"lastCopied":200,"count":1,"pinned":false}]"#, for: id)
        let session = try await host.session("Clipboard")
        let opened = try await session.openView("clear")
        let rows = await session.commandView(opened.session)?.rows ?? opened.root?.rows ?? []
        let confirm = try XCTUnwrap(rows.first { $0.key == "confirm" })
        try await session.event(try XCTUnwrap(confirm.actions.first).id)
        let cleared = await waitUntil { await self.history(host, id).count == 1 }
        XCTAssertTrue(cleared, "the unpinned copy is cleared")
        let remaining = await history(host, id)
        XCTAssertEqual(remaining.first?["text"] as? String, "keep me", "the pinned copy stays")
        await session.stop()
    }

    func testClearingTheHistoryTakesTwoPresses() async throws {
        let host = Host(self)
        let id = "io.navbytes.stackbar.clipboard"
        try await host.services.storage.set("history", #"[{"id":"a","kind":"text","text":"one","files":[],"firstCopied":0,"lastCopied":100,"count":1,"pinned":false},{"id":"b","kind":"text","text":"two","files":[],"firstCopied":0,"lastCopied":200,"count":1,"pinned":false}]"#, for: id)
        let supervisor = try await host.start("Clipboard")
        let clear = ActionID("button/clear")
        await supervisor.press(clear)
        let afterOne = await history(host, id).count
        XCTAssertEqual(afterOne, 2, "the first click only asks")
        await supervisor.press(clear)
        let cleared = await waitUntil { await self.history(host, id).isEmpty }
        XCTAssertTrue(cleared, "the second click clears the unpinned copies")
        await supervisor.stop()
    }

    private func history(_ host: Host, _ id: String) async -> [[String: Any]] {
        let json = await host.services.storage.snapshot(for: id)["history"] ?? "[]"
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] ?? []
    }
}
