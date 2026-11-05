import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

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
}
