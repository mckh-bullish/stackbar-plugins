import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class ColorPickerTests: XCTestCase {
    func testConvertsATypedHexColor() async throws {
        let session = try await Host(self).session("ColorPicker")
        let opened = try await session.openView("convert", query: CommandQuery(text: "#0A60C8"))
        let titles = (await session.commandView(opened.session)?.rows ?? opened.root?.rows ?? []).map(\.title)
        XCTAssertTrue(titles.contains("rgb(10, 96, 200)"), "\(titles)")
        XCTAssertTrue(titles.contains("Color(red: 0.039, green: 0.376, blue: 0.784)"), "\(titles)")
        await session.stop()
    }

    func testPickedRowsDontClaimCommandDigits() async throws {
        let session = try await Host(self).session("ColorPicker")
        _ = try await session.runCommand("pick")
        let opened = try await session.openView("history")
        let rows = await session.commandView(opened.session)?.rows ?? opened.root?.rows ?? []
        XCTAssertFalse(rows.isEmpty, "the pick is in the list")
        let shortcuts = rows.flatMap(\.actions).compactMap(\.shortcut)
        XCTAssertFalse(shortcuts.contains { ["cmd+1", "cmd+2", "cmd+3"].contains($0) }, "⌘1 to ⌘9 pick rows, so rows don't claim them: \(shortcuts)")
        await session.stop()
    }

    func testClearingPickedColorsTakesTwoPresses() async throws {
        let host = Host(self)
        let id = "io.navbytes.stackbar.plugins.color-picker"
        try await host.services.storage.set("history", ##"[{"hex":"#0A60C8","at":0},{"hex":"#FF5FA2","at":0}]"##, for: id)
        let session = try await host.session("ColorPicker")
        let clear = ActionID("button/clear")
        let settings = await session.view(.settings)
        XCTAssertEqual(settings?.confirmations[clear], "clear 2 picked colors")
        let held = try await session.event(clear)
        XCTAssertNotNil(held, "Stackbar holds the first click")
        let afterOne = await savedHistory(host, id).count
        XCTAssertEqual(afterOne, 2, "the first click only asks")
        try await session.event(clear)
        let cleared = await waitUntil { await self.savedHistory(host, id).isEmpty }
        XCTAssertTrue(cleared, "the second click clears the colors")
        await session.stop()
    }

    private func savedHistory(_ host: Host, _ id: String) async -> [[String: Any]] {
        let json = await host.services.storage.snapshot(for: id)["history"] ?? "[]"
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] ?? []
    }
}
