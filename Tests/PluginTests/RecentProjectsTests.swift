import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

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
}

extension ViewNode {
    /// Pickers anywhere below, as (options, selection, action).
    var pickers: [(options: [String], selection: String?, action: ActionID)] {
        tree.compactMap { node in
            if case .picker(_, let options, let selection, _, let action) = node { return (options, selection, action) }
            return nil
        }
    }
}
