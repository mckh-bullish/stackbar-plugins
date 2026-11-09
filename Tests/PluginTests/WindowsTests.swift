import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol
@testable import Plugin_Windows

final class WindowsTests: XCTestCase {
    /// The sample desk with every window piled into one corner.
    private func scrambled(_ snapshot: WindowSnapshot) -> WindowSnapshot {
        var snapshot = snapshot
        snapshot.windows = snapshot.windows.map { var window = $0; window.frame = WindowRect(x: 10, y: 40, width: 500, height: 400); return window }
        return snapshot
    }

    /// The laptop on its own: the built-in display as the main one.
    private func laptopAlone(_ desk: WindowSnapshot) -> WindowSnapshot {
        var laptop = desk.displays.first { $0.isBuiltIn }!
        laptop.frame = WindowRect(x: 0, y: 0, width: 1512, height: 982)
        laptop.visibleFrame = WindowRect(x: 0, y: 33, width: 1512, height: 949)
        laptop.isMain = true
        let windows = desk.windows.map { var window = $0; window.frame = WindowRect(x: 0, y: 33, width: 1512, height: 949); window.displayID = laptop.id; return window }
        return WindowSnapshot(displays: [laptop], windows: windows)
    }

    func testSaveAndRestoreFromACommand() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Windows")
        let desk = host.system.currentWindows

        guard case .message(let saved) = await supervisor.runCommand("save", arguments: ["name": "Desk"], source: .palette) else { return XCTFail("save saves") }
        XCTAssertEqual(saved, "Saved “Desk” with 4 windows on Studio Display + Built-in")
        guard case .failure = await supervisor.runCommand("save", arguments: ["name": "  "], source: .palette) else { return XCTFail("a layout needs a name") }

        host.system.simulate(windows: scrambled(desk))
        let commands = await supervisor.commands
        guard let restore = commands.first(where: { $0.id.hasPrefix("restore-") }) else { return XCTFail("each layout is a command: \(commands.map(\.id))") }
        XCTAssertEqual(restore.title, "Restore Desk")
        guard case .message(let restored) = await supervisor.runCommand(restore.id, arguments: [:], source: .hotkey) else { return XCTFail("restore restores") }
        XCTAssertEqual(restored, "Restored “Desk”: moved 4 windows")
        XCTAssertEqual(host.system.currentWindows.windows.map(\.frame), desk.windows.map(\.frame))

        guard case .message(let again) = await supervisor.runCommand("restore", arguments: ["layout": "desk"], source: .palette) else { return XCTFail("restore by name") }
        XCTAssertEqual(again, "Restored “Desk”: everything was already in place")
        await supervisor.stop()
    }

    func testDockingBringsBackTheSetupsStarredLayout() async throws {
        let host = Host(self)
        let desk = host.system.currentWindows
        let laptop = laptopAlone(desk)
        let supervisor = try await host.start("Windows")
        _ = await supervisor.runCommand("save", arguments: ["name": "Desk"], source: .palette)

        // Undock: a new setup with nothing saved; nothing moves.
        host.system.simulate(windows: laptop)
        await supervisor.displaysChanged()
        _ = await waitUntil { (await supervisor.callTool("layouts").text).contains("Desk") }
        _ = await supervisor.runCommand("save", arguments: ["name": "Laptop"], source: .palette)
        let tools = await supervisor.callTool("layouts").text
        XCTAssertTrue(tools.contains("- Laptop: 4 windows on Built-in (current setup), starred"), tools)
        XCTAssertTrue(tools.contains("- Desk: 4 windows on Studio Display + Built-in, starred"), tools)

        // Dock again, with the windows still laid out for the laptop.
        var docked = desk
        docked.windows = laptop.windows
        host.system.simulate(windows: docked)
        await supervisor.displaysChanged()
        let back = await waitUntil { host.system.currentWindows.windows.map(\.frame) == desk.windows.map(\.frame) }
        XCTAssertTrue(back, "the desk's layout came back by itself")

        // Same displays again (a display woke): leave the windows alone.
        host.system.simulate(windows: scrambled(desk))
        await supervisor.displaysChanged()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(host.system.currentWindows.windows.first?.frame, WindowRect(x: 10, y: 40, width: 500, height: 400))
        await supervisor.stop()
    }

    func testMissingAppsAreOpenedAndReported() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Windows")
        let desk = host.system.currentWindows
        _ = await supervisor.callTool("save_layout", arguments: ["name": .text("Desk")])
        var quit = desk
        quit.windows = desk.windows.filter { $0.appName != "Slack" && $0.appName != "Xcode" }
        host.system.simulate(windows: quit)
        // Xcode opens with its window somewhere else; Slack isn't installed.
        var xcode = desk.windows[0]
        xcode.frame = WindowRect(x: 0, y: 25, width: 800, height: 600)
        host.system.launchable["com.apple.dt.Xcode"] = [xcode]
        let text = await supervisor.callTool("restore_layout", arguments: ["name": .text("Desk")]).text
        XCTAssertEqual(text, "Restored “Desk”: moved 1 window; opened Xcode; 1 window not open (Slack)")
        await supervisor.stop()
    }

    func testSnapsTheFrontWindowAndUndoes() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Windows")
        let before = host.system.currentWindows
        let front = before.windows.first { !$0.isMinimized }!
        let display = before.display(for: front.frame)!

        let commands = await supervisor.commands.map(\.id)
        XCTAssertTrue(commands.contains("left-half"), "Window Layouts' command ids carry over: \(commands)")
        XCTAssertTrue(commands.contains("restore"), "and Workspaces' restore is still the saved-layout one")
        XCTAssertTrue(commands.contains("undo-snap"))

        guard case .message = await supervisor.runCommand("left-half", arguments: [:], source: .hotkey) else { return XCTFail("left half snaps") }
        let snapped = host.system.currentWindows.windows.first { $0.appID == front.appID && $0.title == front.title }!
        XCTAssertEqual(snapped.frame.x, display.visibleFrame.x)
        XCTAssertEqual(snapped.frame.width, (display.visibleFrame.width / 2).rounded())

        guard case .message = await supervisor.runCommand("undo-snap", arguments: [:], source: .hotkey) else { return XCTFail("undo puts it back") }
        XCTAssertEqual(host.system.currentWindows.windows.first { $0.appID == front.appID && $0.title == front.title }?.frame, front.frame)

        let text = await supervisor.callTool("snap", arguments: ["to": .text("Nowhere")]).text
        XCTAssertTrue(text.hasPrefix("No snap called Nowhere"), text)
        await supervisor.stop()
    }

    func testSnapButtonsSayWhyNothingMoved() async throws {
        let host = Host(self)
        let desk = host.system.currentWindows
        let supervisor = try await host.start("Windows")
        host.system.simulate(windows: laptopAlone(desk))

        await supervisor.press("button/snap-next-display")
        let said = await waitUntil { String(describing: await supervisor.views[.panel]).contains("Only one display") }
        XCTAssertTrue(said, "the panel says why nothing moved")
        await supervisor.stop()
    }

    func testRestoringAnotherSetupsLayoutKeepsWindowsOnScreen() async throws {
        let host = Host(self)
        let desk = host.system.currentWindows
        let supervisor = try await host.start("Windows")
        _ = await supervisor.runCommand("save", arguments: ["name": "Desk"], source: .palette)

        // Only the laptop is connected now, so the desk's windows sit off every screen.
        host.system.simulate(windows: laptopAlone(desk))
        await supervisor.displaysChanged()
        guard case .message = await supervisor.runCommand("restore", arguments: ["layout": "Desk"], source: .palette) else { return XCTFail("the layout restores") }

        let now = host.system.currentWindows
        for window in now.windows where !window.isMinimized {
            let onScreen = now.displays.contains { $0.frame.contains(x: window.frame.midX, y: window.frame.midY) }
            XCTAssertTrue(onScreen, "\(window.appName) is on a screen")
        }
        await supervisor.stop()
    }

    func testDeletingALayoutAsksTwice() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Windows")
        _ = await supervisor.runCommand("save", arguments: ["name": "Desk"], source: .palette)
        // The command list follows the save in a message of its own.
        _ = await waitUntil { await supervisor.commands.contains { $0.id.hasPrefix("restore-") } }
        let commands = await supervisor.commands
        guard let restore = commands.first(where: { $0.id.hasPrefix("restore-") }) else { return XCTFail("each layout is a command") }
        let id = String(restore.id.dropFirst("restore-".count))

        // Stackbar asks for the second click; the plugin only says what it confirms.
        let delete = ActionID("button/delete-\(id)")
        _ = await waitUntil { await supervisor.views[.panel]?.confirmations[delete] != nil }
        let panel = await supervisor.views[.panel]
        XCTAssertEqual(panel?.confirmations[delete], "delete Desk")
        await supervisor.press(delete)
        let after = await supervisor.callTool("layouts").text
        XCTAssertEqual(after, "No layouts saved", "the confirmed click deletes it")
        await supervisor.stop()
    }

    func testPressingAHalfAgainCyclesAndUndoGoesBack() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Windows")
        let before = host.system.currentWindows
        let front = before.windows.first { !$0.isMinimized }!
        let visible = before.display(for: front.frame)!.visibleFrame
        func frontWindow() -> WindowInfo? { host.system.currentWindows.windows.first { $0.appID == front.appID && $0.title == front.title } }

        // Left Half three times: a half, then two thirds, then one third.
        for fraction in [0.5, 2.0 / 3, 1.0 / 3] {
            guard case .message = await supervisor.runCommand("left-half", arguments: [:], source: .hotkey) else { return XCTFail("left half snaps") }
            XCTAssertEqual(frontWindow()?.frame.width, (visible.width * fraction).rounded())
        }
        guard case .message = await supervisor.runCommand("undo-snap", arguments: [:], source: .hotkey) else { return XCTFail("undo puts it back") }
        XCTAssertEqual(frontWindow()?.frame, front.frame, "undo goes back past the whole cycle")
        await supervisor.stop()
    }

    func testPreviousDisplayIsACommandOnly() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Windows")
        let laptop = host.system.currentWindows.displays.first { $0.isBuiltIn }!
        let commands = await supervisor.commands.map(\.id)
        XCTAssertTrue(commands.contains("previous-display"), "\(commands)")

        guard case .message = await supervisor.runCommand("previous-display", arguments: [:], source: .palette) else { return XCTFail("the front window moves to the other display") }
        let front = host.system.currentWindows.windows.first { $0.appID == "com.apple.dt.Xcode" }
        XCTAssertEqual(front?.displayID, laptop.id)

        let panel = String(describing: await supervisor.views[.panel])
        XCTAssertFalse(panel.contains("snap-previous-display"), "the panel grid leaves it out")
        XCTAssertTrue(panel.contains("snap-next-display"), "Next Display stays in the grid")
        await supervisor.stop()
    }

    func testNextDisplayKeepsTheWindowsShareOfTheScreen() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Windows")
        let before = host.system.currentWindows
        let front = before.windows.first { !$0.isMinimized }!
        func frontWindow() -> WindowInfo? { host.system.currentWindows.windows.first { $0.appID == front.appID && $0.title == front.title } }
        guard case .message = await supervisor.runCommand("left-half", arguments: [:], source: .hotkey) else { return XCTFail("left half snaps") }
        let from = before.display(for: frontWindow()!.frame)!
        guard case .message = await supervisor.runCommand("next-display", arguments: [:], source: .hotkey) else { return XCTFail("it moves") }
        let to = host.system.currentWindows.displays.first { $0.id != from.id }!
        XCTAssertEqual(frontWindow()?.frame.width, (to.visibleFrame.width / 2).rounded(), "a half stays a half")
        XCTAssertEqual(frontWindow()?.frame.x, to.visibleFrame.x, "on the left")
        await supervisor.stop()
    }

    @MainActor
    func testMakeLargerAndSmallerStayOnScreen() {
        let visible = WindowRect(x: 0, y: 0, width: 1000, height: 800)
        let larger = Windows.snaps.first { $0.id == "make-larger" }!
        let smaller = Windows.snaps.first { $0.id == "make-smaller" }!
        let grown = Windows.frame(larger, window: WindowRect(x: 0, y: 0, width: 400, height: 400), visible: visible)
        XCTAssertEqual(grown, WindowRect(x: 0, y: 0, width: 500, height: 480), "pushed back on screen at the corner")
        let full = Windows.frame(larger, window: visible, visible: visible)
        XCTAssertEqual(full, visible, "never larger than the screen")
        let shrunk = Windows.frame(smaller, window: WindowRect(x: 100, y: 100, width: 200, height: 160), visible: visible)
        XCTAssertEqual(shrunk?.width, 200, "never smaller than a fifth")
    }

    func testALayoutCanKeepOnlySomeAppsAndLoseAWindow() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Windows")
        let desk = host.system.currentWindows
        let first = desk.windows[0]
        guard case .message(let saved) = await supervisor.runCommand("save", arguments: ["name": "Code", "apps": first.appName], source: .palette) else { return XCTFail("save saves") }
        let count = desk.windows.filter { $0.appID == first.appID }.count
        XCTAssertTrue(saved?.contains(count == 1 ? "1 window" : "\(count) windows") == true, saved ?? "")
        guard case .failure = await supervisor.runCommand("save", arguments: ["name": "None", "apps": "No Such App"], source: .palette) else { return XCTFail("nothing to save") }
        await supervisor.stop()
    }

    @MainActor
    func testAppNamesMatchByNameOrBundleID() {
        let placement = WindowPlacement(appID: "com.apple.Safari", appName: "Safari", frame: WindowRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertTrue(Windows.matches(placement, Windows.appNames(" xcode , SAFARI")))
        XCTAssertTrue(Windows.matches(placement, Windows.appNames("com.apple.safari")))
        XCTAssertFalse(Windows.matches(placement, Windows.appNames("Xcode")))
        XCTAssertTrue(Windows.matches(placement, []))
    }
}
