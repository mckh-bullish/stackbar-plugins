import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class AppSwitcherTests: XCTestCase {
    private let safari = "com.apple.Safari"
    private let slack = "com.tinyspeck.slackmacgap"
    private let spotify = "com.spotify.client"
    private let xcode = "com.apple.dt.Xcode"

    private func front(_ host: Host) -> String? { host.system.currentApps.first(where: \.isActive)?.id }

    private func layer(_ host: Host) -> KeyLayer? { host.system.keyLayers.listening.first?.layer }

    func testRunningAppsGetTheirFirstLetter() async throws {
        let host = Host(self)
        let supervisor = try await host.start("AppSwitcher")
        _ = await waitUntil { self.layer(host) != nil }
        let layer = try XCTUnwrap(layer(host))
        XCTAssertEqual(layer.trigger, .rightCommand)
        XCTAssertEqual(layer.bindings.map(\.key), ["f", "s", "x"])
        XCTAssertEqual(layer.binding(for: "s")?.apps, [safari, slack, spotify], "launch order")
        XCTAssertEqual(layer.assignCommand, "assign")

        // Safari is in front: S moves on to Slack, then Spotify, then back.
        await host.system.pressKeyLayer("s")
        XCTAssertEqual(front(host), slack)
        await host.system.pressKeyLayer("s")
        XCTAssertEqual(front(host), spotify)
        await host.system.pressKeyLayer("x")
        XCTAssertEqual(front(host), xcode)
        await host.system.pressKeyLayer("x")
        XCTAssertTrue(host.system.currentApps.first { $0.id == xcode }!.isHidden, "the only app on X hides on a second press")
        let copy = await host.system.pressKeyLayer("c")
        XCTAssertEqual(copy, .passThrough, "Right ⌘ C still copies")
        await supervisor.stop()
    }

    func testPinningALetterOpensTheAppAndReLetters() async throws {
        let host = Host(self)
        let supervisor = try await host.start("AppSwitcher")
        _ = await waitUntil { self.layer(host) != nil }

        // Right ⌘ ⌥ K with Slack in front.
        try await host.system.activateApp(slack, launch: false)
        let chord = await host.system.pressKeyLayer("k", held: [.rightCommand, .rightOption])
        guard case .assign(_, let command, let key, let app) = chord else { return XCTFail("the chord assigns: \(chord)") }
        guard case .message(let message) = await supervisor.runCommand(command, arguments: ["key": key, "app": app], source: .hotkey) else { return XCTFail("assign answers") }
        XCTAssertEqual(message, "Right ⌘ K now opens Slack")
        let pinned = try XCTUnwrap(layer(host))
        XCTAssertEqual(pinned.binding(for: "k"), KeyBinding(key: "k", apps: [slack], launch: true))
        XCTAssertEqual(pinned.binding(for: "s")?.apps, [safari, spotify], "a pinned app leaves its own letter")

        // Slack quits: K still opens it.
        host.system.simulate(apps: host.system.currentApps.filter { $0.id != slack })
        host.system.applications["Slack"] = slack
        await supervisor.appsChanged()
        _ = await waitUntil { self.layer(host)?.binding(for: "s")?.apps == [self.safari, self.spotify] }
        await host.system.pressKeyLayer("k")
        XCTAssertEqual(front(host), slack)
        XCTAssertTrue(host.system.appActions.contains("launch \(slack)"))

        // The same chord again unpins.
        guard case .message(let again) = await supervisor.runCommand("assign", arguments: ["key": "k", "app": slack], source: .hotkey) else { return XCTFail("assign answers") }
        XCTAssertEqual(again, "K is no longer pinned to Slack")
        XCTAssertNil(layer(host)?.binding(for: "k"))
        let letters = await supervisor.callTool("letters").text
        XCTAssertTrue(letters.contains("- S: Safari, Spotify, Slack"), "Slack opened last, so it comes last"); XCTAssertTrue(letters.contains("- F: Finder"), letters)
        await supervisor.stop()
        XCTAssertTrue(host.system.keyLayers.isEmpty, "stopping lets the key go")
    }

    func testSettingsChangeTheLayer() async throws {
        let host = Host(self)
        let supervisor = try await host.start("AppSwitcher")
        _ = await waitUntil { self.layer(host) != nil }
        await supervisor.press("picker/Hold", value: .text("Right ⌥"))
        await supervisor.press("picker/Pressing the letter of the app in front", value: .text("Shows its next window"))
        _ = await waitUntil { self.layer(host)?.trigger == .rightOption }
        let layer = try XCTUnwrap(layer(host))
        XCTAssertEqual(layer.trigger, .rightOption)
        XCTAssertEqual(layer.secondPress, .cycleWindows)
        await host.system.pressKeyLayer("s", held: [.rightOption])
        await host.system.pressKeyLayer("f", held: [.rightOption])
        await host.system.pressKeyLayer("f", held: [.rightOption])
        XCTAssertEqual(host.system.appActions.last, "cycleWindows com.apple.finder")
        await supervisor.stop()
    }
}
