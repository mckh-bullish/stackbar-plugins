import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class ClipboardTests: XCTestCase {
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
}
