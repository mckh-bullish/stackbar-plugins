import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol
@testable import Plugin_RecentProjects

final class RecentProjectsTests: XCTestCase {
    /// Settings offers the installed editors as the default, and keeps the
    /// one picked.
    func testDefaultEditorListsInstalledEditors() async throws {
        let system = SimulatedSystem()
        system.applications = ["Xcode": "com.apple.dt.Xcode", "Zed": "dev.zed.Zed", "Safari": "com.apple.Safari"]
        let supervisor = try await Host(self, system: system).start("RecentProjects")
        XCTAssertTrue(supervisor.manifest.surfaces.contains(.settings))

        let settings = await supervisor.views[.settings]
        let picker = try XCTUnwrap(settings?.pickers.first)
        XCTAssertEqual(picker.options, ["Where it was last opened", "Zed", "Xcode"])
        XCTAssertEqual(picker.selection, "Where it was last opened")

        await supervisor.press(picker.action, value: .text("Zed"))
        let picked = await supervisor.views[.settings]?.pickers.first?.selection
        XCTAssertEqual(picked, "Zed")

        await supervisor.press(picker.action, value: .text("Where it was last opened"))
        let reset = await supervisor.views[.settings]?.pickers.first?.selection
        XCTAssertEqual(reset, "Where it was last opened")
        await supervisor.stop()
    }

    /// VS Code 1.118 keeps its recent list in ~/.vscode-shared, so the plugin
    /// asks to read it as well as the old Application Support folder.
    func testReadsVSCodeSharedStorage() async throws {
        let supervisor = try await Host(self, system: SimulatedSystem()).start("RecentProjects")
        let paths = supervisor.manifest.capabilities.flatMap { capability -> [String] in
            if case .files(let paths) = capability { return paths }
            return []
        }
        XCTAssertTrue(paths.contains("~/.vscode-shared/sharedStorage"))
        XCTAssertTrue(paths.contains("~/Library/Application Support/Code/User/globalStorage"))
        await supervisor.stop()
    }
}

extension ViewNode {
    /// Pickers anywhere below, as (options, selection, action).
    var pickers: [(options: [String], selection: String?, action: ActionID)] {
        tree.compactMap { node in
            if case .picker(_, let options, let selection, _, let action) = node { return (options, selection, action) }
            return nil
        }
    }

    @MainActor
    func testRemoteEntriesAreCountedNotListed() {
        let json = #"{"entries":[{"folderUri":"file:///Users/me/app"},{"folderUri":"vscode-remote://ssh-remote+box/home/me/api"},{"workspace":{"configPath":"vscode-remote://dev-container+1/w.code-workspace"}}]}"#
        XCTAssertEqual(RecentProjects.parse(json, editor: "VS Code").map(\.path), ["/Users/me/app"])
        XCTAssertEqual(RecentProjects.remoteCount(json), 2)
    }
}
